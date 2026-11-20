import SwiftUI
import UIKit

/// Colors and shared bits of the app's look. The accent comes from the
/// AccentColor asset (#6545D3, #AB94F9 in dark mode), like the icon.
@MainActor
enum FreeFlowStyle {
    static let accent = Color.accentColor
    /// Lavender to purple, for the mic and the recorder.
    static let micGradient = LinearGradient(
        colors: [Color(red: 0.67, green: 0.58, blue: 0.98), Color(red: 0.40, green: 0.27, blue: 0.83)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let fieldBackground = Color(uiColor: .tertiarySystemGroupedBackground)

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// A rounded card on a grouped background.
struct FreeFlowCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FreeFlowStyle.cardBackground)
            )
    }
}

/// A numbered step, like the "Using Groq?" steps in the macOS setup.
struct FreeFlowInstructionRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An icon and a line of text, like the macOS "You're All Set!" tips.
struct FreeFlowTipRow: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(FreeFlowStyle.accent)
                .frame(width: 24)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The multi-line field for trying the keyboard, on Home and on the
/// onboarding try-it page. UI tests find it as `freeflow.app.testField`.
struct FreeFlowTestField: View {
    @Binding var text: String
    var minHeight: CGFloat = 140

    var body: some View {
        TextEditor(text: $text)
            .accessibilityIdentifier("freeflow.app.testField")
            .accessibilityLabel("Test field")
            .font(.body)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FreeFlowStyle.fieldBackground)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Tap here, then switch to FreeFlow with 🌐")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25))
                    .allowsHitTesting(false)
            }
    }
}

/// Copies text to the clipboard when tapped and says "Copied" briefly.
/// The clipboard is only ever written here, on an explicit tap.
struct FreeFlowCopyButton: View {
    let text: String
    var title: String = "Copy"
    /// The button's accessibility identifier, if UI tests need one.
    var identifier: String?

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier(identifier ?? "")
        .disabled(text.isEmpty)
    }
}
