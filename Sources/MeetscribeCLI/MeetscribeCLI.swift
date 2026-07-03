import ArgumentParser
import Foundation
import MeetscribeCore

@main
struct MeetscribeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meetscribe",
        abstract: "Bot-free, on-device meeting transcription for macOS.",
        version: MeetscribeVersion.version,
        subcommands: [
            InitCommand.self,
            ConfigCommand.self,
            ModelsCommand.self,
            RecordCommand.self,
            SessionsCommand.self,
            TranscribeCommand.self,
            ExportCommand.self,
            SpeakersCommand.self,
            SearchCommand.self,
            WatchCommand.self,
            PermissionsCommand.self,
            DoctorCommand.self,
        ]
    )
}

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create config directories and download on-device models."
    )

    @Flag(name: .long, help: "Skip downloading FluidAudio model weights.")
    var skipModels: Bool = false

    func run() async throws {
        try MeetscribePaths.ensureConfigDirectory()
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        try config.save()
        let store = SessionStore()
        try FileManager.default.createDirectory(at: store.sessionsRoot, withIntermediateDirectories: true)
        _ = try SpeakerStore()
        try FileManager.default.createDirectory(at: MeetscribePaths.voiceProfilesDirectory, withIntermediateDirectories: true)
        print("Initialized at \(MeetscribePaths.configDirectory.path)")

        if skipModels {
            print("Skipped model download. Run `meetscribe models download` before your first recording.")
        } else {
            try await ModelBootstrap.ensureModels(config: config)
        }

        await PermissionsChecker.requestMissingPermissions()
        let permissions = PermissionsChecker.check()
        if permissions.recordingReady {
            print("Permissions: ready to record.")
        } else {
            print("Permissions: finish granting access before your first recording (meetscribe will prompt again on record start).")
        }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage configuration.",
        subcommands: [
            ConfigShowCommand.self,
            ConfigSetSessionsDirCommand.self,
            ConfigSetLanguageCommand.self,
            ConfigSetThresholdCommand.self,
            ConfigSetAutoRecordCommand.self,
            ConfigSetDeleteAudioCommand.self,
            ConfigSetUseCalendarCommand.self,
            ConfigSetGcalcliPathCommand.self,
            ConfigSetGcalcliCalendarCommand.self,
            ConfigSetKeepReviewSnippetsCommand.self,
        ]
    )
}

struct ConfigSetAutoRecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-auto-record",
        abstract: "Enable/disable lightweight call watcher (default: false)."
    )

    @Argument(help: "true or false") var enabled: String

    func run() throws {
        guard let value = Bool(enabled) else {
            throw ValidationError("Use true or false")
        }
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.autoRecordEnabled = value
        try config.save()
        print("Auto-record enabled: \(value). Run `meetscribe watch start` to activate.")
    }
}

struct ConfigSetDeleteAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-delete-audio",
        abstract: "Delete meeting.wav after analysis (default: true). Embeddings are always kept."
    )

    @Argument(help: "true or false") var enabled: String

    func run() throws {
        guard let value = Bool(enabled) else {
            throw ValidationError("Use true or false")
        }
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.deleteAudioAfterAnalysis = value
        try config.save()
        print("Delete audio after analysis: \(value)")
    }
}

struct ConfigShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show configuration.")

    func run() throws {
        let config = try MeetscribeConfig.load()
        print("Config: \(MeetscribePaths.configFile.path)")
        print("Sessions: \(config.sessionsDirectory)")
        print("Speakers DB: \(MeetscribePaths.speakerDatabaseURL.path)")
        print("Language: \(config.defaultLanguage.rawValue)")
        print("Similarity threshold: \(config.similarityThreshold)")
        print("Auto-process on stop: \(config.autoProcessOnStop)")
        print("Auto-record enabled: \(config.autoRecordEnabled) (poll: \(config.autoRecordPollSeconds)s)")
        print("Delete audio after analysis: \(config.deleteAudioAfterAnalysis)")
        print("Level meter: \(config.showLevelMeter)")
        print("Use calendar (gcalcli): \(config.useCalendar)")
        print("gcalcli path: \(config.gcalcliPath)")
        if let calendar = config.gcalcliCalendar {
            print("gcalcli calendar: \(calendar)")
        }
        print("Keep review snippets: \(config.keepReviewSnippets)")
        print("Voice profiles: \(MeetscribePaths.voiceProfilesDirectory.path)")
    }
}

