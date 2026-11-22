import UIKit
import WebKit
import XCTest
@testable import FreeFlow

/// WebAudioCapture in the simulator, with the real capture page in a real WKWebView.
///
/// In the simulator WebKit replaces the microphone with a deterministic mock: a 150 Hz hum
/// under 70 ms bursts at 1500 Hz and 500 Hz, on a 2 s loop. The synthetic tests use the
/// page's DEBUG 440 Hz source instead, which needs no Web Audio. Failure paths are driven by
/// replacing page functions from the test, so production code needs no test hooks.
final class CaptureTests: XCTestCase {
    @MainActor
    func testPageLoadsIntoALockedDownSecureContext() async throws {
        let harness = try await CaptureHarness.make()
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()

        XCTAssertEqual(harness.events, [.ready])
        XCTAssertEqual(harness.capture.state, .ready)
        let webView = harness.capture.webView
        XCTAssertTrue(webView.window === harness.window, "The web view must be in the window")
        XCTAssertEqual(webView.bounds.size, CGSize(width: 2, height: 2))
        XCTAssertEqual(webView.alpha, 0.02, accuracy: 0.001)
        XCTAssertFalse(webView.isHidden)
        XCTAssertFalse(webView.isUserInteractionEnabled)

        let facts = try await harness.evaluateJSON("""
            JSON.stringify({
              secure: isSecureContext,
              origin: location.origin,
              csp: document.querySelector('meta[http-equiv="Content-Security-Policy"]').content,
              version: ffCapture.version,
              start: typeof ffCapture.start,
              getUserMedia: typeof (navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
              audioContext: typeof AudioContext,
              synthetic: typeof ffSyntheticSource
            })
            """)
        XCTAssertEqual(facts["secure"] as? Bool, true)
        XCTAssertEqual(facts["origin"] as? String, "https://\(CapturePageSource.host)")
        XCTAssertEqual(facts["csp"] as? String, CapturePageSource.contentSecurityPolicy)
        XCTAssertEqual(facts["version"] as? Int, CapturePageSource.pageVersion)
        XCTAssertEqual(facts["start"] as? String, "function")
        XCTAssertEqual(facts["getUserMedia"] as? String, "function")
        XCTAssertEqual(facts["audioContext"] as? String, "function")
        XCTAssertEqual(facts["synthetic"] as? String, "function", "DEBUG pages include the synthetic source")
    }

    @MainActor
    func testSyntheticSourceRecordsAToneThroughThePage() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()

