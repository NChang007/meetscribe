import Foundation

public enum MeetingPipelineError: Error, LocalizedError {
    case missingAudio
    case emptySpeech

    public var errorDescription: String? {
        switch self {
        case .missingAudio:
            return "No meeting audio found for this session."
        case .emptySpeech:
            return "No speech detected in the recording."
        }
    }
}

public final class MeetingPipeline {
    private let sessionStore: SessionStore
    private let speakerStore: SpeakerStore
    private let progress: ProgressReporter

    public init(
        sessionStore: SessionStore = SessionStore(),
        speakerStore: SpeakerStore? = nil,
        progress: ProgressReporter = ConsoleProgress()
    ) throws {
        self.sessionStore = sessionStore
        self.speakerStore = try speakerStore ?? SpeakerStore()
        self.progress = progress
    }

    public static func prepareModels(config: MeetscribeConfig) async throws {
        let allowDownload = config.allowModelDownload
        let diarizer = DiarizationPipeline()
        try await diarizer.prepareModels(allowDownload: allowDownload)
        let transcription = TranscriptionPipeline()
        try await transcription.prepareModels(language: config.defaultLanguage, allowDownload: allowDownload)
    }

    public func processSession(sessionId: String, config: MeetscribeConfig) async throws -> RecordingSession {
        var session = try sessionStore.load(id: sessionId)
        do {
            return try await processSessionBody(session: &session, sessionId: sessionId, config: config)
        } catch {
            try? sessionStore.markFailed(id: sessionId)
            throw error
        }
    }

    private func processSessionBody(
        session: inout RecordingSession,
        sessionId: String,
        config: MeetscribeConfig
    ) async throws -> RecordingSession {
        let allowDownload = config.allowModelDownload
        let audioURL = sessionStore.meetingAudioURL(for: session)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw MeetingPipelineError.missingAudio
        }

        progress.step("Loading audio …")
        let audio = try SessionAudioLoader.load(url: audioURL)

        progress.step("Diarizing …")
        let diarizer = DiarizationPipeline()
        try await diarizer.prepareModels(allowDownload: allowDownload)

        let diarization: DiarizationOutput
        if audio.isStereoSplit, let micChannel = audio.micChannel, let systemChannel = audio.systemChannel {
            progress.step("Stereo split — diarizing mic and system separately …")
            let micDiarization = try await diarizer.diarize(samples: micChannel)
            let systemDiarization = try await diarizer.diarize(samples: systemChannel)
            diarization = DiarizationOutput.merged(
                mic: micDiarization,
                system: systemDiarization,
                micPrefix: "local",
                systemPrefix: "remote"
            )
        } else {
            diarization = try await diarizer.diarize(samples: audio.samples)
        }

        guard !diarization.segments.isEmpty else {
            throw MeetingPipelineError.emptySpeech
        }

        progress.step("Matching speakers across sessions …")
        let matcher = try SpeakerMatcher(
            store: speakerStore,
            config: SpeakerMatcher.Config(threshold: config.similarityThreshold)
        )
        var localToGlobal: [String: String] = [:]
        for (localId, centroid) in diarization.speakerCentroids {
            let result = try matcher.matchOrCreate(
                centroid: centroid,
                sessionId: sessionId,
                segmentRange: nil
            )
            localToGlobal[localId] = result.speakerId
        }

        progress.step("Transcribing segments …")
        let transcription = TranscriptionPipeline(progress: progress)
        try await transcription.prepareModels(language: config.defaultLanguage, allowDownload: allowDownload)

