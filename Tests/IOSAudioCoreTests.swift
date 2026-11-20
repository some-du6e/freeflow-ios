import Foundation
import JavaScriptCore

/// Tests for the Foundation-only iOS audio helpers in ios/Shared/Core/Audio. The capture
/// page's JavaScript runs here too, in JavaScriptCore, against mocked Web Audio and a native
/// side built from the same Core types WebAudioCapture uses.
enum IOSAudioCoreTests {
    static func run() {
        testPCM16MatchesTheJavaScriptConversion()
        testPCM16LittleEndianRoundTripAndGoldenBase64()
        testPCM16GainRoundsAndClamps()
        testParsesEveryPageMessage()
        testRejectsMalformedPageMessages()
        testFailureNamesAndTokens()
        testChunkDecoderValidatesAndCountsGaps()
        testLevelMeterMatchesAudioRecorder()
        testLiveAudioLevelNormalizerGoldenSequence()
        testLoudnessAnalyzerPercentiles()
        testLoudnessAnalyzerIsChunkInvariant()
        testGainPolicyDecisions()
        testGainPolicyOnSyntheticSpeechAndNoise()
        testWAVHeaderGoldenBytes()
        testWAVParsingAndDecoding()
        testStreamingWriterMatchesOneShotEncoding()
        testApplyGainInPlace()
        testWriterFinishDiscardAndErrors()
        testCaptureRecordingFinishesAndRejectsShortClips()
        testCapturePageHTML()
        testJavaScriptCoreRunsPromiseJobs()
        testJavaScriptInt16AndBase64MatchSwift()
        testJavaScriptResamplerResponse()
        testJavaScriptCaptureSessionEndToEnd()
        testJavaScriptDeadManSwitch()
        testJavaScriptStopTimeoutCancelAndStaleSessions()
        testJavaScriptFailures()
        testJavaScriptSyntheticSource()
        testJavaScriptInterruptions()
    }

    // MARK: PCM16

    private static func testPCM16MatchesTheJavaScriptConversion() {
        let cases: [(Float, Int16)] = [
            (0, 0), (1, 32_767), (-1, -32_767), (0.5, 16_384), (-0.5, -16_383), (2, 32_767), (-2, -32_767),
            (.nan, 0), (.infinity, 32_767), (-.infinity, -32_767), (1e-30, 0), (-1e-30, 0),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(PCM16.sample(fromUnit: input), expected)
        }
        TestSupport.expectEqual(PCM16.unit(-32_768), -1)
        TestSupport.expectEqual(PCM16.unit(16_384), 0.5)
    }

    private static func testPCM16LittleEndianRoundTripAndGoldenBase64() {
        // The capture page's output for [0, 1, -1, 0.5, -0.5, 2].
        let golden: [Int16] = [0, 32_767, -32_767, 16_384, -16_383, 32_767]
        TestSupport.expectEqual(PCM16.encodeLittleEndian(golden).base64EncodedString(), "AAD/fwGAAEABwP9/")
        TestSupport.expectEqual(try? PCM16.decodeLittleEndian(Data(base64Encoded: "AAD/fwGAAEABwP9/")!), golden)

        let extremes: [Int16] = [.min, .max, -1, 1, 0x1234]
        TestSupport.expectEqual(try? PCM16.decodeLittleEndian(PCM16.encodeLittleEndian(extremes)), extremes)
        TestSupport.expectEqual(PCM16.encodeLittleEndian([Int16(0x1234)]), Data([0x34, 0x12]))
        TestSupport.expectEqual(try? PCM16.decodeLittleEndian(Data([9, 0x34, 0x12]).dropFirst()), [0x1234])
        TestSupport.expectEqual(PCM16.encodeLittleEndian(extremes[1...2]), Data([0xFF, 0x7F, 0xFF, 0xFF]))

        do {
            _ = try PCM16.decodeLittleEndian(Data([1, 2, 3]))
            TestSupport.expect(false, "An odd byte count must not decode")
        } catch {
            TestSupport.expectEqual(error as? PCM16.DecodingError, .oddByteCount(3))
        }
    }

    private static func testPCM16GainRoundsAndClamps() {
        var samples: [Int16] = [0, 1, -1, 100, -100, 20_000, -20_000, .max, .min]
        PCM16.apply(gainDB: 20 * log10f(2), to: &samples)
        TestSupport.expectEqual(samples, [0, 2, -2, 200, -200, 32_767, -32_768, 32_767, -32_768])
        TestSupport.expectEqual(PCM16.scaled(3, by: 0.5), 2)
        TestSupport.expectEqual(PCM16.scaled(-3, by: 0.5), -2)
        TestSupport.expectApproximatelyEqual(PCM16.linearFactor(forGainDB: 20), 10, accuracy: 1e-9)
    }

    // MARK: Page messages

    private static func testParsesEveryPageMessage() {
        // WebKit delivers numbers as NSNumber doubles and booleans as CFBoolean.
        let ready: NSDictionary = ["t": "ready", "v": NSNumber(value: 1.0), "synthetic": true]
        TestSupport.expectEqual(CaptureMessage(body: ready), .ready(pageVersion: 1, hasSyntheticSource: true))

        let started: NSDictionary = [
            "t": "started", "sid": NSNumber(value: 3.0), "rate": NSNumber(value: 48_000.0),
            "captureRate": NSNumber(value: 44_100.0), "synthetic": false,
        ]
        TestSupport.expectEqual(
            CaptureMessage(body: started),
            .started(session: 3, contextRate: 48_000, captureRate: 44_100, isSynthetic: false)
        )

        let pcm: NSDictionary = [
            "t": "pcm", "sid": 3, "seq": NSNumber(value: 4.0), "n": 2, "b64": "AQACAA==",
            "lv": [NSNumber(value: 0.25), NSNumber(value: 0.5)], "final": true,
        ]
        let chunk = PCMChunk(session: 3, sequence: 4, frameCount: 2, base64: "AQACAA==", levels: [0.25, 0.5], isFinal: true)
        TestSupport.expectEqual(CaptureMessage(body: pcm), .pcm(chunk))
        TestSupport.expectEqual(CaptureMessage(body: pcm)?.session, 3)

        let ended: NSDictionary = ["t": "ended", "sid": 3, "reason": "native-unresponsive", "frames": 683]
        TestSupport.expectEqual(CaptureMessage(body: ended), .ended(session: 3, reason: "native-unresponsive", frames: 683))

        let failed: NSDictionary = ["t": "failed", "sid": 5, "name": "NotAllowedError"]
        TestSupport.expectEqual(CaptureMessage(body: failed), .failed(session: 5, name: "NotAllowedError"))
        TestSupport.expectEqual(CaptureMessage(body: failed)?.session, 5)
        TestSupport.expectEqual(CaptureMessage(body: ready)?.session, nil)

        let unknownRate: NSDictionary = ["t": "started", "sid": 1, "rate": 16_000]
        TestSupport.expectEqual(
            CaptureMessage(body: unknownRate),
            .started(session: 1, contextRate: 16_000, captureRate: 0, isSynthetic: false)
        )
    }

