import Foundation

/// Everything one dictation needs, resolved from shared settings and secrets
/// with the same fallbacks as the macOS app (Sources/AppState.swift:1144-1175):
/// an empty transcription URL or key falls back to the main base URL and key,
/// and blank models fall back to the defaults.
struct DictationConfiguration: Equatable {
    var apiKey: String
    var baseURL: String
    /// Effective transcription credentials, after the fallbacks above.
    var transcriptionAPIKey: String
    var transcriptionBaseURL: String
    var transcriptionModel: String
    /// ISO code, or "" for auto-detect.
    var transcriptionLanguageCode: String
    var postProcessingModel: String
    var postProcessingFallbackModel: String
    var customSystemPrompt: String
    var customVocabulary: String
    /// English language name, or "" for "Same as spoken".
    var outputLanguage: String
    var preserveExactWording: Bool
    var instructionExecutionGuardEnabled: Bool
    var pressEnterVoiceCommandEnabled: Bool
    var voiceMacros: [VoiceMacro]

    /// The English name PostProcessingService expects as `dictationLanguage`.
    var dictationLanguageName: String {
        LanguageOptions.transcriptionLanguageName(forCode: transcriptionLanguageCode)
    }

    /// Returns nil when there is no usable API key, which callers present as
    /// "setup needed". Reads only the keys in `FreeFlowSettingKey`.
    static func resolve(
        defaults: UserDefaults,
        apiKey: String?,
        transcriptionAPIKey: String?
    ) -> DictationConfiguration? {
        let key = trimmed(apiKey)
        guard !key.isEmpty else { return nil }

        let storedBaseURL = trimmed(defaults.string(forKey: FreeFlowSettingKey.apiBaseURL))
        let baseURL = storedBaseURL.isEmpty ? FreeFlowSettingDefaults.apiBaseURL : storedBaseURL
        let storedTranscriptionURL = trimmed(defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL))
        let storedTranscriptionKey = trimmed(transcriptionAPIKey)

        return DictationConfiguration(
            apiKey: key,
            baseURL: baseURL,
            transcriptionAPIKey: storedTranscriptionKey.isEmpty ? key : storedTranscriptionKey,
            transcriptionBaseURL: storedTranscriptionURL.isEmpty ? baseURL : storedTranscriptionURL,
            transcriptionModel: string(defaults, FreeFlowSettingKey.transcriptionModel, FreeFlowSettingDefaults.transcriptionModel),
            transcriptionLanguageCode: trimmed(defaults.string(forKey: FreeFlowSettingKey.transcriptionLanguage)),
            postProcessingModel: string(defaults, FreeFlowSettingKey.postProcessingModel, FreeFlowSettingDefaults.postProcessingModel),
            postProcessingFallbackModel: string(defaults, FreeFlowSettingKey.postProcessingFallbackModel, FreeFlowSettingDefaults.postProcessingFallbackModel),
            customSystemPrompt: defaults.string(forKey: FreeFlowSettingKey.customSystemPrompt) ?? "",
            customVocabulary: defaults.string(forKey: FreeFlowSettingKey.customVocabulary) ?? "",
            outputLanguage: trimmed(defaults.string(forKey: FreeFlowSettingKey.outputLanguage)),
            preserveExactWording: bool(defaults, FreeFlowSettingKey.preserveExactWording, FreeFlowSettingDefaults.preserveExactWording),
            instructionExecutionGuardEnabled: bool(defaults, FreeFlowSettingKey.instructionExecutionGuardEnabled, FreeFlowSettingDefaults.instructionExecutionGuardEnabled),
            pressEnterVoiceCommandEnabled: bool(defaults, FreeFlowSettingKey.pressEnterVoiceCommandEnabled, FreeFlowSettingDefaults.pressEnterVoiceCommandEnabled),
            voiceMacros: VoiceMacroCodec.decode(defaults.data(forKey: FreeFlowSettingKey.voiceMacros))
        )
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ defaults: UserDefaults, _ key: String, _ fallback: String) -> String {
        let value = trimmed(defaults.string(forKey: key))
        return value.isEmpty ? fallback : value
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
