import AVFoundation

enum AppAudioRecorderError: LocalizedError, Equatable {
    case noInputAvailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            "No audio input device available."
        case .conversionFailed:
            "Audio conversion failed."
        }
    }
}

/// Writes 16 kHz mono 16-bit PCM WAV the same way the macOS AudioRecorder
/// does (Sources/AudioRecorder.swift): AVAudioConverter from the capture
/// format, then AVAudioFile with the same linear PCM settings. Not thread
/// safe; AppAudioRecorder serializes access.
final class AppRecordingWAVWriter {
    static let sampleRate: Double = 16_000

    /// Matches `AudioRecorder.recordingTargetFormat`.
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!

    /// Matches `AudioRecorder.pcmFileSettings(for:)` for the target format.
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    let fileURL: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var framesWritten: AVAudioFramePosition = 0

    /// Creates the file. The ".wav" extension selects the WAVE container,
    /// and TranscriptionService uploads it as audio/wav.
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        file = try AVAudioFile(
            forWriting: fileURL,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// Converts `buffer` to the target format and appends it. Returns the
    /// converted audio for metering, or nil when the converter produced none
    /// yet (it buffers a little while resampling).
    func append(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let file, buffer.frameLength > 0 else { return nil }
        let targetFormat = Self.targetFormat

        if buffer.format == targetFormat {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            return buffer
        }

        let activeConverter = try makeConverter(from: buffer.format)
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AppAudioRecorderError.conversionFailed
        }

        // Hand the converter one buffer, then report "no data now" rather
        // than end of stream, so it keeps its resampler state for the next
        // buffer (the same approach as AudioRecorder.convertBuffer).
        var suppliedInput = false
        var conversionError: NSError?
        let status = activeConverter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if conversionError != nil || status == .error {
            throw AppAudioRecorderError.conversionFailed
        }
        guard output.frameLength > 0 else { return nil }

        try file.write(from: output)
        framesWritten += AVAudioFramePosition(output.frameLength)
        return output
    }

    /// Releases the AVAudioFile, which finalizes the WAV header sizes, and
    /// returns the number of frames written.
    @discardableResult
    func finish() -> AVAudioFramePosition {
        file = nil
        converter = nil
        return framesWritten
    }

    private func makeConverter(from format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converter.inputFormat == format {
            return converter
        }
        guard let created = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw AppAudioRecorderError.conversionFailed
        }
        converter = created
        return created
    }
}

/// Turns 16 kHz Int16 audio into the waveform level, with the same RMS as
/// the macOS AudioRecorder.rmsLevel and the shared LiveAudioLevelNormalizer.
/// The normalizer smooths per call, so it is fed 20 ms blocks no matter how
/// large the capture buffers are.
struct AppRecorderLevelMeter {
    static let blockFrames = 320

    private var normalizer = LiveAudioLevelNormalizer()
    private(set) var level: Float = 0
    /// True once any block had a non-zero RMS, which is when macOS treats
    /// the recording as started.
    private(set) var hasHeardAudio = false

    @discardableResult
    mutating func consume(_ samples: UnsafeBufferPointer<Int16>) -> Float {
        var start = 0
        while start < samples.count {
            let end = min(start + Self.blockFrames, samples.count)
            let rms = Self.rms(samples[start..<end])
            if rms > 0 {
                hasHeardAudio = true
            }
            level = normalizer.normalizedLevel(forRMS: rms)
            start = end
        }
        return level
    }

    @discardableResult
    mutating func consume(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatInt16,
              let channels = buffer.int16ChannelData else {
            return level
        }
        return consume(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }

    static func rms(_ samples: Slice<UnsafeBufferPointer<Int16>>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample) / 32768.0
            sumOfSquares += value * value
        }
        return Float((sumOfSquares / Double(samples.count)).squareRoot())
    }
}
