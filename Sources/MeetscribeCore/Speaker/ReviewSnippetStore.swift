import Foundation

public struct ReviewSample: Codable, Sendable {
    public let sessionId: String
    public let sessionTitle: String
    public let excerpt: String
    public let fileName: String
    public let capturedAt: Date

    public init(
        sessionId: String,
        sessionTitle: String,
        excerpt: String,
        fileName: String,
        capturedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.excerpt = excerpt
        self.fileName = fileName
        self.capturedAt = capturedAt
    }
}

/// Saves short voice samples for unlabeled speakers so `speakers review` can run later.
public enum ReviewSnippetStore {
    private static let manifestFileName = "manifest.json"
    private static let minDurationSec = 2.0
    private static let maxDurationSec = 8.0
    private static let maxSamplesPerSession = 2

    public static func samplesDirectory(speakerId: String) -> URL {
        MeetscribePaths.voiceProfileDirectory(speakerId: speakerId)
            .appendingPathComponent("samples", isDirectory: true)
    }

    public static func manifestURL(speakerId: String) -> URL {
        samplesDirectory(speakerId: speakerId).appendingPathComponent(manifestFileName)
    }

    public static func pendingSpeakerIds() -> [String] {
        guard let voiceRoot = try? FileManager.default.contentsOfDirectory(
            at: MeetscribePaths.voiceProfilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return voiceRoot.compactMap { directoryURL in
            let speakerId = directoryURL.lastPathComponent
            guard hasPendingSamples(speakerId: speakerId) else { return nil }
            return speakerId
        }
        .sorted()
    }

    public static func hasPendingSamples(speakerId: String) -> Bool {
        guard let manifest = try? loadManifest(speakerId: speakerId) else { return false }
        return !manifest.isEmpty && manifest.contains { sampleFileExists(speakerId: speakerId, fileName: $0.fileName) }
    }

    public static func loadManifest(speakerId: String) throws -> [ReviewSample] {
        let url = manifestURL(speakerId: speakerId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ReviewSample].self, from: data)
    }

    public static func captureSnippets(
        speakerStore: SpeakerStore,
        session: RecordingSession,
        diarization: DiarizationOutput,
        localToGlobal: [String: String],
        transcribed: [TranscribedSegment],
        audio: LoadedAudio
    ) throws {
        let labeledIds = Set(
            try speakerStore.allSpeakers()
                .filter { $0.label != nil && !($0.label?.isEmpty ?? true) }
                .map(\.id)
        )

        var globalToLocalIds: [String: [String]] = [:]
        for (localSpeakerId, globalSpeakerId) in localToGlobal {
            globalToLocalIds[globalSpeakerId, default: []].append(localSpeakerId)
        }
        let unlabeledGlobals = Set(localToGlobal.values).subtracting(labeledIds)

        for globalSpeakerId in unlabeledGlobals {
            let localSpeakerIds = globalToLocalIds[globalSpeakerId] ?? []
            let segments = diarization.segments.filter { localSpeakerIds.contains($0.localSpeakerId) }
            let picks = pickSegments(from: segments)
            guard !picks.isEmpty else { continue }

            var manifest = (try? loadManifest(speakerId: globalSpeakerId)) ?? []
            let samplesDir = samplesDirectory(speakerId: globalSpeakerId)
            try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)

            for (index, segment) in picks.enumerated() {
                let fileName = "\(session.id)-\(index + 1).wav"
                let sampleURL = samplesDir.appendingPathComponent(fileName)
                let channelSamples = channelSamples(for: segment, audio: audio)
                guard !channelSamples.isEmpty else { continue }

                let writer = try WAVWriter(url: sampleURL, sampleRate: audio.sampleRate, channels: 1)
                try writer.append(samples: channelSamples)
                try writer.close()

                let excerpt = excerptText(for: segment, in: transcribed, globalSpeakerId: globalSpeakerId)
                let sample = ReviewSample(
                    sessionId: session.id,
                    sessionTitle: session.title,
                    excerpt: excerpt,
                    fileName: fileName
                )
                manifest.removeAll { $0.sessionId == session.id && $0.fileName == fileName }
                manifest.append(sample)
            }

            try saveManifest(manifest, speakerId: globalSpeakerId)
        }
    }

    public static func primarySampleURL(speakerId: String) -> URL? {
        guard let manifest = try? loadManifest(speakerId: speakerId),
              let first = manifest.first(where: { sampleFileExists(speakerId: speakerId, fileName: $0.fileName) }) else {
            return nil
        }
        return samplesDirectory(speakerId: speakerId).appendingPathComponent(first.fileName)
    }

    public static func deleteAllSamples(speakerId: String) throws {
        let directory = samplesDirectory(speakerId: speakerId)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public static func purgeAllPending() throws -> Int {
        var count = 0
        for speakerId in pendingSpeakerIds() {
            try deleteAllSamples(speakerId: speakerId)
            count += 1
        }
        return count
    }

    private static func saveManifest(_ manifest: [ReviewSample], speakerId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(speakerId: speakerId), options: .atomic)
    }

    private static func sampleFileExists(speakerId: String, fileName: String) -> Bool {
        FileManager.default.fileExists(
            atPath: samplesDirectory(speakerId: speakerId).appendingPathComponent(fileName).path
        )
    }

    private static func pickSegments(from segments: [LocalDiarizedSegment]) -> [LocalDiarizedSegment] {
        let scored = segments
            .filter { segment in
                let duration = segment.endSec - segment.startSec
                return duration >= minDurationSec && duration <= maxDurationSec
            }
            .sorted { lhs, rhs in
                if lhs.qualityScore != rhs.qualityScore {
                    return lhs.qualityScore > rhs.qualityScore
                }
                let lhsDuration = lhs.endSec - lhs.startSec
                let rhsDuration = rhs.endSec - rhs.startSec
                return abs(lhsDuration - 4.5) < abs(rhsDuration - 4.5)
            }
        return Array(scored.prefix(maxSamplesPerSession))
    }

    private static func channelSamples(for segment: LocalDiarizedSegment, audio: LoadedAudio) -> [Float] {
        let sampleRate = audio.sampleRate
        let startIndex = max(0, Int(segment.startSec * Double(sampleRate)))
        let endIndex: Int

        if segment.localSpeakerId.hasPrefix("local-"), let micChannel = audio.micChannel {
            endIndex = min(micChannel.count, Int(segment.endSec * Double(sampleRate)))
            guard endIndex > startIndex else { return [] }
            return Array(micChannel[startIndex..<endIndex])
        }

        if segment.localSpeakerId.hasPrefix("remote-"), let systemChannel = audio.systemChannel {
            endIndex = min(systemChannel.count, Int(segment.endSec * Double(sampleRate)))
            guard endIndex > startIndex else { return [] }
            return Array(systemChannel[startIndex..<endIndex])
        }

        endIndex = min(audio.samples.count, Int(segment.endSec * Double(sampleRate)))
        guard endIndex > startIndex else { return [] }
        return Array(audio.samples[startIndex..<endIndex])
    }

    private static func excerptText(
        for segment: LocalDiarizedSegment,
        in transcribed: [TranscribedSegment],
        globalSpeakerId: String
    ) -> String {
        let match = transcribed.first { item in
            item.globalSpeakerId == globalSpeakerId
                && abs(item.startSec - segment.startSec) < 0.5
        }
        let text = match?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.count <= 120 { return text.isEmpty ? "(no transcript excerpt)" : text }
        return String(text.prefix(117)) + "…"
    }
}
