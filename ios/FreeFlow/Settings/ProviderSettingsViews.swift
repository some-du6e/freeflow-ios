import SwiftUI

/// The API key row group in Settings, with the macOS wording.
struct APIKeySettingsSection: View {
    @ObservedObject var form: APIKeyFormModel

    var body: some View {
        Section {
            SecureField("Enter your Groq API key", text: $form.draft.apiKey)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(form.isValidating)
                .accessibilityIdentifier("freeflow.settings.apiKeyField")

            Button {
                Task { await form.save() }
            } label: {
                HStack {
                    Text(form.isValidating ? "Validating..." : "Save")
                    if form.isValidating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!form.canSubmit)
            .accessibilityIdentifier("freeflow.settings.saveAPIKey")

            NavigationLink {
                ProviderAdvancedScreen(form: form)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Provider Settings")
                    Text("Base URL and transcription endpoint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("FreeFlow uses the configured transcription model with your selected OpenAI-compatible provider.")
                APIKeyStatusLabel(form: form)
            }
        }
    }
}

/// "Validating...", "API key saved" or the validation error.
struct APIKeyStatusLabel: View {
    @ObservedObject var form: APIKeyFormModel

    var body: some View {
        if let message = form.failureMessage {
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityIdentifier("freeflow.apiKey.error")
        } else if form.showsSavedSuccess {
            Label("API key saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("freeflow.apiKey.saved")
        } else if let failure = form.keychainFailure {
            Label(Self.keychainMessage(failure), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func keychainMessage(_ failure: SharedKeychain.Failure) -> String {
        switch failure {
        case .missingEntitlement:
            "This build can't use the shared keychain, so the keyboard can't read your key."
        case .unavailable:
            "The keychain is locked. Unlock your iPhone and try again."
        case .unexpected:
            "The keychain couldn't be read."
        }
    }
}

/// Base URL, transcription URL and transcription key. They are saved with
/// the API key, after validation, like the macOS settings.
struct ProviderAdvancedScreen: View {
    @ObservedObject var form: APIKeyFormModel

    var body: some View {
        Form {
            Section {
                TextField(APIConfigurationSaveFlow.defaultBaseURL, text: $form.draft.baseURL)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(form.isValidating)
                    .accessibilityIdentifier("freeflow.settings.baseURLField")
                if form.draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != APIConfigurationSaveFlow.defaultBaseURL {
                    Button("Reset to Default") {
                        form.resetBaseURLToDefault()
                    }
                }
            } header: {
                Text("API Base URL")
            } footer: {
                Text("Change this to use a different OpenAI-compatible API provider. If you use another provider, set that provider's model IDs in Models.")
            }

            Section {
                TextField("Uses API Base URL when empty", text: $form.draft.transcriptionAPIURL)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(form.isValidating)
                if !form.draft.transcriptionAPIURL.isEmpty {
                    Button("Clear") {
                        form.draft.transcriptionAPIURL = ""
                    }
                }
            } header: {
                Text("Transcription API URL")
            }

            Section {
                SecureField("Uses API Key when empty", text: $form.draft.transcriptionAPIKey)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(form.isValidating)
                if !form.draft.transcriptionAPIKey.isEmpty {
                    Button("Clear") {
                        form.draft.transcriptionAPIKey = ""
                    }
                }
            } header: {
                Text("Transcription API Key")
            }

            Section {
                Button {
                    Task { await form.save() }
                } label: {
                    HStack {
                        Text(form.isValidating ? "Validating..." : "Save")
                        if form.isValidating {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!form.canSubmit)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saving checks the API key against the base URL, and the transcription key against the transcription URL when they differ.")
                    APIKeyStatusLabel(form: form)
                }
            }
        }
        .navigationTitle("Advanced Provider Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The advanced fields as a plain stack, for the onboarding API key page.
struct OnboardingProviderFields: View {
    @ObservedObject var form: APIKeyFormModel
    @ObservedObject var settings: SettingsScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use these fields when pointing FreeFlow at another OpenAI-compatible provider or when you need custom model IDs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Base URL")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if form.draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != APIConfigurationSaveFlow.defaultBaseURL {
                        Button("Reset to Default") {
                            form.resetBaseURLToDefault()
                        }
                        .font(.caption)
                    }
                }
                TextField(APIConfigurationSaveFlow.defaultBaseURL, text: $form.draft.baseURL)
                    .font(.system(.callout, design: .monospaced))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.isValidating)
                    .accessibilityIdentifier("freeflow.onboarding.baseURLField")
                Text("Change this to use a different OpenAI-compatible API provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("If you use another provider, enter that provider's model IDs here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ModelChoiceField(
                title: "Transcription Model",
                subtitle: "Used for speech-to-text transcription.",
                choice: .transcription,
                storedModel: settings.transcriptionModel,
                onCommit: { settings.setTranscriptionModel($0) }
            )
            ModelChoiceField(
                title: "Post-Processing Model",
                subtitle: "Used for transcript cleanup.",
                choice: .postProcessing,
                storedModel: settings.postProcessingModel,
                onCommit: { settings.setPostProcessingModel($0) }
            )
            ModelChoiceField(
                title: "Post-Processing Fallback Model",
                subtitle: "Used as the explicit retry model for transcript cleanup.",
                choice: .postProcessingFallback,
                storedModel: settings.postProcessingFallbackModel,
                onCommit: { settings.setPostProcessingFallbackModel($0) }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API URL")
                    .font(.subheadline.weight(.semibold))
                TextField("Uses API Base URL when empty", text: $form.draft.transcriptionAPIURL)
                    .font(.system(.callout, design: .monospaced))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.isValidating)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcription API Key")
                    .font(.subheadline.weight(.semibold))
                SecureField("Uses API Key when empty", text: $form.draft.transcriptionAPIKey)
                    .font(.system(.callout, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(form.isValidating)
            }
        }
    }
}
