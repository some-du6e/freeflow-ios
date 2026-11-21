import SwiftUI
import UIKit

/// The full-screen recorder: the keyboard's fallback and "try without the
/// keyboard". Accessibility identifiers follow DESIGN §5.1.
struct RecorderView: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 24) {
                    statusHeader
                    centerpiece
                    details
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear {
            model.startIfNeeded()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if model.isBusy || model.phase == .needsPermission {
                Button("Cancel") {
                    app.closeRecorder()
                }
                .accessibilityIdentifier("freeflow.recorder.cancel")
            } else {
                Button("Done") {
                    app.closeRecorder()
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("freeflow.recorder.done")
            }
            Spacer()
            Text(model.mode.sessionID == nil ? "Dictate without the keyboard" : "Dictating for the FreeFlow keyboard")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Status

    private var statusHeader: some View {
        VStack(spacing: 8) {
            Text(statusTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("freeflow.recorder.status")
                .accessibilityValue(model.phase.accessibilityName)
            if let subtitle = statusSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 8)
    }

    private var statusTitle: String {
        switch model.phase {
        case .idle: "Ready"
        case .needsPermission, .requestingPermission: "Microphone Access"
        case .permissionDenied: "Microphone access is off"
        case .setupNeeded: "API key required"
        case .consentNeeded: "Finish setting up FreeFlow"
        case .starting: "Starting..."
        case .recording: "Listening..."
        case .processing: "Transcribing..."
        case .finished(let outcome):
            if outcome.isNothingToInsert {
                "No speech detected"
            } else if outcome.handedOff {
                "Swipe back to return to your app"
            } else if outcome.keyboardStoppedWaiting {
                "Not sent to the keyboard"
            } else {
                "Perfect — FreeFlow is ready to go."
            }
        case .failed: "Something went wrong"
        }
    }

    private var statusSubtitle: String? {
        switch model.phase {
        case .idle:
            model.startsOnAppear ? nil : "FreeFlow starts recording when you tap Start Recording."
        case .needsPermission, .requestingPermission:
            "FreeFlow needs access to your microphone to record audio for transcription."
        case .permissionDenied:
            "Turn on Microphone for FreeFlow in Settings, then try again."
        case .setupNeeded:
            "Add your API key in FreeFlow's settings to dictate."
        case .consentNeeded:
            "FreeFlow records only after you agree, in setup, to send audio to your provider."
        case .starting, .recording:
            "Say anything — a sentence or two is perfect."
        case .processing:
            nil
        case .finished(let outcome):
            if outcome.handedOff {
                outcome.isNothingToInsert
                    ? "Swipe back to return to your app. There was nothing to insert."
                    : "The FreeFlow keyboard inserts the text when it reappears. If it doesn't, use Insert Last on the keyboard."
            } else if outcome.keyboardStoppedWaiting {
                outcome.isNothingToInsert
                    ? "There was nothing to insert."
                    : "The FreeFlow keyboard isn't waiting for this text. Copy it to paste it anywhere."
            } else {
                outcome.isNothingToInsert ? "Nothing was added to the test field." : "Added to the test field."
            }
        case .failed(let message, _):
            message
        }
    }

    // MARK: Centerpiece

    @ViewBuilder
    private var centerpiece: some View {
        switch model.phase {
        case .starting:
            VStack(spacing: 20) {
                RecorderWaveformView(level: 0, isActive: false)
                RecorderPulsingDots()
            }
        case .recording:
            VStack(spacing: 16) {
                RecorderWaveformView(level: model.level, isActive: true)
                elapsedTime
            }
        case .processing:
            VStack(spacing: 20) {
                RecorderWaveformView(level: 0, isActive: false)
                ProgressView()
                    .controlSize(.large)
            }
        case .needsPermission, .requestingPermission, .permissionDenied:
            symbol("mic.fill")
        case .setupNeeded:
            symbol("key.fill")
        case .consentNeeded:
            symbol("lock.shield.fill")
        case .failed:
            symbol("exclamationmark.circle.fill", color: .red)
        case .finished(let outcome):
            if outcome.isNothingToInsert {
                symbol("waveform.slash", color: .secondary)
            } else {
                resultCard(outcome)
            }
        case .idle:
            if !model.startsOnAppear {
                symbol("mic.fill")
            }
        }
    }

    private func symbol(_ name: String, color: Color = .accentColor) -> some View {
        Image(systemName: name)
            .font(.system(size: 60))
            .foregroundStyle(color)
            .padding(.vertical, 12)
            .accessibilityHidden(true)
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsedText(since: model.recordingStartedAt, now: context.date))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    static func elapsedText(since start: Date?, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func resultCard(_ outcome: RecorderOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(outcome.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("freeflow.recorder.result")
            if outcome.usedRawFallback {
                Label("Cleanup was unavailable, so this is the raw transcript.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if outcome.pressEnter {
                Label("Then presses Return", systemImage: "return")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FreeFlowStyle.cardBackground)
        )
    }

    // MARK: Details and controls

    @ViewBuilder
    private var details: some View {
        if case .finished(let outcome) = model.phase, outcome.handedOff, !outcome.isNothingToInsert {
            Label("Swipe right along the bottom edge of the screen, or tap the back arrow in the top-left corner.", systemImage: "hand.draw")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .starting, .recording:
            Button {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.recorder.stop")
        case .needsPermission, .requestingPermission:
            // App Review 5.1.1(iv): the button before the system prompt says "Continue".
            Button {
                Task { await model.requestMicrophonePermission() }
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.phase == .requestingPermission)
            .accessibilityIdentifier("freeflow.recorder.continue")
        case .permissionDenied:
            Button {
                FreeFlowStyle.openSystemSettings()
            } label: {
                Text("Open Settings")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.recorder.openSettings")
        case .setupNeeded:
            Button {
                app.closeRecorderAndOpenSettings()
            } label: {
                Text(app.hasCompletedSetup ? "Open FreeFlow Settings" : "Back to Setup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.recorder.openAppSettings")
        case .consentNeeded:
            Button {
                app.closeRecorderAndReturnToSetup()
            } label: {
                Text("Back to Setup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.recorder.backToSetup")
        case .failed:
            Button {
                model.retry()
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("freeflow.recorder.retry")
        case .finished(let outcome):
            if outcome.isNothingToInsert {
                if model.mode == .inApp {
                    Button {
                        app.closeRecorder()
                        app.startDictation(mode: .inApp)
                    } label: {
                        Text("Try Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("freeflow.recorder.retry")
                }
            } else {
                FreeFlowCopyButton(text: outcome.text, identifier: "freeflow.recorder.copy")
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .idle:
            // Opened by a link other than the keyboard's awaited session:
            // nothing records until this tap.
            if !model.startsOnAppear {
                Button {
                    model.start()
                } label: {
                    Label("Start Recording", systemImage: "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("freeflow.recorder.start")
            }
        case .processing:
            EmptyView()
        }
    }
}
