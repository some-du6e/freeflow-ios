import SwiftUI

// Page wording follows the macOS SetupView, with "Mac" changed to "iPhone",
// "Click" to "Tap", and "pasted" to "inserted".

struct OnboardingWelcomePage: View {
    var body: some View {
        VStack(spacing: 18) {
            Image("WelcomeIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to FreeFlow")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Dictate text anywhere on your iPhone.\nHold to talk or tap to toggle dictation.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            FreeFlowCard {
                VStack(alignment: .leading, spacing: 12) {
                    FreeFlowTipRow(systemImage: "keyboard", text: "Use the FreeFlow keyboard in any app")
                    FreeFlowTipRow(systemImage: "waveform", text: "Your words are transcribed and cleaned up by your own AI provider")
                    FreeFlowTipRow(systemImage: "lock.shield", text: "Free and open source, with no FreeFlow servers")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// App Review 5.1.2(i): say where the data goes and get explicit consent.
struct OnboardingConsentPage: View {
    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "lock.shield.fill",
                title: "What leaves your iPhone",
                caption: "When you dictate, FreeFlow sends your audio to your configured provider for transcription, then sends the transcript to your provider's model for cleanup."
            )
            FreeFlowCard {
                VStack(alignment: .leading, spacing: 12) {
                    FreeFlowTipRow(
                        systemImage: "server.rack",
                        text: "Your provider is Groq unless you choose another OpenAI-compatible provider. Its privacy policy covers what it receives."
                    )
                    FreeFlowTipRow(
                        systemImage: "iphone",
                        text: "Recordings are kept only while they're being transcribed. Transcripts stay on this iPhone, in a text-only history of your 20 most recent dictations that you can turn off or clear."
                    )
                    FreeFlowTipRow(
                        systemImage: "text.cursor",
                        text: "The keyboard never sends what you type, only what you dictate."
                    )
                    FreeFlowTipRow(
                        systemImage: "xmark.icloud",
                        text: "Nothing is stored on FreeFlow's servers (FreeFlow doesn't have servers)."
                    )
                }
            }
            Text("You can withdraw consent at any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct OnboardingAPIKeyPage: View {
    @ObservedObject var form: APIKeyFormModel
    @ObservedObject var settingsModel: SettingsScreenModel
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "key.fill",
                title: "API Key",
                caption: "Enter an API key for your OpenAI-compatible provider. If you are not using Groq, expand the advanced provider settings and enter that provider's base URL and model IDs before continuing."
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Using Groq?")
                    .font(.subheadline.weight(.semibold))
                FreeFlowInstructionRow(number: 1, text: "Go to [console.groq.com/keys](https://console.groq.com/keys)")
                FreeFlowInstructionRow(number: 2, text: "Create a free account (if you don't have one)")
                FreeFlowInstructionRow(number: 3, text: "Tap **Create API Key** and copy it")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FreeFlowStyle.accent.opacity(0.08))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.headline)
                SecureField("Paste your API key", text: $form.draft.apiKey)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .disabled(form.isValidating)
                    .accessibilityIdentifier("freeflow.onboarding.apiKeyField")
                APIKeyStatusLabel(form: form)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DisclosureGroup(isExpanded: $showsAdvanced) {
                OnboardingProviderFields(form: form, settings: settingsModel)
                    .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced Provider Settings")
                        .foregroundStyle(.primary)
                    Text("Base URL and model IDs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("freeflow.onboarding.advanced")
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FreeFlowStyle.cardBackground)
            )
        }
        .onAppear {
            form.presentIfNeeded()
            settingsModel.reload()
        }
    }
}

/// A hard gate: the keyboard records through the app's permission.
struct OnboardingMicrophonePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "mic.fill",
                title: "Microphone Access",
                caption: "FreeFlow needs access to your microphone to record audio for transcription. The FreeFlow keyboard uses this permission when you tap the mic."
            )
            OnboardingStatusRow(
                systemImage: "mic.fill",
                title: "Microphone",
                isDone: model.microphonePermission == .granted,
                pendingText: model.microphonePermission == .denied ? "Off" : "Not granted yet"
            )
            if model.microphonePermission == .denied {
                VStack(spacing: 12) {
                    Text("Microphone access is off. Turn on Microphone for FreeFlow in Settings to continue.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        FreeFlowStyle.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("freeflow.onboarding.openSettings")
                }
            } else if model.microphonePermission == .undetermined {
                Text("Tap Continue, then allow microphone access when iOS asks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// A soft gate: the app learns the keyboard is set up once it reports in.
struct OnboardingKeyboardPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "keyboard.fill",
                title: "Add the FreeFlow Keyboard",
                caption: "FreeFlow dictates through its own keyboard, which works in any app."
            )
            VStack(alignment: .leading, spacing: 6) {
                FreeFlowInstructionRow(number: 1, text: "Tap **Open Settings** below")
                FreeFlowInstructionRow(number: 2, text: "Tap **Keyboards** and turn on **FreeFlow**")
                FreeFlowInstructionRow(number: 3, text: "Turn on **Allow Full Access**")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FreeFlowStyle.accent.opacity(0.08))
            )

            Button {
                FreeFlowStyle.openSystemSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.onboarding.openSettings")

            Text("You can also go to Settings > General > Keyboard > Keyboards > Add New Keyboard and choose FreeFlow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            FreeFlowCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Why Full Access?")
                        .font(.subheadline.weight(.semibold))
                    Text("Full Access lets the keyboard reach your provider and read your API key from the FreeFlow app. iOS shows a general warning when you turn it on. The keyboard only sends the audio you dictate to your provider, never what you type, and FreeFlow has no servers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                OnboardingStatusRow(
                    systemImage: "keyboard",
                    title: "Keyboard",
                    isDone: model.keyboardStatus != nil,
                    pendingText: "We'll check in the next step.",
                    doneText: "Added"
                )
                OnboardingStatusRow(
                    systemImage: "lock.open",
                    title: "Full Access",
                    isDone: model.keyboardStatus?.hasFullAccess == true,
                    pendingText: "We'll check in the next step.",
                    doneText: "On"
                )
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshKeyboardStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct OnboardingTryItPage: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "text.cursor",
                title: "Let's Try It Out!",
                caption: "Tap the field, switch to FreeFlow with 🌐, then tap the mic. Say anything — a sentence or two is perfect."
            )
            FreeFlowTestField(text: $app.testFieldText, minHeight: 120)
            keyboardFeedback
            Button {
                app.startDictation(mode: .inApp)
            } label: {
                Label("Try Without the Keyboard", systemImage: "mic.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("freeflow.app.dictateInApp")
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var keyboardFeedback: some View {
        if let status = model.keyboardStatus {
            if !status.hasFullAccess {
                feedbackRow("Turn on Allow Full Access for FreeFlow in Settings > Keyboards so it can dictate.", systemImage: "exclamationmark.triangle.fill", color: .orange)
            } else if model.apiKeyState != .saved {
                feedbackRow("Add your API key so the keyboard can transcribe.", systemImage: "exclamationmark.triangle.fill", color: .orange)
            } else if status.inKeyboardCaptureWorked == false {
                feedbackRow("The keyboard couldn't record here, so it will open FreeFlow to record instead.", systemImage: "info.circle.fill", color: .secondary)
            } else {
                feedbackRow("The FreeFlow keyboard is ready.", systemImage: "checkmark.circle.fill", color: .green)
            }
        } else {
            feedbackRow("Waiting for the FreeFlow keyboard. It shows up here after you switch to it with Full Access on.", systemImage: "keyboard", color: .secondary)
        }
    }

    private func feedbackRow(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct OnboardingDonePage: View {
    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                systemImage: "checkmark.circle.fill",
                title: "You're All Set!",
                caption: "FreeFlow lives in your keyboard.",
                symbolColor: .green
            )
            FreeFlowCard {
                VStack(alignment: .leading, spacing: 14) {
                    FreeFlowTipRow(systemImage: "hand.tap", text: "Tap the mic to start and stop")
                    FreeFlowTipRow(systemImage: "hand.point.down", text: "Hold the mic to record, and let go to stop")
                    FreeFlowTipRow(systemImage: "globe", text: "Switch keyboards with 🌐")
                    FreeFlowTipRow(systemImage: "text.cursor", text: "Text is typed at your cursor")
                }
            }
        }
    }
}
