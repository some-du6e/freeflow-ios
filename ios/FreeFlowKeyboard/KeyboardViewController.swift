import AVFAudio
import os
import UIKit

private let keyboardLog = Logger(subsystem: "com.zachlatta.freeflow.ios.keyboard", category: "Keyboard")

/// The FreeFlow keyboard: a dictation-first panel.
///
/// Pressing the mic records inside the keyboard through `WebAudioCapture`,
/// `DictationPipeline` transcribes and cleans up the recording, and the text
/// goes in through `textDocumentProxy`, so the user never leaves the host
/// app. When in-keyboard capture can't run, the keyboard offers to record in
/// the FreeFlow app and inserts that result when the user comes back.
///
/// `KeyboardDictationMachine` (ios/Shared/Core/Keyboard) makes every
/// decision. This controller feeds it events, carries out the effects it
/// returns, and renders `KeyboardDictationDisplay` into `KeyboardPanelView`.
/// Logs carry only state names and failure kinds, never text or audio.
final class KeyboardViewController: UIInputViewController {
    /// One capture per keyboard process. Its web view stays loaded between
    /// dictations and moves to whichever controller is on screen.
    private static var processCapture: WebAudioCapture?
    /// For the handoff log: how long this process has run, and how many
    /// controllers it has loaded. In CI, iOS stopped long-lived keyboard
    /// processes right after a check read the app's result.
    private static let processStartedAt = Date()
    private static var controllersLoaded = 0
    private var controllerNumber = 0
    /// This process's latest result for Insert last. In memory only.
    private static var rememberedText: KeyboardRememberedText?

    private var machine = KeyboardDictationMachine()
    /// Events with the time they happened; nil means when handled.
    private var queuedEvents: [(event: KeyboardDictationEvent, time: Date?)] = []
    private var isHandlingEvents = false
    private let handoffLedger = KeyboardHandoffLedger(defaults: .standard)

    private var rootInputView: KeyboardInputView?
    private var panel: KeyboardPanelView?
    private var heightConstraint: NSLayoutConstraint?
    private var panelHeightConstraint: NSLayoutConstraint?
    private var didScheduleHeightConstraint = false

    /// Whether a capture produced audio since the capture page was attached.
    /// Until one has, starts get `KeyboardDictationMachine.firstStartCaptureTimeout`,
    /// because they can wait on WebKit's GPU process launching cold. A start
    /// that fails before any audio doesn't use up that allowance.
    private var hasCapturedSinceAttach = false

    private var wakeTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private let deleteRepeater = KeyboardDeleteRepeater()
    private lazy var haptics = UIImpactFeedbackGenerator(style: .light)
    private var lastLoggedStatus: KeyboardDictationStatus?

    #if DEBUG && targetEnvironment(simulator)
    /// A fixed display state for UI-test screenshots; see
    /// `KeyboardDebugDisplayState`.
    private var debugMachine: KeyboardDictationMachine?
    #endif

