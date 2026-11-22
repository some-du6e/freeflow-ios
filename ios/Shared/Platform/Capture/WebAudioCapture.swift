import os
import UIKit
import WebKit

/// A finished in-keyboard recording: 16 kHz mono 16-bit WAV on disk.
struct CapturedAudio: Equatable {
    let fileURL: URL
    let frameCount: Int
    let sampleRate: Int
    /// Gain applied at stop, in dB (0 when the audio was left unchanged).
    let appliedGainDB: Float
    /// The page's count of audio lost between WebKit's audio context and the page, from its
    /// `ended` message. Nil when the capture finished without one: the stop wait ran out, or the
    /// page went away.
    var pageContinuity: CaptureContinuity? = nil

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }
}

enum WebAudioCaptureFailure: Error, Equatable {
    /// The capture page isn't loaded, or its web process went away.
    case pageUnavailable
    /// No audio arrived within `WebAudioCapture.startTimeout` of `start()`.
    case startTimedOut
    /// WebKit refused the microphone (NotAllowedError), usually because the
    /// containing app doesn't hold microphone permission.
    case permissionDenied
    /// The page reports the platform can't capture, e.g. Lockdown Mode.
    case unsupported(String)
    /// Capture stopped on its own mid-recording (track ended, page hidden,
    /// native side unresponsive, audio context interrupted).
    case interrupted(String)
    /// Stopped with less than 0.01 s of audio.
    case noAudio
    case fileError
}

@MainActor
protocol WebAudioCaptureDelegate: AnyObject {
    func webAudioCaptureDidBecomeReady(_ capture: WebAudioCapture)
    /// The first non-silent audio arrived; show the recording state.
    func webAudioCaptureDidStart(_ capture: WebAudioCapture)
    /// Display level in 0...1, already smoothed for a waveform.
    func webAudioCapture(_ capture: WebAudioCapture, didUpdateLevel level: Float)
    func webAudioCapture(_ capture: WebAudioCapture, didFinish audio: CapturedAudio)
    func webAudioCapture(_ capture: WebAudioCapture, didFail failure: WebAudioCaptureFailure)
}

/// Microphone capture for the keyboard through a hidden WKWebView, because a
/// keyboard extension can't record with AVAudioSession itself. It lives in
/// ios/Shared so the app-hosted unit tests can exercise it in the simulator,
/// where WebKit substitutes a deterministic mock microphone.
///
/// WebKit records in its own processes and attributes the capture to the containing app, so
/// the app must hold microphone permission. The web view is 2×2 pt at alpha 0.02 and must
/// stay in the window while capturing: WebKit mutes pages that are hidden or detached.
///
/// A `start()` made while no capture is running gets exactly one `didFinish` or `didFail`,
/// unless `cancel()` or `detach()` discards it first. A `start()` during a capture is ignored,
/// with no callback. A failure can arrive synchronously, before `start()` returns
/// (`.pageUnavailable` when the web view isn't in a window, `.fileError` when the file can't
/// be created), or later; both of those can also arrive later.
///
/// Keep one instance per process: attach it in `viewDidAppear` and detach it in
/// `viewDidDisappear`. The page stays loaded in between, because reloading it costs the next
/// dictation a slow start. A page that stops running script fails starts with
/// `.pageUnavailable`; one that stays stuck for `pageLivenessTimeout` gets a fresh web view
/// and WebContent process.
///
/// The caller owns `CapturedAudio.fileURL` and should delete it after use. Logs carry only
/// states, ids, counts and durations.
@MainActor
final class WebAudioCapture: NSObject {
    enum State: Equatable {
        case detached
        case loading
        case ready
        case starting
        case capturing
        case stopping
    }

    /// What the page reported when its audio graph started, for logs and tests.
    struct StartInfo: Equatable {
        let session: Int
        let contextRate: Double
        let captureRate: Double
        let isSynthetic: Bool
    }

