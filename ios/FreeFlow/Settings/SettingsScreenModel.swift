import Foundation

/// Every v1 setting except the API keys, read from and written straight to
/// `SettingsStore` (the App Group the keyboard reads). Text fields commit on
/// submit or when they lose focus, like macOS; toggles and pickers commit
/// at once. `reload()` re-reads the store, so reopened screens show what
/// is saved.
@MainActor
final class SettingsScreenModel: ObservableObject {
    @Published private(set) var transcriptionModel = ""
    @Published private(set) var postProcessingModel = ""
    @Published private(set) var postProcessingFallbackModel = ""
    @Published private(set) var customVocabulary = ""
    /// "" means the default prompt.
    @Published private(set) var customSystemPrompt = ""
    @Published private(set) var customSystemPromptLastModified = ""
    @Published private(set) var voiceMacros: [VoiceMacro] = []

    @Published var transcriptionLanguage = "" {
        didSet { persist { storeOrRemove(transcriptionLanguage, for: FreeFlowSettingKey.transcriptionLanguage) } }
    }
    @Published var outputLanguage = "" {
        didSet { persist { storeOrRemove(outputLanguage, for: FreeFlowSettingKey.outputLanguage) } }
    }
    @Published var preserveExactWording = FreeFlowSettingDefaults.preserveExactWording {
        didSet { persist { settings.set(preserveExactWording, for: FreeFlowSettingKey.preserveExactWording) } }
    }
    @Published var instructionExecutionGuardEnabled = FreeFlowSettingDefaults.instructionExecutionGuardEnabled {
        didSet {
            persist { settings.set(instructionExecutionGuardEnabled, for: FreeFlowSettingKey.instructionExecutionGuardEnabled) }
        }
    }
    @Published var pressEnterVoiceCommandEnabled = FreeFlowSettingDefaults.pressEnterVoiceCommandEnabled {
        didSet {
            persist { settings.set(pressEnterVoiceCommandEnabled, for: FreeFlowSettingKey.pressEnterVoiceCommandEnabled) }
        }
    }
    /// Turning Keep History off also deletes the saved history and any
    /// handed-off result, so no dictation text stays on the device
    /// (FreeFlowAppEnvironment.clearHistory()).
    @Published var historyEnabled = FreeFlowSettingDefaults.historyEnabled {
        didSet {
            persist {
                settings.historyEnabled = historyEnabled
                if !historyEnabled {
                    clearHistory()
                }
            }
        }
    }

    let settings: SettingsStore
    private let clearHistory: () -> Void
    private var isLoading = false

    /// `clearHistory` runs when Keep History is turned off. Screens use
    /// `init(environment:)`, which wires it to the real clear.
    init(settings: SettingsStore, clearHistory: @escaping () -> Void) {
        self.settings = settings
        self.clearHistory = clearHistory
        reload()
    }

    /// The model the screens use: turning Keep History off runs
    /// `FreeFlowAppEnvironment.clearHistory()`, like Clear History.
    convenience init(environment: FreeFlowAppEnvironment) {
        self.init(settings: environment.settings) {
            environment.clearHistory()
        }
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        transcriptionModel = trimmed(FreeFlowSettingKey.transcriptionModel)
        postProcessingModel = trimmed(FreeFlowSettingKey.postProcessingModel)
        postProcessingFallbackModel = trimmed(FreeFlowSettingKey.postProcessingFallbackModel)
        transcriptionLanguage = trimmed(FreeFlowSettingKey.transcriptionLanguage)
        outputLanguage = trimmed(FreeFlowSettingKey.outputLanguage)
        preserveExactWording = settings.bool(
            FreeFlowSettingKey.preserveExactWording,
            default: FreeFlowSettingDefaults.preserveExactWording
        )
        instructionExecutionGuardEnabled = settings.bool(
            FreeFlowSettingKey.instructionExecutionGuardEnabled,
            default: FreeFlowSettingDefaults.instructionExecutionGuardEnabled
        )
        pressEnterVoiceCommandEnabled = settings.bool(
            FreeFlowSettingKey.pressEnterVoiceCommandEnabled,
            default: FreeFlowSettingDefaults.pressEnterVoiceCommandEnabled
        )
        historyEnabled = settings.historyEnabled
        customVocabulary = settings.string(FreeFlowSettingKey.customVocabulary)
        customSystemPrompt = settings.string(FreeFlowSettingKey.customSystemPrompt)
        customSystemPromptLastModified = settings.string(FreeFlowAppSettingKey.customSystemPromptLastModified)
        voiceMacros = settings.voiceMacros
    }

    // MARK: Models

    /// The model in use: the stored one, or the default when none is stored.
    var effectiveTranscriptionModel: String {
        transcriptionModel.isEmpty ? FreeFlowSettingDefaults.transcriptionModel : transcriptionModel
    }