struct ConfigSetUseCalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-use-calendar",
        abstract: "Use gcalcli for Google Calendar title + attendees at record start (default: true)."
    )

    @Argument(help: "true or false") var enabled: String

    func run() throws {
        guard let value = Bool(enabled) else {
            throw ValidationError("Use true or false")
        }
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.useCalendar = value
        try config.save()
        print("Use calendar: \(value)")
    }
}

struct ConfigSetKeepReviewSnippetsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-keep-review-snippets",
        abstract: "Save short voice samples for unlabeled speakers until review (default: true)."
    )

    @Argument(help: "true or false") var enabled: String

    func run() throws {
        guard let value = Bool(enabled) else {
            throw ValidationError("Use true or false")
        }
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.keepReviewSnippets = value
        try config.save()
        print("Keep review snippets: \(value)")
    }
}

struct ConfigSetGcalcliPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-gcalcli-path",
        abstract: "Path to gcalcli binary (default: gcalcli on PATH)."
    )

    @Argument var path: String

    func run() throws {
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.gcalcliPath = path
        try config.save()
        print("gcalcli path: \(path)")
    }
}

struct ConfigSetGcalcliCalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-gcalcli-calendar",
        abstract: "gcalcli calendar name or email (optional)."
    )

    @Argument var calendar: String

    func run() throws {
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.gcalcliCalendar = calendar.isEmpty ? nil : calendar
        try config.save()
        print("gcalcli calendar: \(config.gcalcliCalendar ?? "(default)")")
    }
}

struct ConfigSetSessionsDirCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-sessions-dir", abstract: "Set sessions directory.")

    @Argument var path: String

    func run() throws {
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.sessionsDirectory = NSString(string: path).expandingTildeInPath
        try config.save()
        print("Sessions: \(config.sessionsDirectory)")
    }
}

struct ConfigSetLanguageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-language", abstract: "Set default language: auto, en, de.")

    @Argument var language: String

    func run() throws {
        guard let code = MeetscribeConfig.LanguageCode(rawValue: language) else {
            throw ValidationError("Invalid language. Use auto, en, or de.")
        }
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.defaultLanguage = code
        try config.save()
        print("Language: \(code.rawValue)")
    }
}

struct ConfigSetThresholdCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-threshold", abstract: "Set speaker match threshold (0.0-1.0).")

    @Argument var threshold: Float

    func run() throws {
        var config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        config.similarityThreshold = threshold
        try config.save()
        print("Threshold: \(threshold)")
    }
}

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Manage on-device FluidAudio models.",
        subcommands: [ModelsDownloadCommand.self, ModelsStatusCommand.self]
    )
}

struct ModelsDownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download Core ML model weights to this Mac (not your audio)."
    )

    func run() async throws {
        try await ModelBootstrap.ensureModels()
        print("Models ready.")
    }
}

struct ModelsStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show on-device model status.")

    func run() throws {
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        let status = ModelAvailability.statusSummary(language: config.defaultLanguage)
        print("ASR models: \(status.asr ? "installed" : "missing")")
        print("Diarizer models: \(status.diarizer ? "installed" : "missing")")
        if status.asr && status.diarizer {
            print("All models ready.")
        } else {
            print("Run `meetscribe models download` or `meetscribe init`.")
        }
    }
}

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record meetings (stereo mic+system) and auto-process on stop.",
        subcommands: [RecordStartCommand.self, RecordStopCommand.self, RecordStatusCommand.self, RecordWorkerCommand.self]
    )
}

