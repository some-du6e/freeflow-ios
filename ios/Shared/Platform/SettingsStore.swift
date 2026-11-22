import Foundation

/// Shared settings: non-secret values in the App Group's UserDefaults under
/// `FreeFlowSettingKey` names, API keys in `SharedKeychain`.
final class SettingsStore {
    static let shared = SettingsStore(
        defaults: UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier) ?? .standard,
        keychain: .shared
    )

    let defaults: UserDefaults
    let keychain: SharedKeychain

    init(defaults: UserDefaults, keychain: SharedKeychain) {
        self.defaults = defaults
        self.keychain = keychain
    }

    // MARK: Generic access by FreeFlowSettingKey

    func string(_ key: String, default fallback: String = "") -> String {
        defaults.string(forKey: key) ?? fallback
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    func set(_ value: String, for key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Bool, for key: String) {
        defaults.set(value, forKey: key)
    }

    func removeValue(for key: String) {
        defaults.removeObject(forKey: key)
    }

    var voiceMacros: [VoiceMacro] {
        get { VoiceMacroCodec.decode(defaults.data(forKey: FreeFlowSettingKey.voiceMacros)) }
        set { defaults.set(VoiceMacroCodec.encode(newValue), forKey: FreeFlowSettingKey.voiceMacros) }
    }

    var hasCompletedSetup: Bool {
        get { bool(FreeFlowSettingKey.hasCompletedSetup, default: false) }
        set { set(newValue, for: FreeFlowSettingKey.hasCompletedSetup) }
    }

    var historyEnabled: Bool {
        get { bool(FreeFlowSettingKey.historyEnabled, default: FreeFlowSettingDefaults.historyEnabled) }
        set { set(newValue, for: FreeFlowSettingKey.historyEnabled) }
    }

    /// Written by the app after it obtains microphone permission.
    var microphonePermissionGranted: Bool {
        get { bool(FreeFlowSettingKey.microphonePermissionGranted, default: false) }
        set { set(newValue, for: FreeFlowSettingKey.microphonePermissionGranted) }
    }

    // MARK: Secrets

    func apiKey() -> Result<String?, SharedKeychain.Failure> {
        keychain.read(.apiKey)
    }

    func setAPIKey(_ value: String?) throws {
        try keychain.write(value, for: .apiKey)
    }

    func transcriptionAPIKey() -> Result<String?, SharedKeychain.Failure> {
        keychain.read(.transcriptionAPIKey)
    }

    func setTranscriptionAPIKey(_ value: String?) throws {
        try keychain.write(value, for: .transcriptionAPIKey)
    }

    /// nil when there is no readable API key.
    func dictationConfiguration() -> DictationConfiguration? {
        let key: String? = try? apiKey().get()
        let transcriptionKey: String? = try? transcriptionAPIKey().get()
        return DictationConfiguration.resolve(defaults: defaults, apiKey: key, transcriptionAPIKey: transcriptionKey)
    }
}
