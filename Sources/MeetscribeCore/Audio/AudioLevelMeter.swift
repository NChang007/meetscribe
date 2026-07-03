import Foundation

/// Lock-free live level meter for CLI display during recording.
public final class AudioLevelMeter: @unchecked Sendable {
    public static let shared = AudioLevelMeter()

    public enum Channel: Int, Sendable, CaseIterable {
        case mic = 0
        case system = 1
    }

    private let levels: UnsafeMutablePointer<Double>
    private let lastFeed: UnsafeMutablePointer<Double>
    private let attack = 0.5
    private let release = 0.15
    private let floorDB = -60.0

    public init() {
        levels = .allocate(capacity: Channel.allCases.count)
        lastFeed = .allocate(capacity: Channel.allCases.count)
        levels.initialize(repeating: 0, count: Channel.allCases.count)
        lastFeed.initialize(repeating: 0, count: Channel.allCases.count)
    }

    deinit {
        levels.deallocate()
        lastFeed.deallocate()
    }

    public func feed(_ samples: [Float], channel: Channel) {
        guard !samples.isEmpty else { return }
        var sumSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rootMeanSquare = (sumSquares / Double(samples.count)).squareRoot()
        let decibels = rootMeanSquare > 0 ? 20 * log10(rootMeanSquare) : floorDB
        let normalized = max(0, min(1, (decibels - floorDB) / -floorDB))

        let index = channel.rawValue
        let previous = levels[index]
        let coefficient = normalized > previous ? attack : release
        levels[index] = previous + (normalized - previous) * coefficient
        lastFeed[index] = Date.timeIntervalSinceReferenceDate
    }

    public func level(_ channel: Channel) -> Double {
        let index = channel.rawValue
        let raw = levels[index]
        let age = Date.timeIntervalSinceReferenceDate - lastFeed[index]
        if age > 0.25 {
            let decay = max(0, 1 - (age - 0.25) / 0.5)
            return raw * decay
        }
        return raw
    }

    public func renderBars(width: Int = 24) -> String {
        func bar(_ channel: Channel, label: String) -> String {
            let level = level(channel)
            let filled = Int((level * Double(width)).rounded())
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
            return "\(label) |\(bar)|"
        }
        return "\(bar(.mic, label: "mic "))  \(bar(.system, label: "sys "))"
    }
}
