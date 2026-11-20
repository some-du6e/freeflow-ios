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

    /// Real getUserMedia capture against WebKit's simulator mock microphone.
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

        // At least one bip and one bop fall in any 2.1 s stretch of the mock's loop.
        var sawActiveMicrophone = false
        let recordUntil = Date().addingTimeInterval(2.6)
        while Date() < recordUntil {
            if harness.capture.webView.microphoneCaptureState == .active {
                sawActiveMicrophone = true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        harness.capture.stop()
        let audio = try await harness.waitForRecording(timeout: 10)
        harness.record("microphone recording", [
            "frames": audio.frameCount,
            "appliedGainDB": Double(audio.appliedGainDB),
            "sawActiveMicrophone": sawActiveMicrophone,
        ])

        let wav = try CaptureHarness.loadWAV(audio.fileURL)
        XCTAssertEqual(wav.sampleRate, 16_000)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertGreaterThan(audio.duration, 2)
        let tones = ToneAnalysis.mockDeviceTones(in: wav.samples)
        harness.record("mock device tones", [
            "windows": tones.windows,
            "humWindows": tones.humWindows,
            "bipWindows": tones.bipWindows,
            "bopWindows": tones.bopWindows,
        ])
        XCTAssertGreaterThan(Double(tones.humWindows), 0.8 * Double(tones.windows), "The mock's 150 Hz hum runs throughout")
        XCTAssertGreaterThan(tones.bipWindows, 0, "Expected the mock's 1500 Hz bip")
        XCTAssertGreaterThan(tones.bopWindows, 0, "Expected the mock's 500 Hz bop")
        XCTAssertEqual(audio.appliedGainDB, 0, "The mock is already loud; no gain should apply")

        if sawActiveMicrophone {
            try await harness.waitUntil("WebKit to release the microphone", timeout: 5) {
                harness.capture.webView.microphoneCaptureState == .none
            }
        }
    }

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

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(stoppedAt), WebAudioCapture.stopTimeout - 0.05)
        XCTAssertGreaterThan(audio.duration, 0.4)
        try await harness.waitForPageSession(toEndWith: "cancelled")
    }

    @MainActor
    func testWebContentProcessTerminationFailsAndReloads() async throws {
        let harness = try await CaptureHarness.make(synthetic: true)
        defer { harness.tearDown() }
        try await harness.attachAndWaitForReady()
        harness.start()
        try await harness.waitForStart(timeout: 10)
        let fileURL = try XCTUnwrap(harness.capture.recordingFileURL)

        // Test-only WebKit SPI that really ends the web content process.
        let kill = NSSelectorFromString("_killWebContentProcess")
        let killedForReal = harness.capture.webView.responds(to: kill)
        if killedForReal {
            harness.capture.webView.perform(kill)
        } else {
            harness.capture.webContentProcessDidTerminate()
        }
        harness.record("web process termination", ["killedForReal": killedForReal])
        let event = try await harness.waitForTerminalEvent(timeout: 10)

        XCTAssertEqual(event, .failed(.pageUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try await harness.waitUntil("the page to reload", timeout: 30) {
            harness.events.filter { $0 == .ready }.count == 2
        }
        XCTAssertEqual(harness.capture.state, .ready)

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
            let p150 = power(window, frequency: 150)
            let p500 = power(window, frequency: 500)
            let p1500 = power(window, frequency: 1_500)
            windows += 1
            if p150 > 0.0005 { hum += 1 }
            if p1500 > 0.01 && p1500 > 4 * p500 { bip += 1 }
            if p500 > 0.01 && p500 > 4 * p1500 { bop += 1 }
            start += 160
        }
        return (windows, hum, bip, bop)
    }
}

/// The answer to one evaluateJavaScript call, filled in by its completion handler.
@MainActor
private final class PageReply {
    var isDone = false
    var result: Any?
    var error: Error?
}
