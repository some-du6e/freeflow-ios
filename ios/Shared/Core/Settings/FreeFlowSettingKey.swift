import Foundation

/// UserDefaults keys for settings the iOS app and keyboard share through the
/// App Group. Keys that also exist on macOS keep the macOS names so the two
/// apps describe the same settings the same way (see Sources/AppState.swift).
enum FreeFlowSettingKey {
    // Same names as macOS.
    static let apiBaseURL = "api_base_url"
    static let transcriptionAPIURL = "transcription_api_url"
    static let transcriptionModel = "transcription_model"
    static let transcriptionLanguage = "transcription_language"
    static let postProcessingModel = "post_processing_model"
    static let postProcessingFallbackModel = "post_processing_fallback_model"
    static let customSystemPrompt = "custom_system_prompt"
    static let customVocabulary = "custom_vocabulary"
    static let outputLanguage = "output_language"
    static let preserveExactWording = "preserve_exact_wording"
    static let instructionExecutionGuardEnabled = "instruction_execution_guard_enabled"
    static let pressEnterVoiceCommandEnabled = "press_enter_voice_command_enabled"
    static let voiceMacros = "voice_macros"
    static let hasCompletedSetup = "hasCompletedSetup"

    // iOS only.
    static let historyEnabled = "history_enabled"
    /// Set by the containing app once it holds microphone permission. A
    /// keyboard process can cache a stale "undetermined" record permission
    /// from before the grant, so the keyboard also trusts this flag.
    static let microphonePermissionGranted = "ios_microphone_permission_granted"
}

/// Defaults that match the macOS app (Sources/AppState.swift and
/// Sources/TranscriptionService.swift).
enum FreeFlowSettingDefaults {
    static let apiBaseURL = "https://api.groq.com/openai/v1"
    static let transcriptionModel = "whisper-large-v3"
    static let postProcessingModel = "openai/gpt-oss-20b"
    static let postProcessingFallbackModel = "qwen/qwen3.8-27b"
    static let instructionExecutionGuardEnabled = true
    static let pressEnterVoiceCommandEnabled = true
    static let preserveExactWording = false
    static let historyEnabled = true
}

/// Keychain account names for secrets. Same names as the macOS settings file.
enum FreeFlowSecretAccount: String, CaseIterable {
    case apiKey = "groq_api_key"
    case transcriptionAPIKey = "transcription_api_key"
}
