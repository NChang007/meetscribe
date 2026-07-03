import Foundation

public struct SpeakerMatchResult: Sendable {
    public let speakerId: String
    public let isNew: Bool
    public let similarity: Float
}

public final class SpeakerMatcher {
    public struct Config: Sendable {
        public let threshold: Float
        public let neighborCount: Int
        public let minVotesRatio: Float

        public init(threshold: Float, neighborCount: Int = 5, minVotesRatio: Float = 0.2) {
            self.threshold = threshold
            self.neighborCount = neighborCount
            self.minVotesRatio = minVotesRatio
        }
    }

    private let store: SpeakerStore
    private let config: Config
    private var cache: [(speakerId: String, embedding: [Float])]

    public init(store: SpeakerStore, config: Config) throws {
        self.store = store
        self.config = config
        cache = try Self.loadAllEmbeddings(from: store)
    }

    private static func loadAllEmbeddings(from store: SpeakerStore) throws -> [(String, [Float])] {
        var output: [(String, [Float])] = []
        for speaker in try store.allSpeakers() {
            for embedding in try store.embeddings(for: speaker.id) {
                output.append((speaker.id, embedding.asFloats))
            }
        }
        return output
    }

    public func matchOrCreate(
        centroid: [Float],
        sessionId: String?,
        segmentRange: (Double, Double)?
    ) throws -> SpeakerMatchResult {
        let decision = decide(for: centroid)
        switch decision {
        case .match(let speakerId, let similarity):
            _ = try store.insertEmbedding(
                SpeakerEmbeddingRecord(
                    speakerId: speakerId,
                    vector: centroid,
                    sessionId: sessionId,
                    segmentStart: segmentRange?.0,
                    segmentEnd: segmentRange?.1
                )
            )
            cache.append((speakerId, centroid))
            return SpeakerMatchResult(speakerId: speakerId, isNew: false, similarity: similarity)
        case .newSpeaker:
            let speaker = KnownSpeaker()
            try store.insertSpeaker(speaker)
            _ = try store.insertEmbedding(
                SpeakerEmbeddingRecord(
                    speakerId: speaker.id,
                    vector: centroid,
                    sessionId: sessionId,
                    segmentStart: segmentRange?.0,
                    segmentEnd: segmentRange?.1
                )
            )
            cache.append((speaker.id, centroid))
            return SpeakerMatchResult(speakerId: speaker.id, isNew: true, similarity: 1.0)
        }
    }

    private enum Decision {
        case match(speakerId: String, similarity: Float)
        case newSpeaker
    }

    private func decide(for centroid: [Float]) -> Decision {
        guard !cache.isEmpty else { return .newSpeaker }

        var scored: [(speakerId: String, similarity: Float)] = cache.map { entry in
            (entry.speakerId, MathUtil.cosineSimilarity(centroid, entry.embedding))
        }
        scored.sort { $0.similarity > $1.similarity }
        let topNeighbors = Array(scored.prefix(config.neighborCount))
        let qualified = topNeighbors.filter { $0.similarity >= config.threshold }
        guard !qualified.isEmpty else { return .newSpeaker }

        var weighted: [String: Float] = [:]
        for entry in qualified { weighted[entry.speakerId, default: 0] += entry.similarity }
        guard let winner = weighted.max(by: { $0.value < $1.value }) else { return .newSpeaker }

        let voteCount = qualified.filter { $0.speakerId == winner.key }.count
        let minVotes = max(1, Int(Float(config.neighborCount) * config.minVotesRatio))
        guard voteCount >= minVotes else { return .newSpeaker }

        let bestSimilarity = qualified.first { $0.speakerId == winner.key }?.similarity ?? config.threshold
        return .match(speakerId: winner.key, similarity: bestSimilarity)
    }
}
