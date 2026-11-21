import SwiftUI
import UIKit

/// Settings, using the macOS card titles in order. Every write goes through
/// `SettingsStore` into the App Group, where the keyboard reads it.
struct SettingsScreen: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @StateObject private var model: SettingsScreenModel
    @StateObject private var apiForm: APIKeyFormModel
    @State private var microphonePermission: AppMicrophonePermission = .undetermined
    @State private var keyboardStatus: KeyboardStatus?
    @State private var isConfirmingClearHistory = false
    @State private var isConfirmingWithdrawal = false
    @State private var isConfirmingRerun = false

    init(environment: FreeFlowAppEnvironment) {
        _model = StateObject(wrappedValue: SettingsScreenModel(environment: environment))
        _apiForm = StateObject(wrappedValue: APIKeyFormModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            Form {
                APIKeySettingsSection(form: apiForm)
                modelSections
                languageSection
                cleanupSections
                macrosAndInsertionSections
                historySection
                permissionsSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            reload()
        }
        .onChange(of: app.refreshGeneration) { _, _ in
            reload()
        }
        .onChange(of: app.selectedTab) { _, tab in
            if tab == .settings {
                reload()
            }
        }
        .onChange(of: app.presentationResetGeneration) { _, _ in
            isConfirmingClearHistory = false
            isConfirmingWithdrawal = false
            isConfirmingRerun = false
        }
        .confirmationDialog("Clear all history?", isPresented: $isConfirmingClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                app.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved transcript on this iPhone.")
        }
        .alert("Withdraw consent?", isPresented: $isConfirmingWithdrawal) {
            Button("Withdraw", role: .destructive) {
                app.withdrawConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FreeFlow deletes your API keys from this iPhone and stops sending audio to your provider. You can set it up again at any time.")
        }
        .alert("Re-run setup?", isPresented: $isConfirmingRerun) {
            Button("Re-run Setup") {
                app.rerunSetup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your settings and API key stay as they are.")
        }
    }

    private func reload() {
        model.reload()
        apiForm.presentIfNeeded()
        microphonePermission = app.environment.microphone.permission
        keyboardStatus = app.environment.keyboardStatus.load()
    }

    // MARK: Models

    @ViewBuilder
    private var modelSections: some View {
        ModelChoiceSection(
            title: "Transcription Model",
            subtitle: "Used for speech-to-text transcription.",
            choice: .transcription,
            storedModel: model.transcriptionModel,
            onCommit: { model.setTranscriptionModel($0) }
        )
        ModelChoiceSection(
            title: "Post-Processing Model",
            subtitle: "Used for transcript cleanup.",
            choice: .postProcessing,
            storedModel: model.postProcessingModel,
            warning: dailyLimitWarning(for: model.effectivePostProcessingModel, prefix: "Daily limit reached"),
            onCommit: { model.setPostProcessingModel($0) }
        )
        ModelChoiceSection(
            title: "Post-Processing Fallback Model",
            subtitle: "Used as the explicit retry model for transcript cleanup.",
            choice: .postProcessingFallback,
            storedModel: model.postProcessingFallbackModel,
            warning: dailyLimitWarning(for: model.effectivePostProcessingFallbackModel, prefix: "Fallback daily limit reached"),
            onCommit: { model.setPostProcessingFallbackModel($0) }
        )
    }

    private func dailyLimitWarning(for modelID: String, prefix: String) -> String? {
        let now = Date()
        guard let reset = model.dailyLimitReset(for: modelID, now: now) else { return nil }
        let time = Calendar.current.isDate(reset, inSameDayAs: now)
            ? reset.formatted(date: .omitted, time: .shortened)
            : reset.formatted(date: .abbreviated, time: .shortened)
        return "\(prefix) — resets at \(time)"
    }

    // MARK: Languages

    private var languageSection: some View {
        Section {
            Picker("Transcription Language", selection: $model.transcriptionLanguage) {
                ForEach(LanguageOptions.transcriptionLanguages, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            .pickerStyle(.menu)
            Picker("Output Language", selection: $model.outputLanguage) {
                Text("Same as spoken").tag("")
                ForEach(LanguageOptions.outputLanguages.filter { !$0.isEmpty }, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Languages")
        } footer: {
            Text("Transcription Language is a hint to the transcription model. Auto-detect works for most users. Pick a specific language if you see wrong-script characters (for example Chinese) appear in your output. When Output Language is set, FreeFlow translates your speech into the selected language.")
        }
    }

    // MARK: Cleanup

    @ViewBuilder
    private var cleanupSections: some View {
        Section {
            Toggle("Preserve exact wording", isOn: $model.preserveExactWording)
                .accessibilityIdentifier("freeflow.settings.preserveExactWording")
        } header: {
            Text("Cleanup")
        } footer: {
            Text("When on, FreeFlow skips the LLM cleanup step and inserts the transcript verbatim — filler words, informal phrasing, and explicit language are all preserved. Voice macros still run. If Output Language is set, the transcript is still translated into that language, but the translation is literal: no rewording, no filler removal, no reformatting.")
        }

        Section {
            Toggle("Prevent dictated prompts from being executed", isOn: $model.instructionExecutionGuardEnabled)
        } footer: {
            Text("When enabled, FreeFlow retries or falls back to the literal transcript if post-processing looks like it answered the dictated text instead of cleaning it.")
        }

        Section {
            NavigationLink {
                SystemPromptScreen(model: model)
            } label: {
                LabeledContent("System Prompt", value: model.isUsingCustomSystemPrompt ? "Custom" : "Default")
            }
            NavigationLink {
                CustomVocabularyScreen(model: model)
            } label: {
                LabeledContent("Custom Vocabulary", value: vocabularySummary)
            }
        } footer: {
            Text("The system prompt controls how raw transcriptions are cleaned up. Custom vocabulary lists words and phrases to preserve during post-processing.")
        }
    }

    private var vocabularySummary: String {
        let count = CustomVocabularyScreen.entries(in: model.customVocabulary).count
        return count == 0 ? "None" : "\(count)"
    }

    // MARK: Macros and insertion

    @ViewBuilder
    private var macrosAndInsertionSections: some View {
        Section {
            NavigationLink {
                VoiceMacrosScreen(model: model)
            } label: {
                LabeledContent("Voice Macros", value: model.voiceMacros.isEmpty ? "None" : "\(model.voiceMacros.count)")
            }
        } footer: {
            Text("Bypass post-processing and immediately insert your predefined text.")
        }

        Section {
            Toggle("Say \"press enter\" to submit after inserting", isOn: $model.pressEnterVoiceCommandEnabled)
        } header: {
            Text("Text Insertion")
        } footer: {
            Text("When the transcription ends with \"press enter\", FreeFlow removes those words before cleanup, inserts the remaining transcript, then presses Return.")
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            Toggle("Keep History", isOn: $model.historyEnabled)
                .accessibilityIdentifier("freeflow.settings.keepHistory")
            Button("Clear History", role: .destructive) {
                isConfirmingClearHistory = true
            }
        } header: {
            Text("History")
        } footer: {
            Text("Stored locally. Only the \(HistoryLog.maxEntries) most recent runs are kept, as text only. Turning Keep History off deletes them. The keyboard's Insert Last key uses the newest one.")
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        let checklist = HomeSetupChecklist.make(
            apiKey: .saved,
            microphone: microphonePermission,
            keyboardStatus: keyboardStatus
        )
        return Section {
            ForEach(checklist.items.filter { $0.kind != .apiKey }) { item in
                LabeledContent {
                    if item.state == .done {
                        Label(item.detail, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(item.state == .unknown ? "Not reported yet" : "Needed")
                            .foregroundStyle(.orange)
                    }
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            Button("Open Settings") {
                FreeFlowStyle.openSystemSettings()
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("The keyboard reports Keyboard and Full Access after it opens with Full Access on. To add it, open Settings, tap Keyboards and turn on FreeFlow, then turn on Allow Full Access.")
        }
    }

    // MARK: Data and privacy

    private var privacySection: some View {
        Section {
            Text("When you dictate, FreeFlow sends your audio to your configured provider for transcription, then sends the transcript to your provider's model for cleanup. Nothing is stored on FreeFlow's servers (FreeFlow doesn't have servers).")
                .font(.callout)
            Button("Withdraw Consent", role: .destructive) {
                isConfirmingWithdrawal = true
            }
            .accessibilityIdentifier("freeflow.settings.withdrawConsent")
        } header: {
            Text("Data & Privacy")
        } footer: {
            Text("Withdrawing deletes your API keys from this iPhone, so nothing more is sent, and starts setup again.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: FreeFlowAppInfo.version)
            LabeledContent("Build", value: FreeFlowAppInfo.build)
            FreeFlowCopyButton(text: FreeFlowAppInfo.diagnostics, title: "Copy Diagnostics")
            Link(destination: FreeFlowAppInfo.repositoryURL) {
                Label("zachlatta/freeflow", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button("Re-run Setup...") {
                isConfirmingRerun = true
            }
            .accessibilityIdentifier("freeflow.settings.rerunSetup")
        } header: {
            Text("About")
        } footer: {
            Text("FreeFlow is free and open source. Nothing is stored on FreeFlow's servers (FreeFlow doesn't have servers).")
        }
    }
}

/// Version strings for About.
enum FreeFlowAppInfo {
    static let repositoryURL = URL(string: "https://github.com/zachlatta/freeflow")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Like the macOS Build card: app version and OS, no user data.
    @MainActor
    static var diagnostics: String {
        "FreeFlow \(version) (\(build))\niOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))"
    }
}

/// The System Prompt card from the macOS Prompts tab.
struct SystemPromptScreen: View {
    @ObservedObject var model: SettingsScreenModel
    @State private var draft = ""
    @State private var showsDefaultPrompt = false
    @FocusState private var isEditing: Bool

    var body: some View {
        Form {
            if model.hasNewerDefaultSystemPrompt {
                Section {
                    Label("A newer default prompt is available.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Button(showsDefaultPrompt ? "Hide Default" : "View Default") {
                        showsDefaultPrompt.toggle()
                    }
                    Button("Switch to Default") {
                        model.resetSystemPrompt()
                        draft = model.systemPromptEditorText
                    }
                }
            }

            if showsDefaultPrompt {
                Section {
                    Text(PostProcessingService.defaultSystemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Default System Prompt")
                }
            }

            Section {
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 260)
                    .focused($isEditing)
                    .autocorrectionDisabled()
            } header: {
                Text("Prompt")
            } footer: {
                Text("Controls how raw transcriptions are cleaned up.")
            }

            Section {
                if model.isUsingCustomSystemPrompt {
                    Label("Using custom prompt", systemImage: "pencil")
                        .foregroundStyle(FreeFlowStyle.accent)
                    Button("Reset to Default") {
                        model.resetSystemPrompt()
                        draft = model.systemPromptEditorText
                    }
                } else {
                    Label("Using default", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") {
                        isEditing = false
                    }
                }
            }
        }
        .onAppear {
            draft = model.systemPromptEditorText
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                model.commitSystemPrompt(draft)
            }
        }
        .onDisappear {
            model.commitSystemPrompt(draft)
        }
    }
}

/// The Custom Vocabulary card.
struct CustomVocabularyScreen: View {
    @ObservedObject var model: SettingsScreenModel
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    /// Entries split the way the macOS vocabulary is: commas, new lines, or
    /// semicolons.
    static func entries(in vocabulary: String) -> [String] {
        vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .focused($isEditing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("freeflow.settings.vocabularyField")
            } header: {
                Text("Words and phrases to preserve during post-processing.")
            } footer: {
                Text("Separate entries with commas, new lines, or semicolons.")
            }
        }
        .navigationTitle("Custom Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") {
                        isEditing = false
                    }
                }
            }
        }
        .onAppear {
            draft = model.customVocabulary
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                model.setCustomVocabulary(draft)
            }
        }
        .onDisappear {
            model.setCustomVocabulary(draft)
        }
    }
}

/// The macOS Voice Macros tab.
struct VoiceMacrosScreen: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @ObservedObject var model: SettingsScreenModel
    @State private var editing: VoiceMacroDraft?

    var body: some View {
        List {
            Section {
                ForEach(model.voiceMacros) { macro in
                    Button {
                        editing = VoiceMacroDraft(macro: macro)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(macro.command)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(macro.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    model.deleteVoiceMacros(at: offsets)
                }
            } footer: {
                Text("Bypass post-processing and immediately insert your predefined text.")
            }
        }
        .overlay {
            if model.voiceMacros.isEmpty {
                ContentUnavailableView(
                    "No Voice Macros Yet",
                    systemImage: "music.mic",
                    description: Text("Tap 'Add Macro' to define your first voice macro.")
                )
            }
        }
        .navigationTitle("Voice Macros")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Macro") {
                    editing = VoiceMacroDraft(macro: nil)
                }
                .accessibilityIdentifier("freeflow.settings.addMacro")
            }
        }
        .onChange(of: app.presentationResetGeneration) { _, _ in
            editing = nil
        }
        .sheet(item: $editing) { draft in
            VoiceMacroEditorSheet(draft: draft) { macro in
                model.saveVoiceMacro(macro)
            } onDelete: { id in
                model.deleteVoiceMacro(id: id)
            }
        }
    }
}

/// What the macro editor sheet starts with.
struct VoiceMacroDraft: Identifiable {
    let id = UUID()
    let macro: VoiceMacro?
}

struct VoiceMacroEditorSheet: View {
    let draft: VoiceMacroDraft
    let onSave: @MainActor (VoiceMacro) -> Void
    let onDelete: @MainActor (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var payload = ""

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !payload.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. debugging prompt", text: $command)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("freeflow.settings.macroCommand")
                } header: {
                    Text("Voice Command (What you say)")
                }
                Section {
                    TextEditor(text: $payload)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("freeflow.settings.macroText")
                } header: {
                    Text("Text (What gets inserted)")
                }
                if let existing = draft.macro {
                    Section {
                        Button("Delete Macro", role: .destructive) {
                            onDelete(existing.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(draft.macro == nil ? "Add Macro" : "Edit Macro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(VoiceMacro(
                            id: draft.macro?.id ?? UUID(),
                            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                            payload: payload
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("freeflow.settings.saveMacro")
                }
            }
            .onAppear {
                command = draft.macro?.command ?? ""
                payload = draft.macro?.payload ?? ""
            }
        }
    }
}