        harness.start()
        XCTAssertEqual(harness.capture.state, .starting)
        try await harness.waitForStart(timeout: 10)
        XCTAssertEqual(harness.capture.state, .capturing)
        XCTAssertEqual(harness.capture.lastStartInfo?.isSynthetic, true)
        XCTAssertEqual(harness.capture.lastStartInfo?.contextRate, 48_000)
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)

        try await Task.sleep(nanoseconds: 1_200_000_000)
        harness.capture.stop()
        XCTAssertEqual(harness.capture.state, .stopping)
        let audio = try await harness.waitForRecording(timeout: 10)

        XCTAssertEqual(audio.fileURL, fileURL)
        XCTAssertEqual(audio.sampleRate, 16_000)
        XCTAssertGreaterThan(audio.duration, 0.9)
        XCTAssertLessThan(audio.duration, 6)
        // 0.3 s at -23 dBFS then 0.2 s at -63 dBFS: the policy lifts speech towards -20 dBFS.
        XCTAssertGreaterThan(audio.appliedGainDB, 2)
        XCTAssertLessThan(audio.appliedGainDB, 4)

        let wav = try CaptureHarness.loadWAV(audio.fileURL)
        XCTAssertEqual(wav.samples.count, audio.frameCount)
        let loud = Array(wav.samples.prefix(4_000))
        XCTAssertGreaterThan(
            ToneAnalysis.power(loud[...], frequency: 440),
            1_000 * ToneAnalysis.power(loud[...], frequency: 1_000),
            "The recording should be the 440 Hz test tone"
        )
        let loudestBlock = LevelMeter.blockRMS(wav.samples, blockFrames: 320).max() ?? 0
        XCTAssertEqual(Double(LevelMeter.decibels(fromRMS: Double(loudestBlock))), -20, accuracy: 1.5)

        XCTAssertEqual(harness.capture.state, .ready)
        XCTAssertEqual(harness.terminalEvents.count, 1)
        XCTAssertFalse(harness.levels.isEmpty)
        XCTAssertTrue(harness.levels.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(harness.levels.max() ?? 0, 0.1)
    }

    /// Real getUserMedia capture against WebKit's simulator mock microphone, which plays a 70 ms
    /// 1500 Hz bip and a 70 ms 500 Hz bop 1 s apart, on a 2 s loop over a 150 Hz hum. WebKit
    /// bends or repeats stretches of that audio before the page sees it (see MockRhythm), so
    /// this records long enough that one such stretch still leaves a bip, a bop and a steady
    /// rhythm. FreeFlow's own part is exact: every frame the page sent is in the file.
    @MainActor
    func testMicrophoneCaptureRecordsWebKitsMockDevice() async throws {
        let harness = try await CaptureHarness.make(synthetic: false)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()

        // The first capture on a cold CI simulator also launches WebKit's GPU process.
        harness.capture.startTimeoutInterval = 20
        let requestedAt = Date()
        harness.start()
        try await harness.waitUntil("audible audio or a failure", timeout: 25) {
            harness.sessionEvents.contains(.started) || harness.sessionEvents.contains(where: \.isTerminal)
        }
        let startStatus = try await harness.pageStatus()
        harness.record("page status after start", startStatus)
        if let failure = harness.sessionEvents.first(where: \.isTerminal) {
            try Self.explainMicrophoneFailure(failure, status: startStatus)
        }
        let startLatency = Date().timeIntervalSince(requestedAt)
        let info = try XCTUnwrap(harness.capture.lastStartInfo)
        harness.record("microphone start", [
            "latencySeconds": startLatency,
            "contextRate": info.contextRate,
            "captureRate": info.captureRate,
        ])
        XCTAssertFalse(info.isSynthetic)

        // Four or more bursts fall in 4.2 s, two of each kind, so a gap that takes one leaves both.
        var sawActiveMicrophone = false
        let recordUntil = Date().addingTimeInterval(Self.microphoneRecordingSeconds)
        while Date() < recordUntil {
            if harness.capture.webView.microphoneCaptureState == .active {
                sawActiveMicrophone = true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        let endStatus = try await harness.pageStatus()
        harness.record("microphone recording", [
            "frames": audio.frameCount,
            "appliedGainDB": Double(audio.appliedGainDB),
            "sawActiveMicrophone": sawActiveMicrophone,
            "pageReported": audio.pageContinuity != nil,
        ])
        harness.record("page status after stop", endStatus)

        // The file holds every frame the page sent, and the page's own count of what WebKit lost.
        // A page that stalls past the stop wait loses its last frames by design, so only a page
        // that ended in time is held to this.
        if let continuity = audio.pageContinuity {
            XCTAssertEqual(audio.frameCount, endStatus["frames"] as? Int, "Every frame the page sent must be in the file")
            XCTAssertEqual(continuity.callbacks, endStatus["callbacks"] as? Int)
            XCTAssertEqual(continuity.skippedCallbacks, endStatus["skipped"] as? Int)
            XCTAssertEqual(continuity.lateCallbacks, endStatus["late"] as? Int)
        }

        let wav = try CaptureHarness.loadWAV(audio.fileURL)
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertGreaterThan(audio.duration, Self.microphoneRecordingSeconds - 0.4)
        let tones = ToneAnalysis.mockDeviceTones(in: wav.samples)
        let bursts = ToneAnalysis.mockDeviceBursts(in: wav.samples)
        let rhythm = ToneAnalysis.MockRhythm(bursts)
        // One stretch of WebKit's latency adaptation (see MockRhythm) bends at most two spacings,
        // and its period of about 5 s leaves room for only one in a recording this short.
        let allowedGlitches = 2
        let steady = rhythm.isSteady(allowingGlitches: allowedGlitches)
        let burstList = bursts.map(\.summary).joined(separator: " ")
        let pageCounts = audio.pageContinuity.map { "\($0.skippedCallbacks) skipped, \($0.lateCallbacks) late" } ?? "no report"
        harness.record("mock device tones", [
            "windows": tones.windows,
            "humWindows": tones.humWindows,
            "bipWindows": tones.bipWindows,
            "bopWindows": tones.bopWindows,
            "bursts": burstList,
            "offsetsMs": rhythm.offsetsMilliseconds,
            "repeatedBursts": rhythm.repeats,
            "glitches": rhythm.glitches,
            "steady": steady,
        ])
        XCTAssertGreaterThan(Double(tones.humWindows), 0.8 * Double(tones.windows), "The mock's 150 Hz hum runs throughout")
        // A burst falls every second; a gap, or either end of the recording, can take one.
        let expectedBursts = Int((audio.duration - 0.07).rounded(.down))
        XCTAssertGreaterThanOrEqual(bursts.count, expectedBursts - 1, "Expected about \(expectedBursts) bursts, got \(burstList)")
        XCTAssertTrue(bursts.contains { $0.kind == .bip }, "Expected the mock's 1500 Hz bip: \(burstList)")
        XCTAssertTrue(bursts.contains { $0.kind == .bop }, "Expected the mock's 500 Hz bop: \(burstList)")
        XCTAssertTrue(steady, "The bursts must keep the mock's 1 s rhythm, but for \(allowedGlitches) gap(s): \(burstList), offsets \(rhythm.offsetsMilliseconds) ms, page \(pageCounts)")
        XCTAssertEqual(audio.appliedGainDB, 0, "The mock is already loud; no gain should apply")

        if sawActiveMicrophone {
            try await harness.waitUntil("WebKit to release the microphone", timeout: 5) {
                harness.capture.webView.microphoneCaptureState == .none
            }
        }
    }

    private static let microphoneRecordingSeconds: TimeInterval = 4.2

    /// Named to run first, while WebKit's processes are still cold. A keyboard idles between
    /// dictations, so an idle page must still answer and start the next capture.
    @MainActor
    func testAnIdlePageStillAnswers() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        try await Task.sleep(nanoseconds: 300_000_000)
        harness.capture.cancel()
        try await harness.waitForPageSession(toEndWith: "cancelled")

        try await Task.sleep(nanoseconds: 1_500_000_000)
        let probedAt = Date()
        let answer = try await harness.evaluate("6 * 7", timeout: 15) as? Int
        harness.record("idle page probe", ["answer": answer ?? -1, "seconds": Date().timeIntervalSince(probedAt)])
        XCTAssertEqual(answer, 42)

        harness.start()
        try await harness.waitForStart(timeout: 10)
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        XCTAssertGreaterThanOrEqual(audio.frameCount, CaptureRecording.minimumFrameCount)
    }

    @MainActor
    func testCancelDeletesTheRecordingWithoutACallback() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()

        harness.start()
        try await harness.waitForStart(timeout: 10)
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        harness.capture.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Cancel must delete the audio")
        XCTAssertNil(harness.capture.recordingFileURL)
        XCTAssertEqual(harness.capture.state, .ready)

        // The next capture is unaffected, and the cancelled one never reports.
        harness.start()
        try await harness.waitForStart(timeout: 10)
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        XCTAssertNotEqual(audio.fileURL, fileURL)
        XCTAssertGreaterThanOrEqual(audio.frameCount, CaptureRecording.minimumFrameCount)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(harness.terminalEvents, [.finished(audio)], "Only the second capture reports")
    }

    @MainActor
    func testStopBeforeAnyAudioReportsNoAudio() async throws {
        let harness = try await CaptureHarness.make(synthetic: false)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        try await harness.run("navigator.mediaDevices.getUserMedia = () => new Promise(() => {})")

        harness.start()
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)
        harness.capture.stop()
        let event = try await harness.waitForTerminalEvent(timeout: 5)

        XCTAssertEqual(event, .failed(.noAudio))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(harness.capture.state, .ready)
    }

    @MainActor
    func testStartTimesOutWhenNoAudioArrives() async throws {
        let harness = try await CaptureHarness.make(synthetic: false)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        try await harness.run("navigator.mediaDevices.getUserMedia = () => new Promise(() => {})")

        let startedAt = Date()
        harness.start()
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)
        let event = try await harness.waitForTerminalEvent(timeout: 10)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(event, .failed(.startTimedOut))
        XCTAssertGreaterThanOrEqual(elapsed, WebAudioCapture.startTimeout - 0.05)
        XCTAssertLessThan(elapsed, WebAudioCapture.startTimeout + 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(harness.capture.state, .ready)
        try await harness.waitForPageSession(toEndWith: "cancelled")
    }

    @MainActor
    func testNotAllowedErrorMeansPermissionDenied() async throws {
        let harness = try await CaptureHarness.make(synthetic: false)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        try await harness.run("navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('Denied', 'NotAllowedError'))")

        harness.start()
        let event = try await harness.waitForTerminalEvent(timeout: 10)

        XCTAssertEqual(event, .failed(.permissionDenied))
        XCTAssertEqual(harness.capture.state, .ready)
    }

    @MainActor
    func testMissingMediaDevicesIsUnsupported() async throws {
        let harness = try await CaptureHarness.make(synthetic: false)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        try await harness.run("Object.defineProperty(navigator, 'mediaDevices', { value: undefined, configurable: true })")

        harness.start()
        let event = try await harness.waitForTerminalEvent(timeout: 10)

        XCTAssertEqual(event, .failed(.unsupported("MediaDevicesUnavailable")))
    }

    @MainActor
    func testPageHideInterruptsAndDiscards() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)

        try await harness.run("dispatchEvent(new Event('pagehide'))")
        let event = try await harness.waitForTerminalEvent(timeout: 5)

        XCTAssertEqual(event, .failed(.interrupted("pagehide")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(harness.capture.state, .ready)
    }

    @MainActor
    func testStopFinishesWhenThePageNeverAnswers() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        try await Task.sleep(nanoseconds: 500_000_000)
        try await harness.run("ffCapture.stop = function () {}")

        let stoppedAt = Date()
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        let elapsed = Date().timeIntervalSince(stoppedAt)

        XCTAssertGreaterThanOrEqual(elapsed, WebAudioCapture.stopTimeout - 0.05)
        XCTAssertLessThan(elapsed, KeyboardDictationMachine.stopBackstop - 1, "The capture must finish well before the keyboard gives up on it")
        XCTAssertGreaterThan(audio.duration, 0.4)
        XCTAssertNil(audio.pageContinuity, "A page that never ended reported nothing")
        try await harness.waitForPageSession(toEndWith: "cancelled")

        // Each capture can set its own wait.
        harness.capture.stopTimeoutInterval = 0.4
        harness.start()
        try await harness.waitForStart(timeout: 10)
        let shortStopAt = Date()
        harness.capture.stop()
        _ = try await harness.waitForRecording(timeout: 10)
        let shortElapsed = Date().timeIntervalSince(shortStopAt)
        XCTAssertGreaterThanOrEqual(shortElapsed, 0.35)
        XCTAssertLessThan(shortElapsed, WebAudioCapture.stopTimeout - 0.5)
        try await harness.waitForPageSession(toEndWith: "cancelled")
    }

    /// A page that stalls at stop for longer than the old 1 s wait, but within `stopTimeout`,
    /// still delivers the end of the recording: its final flush is kept, not cut off.
    @MainActor
    func testSlowFinalFlushWithinTheStopWaitIsKept() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        try await Task.sleep(nanoseconds: 800_000_000)
        // The stop command first blocks the page's script thread, as a stalled page would, then
        // stops for real. The synthetic source then delivers the time that passed. The stall
        // outlasts the old 1 s wait and leaves the rest of the stop wait for CI's own stalls.
        let stall = 1.2
        XCTAssertGreaterThanOrEqual(WebAudioCapture.stopTimeout, stall + 1.2, "The stall must fall well inside the stop wait")
        try await harness.run("""
            (() => {
              const stop = ffCapture.stop;
              ffCapture.stop = (sid) => { const end = Date.now() + \(Int(stall * 1000)); while (Date.now() < end) {} stop(sid); };
            })()
            """)

        let stoppedAt = Date()
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        let elapsed = Date().timeIntervalSince(stoppedAt)
        let status = try await harness.pageStatus()
        harness.record("slow stop flush", [
            "elapsedSeconds": elapsed,
            "frames": audio.frameCount,
            "pageFrames": status["frames"] ?? -1,
            "pageReason": status["reason"] ?? "",
        ])

        XCTAssertGreaterThanOrEqual(elapsed, stall - 0.05, "The capture waited for the stalled page")
        XCTAssertEqual(status["reason"] as? String, "stopped", "The page finished its own stop")
        XCTAssertNotNil(audio.pageContinuity, "The page's ended message arrived within the stop wait")
        XCTAssertEqual(audio.frameCount, status["frames"] as? Int, "Every frame the page sent, its final flush included, is kept")
        XCTAssertGreaterThan(audio.duration, 0.8 + stall - 0.3, "The recording covers the stall")
        XCTAssertEqual(harness.terminalEvents.count, 1)
    }

    /// Every capture starts with a stop wait that ends inside the keyboard's stop backstop.
    @MainActor
    func testStopWaitDefaultsInsideTheKeyboardsBackstop() {
        XCTAssertEqual(WebAudioCapture.stopTimeout, CaptureTiming.stopTimeout)
        XCTAssertEqual(WebAudioCapture().stopTimeoutInterval, WebAudioCapture.stopTimeout)
        XCTAssertLessThan(WebAudioCapture.stopTimeout, KeyboardDictationMachine.stopBackstop)
    }

    /// WebKit's own handling of a terminated web content process: the session fails, its file is
    /// deleted, the page reloads in a new process, and capture works again.
    @MainActor
    func testWebContentProcessTerminationFailsAndReloads() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)
        let page = harness.capture.webView
        let killedProcess = CaptureHarness.webContentProcessIdentifier(of: page)

        // Test-only WebKit SPI. It asks for the process to end, then runs WebKit's own handling
        // of a terminated process, which calls webViewWebContentProcessDidTerminate, whether or
        // not the system lets the kill through. The plain _killWebContentProcess waits for the
        // process to die, and RunningBoard sometimes refuses to kill it for the simulator's test
        // host ("Client not entitled"), which left the process running and nothing reported.
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        guard page.responds(to: kill) else {
            throw XCTSkip("This WebKit has no _killWebContentProcessAndResetState, so the test can't end the page's web content process")
        }
        let killedAt = Date()
        page.perform(kill)
        let event = try await harness.waitForTerminalEvent(timeout: 5)
        harness.record("web process termination", [
            "notifiedAfterMs": Int(Date().timeIntervalSince(killedAt) * 1000),
            "knewProcess": killedProcess != nil,
        ])

        XCTAssertEqual(event, .failed(.pageUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        // A reload slower than pageLoadTimeout gets a fresh web view instead; that is a slow
        // runner, not this path, so it gets its own message.
        try await harness.waitUntil("the page to reload", timeout: WebAudioCapture.pageLoadTimeout + 5) {
            harness.events.filter { $0 == .ready }.count == 2
        }
        XCTAssertEqual(harness.capture.state, .ready)
        XCTAssertTrue(harness.capture.webView === page, "The page must reload in its own web view; the page-load watchdog replaced it")
        let reloadedProcess = CaptureHarness.webContentProcessIdentifier(of: harness.capture.webView)
        harness.record("web process after reload", [
            "newProcess": reloadedProcess != nil && reloadedProcess != killedProcess,
            "oldProcess": killedProcess.map { CaptureHarness.processState($0) } ?? "unknown",
        ])
        if let killedProcess, let reloadedProcess {
            XCTAssertNotEqual(reloadedProcess, killedProcess, "The page must reload in a new web content process")
        }

        harness.start()
        try await harness.waitForStart(timeout: 10)
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        XCTAssertGreaterThanOrEqual(audio.frameCount, CaptureRecording.minimumFrameCount)
    }

    @MainActor
    func testNavigationIsLockedToThePage() async throws {
        let harness = try await CaptureHarness.make()
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()

        // about:blank would commit at once if the lock let it through.
        try await harness.run("window.__marker = 'kept'; location.href = 'about:blank'")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let marker = try await harness.evaluate("window.__marker") as? String
        XCTAssertEqual(marker, "kept", "The page must not have navigated")
        XCTAssertEqual(harness.capture.webView.url?.host, CapturePageSource.host)
        XCTAssertEqual(harness.events, [.ready])
        XCTAssertEqual(harness.capture.state, .ready)
    }

    @MainActor
    func testDetachKeepsThePageLoadedForTheNextAttach() async throws {
        let harness = try await CaptureHarness.make()
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        try await harness.run("window.__marker = 'kept'")

        harness.capture.detach()
        XCTAssertEqual(harness.capture.state, .detached)
        XCTAssertNil(harness.capture.webView.superview)

        harness.capture.attach(to: harness.hostView)
        XCTAssertEqual(harness.capture.state, .ready)
        XCTAssertEqual(harness.events, [.ready, .ready])
        harness.capture.attach(to: harness.hostView)
        XCTAssertEqual(harness.events, [.ready, .ready], "Attaching again changes nothing")
        let marker = try await harness.evaluate("window.__marker") as? String
        XCTAssertEqual(marker, "kept", "Re-attaching must not reload the page")
    }

    @MainActor
    func testStartWhileDetachedFailsImmediately() async throws {
        let harness = try await CaptureHarness.make()
        defer { harness.tearDown() }

        harness.start()

        XCTAssertEqual(harness.events, [.failed(.pageUnavailable)])
        XCTAssertEqual(harness.capture.state, .detached)
    }

    @MainActor
    func testStartDuringPageLoadWaitsForThePage() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        harness.capture.attach(to: harness.hostView)
        XCTAssertEqual(harness.capture.state, .loading)

        harness.capture.startTimeoutInterval = 30 // a cold page load on CI
        harness.start()
        XCTAssertEqual(harness.capture.state, .starting)
        try await harness.waitForStart(timeout: 35)
        harness.capture.stop()
        _ = try await harness.waitForRecording(timeout: 10)

        XCTAssertFalse(harness.events.contains(.ready), "A start that waited for the page reports no ready")
        XCTAssertEqual(harness.capture.state, .ready)
    }

    /// A page whose WebContent process stops running script for a few seconds fails starts
    /// with pageUnavailable, refuses new ones until it answers, then works again in place.
    @MainActor
    func testBrieflyStalledPageRecoversInPlace() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        let page = harness.capture.webView
        try await harness.run(Self.stallScript(seconds: 5))

        harness.start()
        let event = try await harness.waitForTerminalEvent(timeout: 10)
        XCTAssertEqual(event, .failed(.pageUnavailable))
        harness.start()
        XCTAssertEqual(Array(harness.sessionEvents), [.failed(.pageUnavailable)], "A stalled page refuses new starts at once")

        // This runs once the stall ends, behind the unanswered start and its cancel.
        let answer = try await harness.evaluate("6 * 7", timeout: 15) as? Int
        XCTAssertEqual(answer, 42)
        XCTAssertTrue(harness.capture.webView === page, "A brief stall keeps the page")
        harness.start()
        try await harness.waitForStart(timeout: 10)
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        XCTAssertGreaterThanOrEqual(audio.frameCount, CaptureRecording.minimumFrameCount)
    }

    /// A page stuck past the liveness timeout gets a fresh web view, and with it a new
    /// WebContent process, so capture works while the old process is still stuck.
    @MainActor
    func testStuckPageIsReplacedByAFreshWebView() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        let stuck = harness.capture.webView
        try await harness.run(Self.stallScript(seconds: WebAudioCapture.pageLivenessTimeout + 6))

        harness.start()
        let event = try await harness.waitForTerminalEvent(timeout: 10)
        XCTAssertEqual(event, .failed(.pageUnavailable))
        try await harness.waitUntil("the stuck web view to be replaced", timeout: WebAudioCapture.pageLivenessTimeout + 5) {
            harness.capture.webView !== stuck
        }
        XCTAssertNil(stuck.superview)
        XCTAssertTrue(harness.capture.webView.window === harness.window)

        try await harness.waitUntil("the fresh page to load", timeout: 30) { harness.capture.isReady }
        harness.start()
        try await harness.waitForStart(timeout: 10)
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        XCTAssertGreaterThanOrEqual(audio.frameCount, CaptureRecording.minimumFrameCount)
    }

    /// Blocks the page's script thread, standing in for a WebContent process that stalls.
    private static func stallScript(seconds: TimeInterval) -> String {
        "setTimeout(() => { const end = Date.now() + \(Int(seconds * 1000)); while (Date.now() < end) {} }, 0)"
    }

    func testMicrophoneIsGrantedOnlyToTheCapturePagesMainFrame() {
        let host = CapturePageSource.host
        XCTAssertTrue(WebAudioCapture.shouldGrantMediaCapture(type: .microphone, originProtocol: "https", originHost: host, isMainFrame: true))
        XCTAssertFalse(WebAudioCapture.shouldGrantMediaCapture(type: .camera, originProtocol: "https", originHost: host, isMainFrame: true))
        XCTAssertFalse(WebAudioCapture.shouldGrantMediaCapture(type: .cameraAndMicrophone, originProtocol: "https", originHost: host, isMainFrame: true))
        XCTAssertFalse(WebAudioCapture.shouldGrantMediaCapture(type: .microphone, originProtocol: "https", originHost: host, isMainFrame: false))
        XCTAssertFalse(WebAudioCapture.shouldGrantMediaCapture(type: .microphone, originProtocol: "http", originHost: host, isMainFrame: true))
        XCTAssertFalse(WebAudioCapture.shouldGrantMediaCapture(type: .microphone, originProtocol: "https", originHost: "example.invalid", isMainFrame: true))
    }

    /// Turns a failed microphone start into a skip when the simulator can't run Web Audio,
    /// and into a failure otherwise. Either way the page status goes in the message. The
    /// page's endedIn field survives the cancel that follows a start timeout.
    private static func explainMicrophoneFailure(_ event: CaptureHarness.Event, status: [String: Any]) throws {
        let endedIn = status["endedIn"] as? String ?? ""
        let callbacks = status["callbacks"] as? Int ?? 0
        let summary = status.keys.sorted().map { "\($0)=\(status[$0] ?? "")" }.joined(separator: " ")
        let neverRendered = endedIn == "context" || (endedIn == "running" && callbacks == 0)
        let noAudio = event == .failed(.startTimedOut) || event == .failed(.interrupted("no-audio"))
        if noAudio && neverRendered {
            throw XCTSkip("The simulator's AudioContext never rendered audio, so real capture can't run on this machine. Page status: \(summary)")
        }
        XCTFail("Microphone capture failed with \(event). Page status: \(summary)")
        throw CaptureTestError.microphoneFailed
    }
}