struct RecordStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start recording.")

    @Option(name: .long) var title: String = "Untitled meeting"
    @Option(name: .long) var attendees: String = ""
    @Flag(name: .long) var background: Bool = false
    @Flag(name: .long) var noAutoProcess: Bool = false
    @Flag(name: .long, help: "Do not read Google Calendar via gcalcli for title/attendees.")
    var noCalendar: Bool = false

    func run() async throws {
        let autoProcess = noAutoProcess ? false : nil
        let attendeeList = attendees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let session = try await RecordingService.shared.start(
            title: title,
            attendees: attendeeList,
            background: background,
            autoProcessOnStop: autoProcess,
            useCalendar: noCalendar ? false : nil
        )

        if background {
            print("Recording \(session.id) in background. Stop with: meetscribe record stop")
        } else {
            print("Processed session \(session.id)")
        }
    }
}

struct RecordStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop recording and process.")

    func run() async throws {
        let session = try await RecordingService.shared.stop()
        print("Session \(session.id) status=\(session.status.rawValue)")
    }
}

struct RecordStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show active recording.")

    func run() throws {
        guard let session = try RecordingService.shared.status() else {
            print("No active recording.")
            return
        }
        print("Recording \(session.id): \(session.title)")
    }
}

struct RecordWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "worker", abstract: "Internal background worker.")

    @Argument var sessionId: String

    func run() async throws {
        try await RecordingService.shared.runWorker(sessionId: sessionId)
    }
}

struct SessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List sessions.",
        subcommands: [SessionsListCommand.self]
    )
}

struct SessionsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all sessions.")

    func run() throws {
        let sessions = try SessionStore().listSessions()
        if sessions.isEmpty {
            print("No sessions.")
            return
        }
        for session in sessions {
            print("\(session.id)  \(session.status.rawValue)  \(session.title)")
        }
    }
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Process a session or audio file on-device."
    )

    @Option(name: .long) var session: String?
    @Option(name: .long, help: "Transcribe an existing audio file into a new session.") var file: String?

    func run() async throws {
        let config = try MeetscribeConfig.load()
        let pipeline = try MeetingPipeline()
        let store = SessionStore()

        if let filePath = file {
            let url = URL(fileURLWithPath: NSString(string: filePath).expandingTildeInPath)
            let imported = try await pipeline.processFile(
                audioURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                config: config
            )
            print("Transcribed imported session \(imported.id)")
            return
        }

        let sessionId = try session ?? latestRecordedSessionID(store: store)
        let updated = try await pipeline.processSession(sessionId: sessionId, config: config)
        print("Transcribed session \(updated.id)")
    }
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export notes.md for a session.")

    @Option(name: .long) var session: String?

    func run() throws {
        let store = SessionStore()
        let sessionId = try session ?? latestTranscribedSessionID(store: store)
        let url = try TranscriptionService().exportMarkdown(sessionId: sessionId, sessionStore: store)
        print("Exported to \(url.path)")
    }
}

struct SpeakersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "Manage recognized voices.",
        subcommands: [
            SpeakersListCommand.self,
            SpeakersLabelCommand.self,
            SpeakersMergeCommand.self,
            SpeakersReviewCommand.self,
        ]
    )
}

struct SpeakersListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List known speakers.")

    func run() throws {
        let store = try SpeakerStore()
        let speakers = try store.allSpeakers()
        if speakers.isEmpty {
            print("No speakers yet.")
            return
        }
        for speaker in speakers {
            let name = speaker.label ?? "(unnamed)"
            print("\(speaker.id)  \(name)")
        }
    }
}

struct SpeakersLabelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "label", abstract: "Label a speaker globally.")

    @Argument var speakerId: String
    @Argument var name: String

    func run() throws {
        let store = try SpeakerStore()
        try store.updateLabel(id: speakerId, label: name)
        print("Labeled \(speakerId) as \(name)")
    }
}

struct SpeakersMergeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "merge", abstract: "Merge duplicate speakers.")

    @Argument var fromSpeakerId: String
    @Argument var intoSpeakerId: String

    func run() throws {
        let store = try SpeakerStore()
        try store.mergeSpeakers(from: fromSpeakerId, into: intoSpeakerId)
        print("Merged \(fromSpeakerId) into \(intoSpeakerId)")
    }
}

