import Foundation

/// The onboarding pages, in order (DESIGN §6.4).
enum OnboardingStep: String, CaseIterable {
    case welcome
    /// What leaves the iPhone, and explicit consent (App Review 5.1.2(i)).
    case consent
    case apiKey
    /// A hard gate: the keyboard's WebKit capture needs the app's permission.
    case microphone
    /// A soft gate, confirmed later by the keyboard's status report.
    case keyboard
    case tryIt
    case done

    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    var next: OnboardingStep? {
        let all = Self.allCases
        let nextIndex = index + 1
        return nextIndex < all.count ? all[nextIndex] : nil
    }

    var previous: OnboardingStep? {
        index > 0 ? Self.allCases[index - 1] : nil
    }

    /// The page to show after a relaunch: the saved one, but never past a
    /// page whose requirement is missing.
    static func resume(from stored: String?, hasConsent: Bool, hasAPIKey: Bool) -> OnboardingStep {
        guard let stored, let step = OnboardingStep(rawValue: stored) else { return .welcome }
        if step.index > OnboardingStep.consent.index && !hasConsent {
            return .consent
        }
        if step.index > OnboardingStep.apiKey.index && !hasAPIKey {
            return .apiKey
        }
        return step
    }
}

/// The primary button for the current page.
struct OnboardingPrimaryAction: Equatable {
    var title: String
    /// DESIGN §5.1: `freeflow.onboarding.continue`, or
    /// `freeflow.onboarding.microphone` while it would show the mic prompt.
    var accessibilityIdentifier: String
    var isEnabled: Bool

    static let continueIdentifier = "freeflow.onboarding.continue"
    static let microphoneIdentifier = "freeflow.onboarding.microphone"
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep
    @Published private(set) var microphonePermission: AppMicrophonePermission
    @Published private(set) var isRequestingMicrophone = false
    @Published private(set) var keyboardStatus: KeyboardStatus?
    @Published private(set) var apiKeyState: HomeSetupChecklist.APIKeyState

    let apiForm: APIKeyFormModel
    private let environment: FreeFlowAppEnvironment
    private let onFinish: @MainActor () -> Void

    init(environment: FreeFlowAppEnvironment, onFinish: @escaping @MainActor () -> Void) {
        self.environment = environment
        self.onFinish = onFinish
        self.apiForm = APIKeyFormModel(environment: environment)
        let apiKeyState = environment.apiKeyState()
        self.apiKeyState = apiKeyState
        self.step = OnboardingStep.resume(
            from: environment.settings.string(FreeFlowAppSettingKey.onboardingStep),
            hasConsent: environment.hasDataSharingConsent,
            hasAPIKey: apiKeyState == .saved
        )
        self.microphonePermission = environment.microphone.permission
        self.keyboardStatus = environment.keyboardStatus.load()
    }

    var canGoBack: Bool {
        step.previous != nil && !apiForm.isValidating && !isRequestingMicrophone
    }

    var primaryAction: OnboardingPrimaryAction {
        let continueID = OnboardingPrimaryAction.continueIdentifier
        switch step {
        case .welcome, .keyboard, .tryIt:
            return OnboardingPrimaryAction(title: "Continue", accessibilityIdentifier: continueID, isEnabled: true)
        case .consent:
            return OnboardingPrimaryAction(title: "Agree and Continue", accessibilityIdentifier: continueID, isEnabled: true)
        case .apiKey:
            return OnboardingPrimaryAction(
                title: apiForm.isValidating ? "Validating..." : "Continue",
                accessibilityIdentifier: continueID,
                isEnabled: apiForm.canSubmit
            )
        case .microphone:
            switch microphonePermission {
            case .granted:
                return OnboardingPrimaryAction(title: "Continue", accessibilityIdentifier: continueID, isEnabled: true)
            case .undetermined:
                // App Review 5.1.1(iv): the button before the prompt says "Continue".
                return OnboardingPrimaryAction(
                    title: "Continue",
                    accessibilityIdentifier: OnboardingPrimaryAction.microphoneIdentifier,
                    isEnabled: !isRequestingMicrophone
                )
            case .denied:
                return OnboardingPrimaryAction(title: "Continue", accessibilityIdentifier: continueID, isEnabled: false)
            }
        case .done:
            return OnboardingPrimaryAction(title: "Get Started", accessibilityIdentifier: continueID, isEnabled: true)
        }
    }

    func primaryTapped() async {
        guard primaryAction.isEnabled else { return }
        switch step {
        case .welcome, .keyboard, .tryIt:
            advance()
        case .consent:
            environment.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
            advance()
        case .apiKey:
            if apiForm.isUnchangedAndSaved {
                advance()
            } else if await apiForm.save() {
                apiKeyState = environment.apiKeyState()
                advance()
            }
        case .microphone:
            switch microphonePermission {
            case .granted:
                advance()
            case .undetermined:
                if await requestMicrophone() {
                    advance()
                }
            case .denied:
                break
            }
        case .done:
            environment.settings.removeValue(for: FreeFlowAppSettingKey.onboardingStep)
            onFinish()
        }
    }

    func goBack() {
        guard canGoBack, let previous = step.previous else { return }
        move(to: previous)
    }

    /// Re-reads what may have changed outside the app: the permission after
    /// a trip to Settings, and the keyboard's status report.
    func refresh() {
        microphonePermission = environment.microphone.permission
        refreshKeyboardStatus()
    }

    func refreshKeyboardStatus() {
        let status = environment.keyboardStatus.load()
        if status != keyboardStatus {
            keyboardStatus = status
        }
    }

    /// Shows the system prompt. On grant, records it in the App Group so the
    /// keyboard trusts it even before its own permission reading catches up.
    @discardableResult
    func requestMicrophone() async -> Bool {
        guard !isRequestingMicrophone else { return false }
        isRequestingMicrophone = true
        let granted = await environment.microphone.requestPermission()
        isRequestingMicrophone = false
        if granted {
            environment.settings.microphonePermissionGranted = true
            microphonePermission = .granted
        } else {
            microphonePermission = environment.microphone.permission == .granted ? .granted : .denied
        }
        return microphonePermission == .granted
    }

    private func advance() {
        guard let next = step.next else { return }
        move(to: next)
    }

    private func move(to newStep: OnboardingStep) {
        step = newStep
        environment.settings.set(newStep.rawValue, for: FreeFlowAppSettingKey.onboardingStep)
        if newStep == .apiKey {
            apiForm.presentIfNeeded()
        }
        refresh()
    }
}
