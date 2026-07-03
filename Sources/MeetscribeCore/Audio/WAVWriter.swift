import Foundation

public enum WAVWriterError: Error, LocalizedError {
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Recording exceeded WAV size limit (~4 GB). Stop and start a new session."
        }
    }
}

/// Streaming WAV writer for 32-bit float PCM. Adapted from the diarize project (MIT).
public final class WAVWriter {
    private static let maxDataBytes = UInt64(UInt32.max) - 36

    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private var dataBytesWritten: UInt64 = 0
    private var closed = false

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)
        try writeHeaderPlaceholder()
    }

    public func append(samples: [Float]) throws {
        guard !closed, !samples.isEmpty else { return }
        let byteCount = UInt64(samples.count * MemoryLayout<Float>.size)
        if dataBytesWritten + byteCount > Self.maxDataBytes {
            throw WAVWriterError.fileTooLarge
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try handle.write(contentsOf: data)
        dataBytesWritten += byteCount
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try patchHeader()
        try handle.close()
    }

    deinit { try? close() }

    private func writeHeaderPlaceholder() throws {
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(uint32LE(0))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(uint32LE(16))
        header.append(uint16LE(3))
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        let byteRate = sampleRate * UInt32(channels) * 4
        header.append(uint32LE(byteRate))
        header.append(uint16LE(channels * 4))
        header.append(uint16LE(32))
        header.append("data".data(using: .ascii)!)
        header.append(uint32LE(0))
        try handle.write(contentsOf: header)
    }

    private func patchHeader() throws {
        let chunkSize = UInt32(min(dataBytesWritten + 36, UInt64(UInt32.max)))
        let dataSize = UInt32(min(dataBytesWritten, UInt64(UInt32.max)))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: uint32LE(chunkSize))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: uint32LE(dataSize))
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: 4)
    }

    private func uint16LE(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: 2)
    }
}