    private static func testRejectsMalformedPageMessages() {
        let valid: [String: Any] = ["t": "pcm", "sid": 1, "seq": 0, "n": 1, "b64": "AQA=", "lv": [0.1], "final": false]
        TestSupport.expect(CaptureMessage(body: valid) != nil, "The baseline pcm message must parse")

        let broken: [(String, Any)] = [
            ("seq", -1), ("seq", 1.5), ("seq", true), ("seq", "0"), ("n", 2.5), ("n", -3),
            ("sid", false), ("b64", 12), ("lv", [Double.nan]), ("lv", [-0.1]), ("lv", ["0.1"]),
            ("lv", 0.1), ("lv", [Double](repeating: 0.1, count: 65)), ("final", 0), ("final", "false"),
        ]
        for (key, value) in broken {
            var body = valid
            body[key] = value
            TestSupport.expect(CaptureMessage(body: body) == nil, "pcm with \(key)=\(value) must be rejected")
        }
        var missing = valid
        missing["b64"] = nil
        TestSupport.expect(CaptureMessage(body: missing) == nil, "pcm without b64 must be rejected")

        TestSupport.expect(CaptureMessage(body: "pcm") == nil, "A string body must be rejected")
        TestSupport.expect(CaptureMessage(body: ["type": "ready"]) == nil, "A body without t must be rejected")
        TestSupport.expect(CaptureMessage(body: ["t": "launch"]) == nil, "An unknown type must be rejected")
        let zeroRate: [String: Any] = ["t": "started", "sid": 1, "rate": 0]
        TestSupport.expect(CaptureMessage(body: zeroRate) == nil, "A zero rate must be rejected")
        TestSupport.expect(CaptureMessage(body: ["t": "ended", "reason": "stopped"]) == nil, "ended needs a session")
        let hugeSession: [String: Any] = ["t": "failed", "sid": 9_007_199_254_740_992.0, "name": "x"]
        TestSupport.expect(CaptureMessage(body: hugeSession) == nil, "Session ids JavaScript can't represent exactly must be rejected")
    }

    private static func testFailureNamesAndTokens() {
        TestSupport.expectEqual(CaptureMessage.failureKind(forName: "NotAllowedError"), .permissionDenied)
        for name in ["NotFoundError", "NotReadableError", "SecurityError", "MediaDevicesUnavailable", "UnsupportedRateError", "unknown"] {
            TestSupport.expectEqual(CaptureMessage.failureKind(forName: name), .unsupported)
        }

        TestSupport.expectEqual(CaptureMessage.token("track-ended"), "track-ended")
        TestSupport.expectEqual(CaptureMessage.token("context-interrupted"), "context-interrupted")
        TestSupport.expectEqual(CaptureMessage.token("Not Allowed\n<Error>"), "NotAllowedError")
        TestSupport.expectEqual(CaptureMessage.token(String(repeating: "x", count: 100)).count, CaptureMessage.maxTokenLength)
        TestSupport.expectEqual(CaptureMessage.token(42), "unknown")
        TestSupport.expectEqual(CaptureMessage.token(""), "unknown")
        TestSupport.expectEqual(CaptureMessage.token("日本語"), "unknown")
        let unsafeReason: [String: Any] = ["t": "ended", "sid": 1, "reason": "stopped; rm -rf", "frames": -4]
        TestSupport.expectEqual(CaptureMessage(body: unsafeReason), .ended(session: 1, reason: "stoppedrm-rf", frames: 0))
    }

    private static func testChunkDecoderValidatesAndCountsGaps() {
        func chunk(_ sequence: Int, _ samples: [Int16], declared: Int? = nil, base64: String? = nil) -> PCMChunk {
            PCMChunk(
                session: 1,
                sequence: sequence,
                frameCount: declared ?? samples.count,
                base64: base64 ?? PCM16.encodeLittleEndian(samples).base64EncodedString(),
                levels: [],
                isFinal: false
            )
        }
        var decoder = PCMChunkDecoder()
        TestSupport.expectEqual(try? decoder.decode(chunk(0, [1, 2, 3])), [1, 2, 3])
        TestSupport.expectEqual(try? decoder.decode(chunk(2, [4])), [4])
        TestSupport.expectEqual(decoder.skippedChunks, 1)
        TestSupport.expectEqual(decoder.expectedSequence, 3)
        TestSupport.expectEqual(decoder.totalFrames, 4)

        expectDecodeFailure(.duplicateSequence(2)) { _ = try decoder.decode(chunk(2, [5])) }
        expectDecodeFailure(.duplicateSequence(0)) { _ = try decoder.decode(chunk(0, [5])) }
        expectDecodeFailure(.invalidBase64) { _ = try decoder.decode(chunk(3, [], declared: 1, base64: "!!!!")) }
        expectDecodeFailure(.oddByteCount(3)) { _ = try decoder.decode(chunk(3, [], declared: 1, base64: "AQID")) }
        expectDecodeFailure(.frameCountMismatch(declared: 2, decoded: 1)) { _ = try decoder.decode(chunk(3, [7], declared: 2)) }
        expectDecodeFailure(.chunkTooLarge(16_385)) { _ = try decoder.decode(chunk(3, [], declared: 16_385)) }
        let oversized = String(repeating: "A", count: PCMChunkDecoder.maxBase64Length + 4)
        expectDecodeFailure(.chunkTooLarge((PCMChunkDecoder.maxBase64Length + 4) * 3 / 8)) {
            _ = try decoder.decode(chunk(3, [], declared: 0, base64: oversized))
        }
        TestSupport.expectEqual(decoder.expectedSequence, 3)
        TestSupport.expectEqual(decoder.totalFrames, 4)

        // The final chunk of a session can hold no frames at all.
        TestSupport.expectEqual(try? decoder.decode(chunk(3, [])), [])
        TestSupport.expectEqual(decoder.expectedSequence, 4)
    }

