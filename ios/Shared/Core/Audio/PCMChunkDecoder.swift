import Foundation

/// Validates and decodes the capture page's `pcm` chunks for one session, in order.
struct PCMChunkDecoder {
    enum Failure: Error, Equatable {
        case invalidBase64
        case oddByteCount(Int)
        case frameCountMismatch(declared: Int, decoded: Int)
        /// The sequence number was already decoded (or is older than one that was).
        case duplicateSequence(Int)
        case chunkTooLarge(Int)
    }

    /// About one second at 16 kHz; the page sends about 683 frames per chunk.
    static let maxFramesPerChunk = 16_384
    static let maxBase64Length = (maxFramesPerChunk * 2 + 2) / 3 * 4

    private(set) var expectedSequence = 0
    /// Chunks the sequence numbers say were never received.
    private(set) var skippedChunks = 0
    private(set) var totalFrames = 0

    mutating func decode(_ chunk: PCMChunk) throws -> [Int16] {
        guard chunk.sequence >= expectedSequence else {
            throw Failure.duplicateSequence(chunk.sequence)
        }
        guard chunk.frameCount <= Self.maxFramesPerChunk else {
            throw Failure.chunkTooLarge(chunk.frameCount)
        }
        guard chunk.base64.utf8.count <= Self.maxBase64Length else {
            throw Failure.chunkTooLarge(chunk.base64.utf8.count * 3 / 8)
        }
        guard let data = Data(base64Encoded: chunk.base64) else {
            throw Failure.invalidBase64
        }
        guard data.count % 2 == 0 else {
            throw Failure.oddByteCount(data.count)
        }
        let samples = (try? PCM16.decodeLittleEndian(data)) ?? []
        guard samples.count == chunk.frameCount else {
            throw Failure.frameCountMismatch(declared: chunk.frameCount, decoded: samples.count)
        }

        skippedChunks += chunk.sequence - expectedSequence
        expectedSequence = chunk.sequence + 1
        totalFrames += samples.count
        return samples
    }
}
