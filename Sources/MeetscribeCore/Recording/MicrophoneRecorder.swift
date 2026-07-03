import AVFoundation
import Foundation

public enum AudioRecorderError: Error, LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(String)
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied."
        case .engineStartFailed(let detail):
            return "Failed to start microphone capture: \(detail)"
        case .alreadyRecording:
            return "Microphone recorder is already running"
        }
    }
}

public final class MicrophoneRecorder: @unchecked Sendable {
    private let onSamples: ([Float]) -> Void
    private var audioEngine: AVAudioEngine?

    public init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start() throws {
        guard audioEngine == nil else { throw AudioRecorderError.alreadyRecording }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.engineStartFailed("Could not create target format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.engineStartFailed("Could not create converter")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [onSamples] buffer, _ in
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(frameCapacity, 1)
            ) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if error != nil { return }

            guard let channel = convertedBuffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(convertedBuffer.frameLength)))
            onSamples(samples)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    public func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }
}
