import SwiftUI

/// The macOS ModelDropdownView rules: a list of known models plus
/// "Custom...", where an empty stored value means the default model.
struct ModelChoice: Equatable {
    static let customTag = "Custom..."

    let predefinedModels: [String]
    let defaultModel: String

    static let transcription = ModelChoice(
        predefinedModels: ModelConfiguration.transcriptionModels,
        defaultModel: FreeFlowSettingDefaults.transcriptionModel
    )
    static let postProcessing = ModelChoice(
        predefinedModels: ModelConfiguration.llmModels,
        defaultModel: FreeFlowSettingDefaults.postProcessingModel
    )
    static let postProcessingFallback = ModelChoice(
        predefinedModels: ModelConfiguration.llmModels,
        defaultModel: FreeFlowSettingDefaults.postProcessingFallbackModel
    )

    func effectiveModel(_ stored: String) -> String {
        stored.isEmpty ? defaultModel : stored
    }

    func isPredefined(_ model: String) -> Bool {
        predefinedModels.contains(model)
    }

    /// The picker shows the model itself when it is a known one.
    func pickerSelection(stored: String, prefersCustom: Bool) -> String {
        let model = effectiveModel(stored)
        return !prefersCustom && isPredefined(model) ? model : Self.customTag
    }
}

/// One model setting as a Form section: picker, custom ID field, and
/// Reset to Default.
struct ModelChoiceSection: View {
    let title: String
    let subtitle: String
    let choice: ModelChoice
    let storedModel: String
    var warning: String?
    let onCommit: @MainActor (String) -> Void

    @State private var selection = ""
    @State private var customDraft = ""
    @FocusState private var isEditingCustom: Bool

    var body: some View {
        Section {
            Picker(title, selection: $selection) {
                ForEach(choice.predefinedModels, id: \.self) { model in
                    Text(model).tag(model)
                }
                Text("Custom...").tag(ModelChoice.customTag)
            }
            .pickerStyle(.menu)

            if selection == ModelChoice.customTag {
                TextField(choice.defaultModel, text: $customDraft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isEditingCustom)
                    .onSubmit {
                        commitCustomDraft()
                    }
            }

            if choice.effectiveModel(storedModel) != choice.defaultModel {
                Button("Reset to Default") {
                    onCommit(choice.defaultModel)
                    syncFromStore(choice.defaultModel)
                }
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(subtitle)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            syncFromStore(storedModel)
        }
        .onChange(of: storedModel) { _, newValue in
            if !isEditingCustom {
                syncFromStore(newValue)
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            pickerChanged(from: oldValue, to: newValue)
        }
        .onChange(of: isEditingCustom) { _, isEditing in
            if !isEditing {
                commitCustomDraft()
            }
        }
    }

    private func syncFromStore(_ stored: String) {
        let model = choice.effectiveModel(stored)
        let isCustom = !choice.isPredefined(model)
        customDraft = isCustom ? model : ""
        selection = choice.pickerSelection(stored: stored, prefersCustom: false)
    }

    private func pickerChanged(from oldValue: String, to newValue: String) {
        guard oldValue != newValue, !oldValue.isEmpty else { return }
        if newValue == ModelChoice.customTag {
            let current = choice.effectiveModel(storedModel)
            customDraft = choice.isPredefined(current) ? "" : current
        } else if newValue != choice.effectiveModel(storedModel) {
            onCommit(newValue)
        }
    }

    private func commitCustomDraft() {
        guard selection == ModelChoice.customTag else { return }
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != choice.effectiveModel(storedModel) else { return }
        onCommit(trimmed)
    }
}

/// The same setting as a plain stack, for the onboarding page's advanced
/// provider settings.
struct ModelChoiceField: View {
    let title: String
    let subtitle: String
    let choice: ModelChoice
    let storedModel: String
    let onCommit: @MainActor (String) -> Void

    @State private var selection = ""
    @State private var customDraft = ""
    @FocusState private var isEditingCustom: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker(title, selection: $selection) {
                    ForEach(choice.predefinedModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Text("Custom...").tag(ModelChoice.customTag)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            if selection == ModelChoice.customTag {
                TextField(choice.defaultModel, text: $customDraft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($isEditingCustom)
                    .onSubmit {
                        commitCustomDraft()
                    }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            let model = choice.effectiveModel(storedModel)
            customDraft = choice.isPredefined(model) ? "" : model
            selection = choice.pickerSelection(stored: storedModel, prefersCustom: false)
        }
        .onChange(of: selection) { oldValue, newValue in
            guard oldValue != newValue, !oldValue.isEmpty, newValue != ModelChoice.customTag else { return }
            if newValue != choice.effectiveModel(storedModel) {
                onCommit(newValue)
            }
        }
        .onChange(of: isEditingCustom) { _, isEditing in
            if !isEditing {
                commitCustomDraft()
            }
        }
    }

    private func commitCustomDraft() {
        guard selection == ModelChoice.customTag else { return }
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != choice.effectiveModel(storedModel) else { return }
        onCommit(trimmed)
    }
}
