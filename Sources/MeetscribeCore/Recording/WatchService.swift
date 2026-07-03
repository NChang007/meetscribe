import Foundation

public enum WatchServiceError: Error, LocalizedError {
    case stopTimeout(Int32)

    public var errorDescription: String? {
        switch self {
        case .stopTimeout(let pid):
            return "Watch process \(pid) did not stop."
        }
    }
}

public struct WatchState: Codable, Sendable {
    public let pid: Int32
}

public enum WatchService {
    private static var stateFile: URL {
        MeetscribePaths.configDirectory.appendingPathComponent(".watch-state.json")
    }

    public static func saveState(pid: Int32) throws {
        try MeetscribePaths.ensureConfigDirectory()
        let data = try JSONEncoder().encode(WatchState(pid: pid))
        try data.write(to: stateFile, options: .atomic)
    }

    public static func loadState() throws -> WatchState? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        let state = try JSONDecoder().decode(WatchState.self, from: Data(contentsOf: stateFile))
        if kill(state.pid, 0) != 0 {
            try clearState()
            return nil
        }
        return state
    }

    public static func clearState() throws {
        if FileManager.default.fileExists(atPath: stateFile.path) {
            try FileManager.default.removeItem(at: stateFile)
        }
    }

    public static func isRunning() -> Bool {
        (try? loadState()) != nil
    }

    public static func stopRemoteWatcher() throws {
        guard let state = try loadState() else { return }
        kill(state.pid, SIGTERM)
        for _ in 0..<20 {
            if kill(state.pid, 0) != 0 {
                try clearState()
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw WatchServiceError.stopTimeout(state.pid)
    }
}