    /// Matches the macOS AudioRecorder buffer watchdog.
    static let startTimeout: TimeInterval = 2.0
    /// How long `stop()` waits by default for the page's final chunk before finishing with what
    /// arrived. It stays inside the keyboard's stop backstop (see `CaptureTiming`).
    static let stopTimeout: TimeInterval = CaptureTiming.stopTimeout
    /// A backstop: capture stops by itself after 10 minutes, which keeps the WAV (19.2 MB)
    /// under the providers' 25 MB upload limit. The keyboard stops sooner on its own.
    static let maximumDuration: TimeInterval = 600
    static let maximumFrameCount = Int(maximumDuration) * CaptureRecording.sampleRate
    /// Leftover recordings older than this are deleted when the capture attaches.
    static let staleRecordingAge: TimeInterval = 15 * 60
    /// A page that hasn't reported ready by then gets a fresh web view.
    static let pageLoadTimeout: TimeInterval = 10
    /// A page that leaves a start command unanswered this long gets a fresh web view. It is
    /// long because the usual cause, a cold GPU process, clears by itself in a few seconds,
    /// and a new WebContent process would wait on the same GPU process.
    static let pageLivenessTimeout: TimeInterval = 10
    /// Fresh web views tried for loads that time out, before waiting for the next attach.
    static let maximumPageReplacements = 2

    weak var delegate: WebAudioCaptureDelegate?
    private(set) var state: State = .detached

    var isReady: Bool { state == .ready }

    /// The first-audio watchdog for the next `start()`. Defaults to `startTimeout`; tests
    /// lengthen it for slow CI simulators.
    var startTimeoutInterval: TimeInterval = WebAudioCapture.startTimeout

    /// How long the next `stop()` waits for the page's final chunk. Defaults to `stopTimeout`;
    /// keep it under `KeyboardDictationMachine.stopBackstop`.
    var stopTimeoutInterval: TimeInterval = WebAudioCapture.stopTimeout

    #if DEBUG
    /// DEBUG builds only. When set, overrides the App Group flag
    /// `CapturePageSource.syntheticCaptureDefaultsKey`, which is read at every `start()`.
    var syntheticSourceOverride: Bool?
    #endif

    /// Where recordings are written: the process's temporary directory.
    let recordingsDirectory: URL
    /// The page reported by the latest session that started its audio graph.
    private(set) var lastStartInfo: StartInfo?

    /// The current web view. It changes only when a stuck page is replaced.
    private(set) var webView: WKWebView
    private let bridge: CaptureBridge
    private weak var hostView: UIView?
    private var isAttached = false
    private var isPageLoaded = false
    private var isPageLoading = false
    /// Loads this object started whose navigation the policy check hasn't seen yet.
    private var allowedPageLoads = 0
    private var pageLoadWatchdog: Task<Void, Never>?
    private var timedOutPageLoads = 0
    /// The oldest start command the current web view hasn't run yet.
    private var unansweredStart: (session: Int, page: ObjectIdentifier)?
    private var livenessCheck: Task<Void, Never>?
    private var nextSessionID = 1
    private var session: Session?
    private var lastStaleChunkSession: Int?

    fileprivate static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FreeFlow", category: "WebAudioCapture")

    #if DEBUG
    private static let includesSyntheticSource = true
    #else
    private static let includesSyntheticSource = false
    #endif

