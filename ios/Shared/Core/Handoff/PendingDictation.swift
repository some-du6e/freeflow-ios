import Foundation

/// A result the containing app recorded on behalf of the keyboard (the
/// open-the-app fallback). The keyboard inserts it when it next appears, if
/// it is still waiting for that session and the result is fresh.
struct PendingDictation: Codable, Equatable {
    static let maxAge: TimeInterval = 180

    var sessionID: UUID
    var createdAt: Date
    var text: String
    var pressEnter: Bool

    func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= -5 && age <= Self.maxAge
    }
}

/// What `PendingDictationStore.take(sessionID:now:)` found for a session.
/// A fresh or expired result is removed from the store either way.
enum PendingDictationTake: Equatable {
    /// Young enough to insert.
    case fresh(PendingDictation)
    /// Older than `PendingDictation.maxAge`. The keyboard stops waiting and
    /// says the result expired instead of inserting it.
    case expired(PendingDictation)
    /// Nothing for this session yet.
    case none
}

/// What the keyboard last reported about itself, so the containing app can
/// show setup status. Written only when the keyboard has Full Access (without
/// it the App Group is read-only to the keyboard). Contains no user content.
struct KeyboardStatus: Codable, Equatable {
    enum MicrophonePermission: String, Codable, Equatable {
        case granted
        case denied
        case undetermined
    }

    var lastSeenAt: Date
    var hasFullAccess: Bool
    var microphonePermission: MicrophonePermission
    /// nil until the keyboard has tried in-keyboard capture once.
    var inKeyboardCaptureWorked: Bool?
    /// A failure kind such as "startTimedOut"; never user content.
    var lastCaptureFailure: String?
}
