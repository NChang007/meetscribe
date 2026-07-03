import Foundation

/// Per-speaker voice profile on disk. Stores embedding centroids (not raw audio).
/// Recognition improves as more embeddings are merged after each analyzed session.
public struct VoiceProfileMetadata: Codable, Sendable {
    public var speakerId: String
    public var label: String?
    public var embeddingCount: Int
    public var updatedAt: Date
    public var sessionCount: Int
}

public enum VoiceProfileStore {
    public static func refreshProfile(speakerId: String, store: SpeakerStore) throws {
        let embeddings = try store.embeddings(for: speakerId)
        guard !embeddings.isEmpty else { return }

        let vectors = embeddings.map(\.asFloats)
        guard let centroid = MathUtil.mean(of: vectors) else { return }

        let directory = MeetscribePaths.voiceProfileDirectory(speakerId: speakerId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let centroidURL = directory.appendingPathComponent("centroid.bin")
        let centroidData = centroid.withUnsafeBufferPointer { Data(buffer: $0) }
        try centroidData.write(to: centroidURL, options: .atomic)

        let speaker = try store.allSpeakers().first { $0.id == speakerId }
        let uniqueSessions = Set(embeddings.compactMap(\.sessionId)).count
        let metadata = VoiceProfileMetadata(
            speakerId: speakerId,
            label: speaker?.label,
            embeddingCount: embeddings.count,
            updatedAt: Date(),
            sessionCount: uniqueSessions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("profile.json"), options: .atomic)
    }

    public static func refreshProfiles(for speakerIds: Set<String>, store: SpeakerStore) throws {
        for speakerId in speakerIds {
            try refreshProfile(speakerId: speakerId, store: store)
        }
    }
}
