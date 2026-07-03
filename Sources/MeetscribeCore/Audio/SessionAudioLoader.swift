import AVFoundation
import FluidAudio
import Foundation

public struct LoadedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let micChannel: [Float]?
    public let systemChannel: [Float]?

    public var durationSec: Double { Double(samples.count) / Double(sampleRate) }
    public var isStereoSplit: Bool { micChannel != nil && systemChannel != nil }
}

public enum SessionAudioLoader {
    public static func load(url: URL) throws -> LoadedAudio {
        let channelCount = channelCount(of: url)
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)

        if channelCount == 2 {
            let (left, right) = try deinterleave(url: url)
            return LoadedAudio(samples: samples, sampleRate: 16000, micChannel: left, systemChannel: right)
        }
        return LoadedAudio(samples: samples, sampleRate: 16000, micChannel: nil, systemChannel: nil)
    }

    private static func channelCount(of url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 1 }
        return Int(file.processingFormat.channelCount)
    }

    private static func deinterleave(url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard sourceFormat.channelCount == 2 else { return ([], []) }

        let frameCount = AVAudioFrameCount(file.length)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return ([], [])
        }
        try file.read(into: readBuffer)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let left = resampleChannel(readBuffer, channelIndex: 0, sourceFormat: sourceFormat, targetFormat: targetFormat)
        let right = resampleChannel(readBuffer, channelIndex: 1, sourceFormat: sourceFormat, targetFormat: targetFormat)
        return (left, right)
    }

    private static func resampleChannel(
        _ buffer: AVAudioPCMBuffer,
        channelIndex: Int,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
            return []
        }
        monoBuffer.frameLength = buffer.frameLength

        if let source = buffer.floatChannelData?[channelIndex],
           let destination = monoBuffer.floatChannelData?[0] {
            memcpy(destination, source, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }

        guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else { return [] }
        let ratio = targetFormat.sampleRate / monoFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return []
        }

        guard (try? converter.convert(to: outputBuffer, from: monoBuffer)) != nil else { return [] }
        guard let channel = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
    }
}