        let transcribed: [TranscribedSegment]
        if audio.isStereoSplit, let micChannel = audio.micChannel, let systemChannel = audio.systemChannel {
            let localSegments = diarization.segments.filter { $0.localSpeakerId.hasPrefix("local-") }
            let remoteSegments = diarization.segments.filter { $0.localSpeakerId.hasPrefix("remote-") }
            let localText = try await transcription.transcribe(
                diarized: localSegments,
                samples: micChannel,
                localToGlobal: localToGlobal,
                language: config.defaultLanguage
            )
            let remoteText = try await transcription.transcribe(
                diarized: remoteSegments,
                samples: systemChannel,
                localToGlobal: localToGlobal,
                language: config.defaultLanguage
            )
            transcribed = (localText + remoteText).sorted { $0.startSec < $1.startSec }
        } else {
            transcribed = try await transcription.transcribe(
                diarized: diarization.segments,
                samples: audio.samples,
                localToGlobal: localToGlobal,
                language: config.defaultLanguage
            )
        }

        progress.step("Applying meeting UI speaker hints …")
        let events = try SpeakerEventLoader.load(from: sessionStore.speakerEventsURL(for: session))
        let speakerLabels = try speakerStore.allSpeakers().reduce(into: [String: String]()) { labels, speaker in
            labels[speaker.id] = speaker.label ?? speaker.id
        }

        let segments = transcribed.map { segment in
            TranscriptSegment(
                start: segment.startSec,
                end: segment.endSec,
                text: segment.text,
                speakerLabel: segment.globalSpeakerId,
                resolvedSpeaker: resolveDisplayName(
                    segment: segment,
                    events: events,
                    speakerLabels: speakerLabels
                )
            )
        }

        try TranscriptLoader.save(segments, to: sessionStore.transcriptURL(for: session))
        try speakerStore.indexTranscript(sessionId: sessionId, segments: segments)

        let resolved = ResolvedTranscript(sessionId: sessionId, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(resolved).write(to: sessionStore.resolvedTranscriptURL(for: session), options: .atomic)

        let markdown = MarkdownExporter().export(session: session, segments: segments)
        try markdown.write(to: sessionStore.markdownURL(for: session), atomically: true, encoding: .utf8)

        session.status = .transcribed
        try sessionStore.save(session)

        progress.step("Updating voice profiles …")
        try VoiceProfileStore.refreshProfiles(for: Set(localToGlobal.values), store: speakerStore)

        if config.keepReviewSnippets {
            progress.step("Saving review snippets for unlabeled speakers …")
            try ReviewSnippetStore.captureSnippets(
                speakerStore: speakerStore,
                session: session,
                diarization: diarization,
                localToGlobal: localToGlobal,
                transcribed: transcribed,
                audio: audio
            )
        }

        if config.deleteAudioAfterAnalysis {
            let audioURL = sessionStore.meetingAudioURL(for: session)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                try FileManager.default.removeItem(at: audioURL)
                progress.step("Deleted raw audio (embeddings + transcript kept)")
            }
        }

        progress.step("Done — \(segments.count) segments")
        return session
    }

    public func processFile(
        audioURL: URL,
        title: String,
        config: MeetscribeConfig,
        attendees: [String] = []
    ) async throws -> RecordingSession {
        let session = try sessionStore.importSession(title: title, attendees: attendees)
        let destination = sessionStore.meetingAudioURL(for: session)
        try FileManager.default.copyItem(at: audioURL, to: destination)
        return try await processSession(sessionId: session.id, config: config)
    }

    private func resolveDisplayName(
        segment: TranscribedSegment,
        events: [SpeakerEvent],
        speakerLabels: [String: String]
    ) -> String {
        if segment.localSpeakerId.hasPrefix("local-") {
            return "You"
        }

        let midpoint = (segment.startSec + segment.endSec) / 2
        let nearby = events.filter { abs($0.timestamp - midpoint) <= 2.0 }
        if let eventName = nearby.max(by: { lhs, rhs in
            abs(lhs.timestamp - midpoint) < abs(rhs.timestamp - midpoint)
        })?.speakerName {
            return eventName.replacingOccurrences(of: " (You)", with: "You")
        }

        return speakerLabels[segment.globalSpeakerId] ?? segment.globalSpeakerId
    }
}

public enum TranscriptLoader {
    public static func load(from url: URL) throws -> [TranscriptSegment] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    public static func save(_ segments: [TranscriptSegment], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(segments).write(to: url, options: .atomic)
    }
}
