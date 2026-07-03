import Foundation

public struct RecordingSession: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var attendees: [String]
    public var calendarEventId: String?
    public var status: Status

    public enum Status: String, Codable, Sendable {
        case recording
        case recorded
        case transcribed
        case failed
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        attendees: [String] = [],
        calendarEventId: String? = nil,
        status: Status = .recording
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attendees = attendees
        self.calendarEventId = calendarEventId
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, attendees, calendarEventId, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        attendees = try container.decodeIfPresent([String].self, forKey: .attendees) ?? []
        calendarEventId = try container.decodeIfPresent(String.self, forKey: .calendarEventId)
        status = try container.decode(Status.self, forKey: .status)
    }
}

public struct SpeakerEvent: Codable, Sendable {
    public let timestamp: TimeInterval
    public let speakerName: String
    public let source: String

    public init(timestamp: TimeInterval, speakerName: String, source: String) {
        self.timestamp = timestamp
        self.speakerName = speakerName
        self.source = source
    }
}

public struct TranscriptSegment: Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let speakerLabel: String?
    public var resolvedSpeaker: String?

    public init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerLabel: String? = nil,
        resolvedSpeaker: String? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
        self.resolvedSpeaker = resolvedSpeaker
    }
}

public struct ResolvedTranscript: Codable, Sendable {
    public let sessionId: String
    public let segments: [TranscriptSegment]
    public let generatedAt: Date

    public init(sessionId: String, segments: [TranscriptSegment], generatedAt: Date = Date()) {
        self.sessionId = sessionId
        self.segments = segments
        self.generatedAt = generatedAt
    }
}