    override init() {
        let bridge = CaptureBridge()
        self.bridge = bridge
        webView = WebAudioCapture.makeWebView(bridge: bridge)
        recordingsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "FreeFlowCapture", directoryHint: .isDirectory)
        super.init()
        bridge.owner = self
    }

    /// Adds the hidden web view to `view` (it must stay in the window while
    /// capturing) and preloads the page. Safe to call repeatedly.
    func attach(to view: UIView) {
        let previous = state
        hostView = view
        if webView.superview !== view {
            view.addSubview(webView)
        }
        view.sendSubviewToBack(webView)
        if !isAttached {
            isAttached = true
            timedOutPageLoads = 0
            purgeStaleRecordings()
        }
        if !isPageLoaded && !isPageLoading {
            loadPage()
        }
        updateState(from: previous)
    }

    /// Cancels any capture and removes the web view.
    func detach() {
        let previous = state
        if session != nil {
            cancel()
            // Belt and braces in case the page can't run its own teardown.
            webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
        webView.removeFromSuperview()
        hostView = nil
        isAttached = false
        updateState(from: previous)
    }

    /// Starts capture. Results arrive through the delegate.
    func start() {
        guard session == nil else {
            Self.log.info("Capture start ignored: a capture is already running")
            return
        }
        #if DEBUG
        // UI tests reach the keyboard's fallback through this (WebAudioCaptureUITestSwitch).
        if WebAudioCaptureUITestSwitch.isOn() {
            Self.log.info("Capture start failed: capture is switched off for UI tests")
            delegate?.webAudioCapture(self, didFail: WebAudioCaptureUITestSwitch.failure)
            return
        }
        #endif
        guard isAttached, webView.window != nil else {
            Self.log.error("Capture start failed: the page is not in a window")
            delegate?.webAudioCapture(self, didFail: .pageUnavailable)
            return
        }
        if let pending = unansweredStart, pending.page == ObjectIdentifier(webView) {
            // Queuing another command behind a stalled page would only start it late.
            Self.log.error("Capture start failed: the page has not run session \(pending.session, privacy: .public)'s start command")
            delegate?.webAudioCapture(self, didFail: .pageUnavailable)
            return
        }

        let id = nextSessionID
        nextSessionID += 1
        let recording: CaptureRecording
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            let fileURL = recordingsDirectory.appending(path: "\(UUID().uuidString).wav", directoryHint: .notDirectory)
            recording = try CaptureRecording(session: id, fileURL: fileURL)
        } catch {
            Self.log.error("Capture start failed: could not create the recording file")
            delegate?.webAudioCapture(self, didFail: .fileError)
            return
        }

        let session = Session(id: id, recording: recording, isSynthetic: usesSyntheticSource)
        self.session = session
        session.watchdog = after(startTimeoutInterval) { [weak self] in
            self?.startTimeoutPassed(session: id)
        }
        updateState()
        Self.log.info("Capture session \(id, privacy: .public) starting, synthetic \(session.isSynthetic, privacy: .public), page loaded \(self.isPageLoaded, privacy: .public)")
        if isPageLoaded {
            startPage(session)
        } else if !isPageLoading {
            loadPage()
        }
    }

    /// Stops gracefully; the delegate receives `didFinish` or `didFail`.
    func stop() {
        guard let session, session.phase != .stopping else { return }
        session.phase = .stopping
        session.watchdog?.cancel()
        updateState()
        let id = session.id
        if session.hasStartedPage {
            sendPageCommand("stop", session: id)
            // A microphone session waits at most CaptureTiming.microphoneStopTimeout; see there.
            let wait = session.isSynthetic
                ? stopTimeoutInterval
                : min(stopTimeoutInterval, CaptureTiming.microphoneStopTimeout)
            session.stopDeadline = after(wait) { [weak self] in
                self?.stopTimeoutPassed(session: id)
            }
        } else {
            // The page never started, so there is nothing to wait for. Finishing on a later
            // turn keeps the delegate callback after stop() returns.
            session.stopDeadline = after(0) { [weak self] in
                self?.stopTimeoutPassed(session: id)
            }
        }
    }

    /// Stops and discards the recording without a delegate callback.
    func cancel() {
        guard let session else { return }
        end(session)
        session.recording.discard()
        if session.hasStartedPage {
            sendPageCommand("cancel", session: session.id)
        }
        Self.log.info("Capture session \(session.id, privacy: .public) cancelled")
    }

    // MARK: Testing and diagnostics

    /// The file the current session is writing, if any.
    var recordingFileURL: URL? { session?.recording.fileURL }

    /// Grants the microphone only to the capture page's own main frame.
    nonisolated static func shouldGrantMediaCapture(
        type: WKMediaCaptureType,
        originProtocol: String,
        originHost: String,
        isMainFrame: Bool
    ) -> Bool {
        type == .microphone && isMainFrame && originProtocol == "https" && originHost == CapturePageSource.host
    }

    /// Handles a parsed page message. Returns false to reject it, which the page sees as a
    /// failed acknowledgement.
    @discardableResult
    func handle(_ message: CaptureMessage) -> Bool {
        switch message {
        case .ready(let version, _):
            pageDidLoad(version: version)
            return true
        case .started(let id, let contextRate, let captureRate, let isSynthetic):
            guard let session, session.id == id else { return rejectStale("started", session: id) }
            lastStartInfo = StartInfo(session: id, contextRate: contextRate, captureRate: captureRate, isSynthetic: isSynthetic)
            Self.log.info("Capture session \(id, privacy: .public) audio graph started: context \(contextRate, privacy: .public) Hz, capture \(captureRate, privacy: .public) Hz, synthetic \(isSynthetic, privacy: .public)")
            return true
        case .pcm(let chunk):
            guard let session, session.id == chunk.session else { return rejectStale("pcm", session: chunk.session) }
            return receive(chunk, in: session)
        case .ended(let id, let reason, let frames, let continuity):
            guard let session, session.id == id else { return rejectStale("ended", session: id) }
            Self.log.info("Capture session \(id, privacy: .public) ended in the page: \(reason, privacy: .public), \(frames, privacy: .public) frames sent")
            session.pageContinuity = continuity
            if session.phase == .stopping {
                finish(session)
            } else {
                fail(session, .interrupted(reason), cancellingPage: false)
            }
            return true
        case .failed(let id, let name):
            guard let session, session.id == id else { return rejectStale("failed", session: id) }
            let failure: WebAudioCaptureFailure = CaptureMessage.failureKind(forName: name) == .permissionDenied
                ? .permissionDenied
                : .unsupported(name)
            fail(session, failure, cancellingPage: false)
            return true
        }
    }

    /// Ends any session and reloads the page, as after WebKit's content process exits.
    func webContentProcessDidTerminate() {
        Self.log.error("Capture web content process terminated")
        let session = self.session
        // Reload before reporting, so a retry from didFail waits for the new page.
        reloadPage()
        if let session {
            endForLostPage(session)
        }
    }

    // MARK: Page

    private static func makeWebView(bridge: CaptureBridge) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // A data store of its own also gives each web view its own WebContent process, which
        // is what lets replaceWebView() get away from a stuck one.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: .page,
            name: CapturePageSource.messageHandlerName
        )

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        webView.alpha = 0.02
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.uiDelegate = bridge
        webView.navigationDelegate = bridge
        return webView
    }

    private func loadPage() {
        isPageLoaded = false
        isPageLoading = true
        allowedPageLoads += 1
        pageLoadWatchdog?.cancel()
        pageLoadWatchdog = after(Self.pageLoadTimeout) { [weak self] in
            self?.pageLoadTimedOut()
        }
        webView.loadHTMLString(
            CapturePageSource.html(includeSyntheticSource: Self.includesSyntheticSource),
            baseURL: CapturePageSource.baseURL
        )
    }

    private func reloadPage() {
        let previous = state
        clearUnansweredStart()
        isPageLoaded = false
        isPageLoading = false
        if isAttached {
            loadPage()
        }
        updateState(from: previous)
    }

    /// Swaps in a new web view, and with it a new WebContent process, for a page that stopped
    /// running script: reloading in place would queue behind the stuck process. The old view
    /// keeps the bridge as its delegate, which rejects its messages and denies its capture
    /// requests, and it is released once it leaves the window.
    private func replaceWebView() {
        let old = webView
        old.stopLoading()
        old.setMicrophoneCaptureState(.none, completionHandler: nil)
        old.removeFromSuperview()
        webView = WebAudioCapture.makeWebView(bridge: bridge)
        if isAttached, let hostView {
            hostView.addSubview(webView)
            hostView.sendSubviewToBack(webView)
        }
        Self.log.info("Capture web view replaced")
        reloadPage()
    }

    private func pageLoadTimedOut() {
        guard isPageLoading, !isPageLoaded else { return }
        timedOutPageLoads += 1
        Self.log.error("Capture page did not load within \(Self.pageLoadTimeout, privacy: .public) s, attempt \(self.timedOutPageLoads, privacy: .public)")
        if isAttached && timedOutPageLoads <= Self.maximumPageReplacements {
            replaceWebView()
        } else {
            // The next attach() or start() loads again.
            isPageLoading = false
        }
    }

    private func pageDidLoad(version: Int) {
        let previous = state
        let reloadedUnderSession = isPageLoaded
        isPageLoaded = true
        isPageLoading = false
        allowedPageLoads = 0
        timedOutPageLoads = 0
        pageLoadWatchdog?.cancel()
        pageLoadWatchdog = nil
        if version != CapturePageSource.pageVersion {
            Self.log.error("Capture page version \(version, privacy: .public) differs from \(CapturePageSource.pageVersion, privacy: .public)")
        }
        if let session {
            if session.hasStartedPage || reloadedUnderSession {
                endForLostPage(session)
            } else if session.phase == .starting {
                startPage(session)
            }
            // A session stopped before the page loaded finishes on its own deadline.
        }
        updateState(from: previous)
    }

    fileprivate func pageLoadFailed(_ error: Error) {
        let error = error as NSError
        guard isPageLoading, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        Self.log.error("Capture page failed to load: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        isPageLoading = false
        pageLoadWatchdog?.cancel()
        pageLoadWatchdog = nil
    }

    fileprivate func receive(_ message: WKScriptMessage) -> Bool {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == CapturePageSource.host,
              let parsed = CaptureMessage(body: message.body) else {
            Self.log.error("Capture page message rejected")
            return false
        }
        return handle(parsed)
    }

    /// Navigation is locked to the page loads this object starts.
    fileprivate func shouldAllowNavigation(_ action: WKNavigationAction) -> Bool {
        let url = action.request.url
        guard allowedPageLoads > 0,
              action.targetFrame?.isMainFrame == true,
              url?.scheme == "https",
              url?.host == CapturePageSource.host else {
            Self.log.error("Capture page navigation blocked")
            return false
        }
        allowedPageLoads -= 1
        return true
    }

    private func startPage(_ session: Session) {
        session.hasStartedPage = true
        let id = session.id
        let page = ObjectIdentifier(webView)
        let sentAt = ProcessInfo.processInfo.systemUptime
        if unansweredStart?.page != page {
            unansweredStart = (id, page)
            livenessCheck?.cancel()
            livenessCheck = after(Self.pageLivenessTimeout) { [weak self] in
                self?.livenessTimeoutPassed(page: page)
            }
        }
        let script = "ffCapture.start({sid: \(id), synthetic: \(session.isSynthetic), echoCancellation: true}); 0"
        webView.evaluateJavaScript(script) { [weak self, weak session] _, error in
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - sentAt) * 1000)
            self?.pageAnswered(page)
            if error != nil {
                self?.pageCommandFailed(session: id)
                return
            }
            session?.pageAnsweredStart = true
            WebAudioCapture.log.info("Capture page ran the start command for session \(id, privacy: .public) after \(milliseconds, privacy: .public) ms")
        }
    }

    /// The page ran a start command, so it is running script again.
    private func pageAnswered(_ page: ObjectIdentifier) {
        guard unansweredStart?.page == page else { return }
        clearUnansweredStart()
    }

    private func clearUnansweredStart() {
        unansweredStart = nil
        livenessCheck?.cancel()
        livenessCheck = nil
    }

    private func livenessTimeoutPassed(page: ObjectIdentifier) {
        guard unansweredStart?.page == page, ObjectIdentifier(webView) == page else { return }
        Self.log.error("Capture page left a start command unanswered for \(Self.pageLivenessTimeout, privacy: .public) s; replacing the web view")
        let session = self.session
        // Replace first, so a retry from didFail waits for the new page.
        replaceWebView()
        if let session {
            endForLostPage(session)
        }
    }

    private func sendPageCommand(_ command: String, session id: Int) {
        webView.evaluateJavaScript("ffCapture.\(command)(\(id)); 0") { [weak self] _, error in
            guard error != nil else { return }
            self?.pageCommandFailed(session: id)
        }
    }

    private func pageCommandFailed(session id: Int) {
        Self.log.error("Capture page command failed for session \(id, privacy: .public)")
        guard let session else {
            // Nothing is recording, so stopping WebKit's capture can't cut a healthy session.
            webView.setMicrophoneCaptureState(.none, completionHandler: nil)
            return
        }
        // A late error for an earlier session says nothing about this one.
        guard session.id == id else { return }
        // The page may be wedged, so stop WebKit's capture directly.
        webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        endForLostPage(session)
    }

    private func rejectStale(_ type: String, session id: Int) -> Bool {
        if type == "pcm" {
            guard lastStaleChunkSession != id else { return false }
            lastStaleChunkSession = id
        }
        Self.log.info("Capture page \(type, privacy: .public) for session \(id, privacy: .public) ignored; current session \(self.session?.id ?? 0, privacy: .public)")
        return false
    }

    // MARK: Sessions

    private func receive(_ chunk: PCMChunk, in session: Session) -> Bool {
        let outcome: CaptureRecording.ChunkOutcome
        do {
            outcome = try session.recording.append(chunk)
        } catch is PCMChunkDecoder.Failure {
            fail(session, .interrupted("invalid-audio"), cancellingPage: true)
            return false
        } catch {
            fail(session, .fileError, cancellingPage: true)
            return false
        }

        if outcome.becameAudible && session.phase == .starting {
            session.phase = .capturing
            session.watchdog?.cancel()
            updateState()
            let latency = ProcessInfo.processInfo.systemUptime - session.requestedAt
            Self.log.info("Capture session \(session.id, privacy: .public) audible after \(Int(latency * 1000), privacy: .public) ms")
            delegate?.webAudioCaptureDidStart(self)
            guard self.session === session else { return true }
        }
        if session.phase == .capturing, let level = outcome.displayLevel {
            delegate?.webAudioCapture(self, didUpdateLevel: level)
            guard self.session === session else { return true }
        }
        if session.phase == .capturing && session.recording.frameCount >= Self.maximumFrameCount {
            Self.log.info("Capture session \(session.id, privacy: .public) reached the maximum duration")
            stop()
        }
        return true
    }

    private func startTimeoutPassed(session id: Int) {
        guard let session, session.id == id, session.phase == .starting else { return }
        guard isPageLoaded else {
            fail(session, .pageUnavailable, cancellingPage: false)
            return
        }
        guard session.pageAnsweredStart else {
            // The page's WebContent process ran no script, usually while a cold GPU process
            // starts. Keep the page, which normally recovers: the cancel queued behind the start
            // undoes it then, and the liveness check replaces the page if it never does.
            Self.log.error("Capture page did not run the start command within \(self.startTimeoutInterval, privacy: .public) s")
            fail(session, .pageUnavailable, cancellingPage: true)
            return
        }
        fail(session, .startTimedOut, cancellingPage: true)
    }

    private func stopTimeoutPassed(session id: Int) {
        guard let session, session.id == id, session.phase == .stopping else { return }
        if session.hasStartedPage {
            Self.log.info("Capture session \(id, privacy: .public) stop timed out; finishing with the audio received")
            sendPageCommand("cancel", session: id)
        }
        finish(session)
    }

    /// The page went away under a session. One that is stopping keeps the audio already
    /// written; any other fails.
    private func endForLostPage(_ session: Session) {
        if session.phase == .stopping {
            Self.log.info("Capture session \(session.id, privacy: .public) lost its page while stopping; finishing with the audio received")
            finish(session)
        } else {
            fail(session, .pageUnavailable, cancellingPage: false)
        }
    }

    private func finish(_ session: Session) {
        guard self.session === session else { return }
        end(session)
        let finished: CaptureRecording.Finished?
        do {
            finished = try session.recording.finish()
        } catch {
            session.recording.discard()
            Self.log.error("Capture session \(session.id, privacy: .public) could not finish its file")
            delegate?.webAudioCapture(self, didFail: .fileError)
            return
        }
        guard let finished else {
            Self.log.info("Capture session \(session.id, privacy: .public) finished with no audio")
            delegate?.webAudioCapture(self, didFail: .noAudio)
            return
        }
        // The page's counts come early in the line: CI keeps only the first 220 characters.
        let page = session.pageContinuity.map {
            "\($0.callbacks) callbacks, \($0.skippedCallbacks) skipped, \($0.lateCallbacks) late"
        } ?? "no report"
        Self.log.info("Capture session \(session.id, privacy: .public) finished: \(finished.frameCount, privacy: .public) frames (page: \(page, privacy: .public)), gain \(finished.gain.gainDB, privacy: .public) dB, \(finished.skippedChunks, privacy: .public) chunks missing")
        #if DEBUG
        let loudness = finished.loudness
        Self.log.debug("Capture loudness: peak \(loudness.peakDBFS, privacy: .public), speech \(loudness.speechDBFS, privacy: .public), floor \(loudness.noiseFloorDBFS, privacy: .public) dBFS")
        #endif
        delegate?.webAudioCapture(self, didFinish: CapturedAudio(
            fileURL: finished.fileURL,
            frameCount: finished.frameCount,
            sampleRate: finished.sampleRate,
            appliedGainDB: finished.gain.gainDB,
            pageContinuity: session.pageContinuity
        ))
    }

    private func fail(_ session: Session, _ failure: WebAudioCaptureFailure, cancellingPage: Bool) {
        guard self.session === session else { return }
        end(session)
        session.recording.discard()
        if cancellingPage && session.hasStartedPage {
            sendPageCommand("cancel", session: session.id)
        }
        Self.log.error("Capture session \(session.id, privacy: .public) failed: \(Self.describe(failure), privacy: .public)")
        delegate?.webAudioCapture(self, didFail: failure)
    }

    private func end(_ session: Session) {
        session.watchdog?.cancel()
        session.stopDeadline?.cancel()
        if self.session === session {
            self.session = nil
        }
        updateState()
    }

    /// Recomputes `state` and reports `didBecomeReady` when the page becomes usable.
    private func updateState(from previous: State? = nil) {
        let previous = previous ?? state
        if !isAttached {
            state = .detached
        } else if let session {
            switch session.phase {
            case .starting: state = .starting
            case .capturing: state = .capturing
            case .stopping: state = .stopping
            }
        } else {
            state = isPageLoaded ? .ready : .loading
        }
        if state == .ready && (previous == .detached || previous == .loading) {
            Self.log.info("Capture page ready")
            delegate?.webAudioCaptureDidBecomeReady(self)
        }
    }

    private var usesSyntheticSource: Bool {
        #if DEBUG
        if let syntheticSourceOverride {
            return syntheticSourceOverride
        }
        return UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier)?
            .bool(forKey: CapturePageSource.syntheticCaptureDefaultsKey) ?? false
        #else
        return false
        #endif
    }

    /// Deletes recordings a crash or jetsam left behind. Recent files may still be uploading.
    private func purgeStaleRecordings() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Self.staleRecordingAge)
        for file in files where file.pathExtension == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private static func describe(_ failure: WebAudioCaptureFailure) -> String {
        switch failure {
        case .pageUnavailable: return "page-unavailable"
        case .startTimedOut: return "start-timed-out"
        case .permissionDenied: return "permission-denied"
        case .unsupported(let name): return "unsupported(\(name))"
        case .interrupted(let reason): return "interrupted(\(reason))"
        case .noAudio: return "no-audio"
        case .fileError: return "file-error"
        }
    }

    private final class Session {
        enum Phase {
            case starting
            case capturing
            case stopping
        }

        let id: Int
        let recording: CaptureRecording
        let isSynthetic: Bool
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var phase = Phase.starting
        /// `ffCapture.start` was sent to the page.
        var hasStartedPage = false
        /// The page ran the start command (its evaluateJavaScript call completed).
        var pageAnsweredStart = false
        /// What the page's `ended` message counted, once it arrives.
        var pageContinuity: CaptureContinuity?
        var watchdog: Task<Void, Never>?
        var stopDeadline: Task<Void, Never>?

        init(id: Int, recording: CaptureRecording, isSynthetic: Bool) {
            self.id = id
            self.recording = recording
            self.isSynthetic = isSynthetic
        }
    }
}