    private var capture: WebAudioCapture {
        if let capture = Self.processCapture {
            return capture
        }
        let capture = WebAudioCapture()
        Self.processCapture = capture
        return capture
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = Self.processStartedAt
        Self.controllersLoaded += 1
        controllerNumber = Self.controllersLoaded
        // A clear, non-opaque root lets the system keyboard backdrop show,
        // including while iOS stretches the view during its entry animation.
        let root = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        root.backgroundColor = .clear
        root.isOpaque = false
        rootInputView = root
        inputView = root
        hasDictationKey = true

        deleteRepeater.deleteOnce = { [weak self] unit in
            self?.performDelete(unit)
        }
        // WebKit records on behalf of this process, and iOS mutes haptics
        // during recording unless the session allows them.
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installPanelIfNeeded()
        loadDebugState()
        if hasFullAccess {
            NetworkMonitor.shared.start()
        }
        send(.setupChanged(currentSetup()))
        send(.appeared)
        recordKeyboardStatus()
        checkForAppResult()
        refreshKeys()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Preload the capture page so the first tap records quickly. Without
        // Full Access the keyboard can't dictate, so it skips the web view.
        guard hasFullAccess, let rootInputView else { return }
        let capture = self.capture
        capture.delegate = self
        capture.attach(to: rootInputView)
        hasCapturedSinceAttach = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        deleteRepeater.stop()
        send(.disappeared)
        if let capture = Self.processCapture, capture.delegate === self {
            capture.detach()
            capture.delegate = nil
        }
        hasCapturedSinceAttach = false
        wakeTask?.cancel()
        wakeTask = nil
        // Controllers can outlive their host, so drop the views now.
        tearDownPanel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let height = preferredHeight()
        if let heightConstraint, heightConstraint.constant != height {
            heightConstraint.constant = height
        }
        if let panelHeightConstraint, panelHeightConstraint.constant != height {
            panelHeightConstraint.constant = height
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard heightConstraint == nil, !didScheduleHeightConstraint else { return }
        didScheduleHeightConstraint = true
        // Adding the height after iOS's first layout pass avoids fighting its
        // priority-1000 height during the keyboard's entry animation.
        Task { [weak self] in
            self?.installHeightConstraint()
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshKeys()
    }

    // MARK: Layout

    private func preferredHeight() -> CGFloat {
        if traitCollection.verticalSizeClass == .compact {
            return 196
        }
        let window = rootInputView?.window ?? view.window
        let screenSize = window?.windowScene?.screen.bounds.size ?? .zero
        let longSide = max(screenSize.width, screenSize.height)
        if longSide > 0, longSide < 700 {
            return 236
        }
        return 260
    }

    private func installHeightConstraint() {
        guard heightConstraint == nil, let rootInputView else { return }
        let constraint = rootInputView.heightAnchor.constraint(equalToConstant: preferredHeight())
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func installPanelIfNeeded() {
        guard panel == nil, let rootInputView else { return }
        let panel = KeyboardPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        // Below the capture's hidden web view, which must stay in the window.
        rootInputView.insertSubview(panel, at: 0)

        // A fixed height anchored to the bottom keeps the panel from
        // stretching when iOS briefly makes the keyboard taller.
        let height = panel.heightAnchor.constraint(equalToConstant: preferredHeight())
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: rootInputView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: rootInputView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: rootInputView.bottomAnchor),
            panel.topAnchor.constraint(greaterThanOrEqualTo: rootInputView.topAnchor),
            height,
        ])
        panelHeightConstraint = height
        wire(panel)
        self.panel = panel
        render()
    }

    private func tearDownPanel() {
        panel?.removeFromSuperview()
        panel = nil
        panelHeightConstraint = nil
    }

