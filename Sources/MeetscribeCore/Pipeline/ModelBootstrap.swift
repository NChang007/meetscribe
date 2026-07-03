import Foundation

public enum ModelBootstrap {
    /// Downloads FluidAudio Core ML weights if missing. Safe to call from install/init.
    public static func ensureModels(config: MeetscribeConfig? = nil) async throws {
        var loadedConfig = config ?? (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        try MeetscribePaths.ensureConfigDirectory()
        loadedConfig.allowModelDownload = true
        try loadedConfig.save()

        FileHandle.standardError.write(
            Data("[meetscribe] Downloading on-device models (open weights only, not your audio)…\n".utf8)
        )
        try await MeetingPipeline.prepareModels(config: loadedConfig)

        loadedConfig.allowModelDownload = false
        try loadedConfig.save()
        FileHandle.standardError.write(Data("[meetscribe] Models ready.\n".utf8))
    }
}
