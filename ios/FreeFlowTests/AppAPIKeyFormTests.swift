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

    /// GET /models accepts these, but the pipeline can't build a cleanup URL
    /// from them, so every dictation would skip cleanup and translation.
    @MainActor
    func testBaseURLsThePipelineRejectsAreRefusedBeforeAnyRequest() async {
        let refused = [
            "https://llm.invalid/v1?",
            "https://llm.invalid/v1?token=synthetic",
            "https://llm.invalid/v1#",
            "https://llm.invalid/v1#part",
            " ftp://llm.invalid/v1 ",
            "https:///v1",
        ]
        for baseURL in refused {
            let stores = AppTestStores()
            defer { stores.tearDown() }
            let validations = AppValidationRecorder()
            let form = makeForm(stores, validations)

            form.presentIfNeeded()
            form.draft.apiKey = "synthetic-key"
            form.draft.baseURL = baseURL

            let saved = await form.save()

            XCTAssertFalse(saved, baseURL)
            XCTAssertEqual(form.status, .failed(APIKeyFormModel.validationFailedMessage), baseURL)
            XCTAssertFalse(form.showsSavedSuccess, baseURL)
            let calls = await validations.calls
            XCTAssertEqual(calls, [], "Nothing is sent for \(baseURL)")
            XCTAssertEqual(stores.credentials.writeCount, 0, baseURL)
            XCTAssertNil(stores.credentials.storedAPIKey, baseURL)
            XCTAssertNil(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL), baseURL)
            XCTAssertEqual(form.draft.baseURL, baseURL, "The field keeps the URL so it can be corrected")
        }
    }

    @MainActor
    func testRefusedBaseURLLeavesTheSavedConfigurationAlone() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.storedAPIKey = "saved-key"
        stores.defaults.set("https://llm.invalid/v1", forKey: FreeFlowSettingKey.apiBaseURL)
        let validations = AppValidationRecorder()
        let form = makeForm(stores, validations)

        form.presentIfNeeded()
        form.draft.apiKey = "new-key"
        form.draft.baseURL = "https://llm.invalid/v1#part"

        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(form.failureMessage, APIKeyFormModel.validationFailedMessage)
        XCTAssertEqual(stores.credentials.storedAPIKey, "saved-key")
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL), "https://llm.invalid/v1")
        XCTAssertEqual(form.committed.baseURL, "https://llm.invalid/v1")
        let calls = await validations.calls
        XCTAssertEqual(calls, [])

        // Without the fragment the same form validates and saves.
        form.draft.baseURL = "https://llm.invalid/v2"
        let resaved = await form.save()

        XCTAssertTrue(resaved)
        XCTAssertEqual(stores.credentials.storedAPIKey, "new-key")
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.apiBaseURL), "https://llm.invalid/v2")
    }

    /// Only the cleanup base URL is checked. The transcription service keeps
    /// a query when it adds its path, so a transcription URL may have one.
    @MainActor
    func testTranscriptionURLMayKeepAQuery() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let validations = AppValidationRecorder()
        let form = makeForm(stores, validations)

        form.presentIfNeeded()
        form.draft.apiKey = "main-key"
        form.draft.transcriptionAPIURL = "https://speech.invalid/v1?region=synthetic"

        let saved = await form.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(
            stores.defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL),
            "https://speech.invalid/v1?region=synthetic"
        )
        let calls = await validations.calls
        XCTAssertEqual(calls.map(\.baseURL), [APIConfigurationSaveFlow.defaultBaseURL, "https://speech.invalid/v1?region=synthetic"])
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

    /// The onboarding page says a key is saved instead of leaving a field of
    /// dots unexplained, and never shows any of the key.
    @MainActor
    func testAStoredKeyShowsTheSavedHintWithoutTheKey() async {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.storedAPIKey = "synthetic-saved-key"
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()

        XCTAssertTrue(form.showsSavedKeyHint)
        XCTAssertEqual(APIKeyFormModel.savedKeyHint, "A key is saved. Enter a new one to replace it.")
        XCTAssertFalse(APIKeyFormModel.savedKeyHint.contains("synthetic"), "The hint never shows the key")

        form.draft.apiKey = ""
        XCTAssertFalse(form.showsSavedKeyHint, "A cleared field is being replaced")
        form.draft.apiKey = "synthetic-new-key"
        XCTAssertFalse(form.showsSavedKeyHint, "A new key is being typed")

        let saved = await form.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(form.showsSavedSuccess)
        XCTAssertFalse(form.showsSavedKeyHint, "\"API key saved\" says it already")
    }

    @MainActor
    func testNoStoredKeyShowsNoSavedHint() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()
        XCTAssertFalse(form.showsSavedKeyHint)

        form.draft.apiKey = "synthetic-typed-key"
        XCTAssertFalse(form.showsSavedKeyHint, "A typed key isn't a saved one")
    }

    @MainActor
    func testUnreadableKeychainShowsNoSavedHint() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.readFailure = .unavailable
        let form = makeForm(stores, AppValidationRecorder())

        form.presentIfNeeded()

        XCTAssertFalse(form.showsSavedKeyHint)
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
