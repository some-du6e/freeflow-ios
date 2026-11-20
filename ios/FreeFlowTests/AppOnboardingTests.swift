import XCTest
@testable import FreeFlow

final class AppOnboardingTests: XCTestCase {
    func testStepsRunInTheDesignOrder() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .consent, .apiKey, .microphone, .keyboard, .tryIt, .done])
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.welcome.next, .consent)
        XCTAssertEqual(OnboardingStep.tryIt.next, .done)
        XCTAssertNil(OnboardingStep.done.next)
    }

    func testResumeNeverSkipsAMissingRequirement() {
        XCTAssertEqual(OnboardingStep.resume(from: nil, hasConsent: false, hasAPIKey: false), .welcome)
        XCTAssertEqual(OnboardingStep.resume(from: "not-a-step", hasConsent: true, hasAPIKey: true), .welcome)
        XCTAssertEqual(OnboardingStep.resume(from: "microphone", hasConsent: true, hasAPIKey: true), .microphone)
        XCTAssertEqual(OnboardingStep.resume(from: "microphone", hasConsent: true, hasAPIKey: false), .apiKey)
        XCTAssertEqual(OnboardingStep.resume(from: "tryIt", hasConsent: false, hasAPIKey: true), .consent)
        XCTAssertEqual(OnboardingStep.resume(from: "apiKey", hasConsent: true, hasAPIKey: false), .apiKey)
        XCTAssertEqual(OnboardingStep.resume(from: "consent", hasConsent: false, hasAPIKey: false), .consent)
    }

    @MainActor
    func testWelcomeThroughAPIKeyRecordsConsentAndValidates() async {
        let stores = AppTestStores(microphone: AppFakeMicrophone(permission: .undetermined))
        defer { stores.tearDown() }
        let validations = AppValidationRecorder()
        let model = OnboardingModel(environment: stores.environment(validator: { key, url in
            await validations.validate(key, url)
        })) {}

        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.canGoBack)
        XCTAssertEqual(model.primaryAction.accessibilityIdentifier, "freeflow.onboarding.continue")
        await model.primaryTapped()

        XCTAssertEqual(model.step, .consent)
        XCTAssertFalse(stores.settings.bool(FreeFlowAppSettingKey.dataSharingConsent, default: false))
        XCTAssertEqual(model.primaryAction.title, "Agree and Continue")
        await model.primaryTapped()

        XCTAssertTrue(stores.settings.bool(FreeFlowAppSettingKey.dataSharingConsent, default: false))
        XCTAssertEqual(model.step, .apiKey)
        XCTAssertEqual(stores.settings.string(FreeFlowAppSettingKey.onboardingStep), "apiKey")
        XCTAssertFalse(model.primaryAction.isEnabled, "Continue needs a key")

        model.apiForm.draft.apiKey = "synthetic-key"
        XCTAssertTrue(model.primaryAction.isEnabled)
        await model.primaryTapped()

        XCTAssertEqual(model.step, .microphone)
        XCTAssertEqual(stores.credentials.storedAPIKey, "synthetic-key")
        XCTAssertEqual(model.apiKeyState, .saved)
        let calls = await validations.calls
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor
    func testRejectedKeyStaysOnTheAPIKeyPage() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.settings.set(OnboardingStep.apiKey.rawValue, for: FreeFlowAppSettingKey.onboardingStep)
        stores.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
        let model = OnboardingModel(environment: stores.environment(validator: { _, _ in false })) {}
        XCTAssertEqual(model.step, .apiKey)

        model.apiForm.presentIfNeeded()
        model.apiForm.draft.apiKey = "rejected-key"
        await model.primaryTapped()

        XCTAssertEqual(model.step, .apiKey)
        XCTAssertEqual(model.apiForm.failureMessage, APIKeyFormModel.validationFailedMessage)
        XCTAssertNil(stores.credentials.storedAPIKey)
    }

    @MainActor
    func testMicrophonePageAsksWithContinueThenAdvances() async {
        let microphone = AppFakeMicrophone(permission: .undetermined, grantsOnRequest: true)
        let stores = AppTestStores(microphone: microphone)
        defer { stores.tearDown() }
        let model = makeModel(at: .microphone, stores)

        let action = model.primaryAction
        XCTAssertEqual(action.title, "Continue", "App Review 5.1.1(iv)")
        XCTAssertEqual(action.accessibilityIdentifier, "freeflow.onboarding.microphone")
        XCTAssertTrue(action.isEnabled)
        XCTAssertEqual(microphone.requestCount, 0, "Nothing is asked before the tap")

        await model.primaryTapped()

        XCTAssertEqual(microphone.requestCount, 1)
        XCTAssertTrue(stores.settings.microphonePermissionGranted)
        XCTAssertEqual(model.step, .keyboard)
    }

    @MainActor
    func testDeniedMicrophoneIsAHardGate() async {
        let microphone = AppFakeMicrophone(permission: .undetermined, grantsOnRequest: false)
        let stores = AppTestStores(microphone: microphone)
        defer { stores.tearDown() }
        let model = makeModel(at: .microphone, stores)

        await model.primaryTapped()

        XCTAssertEqual(model.step, .microphone)
        XCTAssertEqual(model.microphonePermission, .denied)
        XCTAssertFalse(model.primaryAction.isEnabled)
        XCTAssertEqual(model.primaryAction.accessibilityIdentifier, "freeflow.onboarding.continue")
        XCTAssertFalse(stores.settings.microphonePermissionGranted)

        // Granted later in Settings: the page notices on refresh.
        microphone.permission = .granted
        model.refresh()
        XCTAssertTrue(model.primaryAction.isEnabled)
        await model.primaryTapped()
        XCTAssertEqual(model.step, .keyboard)
    }

    @MainActor
    func testGrantedMicrophoneSkipsThePrompt() async {
        let microphone = AppFakeMicrophone(permission: .granted)
        let stores = AppTestStores(microphone: microphone)
        defer { stores.tearDown() }
        let model = makeModel(at: .microphone, stores)

        XCTAssertEqual(model.primaryAction.accessibilityIdentifier, "freeflow.onboarding.continue")
        await model.primaryTapped()

        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(model.step, .keyboard)
    }

    @MainActor
    func testKeyboardPageIsASoftGateThatPicksUpTheStatusReport() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = makeModel(at: .keyboard, stores)

        XCTAssertNil(model.keyboardStatus)
        XCTAssertTrue(model.primaryAction.isEnabled)
        await model.primaryTapped()
        XCTAssertEqual(model.step, .tryIt)
    }

    @MainActor
    func testGetStartedFinishesSetup() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
        stores.credentials.storedAPIKey = "synthetic-key"
        stores.settings.set(OnboardingStep.done.rawValue, for: FreeFlowAppSettingKey.onboardingStep)
        let app = FreeFlowAppModel(environment: stores.environment())
        let model = OnboardingModel(environment: app.environment) { [weak app] in
            app?.completeOnboarding()
        }
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.primaryAction.title, "Get Started")

        await model.primaryTapped()

        XCTAssertTrue(app.hasCompletedSetup)
        XCTAssertTrue(stores.settings.hasCompletedSetup)
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowAppSettingKey.onboardingStep))
    }

    @MainActor
    func testBackReturnsToThePreviousPage() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = makeModel(at: .keyboard, stores)

        XCTAssertTrue(model.canGoBack)
        model.goBack()

        XCTAssertEqual(model.step, .microphone)
        XCTAssertEqual(stores.settings.string(FreeFlowAppSettingKey.onboardingStep), "microphone")
    }

    /// An onboarding model resumed at `step`, with consent and a key stored
    /// so the resume rules allow it.
    @MainActor
    private func makeModel(at step: OnboardingStep, _ stores: AppTestStores) -> OnboardingModel {
        stores.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
        stores.credentials.storedAPIKey = "synthetic-key"
        stores.settings.set(step.rawValue, for: FreeFlowAppSettingKey.onboardingStep)
        let model = OnboardingModel(environment: stores.environment()) {}
        XCTAssertEqual(model.step, step)
        return model
    }
}