    private func wire(_ panel: KeyboardPanelView) {
        panel.micButton.addTarget(self, action: #selector(micTouchDown(_:forEvent:)), for: .touchDown)
        panel.micButton.addTarget(
            self,
            action: #selector(micTouchUp(_:forEvent:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        panel.cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        panel.doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        panel.openAppButton.addTarget(self, action: #selector(openAppTapped), for: .touchUpInside)
        panel.insertLastButton.addTarget(self, action: #selector(insertLastTapped), for: .touchUpInside)
        panel.insertPendingButton.addTarget(self, action: #selector(insertPendingTapped), for: .touchUpInside)
        // Tap switches keyboards; touch and hold shows the keyboard list.
        panel.globeKey.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        panel.spaceKey.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        panel.deleteKey.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        panel.deleteKey.addTarget(self, action: #selector(deleteTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        panel.returnKey.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
    }

    /// The globe only when iOS asks for one (re-read on every appearance, as
    /// it's wrong in viewDidLoad), and a return key that follows the field.
    private func refreshKeys() {
        guard let panel else { return }
        let proxy = textDocumentProxy
        let returnKind = KeyboardReturnKeyKind(returnKeyTypeRawValue: proxy.returnKeyType?.rawValue)
        let returnEnabled = proxy.enablesReturnKeyAutomatically != true || proxy.hasText
        panel.configureKeys(showsGlobe: needsInputModeSwitchKey, returnKind: returnKind, returnEnabled: returnEnabled)
        panel.overrideUserInterfaceStyle = proxy.keyboardAppearance == .dark ? .dark : .unspecified
    }

    // MARK: Controls

    @objc private func micTouchDown(_ sender: UIControl, forEvent event: UIEvent) {
        guard !isShowingDebugState else { return }
        send(.setupChanged(currentSetup()))
        send(.micPressBegan(documentID: textDocumentProxy.documentIdentifier), at: Self.time(of: event))
    }

    @objc private func micTouchUp(_ sender: UIControl, forEvent event: UIEvent) {
        guard !isShowingDebugState else { return }
        send(.micPressEnded, at: Self.time(of: event))
    }

    /// When the touch happened. Tap and hold are told apart by touch times,
    /// so work done while handling the press doesn't count as holding.
    private static func time(of event: UIEvent) -> Date {
        let time = Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
        // Fall back to now for a synthesized event without a usable timestamp.
        return abs(time.timeIntervalSinceNow) < 5 ? time : Date()
    }

    @objc private func cancelTapped() {
        guard !isShowingDebugState else { return }
        send(.cancelTapped)
    }

    @objc private func doneTapped() {
        guard !isShowingDebugState else { return }
        send(.doneTapped)
    }

    @objc private func openAppTapped() {
        guard !isShowingDebugState else { return }
        send(.openAppTapped(newSessionID: UUID()))
    }

    @objc private func insertLastTapped() {
        guard !isShowingDebugState else { return }
        UIDevice.current.playInputClick()
        let text = KeyboardInsertLast.text(remembered: Self.rememberedText, history: HistoryStore.shared.load())
        send(.insertLastTapped(text: text, document: currentDocument()))
    }

    @objc private func insertPendingTapped() {
        guard !isShowingDebugState else { return }
        UIDevice.current.playInputClick()
        send(.insertPendingTapped(document: currentDocument()))
    }

    @objc private func spaceTapped() {
        UIDevice.current.playInputClick()
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
        UIDevice.current.playInputClick()
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteTouchDown() {
        deleteRepeater.begin()
    }

    @objc private func deleteTouchUp() {
        deleteRepeater.stop()
    }

    private func performDelete(_ unit: KeyboardDeleteRepeat.Unit) {
        UIDevice.current.playInputClick()
        // The text before the cursor is read only to count a word, never kept.
        let context = unit == .word ? textDocumentProxy.documentContextBeforeInput : nil
        let count = KeyboardDeleteRepeat.deletionCount(for: unit, textBeforeCursor: context)
        for _ in 0..<count {
            textDocumentProxy.deleteBackward()
        }
    }

    // MARK: State machine

    /// Events raised while effects run (capture callbacks can fire
    /// synchronously) queue up and are handled in order.
    private func send(_ event: KeyboardDictationEvent, at time: Date? = nil) {
        queuedEvents.append((event: event, time: time))
        guard !isHandlingEvents else { return }
        isHandlingEvents = true
        while !queuedEvents.isEmpty {
            let next = queuedEvents.removeFirst()
            let effects = machine.handle(next.event, now: next.time ?? Date())
            for effect in effects {
                carryOut(effect)
            }
        }
        isHandlingEvents = false
        render()
        scheduleWakeUp()
    }

    private func carryOut(_ effect: KeyboardDictationEffect) {
        switch effect {
        case .startCapture:
            let capture = self.capture
            capture.delegate = self
            if let rootInputView {
                if capture.state == .detached {
                    hasCapturedSinceAttach = false
                }
                capture.attach(to: rootInputView)
            }
            capture.startTimeoutInterval = hasCapturedSinceAttach
                ? WebAudioCapture.startTimeout
                : KeyboardDictationMachine.firstStartCaptureTimeout
            capture.start()
        case .stopCapture:
            capture.stop()
        case .cancelCapture:
            capture.cancel()
        case .runPipeline(let attempt, let audioFileURL):
            runPipeline(attempt: attempt, audioFileURL: audioFileURL)
        case .cancelPipeline:
            pipelineTask?.cancel()
            pipelineTask = nil
        case .deleteAudio(let url):
            try? FileManager.default.removeItem(at: url)
        case .insert(let text):
            textDocumentProxy.insertText(text)
        case .recordHistory(let draft):
            HistoryStore.shared.append(draft.makeEntry())
        case .rememberForInsertLast(let text, let time):
            Self.rememberedText = KeyboardRememberedText(text: text, savedAt: time)
        case .openApp(let sessionID):
            openContainingApp(sessionID: sessionID)
        case .stopAwaitingApp(let sessionID):
            // Without Full Access the App Group is read-only to the keyboard.
            if hasFullAccess {
                let removed = KeyboardHandoffCheck.stopAwaiting(PendingDictationStore.shared, sessionID: sessionID, now: Date())
                let session = KeyboardHandoffCheck.shortID(sessionID)
                keyboardLog.info("stopped waiting for FreeFlow's result for \(session, privacy: .public); removed a result: \(removed, privacy: .public)")
            }
        case .checkForAppResult:
            checkForAppResult()
        case .haptic:
            playHaptic()
        case .reportCapture(let worked, let failure):
            recordCaptureReport(worked: worked, failure: failure)
        case .announce(let message):
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func render() {
        guard let panel else { return }
        let display = KeyboardDictationDisplay(machine: displayedMachine)
        panel.apply(display)
        if isShowingDebugState, display.mic == .recording {
            panel.setLevel(0.65)
        }
        if display.status != lastLoggedStatus {
            lastLoggedStatus = display.status
            keyboardLog.info("status \(display.status.rawValue, privacy: .public)")
        }
    }

    /// Sends `.tick` when the machine's next deadline passes.
    private func scheduleWakeUp() {
        wakeTask?.cancel()
        wakeTask = nil
        guard let deadline = machine.nextWakeUp else { return }
        let delay = max(deadline.timeIntervalSinceNow, 0.01)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.send(.tick)
        }
    }

    // MARK: Setup and status

    private func currentSetup() -> KeyboardDictationSetup {
        let fullAccess = hasFullAccess
        let settings = SettingsStore.shared
        // Shared settings and the keychain are only readable with Full Access.
        let microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
            || (fullAccess && settings.microphonePermissionGranted)
        let hasAPIKey = fullAccess && settings.dictationConfiguration() != nil
        let availableMemory = os_proc_available_memory()
        return KeyboardDictationSetup(
            hasFullAccess: fullAccess,
            microphoneGranted: microphoneGranted,
            hasAPIKey: hasAPIKey,
            availableMemoryBytes: availableMemory > 0 ? availableMemory : nil
        )
    }

    private static func microphonePermission() -> KeyboardStatus.MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    /// Lets the app's setup checklist see the keyboard. Without Full Access
    /// the App Group is read-only to the keyboard, so nothing is written.
    private func recordKeyboardStatus() {
        guard hasFullAccess else { return }
        let previous = KeyboardStatusStore.shared.load()
        KeyboardStatusStore.shared.record(KeyboardStatus(
            lastSeenAt: Date(),
            hasFullAccess: true,
            microphonePermission: Self.microphonePermission(),
            inKeyboardCaptureWorked: previous?.inKeyboardCaptureWorked,
            lastCaptureFailure: previous?.lastCaptureFailure
        ))
    }

    private func recordCaptureReport(worked: Bool, failure: KeyboardDictationCaptureFailure?) {
        if let failure {
            keyboardLog.error("capture failed: \(failure.rawValue, privacy: .public)")
        }
        guard hasFullAccess else { return }
        KeyboardStatusStore.shared.record(KeyboardStatus(
            lastSeenAt: Date(),
            hasFullAccess: true,
            microphonePermission: Self.microphonePermission(),
            inKeyboardCaptureWorked: worked,
            lastCaptureFailure: failure?.rawValue
        ))
    }

    private func playHaptic() {
        guard hasFullAccess else { return }
        haptics.impactOccurred()
        haptics.prepare()
    }

    // MARK: Pipeline

    private func runPipeline(attempt: Int, audioFileURL: URL) {
        pipelineTask?.cancel()
        guard let configuration = SettingsStore.shared.dictationConfiguration() else {
            send(.pipelineFailed(attempt: attempt, message: KeyboardDictationDisplay.setupText(for: .apiKey)))
            return
        }
        let pipeline = DictationPipeline()
        // Holds the controller until the request ends (it's bounded by the
        // pipeline's timeouts): if the keyboard closes meanwhile, the machine
        // still records the result for Insert last and deletes the audio.
        pipelineTask = Task { [self] in
            do {
                let result = try await pipeline.run(audioFileURL: audioFileURL, configuration: configuration)
                guard !Task.isCancelled else { return }
                keyboardLog.info("dictation finished: \(result.route.rawValue, privacy: .public)")
                send(.pipelineFinished(attempt: attempt, result: result, document: currentDocument()))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                keyboardLog.error("dictation failed: \(String(describing: type(of: error)), privacy: .public)")
                let message = DictationPipeline.userFacingMessage(for: error, isOnline: NetworkMonitor.shared.isOnline)
                send(.pipelineFailed(attempt: attempt, message: message))
            }
        }
    }

    /// Read just before inserting, for spacing and the changed-field check.
    private func currentDocument() -> KeyboardDictationDocument {
        KeyboardDictationDocument(
            identifier: textDocumentProxy.documentIdentifier,
            textBeforeCursor: textDocumentProxy.documentContextBeforeInput
        )
    }

    // MARK: Open-the-app fallback

    private func openContainingApp(sessionID: UUID) {
        PendingDictationStore.shared.awaitedSessionID = sessionID
        handoffLedger.recordOpen(sessionID: sessionID, documentID: textDocumentProxy.documentIdentifier, at: Date())
        // Start from the view iOS put in the keyboard window; its responder
        // chain ends at the extension's UIApplication.
        let responder: UIResponder
        if let rootInputView {
            responder = rootInputView
        } else {
            responder = self
        }
        let url = KeyboardHandoffURL.dictate(sessionID: sessionID)
        let found = KeyboardAppOpener.open(url, from: responder) { [weak self] opened in
            guard !opened else { return }
            keyboardLog.error("iOS didn't open FreeFlow")
            self?.send(.appOpenFailed)
        }
        if found {
            keyboardLog.info("asked iOS to open FreeFlow for the fallback")
        } else {
            keyboardLog.error("found no UIApplication to open FreeFlow")
            send(.appOpenFailed)
        }
    }

    /// Picks up a result the app recorded for this keyboard, if one is
    /// waiting. `KeyboardHandoffCheck` decides what the store's contents
    /// mean, including when a result nobody seems to await may be removed
    /// (only once it can never be inserted). It never removes the result it
    /// hands over; the machine lets go of it once used. Each check is logged
    /// without content.
    private func checkForAppResult() {
        guard hasFullAccess, !machine.isBusy else {
            if !hasFullAccess {
                keyboardLog.info("handoff check skipped: no Full Access")
            }
            return
        }
        let checked = KeyboardHandoffCheck.checkAndReport(
            PendingDictationStore.shared,
            ledger: handoffLedger,
            now: Date(),
            document: currentDocument()
        )
        let summary = checked.report.summary
        let uptime = Int(Date().timeIntervalSince(Self.processStartedAt))
        keyboardLog.info("handoff check: \(summary, privacy: .public); process up \(uptime, privacy: .public) s, controller \(self.controllerNumber, privacy: .public) of \(Self.controllersLoaded, privacy: .public)")
        send(checked.event)
    }

    // MARK: DEBUG screenshot states

    private var displayedMachine: KeyboardDictationMachine {
        #if DEBUG && targetEnvironment(simulator)
        if let debugMachine {
            return debugMachine
        }
        #endif
        return machine
    }

    private var isShowingDebugState: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return debugMachine != nil
        #else
        return false
        #endif
    }

    private func loadDebugState() {
        #if DEBUG && targetEnvironment(simulator)
        let key = KeyboardDebugDisplayState.defaultsKey
        let rawValue = SettingsStore.shared.defaults.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
        debugMachine = rawValue.flatMap { KeyboardDebugDisplayState.machine(for: $0, now: Date()) }
        #endif
    }
}

// MARK: - WebAudioCaptureDelegate

extension KeyboardViewController: WebAudioCaptureDelegate {
    func webAudioCaptureDidBecomeReady(_ capture: WebAudioCapture) {}

    func webAudioCaptureDidStart(_ capture: WebAudioCapture) {
        hasCapturedSinceAttach = true
        send(.captureStarted)
    }

    func webAudioCapture(_ capture: WebAudioCapture, didUpdateLevel level: Float) {
        guard case .recording = machine.phase else { return }
        panel?.setLevel(level)
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFinish audio: CapturedAudio) {
        send(.captureFinished(KeyboardDictationAudio(fileURL: audio.fileURL, duration: audio.duration)))
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFail failure: WebAudioCaptureFailure) {
        send(.captureFailed(KeyboardDictationCaptureFailure(failure)))
    }
}

extension KeyboardDictationCaptureFailure {
    init(_ failure: WebAudioCaptureFailure) {
        switch failure {
        case .pageUnavailable:
            self = .pageUnavailable
        case .startTimedOut:
            self = .startTimedOut
        case .permissionDenied:
            self = .permissionDenied
        case .unsupported:
            self = .unsupported
        case .interrupted:
            self = .interrupted
        case .noAudio:
            self = .noAudio
        case .fileError:
            self = .fileError
        }
    }
}
