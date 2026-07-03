import Foundation

public enum RecordingServiceError: Error, LocalizedError {
    case alreadyRecording(String)
    case notRecording
}

public struct RecordingState: Codable, Sendable {
    public let pid: Int32
    public let sessionId: String
}

public final class RecordingService: @unchecked Sendable {
    public static let shared = RecordingService()

    private let sessionStore: SessionStore
    private var coordinator: RecordingCoordinator?
    private var activeSession: RecordingSession?
    private var shouldStop = false
    private var autoProcessOverride: Bool?
    private var useCalendarOverride: Bool?
    private var levelMeterTask: Task<Void, Never>?
    private let stateFile: URL

    public init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
        stateFile = sessionStore.sessionsRoot.appendingPathComponent(".recording-state.json")
    }

    public func start(
        title: String,
        attendees: [String],
        background: Bool,
        autoProcessOnStop: Bool? = nil,
        useCalendar: Bool? = nil
    ) async throws -> RecordingSession {
        autoProcessOverride = autoProcessOnStop
        useCalendarOverride = useCalendar
        if let state = try loadState() {
            throw RecordingServiceError.alreadyRecording(state.sessionId)
        }

        let session = try sessionStore.createSession(
            title: title,
            attendees: attendees,
            calendarEventId: nil
        )

        if background {
            let executable = ProcessInfo.processInfo.environment["MEETSCRIBE_EXECUTABLE"]
                ?? CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["record", "worker", session.id]
            var environment = ProcessInfo.processInfo.environment
            if let useCalendar {
                environment["MEETSCRIBE_USE_CALENDAR"] = useCalendar ? "1" : "0"
            }
            process.environment = environment
            try process.run()
            try saveState(RecordingState(pid: process.processIdentifier, sessionId: session.id))
            return session
        }

        try await runRecording(session: session)
        return try sessionStore.load(id: session.id)
    }

    public func runWorker(sessionId: String) async throws {
        let session = try sessionStore.load(id: sessionId)
        try saveState(RecordingState(pid: ProcessInfo.processInfo.processIdentifier, sessionId: session.id))
        try await runRecording(session: session)
    }

    public func stop() async throws -> RecordingSession {
        guard let state = try loadState() else {
            throw RecordingServiceError.notRecording
        }

        if state.pid == ProcessInfo.processInfo.processIdentifier {
            return try await finishActiveRecording(autoProcess: true)
        }

        kill(state.pid, SIGTERM)
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if (try? loadState()) == nil {
                return try sessionStore.load(id: state.sessionId)
            }
        }
        throw RecordingServiceError.notRecording
    }

    public func status() throws -> RecordingSession? {
        guard let state = try loadState() else { return nil }
        return try sessionStore.load(id: state.sessionId)
    }

    /// Returns stale lock info when a pid file exists but the worker is dead.
    public func staleRecordingState() -> RecordingState? {
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let state = try? JSONDecoder().decode(RecordingState.self, from: Data(contentsOf: stateFile)) else {
            return nil
        }
        if state.pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        if kill(state.pid, 0) == 0 {
            return nil
        }
        return state
    }

    public static func activeRecordingPID() -> pid_t? {
        let store = SessionStore()
        let stateFile = store.sessionsRoot.appendingPathComponent(".recording-state.json")
        guard FileManager.default.fileExists(atPath: stateFile.path),
              let state = try? JSONDecoder().decode(RecordingState.self, from: Data(contentsOf: stateFile)),
              kill(state.pid, 0) == 0 else {
            return nil
        }
        return state.pid
    }

    private func runRecording(session: RecordingSession) async throws {
        activeSession = session
        shouldStop = false

        let config = try MeetscribeConfig.load()
        let useCalendar = Self.resolveUseCalendar(config: config, override: useCalendarOverride)
        SessionMetadataResolver.enrichSessionIfNeeded(
            sessionId: session.id,
            sessionStore: sessionStore,
            useCalendar: useCalendar
        )
        useCalendarOverride = nil
        if config.showLevelMeter {
            levelMeterTask = Task {
                while !Task.isCancelled && !shouldStop {
                    let line = "\r" + AudioLevelMeter.shared.renderBars()
                    FileHandle.standardError.write(Data(line.utf8))
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }

        let coordinator = RecordingCoordinator()
        self.coordinator = coordinator
        try await coordinator.start(sessionStore: sessionStore, session: session)
        installStopHandlers()

        while !shouldStop {
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        _ = try await finishActiveRecording(autoProcess: true)
    }

    private func finishActiveRecording(autoProcess: Bool) async throws -> RecordingSession {
        levelMeterTask?.cancel()
        levelMeterTask = nil
        try await coordinator?.stop()
        coordinator = nil

        guard var session = activeSession else {
            throw RecordingServiceError.notRecording
        }

        session = try sessionStore.finishSession(id: session.id)
        activeSession = nil
        try clearState()

        let shouldProcess: Bool
        if let override = autoProcessOverride {
            shouldProcess = override
        } else {
            let config = try MeetscribeConfig.load()
            shouldProcess = config.autoProcessOnStop
        }
        autoProcessOverride = nil

        if autoProcess && shouldProcess {
            let config = try MeetscribeConfig.load()
            do {
                let pipeline = try MeetingPipeline(sessionStore: sessionStore)
                session = try await pipeline.processSession(sessionId: session.id, config: config)
            } catch {
                session = try sessionStore.load(id: session.id)
                throw error
            }
        }

        return session
    }

    private func installStopHandlers() {
        signal(SIGINT) { _ in RecordingService.shared.shouldStop = true }
        signal(SIGTERM) { _ in RecordingService.shared.shouldStop = true }
    }

    private func saveState(_ state: RecordingState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFile, options: .atomic)
    }

    private func loadState() throws -> RecordingState? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        let state = try JSONDecoder().decode(RecordingState.self, from: Data(contentsOf: stateFile))
        if state.pid != ProcessInfo.processInfo.processIdentifier, kill(state.pid, 0) != 0 {
            try clearState()
            return nil
        }
        return state
    }

    private func clearState() throws {
        if FileManager.default.fileExists(atPath: stateFile.path) {
            try FileManager.default.removeItem(at: stateFile)
        }
    }

    private static func resolveUseCalendar(config: MeetscribeConfig, override: Bool?) -> Bool {
        if let override {
            return override
        }
        if let env = ProcessInfo.processInfo.environment["MEETSCRIBE_USE_CALENDAR"] {
            return env == "1"
        }
        return config.useCalendar
    }
}