enum CaptureTestError: Error {
    case timedOut(String)
    case noWindowScene
    case microphoneFailed
    case startFailed
    case badWAV
    /// evaluateJavaScript got no answer: the page's web process isn't running script.
    case pageUnresponsive(String)
}

/// Owns a window, a WebAudioCapture attached to it, and the delegate events it reports.
@MainActor
final class CaptureHarness: WebAudioCaptureDelegate {
    enum Event: Equatable {
        case ready
        case started
        case finished(CapturedAudio)
        case failed(WebAudioCaptureFailure)

        var isTerminal: Bool {
            switch self {
            case .finished, .failed: return true
            case .ready, .started: return false
            }
        }
    }

    let window: UIWindow
    let capture: WebAudioCapture
    private(set) var events: [Event] = []
    private(set) var levels: [Float] = []
    private var recordings: [URL] = []
    private var sessionStart = 0

    static func make(synthetic: Bool = false) async throws -> CaptureHarness {
        let scene = try await foregroundScene()
        return CaptureHarness(scene: scene, synthetic: synthetic)
    }

    private init(scene: UIWindowScene, synthetic: Bool) {
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        let capture = WebAudioCapture()
        #if DEBUG
        capture.syntheticSourceOverride = synthetic
        #endif
        self.window = window
        self.capture = capture
        capture.delegate = self
    }