    private static func expectDecodeFailure(
        _ expected: PCMChunkDecoder.Failure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            TestSupport.expect(false, "Expected \(expected)", file: file, line: line)
        } catch {
            TestSupport.expectEqual(error as? PCMChunkDecoder.Failure, expected, file: file, line: line)
        }
    }

    // MARK: Levels and loudness

    private static func testLevelMeterMatchesAudioRecorder() {
        let samples: [Int16] = [0, 16_384, -16_384, 32_767, -32_768, 1_000]
        var sumOfSquares: Double = 0
        for sample in samples {
            let value = Double(sample) / 32_768.0
            sumOfSquares += value * value
        }
        TestSupport.expectEqual(LevelMeter.rms(samples), Float(sqrt(sumOfSquares / Double(samples.count))))
        TestSupport.expectEqual(LevelMeter.rms([Int16]()), 0)
        TestSupport.expectApproximatelyEqual(Double(LevelMeter.rms([Float](repeating: -0.5, count: 10))), 0.5)
        TestSupport.expectEqual(LevelMeter.blockRMS([1, 1, 2, 2, 3], blockFrames: 2).count, 3)
        TestSupport.expectEqual(LevelMeter.blockRMS([1, 2], blockFrames: 0), [])

        let sine = tone(frequency: 1_000, amplitude: 1, frames: 1_600)
        TestSupport.expectApproximatelyEqual(
            Double(LevelMeter.decibels(fromRMS: Double(LevelMeter.rms(sine)))),
            -3.01,
            accuracy: 0.05
        )
        TestSupport.expectEqual(LevelMeter.decibels(fromRMS: 0), -120)
        TestSupport.expectEqual(LevelMeter.decibels(fromRMS: 1e-9), -120)
    }

    /// Pins the waveform smoothing the keyboard shares with macOS, at the page's ~21 ms
    /// level cadence. Values come from an independent float32 port of the algorithm.
    private static func testLiveAudioLevelNormalizerGoldenSequence() {
        var inputs: [Float] = []
        for (level, count) in [(Float(0), 4), (0.0005, 4), (0.02, 6), (0.1, 4), (0.003, 6), (0, 4)] {
            inputs += [Float](repeating: level, count: count)
        }
        let golden: [Double] = [
            0, 0, 0, 0, 0.075774, 0.118600, 0.143292, 0.157997, 0.488376, 0.654175, 0.738610, 0.782086,
            0.804679, 0.816515, 0.885245, 0.896992, 0.895852, 0.893608, 0.832064, 0.778808, 0.732843,
            0.693291, 0.659381, 0.630430, 0.554778, 0.488205, 0.429620, 0.378066,
        ]
        var normalizer = LiveAudioLevelNormalizer()
        TestSupport.expectEqual(inputs.count, golden.count)
        for (input, expected) in zip(inputs, golden) {
            TestSupport.expectApproximatelyEqual(Double(normalizer.normalizedLevel(forRMS: input)), expected, accuracy: 1e-4)
        }
    }

    private static func testLoudnessAnalyzerPercentiles() {
        var analyzer = LoudnessAnalyzer()
        TestSupport.expectEqual(
            analyzer.summary(),
            LoudnessSummary(frames: 0, peakDBFS: -120, speechDBFS: -120, noiseFloorDBFS: -120)
        )

        // 20 quiet blocks (-63 dBFS RMS) then 80 loud ones (-23 dBFS RMS, -20 dBFS peak).
        analyzer.ingest(tone(frequency: 1_000, amplitude: 0.001, frames: 20 * 320))
        analyzer.ingest(tone(frequency: 1_000, amplitude: 0.1, frames: 80 * 320))
        let summary = analyzer.summary()
        TestSupport.expectEqual(summary.frames, 32_000)
        TestSupport.expectApproximatelyEqual(Double(summary.speechDBFS), -23.01, accuracy: 0.5)
        TestSupport.expectApproximatelyEqual(Double(summary.noiseFloorDBFS), -63.0, accuracy: 0.5)
        TestSupport.expectApproximatelyEqual(Double(summary.peakDBFS), -20.0, accuracy: 0.05)

        // A clip shorter than one block counts as one block.
        var short = LoudnessAnalyzer()
        short.ingest(tone(frequency: 1_000, amplitude: 0.1, frames: 160))
        let shortSummary = short.summary()
        TestSupport.expectEqual(shortSummary.frames, 160)
        TestSupport.expectApproximatelyEqual(Double(shortSummary.speechDBFS), -23.01, accuracy: 0.5)
        TestSupport.expectEqual(shortSummary.speechDBFS, shortSummary.noiseFloorDBFS)

        var fullScale = LoudnessAnalyzer()
        fullScale.ingest([Int16.min, 0, 0, 0])
        TestSupport.expectEqual(fullScale.summary().peakDBFS, 0)
    }

    private static func testLoudnessAnalyzerIsChunkInvariant() {
        let samples = speechAndNoise(seconds: 1.5)
        var whole = LoudnessAnalyzer()
        whole.ingest(samples)
        for chunkSize in [1, 7, 683, 4_096] {
            var chunked = LoudnessAnalyzer()
            var start = 0
            while start < samples.count {
                chunked.ingest(samples[start..<min(start + chunkSize, samples.count)])
                start += chunkSize
            }
            TestSupport.expectEqual(chunked.summary(), whole.summary())
        }
    }

    private static func testGainPolicyDecisions() {
        func decide(peak: Float, speech: Float, floor: Float, frames: Int = 16_000) -> UploadGainPolicy.Decision {
            UploadGainPolicy.decide(LoudnessSummary(frames: frames, peakDBFS: peak, speechDBFS: speech, noiseFloorDBFS: floor))
        }
        // The worked example: quiet speech over a low floor gets +22 dB.
        TestSupport.expectEqual(decide(peak: -24, speech: -42, floor: -72), .apply(gainDB: 22))
        TestSupport.expectEqual(decide(peak: -24, speech: -42, floor: -72).gainDB, 22)
        TestSupport.expectEqual(decide(peak: -24, speech: -42, floor: -72, frames: 0), .unchanged(.empty))
        // Silence and noise-only clips are left alone.
        TestSupport.expectEqual(decide(peak: -60, speech: -75, floor: -90), .unchanged(.noSpeech))
        TestSupport.expectEqual(decide(peak: -30, speech: -50, floor: -54), .unchanged(.noSpeech))
        // Never attenuate, and skip gains under 0.5 dB.
        TestSupport.expectEqual(decide(peak: -3, speech: -18, floor: -60), .unchanged(.noHeadroom))
        TestSupport.expectEqual(decide(peak: -1.2, speech: -30, floor: -70), .unchanged(.noHeadroom))
        TestSupport.expectEqual(decide(peak: -3, speech: -18, floor: -60).gainDB, 0)
        // Each limit can be the binding one.
        TestSupport.expectEqual(decide(peak: -60, speech: -66, floor: -90), .apply(gainDB: 24))
        TestSupport.expectEqual(decide(peak: -10, speech: -40, floor: -80), .apply(gainDB: 9))
        TestSupport.expectEqual(decide(peak: -30, speech: -45, floor: -60), .apply(gainDB: 10))
        TestSupport.expectEqual(UploadGainPolicy.Decision.Reason.noSpeech.rawValue, "no-speech")
    }

    private static func testGainPolicyOnSyntheticSpeechAndNoise() {
        var samples = speechAndNoise(seconds: 2)
        var analyzer = LoudnessAnalyzer()
        analyzer.ingest(samples)
        let summary = analyzer.summary()
        let decision = UploadGainPolicy.decide(summary)
        guard case .apply(let gainDB) = decision else {
            TestSupport.expect(false, "Quiet speech over a low floor must be boosted, got \(decision) for \(summary)")
            return
        }
        TestSupport.expectApproximatelyEqual(Double(gainDB), 22, accuracy: 1)

        PCM16.apply(gainDB: gainDB, to: &samples)
        var boosted = LoudnessAnalyzer()
        boosted.ingest(samples)
        let after = boosted.summary()
        TestSupport.expect(after.peakDBFS <= -1, "Gain must never push the peak above -1 dBFS: \(after)")
        TestSupport.expectApproximatelyEqual(Double(after.speechDBFS), -20, accuracy: 1)
        TestSupport.expect(after.noiseFloorDBFS <= -49, "Gain must keep the floor near -50 dBFS: \(after)")

        var noiseOnly = LoudnessAnalyzer()
        noiseOnly.ingest(noise(rmsDBFS: -60, frames: 16_000, seed: 3))
        TestSupport.expectEqual(UploadGainPolicy.decide(noiseOnly.summary()), .unchanged(.noSpeech))
    }

    // MARK: WAV

    private static func testWAVHeaderGoldenBytes() {
        let header = WAVEncoder.header(dataByteCount: 32_000)
        TestSupport.expectEqual(header.count, WAVEncoder.headerByteCount)
        TestSupport.expectEqual(
            hex(header),
            "52494646" + "247D0000" + "57415645" + "666D7420" + "10000000" + "0100" + "0100"
                + "803E0000" + "007D0000" + "0200" + "1000" + "64617461" + "007D0000"
        )
        TestSupport.expectEqual(
            WAVEncoder.parseHeader(header),
            WAVEncoder.Format(audioFormat: 1, channels: 1, sampleRate: 16_000, bitsPerSample: 16, dataOffset: 44, dataByteCount: 32_000)
        )
    }

    private static func testWAVParsingAndDecoding() {
        let samples: [Int16] = [1, -2, 3, .max, .min]
        let wav = WAVEncoder.encode(samples)
        TestSupport.expectEqual(wav.count, 44 + 10)
        TestSupport.expectEqual(WAVEncoder.decode(wav)?.samples, samples)
        TestSupport.expectEqual(WAVEncoder.decode(wav)?.sampleRate, 16_000)
        TestSupport.expectEqual(WAVEncoder.decode(wav)?.channels, 1)

        // Another writer's file with a LIST chunk (odd-sized, so padded) before data.
        var extended = Data(wav[0..<36])
        extended.append(contentsOf: Array("LIST".utf8))
        extended.append(contentsOf: [5, 0, 0, 0])
        extended.append(contentsOf: Array("INFOx".utf8))
        extended.append(0)
        extended.append(wav[36...])
        TestSupport.expectEqual(WAVEncoder.parseHeader(extended)?.dataOffset, 58)
        TestSupport.expectEqual(WAVEncoder.decode(extended)?.samples, samples)

        var float32 = wav
        float32[20] = 3
        TestSupport.expectEqual(WAVEncoder.parseHeader(float32)?.audioFormat, 3)
        TestSupport.expect(WAVEncoder.decode(float32) == nil, "Non-PCM audio must not decode")
        var rifx = wav
        rifx[3] = UInt8(ascii: "X")
        TestSupport.expect(WAVEncoder.parseHeader(rifx) == nil, "A RIFX file must not parse")
        TestSupport.expect(WAVEncoder.parseHeader(wav.prefix(30)) == nil, "A truncated header must not parse")
        TestSupport.expectEqual(WAVEncoder.decode(wav.prefix(49))?.samples, [1, -2])
    }

    private static func testStreamingWriterMatchesOneShotEncoding() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "stream.wav")

        let writer = try! StreamingWAVWriter(url: url)
        TestSupport.expectEqual(try! Data(contentsOf: url), WAVEncoder.header(dataByteCount: 0))
        try! writer.append([1, 2, 3])
        try! writer.append([Int16]())
        let more: [Int16] = [9, -4, 5, 9]
        try! writer.append(more[1...2])
        try! writer.append([Int16.max, Int16.min])
        TestSupport.expectEqual(writer.frameCount, 7)
        TestSupport.expectEqual(try! writer.finish(), 7)
        TestSupport.expectEqual(try! Data(contentsOf: url), WAVEncoder.encode([1, 2, 3, -4, 5, .max, .min]))
    }

    private static func testApplyGainInPlace() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [Int16] = (0..<1_001).map { Int16(truncatingIfNeeded: ($0 * 97) % 40_000 - 20_000) }
        let doubled = samples.map { PCM16.scaled($0, by: 2) }

        for blockBytes in [2, 6, 7, 1_000, 65_536] {
            let url = directory.appending(path: "gain-\(blockBytes).wav")
            try! WAVEncoder.encode(samples).write(to: url)
            try! StreamingWAVWriter.applyGain(20 * log10f(2), toWAVAt: url, blockBytes: blockBytes)
            let data = try! Data(contentsOf: url)
            TestSupport.expectEqual(data.prefix(44), WAVEncoder.header(dataByteCount: samples.count * 2))
            TestSupport.expectEqual(WAVEncoder.decode(data)?.samples, doubled)
        }

        let untouched = directory.appending(path: "zero.wav")
        try! WAVEncoder.encode(samples).write(to: untouched)
        try! StreamingWAVWriter.applyGain(0, toWAVAt: untouched)
        TestSupport.expectEqual(try! Data(contentsOf: untouched), WAVEncoder.encode(samples))

        let notWAV = directory.appending(path: "text.wav")
        try! Data("not a wav file at all, just synthetic text".utf8).write(to: notWAV)
        do {
            try StreamingWAVWriter.applyGain(6, toWAVAt: notWAV)
            TestSupport.expect(false, "A non-WAV file must be refused")
        } catch {
            TestSupport.expectEqual(error as? StreamingWAVWriter.Failure, .unsupportedFormat)
        }
    }

    private static func testWriterFinishDiscardAndErrors() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "finish.wav")

        let writer = try! StreamingWAVWriter(url: url)
        try! writer.append([5, 6])
        TestSupport.expectEqual(try! writer.finish(), 2)
        TestSupport.expectEqual(try! writer.finish(), 2)
        TestSupport.expect(writer.isFinished, "finish() closes the file")
        do {
            try writer.append([7])
            TestSupport.expect(false, "Appending after finish() must fail")
        } catch {
            TestSupport.expectEqual(error as? StreamingWAVWriter.Failure, .alreadyFinished)
        }
        writer.discard()
        TestSupport.expect(!FileManager.default.fileExists(atPath: url.path), "discard() deletes the file")

        let open = try! StreamingWAVWriter(url: directory.appending(path: "open.wav"))
        try! open.append([1])
        open.discard()
        TestSupport.expect(!FileManager.default.fileExists(atPath: open.url.path), "discard() deletes an open file")

        do {
            _ = try StreamingWAVWriter(url: directory.appending(path: "missing/dir/file.wav"))
            TestSupport.expect(false, "A file in a missing directory must fail")
        } catch {
            TestSupport.expectEqual(error as? StreamingWAVWriter.Failure, .cannotCreateFile)
        }
    }

    private static func testCaptureRecordingFinishesAndRejectsShortClips() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func chunk(_ sequence: Int, _ samples: [Int16], levels: [Float]) -> PCMChunk {
            PCMChunk(session: 5, sequence: sequence, frameCount: samples.count, base64: PCM16.encodeLittleEndian(samples).base64EncodedString(), levels: levels, isFinal: false)
        }

        let speech = speechAndNoise(seconds: 1)
        let recording = try! CaptureRecording(session: 5, fileURL: directory.appending(path: "speech.wav"))
        let silent = try! recording.append(chunk(0, [Int16](repeating: 0, count: 320), levels: [0, 0]))
        TestSupport.expectEqual(silent, CaptureRecording.ChunkOutcome(becameAudible: false, displayLevel: nil, wasDuplicate: false))
        TestSupport.expect(!recording.isAudible, "Silence is not audible")

        let first = try! recording.append(chunk(1, Array(speech[0..<8_000]), levels: [0.01, 0.02]))
        TestSupport.expect(first.becameAudible, "The first level above zero makes the recording audible")
        TestSupport.expect((first.displayLevel ?? -1) > 0 && (first.displayLevel ?? 2) <= 1, "Display levels are in 0...1")
        let duplicate = try! recording.append(chunk(1, [1, 2, 3], levels: [0.5]))
        TestSupport.expect(duplicate.wasDuplicate, "A repeated sequence number is ignored")
        let second = try! recording.append(chunk(3, Array(speech[8_000...]), levels: [0.02]))
        TestSupport.expect(!second.becameAudible && second.displayLevel != nil, "Later chunks only update the level")
        TestSupport.expectEqual(recording.skippedChunks, 1)
        TestSupport.expectEqual(recording.frameCount, 320 + speech.count)

        guard let finished = try! recording.finish() else {
            TestSupport.expect(false, "A one-second recording must finish")
            return
        }
        TestSupport.expectEqual(finished.frameCount, 320 + speech.count)
        TestSupport.expectEqual(finished.sampleRate, 16_000)
        TestSupport.expectEqual(finished.skippedChunks, 1)
        TestSupport.expectEqual(finished.gain, UploadGainPolicy.decide(finished.loudness))
        TestSupport.expect(finished.gain.gainDB > 10, "Quiet synthetic speech must be boosted: \(finished.gain)")
        var expected = [Int16](repeating: 0, count: 320) + speech
        PCM16.apply(gainDB: finished.gain.gainDB, to: &expected)
        TestSupport.expectEqual(WAVEncoder.decode(try! Data(contentsOf: finished.fileURL))?.samples, expected)

        let short = try! CaptureRecording(session: 6, fileURL: directory.appending(path: "short.wav"))
        _ = try! short.append(chunk(0, [Int16](repeating: 900, count: CaptureRecording.minimumFrameCount - 1), levels: [0.03]))
        TestSupport.expect(try! short.finish() == nil, "Under 0.01 s is no audio")
        TestSupport.expect(!FileManager.default.fileExists(atPath: short.fileURL.path), "A too-short recording is deleted")

        let broken = try! CaptureRecording(session: 7, fileURL: directory.appending(path: "broken.wav"))
        do {
            _ = try broken.append(PCMChunk(session: 7, sequence: 0, frameCount: 1, base64: "%%%", levels: [], isFinal: false))
            TestSupport.expect(false, "A malformed chunk must throw")
        } catch {
            TestSupport.expectEqual(error as? PCMChunkDecoder.Failure, .invalidBase64)
        }
        broken.discard()
    }

    private static func testCapturePageHTML() {
        let html = CapturePageSource.html(includeSyntheticSource: true)
        TestSupport.expect(
            html.contains(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">"#),
            "The page must carry its CSP"
        )
        TestSupport.expect(html.hasPrefix("<!doctype html>"), "The page must start with a doctype")
        let order = [CapturePageSource.dspScript, CapturePageSource.syntheticScript, CapturePageSource.captureScript]
            .compactMap { html.range(of: $0)?.lowerBound }
        TestSupport.expect(order.count == 3 && order == order.sorted(), "Scripts must appear in order: dsp, synthetic, capture")
        let release = CapturePageSource.html(includeSyntheticSource: false)
        TestSupport.expect(!release.contains(CapturePageSource.syntheticScript), "Release pages leave out the synthetic source")
        TestSupport.expect(!release.contains("function ffSyntheticSource"), "Release pages define no synthetic source")
        for script in [CapturePageSource.dspScript, CapturePageSource.syntheticScript, CapturePageSource.captureScript] {
            TestSupport.expect(script.range(of: "</script", options: .caseInsensitive) == nil, "A script must not close its tag")
        }
        TestSupport.expectEqual(CapturePageSource.baseURL.absoluteString, "https://capture.freeflow.invalid/")
        TestSupport.expectEqual(CapturePageSource.baseURL.host, CapturePageSource.host)
        let capture = CapturePageSource.captureScript
        TestSupport.expect(capture.contains("window.webkit.messageHandlers.\(CapturePageSource.messageHandlerName)"), "The page posts to the native handler name")
        TestSupport.expect(capture.contains("version: \(CapturePageSource.pageVersion),"), "ffCapture.version matches pageVersion")
        TestSupport.expect(capture.contains("t: 'ready', v: \(CapturePageSource.pageVersion),"), "The ready message carries pageVersion")
    }

    // MARK: The capture page in JavaScriptCore

    private static func testJavaScriptCoreRunsPromiseJobs() {
        let page = JSCapturePage()
        page.evaluate("var __settled = 'no'; Promise.resolve().then(() => { __settled = 'yes'; }); 0")
        TestSupport.expectEqual(page.string("__settled"), "yes")
        TestSupport.expectEqual(page.native.messages, [.ready(pageVersion: CapturePageSource.pageVersion, hasSyntheticSource: true)])
        page.expectNoExceptions()
    }

    private static func testJavaScriptInt16AndBase64MatchSwift() {
        let page = JSCapturePage()
        var values: [Double] = [
            0, 1, -1, 0.5, -0.5, 2, -2, 0.25, 1.0 / 32_767, -1.0 / 32_767, 0.5 / 32_767, -0.5 / 32_767,
            1.5 / 32_767, -1.5 / 32_767, 0.999_99, -0.999_99, 1e-30, -1e-30, 0.123_456_789,
        ]
        var state: UInt32 = 0x2545_F491
        for _ in 0..<300 {
            state = state &* 1_664_525 &+ 1_013_904_223
            values.append(Double(state) / Double(UInt32.max) * 2.4 - 1.2)
        }
        let literal = values.map { "\($0)" }.joined(separator: ",")
        let fromJavaScript = page.doubles("Array.from(ffToInt16(Float32Array.from([\(literal), NaN, Infinity, -Infinity])))")
        let fromSwift = (values + [.nan, .infinity, -.infinity]).map { Double(PCM16.sample(fromUnit: Float($0))) }
        TestSupport.expectEqual(fromJavaScript, fromSwift)

        for length in 0...48 {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 41) }
            let list = bytes.map { String($0) }.joined(separator: ",")
            let expected = Data(bytes).base64EncodedString()
            // A plain array has no toBase64, so this always takes the fallback encoder.
            TestSupport.expectEqual(page.string("ffBase64([\(list)])"), expected)
            TestSupport.expectEqual(page.string("ffBase64(new Uint8Array([\(list)]))"), expected)
        }
        let roundTrip = page.string("ffBase64(new Uint8Array(ffToInt16(Float32Array.from([0, 1, -1, 0.5, -0.5, 2])).buffer))")
        TestSupport.expectEqual(roundTrip, "AAD/fwGAAEABwP9/")
        page.expectNoExceptions()
    }

    private static func testJavaScriptResamplerResponse() {
        let page = JSCapturePage()
        for rate in [48_000, 44_100] {
            func responseDB(_ frequency: Int) -> Double {
                let output = page.doubles("__resample(\(rate), __tone(\(rate), \(frequency), 1, 0.5), 2048)").map { Float($0) }
                let steady = output[400..<(output.count - 400)]
                return 20 * log10(Double(LevelMeter.rms(steady)) / (0.5 / 2.0.squareRoot()) + 1e-12)
            }
            for frequency in [100, 1_000, 4_000, 6_500, 7_000] {
                let response = responseDB(frequency)
                TestSupport.expect(abs(response) < 0.1, "\(rate) Hz: \(frequency) Hz must pass, got \(response) dB")
            }
            let at8k = responseDB(8_000)
            let at12k = responseDB(12_000)
            TestSupport.expect(at8k < -65, "\(rate) Hz: 8 kHz must be at least 65 dB down, got \(at8k) dB")
            TestSupport.expect(at12k < -90, "\(rate) Hz: 12 kHz must be at least 90 dB down, got \(at12k) dB")

            let x = "__tone(\(rate), 1234, 0.5, 0.3)"
            let a = page.doubles("__resample(\(rate), \(x), 2048)")
            TestSupport.expectEqual(page.doubles("__resample(\(rate), \(x), 997)"), a)
            TestSupport.expectEqual(page.doubles("__resample(\(rate), \(x), 1 << 30)"), a)
            // 0.5 s is 8,000 output frames, plus the flushed filter tail.
            TestSupport.expect((8_000...8_060).contains(a.count), "\(rate) Hz: unexpected output length \(a.count)")
        }
        TestSupport.expectEqual(page.doubles("__resample(16000, Float32Array.from([0.5, -0.25, 1]), 2)"), [0.5, -0.25, 1])
        TestSupport.expectEqual(page.string("(() => { try { new FFResampler(12345); return 'ok'; } catch (e) { return e.name; } })()"), "UnsupportedRateError")
        TestSupport.expectEqual(page.string("(() => { try { new FFResampler(0); return 'ok'; } catch (e) { return e.name; } })()"), "UnsupportedRateError")
        page.expectNoExceptions()
    }

    private static func testJavaScriptCaptureSessionEndToEnd() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = JSCapturePage(directory: directory)

        page.evaluate("ffCapture.start({sid: 7, synthetic: false, echoCancellation: true}); 0")
        TestSupport.expectEqual(page.native.messages.last, .started(session: 7, contextRate: 48_000, captureRate: 44_100, isSynthetic: false))
        TestSupport.expectEqual(page.string("__media.calls.join('|')"), #"{"audio":{"echoCancellation":true},"video":false}|session=play-and-record"#)
        TestSupport.expectEqual(page.string("__graph.join(',')"), "source>processor,processor>gain,gain>destination@0")
        TestSupport.expectEqual(page.string("__sp.shape"), "2048,1,1")
        TestSupport.expectEqual(page.string("__ctx.options"), #"{"latencyHint":"interactive"}"#)

        // 0.25 s of quiet speech-like tone, 0.25 s of near silence, then one more block after stop().
        page.evaluate("""
            var __input = (() => {
              const a = __tone(48000, 1000, 0.25, 0.02), b = __tone(48000, 1000, 0.25, 0.0002, 12000);
              const z = new Float32Array(a.length + b.length); z.set(a); z.set(b, a.length); return z;
            })();
            var __blocks = __feed(__input);
            ffCapture.stop(7);
            var __last = __tone(48000, 1000, 2048 / 48000, 0.0002, __input.length);
            __feed(__last);
            0
            """)
        guard case .ended(7, "stopped", let pageFrames)? = page.native.messages.last else {
            TestSupport.expect(false, "The session must end as stopped: \(page.native.messages.suffix(2))")
            return
        }
        let chunks = page.native.chunks
        TestSupport.expectEqual(chunks.count, Int(page.number("__blocks")) + 1)
        TestSupport.expectEqual(chunks.map(\.sequence), Array(0..<chunks.count))
        TestSupport.expectEqual(chunks.map(\.isFinal), [Bool](repeating: false, count: chunks.count - 1) + [true])
        // One level per 1024 input frames (~21 ms at 48 kHz), carried across callbacks.
        TestSupport.expectEqual(chunks.reduce(0) { $0 + $1.levels.count }, (24_000 + 2_048) / 1_024)
        TestSupport.expectEqual(chunks.first?.levels.count, 2)
        TestSupport.expectEqual(pageFrames, chunks.reduce(0) { $0 + $1.frameCount })
        TestSupport.expectEqual(Int(page.number("ffCapture.status().acked")), chunks.count)
        TestSupport.expectEqual(page.number("__media.trackStops"), 1)
        TestSupport.expectEqual(page.string("__ctx.state"), "closed")
        TestSupport.expectEqual(page.string("navigator.audioSession.type"), "auto")
        TestSupport.expect(page.bool("__sp.disconnected === true && __sp.onaudioprocess === null"), "The graph must be torn down")

        guard let recording = page.native.recording, let finished = try! recording.finish() else {
            TestSupport.expect(false, "The session must produce a recording")
            return
        }
        TestSupport.expectEqual(finished.frameCount, pageFrames)
        TestSupport.expectEqual(finished.skippedChunks, 0)
        guard case .apply(let gainDB) = finished.gain else {
            TestSupport.expect(false, "Quiet speech must be boosted, got \(finished.gain) for \(finished.loudness)")
            return
        }
        TestSupport.expect(gainDB > 10 && gainDB <= 24, "Unexpected gain \(gainDB) dB for \(finished.loudness)")

        // The chunked, bridged, written and boosted file equals the page's one-shot output.
        var reference = page.doubles("""
            Array.from(ffToInt16(Float32Array.from(__resample(48000, (() => {
              const z = new Float32Array(__input.length + __last.length); z.set(__input); z.set(__last, __input.length); return z;
            })(), 1 << 30))))
            """).map { Int16($0) }
        PCM16.apply(gainDB: gainDB, to: &reference)
        TestSupport.expectEqual(WAVEncoder.decode(try! Data(contentsOf: finished.fileURL))?.samples, reference)
        page.expectNoExceptions()
    }

    private static func testJavaScriptDeadManSwitch() {
        let page = JSCapturePage()
        page.evaluate("ffCapture.start({sid: 1}); 0")
        page.evaluate("__ackMode = 'hold'; __feed(__tone(48000, 440, 0.2, 0.1)); 0")
        page.evaluate("__advance(2400); 0")
        TestSupport.expect(!page.bool("__posts.some((m) => m.t === 'ended')"), "The page must wait 2.5 s for acks")
        page.evaluate("__advance(700); 0")
        TestSupport.expectEqual(page.string("__posts[__posts.length - 1].reason"), "native-unresponsive")
        TestSupport.expectEqual(page.number("__media.trackStops"), 1)
        TestSupport.expectEqual(page.string("__ctx.state"), "closed")

        let rejecting = JSCapturePage()
        rejecting.evaluate("ffCapture.start({sid: 2}); 0")
        rejecting.native.acceptsMessages = false
        rejecting.evaluate("__feed(__tone(48000, 440, 0.05, 0.1)); 0")
        TestSupport.expectEqual(rejecting.string("__posts[__posts.length - 1].reason"), "bridge-lost")
        TestSupport.expectEqual(rejecting.number("__media.trackStops"), 1)
        page.expectNoExceptions()
        rejecting.expectNoExceptions()
    }

    private static func testJavaScriptStopTimeoutCancelAndStaleSessions() {
        let page = JSCapturePage()
        page.evaluate("ffCapture.start({sid: 3}); 0")
        page.evaluate("__feed(__tone(48000, 440, 0.1, 0.1)); 0")
        page.evaluate("ffCapture.stop(99); ffCapture.cancel(98); 0")
        TestSupport.expectEqual(page.string("ffCapture.status().phase"), "running")
        page.evaluate("ffCapture.stop(3); __advance(200); 0")
        TestSupport.expectEqual(page.string("ffCapture.status().phase"), "stopping")
        page.evaluate("__advance(100); 0")
        guard case .ended(3, "stopped", _)? = page.native.messages.last,
              let last = page.native.chunks.last else {
            TestSupport.expect(false, "A stop with no further callback must end after the grace period")
            return
        }
        TestSupport.expect(last.isFinal && last.frameCount > 0, "The grace-period stop still flushes the resampler tail")

        page.evaluate("ffCapture.start({sid: 4}); ffCapture.cancel(4); 0")
        TestSupport.expectEqual(page.native.messages.last, .ended(session: 4, reason: "cancelled", frames: 0))
        // A second start ends the first, even while it still waits for getUserMedia.
        page.evaluate("ffCapture.start({sid: 5}); ffCapture.start({sid: 6}); 0")
        TestSupport.expectEqual(
            Array(page.native.messages.suffix(3)),
            [
                .ended(session: 4, reason: "cancelled", frames: 0),
                .ended(session: 5, reason: "restarted", frames: 0),
                .started(session: 6, contextRate: 48_000, captureRate: 44_100, isSynthetic: false),
            ]
        )
        page.expectNoExceptions()
    }

    private static func testJavaScriptFailures() {
        let denied = JSCapturePage()
        denied.evaluate("__media.fail = 'NotAllowedError'; ffCapture.start({sid: 1}); 0")
        TestSupport.expectEqual(denied.native.messages.last, .failed(session: 1, name: "NotAllowedError"))
        TestSupport.expectEqual(CaptureMessage.failureKind(forName: "NotAllowedError"), .permissionDenied)
        TestSupport.expectEqual(denied.string("navigator.audioSession.type"), "auto")

        let scenarios: [(setup: String, name: String)] = [
            ("navigator.mediaDevices = undefined", "MediaDevicesUnavailable"),
            ("AudioContext = undefined", "AudioContextUnavailable"),
            ("__media.rate = 12345", "UnsupportedRateError"),
            ("__media.fail = 'NotFoundError'", "NotFoundError"),
        ]
        for scenario in scenarios {
            let page = JSCapturePage()
            page.evaluate("\(scenario.setup); ffCapture.start({sid: 2}); 0")
            TestSupport.expectEqual(page.native.messages.last, .failed(session: 2, name: scenario.name))
            TestSupport.expectEqual(CaptureMessage.failureKind(forName: scenario.name), .unsupported)
            page.expectNoExceptions()
        }
        let rate = JSCapturePage()
        rate.evaluate("__media.rate = 12345; ffCapture.start({sid: 3}); 0")
        TestSupport.expectEqual(rate.number("__media.trackStops"), 1)
        TestSupport.expectEqual(rate.string("__ctx.state"), "closed")

        let pending = JSCapturePage()
        pending.evaluate("__media.hang = true; ffCapture.start({sid: 4}); ffCapture.stop(4); 0")
        TestSupport.expectEqual(pending.native.messages.last, .ended(session: 4, reason: "stopped-before-audio", frames: 0))

        let release = JSCapturePage(includeSyntheticSource: false)
        release.evaluate("ffCapture.start({sid: 5, synthetic: true}); 0")
        TestSupport.expectEqual(release.native.messages, [
            .ready(pageVersion: CapturePageSource.pageVersion, hasSyntheticSource: false),
            .failed(session: 5, name: "SyntheticSourceUnavailable"),
        ])
        denied.expectNoExceptions()
        pending.expectNoExceptions()
        release.expectNoExceptions()
    }

    private static func testJavaScriptSyntheticSource() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = JSCapturePage(directory: directory)
        page.evaluate("ffCapture.start({sid: 9, synthetic: true}); 0")
        TestSupport.expectEqual(page.native.chunks.count, 1)
        TestSupport.expectEqual(page.number("__media.calls.length + __media.contexts"), 0)
        TestSupport.expect(
            page.native.messages.contains(.started(session: 9, contextRate: 48_000, captureRate: 0, isSynthetic: true)),
            "The synthetic source reports a 48 kHz device rate"
        )
        TestSupport.expect(page.native.outcomes.first?.becameAudible == true, "The first synthetic chunk is audible")
        for _ in 0..<50 {
            page.evaluate("__advance(20); 0")
        }
        page.evaluate("ffCapture.stop(9); 0")
        guard case .ended(9, "stopped", _)? = page.native.messages.last,
              let recording = page.native.recording, let finished = try! recording.finish() else {
            TestSupport.expect(false, "The synthetic session must stop cleanly: \(page.native.messages.suffix(2))")
            return
        }
        // One second of 16 kHz audio, plus one block of look-ahead and the filter tail.
        TestSupport.expect((15_500...17_500).contains(finished.frameCount), "Unexpected synthetic length \(finished.frameCount)")
        // Speech sits near -23 dBFS, so the -20 dBFS target needs about +3 dB.
        TestSupport.expectApproximatelyEqual(Double(finished.gain.gainDB), 3, accuracy: 1)
        guard let samples = WAVEncoder.decode(try! Data(contentsOf: finished.fileURL))?.samples else {
            TestSupport.expect(false, "The synthetic recording must decode")
            return
        }
        let loud = samples[0..<4_000]
        TestSupport.expect(goertzel(loud, frequency: 440) > 1_000 * goertzel(loud, frequency: 1_000), "The synthetic source is a 440 Hz tone")
        page.expectNoExceptions()
    }

    private static func testJavaScriptInterruptions() {
        let cases: [(trigger: String, reason: String)] = [
            ("document.hidden = true; __dispatch('document:visibilitychange')", "hidden"),
            ("__dispatch('pagehide')", "pagehide"),
            ("__media.track.onended()", "track-ended"),
            ("__ctx.state = 'interrupted'; __ctx.onstatechange()", "context-interrupted"),
        ]
        for item in cases {
            let page = JSCapturePage()
            page.evaluate("ffCapture.start({sid: 1}); 0")
            page.evaluate("__feed(__tone(48000, 440, 0.05, 0.1)); \(item.trigger); 0")
            guard case .ended(1, let reason, _)? = page.native.messages.last else {
                TestSupport.expect(false, "\(item.trigger) must end the session")
                continue
            }
            TestSupport.expectEqual(reason, item.reason)
            TestSupport.expectEqual(page.number("__media.trackStops"), 1)
            page.expectNoExceptions()
        }
        let hiddenWhileIdle = JSCapturePage()
        hiddenWhileIdle.evaluate("document.hidden = true; __dispatch('document:visibilitychange'); __dispatch('pagehide'); 0")
        TestSupport.expectEqual(hiddenWhileIdle.native.messages.count, 1)
        hiddenWhileIdle.expectNoExceptions()
    }

    // MARK: Fixtures

    private static func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FreeFlowAudioCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 16 kHz sine; 1 kHz fills a 320-frame block with whole periods.
    private static func tone(frequency: Double, amplitude: Double, frames: Int, phase: Int = 0) -> [Int16] {
        (0..<frames).map { index in
            PCM16.sample(fromUnit: Float(amplitude * sin(2 * Double.pi * frequency * Double(index + phase) / 16_000)))
        }
    }

    /// Deterministic noise with the given RMS, from a linear congruential generator.
    private static func noise(rmsDBFS: Double, frames: Int, seed: UInt32) -> [Int16] {
        let amplitude = pow(10, rmsDBFS / 20) * 3.0.squareRoot()
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            let uniform = Double(state) / Double(UInt32.max) * 2 - 1
            return PCM16.sample(fromUnit: Float(amplitude * uniform))
        }
    }

    /// Quiet "speech" (a -42 dBFS tone, 200 ms of every 500 ms) over a -72 dBFS noise floor.
    private static func speechAndNoise(seconds: Double) -> [Int16] {
        let frames = Int(seconds * 16_000)
        let floor = noise(rmsDBFS: -72, frames: frames, seed: 7)
        let speech = tone(frequency: 1_000, amplitude: pow(10, -42.0 / 20) * 2.0.squareRoot(), frames: frames)
        return (0..<frames).map { index in
            let speaking = index % 8_000 < 3_200
            let mixed = Int(floor[index]) + (speaking ? Int(speech[index]) : 0)
            return Int16(clamping: mixed)
        }
    }

    private static func goertzel(_ samples: ArraySlice<Int16>, frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / 16_000)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) / 32_768 + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

