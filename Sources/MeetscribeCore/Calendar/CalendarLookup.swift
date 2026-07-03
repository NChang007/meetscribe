import Foundation

public struct CalendarMeeting: Sendable {
    public let eventIdentifier: String
    public let title: String
    public let attendees: [String]
    public let startDate: Date
    public let endDate: Date
    public let hasVideoLink: Bool
}

public enum CalendarLookupError: Error, LocalizedError {
    case gcalcliNotFound
    case gcalcliFailed(String)
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .gcalcliNotFound:
            return "gcalcli not found. Install with: brew install gcalcli"
        case .gcalcliFailed(let detail):
            return "gcalcli failed: \(detail)"
        case .notAuthenticated:
            return "gcalcli is not authenticated. Run: gcalcli init"
        }
    }
}

/// Google Calendar lookup via [gcalcli](https://github.com/insanum/gcalcli) (no macOS Calendar app required).
public enum CalendarLookup {
    private static let videoHostMarkers = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
    ]

    public static func gcalcliInstalled(config: MeetscribeConfig = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()) -> Bool {
        resolveExecutable(config: config) != nil
    }

    private static let authCache = AuthStatusCache()

    /// Returns true when gcalcli can read today's agenda (OAuth configured). Result cached ~5 minutes for doctor/permissions.
    public static func authorizationGranted(config: MeetscribeConfig = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()) -> Bool {
        if let cached = authCache.readIfValid() {
            return cached
        }

        guard gcalcliInstalled(config: config) else {
            authCache.store(granted: false)
            return false
        }
        let granted = (try? probeAgenda(config: config)) != nil
        authCache.store(granted: granted)
        return granted
    }

    public static func requestAccess() async throws -> Bool {
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        guard gcalcliInstalled(config: config) else {
            throw CalendarLookupError.gcalcliNotFound
        }
        if authorizationGranted(config: config) { return true }
        throw CalendarLookupError.notAuthenticated
    }

    public static func meetingAt(
        date: Date = Date(),
        config: MeetscribeConfig = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
    ) -> CalendarMeeting? {
        guard gcalcliInstalled(config: config) else { return nil }

        let (rangeStart, rangeEnd) = agendaRange(around: date)
        if let jsonEvents = try? fetchJSONEvents(start: rangeStart, end: rangeEnd, config: config),
           let meeting = pickMeeting(from: jsonEvents, at: date) {
            return meeting
        }

        if let tsvEvents = try? fetchTSVEvents(start: rangeStart, end: rangeEnd, config: config),
           let meeting = pickMeeting(from: tsvEvents, at: date) {
            return meeting
        }

        return nil
    }

    public static func shouldReplaceDefaultTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "untitled meeting"
            || normalized == "auto-recorded call"
    }

    // MARK: - gcalcli subprocess

    private static func resolveExecutable(config: MeetscribeConfig) -> String? {
        let configured = config.gcalcliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        for candidate in ["/opt/homebrew/bin/gcalcli", "/usr/local/bin/gcalcli"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return which("gcalcli")
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    private static func probeAgenda(config: MeetscribeConfig) throws -> Bool {
        let today = dayString(for: Date())
        _ = try runGcalcli(
            arguments: ["--tsv", "--nocolor", "agenda", today, today],
            config: config,
            timeoutSeconds: 15
        )
        return true
    }

    private static func runGcalcli(
        arguments: [String],
        config: MeetscribeConfig,
        timeoutSeconds: TimeInterval = 30
    ) throws -> String {
        guard let executable = resolveExecutable(config: config) else {
            throw CalendarLookupError.gcalcliNotFound
        }

        var fullArguments = arguments
        if let calendar = config.gcalcliCalendar?.trimmingCharacters(in: .whitespacesAndNewlines),
           !calendar.isEmpty {
            fullArguments = ["--calendar", calendar] + fullArguments
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = fullArguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw CalendarLookupError.gcalcliFailed("timed out after \(Int(timeoutSeconds))s")
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("auth")
                || detail.localizedCaseInsensitiveContains("credential")
                || detail.localizedCaseInsensitiveContains("oauth") {
                throw CalendarLookupError.notAuthenticated
            }
            throw CalendarLookupError.gcalcliFailed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }

        return stdout
    }

    // MARK: - JSON (gcalcli forks / builds with --json)

    private struct GcalJSONEvent: Decodable {
        struct DateTime: Decodable {
            let dateTime: String?
            let date: String?
        }

        struct Attendee: Decodable {
            let email: String?
            let displayName: String?
            let responseStatus: String?
        }

        let id: String?
        let summary: String?
        let start: DateTime?
        let end: DateTime?
        let attendees: [Attendee]?
        let location: String?
        let description: String?
        let hangoutLink: String?
    }

    private static func fetchJSONEvents(
        start: String,
        end: String,
        config: MeetscribeConfig
    ) throws -> [ParsedCalendarEvent] {
        let output = try runGcalcli(
            arguments: ["--json", "--nocolor", "--details", "all", "agenda", start, end],
            config: config
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{") else {
            throw CalendarLookupError.gcalcliFailed("no JSON output (try upgrading gcalcli or use brew install gcalcli)")
        }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()

        if trimmed.hasPrefix("[") {
            let events = try decoder.decode([GcalJSONEvent].self, from: data)
            return events.compactMap(mapJSONEvent)
        }

        let event = try decoder.decode(GcalJSONEvent.self, from: data)
        return mapJSONEvent(event).map { [$0] } ?? []
    }

    private static func mapJSONEvent(_ event: GcalJSONEvent) -> ParsedCalendarEvent? {
        guard let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let startDate = parseJSONDate(event.start) else {
            return nil
        }
        let endDate = parseJSONDate(event.end) ?? startDate.addingTimeInterval(3600)

        let attendees = (event.attendees ?? [])
            .filter { ($0.responseStatus ?? "") != "declined" }
            .compactMap { attendee -> String? in
                if let name = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return name
                }
                if let email = attendee.email, let local = email.split(separator: "@").first {
                    return String(local).replacingOccurrences(of: ".", with: " ").capitalized
                }
                return nil
            }

        let haystack = [
            event.location ?? "",
            event.description ?? "",
            event.hangoutLink ?? "",
        ].joined(separator: " ").lowercased()

        return ParsedCalendarEvent(
            id: event.id ?? UUID().uuidString,
            title: title,
            attendees: Array(Set(attendees)).sorted(),
            startDate: startDate,
            endDate: endDate,
            hasVideoLink: videoHostMarkers.contains { haystack.contains($0) } || event.hangoutLink != nil
        )
    }

    private static func parseJSONDate(_ value: GcalJSONEvent.DateTime?) -> Date? {
        guard let value else { return nil }
        if let dateTime = value.dateTime {
            return parseFlexibleDate(dateTime)
        }
        if let dateOnly = value.date {
            return parseFlexibleDate(dateOnly)
        }
        return nil
    }

    // MARK: - TSV (standard gcalcli)

    private struct ParsedCalendarEvent: Sendable {
        let id: String
        let title: String
        let attendees: [String]
        let startDate: Date
        let endDate: Date
        let hasVideoLink: Bool
    }

    private static func fetchTSVEvents(
        start: String,
        end: String,
        config: MeetscribeConfig
    ) throws -> [ParsedCalendarEvent] {
        let output = try runGcalcli(
            arguments: [
                "--tsv", "--nocolor",
                "--details", "id,time,title,location,description,attendees,url",
                "agenda", start, end,
            ],
            config: config
        )
        return parseTSV(output)
    }

    private static func parseTSV(_ output: String) -> [ParsedCalendarEvent] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else { return [] }

        let headers = lines[0].split(separator: "\t").map { String($0).lowercased() }
        func index(_ name: String) -> Int? {
            headers.firstIndex(of: name)
        }

        var events: [ParsedCalendarEvent] = []
        for line in lines.dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= headers.count else { continue }

            func field(_ name: String) -> String {
                guard let idx = index(name), idx < columns.count else { return "" }
                return columns[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let title = field("title")
            guard !title.isEmpty else { continue }

            let (startDate, endDate) = parseTSVTime(field("time")) ?? (Date(), Date().addingTimeInterval(3600))
            let attendeeField = field("attendees")
            let attendees = attendeeField
                .split(separator: ";")
                .map { piece in
                    let email = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let local = email.split(separator: "@").first {
                        return String(local).replacingOccurrences(of: ".", with: " ").capitalized
                    }
                    return email
                }
                .filter { !$0.isEmpty }

            let haystack = [
                field("location"),
                field("description"),
                field("url"),
            ].joined(separator: " ").lowercased()

            events.append(
                ParsedCalendarEvent(
                    id: field("id").isEmpty ? UUID().uuidString : field("id"),
                    title: title,
                    attendees: Array(Set(attendees)).sorted(),
                    startDate: startDate,
                    endDate: endDate,
                    hasVideoLink: videoHostMarkers.contains { haystack.contains($0) }
                )
            )
        }
        return events
    }

    private static func parseTSVTime(_ value: String) -> (Date, Date)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(" - ") {
            let parts = trimmed.components(separatedBy: " - ")
            if parts.count == 2,
               let start = parseFlexibleDate(parts[0]),
               let end = parseFlexibleDate(parts[1]) {
                return (start, end)
            }
        }

        if let start = parseFlexibleDate(trimmed) {
            return (start, start.addingTimeInterval(3600))
        }
        return nil
    }

    private static func parseFlexibleDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "EEE MMM dd HH:mm:ss yyyy",
            "MMM d, yyyy HH:mm",
            "MMM  d HH:mm",
            "MMM d HH:mm",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private static func pickMeeting(from events: [ParsedCalendarEvent], at date: Date) -> CalendarMeeting? {
        let candidates = events.filter { event in
            date >= event.startDate && date <= event.endDate && isLikelyMeeting(event)
        }
        guard !candidates.isEmpty else { return nil }

        let best = candidates.max { lhs, rhs in
            score(event: lhs, at: date) < score(event: rhs, at: date)
        }

        guard let best else { return nil }
        return CalendarMeeting(
            eventIdentifier: best.id,
            title: best.title,
            attendees: best.attendees,
            startDate: best.startDate,
            endDate: best.endDate,
            hasVideoLink: best.hasVideoLink
        )
    }

    private static func isLikelyMeeting(_ event: ParsedCalendarEvent) -> Bool {
        if event.hasVideoLink { return true }
        return !event.attendees.isEmpty
    }

    private static func score(event: ParsedCalendarEvent, at date: Date) -> Int {
        var points = 0
        if event.hasVideoLink { points += 100 }
        points += min(event.attendees.count, 10) * 5
        let startDelta = abs(event.startDate.timeIntervalSince(date))
        points += max(0, 30 - Int(startDelta / 60))
        return points
    }

    private static func agendaRange(around date: Date) -> (String, String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        let start = date.addingTimeInterval(-15 * 60)
        let end = date.addingTimeInterval(60 * 60)
        return (formatter.string(from: start), formatter.string(from: end))
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

private final class AuthStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (expires: Date, granted: Bool)?

    func readIfValid() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.expires > Date() else { return nil }
        return entry.granted
    }

    func store(granted: Bool) {
        lock.lock()
        entry = (Date().addingTimeInterval(300), granted)
        lock.unlock()
    }
}
