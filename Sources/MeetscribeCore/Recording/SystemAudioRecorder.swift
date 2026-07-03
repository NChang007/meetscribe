import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum SystemAudioRecorderError: Error, LocalizedError {
    case noDisplayAvailable
    case alreadyRecording
    case permissionDenied
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for system audio capture"
        case .alreadyRecording:
            return "System audio recorder is already running"
        case .permissionDenied:
            return "Screen Recording permission is required for system audio capture"
        case .unsupportedFormat:
            return "Unsupported system audio sample format"
        }
    }
}

public final class SystemAudioRecorder: NSObject, @unchecked Sendable {
    private let onSamples: ([Float]) -> Void
    private var stream: SCStream?
    private var targetFormat: AVAudioFormat?

    public init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    public func start() async throws {
        guard stream == nil else { throw SystemAudioRecorderError.alreadyRecording }

        if #available(macOS 11.0, *) {
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()
                throw SystemAudioRecorderError.permissionDenied
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }
        targetFormat = format

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "meetscribe.system-audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        targetFormat = nil
    }
}

extension SystemAudioRecorder: SCStreamDelegate {}

extension SystemAudioRecorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              let targetFormat,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let samples: [Float]
        if inputFormat.commonFormat == .pcmFormatFloat32,
           let channel = pcmBuffer.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(frameCount)))
        } else if inputFormat.commonFormat == .pcmFormatInt16,
                  let channel = pcmBuffer.int16ChannelData?[0] {
            samples = (0..<Int(frameCount)).map { index in
                Float(channel[index]) / Float(Int16.max)
            }
        } else {
            return
        }

        if inputFormat.sampleRate == targetFormat.sampleRate {
            onSamples(samples)
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
        let outputCapacity = AVAudioFrameCount(
            Double(frameCount) * targetFormat.sampleRate / inputFormat.sampleRate + 32
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }
        guard (try? converter.convert(to: converted, from: pcmBuffer)) != nil,
              let outputChannel = converted.floatChannelData?[0] else {
            return
        }
        let convertedSamples = Array(
            UnsafeBufferPointer(start: outputChannel, count: Int(converted.frameLength))
        )
        onSamples(convertedSamples)
    }
}
