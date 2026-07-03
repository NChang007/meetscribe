import Foundation

public struct DoctorReport: Sendable {
    public struct Check: Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String
    }

    public let checks: [Check]

    public var ok: Bool { checks.allSatisfy(\.ok) }
}

public enum DoctorService {
    public static func run() -> DoctorReport {
        var checks: [DoctorReport.Check] = []

        let configExists = FileManager.default.fileExists(atPath: MeetscribePaths.configFile.path)
        checks.append(.init(
            name: "Config",
            ok: configExists,
            detail: configExists ? MeetscribePaths.configFile.path : "Run `meetscribe init`"
        ))

        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        let modelStatus = ModelAvailability.statusSummary(language: config.defaultLanguage)
        checks.append(.init(
            name: "ASR models",
            ok: modelStatus.asr,
            detail: modelStatus.asr ? "Installed" : "Run `meetscribe models download`"
        ))
        checks.append(.init(
            name: "Diarizer models",
            ok: modelStatus.diarizer,
            detail: modelStatus.diarizer ? "Installed" : "Run `meetscribe models download`"
        ))

        let permissions = PermissionsChecker.check()
        checks.append(.init(
            name: "Accessibility",
            ok: permissions.accessibility,
            detail: permissions.accessibility ? "Granted" : "Run `meetscribe permissions` or `record start` to prompt"
        ))
        checks.append(.init(
            name: "Microphone",
            ok: permissions.microphone,
            detail: permissions.microphone ? "Granted" : "Run `meetscribe permissions` or `record start` to prompt"
        ))
        checks.append(.init(
            name: "Screen Recording",
            ok: permissions.screenRecording,
            detail: permissions.screenRecording ? "Granted" : "Required for system audio — prompted on record start"
        ))
        checks.append(.init(
            name: "gcalcli",
            ok: permissions.gcalcliInstalled,
            detail: permissions.gcalcliInstalled ? "Installed" : "Missing — brew install gcalcli"
        ))
        checks.append(.init(
            name: "Google Calendar (gcalcli)",
            ok: !config.useCalendar || permissions.gcalcliAuthenticated,
            detail: permissions.gcalcliAuthenticated
                ? "Authenticated"
                : (permissions.gcalcliInstalled ? "Run: gcalcli init" : "Install gcalcli + run gcalcli init")
        ))

        let pendingReview = ReviewSnippetStore.pendingSpeakerIds().count
        checks.append(.init(
            name: "Speaker review",
            ok: pendingReview == 0,
            detail: pendingReview == 0 ? "No pending voices" : "\(pendingReview) unlabeled speaker(s) — run `meetscribe speakers review`"
        ))

        let sessionStore = SessionStore()
        try? sessionStore.reconcileActiveRecordingLock()

        if let staleState = RecordingService.shared.staleRecordingState() {
            checks.append(.init(
                name: "Recording lock",
                ok: false,
                detail: "Stale lock for session \(staleState.sessionId) — run `meetscribe record stop` or delete .recording-state.json"
            ))
        } else {
            checks.append(.init(name: "Recording lock", ok: true, detail: "Clear"))
        }

        if WatchService.isRunning() {
            checks.append(.init(name: "Call watcher", ok: true, detail: "Running"))
        } else {
            checks.append(.init(name: "Call watcher", ok: true, detail: "Stopped"))
        }

        return DoctorReport(checks: checks)
    }
}
