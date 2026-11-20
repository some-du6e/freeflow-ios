import SwiftUI
import UIKit

/// The setup flow, shown until `hasCompletedSetup`. One page at a time, so
/// each accessibility identifier is on screen once.
struct OnboardingView: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @StateObject private var model: OnboardingModel
    @StateObject private var settingsModel: SettingsScreenModel

    init(app: FreeFlowAppModel) {
        _model = StateObject(wrappedValue: OnboardingModel(environment: app.environment) { [weak app] in
            app?.completeOnboarding()
        })
        _settingsModel = StateObject(wrappedValue: SettingsScreenModel(settings: app.environment.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepDots(step: model.step)
                .padding(.top, 12)
            ScrollView {
                page
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .id(model.step)
            OnboardingBottomBar(model: model, apiForm: model.apiForm)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: model.step)
        .onAppear {
            model.refresh()
        }
        .onChange(of: app.refreshGeneration) { _, _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomePage()
        case .consent:
            OnboardingConsentPage()
        case .apiKey:
            OnboardingAPIKeyPage(form: model.apiForm, settingsModel: settingsModel)
        case .microphone:
            OnboardingMicrophonePage(model: model)
        case .keyboard:
            OnboardingKeyboardPage(model: model)
        case .tryIt:
            OnboardingTryItPage(model: model)
        case .done:
            OnboardingDonePage()
        }
    }
}

struct OnboardingStepDots: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate == step ? FreeFlowStyle.accent : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.index + 1) of \(OnboardingStep.allCases.count)")
    }
}

struct OnboardingBottomBar: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var apiForm: APIKeyFormModel

    var body: some View {
        let action = model.primaryAction
        HStack(spacing: 12) {
            if model.step.previous != nil {
                Button("Back") {
                    model.goBack()
                }
                .disabled(!model.canGoBack)
                .accessibilityIdentifier("freeflow.onboarding.back")
            }
            Spacer()
            Button {
                Task { await model.primaryTapped() }
            } label: {
                HStack(spacing: 8) {
                    if apiForm.isValidating || model.isRequestingMicrophone {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(action.title)
                        .font(.headline)
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!action.isEnabled)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// The page header shared by every step: symbol, title, caption.
struct OnboardingHeader: View {
    let systemImage: String
    let title: String
    let caption: String
    var symbolColor: Color = .accentColor

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A status row like the macOS permission rows: "Microphone ✓ Granted".
struct OnboardingStatusRow: View {
    let systemImage: String
    let title: String
    let isDone: Bool
    let pendingText: String
    var doneText = "Granted"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(FreeFlowStyle.accent)
                .frame(width: 24)
            Text(title)
            Spacer()
            if isDone {
                Label(doneText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(pendingText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FreeFlowStyle.cardBackground)
        )
        .accessibilityElement(children: .combine)
    }
}
