import Foundation

/// Writes a 16 kHz mono 16-bit WAV file incrementally, so a recording never has to sit in
/// memory. The header starts with zero sizes; `finish()` patches them.
final class StreamingWAVWriter {
    enum Failure: Error, Equatable {
        case cannotCreateFile
        case alreadyFinished
        case unsupportedFormat
    }

    let url: URL
    let sampleRate: Int
    private(set) var frameCount = 0
    private var handle: FileHandle?

    /// Creates (or replaces) the file at `url` and writes the header.
    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        let header = WAVEncoder.header(sampleRate: sampleRate, dataByteCount: 0)
        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw Failure.cannotCreateFile
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            _ = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    var isFinished: Bool { handle == nil }

    func append<Samples: Collection>(_ samples: Samples) throws where Samples.Element == Int16 {
        guard let handle else { throw Failure.alreadyFinished }
        guard !samples.isEmpty else { return }
        try handle.write(contentsOf: PCM16.encodeLittleEndian(samples))
        frameCount += samples.count
    }

    /// Patches the RIFF and data sizes and closes the file. Returns the frame count. Calling
    /// it again returns the same count.
    @discardableResult
    func finish() throws -> Int {
        guard let handle else { return frameCount }
        self.handle = nil
        let dataByteCount = frameCount * 2
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.littleEndianBytes(UInt32(clamping: 36 + dataByteCount)))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.littleEndianBytes(UInt32(clamping: dataByteCount)))
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return frameCount
    }

    /// Closes the file if needed and deletes it.
    func discard() {
        if let handle {
            self.handle = nil
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Multiplies every sample of a 16-bit PCM WAV file by `gainDB`, in place, one block at a
    /// time so memory stays bounded. Samples are rounded and clamped to the Int16 range.
    static func applyGain(_ gainDB: Float, toWAVAt url: URL, blockBytes: Int = 65_536) throws {
        guard gainDB.isFinite, gainDB != 0 else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let probe = try handle.read(upToCount: 4_096) ?? Data()
        guard let format = WAVEncoder.parseHeader(probe), format.isPCM16 else {
            throw Failure.unsupportedFormat
        }
        let fileSize = try handle.seekToEnd()
        let dataStart = UInt64(format.dataOffset)
        let dataEnd = min(dataStart + UInt64(format.dataByteCount), fileSize)
        let step = UInt64(max(2, blockBytes - blockBytes % 2))
        let factor = PCM16.linearFactor(forGainDB: gainDB)

        var offset = dataStart
        while offset + 1 < dataEnd {
            let length = Int(min(step, (dataEnd - offset) & ~1))
            try handle.seek(toOffset: offset)
            guard let block = try handle.read(upToCount: length), block.count >= 2 else { break }
            var samples = try PCM16.decodeLittleEndian(block.prefix(block.count & ~1))
            for index in samples.indices {
                samples[index] = PCM16.scaled(samples[index], by: factor)
            }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: PCM16.encodeLittleEndian(samples))
            offset += UInt64(samples.count * 2)
        }
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
