import Foundation

/// Signed 16-bit PCM helpers shared by the capture bridge, the WAV writer and the tests.
enum PCM16 {
    enum DecodingError: Error, Equatable {
        case oddByteCount(Int)
    }

    /// Converts a sample in -1...1 exactly like the capture page's `ffToInt16`: clamp, then
    /// JavaScript's `Math.round(x * 32767)`, which rounds halves up. NaN becomes 0, which is
    /// what an `Int16Array` stores for it.
    static func sample(fromUnit value: Float) -> Int16 {
        guard !value.isNaN else { return 0 }
        let clamped = Double(min(max(value, -1), 1))
        return Int16((clamped * 32_767 + 0.5).rounded(.down))
    }

    /// The scale AudioRecorder uses for RMS: `sample / 32768`.
    static func unit(_ sample: Int16) -> Float {
        Float(sample) / 32_768
    }

    static func decodeLittleEndian(_ data: Data) throws -> [Int16] {
        guard data.count % 2 == 0 else { throw DecodingError.oddByteCount(data.count) }
        var samples = [Int16](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in samples.indices {
                let low = UInt16(bytes[2 * index])
                let high = UInt16(bytes[2 * index + 1])
                samples[index] = Int16(bitPattern: low | high << 8)
            }
        }
        return samples
    }

    static func encodeLittleEndian<Samples: Collection>(_ samples: Samples) -> Data where Samples.Element == Int16 {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var offset = 0
            for sample in samples {
                let bits = UInt16(bitPattern: sample)
                bytes[offset] = UInt8(truncatingIfNeeded: bits)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                offset += 2
            }
        }
        return data
    }

    /// The linear factor for a gain in dB.
    static func linearFactor(forGainDB gainDB: Float) -> Double {
        pow(10, Double(gainDB) / 20)
    }

    /// Multiplies a sample by `factor`, rounding to nearest and clamping to the Int16 range.
    static func scaled(_ sample: Int16, by factor: Double) -> Int16 {
        let value = (Double(sample) * factor).rounded()
        return Int16(min(max(value, -32_768), 32_767))
    }

    static func apply(gainDB: Float, to samples: inout [Int16]) {
        let factor = linearFactor(forGainDB: gainDB)
        for index in samples.indices {
            samples[index] = scaled(samples[index], by: factor)
        }
    }
}
