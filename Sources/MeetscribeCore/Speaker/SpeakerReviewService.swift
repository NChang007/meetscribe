import Foundation

public struct SpeakerReviewCandidate: Sendable {
    public let speakerId: String
    public let sessionIds: [String]
    public let latestSessionTitle: String
    public let excerpt: String
    public let sampleURL: URL
    public let calendarSuggestions: [String]
}

public enum SpeakerReviewService {
    public static func pendingCandidates(
        sessionStore: SessionStore = SessionStore(),
        speakerStore: SpeakerStore? = nil
    ) throws -> [SpeakerReviewCandidate] {
        let store = try speakerStore ?? SpeakerStore()
        let speakers = try store.allSpeakers().filter { $0.label == nil || $0.label?.isEmpty == true }

        return try speakers.compactMap { speaker in
            guard ReviewSnippetStore.hasPendingSamples(speakerId: speaker.id),
                  let sampleURL = ReviewSnippetStore.primarySampleURL(speakerId: speaker.id) else {
                return nil
            }

            let sessionIds = try store.sessionIds(for: speaker.id)
            let manifest = try ReviewSnippetStore.loadManifest(speakerId: speaker.id)
            let latestSample = manifest.sorted { $0.capturedAt > $1.capturedAt }.first
            let latestTitle = latestSample?.sessionTitle ?? "(unknown session)"
            let excerpt = latestSample?.excerpt ?? ""

            var attendeeNames: [String] = []
            for sessionId in sessionIds {
                if let session = try? sessionStore.load(id: sessionId) {
                    attendeeNames.append(contentsOf: session.attendees)
                }
            }
            let suggestions = uniqueSortedNames(attendeeNames)

            return SpeakerReviewCandidate(
                speakerId: speaker.id,
                sessionIds: sessionIds,
                latestSessionTitle: latestTitle,
                excerpt: excerpt,
                sampleURL: sampleURL,
                calendarSuggestions: suggestions
            )
        }
    }

    public static func pendingCandidates(
        forSession sessionId: String,
        sessionStore: SessionStore = SessionStore(),
        speakerStore: SpeakerStore? = nil
    ) throws -> [SpeakerReviewCandidate] {
        try pendingCandidates(sessionStore: sessionStore, speakerStore: speakerStore)
            .filter { $0.sessionIds.contains(sessionId) }
    }

    @discardableResult
    public static func applyLabel(
        speakerId: String,
        displayName: String,
        speakerStore: SpeakerStore? = nil,
        sessionStore: SessionStore = SessionStore()
    ) throws -> Int {
        let store = try speakerStore ?? SpeakerStore()
        try store.updateLabel(id: speakerId, label: displayName)
        try ReviewSnippetStore.deleteAllSamples(speakerId: speakerId)
        try VoiceProfileStore.refreshProfile(speakerId: speakerId, store: store)
        return try TranscriptRelabeler.applyLabel(
            speakerId: speakerId,
            displayName: displayName,
            sessionStore: sessionStore,
            speakerStore: store
        )
    }

    public static func playSample(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
    }

    private static func uniqueSortedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(trimmed)
        }
        return output.sorted()
    }
}

public enum TranscriptRelabeler {
    public static func applyLabel(
        speakerId: String,
        displayName: String,
        sessionStore: SessionStore,
        speakerStore: SpeakerStore
    ) throws -> Int {
        let sessionIds = try speakerStore.sessionIds(for: speakerId)
        var updatedCount = 0

        for sessionId in sessionIds {
            let session = try sessionStore.load(id: sessionId)
            let transcriptURL = sessionStore.transcriptURL(for: session)
            guard FileManager.default.fileExists(atPath: transcriptURL.path) else { continue }

            var segments = try TranscriptLoader.load(from: transcriptURL)
            var changed = false
            for index in segments.indices {
                if segments[index].speakerLabel == speakerId {
                    segments[index].resolvedSpeaker = displayName
                    changed = true
                }
            }
            guard changed else { continue }

            try TranscriptLoader.save(segments, to: transcriptURL)

            let resolved = ResolvedTranscript(sessionId: sessionId, segments: segments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(resolved).write(
                to: sessionStore.resolvedTranscriptURL(for: session),
                options: .atomic
            )

            let markdown = MarkdownExporter().export(session: session, segments: segments)
            try markdown.write(to: sessionStore.markdownURL(for: session), atomically: true, encoding: .utf8)

            try speakerStore.replaceTranscriptIndex(sessionId: sessionId, segments: segments)
            updatedCount += 1
        }

        return updatedCount
    }
}