/// The native side of the capture bridge for the JavaScriptCore tests: every post goes
/// through CaptureMessage, and pcm chunks go into a CaptureRecording, as in WebAudioCapture.
private final class PageBridgeRecorder {
    private(set) var messages: [CaptureMessage] = []
    private(set) var chunks: [PCMChunk] = []
    private(set) var outcomes: [CaptureRecording.ChunkOutcome] = []
    private(set) var recording: CaptureRecording?
    private(set) var rejections = 0
    var acceptsMessages = true
    private let directory: URL?

    init(directory: URL?) {
        self.directory = directory
    }

    func accept(_ value: JSValue?) -> Bool {
        guard acceptsMessages,
              let body = jsOptional(value?.toObject()),
              let message = CaptureMessage(body: body) else {
            rejections += 1
            return false
        }
        messages.append(message)
        switch message {
        case .started(let session, _, _, _):
            if let directory {
                recording = try! CaptureRecording(session: session, fileURL: directory.appending(path: "session-\(session).wav"))
            }
        case .pcm(let chunk):
            chunks.append(chunk)
            if let recording {
                guard recording.session == chunk.session, let outcome = try? recording.append(chunk) else {
                    rejections += 1
                    return false
                }
                outcomes.append(outcome)
            }
        case .ready, .ended, .failed:
            break
        }
        return true
    }
}

