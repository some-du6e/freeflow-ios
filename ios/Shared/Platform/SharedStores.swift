import Foundation
import os

private let storesLog = Logger(subsystem: "com.zachlatta.freeflow.ios", category: "SharedStores")
/// Handoff store changes, under the running process's own subsystem, so the
/// keyboard's lines land with its other logs. Session IDs appear as their
/// first 8 characters only, and never any text.
private let handoffLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zachlatta.freeflow.ios", category: "Handoff")

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

    /// Deletes the history file. The app calls this, together with
    /// `PendingDictationStore.discardResultAndItsWait()`, when the user clears
    /// history or turns Keep history off, so no dictation text stays on the
    /// device.
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
                let session = KeyboardHandoffCheck.shortID(newValue)
                handoffLog.info("awaited session set to \(session, privacy: .public)")
            } else {
                defaults.removeObject(forKey: Self.awaitedSessionKey)
                handoffLog.info("awaited session cleared")
            }
        }
    }

    /// Replaces any earlier pending result.
    func save(_ pending: PendingDictation) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingDictationKey)
        let session = KeyboardHandoffCheck.shortID(pending.sessionID)
        handoffLog.info("result saved for \(session, privacy: .public)")
    }

    /// The stored result's session and creation time, without its text and
    /// without removing it.
    func peekResult() -> PendingDictationPeek {
        guard let object = defaults.object(forKey: Self.pendingDictationKey) else { return .none }
        guard let data = object as? Data,
              let pending = try? JSONDecoder().decode(PendingDictation.self, from: data) else {
            return .unreadable
        }
        return .stored(sessionID: pending.sessionID, createdAt: pending.createdAt)
    }

    /// The result for `sessionID`, without removing it: `.fresh`, or
    /// `.expired` once it is older than `PendingDictation.maxAge`, so the
    /// keyboard can tell an expired result from one that hasn't arrived. The
    /// keyboard removes it when it uses it or lets it go
    /// (`KeyboardHandoffCheck.stopAwaiting`), so a keyboard process that iOS
    /// stops in between loses nothing. A result for another session is left
    /// alone while fresh and removed once stale.
    func result(for sessionID: UUID, now: Date) -> PendingDictationTake {
        guard let pending = loadResult() else { return .none }
        guard pending.sessionID == sessionID else {
            if !pending.isFresh(now: now) {
                discardResult()
            }
            return .none
        }
        let fresh = pending.isFresh(now: now)
        let state = fresh ? "fresh" : "expired"
        let session = KeyboardHandoffCheck.shortID(sessionID)
        handoffLog.info("found the \(state, privacy: .public) result for \(session, privacy: .public)")
        return fresh ? .fresh(pending) : .expired(pending)
    }

    /// Removes the pending result only. The awaited session stays. The
    /// removal is written even when this process doesn't see a result, so a
    /// result it hasn't read yet goes too.
    func discardResult() {
        let hadResult = defaults.object(forKey: Self.pendingDictationKey) != nil
        defaults.removeObject(forKey: Self.pendingDictationKey)
        if hadResult {
            handoffLog.info("stored result removed")
        }
    }

    /// Clear History and Keep History off: removes the stored result, which
    /// holds dictation text. When it is the result for the session the
    /// keyboard awaits, that handoff has already delivered and nothing else
    /// will arrive for it, so the awaited session goes too. The keyboard's
    /// next check then finds nothing awaited and stops waiting, instead of
    /// waiting minutes for a result that's gone. With no result stored, or
    /// one for another session, the awaited session stays, so a handoff that
    /// hasn't delivered yet still does.
    func discardResultAndItsWait() {
        if let pending = loadResult(), pending.sessionID == awaitedSessionID {
            awaitedSessionID = nil
        }
        discardResult()
    }

    /// Clears out what no keyboard can still use, for the app to run when it
    /// becomes active. A result for a session the keyboard isn't waiting
    /// for (or an unreadable one) is removed. An expired result for the
    /// session it is waiting for loses its text but stays as a marker, so the
    /// keyboard's next `take` still reports `.expired` and the keyboard stops
    /// waiting instead of waiting for a result that's gone. Never touches the
    /// awaited session.
    func discardUnclaimedResult(now: Date) {
        guard defaults.object(forKey: Self.pendingDictationKey) != nil else { return }
        guard let pending = loadResult(), pending.sessionID == awaitedSessionID else {
            discardResult()
            return
        }
        guard !pending.isFresh(now: now), !pending.text.isEmpty || pending.pressEnter else { return }
        save(PendingDictation(sessionID: pending.sessionID, createdAt: pending.createdAt, text: "", pressEnter: false))
    }

    /// Removes the pending result and the awaited session.
    func clear() {
        defaults.removeObject(forKey: Self.pendingDictationKey)
        defaults.removeObject(forKey: Self.awaitedSessionKey)
        handoffLog.info("awaited session and stored result cleared")
    }

    /// The stored result. An unreadable one is removed.
    private func loadResult() -> PendingDictation? {
        guard let data = defaults.data(forKey: Self.pendingDictationKey) else { return nil }
        guard let pending = try? JSONDecoder().decode(PendingDictation.self, from: data) else {
            discardResult()
            return nil
        }
        return pending
    }
}

/// The keyboard reads and ends handoffs through `KeyboardHandoffCheck`.
extension PendingDictationStore: KeyboardHandoffStore {}

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
