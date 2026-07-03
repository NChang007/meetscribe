import MeetscribeCore
import XCTest

final class SessionStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSaveLoadRoundTrip() throws {
        let store = SessionStore(sessionsRoot: tempRoot)
        let session = RecordingSession(title: "Standup", attendees: ["Ada"])
        try store.save(session)

        let loaded = try store.load(id: session.id)
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.title, "Standup")
        XCTAssertEqual(loaded.attendees, ["Ada"])
        XCTAssertEqual(loaded.status, .recording)
    }

    func testListSessionsSortsByStartedAt() throws {
        let store = SessionStore(sessionsRoot: tempRoot)
        var older = RecordingSession(title: "Older", startedAt: Date(timeIntervalSince1970: 100))
        var newer = RecordingSession(title: "Newer", startedAt: Date(timeIntervalSince1970: 200))
        try store.save(older)
        try store.save(newer)

        let listed = try store.listSessions()
        XCTAssertEqual(listed.map(\.title), ["Newer", "Older"])
    }

    func testMarkFailed() throws {
        let store = SessionStore(sessionsRoot: tempRoot)
        let session = RecordingSession(title: "Broken", status: .recorded)
        try store.save(session)
        try store.markFailed(id: session.id)

        let loaded = try store.load(id: session.id)
        XCTAssertEqual(loaded.status, .failed)
    }
}
