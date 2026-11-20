import Foundation

/// The keyboard process's own latest result, kept in memory only (never
/// written anywhere) so Insert last works with Keep History off.
struct KeyboardRememberedText: Equatable {
    var text: String
    var savedAt: Date
}

/// What Insert last inserts: the newer of this keyboard process's remembered
/// result and history's newest insertable entry (which also has results
/// recorded in the app). Like macOS Paste Again, it never touches the
/// clipboard.
enum KeyboardInsertLast {
    static func text(remembered: KeyboardRememberedText?, history: [HistoryEntry]) -> String? {
        let newestEntry = history
            .filter { HistoryLog.latestInsertableText(in: [$0]) != nil }
            .max { $0.createdAt < $1.createdAt }
        switch (remembered, newestEntry) {
        case (nil, nil):
            return nil
        case (let remembered?, nil):
            return remembered.text
        case (nil, let entry?):
            return entry.text
        case (let remembered?, let entry?):
            return entry.createdAt > remembered.savedAt ? entry.text : remembered.text
        }
    }
}

/// When this keyboard last opened FreeFlow for the fallback, kept in the
/// keyboard's own defaults rather than the App Group. A later keyboard
/// process uses it to keep counting the wait from the real start, and to let
/// go of a session that ended long ago. It also records the field the
/// keyboard was in, so the result is auto-inserted only if the field matches
/// on return. Holds a session ID, a time and a field identifier only — no
/// text.
struct KeyboardHandoffLedger {
    static let sessionKey = "freeflow_keyboard_handoff_session"
    static let openedAtKey = "freeflow_keyboard_handoff_opened_at"
    static let documentKey = "freeflow_keyboard_handoff_document"

    let defaults: UserDefaults

    func recordOpen(sessionID: UUID, documentID: UUID?, at date: Date) {
        defaults.set(sessionID.uuidString, forKey: Self.sessionKey)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Self.openedAtKey)
        if let documentID {
            defaults.set(documentID.uuidString, forKey: Self.documentKey)
        } else {
            defaults.removeObject(forKey: Self.documentKey)
        }
    }

    /// nil unless the last recorded open was for `sessionID`.
    func openedAt(sessionID: UUID) -> Date? {
        guard isCurrent(sessionID), defaults.object(forKey: Self.openedAtKey) != nil else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Self.openedAtKey))
    }

    /// The field the keyboard was in when it opened the app for `sessionID`,
    /// or nil if unknown or the session doesn't match.
    func documentID(sessionID: UUID) -> UUID? {
        guard isCurrent(sessionID) else { return nil }
        return defaults.string(forKey: Self.documentKey).flatMap(UUID.init(uuidString:))
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        defaults.string(forKey: Self.sessionKey) == sessionID.uuidString
    }
}
