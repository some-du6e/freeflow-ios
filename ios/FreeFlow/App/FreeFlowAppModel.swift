import Foundation

enum FreeFlowAppTab: Int, CaseIterable, Identifiable {
    case home
    case history
    case settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape.fill"
        }
    }

    /// DESIGN §5.1; UI tests find the tabs by these.
    var accessibilityIdentifier: String {
        switch self {
        case .home: "freeflow.app.tab.home"
        case .history: "freeflow.app.tab.history"
        case .settings: "freeflow.app.tab.settings"
        }
    }
}

/// App-wide state: whether setup is done, the selected tab, the shared test
/// field, and the recorder when one is open.
@MainActor
final class FreeFlowAppModel: ObservableObject {
    @Published private(set) var hasCompletedSetup: Bool
    @Published var selectedTab: FreeFlowAppTab = .home
    /// The recorder on screen. Set to nil to dismiss it.
    @Published var activeRecorder: RecorderModel?
    /// The "Try FreeFlow" field on Home and on the last onboarding page.
    @Published var testFieldText = ""
    /// Bumped when the app returns to the foreground or a recorder closes, so
    /// screens reload what the keyboard may have written meanwhile.
    @Published private(set) var refreshGeneration = 0
    /// Bumped to ask screens to close their sheets and alerts, which would
    /// otherwise stop the recorder from being presented.
    @Published private(set) var presentationResetGeneration = 0

    let environment: FreeFlowAppEnvironment
    private let microphoneFlagIsOverridden: Bool

    /// `handle(url:)` reads the awaited session up to this many more times,
    /// pausing between reads (about 1 s in all), because the keyboard's App
    /// Group write may not have reached the app yet. Tests shorten the pause.
    var awaitedSessionRereads = 10
    var pauseBeforeRereadingAwaitedSession: @MainActor () async -> Void = {
        _ = try? await Task.sleep(for: .milliseconds(100))
    }

    init(environment: FreeFlowAppEnvironment, microphoneFlagIsOverridden: Bool = false) {
        self.environment = environment
        self.microphoneFlagIsOverridden = microphoneFlagIsOverridden
        self.hasCompletedSetup = environment.settings.hasCompletedSetup
        syncMicrophoneFlag()
        discardUnclaimedHandoffResult()
    }

    // MARK: Setup

    func completeOnboarding() {
        environment.settings.hasCompletedSetup = true
        environment.settings.removeValue(for: FreeFlowAppSettingKey.onboardingStep)
        selectedTab = .home
        hasCompletedSetup = true
    }

    /// "Re-run Setup...": keeps every setting and starts onboarding over.
    func rerunSetup() {
        environment.settings.hasCompletedSetup = false
        environment.settings.set(OnboardingStep.welcome.rawValue, for: FreeFlowAppSettingKey.onboardingStep)
        hasCompletedSetup = false
    }

    /// Withdraws the data-sharing consent (App Review 5.1.1(ii)). Deleting the
    /// API keys stops the app and the keyboard from sending audio anywhere,
    /// and setup starts over.
    func withdrawConsent() {
        try? environment.credentials.setAPIKey(nil)
        try? environment.credentials.setTranscriptionAPIKey(nil)
        environment.settings.removeValue(for: FreeFlowAppSettingKey.dataSharingConsent)
        rerunSetup()
    }

    /// Mirrors the real microphone permission into the App Group flag the
    /// keyboard trusts, unless a UI-test launch argument set the flag.
    func syncMicrophoneFlag() {
        guard !microphoneFlagIsOverridden else { return }
        let granted = environment.microphone.permission == .granted
        if environment.settings.microphonePermissionGranted != granted {
            environment.settings.microphonePermissionGranted = granted
        }
    }

    // MARK: Scene

    func sceneBecameActive() {
        syncMicrophoneFlag()
        discardUnclaimedHandoffResult()
        refreshGeneration += 1
    }

    func sceneEnteredBackground() {
        activeRecorder?.appDidEnterBackground()
    }

    /// Removes a handed-off result no keyboard can still take, so its text
    /// doesn't stay in the App Group.
    private func discardUnclaimedHandoffResult() {
        environment.pendingDictations.discardUnclaimedResult(now: Date())
    }

