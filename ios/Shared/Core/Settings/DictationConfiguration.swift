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

    /// The retired default fallback model that macOS resets
    /// (`AppState.deprecatedDefaultPostProcessingFallbackModel`).
    private static let deprecatedPostProcessingFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"

    /// Returns nil when there is no usable API key, which callers present as
    /// "setup needed". Reads only the keys in `FreeFlowSettingKey`, after
    /// applying `migrateLegacyModelSettings(in:)` like macOS does at launch.
    static func resolve(
        defaults: UserDefaults,
        apiKey: String?,
        transcriptionAPIKey: String?
    ) -> DictationConfiguration? {
        let key = trimmed(apiKey)
        guard !key.isEmpty else { return nil }

        migrateLegacyModelSettings(in: defaults)
        let baseURL = resolvedBaseURL(in: defaults)
        let storedTranscriptionURL = trimmed(defaults.string(forKey: FreeFlowSettingKey.transcriptionAPIURL))
        let storedTranscriptionKey = trimmed(transcriptionAPIKey)
        let fallbackModel = string(
            defaults,
            FreeFlowSettingKey.postProcessingFallbackModel,
            FreeFlowSettingDefaults.postProcessingFallbackModel
        )

        return DictationConfiguration(
            apiKey: key,
            baseURL: baseURL,
            transcriptionAPIKey: storedTranscriptionKey.isEmpty ? key : storedTranscriptionKey,
            transcriptionBaseURL: storedTranscriptionURL.isEmpty ? baseURL : storedTranscriptionURL,
            transcriptionModel: string(defaults, FreeFlowSettingKey.transcriptionModel, FreeFlowSettingDefaults.transcriptionModel),
            transcriptionLanguageCode: normalizedTranscriptionLanguageCode(
                defaults.string(forKey: FreeFlowSettingKey.transcriptionLanguage)
            ),
            postProcessingModel: string(defaults, FreeFlowSettingKey.postProcessingModel, FreeFlowSettingDefaults.postProcessingModel),
            // The migration above already rewrote the stored value; this also
            // covers a process whose App Group is read-only.
            postProcessingFallbackModel: fallbackModel == deprecatedPostProcessingFallbackModel
                ? FreeFlowSettingDefaults.postProcessingFallbackModel
                : fallbackModel,
            customSystemPrompt: defaults.string(forKey: FreeFlowSettingKey.customSystemPrompt) ?? "",
            customVocabulary: defaults.string(forKey: FreeFlowSettingKey.customVocabulary) ?? "",
            outputLanguage: trimmed(defaults.string(forKey: FreeFlowSettingKey.outputLanguage)),
            preserveExactWording: bool(defaults, FreeFlowSettingKey.preserveExactWording, FreeFlowSettingDefaults.preserveExactWording),
            instructionExecutionGuardEnabled: bool(defaults, FreeFlowSettingKey.instructionExecutionGuardEnabled, FreeFlowSettingDefaults.instructionExecutionGuardEnabled),
            pressEnterVoiceCommandEnabled: bool(defaults, FreeFlowSettingKey.pressEnterVoiceCommandEnabled, FreeFlowSettingDefaults.pressEnterVoiceCommandEnabled),
            voiceMacros: VoiceMacroCodec.decode(defaults.data(forKey: FreeFlowSettingKey.voiceMacros))
        )
    }

    /// The macOS launch-time model migrations, rewriting stored values:
    /// - `ModelConfiguration.migrateGroqSelection` moves retired Qwen 3.6 IDs
    ///   to Qwen 3.8, only on Groq's own endpoint (Sources/AppState.swift:697-699).
    /// - The retired llama-4-scout default fallback resets to the current
    ///   default (Sources/AppState.swift:981-993).
    /// iOS has no context model, so only the two cleanup models migrate.
    /// Writes only when a value changes. `resolve` calls this; the app may
    /// also call it at launch so Settings shows migrated values.
    static func migrateLegacyModelSettings(in defaults: UserDefaults) {
        let baseURL = resolvedBaseURL(in: defaults)
        for key in [FreeFlowSettingKey.postProcessingModel, FreeFlowSettingKey.postProcessingFallbackModel] {
            ModelConfiguration.migrateGroqSelection(key: key, baseURL: baseURL, defaults: defaults)
        }
        if trimmed(defaults.string(forKey: FreeFlowSettingKey.postProcessingFallbackModel)) == deprecatedPostProcessingFallbackModel {
            defaults.set(
                FreeFlowSettingDefaults.postProcessingFallbackModel,
                forKey: FreeFlowSettingKey.postProcessingFallbackModel
            )
        }
    }

    /// The macOS `AppState.normalizeTranscriptionLanguage`: a known code,
    /// lowercased, or "" (auto-detect) for anything else.
    static func normalizedTranscriptionLanguageCode(_ value: String?) -> String {
        let normalized = trimmed(value).lowercased()
        guard LanguageOptions.transcriptionLanguages.contains(where: { $0.code == normalized }) else {
            return ""
        }
        return normalized
    }

    private static func resolvedBaseURL(in defaults: UserDefaults) -> String {
        let storedBaseURL = trimmed(defaults.string(forKey: FreeFlowSettingKey.apiBaseURL))
        return storedBaseURL.isEmpty ? FreeFlowSettingDefaults.apiBaseURL : storedBaseURL
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
