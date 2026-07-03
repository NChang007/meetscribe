import Foundation
import FluidAudio

public enum ModelAvailabilityError: Error, LocalizedError {
    case downloadDisabled
    case modelsMissing(String)

    public var errorDescription: String? {
        switch self {
        case .downloadDisabled:
            return "Model download is disabled. Run `meetscribe models download` or `meetscribe init` first."
        case .modelsMissing(let detail):
            return "On-device models are not installed (\(detail)). Run `meetscribe models download`."
        }
    }
}

public enum ModelAvailability {
    public static func asrVersion(for language: MeetscribeConfig.LanguageCode) -> AsrModelVersion {
        language == .en ? .v2 : .v3
    }

    public static func asrModelsInstalled(language: MeetscribeConfig.LanguageCode) -> Bool {
        let version = asrVersion(for: language)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    public static func diarizerModelsDirectory() -> URL {
        OfflineDiarizerModels.defaultModelsDirectory()
    }

    /// Best-effort check: diarizer cache directory exists with compiled model artifacts.
    public static func diarizerModelsInstalled() -> Bool {
        let baseDirectory = diarizerModelsDirectory()
        let segmentationName = ModelNames.OfflineDiarizer.segmentationPath
        let candidatePaths = [
            baseDirectory.appendingPathComponent(segmentationName),
            baseDirectory.appendingPathComponent("speaker-diarization/\(segmentationName)"),
            baseDirectory.appendingPathComponent("speaker-diarization-coreml/\(segmentationName)"),
            baseDirectory.appendingPathComponent("speaker-diarization-offline/\(segmentationName)"),
        ]
        return candidatePaths.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func statusSummary(language: MeetscribeConfig.LanguageCode) -> (asr: Bool, diarizer: Bool) {
        (asrModelsInstalled(language: language), diarizerModelsInstalled())
    }
}
