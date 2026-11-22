import AVFoundation
import XCTest
@testable import FreeFlow

/// The app recorder's file format, checked with synthetic sine waves (no
/// microphone): 16 kHz, mono, 16-bit PCM WAV, like the macOS AudioRecorder.
final class AppRecordingWAVWriterTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testWritesSixteenKilohertzMonoInt16WAVFromFortyEightKilohertzFloat() throws {
        let url = makeURL()
        let writer = try AppRecordingWAVWriter(fileURL: url)
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var phase = 0.0
        var convertedFrames: AVAudioFrameCount = 0
        for _ in 0..<10 {
            let buffer = try makeSine(format: source, frames: 4_800, phase: &phase)
            convertedFrames += try writer.append(buffer)?.frameLength ?? 0
        }
        let frames = writer.finish()

        XCTAssertEqual(AVAudioFramePosition(convertedFrames), frames)
        XCTAssertGreaterThan(frames, 15_500, "One second at 16 kHz, minus resampler latency")
        XCTAssertLessThanOrEqual(frames, 16_000)

        let wav = try WAVInfo(data: Data(contentsOf: url))
        XCTAssertTrue([UInt16(1), UInt16(0xFFFE)].contains(wav.formatTag), "format tag \(wav.formatTag)")
        XCTAssertEqual(wav.channels, 1)
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.bitsPerSample, 16)
        XCTAssertEqual(wav.blockAlign, 2)
        XCTAssertEqual(wav.byteRate, 32_000)
        XCTAssertEqual(wav.dataByteCount, Int(frames) * 2)
        XCTAssertGreaterThan(wav.peakSample, 5_000, "The tone survives conversion")
        // Recorded for the e2e mock provider's WAV parser; header facts only.
        print("App recorder WAV: format tag \(wav.formatTag), chunks \(wav.chunkIDs)")
    }

    func testConvertsStereoFortyFourKilohertzToMono() throws {
        let url = makeURL()
        let writer = try AppRecordingWAVWriter(fileURL: url)
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        var phase = 0.0
        for _ in 0..<5 {
            _ = try writer.append(try makeSine(format: source, frames: 4_410, phase: &phase))
        }
        let frames = writer.finish()

        XCTAssertGreaterThan(frames, 7_500)
        XCTAssertLessThanOrEqual(frames, 8_000)
        let wav = try WAVInfo(data: Data(contentsOf: url))
        XCTAssertEqual(wav.channels, 1)
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.dataByteCount, Int(frames) * 2)
        XCTAssertGreaterThan(wav.peakSample, 5_000)
    }

    func testTargetFormatBuffersAreWrittenAsIs() throws {
        let url = makeURL()
        let writer = try AppRecordingWAVWriter(fileURL: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AppRecordingWAVWriter.targetFormat, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for index in 0..<1_600 {
            samples[index] = Int16(index % 2 == 0 ? 1_000 : -1_000)
        }

        XCTAssertEqual(try writer.append(buffer)?.frameLength, 1_600)
        XCTAssertEqual(writer.finish(), 1_600)
        XCTAssertEqual(try WAVInfo(data: Data(contentsOf: url)).dataByteCount, 3_200)
    }

    func testEmptyBuffersAreIgnored() throws {
        let writer = try AppRecordingWAVWriter(fileURL: makeURL())
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 512))

        XCTAssertNil(try writer.append(empty))
        XCTAssertEqual(writer.finish(), 0)
    }

    func testLevelMeterIsSilentForSilenceAndRisesForATone() {
        var silentMeter = AppRecorderLevelMeter()
        let silence = [Int16](repeating: 0, count: 3_200)
        let silentLevel = silence.withUnsafeBufferPointer { silentMeter.consume($0) }
        XCTAssertEqual(silentLevel, 0)
        XCTAssertFalse(silentMeter.hasHeardAudio)

        var toneMeter = AppRecorderLevelMeter()
        // Explicit types and steps: Xcode 27's type checker times out on the one-line form.
        let radiansPerSample: Double = 2 * Double.pi * 440 / 16_000
        let tone: [Int16] = (0..<3_200).map { (index: Int) -> Int16 in
            let sample: Double = sin(Double(index) * radiansPerSample) * 12_000
            return Int16(sample)
        }
        let toneLevel = tone.withUnsafeBufferPointer { toneMeter.consume($0) }
        XCTAssertGreaterThan(toneLevel, 0.1)
        XCTAssertLessThanOrEqual(toneLevel, 1)
        XCTAssertTrue(toneMeter.hasHeardAudio)
    }

    func testRMSMatchesTheMacOSFormula() {
        let samples: [Int16] = [16_384, -16_384, 16_384, -16_384]
        let rms = samples.withUnsafeBufferPointer { AppRecorderLevelMeter.rms($0[...]) }
        XCTAssertEqual(rms, 0.5, accuracy: 0.0001)
    }

    func testRemovesOnlyLeftoverRecordings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryFiles.append(directory)
        let leftover = directory.appendingPathComponent("\(AppAudioRecorder.fileNamePrefix)old.wav")
        let unrelatedWAV = directory.appendingPathComponent("other.wav")
        let unrelatedText = directory.appendingPathComponent("\(AppAudioRecorder.fileNamePrefix)notes.txt")
        for url in [leftover, unrelatedWAV, unrelatedText] {
            try Data("synthetic".utf8).write(to: url)
        }

        AppAudioRecorder.removeLeftoverRecordings(in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedWAV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedText.path))
    }

    func testRecordingURLsAreTemporaryWAVFiles() {
        let url = AppAudioRecorder.makeRecordingURL()
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertTrue(url.lastPathComponent.hasPrefix(AppAudioRecorder.fileNamePrefix))
        XCTAssertEqual(url.deletingLastPathComponent().path, FileManager.default.temporaryDirectory.path)
    }

    func testSyntheticRecorderWritesAPlayableFile() throws {
        let recorder = AppAudioRecorder(usesSyntheticInput: true)
        let firstAudio = expectation(description: "first audio")
        firstAudio.assertForOverFulfill = false
        recorder.onFirstAudio = {
            firstAudio.fulfill()
        }
        let url = makeURL()

        try recorder.start(writingTo: url)
        wait(for: [firstAudio], timeout: 5)
        Thread.sleep(forTimeInterval: 0.5)
        let summary = try XCTUnwrap(recorder.stop())

        XCTAssertEqual(summary.fileURL, url)
        XCTAssertGreaterThan(summary.duration, 0.3)
        let wav = try WAVInfo(data: Data(contentsOf: url))
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertGreaterThan(wav.peakSample, 5_000)
    }

    func testCancelledSyntheticRecordingDeletesTheFile() throws {
        let recorder = AppAudioRecorder(usesSyntheticInput: true)
        let url = makeURL()

        try recorder.start(writingTo: url)
        recorder.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(recorder.stop())
    }

    // MARK: Helpers

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-app-tests-\(UUID().uuidString).wav")
        temporaryFiles.append(url)
        return url
    }

    /// A 440 Hz sine at about -10 dBFS in every channel.
    private func makeSine(format: AVAudioFormat, frames: AVAudioFrameCount, phase: inout Double) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let step = 2 * Double.pi * 440 / format.sampleRate
        for frame in 0..<Int(frames) {
            let value = Float(sin(phase) * 0.316)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
            phase += step
        }
        return buffer
    }
}