/// WebKit's side of WebAudioCapture. WKUserContentController retains its message handlers,
/// so they live here and hold the capture weakly, which avoids a retain cycle through the
/// web view. Web views the capture has replaced stay attached to this bridge, which ignores
/// or refuses everything they send.
@MainActor
private final class CaptureBridge: NSObject, WKScriptMessageHandlerWithReply, WKUIDelegate, WKNavigationDelegate {
    weak var owner: WebAudioCapture?

    /// The reply is the page's acknowledgement; a rejection makes the page stop capturing.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let owner else {
            // The capture was released while its page lived on. Leaving the window makes
            // WebKit stop the page's capture too.
            message.webView?.removeFromSuperview()
            replyHandler(nil, "released")
            return
        }
        guard message.webView === owner.webView else {
            replyHandler(nil, "replaced")
            return
        }
        replyHandler(nil, owner.receive(message) ? nil : "rejected")
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let grant = webView === owner?.webView && WebAudioCapture.shouldGrantMediaCapture(
            type: type,
            originProtocol: origin.protocol,
            originHost: origin.host,
            isMainFrame: frame.isMainFrame
        )
        decisionHandler(grant ? .grant : .deny)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let owner, webView === owner.webView else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(owner.shouldAllowNavigation(navigationAction) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let owner, webView === owner.webView else { return }
        owner.pageLoadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let owner, webView === owner.webView else { return }
        owner.pageLoadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let owner, webView === owner.webView else { return }
        owner.webContentProcessDidTerminate()
    }
}
