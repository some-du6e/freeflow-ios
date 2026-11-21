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
///
/// WebKit fills the stream with exact zeros before the microphone's first input and after an
/// underrun. That fill isn't the room's background level, so the analyzer leaves it out of the
/// blocks. Every zero before the first non-zero sample, and every later run of at least
/// `fillRunFrames` zeros, counts towards `frames` and nothing else, and the blocks carry on
/// across the gap. The fill rarely ends on a block boundary. A block that kept part of it would
/// read low, and on a clip of ten blocks or fewer that one block sets the p10 floor and can
/// switch off the gain policy's noise guards. Shorter runs of zeros belong to a quiet signal,
/// and the analyzer measures them like any other sample.
struct LoudnessAnalyzer {
    static let blockFrames = 320
    /// 2 ms. Noise has to be quieter than about -95 dBFS to round to this many zeros in a row.
    static let fillRunFrames = 32
    static let binWidthDB: Float = 0.5
    static let binCount = 240
    static let speechPercentile = 0.95
    static let noiseFloorPercentile = 0.10

    private var histogram = [Int](repeating: 0, count: LoudnessAnalyzer.binCount)
    private var blockCount = 0
    private var partialSumOfSquares: Double = 0
    private var partialFrames = 0
    private var peakMagnitude = 0
    /// Zeros since the last non-zero sample. They join the blocks only if the run ends before
    /// reaching `fillRunFrames`.
    private var zeroRun = 0
    private var hasSignal = false
    private(set) var frames = 0

    mutating func ingest<Samples: Collection>(_ samples: Samples) where Samples.Element == Int16 {
        for sample in samples {
            guard sample != 0 else {
                zeroRun += 1
                continue
            }
            let magnitude = Int(sample.magnitude)
            if magnitude > peakMagnitude { peakMagnitude = magnitude }
            endZeroRun()
            hasSignal = true
            let value = Double(sample) / 32_768
            partialSumOfSquares += value * value
            partialFrames += 1
            if partialFrames == Self.blockFrames { closeBlock() }
        }
        frames += samples.count
    }

    /// Percentiles use complete blocks. When there are none, a partial last block with signal
    /// counts as one block. With nothing left to measure, speech and floor are both -120 dBFS,
    /// which `UploadGainPolicy` treats as no speech.
    func summary() -> LoudnessSummary {
        var measured = self
        measured.endZeroRun()
        if measured.blockCount == 0 && measured.partialSumOfSquares > 0 {
            Self.record(
                rms: (measured.partialSumOfSquares / Double(measured.partialFrames)).squareRoot(),
                in: &measured.histogram
            )
            measured.blockCount = 1
        }
        let peak = LevelMeter.decibels(fromRMS: Double(peakMagnitude) / 32_768)
        guard measured.blockCount > 0 else {
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
            speechDBFS: Self.percentile(Self.speechPercentile, of: measured.histogram, total: measured.blockCount),
            noiseFloorDBFS: Self.percentile(Self.noiseFloorPercentile, of: measured.histogram, total: measured.blockCount)
        )
    }

    /// Adds the current run of zeros to the blocks if it follows signal and is shorter than
    /// `fillRunFrames`, and otherwise drops it as fill.
    private mutating func endZeroRun() {
        if hasSignal && zeroRun < Self.fillRunFrames {
            var zeros = zeroRun
            while zeros > 0 {
                let added = min(zeros, Self.blockFrames - partialFrames)
                partialFrames += added
                zeros -= added
                if partialFrames == Self.blockFrames { closeBlock() }
            }
        }
        zeroRun = 0
    }

    private mutating func closeBlock() {
        // The sum is exactly 0 only when every sample in the block is 0.
        if partialSumOfSquares > 0 {
            Self.record(rms: (partialSumOfSquares / Double(partialFrames)).squareRoot(), in: &histogram)
            blockCount += 1
        }
        partialSumOfSquares = 0
        partialFrames = 0
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
