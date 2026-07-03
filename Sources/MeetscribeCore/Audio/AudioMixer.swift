import Foundation

/// Sample-accurate stereo/mono mixer. Adapted from the diarize project (MIT).
public final class AudioMixer: @unchecked Sendable {
    public enum Channel: Int, Sendable, CaseIterable {
        case mic = 0
        case system = 1
    }

    private let writer: WAVWriter
    private let queue = DispatchQueue(label: "meetscribe.mixer")
    private var buffers: [[Float]] = [[], []]
    private var heads: [Int] = [0, 0]
    private let compactThreshold = 16384
    private var enabledChannels: Set<Channel>
    private let stereo: Bool
    private var lastActivity: [Date] = [Date.distantPast, Date.distantPast]
    private let silenceTimeoutSeconds: Double = 0.25
    private var tickTimer: DispatchSourceTimer?

    public init(writer: WAVWriter, enabled: Set<Channel>, stereo: Bool) {
        self.writer = writer
        enabledChannels = enabled
        self.stereo = stereo
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.flushIfPossible() }
        timer.resume()
        tickTimer = timer
    }

    public func append(_ samples: [Float], channel: Channel) {
        guard enabledChannels.contains(channel) else { return }
        queue.async {
            self.buffers[channel.rawValue].append(contentsOf: samples)
            self.lastActivity[channel.rawValue] = Date()
        }
    }

    public func flushAndClose() throws {
        tickTimer?.cancel()
        tickTimer = nil
        try queue.sync {
            flushAll()
            try writer.close()
        }
    }

    private func flushIfPossible() {
        let now = Date()
        var activeCounts: [Int] = []
        var anyHasData = false
        for channel in enabledChannels {
            let availableCount = available(channel)
            if availableCount > 0 { anyHasData = true }
            let active = now.timeIntervalSince(lastActivity[channel.rawValue]) <= silenceTimeoutSeconds
            if active { activeCounts.append(availableCount) }
        }
        guard anyHasData else { return }

        let commit: Int
        if let activeMin = activeCounts.min(), activeMin > 0 {
            commit = activeMin
        } else {
            commit = enabledChannels.map { available($0) }.max() ?? 0
        }
        guard commit > 0 else { return }
        commitPrefix(length: commit)
    }

    private func flushAll() {
        let maxLen = enabledChannels.map { available($0) }.max() ?? 0
        if maxLen > 0 { commitPrefix(length: maxLen) }
    }

    private func available(_ channel: Channel) -> Int {
        buffers[channel.rawValue].count - heads[channel.rawValue]
    }

    private func commitPrefix(length: Int) {
        if stereo {
            var interleaved = [Float](repeating: 0, count: length * 2)
            for channel in enabledChannels {
                let raw = channel.rawValue
                let head = heads[raw]
                let take = min(length, buffers[raw].count - head)
                if take > 0 {
                    let buffer = buffers[raw]
                    for index in 0..<take {
                        interleaved[index * 2 + raw] = buffer[head + index]
                    }
                    heads[raw] = head + take
                }
                if heads[raw] > compactThreshold {
                    buffers[raw].removeFirst(heads[raw])
                    heads[raw] = 0
                }
            }
            try? writer.append(samples: interleaved)
        } else {
            var mixed = [Float](repeating: 0, count: length)
            for channel in enabledChannels {
                let raw = channel.rawValue
                let head = heads[raw]
                let take = min(length, buffers[raw].count - head)
                if take > 0 {
                    let buffer = buffers[raw]
                    for index in 0..<take { mixed[index] += buffer[head + index] }
                    heads[raw] = head + take
                }
                if heads[raw] > compactThreshold {
                    buffers[raw].removeFirst(heads[raw])
                    heads[raw] = 0
                }
            }
            try? writer.append(samples: mixed)
        }
    }
}
