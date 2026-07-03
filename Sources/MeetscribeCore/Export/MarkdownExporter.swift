import Foundation

public struct MarkdownExporter: Sendable {
    public init() {}

    public func export(session: RecordingSession, segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("- **Session:** `\(session.id)`")
        lines.append("- **Started:** \(iso(session.startedAt))")
        if let endedAt = session.endedAt {
            lines.append("- **Ended:** \(iso(endedAt))")
        }
        if !session.attendees.isEmpty {
            lines.append("- **Attendees:** \(session.attendees.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")

        for segment in segments {
            let speaker = segment.resolvedSpeaker ?? segment.speakerLabel ?? "Unknown"
            let timestamp = formatTimestamp(segment.start)
            lines.append("**\(speaker)** [\(timestamp)]")
            lines.append("")
            lines.append(segment.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
