import Foundation

public enum RecordingCoordinatorError: Error, LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
}

public final class RecordingCoordinator: @unchecked Sendable {
    private var micRecorder: MicrophoneRecorder?
    private var systemRecorder: SystemAudioRecorder?
    private var speakerWatcher: AccessibilitySpeakerWatcher?
    private var mixer: AudioMixer?

    public init() {}

    public func start(sessionStore: SessionStore, session: RecordingSession) async throws {
        let meetingURL = sessionStore.meetingAudioURL(for: session)
        let writer = try WAVWriter(url: meetingURL, sampleRate: 16000, channels: 2)
        let mixer = AudioMixer(
            writer: writer,
            enabled: [.mic, .system],
            stereo: true
        )
        self.mixer = mixer

        let micRecorder = MicrophoneRecorder { samples in
            AudioLevelMeter.shared.feed(samples, channel: .mic)
            mixer.append(samples, channel: .mic)
        }
        guard await micRecorder.requestPermission() else {
            throw RecordingCoordinatorError.microphonePermissionDenied
        }
        try micRecorder.start()
        self.micRecorder = micRecorder

        let systemRecorder = SystemAudioRecorder { samples in
            AudioLevelMeter.shared.feed(samples, channel: .system)
            mixer.append(samples, channel: .system)
        }
        try await systemRecorder.start()
        self.systemRecorder = systemRecorder

        let watcher = try AccessibilitySpeakerWatcher(outputURL: sessionStore.speakerEventsURL(for: session))
        try watcher.start()
        speakerWatcher = watcher
    }

    public func stop() async throws {
        micRecorder?.stop()
        micRecorder = nil

        await systemRecorder?.stop()
        systemRecorder = nil

        speakerWatcher?.stop()
        speakerWatcher = nil

        try mixer?.flushAndClose()
        mixer = nil
    }
}