/// A JSContext holding the fake browser prelude and the real capture page script.
private final class JSCapturePage {
    let context: JSContext
    let native: PageBridgeRecorder
    private(set) var exceptions: [String] = []

    init(includeSyntheticSource: Bool = true, directory: URL? = nil) {
        guard let context = jsOptional(JSContext()) else { fatalError("Could not create a JSContext") }
        self.context = context
        native = PageBridgeRecorder(directory: directory)
        context.exceptionHandler = { [weak self] _, exception in
            self?.exceptions.append(jsOptional(exception?.toString()) ?? "unknown exception")
        }
        let accept: @convention(block) (JSValue?) -> Bool = { [native] value in native.accept(value) }
        context.setObject(unsafeBitCast(accept, to: AnyObject.self), forKeyedSubscript: "__nativeAccept" as NSString)
        evaluate(Self.prelude)
        evaluate(CapturePageSource.script(includeSyntheticSource: includeSyntheticSource))
    }

    @discardableResult
    func evaluate(_ script: String) -> JSValue? {
        jsOptional(context.evaluateScript(script))
    }

    func string(_ script: String) -> String {
        jsOptional(evaluate(script)?.toString()) ?? ""
    }

    func number(_ script: String) -> Double {
        evaluate(script)?.toDouble() ?? .nan
    }