/// Minimal RIFF/WAVE reader: walks the chunks rather than assuming a
/// 44-byte header, since Core Audio may add padding chunks.
private struct WAVInfo {
    var formatTag: UInt16 = 0
    var channels: UInt16 = 0
    var sampleRate: UInt32 = 0
    var byteRate: UInt32 = 0
    var blockAlign: UInt16 = 0
    var bitsPerSample: UInt16 = 0
    var dataByteCount = 0
    var peakSample = 0
    var chunkIDs: [String] = []

    struct Malformed: Error {}

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw Malformed()
        }
        var offset = 12
        var sawFormat = false
        var sawData = false
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(Self.uint32(bytes, offset + 4))
            let body = offset + 8
            chunkIDs.append(id)
            if id == "fmt " {
                guard body + 16 <= bytes.count else { throw Malformed() }
                formatTag = Self.uint16(bytes, body)
                channels = Self.uint16(bytes, body + 2)
                sampleRate = Self.uint32(bytes, body + 4)
                byteRate = Self.uint32(bytes, body + 8)
                blockAlign = Self.uint16(bytes, body + 12)
                bitsPerSample = Self.uint16(bytes, body + 14)
                sawFormat = true
            } else if id == "data" {
                let end = min(body + size, bytes.count)
                dataByteCount = end - body
                var index = body
                while index + 1 < end {
                    let sample = Int(Int16(bitPattern: Self.uint16(bytes, index)))
                    peakSample = max(peakSample, abs(sample))
                    index += 2
                }
                sawData = true
            }
            offset = body + size + (size % 2)
        }
        guard sawFormat, sawData else { throw Malformed() }
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
