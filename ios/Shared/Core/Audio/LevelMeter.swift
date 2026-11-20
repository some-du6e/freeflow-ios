import Foundation

/// RMS levels on the scale macOS AudioRecorder feeds LiveAudioLevelNormalizer: samples as
/// `Int16 / 32768` (or floats in -1...1), squares summed in Double, then the root of the mean.
enum LevelMeter {
    /// The lowest level reported in dBFS; digital silence maps here.
    static let floorDBFS: Float = -120

    static func rms<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Int16 {
        var sumOfSquares: Double = 0
        var count = 0
        for sample in samples {
            let value = Double(sample) / 32_768
            sumOfSquares += value * value
            count += 1
        }
        return count > 0 ? Float((sumOfSquares / Double(count)).squareRoot()) : 0
    }

    static func rms<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
        var sumOfSquares: Double = 0
        var count = 0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
            count += 1
        }
        return count > 0 ? Float((sumOfSquares / Double(count)).squareRoot()) : 0
    }

    /// RMS of consecutive `blockFrames`-long blocks; a shorter last block is included.
    static func blockRMS(_ samples: [Int16], blockFrames: Int) -> [Float] {
        guard blockFrames > 0 else { return [] }
        return stride(from: 0, to: samples.count, by: blockFrames).map { start in
            rms(samples[start..<min(start + blockFrames, samples.count)])
        }
    }

    /// 20·log10(rms), floored at `floorDBFS`.
    static func decibels(fromRMS rms: Double) -> Float {
        guard rms > 0 else { return floorDBFS }
        return max(floorDBFS, Float(20 * log10(rms)))
    }
}

/// Loudness statistics of a recording, in dBFS, for `UploadGainPolicy`.
struct LoudnessSummary: Equatable {
    let frames: Int
    /// The largest absolute sample.
    let peakDBFS: Float
    /// The 95th percentile of 20 ms block RMS: how loud the speech is.
    let speechDBFS: Float
    /// The 10th percentile of 20 ms block RMS: the background level.
    let noiseFloorDBFS: Float
}

/// Streams 16 kHz samples into 20 ms block RMS values kept in a 0.5 dB histogram from
/// -120 to 0 dBFS, so memory stays constant however long the recording runs.
struct LoudnessAnalyzer {
    static let blockFrames = 320
    static let binWidthDB: Float = 0.5
    static let binCount = 240
    static let speechPercentile = 0.95
    static let noiseFloorPercentile = 0.10

    private var histogram = [Int](repeating: 0, count: LoudnessAnalyzer.binCount)
    private var blockCount = 0
    private var partialSumOfSquares: Double = 0
    private var partialFrames = 0
    private var peakMagnitude = 0
    private(set) var frames = 0

    mutating func ingest<Samples: Collection>(_ samples: Samples) where Samples.Element == Int16 {
        for sample in samples {
            let magnitude = Int(sample.magnitude)
            if magnitude > peakMagnitude { peakMagnitude = magnitude }
            let value = Double(sample) / 32_768
            partialSumOfSquares += value * value
            partialFrames += 1
            if partialFrames == Self.blockFrames {
                Self.record(rms: (partialSumOfSquares / Double(partialFrames)).squareRoot(), in: &histogram)
                blockCount += 1
                partialSumOfSquares = 0
                partialFrames = 0
            }
        }
        frames += samples.count
    }

    /// Percentiles use complete blocks. A recording shorter than one block counts as one
    /// partial block.
    func summary() -> LoudnessSummary {
        var histogram = self.histogram
        var blocks = blockCount
        if blocks == 0 && partialFrames > 0 {
            Self.record(rms: (partialSumOfSquares / Double(partialFrames)).squareRoot(), in: &histogram)
            blocks = 1
        }
        let peak = LevelMeter.decibels(fromRMS: Double(peakMagnitude) / 32_768)
        guard blocks > 0 else {
            return LoudnessSummary(
                frames: frames,
                peakDBFS: peak,
                speechDBFS: LevelMeter.floorDBFS,
                noiseFloorDBFS: LevelMeter.floorDBFS
            )
        }
        return LoudnessSummary(
            frames: frames,
            peakDBFS: peak,
            speechDBFS: Self.percentile(Self.speechPercentile, of: histogram, total: blocks),
            noiseFloorDBFS: Self.percentile(Self.noiseFloorPercentile, of: histogram, total: blocks)
        )
    }

    private static func record(rms: Double, in histogram: inout [Int]) {
        let decibels = LevelMeter.decibels(fromRMS: rms)
        let bin = Int(((decibels - LevelMeter.floorDBFS) / binWidthDB).rounded(.down))
        histogram[min(max(bin, 0), binCount - 1)] += 1
    }

    /// Nearest-rank percentile, reported as the centre of its histogram bin.
    private static func percentile(_ fraction: Double, of histogram: [Int], total: Int) -> Float {
        let rank = max(1, Int((fraction * Double(total)).rounded(.up)))
        var seen = 0
        for (bin, count) in histogram.enumerated() {
            seen += count
            if seen >= rank {
                return LevelMeter.floorDBFS + (Float(bin) + 0.5) * binWidthDB
            }
        }
        return 0
    }
}