struct SpeakersReviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Interactively label unlabeled voices saved from past sessions."
    )

    @Option(name: .long, help: "Review speakers from one session only.") var session: String?
    @Flag(name: .long, help: "Delete all pending review snippets without labeling.")
    var purge: Bool = false

    func run() throws {
        if purge {
            let count = try ReviewSnippetStore.purgeAllPending()
            print("Purged review snippets for \(count) speaker(s).")
            return
        }

        let sessionStore = SessionStore()
        let candidates: [SpeakerReviewCandidate]
        if let sessionId = session {
            candidates = try SpeakerReviewService.pendingCandidates(forSession: sessionId, sessionStore: sessionStore)
        } else {
            candidates = try SpeakerReviewService.pendingCandidates(sessionStore: sessionStore)
        }

        if candidates.isEmpty {
            print("No speakers awaiting review.")
            return
        }

        print("\(candidates.count) speaker(s) to review. Commands: number = calendar pick, name = label, r = replay, s = skip, q = quit\n")

        for candidate in candidates {
            let sessionCount = candidate.sessionIds.count
            print("Speaker \(candidate.speakerId) — heard in \(sessionCount) session(s) (latest: \"\(candidate.latestSessionTitle)\")")
            print("Said: \"\(candidate.excerpt)\"")
            print("Playing sample…")
            try SpeakerReviewService.playSample(at: candidate.sampleURL)

            while true {
                print("")
                if candidate.calendarSuggestions.isEmpty {
                    print("Who is this? [type a name]  [r] replay  [s] skip  [q] quit")
                } else {
                    for (index, name) in candidate.calendarSuggestions.enumerated() {
                        print("  [\(index + 1)] \(name)  (from Google Calendar)")
                    }
                    print("  [n] type a name  [r] replay  [s] skip  [q] quit")
                }

                guard let input = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !input.isEmpty else {
                    continue
                }

                let lowered = input.lowercased()
                if lowered == "q" || lowered == "quit" {
                    print("Review paused.")
                    return
                }
                if lowered == "s" || lowered == "skip" {
                    print("Skipped \(candidate.speakerId).")
                    break
                }
                if lowered == "r" || lowered == "replay" {
                    try SpeakerReviewService.playSample(at: candidate.sampleURL)
                    continue
                }

                let chosenName: String?
                if let number = Int(input), number >= 1, number <= candidate.calendarSuggestions.count {
                    chosenName = candidate.calendarSuggestions[number - 1]
                } else if lowered == "n" {
                    print("Name:")
                    guard let typed = readLine(strippingNewline: true)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !typed.isEmpty else {
                        print("Empty name — try again.")
                        continue
                    }
                    chosenName = typed
                } else {
                    chosenName = input
                }

                guard let label = chosenName else { continue }

                let updatedSessions = try SpeakerReviewService.applyLabel(
                    speakerId: candidate.speakerId,
                    displayName: label,
                    sessionStore: sessionStore
                )
                print("Labeled \(candidate.speakerId) as \(label). Updated \(updatedSessions) session transcript(s). Snippets deleted.")
                break
            }
        }

        print("Review complete.")
    }
}

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Full-text search across transcripts.")

    @Argument var query: String

    func run() throws {
        let store = try SpeakerStore()
        let hits = try store.search(query)
        if hits.isEmpty {
            print("No matches.")
            return
        }
        for hit in hits {
            print("[\(hit.sessionId)] \(hit.speakerId): \(hit.snippet)")
        }
    }
}

struct WatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Lightweight call detector — polls CoreAudio only, no ML until a call starts.",
        subcommands: [WatchStartCommand.self, WatchStopCommand.self, WatchStatusCommand.self]
    )
}

