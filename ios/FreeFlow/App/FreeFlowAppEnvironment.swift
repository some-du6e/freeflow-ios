import Foundation

/// App Group keys only the containing app reads. Shared settings use
/// `FreeFlowSettingKey`; these sit next to them in the same App Group suite,
/// so a UI-test reset clears them too.
enum FreeFlowAppSettingKey {
    /// Set when the user agrees to the data-sharing screen in onboarding
    /// (App Review 5.1.2(i)). The version is in the name so a materially
    /// different disclosure can ask again.
    static let dataSharingConsent = "ios_data_sharing_consent_v1"
    /// The onboarding page to resume on after a relaunch, for example after
    /// iOS restarts the app when the user changes a permission in Settings.
    static let onboardingStep = "ios_onboarding_step"
    /// Same name as the macOS key; the date the custom prompt was last saved.
    static let customSystemPromptLastModified = "custom_system_prompt_last_modified"
    /// DEBUG only: feed a synthetic tone instead of the microphone (DESIGN §5.2).
    /// WebAudioCapture reads it in the keyboard; the app's recorder honors it too.
    static let debugSyntheticCapture = "ios_debug_synthetic_capture"
}

/// The secret half of `SettingsStore`, as a protocol so view models can be
/// tested without the shared keychain.
protocol AppCredentialStore: AnyObject {
    func apiKey() -> Result<String?, SharedKeychain.Failure>
    func setAPIKey(_ value: String?) throws
    func transcriptionAPIKey() -> Result<String?, SharedKeychain.Failure>
    func setTranscriptionAPIKey(_ value: String?) throws
}

extension SettingsStore: AppCredentialStore {}

/// Everything the app reads and writes outside its own memory. `live` uses
/// the App Group stores the keyboard also reads; tests build one around a
/// throwaway defaults suite and fakes.
struct FreeFlowAppEnvironment {
    var settings: SettingsStore
    var credentials: AppCredentialStore
    var history: HistoryStore
    var pendingDictations: PendingDictationStore
    var keyboardStatus: KeyboardStatusStore
    var microphone: AppMicrophoneAccess
    /// GET {base}/models, as on macOS. Tests inject a fake.
    var validateAPIKey: @Sendable (String, String) async -> Bool
    var makeRecorderDependencies: (FreeFlowAppEnvironment) -> RecorderDependencies

    static var live: FreeFlowAppEnvironment {
        FreeFlowAppEnvironment(
            settings: .shared,
            credentials: SettingsStore.shared,
            history: .shared,
            pendingDictations: .shared,
            keyboardStatus: .shared,
            microphone: SystemAppMicrophoneAccess(),
            validateAPIKey: { key, baseURL in
                await TranscriptionService.validateAPIKey(key, baseURL: baseURL)
            },
            makeRecorderDependencies: { RecorderDependencies.live(environment: $0) }
        )
    }

    var hasDataSharingConsent: Bool {
        settings.bool(FreeFlowAppSettingKey.dataSharingConsent, default: false)
    }

    /// Clear History and turning Keep History off: deletes the history and
    /// any handed-off result still in the App Group, which holds dictation
    /// text too, including one the keyboard offers with Insert from FreeFlow.
    /// When that result is for the session the keyboard awaits, the wait
    /// ends with it, so the keyboard's next check neither keeps showing
    /// "Waiting for FreeFlow" for a result that's gone nor keeps offering
    /// it. A handoff that hasn't delivered yet keeps its session.
    func clearHistory() {
        history.clear()
        pendingDictations.discardResultAndItsWait()
    }

    /// Whether a usable API key is stored, and why not when the keychain
    /// itself can't be read.
    func apiKeyState() -> HomeSetupChecklist.APIKeyState {
        switch credentials.apiKey() {
        case .success(let key):
            let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .missing : .saved
        case .failure(let failure):
            return .unreadable(failure)
        }
    }
}
