import XCTest
@testable import FreeFlow

/// The API key form's validation states. The validator is faked, so nothing
/// reaches a provider.
final class AppAPIKeyFormTests: XCTestCase {
    @MainActor
    func testSavingAValidKeyStoresItAndLeavesTheDefaultBaseURLUnset() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let validations = AppValidationRecorder()
        let form = makeForm(stores, validations)

        form.presentIfNeeded()
        XCTAssertEqual(form.draft.baseURL, APIConfigurationSaveFlow.defaultBaseURL)
        XCTAssertFalse(form.canSubmit, "An empty key can't be submitted")
        form.draft.apiKey = "  gsk_synthetic_key  "
        XCTAssertTrue(form.canSubmit)

        let saved = await form.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(form.status, .saved)
        XCTAssertTrue(form.showsSavedSuccess)
        XCTAssertEqual(stores.credentials.storedAPIKey, "gsk_synthetic_key")
        XCTAssertNil(stores.credentials.storedTranscriptionAPIKey)
        XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL))
        XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL))
        let calls = await validations.calls
        XCTAssertEqual(calls, [AppValidationRecorder.Call(key: "gsk_synthetic_key", baseURL: APIConfigurationSaveFlow.defaultBaseURL)])
        XCTAssertEqual(form.draft.apiKey, "gsk_synthetic_key", "The form shows the trimmed key")
        XCTAssertTrue(form.isUnchangedAndSaved)
    }

    @MainActor
    func testCustomProviderAndTranscriptionEndpointAreValidatedAndStored() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let validations = AppValidationRecorder()
        let form = makeForm(stores, validations)

        form.presentIfNeeded()
        form.draft.apiKey = "main-key"
        form.draft.baseURL = "https://llm.invalid/v1"
        form.draft.transcriptionAPIURL = "https://speech.invalid/v1"
        form.draft.transcriptionAPIKey = "speech-key"

        let saved = await form.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL), "https://llm.invalid/v1")
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL), "https://speech.invalid/v1")
        XCTAssertEqual(stores.credentials.storedAPIKey, "main-key")
        XCTAssertEqual(stores.credentials.storedTranscriptionAPIKey, "speech-key")
        let calls = await validations.calls
        XCTAssertEqual(calls, [
            AppValidationRecorder.Call(key: "main-key", baseURL: "https://llm.invalid/v1"),
            AppValidationRecorder.Call(key: "speech-key", baseURL: "https://speech.invalid/v1"),
        ])

        // A fresh form, as when Settings opens again, reads it all back.
        let reopened = makeForm(stores, validations)
        reopened.presentIfNeeded()
        XCTAssertEqual(reopened.draft.apiKey, "main-key")
        XCTAssertEqual(reopened.draft.baseURL, "https://llm.invalid/v1")
        XCTAssertEqual(reopened.draft.transcriptionAPIURL, "https://speech.invalid/v1")
        XCTAssertEqual(reopened.draft.transcriptionAPIKey, "speech-key")
    }

    @MainActor
    func testFailedValidationShowsTheMacOSMessageAndStoresNothing() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let form = makeForm(stores, AppValidationRecorder(defaultResult: false))

        form.presentIfNeeded()
        form.draft.apiKey = "rejected-key"
        form.draft.baseURL = "https://llm.invalid/v1"

        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(form.status, .failed(APIKeyFormModel.validationFailedMessage))
        XCTAssertEqual(
            form.failureMessage,
            "Validation failed. Please check your API key and provider settings, then try again."
        )
        XCTAssertNil(stores.credentials.storedAPIKey)
        XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL))
        XCTAssertFalse(form.showsSavedSuccess)
    }

    @MainActor
    func testRejectedTranscriptionEndpointFailsTheWholeSave() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let form = makeForm(stores, AppValidationRecorder(results: ["https://speech.invalid/v1": false]))

        form.presentIfNeeded()
        form.draft.apiKey = "main-key"
        form.draft.transcriptionAPIURL = "https://speech.invalid/v1"

        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertNil(stores.credentials.storedAPIKey)
        XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL))
    }

    @MainActor
    func testKeychainFailureIsReported() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.failsWrites = true
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()
        form.draft.apiKey = "synthetic-key"
        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(form.status, .failed(APIKeyFormModel.keychainFailedMessage))
    }

    @MainActor
    func testEditingAfterSavingHidesTheSavedMessage() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()
        form.draft.apiKey = "first-key"
        _ = await form.save()
        XCTAssertTrue(form.showsSavedSuccess)

        form.draft.apiKey = "second-key"

        XCTAssertFalse(form.showsSavedSuccess)
        XCTAssertFalse(form.isUnchangedAndSaved)
    }

    @MainActor
    func testResetBaseURLRemovesTheStoredOverride() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.defaults.set("https://llm.invalid/v1", forKey: FreeFlowSettingKey.apiBaseURL)
        stores.credentials.storedAPIKey = "synthetic-key"
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()
        XCTAssertEqual(form.draft.baseURL, "https://llm.invalid/v1")
        form.resetBaseURLToDefault()
        let saved = await form.save()

        XCTAssertTrue(saved)
        XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL))
    }

    @MainActor
    func testUnreadableKeychainIsSurfaced() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.readFailure = .unavailable
        let form = makeForm(stores, AppValidationRecorder())

        XCTAssertEqual(form.keychainFailure, .unavailable)
        XCTAssertFalse(form.hasSavedKey)
    }

    @MainActor
    private func makeForm(_ stores: AppTestStores, _ validations: AppValidationRecorder) -> APIKeyFormModel {
        APIKeyFormModel(
            settings: stores.settings,
            credentials: stores.credentials,
            validator: { key, baseURL in await validations.validate(key, baseURL) }
        )
    }
}