struct WatchStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start watching for calls (blocks; Ctrl+C to stop)."
    )

    func run() async throws {
        if let existing = try WatchService.loadState() {
            throw ValidationError("Watch already running (pid \(existing.pid)). Stop with: meetscribe watch stop")
        }

        try await PermissionsChecker.ensureRecordingPermissions()

        var config = try MeetscribeConfig.load()
        config.autoRecordEnabled = true
        try config.save()

        try WatchService.saveState(pid: ProcessInfo.processInfo.processIdentifier)

        signal(SIGINT) { _ in
            AutoRecordWatcher.shared.stop()
            try? WatchService.clearState()
        }
        signal(SIGTERM) { _ in
            AutoRecordWatcher.shared.stop()
            try? WatchService.clearState()
        }

        AutoRecordWatcher.shared.start(config: config)
        FileHandle.standardError.write(Data("[meetscribe watch] running — polls CoreAudio only, no models loaded\n".utf8))
        defer {
            AutoRecordWatcher.shared.stop()
            try? WatchService.clearState()
        }
        while AutoRecordWatcher.shared.isRunning {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

struct WatchStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the call watcher.")

    func run() throws {
        try WatchService.stopRemoteWatcher()
        print("Watch stopped.")
    }
}

struct WatchStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show watch state.")

    func run() throws {
        let config = try MeetscribeConfig.load()
        let running = WatchService.isRunning()
        print("Watch running: \(running)")
        print("Auto-record enabled in config: \(config.autoRecordEnabled)")
        print("Poll interval: \(config.autoRecordPollSeconds)s")
        if let state = try WatchService.loadState() {
            print("Watch pid: \(state.pid)")
        }
    }
}

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Request and check macOS permissions for recording."
    )

    @Flag(name: .long, help: "Check status only — do not show prompts or open System Settings.")
    var checkOnly: Bool = false

    func run() async throws {
        if checkOnly {
            printStatus(PermissionsChecker.check())
            return
        }

        try await PermissionsChecker.ensureRecordingPermissions()
        printStatus(PermissionsChecker.check())
        print("All recording permissions granted.")
    }

    private func printStatus(_ status: PermissionStatus) {
        let host = PermissionsChecker.hostAppName()
        print("Host app: \(host)")
        print("Accessibility: \(status.accessibility ? "granted" : "missing")")
        printPermission(
            name: "Microphone",
            granted: status.microphone,
            deniedHint: "denied — enable \(host) in System Settings → Privacy & Security → Microphone"
        )
        print("Screen Recording: \(status.screenRecording ? "granted" : "missing — enable \(host) in Privacy & Security → Screen Recording")")
        print("gcalcli: \(status.gcalcliInstalled ? "installed" : "missing — brew install gcalcli (optional)")")
        print("Google Calendar (gcalcli): \(status.gcalcliAuthenticated ? "ready" : "optional — run: gcalcli init")")
    }

    private func printPermission(name: String, granted: Bool, deniedHint: String) {
        if granted {
            print("\(name): granted")
            return
        }
        if name == "Microphone",
           PermissionsChecker.microphoneAuthorizationStatus() == .denied
            || PermissionsChecker.microphoneAuthorizationStatus() == .restricted {
            print("\(name): \(deniedHint)")
            return
        }
        print("\(name): missing")
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check install, models, and permissions.")

    func run() throws {
        let report = DoctorService.run()
        for check in report.checks {
            let mark = check.ok ? "ok" : "FAIL"
            print("[\(mark)] \(check.name): \(check.detail)")
        }
        if !report.ok {
            throw ExitCode.failure
        }
    }
}

private func latestRecordedSessionID(store: SessionStore) throws -> String {
    let sessions = try store.listSessions()
    guard let session = sessions.first(where: { $0.status == .recorded || $0.status == .transcribed }) else {
        throw ValidationError("No recorded sessions found.")
    }
    return session.id
}

private func latestTranscribedSessionID(store: SessionStore) throws -> String {
    let sessions = try store.listSessions()
    guard let session = sessions.first(where: { $0.status == .transcribed }) else {
        throw ValidationError("No transcribed sessions found.")
    }
    return session.id
}
