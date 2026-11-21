import Foundation

/// The App Group store that the open-the-app fallback hands results
/// through, as the keyboard uses it. `PendingDictationStore` is the real one;
/// `KeyboardHandoffCheck` decides what the keyboard does with it, so those
/// decisions run in the Core tests without the App Group.
protocol KeyboardHandoffStore: AnyObject {
    /// The session the keyboard opened the app for, while it waits for it.
    var awaitedSessionID: UUID? { get set }
    /// The result for `sessionID`, without removing it: `.expired` once it
    /// is older than `PendingDictation.maxAge`, `.none` if there is none yet.
    /// The keyboard removes it when it uses it or lets it go
    /// (`stopAwaiting`), so a keyboard process stopped in between loses
    /// nothing. Another session's result is removed once stale.
    func result(for sessionID: UUID, now: Date) -> PendingDictationTake
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
/// No decision here deletes a fresh result on the strength of a read that
/// says nobody wants it, and the check itself never removes the result it
/// hands over: in CI, iOS stopped a keyboard process right after an older,
/// destructive check had taken a result, and the result was lost, leaving
/// the next keyboard waiting for good.
enum KeyboardHandoffCheck {
    /// The machine event for what the store holds now.
    /// - Nothing awaited: `.handoffAbsent`. No keyboard inserts a result
    ///   whose session isn't awaited, yet a fresh one stays: deleting
    ///   dictation text on one cross-process read that nobody wants it is
    ///   what this check never does. (CI's logs never caught such a read
    ///   lagging; the lost results came from a destructive read in a keyboard
    ///   process that iOS then stopped.) FreeFlow can leave such a result if
    ///   a keyboard lets go of its session while the app is saving it. It
    ///   goes once it can never be inserted, expired or unreadable: at a
    ///   check after it expires, at the app's cleanup when it becomes active,
    ///   or with Clear History.
    /// - A result for the awaited session, fresh or expired:
    ///   `.handoffResultArrived`, with the result left in the store until
    ///   the machine lets go of it. The machine checks freshness, so an
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
        switch store.result(for: sessionID, now: now) {
        case .fresh(let pending):
            report.outcome = .arrived
            return (arrival(of: pending, sessionID: sessionID, ledger: ledger, document: document()), report)
        case .expired(let pending):
            report.outcome = .expired
            return (arrival(of: pending, sessionID: sessionID, ledger: ledger, document: document()), report)
        case .none:
            // `result(for:now:)` drops another session's stale result and an
            // unreadable one.
            switch peek {
            case .stored(let otherSession, let createdAt):
                report.removedResult = otherSession != sessionID
                    && !PendingDictation.isFresh(createdAt: createdAt, now: now)
            case .unreadable:
                report.removedResult = true
            case .none:
                break
            }
            return (.handoffPending(sessionID: sessionID, openedAt: ledger.openedAt(sessionID: sessionID)), report)
        }
    }

    /// `.stopAwaitingApp(sessionID:)`: this keyboard stops waiting for
    /// `sessionID`, which the machine knows from its own wait, so nothing
    /// here depends on reading back what is awaited. The store forgets the
    /// session only if it still names it, since another keyboard process may
    /// have opened FreeFlow for a newer one since. That session's result goes,
    /// since nothing will insert it now, and so does any result no keyboard
    /// could ever insert (expired or unreadable). Another session's fresh
    /// result stays for the keyboard that awaits it. Returns whether a
    /// result was removed.
    @discardableResult
    static func stopAwaiting(_ store: KeyboardHandoffStore, sessionID: UUID, now: Date) -> Bool {
        if store.awaitedSessionID == sessionID {
            store.awaitedSessionID = nil
        }
        let peek = store.peekResult()
        if case .stored(let storedSession, _) = peek, storedSession == sessionID {
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