    // MARK: URLs and the recorder

    /// `freeflow://dictate`. Any app can open it, so it records on its own
    /// only for the session the keyboard wrote to the App Group before
    /// opening it (only FreeFlow's own processes can). Anything else (no
    /// session, or one the keyboard isn't waiting for) opens the recorder
    /// idle, and it records only after a tap on Start.
    func handle(url: URL) async {
        guard let route = FreeFlowURLRoute(url: url) else { return }
        switch route {
        case .dictate(let sessionID):
            guard let sessionID else {
                openRecorder(mode: .inApp, startsOnAppear: false)
                return
            }
            let isAwaited = await keyboardAwaits(sessionID)
            openRecorder(mode: .handoff(sessionID: sessionID), startsOnAppear: isAwaited)
        }
    }

    /// Whether the keyboard waits for `sessionID`, re-reading briefly in case
    /// its App Group write is still on its way.
    private func keyboardAwaits(_ sessionID: UUID) async -> Bool {
        if environment.pendingDictations.awaitedSessionID == sessionID {
            return true
        }
        for _ in 0..<awaitedSessionRereads {
            await pauseBeforeRereadingAwaitedSession()
            if environment.pendingDictations.awaitedSessionID == sessionID {
                return true
            }
        }
        return false
    }

    /// Opens the recorder for a tap in FreeFlow ("Dictate Without the
    /// Keyboard", Try Again), so it records at once. Keyboard handoffs come
    /// through `handle(url:)`, which checks the session first.
    func startDictation(mode: RecorderMode) {
        openRecorder(mode: mode, startsOnAppear: true)
    }

    /// For a handoff, `startsOnAppear` is true only for the session the
    /// keyboard awaits; nothing else may start a recording or take over a
    /// busy recorder.
    private func openRecorder(mode: RecorderMode, startsOnAppear: Bool) {
        if let current = activeRecorder, current.isBusy {
            // A busy recorder keeps going. Only the awaited session may take
            // over a busy handoff recorder's result. A busy in-app recorder
            // never hands its test-field dictation to the keyboard: the
            // awaited session replaces it below, dropping that unfinished
            // result, and gets a recording of its own.
            guard startsOnAppear, case .handoff(let sessionID) = mode else { return }
            if current.mode.sessionID != nil {
                current.adoptHandoffSession(sessionID)
                return
            }
        }
        // The keyboard reopened the app for the session this recorder already
        // serves. Keep it: closing it would clear the session the keyboard is
        // waiting on. If the keyboard still waits for it, a recorder waiting
        // for a tap starts and a failed recording gets another try.
        if let current = activeRecorder, let sessionID = mode.sessionID, current.mode.sessionID == sessionID {
            if startsOnAppear {
                current.resumeForAwaitedSession()
            }
            return
        }
        activeRecorder?.close()
        let recorder = RecorderModel(
            mode: mode,
            dependencies: environment.makeRecorderDependencies(environment),
            startsOnAppear: startsOnAppear
        )
        recorder.onInsertIntoTestField = { [weak self] text, pressEnter in
            self?.insertIntoTestField(text, pressEnter: pressEnter)
        }
        activeRecorder = recorder
    }

    /// Asks every screen to dismiss its sheets and alerts.
    func closeOtherPresentations() {
        presentationResetGeneration += 1
    }

    func closeRecorder() {
        activeRecorder?.close()
        activeRecorder = nil
        refreshGeneration += 1
    }

    /// Leaves the recorder for Settings, for example to add an API key.
    func closeRecorderAndOpenSettings() {
        closeRecorder()
        if hasCompletedSetup {
            selectedTab = .settings
        }
    }

    /// Appends a dictation the way the keyboard inserts one: spacing from
    /// `TranscriptRouting`, then a newline for "press enter".
    func insertIntoTestField(_ text: String, pressEnter: Bool) {
        var insertion = TranscriptRouting.insertionText(for: text, precedingText: testFieldText)
        if pressEnter {
            insertion += "\n"
        }
        testFieldText += insertion
    }
}