    var effectivePostProcessingModel: String {
        postProcessingModel.isEmpty ? FreeFlowSettingDefaults.postProcessingModel : postProcessingModel
    }

    var effectivePostProcessingFallbackModel: String {
        postProcessingFallbackModel.isEmpty
            ? FreeFlowSettingDefaults.postProcessingFallbackModel
            : postProcessingFallbackModel
    }

    func setTranscriptionModel(_ value: String) {
        transcriptionModel = commitModel(value, key: FreeFlowSettingKey.transcriptionModel)
    }

    func setPostProcessingModel(_ value: String) {
        postProcessingModel = commitModel(value, key: FreeFlowSettingKey.postProcessingModel)
    }

    func setPostProcessingFallbackModel(_ value: String) {
        postProcessingFallbackModel = commitModel(value, key: FreeFlowSettingKey.postProcessingFallbackModel)
    }

    /// When a model hit its provider's daily limit, the time it resets. The
    /// cooldown lives in this process's standard defaults, so it reflects
    /// dictations made in the app.
    func dailyLimitReset(for model: String, now: Date) -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: LLMCooldownManager.udKey(for: model))
        guard timestamp > 0 else { return nil }
        let expiry = Date(timeIntervalSince1970: timestamp)
        return expiry > now ? expiry : nil
    }

    // MARK: Vocabulary and prompt

    func setCustomVocabulary(_ value: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        customVocabulary = trimmedValue
        storeOrRemove(trimmedValue, for: FreeFlowSettingKey.customVocabulary)
    }

    var isUsingCustomSystemPrompt: Bool {
        !customSystemPrompt.isEmpty
    }

    /// Same banner rule as macOS: a custom prompt saved before the current
    /// default prompt's date.
    var hasNewerDefaultSystemPrompt: Bool {
        isUsingCustomSystemPrompt
            && !customSystemPromptLastModified.isEmpty
            && customSystemPromptLastModified < PostProcessingService.defaultSystemPromptDate
    }

    /// What the prompt editor starts with: the custom prompt, or the default.
    var systemPromptEditorText: String {
        isUsingCustomSystemPrompt ? customSystemPrompt : PostProcessingService.defaultSystemPrompt
    }

    /// macOS commit rule: an empty prompt or the default text means "use the
    /// default"; anything else is stored with today's date.
    func commitSystemPrompt(_ value: String, now: Date = Date()) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPrompt = PostProcessingService.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty || trimmedValue == defaultPrompt {
            resetSystemPrompt()
        } else if trimmedValue != customSystemPrompt {
            customSystemPrompt = trimmedValue
            customSystemPromptLastModified = Self.dayFormatter.string(from: now)
            settings.set(trimmedValue, for: FreeFlowSettingKey.customSystemPrompt)
            settings.set(customSystemPromptLastModified, for: FreeFlowAppSettingKey.customSystemPromptLastModified)
        }
    }

    func resetSystemPrompt() {
        customSystemPrompt = ""
        customSystemPromptLastModified = ""
        settings.removeValue(for: FreeFlowSettingKey.customSystemPrompt)
        settings.removeValue(for: FreeFlowAppSettingKey.customSystemPromptLastModified)
    }

    // MARK: Voice macros

    /// Adds the macro, or replaces the one with the same ID.
    func saveVoiceMacro(_ macro: VoiceMacro) {
        var macros = voiceMacros
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
        setVoiceMacros(macros)
    }

    func deleteVoiceMacros(at offsets: IndexSet) {
        var macros = voiceMacros
        for index in offsets.sorted(by: >) where macros.indices.contains(index) {
            macros.remove(at: index)
        }
        setVoiceMacros(macros)
    }

    func deleteVoiceMacro(id: UUID) {
        setVoiceMacros(voiceMacros.filter { $0.id != id })
    }

    private func setVoiceMacros(_ macros: [VoiceMacro]) {
        voiceMacros = macros
        settings.voiceMacros = macros
    }

    // MARK: Helpers

    /// yyyy-MM-dd, the macOS `custom_system_prompt_last_modified` format.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func trimmed(_ key: String) -> String {
        settings.string(key).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitModel(_ value: String, key: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        storeOrRemove(trimmedValue, for: key)
        return trimmedValue
    }

    /// Runs a write unless `reload()` is assigning the stored values.
    private func persist(_ write: () -> Void) {
        guard !isLoading else { return }
        write()
    }

    /// Stores `value`, or removes the key when it is empty so readers fall
    /// back to the default.
    private func storeOrRemove(_ value: String, for key: String) {
        if value.isEmpty {
            settings.removeValue(for: key)
        } else {
            settings.set(value, for: key)
        }
    }
}
