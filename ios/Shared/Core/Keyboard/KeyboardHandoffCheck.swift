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
    /// The stored result's session and creation time, without its text and
    /// without removing it.
    func peekResult() -> PendingDictationPeek
    /// Removes the stored result and leaves the awaited session.
    func discardResult()
}

/// What one handoff check saw and did, for logs that hold no user content:
/// outcomes, ages and the first characters of session IDs, never text.
struct KeyboardHandoffCheckReport: Equatable {
    enum Outcome: String, Equatable {
        /// Nothing awaited.
        case absent
        /// Awaited, with no result for that session yet.
        case pending
        /// A fresh result for the awaited session.
        case arrived
        /// An expired result for the awaited session.
        case expired
    }

    var outcome: Outcome
    /// The awaited session's first characters, or nil when the read found none.
    var awaitedSession: String?
    /// What was stored when the check began, as `KeyboardHandoffCheck.describe` words it.
    var stored: String
    /// Whether the check removed a result without handing it to the keyboard.
    var removedResult: Bool

    var summary: String {
        "\(outcome.rawValue) (awaited \(awaitedSession ?? "none"); stored \(stored)"
            + (removedResult ? "; removed it)" : ")")
    }
}

/// What the keyboard does with the handoff store: look for the app's result
/// when it appears and while it waits (`.checkForAppResult`), and let go of
/// the session when the machine stops waiting (`.stopAwaitingApp`). The
/// controller only carries these out.
///
/// Reads of the App Group can lag another process's writes, and a long-lived
/// keyboard process has been seen to read "nothing awaited" for a session it
/// had opened itself. So no decision here deletes a fresh result on the
/// strength of a read that says nobody wants it.
enum KeyboardHandoffCheck {
    /// The machine event for what the store holds now.
    /// - Nothing awaited: `.handoffAbsent`. No keyboard can insert a result
    ///   unless its session is awaited, but the read may be stale, so only a
    ///   result that can never be inserted (expired or unreadable) is
    ///   removed. A fresh one stays for the keyboard that does await it; the
    ///   app's cleanup when it becomes active, a check after it expires, or
    ///   Clear History removes it otherwise.
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
        checkAndReport(store, ledger: ledger, now: now, document: document()).event
    }

    /// `check`, with a report of what it saw for the keyboard's log.
    static func checkAndReport(
        _ store: KeyboardHandoffStore,
        ledger: KeyboardHandoffLedger,
        now: Date,
        document: @autoclosure () -> KeyboardDictationDocument
    ) -> (event: KeyboardDictationEvent, report: KeyboardHandoffCheckReport) {
        let awaited = store.awaitedSessionID
        let peek = store.peekResult()
        let stored = describe(peek, awaited: awaited, now: now)
        guard let sessionID = awaited else {
            let removed = removeIfStale(store, peek: peek, now: now)
            let report = KeyboardHandoffCheckReport(outcome: .absent, awaitedSession: nil, stored: stored, removedResult: removed)
            return (.handoffAbsent, report)
        }
        var report = KeyboardHandoffCheckReport(
            outcome: .pending,
            awaitedSession: shortID(sessionID),
            stored: stored,
            removedResult: false
        )
        switch store.take(sessionID: sessionID, now: now) {
        case .fresh(let pending):
            report.outcome = .arrived
            return (arrival(of: pending, sessionID: sessionID, ledger: ledger, document: document()), report)
        case .expired(let pending):
            report.outcome = .expired
            return (arrival(of: pending, sessionID: sessionID, ledger: ledger, document: document()), report)
        case .none:
            if case .stored(let otherSession, let createdAt) = peek, otherSession != sessionID,
               !PendingDictation.isFresh(createdAt: createdAt, now: now) {
                // `take` drops a stale result for another session.
                report.removedResult = true
            }
            return (.handoffPending(sessionID: sessionID, openedAt: ledger.openedAt(sessionID: sessionID)), report)
        }
    }

    /// `.stopAwaitingApp`: this keyboard stops waiting, so the awaited
    /// session is forgotten. A result for that session goes with it, since
    /// nothing will insert it now. A result for any other session stays
    /// while fresh: the read of what was awaited can be stale, and the app
    /// may be writing that result for a keyboard that does still wait. A
    /// stale or unreadable result goes either way. Returns whether a result
    /// was removed.
    @discardableResult
    static func stopAwaiting(_ store: KeyboardHandoffStore, now: Date) -> Bool {
        let stopped = store.awaitedSessionID
        store.awaitedSessionID = nil
        let peek = store.peekResult()
        if case .stored(let sessionID, _) = peek, sessionID == stopped {
            store.discardResult()
            return true
        }
        return removeIfStale(store, peek: peek, now: now)
    }

    /// Words for a stored result in logs: whose it is and how old, never its text.
    static func describe(_ peek: PendingDictationPeek, awaited: UUID?, now: Date) -> String {
        switch peek {
        case .none:
            return "nothing"
        case .unreadable:
            return "an unreadable result"
        case .stored(let sessionID, let createdAt):
            let owner = sessionID == awaited ? "a result for it" : "a result for \(shortID(sessionID))"
            return "\(owner), \(ageBucket(now.timeIntervalSince(createdAt)))"
        }
    }

    /// The first 8 characters of a session ID: enough to match log lines,
    /// not the whole identifier.
    static func shortID(_ sessionID: UUID) -> String {
        String(sessionID.uuidString.prefix(8))
    }

    static func ageBucket(_ age: TimeInterval) -> String {
        switch age {
        case ..<(-5):
            return "dated in the future"
        case ..<10:
            return "under 10 s old"
        case ..<60:
            return "10-60 s old"
        case ...PendingDictation.maxAge:
            return "1-3 min old"
        default:
            return "expired"
        }
    }

    private static func arrival(
        of pending: PendingDictation,
        sessionID: UUID,
        ledger: KeyboardHandoffLedger,
        document: KeyboardDictationDocument
    ) -> KeyboardDictationEvent {
        .handoffResultArrived(pending, expectedDocumentID: ledger.documentID(sessionID: sessionID), document: document)
    }

    /// Removes the stored result only if no keyboard could ever insert it.
    private static func removeIfStale(_ store: KeyboardHandoffStore, peek: PendingDictationPeek, now: Date) -> Bool {
        switch peek {
        case .none:
            return false
        case .unreadable:
            store.discardResult()
            return true
        case .stored(_, let createdAt):
            guard !PendingDictation.isFresh(createdAt: createdAt, now: now) else { return false }
            store.discardResult()
            return true
        }
    }
}
