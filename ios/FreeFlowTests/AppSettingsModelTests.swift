import XCTest
@testable import FreeFlow

/// Settings round-trips through SettingsStore, and what the keyboard then
/// resolves from the same App Group defaults.
final class AppSettingsModelTests: XCTestCase {
    @MainActor
    func testTogglesAndPickersRoundTrip() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)

        model.preserveExactWording = true
        model.instructionExecutionGuardEnabled = false
        model.pressEnterVoiceCommandEnabled = false
        model.historyEnabled = false
        model.transcriptionLanguage = "de"
        model.outputLanguage = "Japanese"

        let reopened = SettingsScreenModel(settings: stores.settings)
        XCTAssertTrue(reopened.preserveExactWording)
        XCTAssertFalse(reopened.instructionExecutionGuardEnabled)
        XCTAssertFalse(reopened.pressEnterVoiceCommandEnabled)
        XCTAssertFalse(reopened.historyEnabled)
        XCTAssertEqual(reopened.transcriptionLanguage, "de")
        XCTAssertEqual(reopened.outputLanguage, "Japanese")
        XCTAssertFalse(stores.settings.historyEnabled)

        let configuration = DictationConfiguration.resolve(defaults: stores.defaults, apiKey: "synthetic-key", transcriptionAPIKey: nil)
        XCTAssertEqual(configuration?.preserveExactWording, true)
        XCTAssertEqual(configuration?.instructionExecutionGuardEnabled, false)
        XCTAssertEqual(configuration?.pressEnterVoiceCommandEnabled, false)
        XCTAssertEqual(configuration?.transcriptionLanguageCode, "de")
        XCTAssertEqual(configuration?.dictationLanguageName, "German")
        XCTAssertEqual(configuration?.outputLanguage, "Japanese")
    }

    @MainActor
    func testTurningHistoryOffDeletesTheSavedHistory() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        var clears = 0
        let model = SettingsScreenModel(settings: stores.settings) { clears += 1 }

        model.historyEnabled = false
        XCTAssertEqual(clears, 1)
        XCTAssertFalse(stores.settings.historyEnabled)

        model.historyEnabled = true
        XCTAssertEqual(clears, 1, "Turning history back on deletes nothing")

        stores.settings.historyEnabled = false
        model.reload()
        XCTAssertFalse(model.historyEnabled)
        XCTAssertEqual(clears, 1, "Reading the stored setting deletes nothing")
    }

    @MainActor
    func testAutoDetectAndSameAsSpokenRemoveTheirKeys() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)

        model.transcriptionLanguage = "fr"
        model.outputLanguage = "Spanish"
        model.transcriptionLanguage = ""
        model.outputLanguage = ""

        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.transcriptionLanguage))
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.outputLanguage))
    }

    @MainActor
    func testOpeningSettingsWritesNothing() {
        let stores = AppTestStores()
        defer { stores.tearDown() }

        let model = SettingsScreenModel(settings: stores.settings)
        model.reload()

        XCTAssertTrue(stores.storedKeys.isEmpty, "Stored: \(stores.storedKeys)")
        XCTAssertEqual(model.preserveExactWording, FreeFlowSettingDefaults.preserveExactWording)
        XCTAssertEqual(model.instructionExecutionGuardEnabled, FreeFlowSettingDefaults.instructionExecutionGuardEnabled)
        XCTAssertEqual(model.pressEnterVoiceCommandEnabled, FreeFlowSettingDefaults.pressEnterVoiceCommandEnabled)
        XCTAssertEqual(model.historyEnabled, FreeFlowSettingDefaults.historyEnabled)
    }

    @MainActor
    func testModelsAreTrimmedAndBlankMeansDefault() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)

        model.setTranscriptionModel("  whisper-large-v3-turbo  ")
        model.setPostProcessingModel("custom/llm-model")
        model.setPostProcessingFallbackModel("openai/gpt-oss-120b")

        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.transcriptionModel), "whisper-large-v3-turbo")
        let configuration = DictationConfiguration.resolve(defaults: stores.defaults, apiKey: "synthetic-key", transcriptionAPIKey: nil)
        XCTAssertEqual(configuration?.transcriptionModel, "whisper-large-v3-turbo")
        XCTAssertEqual(configuration?.postProcessingModel, "custom/llm-model")
        XCTAssertEqual(configuration?.postProcessingFallbackModel, "openai/gpt-oss-120b")

        model.setTranscriptionModel("   ")
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.transcriptionModel))
        XCTAssertEqual(model.effectiveTranscriptionModel, FreeFlowSettingDefaults.transcriptionModel)
        XCTAssertEqual(
            SettingsScreenModel(settings: stores.settings).effectivePostProcessingModel,
            "custom/llm-model"
        )
    }

    @MainActor
    func testSystemPromptFollowsTheMacOSCommitRules() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)
        let day = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 UTC

        XCTAssertFalse(model.isUsingCustomSystemPrompt)
        XCTAssertEqual(model.systemPromptEditorText, PostProcessingService.defaultSystemPrompt)

        // Saving the default text unchanged keeps using the default.
        model.commitSystemPrompt(PostProcessingService.defaultSystemPrompt + "\n", now: day)
        XCTAssertFalse(model.isUsingCustomSystemPrompt)
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.customSystemPrompt))

        model.commitSystemPrompt("  Clean up the synthetic transcript.  ", now: day)
        XCTAssertTrue(model.isUsingCustomSystemPrompt)
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.customSystemPrompt), "Clean up the synthetic transcript.")
        let stamp = SettingsScreenModel.dayFormatter.string(from: day)
        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowAppSettingKey.customSystemPromptLastModified), stamp)
        XCTAssertFalse(model.hasNewerDefaultSystemPrompt, "Saved after the default prompt's date")
        XCTAssertEqual(SettingsScreenModel(settings: stores.settings).systemPromptEditorText, "Clean up the synthetic transcript.")

        stores.defaults.set("2020-01-01", forKey: FreeFlowAppSettingKey.customSystemPromptLastModified)
        model.reload()
        XCTAssertTrue(model.hasNewerDefaultSystemPrompt)

        model.resetSystemPrompt()
        XCTAssertFalse(model.isUsingCustomSystemPrompt)
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.customSystemPrompt))
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowAppSettingKey.customSystemPromptLastModified))

        model.commitSystemPrompt("   ", now: day)
        XCTAssertFalse(model.isUsingCustomSystemPrompt)
    }

    @MainActor
    func testVocabularyIsTrimmedAndReadBack() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)

        model.setCustomVocabulary("  Synthetica, Flowbert;\nZyx  ")

        XCTAssertEqual(stores.defaults.string(forKey: FreeFlowSettingKey.customVocabulary), "Synthetica, Flowbert;\nZyx")
        XCTAssertEqual(SettingsScreenModel(settings: stores.settings).customVocabulary, "Synthetica, Flowbert;\nZyx")
        XCTAssertEqual(CustomVocabularyScreen.entries(in: model.customVocabulary), ["Synthetica", "Flowbert", "Zyx"])

        model.setCustomVocabulary(" ")
        XCTAssertNil(stores.defaults.object(forKey: FreeFlowSettingKey.customVocabulary))
    }

    @MainActor
    func testVoiceMacrosAddEditAndDelete() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)
        let first = VoiceMacro(command: "synthetic signature", payload: "Sent from a test.")
        let second = VoiceMacro(command: "synthetic address", payload: "1 Example Way")

        model.saveVoiceMacro(first)
        model.saveVoiceMacro(second)
        var edited = first
        edited.payload = "Edited payload."
        model.saveVoiceMacro(edited)

        XCTAssertEqual(stores.settings.voiceMacros, [edited, second])
        let decoded = VoiceMacroCodec.decode(stores.defaults.data(forKey: FreeFlowSettingKey.voiceMacros))
        XCTAssertEqual(decoded, [edited, second])
        XCTAssertEqual(SettingsScreenModel(settings: stores.settings).voiceMacros, [edited, second])

        model.deleteVoiceMacros(at: IndexSet(integer: 0))
        XCTAssertEqual(stores.settings.voiceMacros, [second])
        model.deleteVoiceMacro(id: second.id)
        XCTAssertEqual(stores.settings.voiceMacros, [])
    }

    @MainActor
    func testDailyLimitWarningUsesTheCooldownKey() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let model = SettingsScreenModel(settings: stores.settings)
        let modelID = "synthetic/cooldown-model-\(UUID().uuidString)"
        let key = LLMCooldownManager.udKey(for: modelID)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        XCTAssertNil(model.dailyLimitReset(for: modelID, now: now))
        UserDefaults.standard.set(now.addingTimeInterval(3_600).timeIntervalSince1970, forKey: key)
        XCTAssertEqual(model.dailyLimitReset(for: modelID, now: now), now.addingTimeInterval(3_600))
        UserDefaults.standard.set(now.addingTimeInterval(-60).timeIntervalSince1970, forKey: key)
        XCTAssertNil(model.dailyLimitReset(for: modelID, now: now))
    }

    func testModelChoiceSelection() {
        let choice = ModelChoice.transcription
        XCTAssertEqual(choice.effectiveModel(""), FreeFlowSettingDefaults.transcriptionModel)
        XCTAssertEqual(choice.pickerSelection(stored: "", prefersCustom: false), FreeFlowSettingDefaults.transcriptionModel)
        XCTAssertEqual(choice.pickerSelection(stored: "whisper-large-v3-turbo", prefersCustom: false), "whisper-large-v3-turbo")
        XCTAssertEqual(choice.pickerSelection(stored: "custom-model", prefersCustom: false), ModelChoice.customTag)
        XCTAssertEqual(choice.pickerSelection(stored: "whisper-large-v3", prefersCustom: true), ModelChoice.customTag)
        XCTAssertEqual(ModelChoice.postProcessing.defaultModel, FreeFlowSettingDefaults.postProcessingModel)
        XCTAssertEqual(ModelChoice.postProcessingFallback.defaultModel, FreeFlowSettingDefaults.postProcessingFallbackModel)
        XCTAssertEqual(ModelChoice.postProcessing.predefinedModels, ModelConfiguration.llmModels)
    }
}
