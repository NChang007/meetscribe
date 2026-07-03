import Foundation
import FluidAudio

public struct LocalDiarizedSegment: Sendable {
    public let localSpeakerId: String
    public let startSec: Double
    public let endSec: Double
    public let qualityScore: Float
    public let embedding: [Float]
}

public struct DiarizationOutput: Sendable {
    public let segments: [LocalDiarizedSegment]
    public let speakerCentroids: [String: [Float]]

    public static func merged(
        mic: DiarizationOutput,
        system: DiarizationOutput,
        micPrefix: String,
        systemPrefix: String
    ) -> DiarizationOutput {
        let micSegments = mic.segments.map { segment in
            LocalDiarizedSegment(
                localSpeakerId: "\(micPrefix)-\(segment.localSpeakerId)",
                startSec: segment.startSec,
                endSec: segment.endSec,
                qualityScore: segment.qualityScore,
                embedding: segment.embedding
            )
        }
        let systemSegments = system.segments.map { segment in
            LocalDiarizedSegment(
                localSpeakerId: "\(systemPrefix)-\(segment.localSpeakerId)",
                startSec: segment.startSec,
                endSec: segment.endSec,
                qualityScore: segment.qualityScore,
                embedding: segment.embedding
            )
        }
        let allSegments = (micSegments + systemSegments).sorted { $0.startSec < $1.startSec }

        var centroids: [String: [Float]] = [:]
        for (identifier, embedding) in mic.speakerCentroids {
            centroids["\(micPrefix)-\(identifier)"] = embedding
        }
        for (identifier, embedding) in system.speakerCentroids {
            centroids["\(systemPrefix)-\(identifier)"] = embedding
        }
        return DiarizationOutput(segments: allSegments, speakerCentroids: centroids)
    }
}

public final class DiarizationPipeline {
    private let manager: OfflineDiarizerManager

    public init(config: OfflineDiarizerConfig = .default) {
        manager = OfflineDiarizerManager(config: config)
    }

    public func prepareModels(allowDownload: Bool = true) async throws {
        if allowDownload {
            try await manager.prepareModels()
            return
        }
        guard ModelAvailability.diarizerModelsInstalled() else {
            throw ModelAvailabilityError.modelsMissing("diarizer")
        }
        let loadedModels = try await OfflineDiarizerModels.load(
            from: ModelAvailability.diarizerModelsDirectory()
        )
        manager.initialize(models: loadedModels)
    }

    public func diarize(samples: [Float]) async throws -> DiarizationOutput {
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return DiarizationOutput(segments: [], speakerCentroids: [:])
        }

        let segments = result.segments.map { segment in
            LocalDiarizedSegment(
                localSpeakerId: segment.speakerId,
                startSec: Double(segment.startTimeSeconds),
                endSec: Double(segment.endTimeSeconds),
                qualityScore: segment.qualityScore,
                embedding: segment.embedding
            )
        }

        let centroids: [String: [Float]]
        if let database = result.speakerDatabase, !database.isEmpty {
            centroids = database
        } else {
            var grouped: [String: [[Float]]] = [:]
            for segment in segments where !segment.embedding.isEmpty {
                grouped[segment.localSpeakerId, default: []].append(segment.embedding)
            }
            centroids = grouped.compactMapValues { MathUtil.mean(of: $0) }
        }

        return DiarizationOutput(segments: segments, speakerCentroids: centroids)
    }
}
