import Foundation

public struct MeetscribeConfig: Codable, Sendable {
    public var sessionsDirectory: String
    public var defaultLanguage: LanguageCode
    public var similarityThreshold: Float
    public var autoProcessOnStop: Bool
    public var allowModelDownload: Bool
    public var defaultCalendarAttendees: [String]

    /// Off by default. When enabled, `meetscribe watch start` polls CoreAudio ~every 3s.
    public var autoRecordEnabled: Bool
    public var autoRecordPollSeconds: Double

    /// Remove meeting.wav after successful on-device analysis (embeddings are kept).
    public var deleteAudioAfterAnalysis: Bool

    /// Show mic/system level bars during foreground recording.
    public var showLevelMeter: Bool

    /// Pull meeting title + attendees from Google Calendar via gcalcli at record start.
    public var useCalendar: Bool

    /// Path to gcalcli binary (default: search PATH).
    public var gcalcliPath: String

    /// Optional gcalcli calendar name/email (maps to `gcalcli --calendar`).
    public var gcalcliCalendar: String?

    /// Keep short voice samples for unlabeled speakers until `speakers review`.
    public var keepReviewSnippets: Bool

    public enum LanguageCode: String, Codable, Sendable {
        case auto
        case en
        case de
    }

    private enum CodingKeys: String, CodingKey {
        case sessionsDirectory
        case defaultLanguage
        case similarityThreshold
        case autoProcessOnStop
        case allowModelDownload
        case defaultCalendarAttendees
        case autoRecordEnabled
        case autoRecordPollSeconds
        case deleteAudioAfterAnalysis
        case showLevelMeter
        case useCalendar
        case gcalcliPath
        case gcalcliCalendar
        case keepReviewSnippets
    }

    public init(
        sessionsDirectory: String? = nil,
        defaultLanguage: LanguageCode = .auto,
        similarityThreshold: Float = 0.6,
        autoProcessOnStop: Bool = true,
        allowModelDownload: Bool = false,
        defaultCalendarAttendees: [String] = [],
        autoRecordEnabled: Bool = false,
        autoRecordPollSeconds: Double = 3.0,
        deleteAudioAfterAnalysis: Bool = true,
        showLevelMeter: Bool = true,
        useCalendar: Bool = true,
        gcalcliPath: String = "gcalcli",
        gcalcliCalendar: String? = nil,
        keepReviewSnippets: Bool = true
    ) {
        self.sessionsDirectory = sessionsDirectory ?? MeetscribePaths.defaultSessionsDirectory.path
        self.defaultLanguage = defaultLanguage
        self.similarityThreshold = similarityThreshold
        self.autoProcessOnStop = autoProcessOnStop
        self.allowModelDownload = allowModelDownload
        self.defaultCalendarAttendees = defaultCalendarAttendees
        self.autoRecordEnabled = autoRecordEnabled
        self.autoRecordPollSeconds = autoRecordPollSeconds
        self.deleteAudioAfterAnalysis = deleteAudioAfterAnalysis
        self.showLevelMeter = showLevelMeter
        self.useCalendar = useCalendar
        self.gcalcliPath = gcalcliPath
        self.gcalcliCalendar = gcalcliCalendar
        self.keepReviewSnippets = keepReviewSnippets
    }

    public init(from decoder: Decoder) throws {
        let defaults = MeetscribeConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionsDirectory = try container.decodeIfPresent(String.self, forKey: .sessionsDirectory)
            ?? defaults.sessionsDirectory
        defaultLanguage = try container.decodeIfPresent(LanguageCode.self, forKey: .defaultLanguage)
            ?? defaults.defaultLanguage
        similarityThreshold = try container.decodeIfPresent(Float.self, forKey: .similarityThreshold)
            ?? defaults.similarityThreshold
        autoProcessOnStop = try container.decodeIfPresent(Bool.self, forKey: .autoProcessOnStop)
            ?? defaults.autoProcessOnStop
        allowModelDownload = try container.decodeIfPresent(Bool.self, forKey: .allowModelDownload)
            ?? defaults.allowModelDownload
        defaultCalendarAttendees = try container.decodeIfPresent([String].self, forKey: .defaultCalendarAttendees)
            ?? defaults.defaultCalendarAttendees
        autoRecordEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRecordEnabled)
            ?? defaults.autoRecordEnabled
        autoRecordPollSeconds = try container.decodeIfPresent(Double.self, forKey: .autoRecordPollSeconds)
            ?? defaults.autoRecordPollSeconds
        deleteAudioAfterAnalysis = try container.decodeIfPresent(Bool.self, forKey: .deleteAudioAfterAnalysis)
            ?? defaults.deleteAudioAfterAnalysis
        showLevelMeter = try container.decodeIfPresent(Bool.self, forKey: .showLevelMeter)
            ?? defaults.showLevelMeter
        useCalendar = try container.decodeIfPresent(Bool.self, forKey: .useCalendar)
            ?? defaults.useCalendar
        gcalcliPath = try container.decodeIfPresent(String.self, forKey: .gcalcliPath)
            ?? defaults.gcalcliPath
        gcalcliCalendar = try container.decodeIfPresent(String.self, forKey: .gcalcliCalendar)
        keepReviewSnippets = try container.decodeIfPresent(Bool.self, forKey: .keepReviewSnippets)
            ?? defaults.keepReviewSnippets
    }

    public static func load() throws -> MeetscribeConfig {
        let configURL = MeetscribePaths.configFile
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return MeetscribeConfig()
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(MeetscribeConfig.self, from: data)
    }

    public func save() throws {
        try MeetscribePaths.ensureConfigDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: MeetscribePaths.configFile, options: .atomic)
    }
}

public enum MeetscribePaths {
    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meetscribe", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static var defaultSessionsDirectory: URL {
        configDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var speakerDatabaseURL: URL {
        configDirectory.appendingPathComponent("speakers.sqlite")
    }

    public static var voiceProfilesDirectory: URL {
        configDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    public static func voiceProfileDirectory(speakerId: String) -> URL {
        voiceProfilesDirectory.appendingPathComponent(speakerId, isDirectory: true)
    }

    public static func ensureConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
    }
}
