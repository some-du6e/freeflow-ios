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

    let environment: FreeFlowAppEnvironment
    private let microphoneFlagIsOverridden: Bool

    init(environment: FreeFlowAppEnvironment, microphoneFlagIsOverridden: Bool = false) {
        self.environment = environment
        self.microphoneFlagIsOverridden = microphoneFlagIsOverridden
        self.hasCompletedSetup = environment.settings.hasCompletedSetup
        syncMicrophoneFlag()
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
        refreshGeneration += 1
    }

    func sceneEnteredBackground() {
        activeRecorder?.appDidEnterBackground()
    }

    // MARK: URLs and the recorder

    func handle(url: URL) {
        guard let route = FreeFlowURLRoute(url: url) else { return }
        switch route {
        case .dictate(let sessionID):
            startDictation(mode: sessionID.map { RecorderMode.handoff(sessionID: $0) } ?? .inApp)
        }
    }

    /// Opens the recorder. A recorder that is still busy keeps going; if the
    /// keyboard asked again with a new session, the result goes to that one.
    func startDictation(mode: RecorderMode) {
        if let current = activeRecorder, current.isBusy {
            if case .handoff(let sessionID) = mode {
                current.adoptHandoffSession(sessionID)
            }
            return
        }
        activeRecorder?.close()
        let recorder = RecorderModel(
            mode: mode,
            dependencies: environment.makeRecorderDependencies(environment)
        )
        recorder.onInsertIntoTestField = { [weak self] text, pressEnter in
            self?.insertIntoTestField(text, pressEnter: pressEnter)
        }
        activeRecorder = recorder
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
