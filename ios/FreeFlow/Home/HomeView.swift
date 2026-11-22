import SwiftUI
import UIKit

/// Home replaces the macOS menu bar: the try-it field, the setup checklist
/// and recent history.
struct HomeView: View {
    @EnvironmentObject private var app: FreeFlowAppModel
    @State private var checklist = HomeSetupChecklist(items: [])
    @State private var recentEntries: [HistoryEntry] = []
    @State private var isRequestingMicrophone = false

    private static let recentCount = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tryItCard
                    HomeChecklistCard(
                        checklist: checklist,
                        isRequestingMicrophone: isRequestingMicrophone,
                        perform: perform
                    )
                    recentCard
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(FreeFlowStyle.groupedBackground)
            .navigationTitle("FreeFlow")
        }
        .task(id: app.refreshGeneration) {
            // The keyboard writes its status and history from another
            // process, so poll while Home is on screen.
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: Try it

    private var tryItCard: some View {
        FreeFlowCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Try FreeFlow")
                    .font(.headline)
                Text("Tap the field, switch to the FreeFlow keyboard with 🌐, then tap the mic. Say anything — a sentence or two is perfect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FreeFlowTestField(text: $app.testFieldText)
                HStack {
                    Button {
                        app.startDictation(mode: .inApp)
                    } label: {
                        Label("Dictate Without the Keyboard", systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("freeflow.app.dictateInApp")
                    Spacer()
                    if !app.testFieldText.isEmpty {
                        Button("Clear") {
                            app.testFieldText = ""
                        }
                    }
                }
            }
        }
    }

    // MARK: Recent

    private var recentCard: some View {
        FreeFlowCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                    Spacer()
                    Button("Open History") {
                        app.selectedTab = .history
                    }
                    .font(.subheadline)
                }
                if !app.environment.settings.historyEnabled {
                    Text("History is off. Turn on Keep History in Settings to keep new dictations.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if recentEntries.isEmpty {
                    Text("No transcripts yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(recentEntries) { entry in
                    HistoryEntryRow(entry: entry, isCompact: true)
                    if entry.id != recentEntries.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func reload() {
        let environment = app.environment
        let updated = HomeSetupChecklist.make(
            apiKey: environment.apiKeyState(),
            microphone: environment.microphone.permission,
            keyboardStatus: environment.keyboardStatus.load()
        )
        if updated != checklist {
            checklist = updated
        }
        let entries = Array(environment.history.load().prefix(Self.recentCount))
        if entries != recentEntries {
            recentEntries = entries
        }
    }

    private func perform(_ action: HomeSetupChecklist.Action) {
        switch action {
        case .none:
            break
        case .addAPIKey:
            app.selectedTab = .settings
        case .openSystemSettings:
            FreeFlowStyle.openSystemSettings()
        case .requestMicrophone:
            guard !isRequestingMicrophone else { return }
            isRequestingMicrophone = true
            Task {
                let granted = await app.environment.microphone.requestPermission()
                if granted {
                    app.environment.settings.microphonePermissionGranted = true
                }
                app.syncMicrophoneFlag()
                isRequestingMicrophone = false
                reload()
            }
        }
    }
}

/// The setup checklist card, shared by Home and the onboarding try-it page.
struct HomeChecklistCard: View {
    let checklist: HomeSetupChecklist
    var isRequestingMicrophone = false
    let perform: @MainActor (HomeSetupChecklist.Action) -> Void

    var body: some View {
        FreeFlowCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Setup")
                        .font(.headline)
                    Spacer()
                    if checklist.isComplete {
                        Label("All set", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
                ForEach(checklist.items) { item in
                    HomeChecklistRow(item: item, isRequestingMicrophone: isRequestingMicrophone, perform: perform)
                }
            }
        }
    }
}

struct HomeChecklistRow: View {
    let item: HomeSetupChecklist.Item
    let isRequestingMicrophone: Bool
    let perform: @MainActor (HomeSetupChecklist.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .foregroundStyle(FreeFlowStyle.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("freeflow.app.setup.\(item.kind.rawValue)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Done")
        case .needsAction, .unknown:
            switch item.action {
            case .none:
                EmptyView()
            case .addAPIKey:
                Button("Add Key") { perform(.addAPIKey) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .requestMicrophone:
                // App Review 5.1.1(iv): the button before the prompt says "Continue".
                Button("Continue") { perform(.requestMicrophone) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRequestingMicrophone)
            case .openSystemSettings:
                Button("Open Settings") { perform(.openSystemSettings) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
