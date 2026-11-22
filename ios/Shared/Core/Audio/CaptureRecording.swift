import Foundation

/// One recording from the capture page. It validates the page's chunks, streams them into a
/// WAV file, measures loudness for the upload gain and smooths levels for the waveform.
///
/// It is Foundation-only, so the macOS tests can drive it with the page's real JavaScript in
/// JavaScriptCore. WebAudioCapture owns one per capture session.
final class CaptureRecording {
    static let sampleRate = 16_000
    /// Fewer frames than this (0.01 s, Groq's minimum) counts as no audio.
    static let minimumFrameCount = 160

    struct ChunkOutcome: Equatable {
        /// True for the first chunk whose level is above zero.
        let becameAudible: Bool
        /// The waveform level after this chunk, in 0...1, once audio is audible.
        let displayLevel: Float?
        /// The chunk repeated a sequence number and was ignored.
        let wasDuplicate: Bool
    }

    struct Finished: Equatable {
        let fileURL: URL
        let frameCount: Int
        let sampleRate: Int
        let loudness: LoudnessSummary
        let gain: UploadGainPolicy.Decision
        let skippedChunks: Int
    }

    let session: Int
    let fileURL: URL
    private let writer: StreamingWAVWriter
    private var decoder = PCMChunkDecoder()
    private var analyzer = LoudnessAnalyzer()
    private var levelNormalizer = LiveAudioLevelNormalizer()
    private(set) var isAudible = false

    init(session: Int, fileURL: URL) throws {
        self.session = session
        self.fileURL = fileURL
        writer = try StreamingWAVWriter(url: fileURL, sampleRate: Self.sampleRate)
    }

    var frameCount: Int { writer.frameCount }
    var skippedChunks: Int { decoder.skippedChunks }
    var isFinished: Bool { writer.isFinished }

    /// Decodes and stores a chunk. Throws `PCMChunkDecoder.Failure` for a malformed chunk and
    /// file errors from the writer.
    func append(_ chunk: PCMChunk) throws -> ChunkOutcome {
        let samples: [Int16]
        do {
            samples = try decoder.decode(chunk)
        } catch PCMChunkDecoder.Failure.duplicateSequence(_) {
            return ChunkOutcome(becameAudible: false, displayLevel: nil, wasDuplicate: true)
        }
        try writer.append(samples)
        analyzer.ingest(samples)

        var becameAudible = false
        if !isAudible, let loudest = chunk.levels.max(), loudest > 0 {
            isAudible = true
            becameAudible = true
        }
        var displayLevel: Float?
        if isAudible {
            for level in chunk.levels {
                displayLevel = levelNormalizer.normalizedLevel(forRMS: level)
            }
        }
        return ChunkOutcome(becameAudible: becameAudible, displayLevel: displayLevel, wasDuplicate: false)
    }

    /// Finishes the file and applies the upload gain in place. Returns nil, and deletes the
    /// file, when it holds fewer than `minimumFrameCount` frames.
    func finish(limits: UploadGainPolicy.Limits = UploadGainPolicy.Limits()) throws -> Finished? {
        let frames = try writer.finish()
        guard frames >= Self.minimumFrameCount else {
            discard()
            return nil
        }
        let loudness = analyzer.summary()
        let decision = UploadGainPolicy.decide(loudness, limits: limits)
        if case .apply(let gainDB) = decision {
            try StreamingWAVWriter.applyGain(gainDB, toWAVAt: fileURL)
        }
        return Finished(
            fileURL: fileURL,
            frameCount: frames,
            sampleRate: Self.sampleRate,
            loudness: loudness,
            gain: decision,
            skippedChunks: decoder.skippedChunks
        )
    }

    /// Closes and deletes the file.
    func discard() {
        writer.discard()
    }
}
