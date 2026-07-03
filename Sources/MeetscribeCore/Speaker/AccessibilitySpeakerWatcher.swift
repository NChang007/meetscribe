import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum SpeakerWatcherError: Error, LocalizedError {
    case accessibilityPermissionDenied
    case unsupportedMeetingApp
}

/// Polls meeting app UI via Accessibility API to detect the active speaker.
public final class AccessibilitySpeakerWatcher: @unchecked Sendable {
    public struct MeetingApp: Sendable {
        public let name: String
        public let bundleIdentifiers: [String]

        public static let zoom = MeetingApp(
            name: "Zoom",
            bundleIdentifiers: ["us.zoom.xos", "us.zoom.caphost"]
        )
        public static let googleMeet = MeetingApp(
            name: "Google Meet",
            bundleIdentifiers: ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "company.thebrowser.Browser"]
        )
        public static let teams = MeetingApp(
            name: "Microsoft Teams",
            bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"]
        )

        public static let all: [MeetingApp] = [.zoom, .googleMeet, .teams]
    }

    private let outputURL: URL
    private let pollInterval: TimeInterval
    private let meetingApps: [MeetingApp]
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()
    private let fileHandle: FileHandle
    private var lastLoggedSpeaker: String?

    public init(
        outputURL: URL,
        pollInterval: TimeInterval = 0.4,
        meetingApps: [MeetingApp] = MeetingApp.all
    ) throws {
        self.outputURL = outputURL
        self.pollInterval = pollInterval
        self.meetingApps = meetingApps

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw SpeakerWatcherError.accessibilityPermissionDenied
        }
        fileHandle = handle
    }

    public var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    public static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary)
    }

    public func start() throws {
        guard Self.isAccessibilityTrusted(prompt: true) else {
            throw SpeakerWatcherError.accessibilityPermissionDenied
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "meetscribe.speaker-watcher"))
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        try? fileHandle.close()
    }

    private func pollOnce() {
        guard let speaker = detectActiveSpeaker() else { return }
        guard speaker != lastLoggedSpeaker else { return }
        lastLoggedSpeaker = speaker

        let event = SpeakerEvent(
            timestamp: elapsedSeconds,
            speakerName: speaker,
            source: "accessibility"
        )
        guard let lineData = try? JSONEncoder().encode(event),
              var line = String(data: lineData, encoding: .utf8) else {
            return
        }
        line.append("\n")
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    private func detectActiveSpeaker() -> String? {
        for app in meetingApps {
            for bundleId in app.bundleIdentifiers {
                guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleId
                }) else {
                    continue
                }

                let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
                if let speaker = findActiveSpeaker(in: appElement, appName: app.name) {
                    return speaker
                }
            }
        }
        return nil
    }

    private func findActiveSpeaker(in element: AXUIElement, appName: String, depth: Int = 0) -> String? {
        if depth > 14 { return nil }

        if let title = attributeString(element, kAXTitleAttribute as String),
           looksLikeSpeakingIndicator(title) {
            return cleanSpeakerName(title)
        }

        if let value = attributeString(element, kAXValueAttribute as String),
           looksLikeSpeakingIndicator(value) {
            return cleanSpeakerName(value)
        }

        if let description = attributeString(element, kAXDescriptionAttribute as String),
           looksLikeSpeakingIndicator(description) {
            return cleanSpeakerName(description)
        }

        if isSpeakingElement(element),
           let title = attributeString(element, kAXTitleAttribute as String) {
            return cleanSpeakerName(title)
        }

        guard let children = attributeValue(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let speaker = findActiveSpeaker(in: child, appName: appName, depth: depth + 1) {
                return speaker
            }
        }
        return nil
    }

    private func isSpeakingElement(_ element: AXUIElement) -> Bool {
        let attributes = [
            kAXSelectedAttribute as String,
            kAXFocusedAttribute as String,
            "AXSpeaking",
            "AXActive",
        ]

        for attribute in attributes {
            if let value = attributeValue(element, attribute) as? Bool, value {
                return true
            }
            if let value = attributeValue(element, attribute) as? NSNumber, value.boolValue {
                return true
            }
        }

        if let role = attributeString(element, kAXRoleAttribute as String)?.lowercased(),
           role.contains("speaking") || role.contains("active") {
            return true
        }

        return false
    }

    private func looksLikeSpeakingIndicator(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("is speaking") || lowered.contains("speaking") {
            return true
        }
        if text.count >= 2, text.count <= 80, !lowered.contains("http") {
            return isSpeakingElementForText(text)
        }
        return false
    }

    private func isSpeakingElementForText(_ text: String) -> Bool {
        !text.localizedCaseInsensitiveContains("mute") &&
            !text.localizedCaseInsensitiveContains("chat") &&
            !text.localizedCaseInsensitiveContains("share")
    }

    private func cleanSpeakerName(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: " is speaking", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " (speaking)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("(You)") {
            name = "You"
        }
        return name
    }

    private func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        attributeValue(element, attribute) as? String
    }

    private func attributeValue(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value
    }
}

public enum SpeakerEventLoader {
    public static func load(from url: URL) throws -> [SpeakerEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(SpeakerEvent.self, from: Data(line.utf8))
            }
    }
}