    var hostView: UIView { window.rootViewController?.view ?? window }

    var terminalEvents: [Event] { events.filter(\.isTerminal) }

    /// Events since the last `start()`.
    var sessionEvents: ArraySlice<Event> { events[sessionStart...] }

    /// Starts a capture and marks where its events begin, so a synchronous failure counts too.
    func start() {
        sessionStart = events.count
        capture.start()
    }

    func tearDown() {
        capture.delegate = nil
        capture.detach()
        window.isHidden = true
        window.rootViewController = nil
        for url in recordings {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: WebAudioCaptureDelegate

    func webAudioCaptureDidBecomeReady(_ capture: WebAudioCapture) {
        events.append(.ready)
    }

    func webAudioCaptureDidStart(_ capture: WebAudioCapture) {
        events.append(.started)
    }

    func webAudioCapture(_ capture: WebAudioCapture, didUpdateLevel level: Float) {
        levels.append(level)
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFinish audio: CapturedAudio) {
        recordings.append(audio.fileURL)
        events.append(.finished(audio))
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFail failure: WebAudioCaptureFailure) {
        events.append(.failed(failure))
    }

    // MARK: Waiting

    func waitUntil(
        _ description: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out after \(timeout) s waiting for \(description). Events: \(events)", file: file, line: line)
                throw CaptureTestError.timedOut(description)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func attachAndWaitForReady(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) async throws {
        capture.attach(to: hostView)
        try await waitUntil("the capture page to load", timeout: timeout, file: file, line: line) { capture.isReady }
    }

    /// Waits for the capture started last to become audible, and stops waiting as soon as it
    /// fails instead.
    func waitForStart(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("audible audio", timeout: timeout, file: file, line: line) {
            sessionEvents.contains(.started) || sessionEvents.contains(where: \.isTerminal)
        }
        guard sessionEvents.contains(.started) else {
            await recordDiagnostics("failed start")
            XCTFail("Capture failed to start: \(Array(sessionEvents))", file: file, line: line)
            throw CaptureTestError.startFailed
        }
    }

    /// The finish or failure of the capture started last.
    func waitForTerminalEvent(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws -> Event {
        try await waitUntil("a finish or a failure", timeout: timeout, file: file, line: line) {
            sessionEvents.contains(where: \.isTerminal)
        }
        guard let event = sessionEvents.first(where: \.isTerminal) else { throw CaptureTestError.timedOut("a terminal event") }
        return event
    }

    func waitForRecording(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws -> CapturedAudio {
        let event = try await waitForTerminalEvent(timeout: timeout, file: file, line: line)
        guard case .finished(let audio) = event else {
            await recordDiagnostics("missing recording")
            XCTFail("Expected a recording, got \(event)", file: file, line: line)
            throw CaptureTestError.badWAV
        }
        return audio
    }

    func waitForPageSession(
        toEndWith reason: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = try await pageStatus(file: file, line: line)
            if status["phase"] as? String == "ended", status["reason"] as? String == reason { return }
            guard Date() < deadline else {
                XCTFail("The page session did not end with \(reason): \(status)", file: file, line: line)
                throw CaptureTestError.timedOut(reason)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Records what a failed wait needs for triage: capture and page state, never audio.
    func recordDiagnostics(_ name: String) async {
        var values = (try? await pageStatus(timeout: 3, failOnTimeout: false)) ?? ["page": "no answer within 3 s"]
        values["captureState"] = "\(capture.state)"
        values["webViewLoading"] = capture.webView.isLoading
        values["webViewInWindow"] = capture.webView.window != nil
        values["sceneActivation"] = window.windowScene?.activationState.rawValue ?? -1
        values["microphoneCaptureState"] = capture.webView.microphoneCaptureState.rawValue
        record(name, values)
    }

    // MARK: Page access

    /// evaluateJavaScript that gives up after `timeout`, so a page whose web process stopped
    /// running script fails the test instead of hanging the suite.
    func evaluate(
        _ script: String,
        timeout: TimeInterval = 10,
        failOnTimeout: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Any? {
        let reply = beginEvaluation(script)
        let sentAt = Date()
        let deadline = sentAt.addingTimeInterval(timeout)
        while !reply.isDone {
            guard Date() < deadline else {
                if failOnTimeout {
                    XCTFail("The page did not answer within \(timeout) s: \(script.prefix(60))", file: file, line: line)
                }
                throw CaptureTestError.pageUnresponsive(String(script.prefix(60)))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let seconds = Date().timeIntervalSince(sentAt)
        if seconds > WebAudioCapture.startTimeout {
            record("slow page answer", ["seconds": seconds, "script": String(script.prefix(40))])
        }
        if let error = reply.error {
            XCTFail("The page threw for \(script.prefix(60)): \(error)", file: file, line: line)
            throw error
        }
        return reply.result
    }

    /// Starts an evaluation from a synchronous context, where the completion-handler API is
    /// the one to use; `evaluate` polls the reply so it can give up.
    private func beginEvaluation(_ script: String) -> PageReply {
        let reply = PageReply()
        capture.webView.evaluateJavaScript(script) { result, error in
            reply.result = result
            reply.error = error
            reply.isDone = true
        }
        return reply
    }

    /// Runs a statement in the page and ignores its value.
    func run(_ statement: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await evaluate("\(statement); 0", file: file, line: line)
    }

    func evaluateJSON(
        _ script: String,
        timeout: TimeInterval = 10,
        failOnTimeout: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Any] {
        let json = try await evaluate(script, timeout: timeout, failOnTimeout: failOnTimeout, file: file, line: line) as? String ?? "{}"
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    }

    /// The page's `ffCapture.status()`: states and counts, never audio.
    func pageStatus(
        timeout: TimeInterval = 10,
        failOnTimeout: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Any] {
        try await evaluateJSON("JSON.stringify(ffCapture.status())", timeout: timeout, failOnTimeout: failOnTimeout, file: file, line: line)
    }

    /// Prints diagnostics and keeps them in the result bundle.
    func record(_ name: String, _ values: [String: Any]) {
        let line = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: " ")
        print("[CaptureTests] \(name): \(line)")
        XCTContext.runActivity(named: "\(name): \(line)") { activity in
            let attachment = XCTAttachment(string: line)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// The web view's WebContent process id, from test-only WebKit SPI; nil without one.
    static func webContentProcessIdentifier(of webView: WKWebView) -> Int32? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let identifier = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              identifier > 0 else { return nil }
        return identifier
    }

    /// Whether a process still exists, found by sending it no signal at all.
    static func processState(_ identifier: Int32) -> String {
        if kill(identifier, 0) == 0 { return "alive" }
        let error = errno
        return error == ESRCH ? "exited" : "unknown(\(error))"
    }

    static func loadWAV(_ url: URL) throws -> (sampleRate: Int, channels: Int, samples: [Int16]) {
        let data = try Data(contentsOf: url)
        guard let wav = WAVEncoder.decode(data) else { throw CaptureTestError.badWAV }
        // The writer always produces the canonical 44-byte header.
        XCTAssertEqual(data.prefix(WAVEncoder.headerByteCount), WAVEncoder.header(dataByteCount: wav.samples.count * 2))
        return wav
    }

    private static func foregroundScene() async throws -> UIWindowScene {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) {
                return scene
            }
            if Date() >= deadline {
                if let scene = scenes.first(where: { $0.activationState == .foregroundInactive }) {
                    print("[CaptureTests] Using a foreground-inactive scene")
                    return scene
                }
                XCTFail("No foreground window scene. Scene states: \(scenes.map { $0.activationState.rawValue })")
                throw CaptureTestError.noWindowScene
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

enum ToneAnalysis {
    /// Goertzel power of `frequency` in 16 kHz samples, normalized so a full-length sine of
    /// amplitude A gives about A² / 4.
    static func power(_ samples: ArraySlice<Int16>, frequency: Double, sampleRate: Double = 16_000) -> Double {
        guard !samples.isEmpty else { return 0 }
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) / 32_768 + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        let count = Double(samples.count)
        return power / (count * count)
    }

    /// Counts 20 ms windows (10 ms apart) holding the WebKit mock's hum, bip and bop.
    static func mockDeviceTones(in samples: [Int16]) -> (windows: Int, humWindows: Int, bipWindows: Int, bopWindows: Int) {
        var windows = 0, hum = 0, bip = 0, bop = 0
        var start = 0
        while start + 320 <= samples.count {
            let window = samples[start..<start + 320]
            windows += 1
            if power(window, frequency: 150) > 0.0005 { hum += 1 }
            switch mockDeviceBurstKind(in: window) {
            case .bip?: bip += 1
            case .bop?: bop += 1
            case nil: break
            }
            start += 160
        }
        return (windows, hum, bip, bop)
    }

    /// Which of the mock's bursts a 20 ms window holds, if either.
    static func mockDeviceBurstKind(in window: ArraySlice<Int16>) -> MockBurst.Kind? {
        let p500 = power(window, frequency: 500)
        let p1500 = power(window, frequency: 1_500)
        if p1500 > 0.01 && p1500 > 4 * p500 { return .bip }
        if p500 > 0.01 && p500 > 4 * p1500 { return .bop }
        return nil
    }

    /// One of the mock's bursts, found as a run of consecutive windows that hold it.
    struct MockBurst: Equatable {
        enum Kind {
            case bip
            case bop
        }

        let kind: Kind
        /// The middle of the burst, in seconds from the start of the recording.
        let time: Double
        /// Windows in the run. A whole 70 ms burst fills 7 or 8.
        let windows: Int

        /// A whole burst, so its middle is timed to within about 5 ms.
        var isWhole: Bool { windows >= 6 }

        var summary: String {
            "\(kind == .bip ? "bip" : "bop")@\(String(format: "%.3f", time))s/\(windows)"
        }
    }

    /// The mock's bursts: runs of at least three consecutive windows holding the same one.
    static func mockDeviceBursts(in samples: [Int16]) -> [MockBurst] {
        var kinds: [MockBurst.Kind?] = []
        var start = 0
        while start + 320 <= samples.count {
            kinds.append(mockDeviceBurstKind(in: samples[start..<start + 320]))
            start += 160
        }
        var bursts: [MockBurst] = []
        var first = 0
        while first < kinds.count {
            guard let kind = kinds[first] else {
                first += 1
                continue
            }
            var end = first + 1
            while end < kinds.count && kinds[end] == kind {
                end += 1
            }
            if end - first >= 3 {
                // Window i spans samples 160 i ..< 160 i + 320, so the run's middle is halfway
                // between the middles of its first and last windows.
                let middle = Double(160 * first + 160 * (end - 1) + 320) / 2 / 16_000
                bursts.append(MockBurst(kind: kind, time: middle, windows: end - first))
            }
            first = end
        }
        return bursts
    }

    /// How whole bursts keep the mock's rhythm. Successive bursts are a whole number of seconds
    /// apart: 1 s from a bip to a bop, 2 s when the burst between them is missing or cut short.
    ///
    /// The simulator's mock makes audio 1.6% too fast (896 frames per 20 ms tick at 44.1 kHz), so
    /// WebKit's media stream buffer grows. At 100 ms, WebKit plays it 5% fast until it is under
    /// 40 ms ("AudioSampleDataConverter::updateBufferedAmount high buffer"): about 1.3 s that
    /// lose about 70 ms, every 5 s or so. That bends the spacings in and out of the stretch, and
    /// raises a bip inside it to 1579 Hz, past the 1500 Hz detector, so that bip goes missing.
    ///
    /// Late callbacks move nothing: when a stalled page catches up, WebKit hands its queued
    /// callbacks its latest buffers again, which replaces the stalled stretch and can repeat a
    /// burst 85 ms apart. The mock never puts two bursts that close, so those are left out of
    /// the timing and counted as repeats.
    struct MockRhythm {
        /// Spacings this close to a whole number of seconds have no gap in them.
        static let exactOffset = 0.02
        /// A spacing off by more than this lost more audio than a brief stall in WebKit would.
        static let maximumOffset = 0.3
        /// Bursts closer than this to another are repeats: the mock's own are 1 s apart, and
        /// repeats about 85 ms.
        static let repeatSpacing = 0.2

        /// How far each spacing between timed bursts is from its whole number of seconds.
        let offsets: [Double]
        /// Whether bip and bop alternate as those whole numbers of seconds say they should.
        let alternates: Bool
        /// Bursts left out of the timing because another one is within `repeatSpacing`.
        let repeats: Int

        init(_ bursts: [MockBurst]) {
            let closeness = MockRhythm.repeatSpacing
            let repeated = bursts.indices.map { index in
                (index > 0 && bursts[index].time - bursts[index - 1].time < closeness)
                    || (index + 1 < bursts.count && bursts[index + 1].time - bursts[index].time < closeness)
            }
            let timed = zip(bursts, repeated).filter { $0.0.isWhole && !$0.1 }.map { $0.0 }
            var offsets: [Double] = []
            var alternates = true
            for (earlier, later) in zip(timed, timed.dropFirst()) {
                let spacing = later.time - earlier.time
                let seconds = max(1, spacing.rounded())
                offsets.append(spacing - seconds)
                if (Int(seconds) % 2 == 1) != (earlier.kind != later.kind) {
                    alternates = false
                }
            }
            self.offsets = offsets
            self.alternates = alternates
            repeats = repeated.filter { $0 }.count
        }

        /// Spacings off their whole number of seconds by more than `exactOffset`.
        var glitches: Int {
            offsets.filter { abs($0) > Self.exactOffset }.count
        }

        /// The bursts alternate on whole seconds, at most `allowedGlitches` spacings are off,
        /// and none by more than a gap could explain.
        func isSteady(allowingGlitches allowedGlitches: Int) -> Bool {
            guard alternates, !offsets.isEmpty else { return false }
            return glitches <= allowedGlitches && offsets.allSatisfy { abs($0) <= Self.maximumOffset }
        }

        var offsetsMilliseconds: String {
            offsets.map { String(Int(($0 * 1_000).rounded())) }.joined(separator: " ")
        }
    }
}

/// The answer to one evaluateJavaScript call, filled in by its completion handler.
@MainActor
private final class PageReply {
    var isDone = false
    var result: Any?
    var error: Error?
}
