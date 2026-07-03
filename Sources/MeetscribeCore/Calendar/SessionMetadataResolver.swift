import Foundation

/// Calendar metadata is optional enrichment — never blocks recording start.
public enum SessionMetadataResolver {
    /// Starts a background lookup; updates `session.json` when gcalcli returns (usually within a few seconds).
    public static func enrichSessionIfNeeded(
        sessionId: String,
        sessionStore: SessionStore,
        useCalendar: Bool
    ) {
        guard useCalendar else { return }
        Task.detached(priority: .utility) {
            await enrichSession(sessionId: sessionId, sessionStore: sessionStore)
        }
    }

    private static func enrichSession(sessionId: String, sessionStore: SessionStore) async {
        let config = (try? MeetscribeConfig.load()) ?? MeetscribeConfig()
        guard CalendarLookup.gcalcliInstalled(config: config) else { return }

        let meeting = await Task.detached(priority: .utility) {
            CalendarLookup.meetingAt(config: config)
        }.value

        guard let meeting else { return }
        guard var session = try? sessionStore.load(id: sessionId) else { return }

        if CalendarLookup.shouldReplaceDefaultTitle(session.title) {
            session.title = meeting.title
        }
        if session.attendees.isEmpty {
            session.attendees = meeting.attendees
        }
        session.calendarEventId = meeting.eventIdentifier
        try? sessionStore.save(session)
    }
}
