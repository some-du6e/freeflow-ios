#if DEBUG
import XCTest
@testable import FreeFlow

/// The DEBUG launch arguments the e2e tests rely on (DESIGN §5.2), applied
/// to a throwaway suite instead of the real App Group.
final class AppUITestHooksTests: XCTestCase {
    private typealias Argument = FreeFlowUITestHooks.Argument

    func testBaseURLHookSetsTheBaseURLAndClearsTheTranscriptionURL() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.defaults.set("https://speech.invalid/v1", forKey: FreeFlowSettingKey.transcriptionAPIURL)

        apply([Argument.baseURL: "http://127.0.0.1:8765/v1"], stores)

        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL), "http://127.0.0.1:8765/v1")
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.transcriptionAPIURL))
        let configuration = DictationConfiguration.resolve(defaults: stores.defaults, apiKey: "ui-test-key", transcriptionAPIKey: nil)
        XCTAssertEqual(configuration?.baseURL, "http://127.0.0.1:8765/v1")
        XCTAssertEqual(configuration?.transcriptionBaseURL, "http://127.0.0.1:8765/v1")
    }

    func testAPIKeyHookStoresTheKey() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.apiKey: "ui-test-key"], stores)

        XCTAssertEqual(stores.credentials.storedAPIKey, "ui-test-key")
    }

    func testSkipOnboardingCompletesSetup() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.skipOnboarding: "YES"], stores)

        XCTAssertTrue(stores.settings.hasCompletedSetup)
        XCTAssertTrue(stores.settings.bool(FreeFlowAppSettingKey.dataSharingConsent, default: false))

        apply([Argument.skipOnboarding: "NO"], stores)
        XCTAssertFalse(stores.settings.hasCompletedSetup)
    }

    func testMicrophoneHookSetsTheFlagAndReportsTheOverride() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        let granted = apply([Argument.microphoneGranted: "YES"], stores)
        XCTAssertTrue(granted.setsMicrophoneFlag)
        XCTAssertTrue(stores.settings.microphonePermissionGranted)

        let revoked = apply([Argument.microphoneGranted: "NO"], stores)
        XCTAssertTrue(revoked.setsMicrophoneFlag)
        XCTAssertFalse(stores.settings.microphonePermissionGranted)

        XCTAssertFalse(apply([:], stores).setsMicrophoneFlag)
    }

    func testPreserveExactWordingHook() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.preserveExactWording: "YES"], stores)
        XCTAssertTrue(stores.defaults.bool(forKey: FreeFlowSettingKey.preserveExactWording))

        apply([Argument.preserveExactWording: "NO"], stores)
        XCTAssertNotNil(stores.defaults.object(forKey: FreeFlowSettingKey.preserveExactWording))
        XCTAssertFalse(stores.defaults.bool(forKey: FreeFlowSettingKey.preserveExactWording))
    }

    func testSyntheticCaptureHookSetsTheAppGroupFlag() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.syntheticCapture: "YES"], stores)

        XCTAssertTrue(stores.defaults.bool(forKey: "ios_debug_synthetic_capture"))
    }

    func testCaptureUnavailableHookSetsAndClearsTheAppGroupFlag() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.captureUnavailable: "YES"], stores)
        XCTAssertTrue(stores.defaults.bool(forKey: "ios_debug_capture_unavailable"))
        XCTAssertTrue(WebAudioCaptureUITestSwitch.isOn(stores.defaults))

        apply([Argument.captureUnavailable: "NO"], stores)
        XCTAssertFalse(stores.defaults.bool(forKey: "ios_debug_capture_unavailable"))
        XCTAssertFalse(WebAudioCaptureUITestSwitch.isOn(stores.defaults))
    }

    func testKeyboardStateHookSetsAndClearsTheForcedState() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        apply([Argument.keyboardState: "recording:hold"], stores)
        XCTAssertEqual(stores.defaults.string(forKey: "ios_debug_keyboard_state"), "recording:hold")

        apply([Argument.keyboardState: "live"], stores)
        XCTAssertNil(stores.defaults.object(forKey: "ios_debug_keyboard_state"))
    }

    func testResetClearsSharedStateBeforeTheOtherHooksApply() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.storedAPIKey = "old-key"
        stores.credentials.storedTranscriptionAPIKey = "old-transcription-key"
        stores.settings.hasCompletedSetup = true
        stores.settings.microphonePermissionGranted = true
        stores.settings.set("custom/llm-model", for: FreeFlowSettingKey.postProcessingModel)
        stores.defaults.set(Data("{}".utf8), forKey: "ios_keyboard_status")
        stores.defaults.set("synthetic", forKey: "ios_unknown_future_key")
        stores.defaults.set(true, forKey: "ios_debug_capture_unavailable")
        stores.pendingDictations.awaitedSessionID = UUID()

        let result = apply([
            Argument.reset: "YES",
            Argument.baseURL: "http://127.0.0.1:8765/v1",
            Argument.apiKey: "ui-test-key",
        ], stores)

        XCTAssertTrue(result.didReset)
        XCTAssertEqual(stores.storedKeys, [FreeFlowSettingKey.apiBaseURL])
        XCTAssertEqual(stores.credentials.storedAPIKey, "ui-test-key")
        XCTAssertNil(stores.credentials.storedTranscriptionAPIKey)
        XCTAssertFalse(stores.settings.hasCompletedSetup)
        XCTAssertNil(stores.pendingDictations.awaitedSessionID)
    }

    func testNoArgumentsChangeNothing() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        let result = apply([:], stores)

        XCTAssertEqual(result, FreeFlowUITestHooks.Result())
        XCTAssertTrue(stores.storedKeys.isEmpty)
        XCTAssertEqual(stores.credentials.writeCount, 0)
    }

    func testArgumentValueParsing() {
        for value in ["YES", "yes", "true", "1", " YES "] {
            XCTAssertEqual(FreeFlowUITestHooks.boolValue(value), true, value)
        }
        for value in ["NO", "no", "false", "0"] {
            XCTAssertEqual(FreeFlowUITestHooks.boolValue(value), false, value)
        }
        XCTAssertNil(FreeFlowUITestHooks.boolValue("maybe"))
        XCTAssertNil(FreeFlowUITestHooks.boolValue(nil))
        XCTAssertEqual(FreeFlowUITestHooks.boolValue(NSNumber(value: true)), true)
        XCTAssertEqual(FreeFlowUITestHooks.stringValue("  ui-test-key "), "ui-test-key")
        XCTAssertNil(FreeFlowUITestHooks.stringValue("   "))
    }

    func testArgumentNamesMatchTheDesign() {
        XCTAssertEqual(Argument.reset, "FreeFlowUITestReset")
        XCTAssertEqual(Argument.apiKey, "FreeFlowUITestAPIKey")
        XCTAssertEqual(Argument.baseURL, "FreeFlowUITestBaseURL")
        XCTAssertEqual(Argument.skipOnboarding, "FreeFlowUITestSkipOnboarding")
        XCTAssertEqual(Argument.microphoneGranted, "FreeFlowUITestMicrophoneGranted")
        XCTAssertEqual(Argument.preserveExactWording, "FreeFlowUITestPreserveExactWording")
        XCTAssertEqual(Argument.syntheticCapture, "FreeFlowUITestSyntheticCapture")
        XCTAssertEqual(Argument.captureUnavailable, "FreeFlowUITestCaptureUnavailable")
        XCTAssertEqual(Argument.keyboardState, "FreeFlowUITestKeyboardState")
    }

    @discardableResult
    private func apply(_ arguments: [String: Any], _ stores: AppTestStores) -> FreeFlowUITestHooks.Result {
        FreeFlowUITestHooks.apply(
            arguments,
            settings: stores.settings,
            credentials: stores.credentials,
            history: stores.history,
            pendingDictations: stores.pendingDictations,
            appGroupSuiteName: stores.suiteName
        )
    }
}
#endif
