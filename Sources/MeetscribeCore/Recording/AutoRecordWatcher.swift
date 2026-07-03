import Foundation

/// Ultra-light call detector. Polls CoreAudio every N seconds — no ML, no capture until a call starts.
public final class AutoRecordWatcher: @unchecked Sendable {
    public static let shared = AutoRecordWatcher()

    private var pollTask: Task<Void, Never>?
    private var isRecording = false
    private var idlePollCount = 0

    private init() {}

    public var isRunning: Bool { pollTask != nil }

    public func start(config: MeetscribeConfig) {
        guard pollTask == nil else { return }

        let pollNanoseconds = UInt64(max(config.autoRecordPollSeconds, 2.0) * 1_000_000_000)
        pollTask = Task {
            FileHandle.standardError.write(Data("[meetscribe watch] idle — polling every \(config.autoRecordPollSeconds)s\n".utf8))
            while !Task.isCancelled {
                await pollOnce(config: config)
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRecording = false
        FileHandle.standardError.write(Data("[meetscribe watch] stopped\n".utf8))
    }

    private func pollOnce(config: MeetscribeConfig) async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var excludedPIDs: Set<pid_t> = [ownPID]
        if let recordingPID = RecordingService.activeRecordingPID() {
            excludedPIDs.insert(recordingPID)
        }

        let foreignCount = MicUsageMonitor.foreignMicInputCount(excludingPIDs: excludedPIDs)
        let micActive = foreignCount.map { $0 > 0 } ?? MicUsageMonitor.defaultInputIsRunningSomewhere()

        if micActive {
            idlePollCount = 0
            guard !isRecording else { return }
            isRecording = true
            FileHandle.standardError.write(Data("[meetscribe watch] call detected — recording\n".utf8))
            do {
                _ = try await RecordingService.shared.start(
                    title: "Auto-recorded call",
                    attendees: [],
                    background: true
                )
            } catch {
                FileHandle.standardError.write(Data("[meetscribe watch] start failed: \(error.localizedDescription)\n".utf8))
                isRecording = false
            }
            return
        }

        if isRecording {
            idlePollCount += 1
            if idlePollCount >= 2 {
                FileHandle.standardError.write(Data("[meetscribe watch] call ended — stopping\n".utf8))
                isRecording = false
                idlePollCount = 0
                do {
                    _ = try await RecordingService.shared.stop()
                } catch {
                    FileHandle.standardError.write(Data("[meetscribe watch] stop failed: \(error.localizedDescription)\n".utf8))
                }
            }
        }
    }
}