    func bool(_ script: String) -> Bool {
        evaluate(script)?.toBool() ?? false
    }

    func doubles(_ script: String) -> [Double] {
        let array: [Any] = jsOptional(evaluate(script)?.toArray()) ?? []
        return array.map { ($0 as? NSNumber)?.doubleValue ?? .nan }
    }

    func expectNoExceptions(file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(exceptions.isEmpty, "JavaScript exceptions: \(exceptions)", file: file, line: line)
    }

    /// A fake browser: a manual clock with timers, Web Audio and getUserMedia mocks, and a
    /// message handler that hands every post to `__nativeAccept`.
    static let prelude = #"""
// A fake browser for the capture page: a manual clock with timers, Web Audio and
// getUserMedia mocks, and a message handler that hands every post to __nativeAccept.
var window = globalThis;
var __now = 0, __nextTimer = 1, __timers = [];
function setTimeout(fn, ms) { const id = __nextTimer++; __timers.push({ id, at: __now + (ms || 0), every: 0, fn }); return id; }
function setInterval(fn, ms) { const id = __nextTimer++; __timers.push({ id, at: __now + Math.max(1, ms || 0), every: Math.max(1, ms || 0), fn }); return id; }
function clearTimeout(id) { __timers = __timers.filter((t) => t.id !== id); }
function clearInterval(id) { clearTimeout(id); }
function __advance(ms) {
  const end = __now + ms;
  for (;;) {
    let next = null;
    for (const t of __timers) if (t.at <= end && (!next || t.at < next.at || (t.at === next.at && t.id < next.id))) next = t;
    if (!next) break;
    __now = next.at;
    if (next.every) next.at += next.every; else __timers = __timers.filter((t) => t !== next);
    next.fn();
  }
  __now = end;
}
var performance = { now: () => __now };
var __listeners = {};
function addEventListener(type, fn) { (__listeners[type] = __listeners[type] || []).push(fn); }
var document = { hidden: false, addEventListener(type, fn) { addEventListener('document:' + type, fn); } };
function __dispatch(type) { (__listeners[type] || []).forEach((fn) => fn()); }
var __posts = [];
var __ackMode = 'native';
window.webkit = { messageHandlers: { ffCapture: { postMessage(m) {
  __posts.push(m);
  if (__ackMode === 'hold') return new Promise(() => {});
  const accepted = __ackMode === 'native' ? __nativeAccept(m) : __ackMode === 'accept';
  return accepted ? Promise.resolve(undefined) : Promise.reject(new Error('rejected'));
} } } };
var __media = { calls: [], fail: '', hang: false, trackStops: 0, contexts: 0, rate: 48000, captureRate: 44100, track: null };
var __graph = [], __sp = null, __ctx = null;
function __node(kind) { return { kind, connect(target) { __graph.push(kind + '>' + target.kind + (this.gain ? '@' + this.gain.value : '')); }, disconnect() { this.disconnected = true; } }; }
var navigator = { audioSession: { type: 'auto' }, mediaDevices: { getUserMedia(constraints) {
  __media.calls.push(JSON.stringify(constraints) + '|session=' + navigator.audioSession.type);
  if (__media.hang) return new Promise(() => {});
  if (__media.fail) { const e = new Error(__media.fail); e.name = __media.fail; return Promise.reject(e); }
  const track = { onended: null, stopped: false, stop() { this.stopped = true; __media.trackStops++; }, getSettings() { return { sampleRate: __media.captureRate }; } };
  __media.track = track;
  return Promise.resolve({ getTracks: () => [track], getAudioTracks: () => [track] });
} } };
class AudioContext {
  constructor(options) { __media.contexts++; this.options = JSON.stringify(options); this.sampleRate = __media.rate; this.state = 'suspended'; this.currentTime = 0; this.destination = { kind: 'destination' }; this.onstatechange = null; __ctx = this; }
  resume() { this.state = 'running'; return Promise.resolve(); }
  close() { this.state = 'closed'; if (this.onstatechange) this.onstatechange(); return Promise.resolve(); }
  createMediaStreamSource() { return __node('source'); }
  createScriptProcessor(frames, inputs, outputs) { __sp = __node('processor'); __sp.shape = [frames, inputs, outputs].join(','); return __sp; }
  createGain() { const gain = __node('gain'); gain.gain = { value: 1 }; return gain; }
}
function __tone(rate, hz, seconds, amplitude, phaseFrames) {
  const n = Math.round(rate * seconds), x = new Float32Array(n), p = phaseFrames || 0;
  for (let i = 0; i < n; i++) x[i] = amplitude * Math.sin(2 * Math.PI * hz * (i + p) / rate);
  return x;
}
// Feeds x to the ScriptProcessor in callback-sized blocks; returns the blocks fed.
function __feed(x, frames) {
  const size = frames || 2048; let blocks = 0;
  for (let i = 0; i < x.length; i += size) { const block = x.slice(i, i + size); __sp.onaudioprocess({ inputBuffer: { getChannelData: () => block } }); blocks++; }
  return blocks;
}
function __resample(rate, x, chunk) {
  const r = new FFResampler(rate), out = [];
  for (let i = 0; i < x.length; i += chunk) { const y = r.process(x.subarray(i, i + chunk)); for (let j = 0; j < y.length; j++) out.push(y[j]); }
  const tail = r.flush(); for (let j = 0; j < tail.length; j++) out.push(tail[j]);
  return out;
}
function __summary() { return __posts.map((m) => m.t === 'pcm' ? `pcm#${m.seq}/${m.sid} n=${m.n} lv=${m.lv.length} final=${m.final}` : JSON.stringify(m)).join('\n'); }
"""#
}

/// Passes a value through as an Optional, whether the JavaScriptCore API returns it as an
/// implicitly unwrapped optional or not, without a warning either way.
private func jsOptional<Value>(_ value: Value?) -> Value? {
    value
}
