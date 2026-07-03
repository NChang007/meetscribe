import Foundation

public enum SessionStoreError: Error, LocalizedError {
    case sessionNotFound(String)
    case sessionAlreadyRecording(String)
    case noActiveRecording

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .sessionAlreadyRecording(let id):
            return "Session \(id) is already recording"
        case .noActiveRecording:
            return "No active recording session"
        }
    }
}

public final class SessionStore: @unchecked Sendable {
    public let sessionsRoot: URL
    private let activeRecordingFile: URL
    private let lock = NSLock()

    public init(sessionsRoot: URL? = nil) {
        if let sessionsRoot {
            self.sessionsRoot = sessionsRoot
        } else if let envPath = ProcessInfo.processInfo.environment["MEETSCRIBE_SESSIONS_DIR"] {
            self.sessionsRoot = URL(fileURLWithPath: envPath, isDirectory: true)
        } else if let config = try? MeetscribeConfig.load(),
                  !config.sessionsDirectory.isEmpty {
            self.sessionsRoot = URL(fileURLWithPath: config.sessionsDirectory, isDirectory: true)
        } else {
            self.sessionsRoot = MeetscribePaths.defaultSessionsDirectory
        }
        self.activeRecordingFile = self.sessionsRoot.appendingPathComponent(".active-recording")
    }

    public func directory(for session: RecordingSession) -> URL {
        sessionsRoot.appendingPathComponent(session.id, isDirectory: true)
    }

    public func micAudioURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("mic.wav")
    }

    public func systemAudioURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("system.wav")
    }

    public func meetingAudioURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("meeting.wav")
    }

    public func speakerEventsURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("speaker-events.jsonl")
    }

    public func transcriptURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("transcript.json")
    }

    public func resolvedTranscriptURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("transcript-resolved.json")
    }

    public func markdownURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("notes.md")
    }

    public func metadataURL(for session: RecordingSession) -> URL {
        directory(for: session).appendingPathComponent("session.json")
    }

    public func importSession(title: String, attendees: [String] = []) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let session = RecordingSession(title: title, attendees: attendees, status: .recorded)
        try FileManager.default.createDirectory(at: directory(for: session), withIntermediateDirectories: true)
        try save(session)
        return session
    }

    public func createSession(
        title: String,
        attendees: [String],
        calendarEventId: String? = nil
    ) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try reconcileActiveRecordingLock()

        if let activeId = try activeRecordingID() {
            throw SessionStoreError.sessionAlreadyRecording(activeId)
        }

        let session = RecordingSession(
            title: title,
            attendees: attendees,
            calendarEventId: calendarEventId
        )
        try FileManager.default.createDirectory(at: directory(for: session), withIntermediateDirectories: true)
        try save(session)
        try setActiveRecording(session.id)
        return session
    }

    public func finishSession(id: String) throws -> RecordingSession {
        var session = try load(id: id)
        session.endedAt = Date()
        session.status = .recorded
        try save(session)
        try clearActiveRecording()
        return session
    }

    public func markFailed(id: String) throws {
        var session = try load(id: id)
        session.status = .failed
        try save(session)
    }

    /// Clears a stale `.active-recording` lock after a failed or interrupted start.
    public func abortRecordingSession(id: String) throws {
        if try activeRecordingID() == id {
            try clearActiveRecording()
        }
        if (try? load(id: id)) != nil {
            try markFailed(id: id)
        }
    }

    /// Drops `.active-recording` when no live recording worker owns the session.
    public func reconcileActiveRecordingLock() throws {
        guard let activeId = try activeRecordingID() else { return }

        let stateFile = sessionsRoot.appendingPathComponent(".recording-state.json")
        if FileManager.default.fileExists(atPath: stateFile.path),
           let data = try? Data(contentsOf: stateFile),
           let state = try? JSONDecoder().decode(RecordingState.self, from: data),
           state.sessionId == activeId,
           kill(state.pid, 0) == 0 {
            return
        }

        try clearActiveRecording()
        if var session = try? load(id: activeId), session.status == .recording {
            session.status = .failed
            session.endedAt = Date()
            try save(session)
        }
    }

    public func activeRecordingID() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: activeRecordingFile.path) else {
            return nil
        }
        return try String(contentsOf: activeRecordingFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func load(id: String) throws -> RecordingSession {
        let metadataURL = metadataURL(for: RecordingSession(id: id, title: ""))
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode(RecordingSession.self, from: data)
    }

    public func save(_ session: RecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: metadataURL(for: session), options: .atomic)
    }

    public func listSessions() throws -> [RecordingSession] {
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let directories = try FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return directories.compactMap { directoryURL in
            let metadataURL = directoryURL.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: metadataURL.path),
                  let data = try? Data(contentsOf: metadataURL),
                  let session = try? decoder.decode(RecordingSession.self, from: data) else {
                return nil
            }
            return session
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func setActiveRecording(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try id.write(to: activeRecordingFile, atomically: true, encoding: .utf8)
    }

    private func clearActiveRecording() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: activeRecordingFile.path) {
            try FileManager.default.removeItem(at: activeRecordingFile)
        }
    }
}
