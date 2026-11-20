#if DEBUG
import Foundation

/// Launch arguments that UI tests use to put the app and the keyboard into a
/// known state (DESIGN §5.2). They are read from the argument domain, so
/// `-FreeFlowUITestReset YES` on the command line works, and applied before
/// any UI shows. Everything lands in the App Group and the shared keychain,
/// where the keyboard process reads it. DEBUG builds only.
enum FreeFlowUITestHooks {
    enum Argument {
        /// YES: clears App Group settings, keychain items, history, the
        /// pending handoff and the keyboard status.
        static let reset = "FreeFlowUITestReset"
        /// Stores the API key in the shared keychain.
        static let apiKey = "FreeFlowUITestAPIKey"
        /// Sets `api_base_url` and clears `transcription_api_url`.
        static let baseURL = "FreeFlowUITestBaseURL"
        /// YES sets `hasCompletedSetup` (NO clears it).
        static let skipOnboarding = "FreeFlowUITestSkipOnboarding"
        /// YES|NO sets `microphonePermissionGranted`. The real permission
        /// comes from `xcrun simctl privacy <udid> grant microphone <bundle id>`.
        static let microphoneGranted = "FreeFlowUITestMicrophoneGranted"
        /// YES|NO sets `preserve_exact_wording`.
        static let preserveExactWording = "FreeFlowUITestPreserveExactWording"
        /// YES|NO sets the App Group bool `ios_debug_synthetic_capture`.
        static let syntheticCapture = "FreeFlowUITestSyntheticCapture"
    }

    struct Result: Equatable {
        var didReset = false
        /// The app then leaves `microphonePermissionGranted` alone instead of
        /// mirroring the real permission into it.
        var setsMicrophoneFlag = false
    }

    /// App Group keys other components own, cleared by a reset even if the
    /// suite's persistent domain can't be listed.
    static let knownSharedKeys: [String] = [
        FreeFlowSettingKey.apiBaseURL,
        FreeFlowSettingKey.transcriptionAPIURL,
        FreeFlowSettingKey.transcriptionModel,
        FreeFlowSettingKey.transcriptionLanguage,
        FreeFlowSettingKey.postProcessingModel,
        FreeFlowSettingKey.postProcessingFallbackModel,
        FreeFlowSettingKey.customSystemPrompt,
        FreeFlowSettingKey.customVocabulary,
        FreeFlowSettingKey.outputLanguage,
        FreeFlowSettingKey.preserveExactWording,
        FreeFlowSettingKey.instructionExecutionGuardEnabled,
        FreeFlowSettingKey.pressEnterVoiceCommandEnabled,
        FreeFlowSettingKey.voiceMacros,
        FreeFlowSettingKey.hasCompletedSetup,
        FreeFlowSettingKey.historyEnabled,
        FreeFlowSettingKey.microphonePermissionGranted,
        FreeFlowAppSettingKey.dataSharingConsent,
        FreeFlowAppSettingKey.onboardingStep,
        FreeFlowAppSettingKey.customSystemPromptLastModified,
        FreeFlowAppSettingKey.debugSyntheticCapture,
        // Store keys from DESIGN §6.2 and §6.3.
        "ios_pending_dictation",
        "ios_awaited_dictation_session",
        "ios_keyboard_status",
        "ios_debug_keyboard_state",
    ]

    static func applyLaunchArguments() -> Result {
        apply(
            UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
            settings: .shared,
            credentials: SettingsStore.shared,
            history: .shared,
            pendingDictations: .shared,
            appGroupSuiteName: FreeFlowIdentifiers.appGroupIdentifier
        )
    }

    static func apply(
        _ arguments: [String: Any],
        settings: SettingsStore,
        credentials: AppCredentialStore,
        history: HistoryStore,
        pendingDictations: PendingDictationStore,
        appGroupSuiteName: String?
    ) -> Result {
        var result = Result()

        if boolValue(arguments[Argument.reset]) == true {
            reset(
                settings: settings,
                credentials: credentials,
                history: history,
                pendingDictations: pendingDictations,
                appGroupSuiteName: appGroupSuiteName
            )
            result.didReset = true
        }
        if let key = stringValue(arguments[Argument.apiKey]) {
            try? credentials.setAPIKey(key)
        }
        if let baseURL = stringValue(arguments[Argument.baseURL]) {
            settings.set(baseURL, for: FreeFlowSettingKey.apiBaseURL)
            settings.removeValue(for: FreeFlowSettingKey.transcriptionAPIURL)
        }
        if let skipOnboarding = boolValue(arguments[Argument.skipOnboarding]) {
            settings.hasCompletedSetup = skipOnboarding
            if skipOnboarding {
                // Skipping onboarding skips the consent page too.
                settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
            }
        }
        if let granted = boolValue(arguments[Argument.microphoneGranted]) {
            settings.microphonePermissionGranted = granted
            result.setsMicrophoneFlag = true
        }
        if let preserve = boolValue(arguments[Argument.preserveExactWording]) {
            settings.set(preserve, for: FreeFlowSettingKey.preserveExactWording)
        }
        if let synthetic = boolValue(arguments[Argument.syntheticCapture]) {
            settings.set(synthetic, for: FreeFlowAppSettingKey.debugSyntheticCapture)
        }
        return result
    }

    private static func reset(
        settings: SettingsStore,
        credentials: AppCredentialStore,
        history: HistoryStore,
        pendingDictations: PendingDictationStore,
        appGroupSuiteName: String?
    ) {
        var keys = Set(knownSharedKeys)
        if let appGroupSuiteName,
           let domain = settings.defaults.persistentDomain(forName: appGroupSuiteName) {
            keys.formUnion(domain.keys)
        }
        for key in keys {
            settings.removeValue(for: key)
        }
        try? credentials.setAPIKey(nil)
        try? credentials.setTranscriptionAPIKey(nil)
        history.clear()
        pendingDictations.clear()
        pendingDictations.awaitedSessionID = nil
    }

    /// Argument-domain values arrive as strings ("YES") or, when parsed as
    /// property lists, numbers.
    static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1":
            return true
        case "no", "false", "0":
            return false
        default:
            return nil
        }
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
