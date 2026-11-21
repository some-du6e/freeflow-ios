import Foundation

/// The App Group store that the open-the-app fallback hands results
/// through, as the keyboard uses it. `PendingDictationStore` is the real one;
/// `KeyboardHandoffCheck` decides what the keyboard does with it, so those
/// decisions run in the Core tests without the App Group.
protocol KeyboardHandoffStore: AnyObject {
    /// The session the keyboard opened the app for, while it waits for it.
    var awaitedSessionID: UUID? { get set }
    /// Removes and returns the result for `sessionID`: `.expired` once it is
    /// older than `PendingDictation.maxAge`, `.none` if there is none yet.
    func take(sessionID: UUID, now: Date) -> PendingDictationTake
    /// Removes the stored result and leaves the awaited session.
    func discardResult()
}

/// What the keyboard does with the handoff store: look for the app's result
/// when it appears and while it waits (`.checkForAppResult`), and let go of
/// the session when the machine stops waiting (`.stopAwaitingApp`). The
/// controller only carries these out.
enum KeyboardHandoffCheck {
    /// The machine event for what the store holds now.
    /// - Nothing awaited: `.handoffAbsent`. No keyboard can insert a result
    ///   left in the store, so it is discarded rather than kept, with its
    ///   text, in the App Group.
    /// - A result for the awaited session, fresh or expired:
    ///   `.handoffResultArrived`. The machine checks freshness, so an
    ///   expired result ends the wait with a message.
    /// - No result yet: `.handoffPending`, with when this keyboard opened
    ///   the app for the session, if it did.
    ///
    /// `document` is read only when a result arrived.
    static func check(
        _ store: KeyboardHandoffStore,
        ledger: KeyboardHandoffLedger,
        now: Date,
        document: @autoclosure () -> KeyboardDictationDocument
    ) -> KeyboardDictationEvent {
        guard let sessionID = store.awaitedSessionID else {
            store.discardResult()
            return .handoffAbsent
        }
        switch store.take(sessionID: sessionID, now: now) {
        case .fresh(let pending), .expired(let pending):
            return .handoffResultArrived(
                pending,
                expectedDocumentID: ledger.documentID(sessionID: sessionID),
                document: document()
            )
        case .none:
            return .handoffPending(sessionID: sessionID, openedAt: ledger.openedAt(sessionID: sessionID))
        }
    }

    /// `.stopAwaitingApp`: nothing awaits a result any more, so none can be
    /// inserted. Forgets the session and drops any result the app left,
    /// rather than keep its text around.
    static func stopAwaiting(_ store: KeyboardHandoffStore) {
        store.awaitedSessionID = nil
        store.discardResult()
    }
}
