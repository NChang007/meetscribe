import Foundation
import FluidAudio

public struct TranscribedSegment: Sendable {
    public let startSec: Double
    public let endSec: Double
    public let localSpeakerId: String
    public let globalSpeakerId: String
    public let text: String
    public let confidence: Double
}

public protocol ProgressReporter: AnyObject {
    func step(_ message: String)
}

public final class ConsoleProgress: ProgressReporter {
    public init() {}
    public func step(_ message: String) {
        FileHandle.standardError.write(Data("[meetscribe] \(message)\n".utf8))
    }
}

public final class TranscriptionPipeline {
    private let manager: AsrManager
    private var loaded = false
    private weak var progress: ProgressReporter?

    public init(config: ASRConfig = .default, progress: ProgressReporter? = nil) {
        manager = AsrManager(config: config)
        self.progress = progress
    }

    public func prepareModels(language: MeetscribeConfig.LanguageCode, allowDownload: Bool = true) async throws {
        guard !loaded else { return }
        let version = ModelAvailability.asrVersion(for: language)
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)

        let models: AsrModels
        if allowDownload {
            models = try await AsrModels.downloadAndLoad(version: version)
        } else {
            guard ModelAvailability.asrModelsInstalled(language: language) else {
                throw ModelAvailabilityError.modelsMissing("ASR")
            }
            models = try await AsrModels.load(from: cacheDirectory, version: version)
        }

        try await manager.loadModels(models)
        loaded = true
    }

    public func transcribe(
        diarized: [LocalDiarizedSegment],
        samples: [Float],
        sampleRate: Int = 16000,
        localToGlobal: [String: String],
        language: MeetscribeConfig.LanguageCode
    ) async throws -> [TranscribedSegment] {
        var output: [TranscribedSegment] = []
        output.reserveCapacity(diarized.count)
        let total = diarized.count
        let asrLanguage: Language? = language == .de ? .german : (language == .en ? .english : nil)

        for (index, segment) in diarized.enumerated() {
            let startIndex = max(0, Int(segment.startSec * Double(sampleRate)))
            let endIndex = min(samples.count, Int(segment.endSec * Double(sampleRate)))
            guard endIndex > startIndex else { continue }
            let slice = Array(samples[startIndex..<endIndex])
            guard slice.count >= sampleRate / 5 else { continue }

            var decoder = try TdtDecoderState()
            let result = try await manager.transcribe(slice, decoderState: &decoder, language: asrLanguage)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let globalSpeakerId = localToGlobal[segment.localSpeakerId] ?? segment.localSpeakerId
            output.append(
                TranscribedSegment(
                    startSec: segment.startSec,
                    endSec: segment.endSec,
                    localSpeakerId: segment.localSpeakerId,
                    globalSpeakerId: globalSpeakerId,
                    text: trimmed,
                    confidence: Double(result.confidence)
                )
            )

            if (index + 1) == total || (index + 1) % max(1, total / 20) == 0 {
                progress?.step("Transcribing \(index + 1)/\(total)")
            }
        }
        return output
    }
}
