import Foundation
import os

private let storesLog = Logger(subsystem: "com.zachlatta.freeflow.ios", category: "SharedStores")

/// The newest dictations, as a small JSON file in the App Group container.
///
/// The app and the keyboard both write it. Every write replaces the whole
/// file atomically (write to a temporary file, then rename), so a reader in
/// the other process sees the old or the new list, never a partial one, and
/// no file lock is held across a suspension (which iOS punishes with a
/// 0xdead10cc kill). Two processes appending at the same instant can lose
/// one of the two entries; the window is a few milliseconds.
final class HistoryStore {
    static let shared = HistoryStore(
        fileURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FreeFlowIdentifiers.appGroupIdentifier)?
            .appendingPathComponent("Library/Application Support/FreeFlow/history.json")
    )

    let fileURL: URL?
    private let settings: SettingsStore
    /// Serializes this process's read-modify-write cycles.
    private let lock = NSLock()

    /// `settings` supplies the Keep history choice (`historyEnabled`).
    init(fileURL: URL?, settings: SettingsStore = .shared) {
        self.fileURL = fileURL
        self.settings = settings
    }

    /// Newest first. Empty when there is no file or it can't be decoded.
    func load() -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return readEntries()
    }

    /// Adds `entry`, keeping the newest `HistoryLog.maxEntries`. Does nothing
    /// while Keep history is off.
    func append(_ entry: HistoryEntry) {
        guard settings.historyEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        write(HistoryLog.appending(entry, to: readEntries()))
    }

    /// Deletes the history file. The app should call this when the user
    /// turns Keep history off, so no dictation text stays on the device.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            storesLog.error("History clear failed: \(Self.errorKind(error), privacy: .public)")
        }
    }

    func latestInsertableText() -> String? {
        HistoryLog.latestInsertableText(in: load())
    }

    private func readEntries() -> [HistoryEntry] {
        guard let fileURL else { return [] }
        return HistoryLog.decode(try? Data(contentsOf: fileURL))
    }

    private func write(_ entries: [HistoryEntry]) {
        guard let fileURL else { return }
        do {
            let data = try HistoryLog.encode(entries)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A keyboard without Full Access has a read-only container.
            storesLog.error("History write failed: \(Self.errorKind(error), privacy: .public)")
        }
    }

    /// Domain and code only; never paths or contents.
    private static func errorKind(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

/// Hands a result recorded in the app to the keyboard that asked for it,
/// through two App Group defaults keys.
final class PendingDictationStore {
    static let pendingDictationKey = "ios_pending_dictation"
    static let awaitedSessionKey = "ios_awaited_dictation_session"

    static let shared = PendingDictationStore(defaults: SettingsStore.shared.defaults)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The session the keyboard opened the app for, if it is still waiting.
    /// Setting nil removes it.
    var awaitedSessionID: UUID? {
        get {
            defaults.string(forKey: Self.awaitedSessionKey).flatMap(UUID.init(uuidString:))
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: Self.awaitedSessionKey)
            } else {
                defaults.removeObject(forKey: Self.awaitedSessionKey)
            }
        }
    }

    /// Replaces any earlier pending result.
    func save(_ pending: PendingDictation) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingDictationKey)
    }

    /// Returns and removes the result for `sessionID` if it is fresh. A
    /// stale result for `sessionID` is removed and not returned. A result
    /// for another session is left alone while fresh and removed once
    /// stale, so a `take` after `PendingDictation.maxAge` always drops it.
    func take(sessionID: UUID, now: Date) -> PendingDictation? {
        guard let data = defaults.data(forKey: Self.pendingDictationKey) else { return nil }
        guard let pending = try? JSONDecoder().decode(PendingDictation.self, from: data) else {
            defaults.removeObject(forKey: Self.pendingDictationKey)
            return nil
        }
        guard pending.sessionID == sessionID else {
            if !pending.isFresh(now: now) {
                defaults.removeObject(forKey: Self.pendingDictationKey)
            }
            return nil
        }
        defaults.removeObject(forKey: Self.pendingDictationKey)
        return pending.isFresh(now: now) ? pending : nil
    }

    /// Removes the pending result and the awaited session.
    func clear() {
        defaults.removeObject(forKey: Self.pendingDictationKey)
        defaults.removeObject(forKey: Self.awaitedSessionKey)
    }
}

/// The keyboard's self-reported status, for the app's setup checklist.
final class KeyboardStatusStore {
    static let keyboardStatusKey = "ios_keyboard_status"

    static let shared = KeyboardStatusStore(defaults: SettingsStore.shared.defaults)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Saves `status`. When it has no capture result yet (both
    /// `inKeyboardCaptureWorked` and `lastCaptureFailure` are nil, as in a
    /// fresh keyboard process), the previously recorded capture result is
    /// kept, so the app's checklist doesn't forget it.
    func record(_ status: KeyboardStatus) {
        var merged = status
        if merged.inKeyboardCaptureWorked == nil, merged.lastCaptureFailure == nil, let previous = load() {
            merged.inKeyboardCaptureWorked = previous.inKeyboardCaptureWorked
            merged.lastCaptureFailure = previous.lastCaptureFailure
        }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        defaults.set(data, forKey: Self.keyboardStatusKey)
    }

    func load() -> KeyboardStatus? {
        guard let data = defaults.data(forKey: Self.keyboardStatusKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardStatus.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: Self.keyboardStatusKey)
    }
}
