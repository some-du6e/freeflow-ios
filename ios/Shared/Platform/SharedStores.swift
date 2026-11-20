import Foundation

/// File-backed dictation history in the App Group container.
///
/// CONTRACT STUB: owned by the shared-pipeline agent (atomic writes, file
/// protection, honoring `SettingsStore.historyEnabled`). Keep the signatures.
final class HistoryStore {
    static let shared = HistoryStore(
        fileURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FreeFlowIdentifiers.appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/FreeFlow/history.json")
    )

    let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func load() -> [HistoryEntry] {
        []
    }

    func append(_ entry: HistoryEntry) {}

    func clear() {}

    func latestInsertableText() -> String? {
        HistoryLog.latestInsertableText(in: load())
    }
}

/// Hands a result recorded in the app to the keyboard that asked for it.
///
/// CONTRACT STUB: owned by the shared-pipeline agent. Keep the signatures.
final class PendingDictationStore {
    static let shared = PendingDictationStore(defaults: SettingsStore.shared.defaults)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The session the keyboard opened the app for, if it is still waiting.
    var awaitedSessionID: UUID? {
        get { nil }
        set {}
    }

    func save(_ pending: PendingDictation) {}

    /// Returns and removes the result for `sessionID` if it is fresh.
    func take(sessionID: UUID, now: Date) -> PendingDictation? {
        nil
    }

    func clear() {}
}

/// The keyboard's self-reported status, for the app's setup checklist.
///
/// CONTRACT STUB: owned by the shared-pipeline agent. Keep the signatures.
final class KeyboardStatusStore {
    static let shared = KeyboardStatusStore(defaults: SettingsStore.shared.defaults)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func record(_ status: KeyboardStatus) {}

    func load() -> KeyboardStatus? {
        nil
    }
}
