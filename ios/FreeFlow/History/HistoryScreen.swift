import SwiftUI
import UIKit

/// Labels for history entries, kept out of the views so they can be tested.
enum HistoryEntryPresentation {
    static func statusTitle(_ status: HistoryEntry.Status) -> String {
        switch status {
        case .inserted: "Inserted"
        case .nothingToInsert: "Nothing to insert"
        case .rawFallback: "Inserted without cleanup"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .handedOff: "Sent to the keyboard"
        case .notInserted: "Not inserted"
        }
    }

    static func sourceTitle(_ source: HistoryEntry.Source) -> String {
        switch source {
        case .keyboard: "Keyboard"
        case .app: "App"
        }
    }

    static func routeTitle(_ route: DictationRoute?) -> String? {
        switch route {
        case .macro: "Voice macro"
        case .verbatim: "Exact wording"
        case .translation: "Translated"
        case .cleanup: "Cleaned up"
        case .empty, nil: nil
        }
    }

    /// The text Copy puts on the clipboard: the final text, else the raw
    /// transcript, else nothing.
    static func copyText(for entry: HistoryEntry) -> String? {
        if !entry.text.isEmpty {
            return entry.text
        }
        return entry.rawTranscript.isEmpty ? nil : entry.rawTranscript
    }

    /// The raw transcript is worth showing when cleanup changed it.
    static func showsRawTranscript(_ entry: HistoryEntry) -> Bool {
        !entry.rawTranscript.isEmpty && entry.rawTranscript != entry.text
    }

    static func displayText(for entry: HistoryEntry) -> String {
        if !entry.text.isEmpty {
            return entry.text
        }
        if !entry.rawTranscript.isEmpty {
            return entry.rawTranscript
        }
        return "(no transcript)"
    }
}

/// The macOS Run Log, text only: the 20 most recent dictations from the
/// keyboard and the app, with raw and final text, Copy, and Clear History.
struct HistoryScreen: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @State private var entries: [HistoryEntry] = []
    @State private var historyEnabled = true
    @State private var isConfirmingClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !historyEnabled {
                        Label("History is off. Turn on Keep History in Settings to keep new dictations.", systemImage: "pause.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HistoryEntryRow(entry: entry, isCompact: false)
                    }
                } footer: {
                    Text("Stored locally. Only the \(HistoryLog.maxEntries) most recent runs are kept.")
                }
            }
            .overlay {
                if entries.isEmpty && historyEnabled {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Use dictation to populate history.")
                    )
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear History", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier("freeflow.history.clear")
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    app.environment.history.clear()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every saved transcript on this iPhone.")
            }
        }
        .onAppear {
            reload()
        }
        .onChange(of: app.refreshGeneration) { _, _ in
            reload()
        }
        .onChange(of: app.selectedTab) { _, tab in
            if tab == .history {
                reload()
            }
        }
        .onChange(of: app.presentationResetGeneration) { _, _ in
            isConfirmingClear = false
        }
    }

    private func reload() {
        let loaded = app.environment.history.load()
        if loaded != entries {
            entries = loaded
        }
        let enabled = app.environment.settings.historyEnabled
        if enabled != historyEnabled {
            historyEnabled = enabled
        }
    }
}

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.source == .keyboard ? "keyboard" : "iphone")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                    .accessibilityHidden(true)
                Text(HistoryEntryPresentation.statusTitle(entry.status))
                    .foregroundStyle(entry.status == .failed ? Color.red : Color.secondary)
                Spacer(minLength: 4)
                if let copyText = HistoryEntryPresentation.copyText(for: entry) {
                    FreeFlowCopyButton(text: copyText)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(HistoryEntryPresentation.displayText(for: entry))
                .font(.body)
                .foregroundStyle(entry.text.isEmpty && entry.rawTranscript.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(isCompact ? 3 : nil)
                .textSelection(.enabled)

            if !isCompact {
                if HistoryEntryPresentation.showsRawTranscript(entry), !entry.text.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw transcript")
                            .font(.caption.weight(.semibold))
                        Text(entry.rawTranscript)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                }
                if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let route = HistoryEntryPresentation.routeTitle(entry.route) {
                    Text(route)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
