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
/// go of a session that ended long ago. Holds a session ID and a time only.
struct KeyboardHandoffLedger {
    static let sessionKey = "freeflow_keyboard_handoff_session"
    static let openedAtKey = "freeflow_keyboard_handoff_opened_at"

    let defaults: UserDefaults

    func recordOpen(sessionID: UUID, at date: Date) {
        defaults.set(sessionID.uuidString, forKey: Self.sessionKey)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Self.openedAtKey)
    }

    /// nil unless the last recorded open was for `sessionID`.
    func openedAt(sessionID: UUID) -> Date? {
        guard defaults.string(forKey: Self.sessionKey) == sessionID.uuidString,
              defaults.object(forKey: Self.openedAtKey) != nil else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Self.openedAtKey))
    }
}
