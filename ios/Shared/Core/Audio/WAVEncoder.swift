import Foundation

/// Canonical RIFF/WAVE files of signed 16-bit little-endian PCM, the format macOS FreeFlow
/// uploads: a 44-byte header (RIFF, `fmt ` with 16 bytes of PCM format, `data`).
enum WAVEncoder {
    static let headerByteCount = 44

    struct Format: Equatable {
        /// 1 is integer PCM.
        let audioFormat: Int
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int
        /// Byte offset of the first sample.
        let dataOffset: Int
        /// The `data` chunk size the header declares.
        let dataByteCount: Int

        var isPCM16: Bool { audioFormat == 1 && bitsPerSample == 16 && channels > 0 }
    }

    static func header(sampleRate: Int = 16_000, channels: Int = 1, dataByteCount: Int) -> Data {
        let bytesPerFrame = channels * 2
        var data = Data(capacity: headerByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(clamping: 36 + dataByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(clamping: channels), to: &data)
        appendLittleEndian(UInt32(clamping: sampleRate), to: &data)
        appendLittleEndian(UInt32(clamping: sampleRate * bytesPerFrame), to: &data)
        appendLittleEndian(UInt16(clamping: bytesPerFrame), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(clamping: dataByteCount), to: &data)
        return data
    }

    static func encode(_ samples: [Int16], sampleRate: Int = 16_000) -> Data {
        var data = header(sampleRate: sampleRate, dataByteCount: samples.count * 2)
        data.append(PCM16.encodeLittleEndian(samples))
        return data
    }

    /// Reads the format from the start of a WAV file, walking RIFF chunks so files with
    /// extra chunks before `data` parse too.
    static func parseHeader(_ data: Data) -> Format? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, at: 0) == "RIFF", ascii(bytes, at: 8) == "WAVE" else { return nil }
        var offset = 12
        var format: (audioFormat: Int, channels: Int, sampleRate: Int, bitsPerSample: Int)?
        while offset + 8 <= bytes.count {
            let chunkID = ascii(bytes, at: offset)
            let chunkSize = Int(readUInt32(bytes, at: offset + 4))
            let body = offset + 8
            if chunkID == "fmt " {
                guard chunkSize >= 16, body + 16 <= bytes.count else { return nil }
                format = (
                    Int(readUInt16(bytes, at: body)),
                    Int(readUInt16(bytes, at: body + 2)),
                    Int(readUInt32(bytes, at: body + 4)),
                    Int(readUInt16(bytes, at: body + 14))
                )
            } else if chunkID == "data" {
                guard let format else { return nil }
                return Format(
                    audioFormat: format.audioFormat,
                    channels: format.channels,
                    sampleRate: format.sampleRate,
                    bitsPerSample: format.bitsPerSample,
                    dataOffset: body,
                    dataByteCount: chunkSize
                )
            }
            offset = body + chunkSize + (chunkSize & 1)
        }
        return nil
    }

    /// Decodes a whole 16-bit PCM WAV file, for tests and checks.
    static func decode(_ wav: Data) -> (sampleRate: Int, channels: Int, samples: [Int16])? {
        guard let format = parseHeader(wav), format.isPCM16 else { return nil }
        let available = max(0, wav.count - format.dataOffset)
        let byteCount = min(format.dataByteCount, available) & ~1
        let start = wav.startIndex + format.dataOffset
        guard let samples = try? PCM16.decodeLittleEndian(wav.subdata(in: start..<start + byteCount)) else { return nil }
        return (format.sampleRate, format.channels, samples)
    }

    private static func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func ascii(_ bytes: [UInt8], at offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
