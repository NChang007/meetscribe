import Foundation

public struct TranscriptionService: Sendable {
    public init() {}

    public func exportMarkdown(sessionId: String, sessionStore: SessionStore = SessionStore()) throws -> URL {
        let session = try sessionStore.load(id: sessionId)
        let resolvedURL = sessionStore.resolvedTranscriptURL(for: session)
        let segments: [TranscriptSegment]
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            let data = try Data(contentsOf: resolvedURL)
            let resolved = try JSONDecoder().decode(ResolvedTranscript.self, from: data)
            segments = resolved.segments
        } else {
            segments = try TranscriptLoader.load(from: sessionStore.transcriptURL(for: session))
        }

        let markdown = MarkdownExporter().export(session: session, segments: segments)
        try markdown.write(to: sessionStore.markdownURL(for: session), atomically: true, encoding: .utf8)
        return sessionStore.markdownURL(for: session)
    }
}
