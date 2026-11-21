import Foundation

/// The API key form on the onboarding page and in Settings. It validates
/// with the macOS save flow (`APIConfigurationSaveFlow.validateAndApply`,
/// GET {base}/models) and tracks edits with `APIConfigurationDraft`, then
/// stores keys in the shared keychain and URLs in the App Group.
@MainActor
final class APIKeyFormModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case validating
        case saved
        case failed(String)
    }

    static let validationFailedMessage = "Validation failed. Please check your API key and provider settings, then try again."
    static let keychainFailedMessage = "Couldn't save the API key in this iPhone's keychain. Try again."

    /// The form's text fields bind to this.
    @Published var draft = APIConfigurationDraft()
    @Published private(set) var status: Status = .idle
    /// The configuration currently stored.
    @Published private(set) var committed: ValidatedAPIConfiguration
    /// Set when the stored keys couldn't be read at all.
    @Published private(set) var keychainFailure: SharedKeychain.Failure?

    private var successful: ValidatedAPIConfiguration?
    private var isPresented = false
    private let settings: SettingsStore
    private let credentials: AppCredentialStore
    private let validator: @Sendable (String, String) async -> Bool

    init(
        settings: SettingsStore,
        credentials: AppCredentialStore,
        validator: @escaping @Sendable (String, String) async -> Bool
    ) {
        self.settings = settings
        self.credentials = credentials
        self.validator = validator
        let saved = Self.loadSaved(settings: settings, credentials: credentials)
        self.committed = saved.configuration
        self.keychainFailure = saved.failure
    }

    convenience init(environment: FreeFlowAppEnvironment) {
        self.init(
            settings: environment.settings,
            credentials: environment.credentials,
            validator: environment.validateAPIKey
        )
    }

    var isValidating: Bool {
        status == .validating
    }

    var canSubmit: Bool {
        !isValidating && !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSavedKey: Bool {
        !committed.apiKey.isEmpty
    }

    /// A stored key that the form still shows unchanged needs no new check.
    var isUnchangedAndSaved: Bool {
        hasSavedKey && draft.configuration == committed
    }

    /// "API key saved", shown only while the fields still match what was saved.
    var showsSavedSuccess: Bool {
        status == .saved && draft.showsSavedSuccess(successful, committed: committed)
    }

    var failureMessage: String? {
        if case .failed(let message) = status {
            return message
        }
        return nil
    }

    /// Fills the fields from the stored configuration the first time the
    /// form shows, and afterwards only updates fields the user hasn't edited.
    func presentIfNeeded() {
        reloadCommitted()
        if isPresented {
            draft.reconcile(committed)
        } else {
            isPresented = true
            draft.present(committed)
        }
    }

    /// Re-reads the stored configuration, for example after the app returns
    /// from the background.
    func reloadCommitted() {
        let saved = Self.loadSaved(settings: settings, credentials: credentials)
        if saved.configuration != committed {
            committed = saved.configuration
        }
        if saved.failure != keychainFailure {
            keychainFailure = saved.failure
        }
    }

    func resetBaseURLToDefault() {
        draft.baseURL = APIConfigurationSaveFlow.defaultBaseURL
    }

    /// Validates and stores the form. Returns true when the configuration was
    /// validated, stored, and still matches the form.
    @discardableResult
    func save() async -> Bool {
        guard !isValidating else { return false }
        if !isPresented {
            presentIfNeeded()
        }
        let submission = draft.submission
        successful = nil
        // The check against GET /models accepts a base URL with a query or
        // fragment, but the pipeline can't build a cleanup URL from one and
        // would quietly skip cleanup and translation. Refuse it here, before
        // the key is sent anywhere, and store nothing.
        guard Self.pipelineAcceptsBaseURL(submission.configuration.baseURL) else {
            status = .failed(Self.validationFailedMessage)
            return false
        }
        status = .validating

        var accepted: ValidatedAPIConfiguration?
        var storeFailed = false
        let valid = await APIConfigurationSaveFlow.validateAndApply(
            apiKey: submission.configuration.apiKey,
            baseURL: submission.configuration.baseURL,
            transcriptionAPIURL: submission.configuration.transcriptionAPIURL,
            transcriptionAPIKey: submission.configuration.transcriptionAPIKey,
            validator: validator
        ) { configuration in
            do {
                try store(configuration)
            } catch {
                storeFailed = true
                return
            }
            if draft.accept(configuration, for: submission) {
                accepted = configuration
            }
            committed = configuration
            keychainFailure = nil
        }

        if storeFailed {
            status = .failed(Self.keychainFailedMessage)
            return false
        }
        if valid, let accepted, draft.configuration == accepted, committed == accepted {
            successful = accepted
            status = .saved
            return true
        }
        if !valid && draft.matches(submission) {
            status = .failed(Self.validationFailedMessage)
        } else {
            status = .idle
        }
        return false
    }

    /// Resolves the base URL as `APIConfigurationSaveFlow.validateAndApply`
    /// does (trimmed, the default when blank), then applies the cleanup
    /// pipeline's rules: http or https, a host, no query and no fragment.
    private static func pipelineAcceptsBaseURL(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? APIConfigurationSaveFlow.defaultBaseURL : trimmed
        return DictationPipeline.validatedLLMBaseURL(resolved) != nil
    }

    /// Keys go to the shared keychain (a blank value deletes the item); a
    /// default base URL and an empty transcription URL are removed rather
    /// than stored, like macOS.
    private func store(_ configuration: ValidatedAPIConfiguration) throws {
        try credentials.setAPIKey(configuration.apiKey)
        try credentials.setTranscriptionAPIKey(
            configuration.transcriptionAPIKey.isEmpty ? nil : configuration.transcriptionAPIKey
        )
        if configuration.baseURL.isEmpty || configuration.baseURL == APIConfigurationSaveFlow.defaultBaseURL {
            settings.removeValue(for: FreeFlowSettingKey.apiBaseURL)
        } else {
            settings.set(configuration.baseURL, for: FreeFlowSettingKey.apiBaseURL)
        }
        if configuration.transcriptionAPIURL.isEmpty {
            settings.removeValue(for: FreeFlowSettingKey.transcriptionAPIURL)
        } else {
            settings.set(configuration.transcriptionAPIURL, for: FreeFlowSettingKey.transcriptionAPIURL)
        }
    }

    static func loadSaved(
        settings: SettingsStore,
        credentials: AppCredentialStore
    ) -> (configuration: ValidatedAPIConfiguration, failure: SharedKeychain.Failure?) {
        var failure: SharedKeychain.Failure?
        let apiKey: String
        switch credentials.apiKey() {
        case .success(let value):
            apiKey = value ?? ""
        case .failure(let error):
            apiKey = ""
            failure = error
        }
        let transcriptionAPIKey: String
        switch credentials.transcriptionAPIKey() {
        case .success(let value):
            transcriptionAPIKey = value ?? ""
        case .failure(let error):
            transcriptionAPIKey = ""
            failure = failure ?? error
        }
        let storedBaseURL = settings.string(FreeFlowSettingKey.apiBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = ValidatedAPIConfiguration(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: storedBaseURL.isEmpty ? APIConfigurationSaveFlow.defaultBaseURL : storedBaseURL,
            transcriptionAPIURL: settings.string(FreeFlowSettingKey.transcriptionAPIURL)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptionAPIKey: transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (configuration, failure)
    }
}
