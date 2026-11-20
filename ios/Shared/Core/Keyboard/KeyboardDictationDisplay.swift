import Foundation

/// The machine state names the keyboard publishes as the status label's
/// accessibility value. UI tests match these exactly.
enum KeyboardDictationStatus: String, Equatable, CaseIterable {
    case idle
    case setupNeeded = "setup-needed"
    case starting
    case recording
    case processing
    case inserted
    case nothingToInsert = "nothing-to-insert"
    case error
    case fallbackAvailable = "fallback-available"
    case waitingForApp = "waiting-for-app"
    /// The app handed a result back into a field the keyboard isn't sure of,
    /// so it waits for a tap on the Insert from FreeFlow CTA.
    case pendingInsert = "pending-insert"
}

/// Accessibility identifiers for the keyboard's controls. UI tests depend on
/// these exact strings.
enum KeyboardAccessibilityID {
    static let mic = "freeflow.keyboard.mic"
    static let cancel = "freeflow.keyboard.cancel"
    static let done = "freeflow.keyboard.done"
    static let globe = "freeflow.keyboard.globe"
    static let space = "freeflow.keyboard.space"
    static let delete = "freeflow.keyboard.delete"
    static let returnKey = "freeflow.keyboard.return"
    static let insertLast = "freeflow.keyboard.insertLast"
    static let openApp = "freeflow.keyboard.openApp"
    /// The CTA shown in the `pending-insert` state.
    static let insertPending = "freeflow.keyboard.insertPending"
    static let status = "freeflow.keyboard.status"
}

/// Everything the keyboard panel shows for one machine state, so the UIKit
/// view only renders and the wording is tested here.
struct KeyboardDictationDisplay: Equatable {
    enum Tone: Equatable {
        case neutral
        case active
        case success
        case warning
        case failure
    }

    enum Mic: Equatable {
        /// Tap or hold to dictate.
        case ready
        /// Setup is missing; pressing re-checks it and explains.
        case unavailable
        case starting
        /// Shows the waveform.
        case recording
        case processing
    }

    /// The control to the right of the mic.
    enum TrailingAction: Equatable {
        case done
        case openApp
    }

    var status: KeyboardDictationStatus
    var statusText: String
    var tone: Tone
    var mic: Mic
    var micAccessibilityLabel: String
    /// The title of the control to the left of the mic, or nil to hide it.
    var cancelTitle: String?
    var trailingAction: TrailingAction?
    var insertLastEnabled: Bool
    /// When true the panel shows the Insert from FreeFlow CTA in place of
    /// Insert last (the `pending-insert` state).
    var pendingInsertVisible = false
}

extension KeyboardDictationDisplay {
    static let idleText = "Tap the mic to dictate, or hold to talk"
    static let startingText = "Starting the microphone…"
    static let processingText = "Transcribing…"
    static let waitingForAppText = "Waiting for FreeFlow. Finish recording there, then swipe back."
    static let pendingInsertText = "FreeFlow finished. Tap Insert from FreeFlow to add it here."
    static let openAppTitle = "Open FreeFlow"
    static let insertPendingTitle = "Insert from FreeFlow"
    static let cancelButtonTitle = "Cancel"
    static let dismissFallbackTitle = "Not now"
    static let dismissPendingTitle = "Dismiss"
    static let stopWaitingTitle = "Stop waiting"
    static let dictateLabel = "Dictate"
    static let stopLabel = "Stop dictation"
    static let transcribingLabel = "Transcribing"

    static func setupText(for issue: KeyboardDictationSetupIssue) -> String {
        switch issue {
        case .fullAccess:
            return "Turn on Allow Full Access in Settings to dictate"
        case .microphone:
            return "Open FreeFlow to allow the microphone"
        case .apiKey:
            return "Open FreeFlow to add your API key"
        }
    }

    static func recordingText(for gesture: KeyboardDictationMachine.Gesture) -> String {
        switch gesture {
        case .pressing:
            return "Listening…"
        case .holding:
            return "Listening… release to stop"
        case .latched:
            return "Listening… tap the mic to stop"
        }
    }

    static func insertedText(for kind: KeyboardDictationMachine.InsertedKind) -> String {
        switch kind {
        case .dictation:
            return "Inserted"
        case .rawFallback:
            return "Inserted without cleanup"
        case .returnOnly:
            return "Pressed return"
        case .lastDictation:
            return "Inserted your last dictation"
        case .handoff:
            return "Inserted from FreeFlow"
        }
    }

    static func nothingText(for reason: KeyboardDictationMachine.NothingReason) -> String {
        switch reason {
        case .emptyTranscript:
            return "Nothing to transcribe"
        case .noAudio:
            return "No audio was recorded"
        case .noHistory:
            return "Nothing to insert yet"
        }
    }

    static func fallbackText(for reason: KeyboardDictationMachine.FallbackReason) -> String {
        switch reason {
        case .captureUnavailable:
            return "Can't record in the keyboard here. Record in FreeFlow instead."
        case .lowMemory:
            return "Not enough memory to record here. Record in FreeFlow instead."
        case .openFailed:
            return "Couldn't open FreeFlow. Open it from your Home Screen."
        }
    }

    init(machine: KeyboardDictationMachine) {
        switch machine.phase {
        case .idle:
            self.init(
                status: .idle,
                statusText: Self.idleText,
                tone: .neutral,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: nil,
                trailingAction: nil,
                insertLastEnabled: true
            )
        case .setupNeeded(let issue):
            self.init(
                status: .setupNeeded,
                statusText: Self.setupText(for: issue),
                tone: .warning,
                mic: .unavailable,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: nil,
                trailingAction: nil,
                insertLastEnabled: true
            )
        case .starting:
            self.init(
                status: .starting,
                statusText: Self.startingText,
                tone: .active,
                mic: .starting,
                micAccessibilityLabel: Self.stopLabel,
                cancelTitle: Self.cancelButtonTitle,
                trailingAction: .done,
                insertLastEnabled: false
            )
        case .recording(let recording):
            self.init(
                status: .recording,
                statusText: Self.recordingText(for: recording.gesture),
                tone: .active,
                mic: .recording,
                micAccessibilityLabel: Self.stopLabel,
                cancelTitle: Self.cancelButtonTitle,
                trailingAction: .done,
                insertLastEnabled: false
            )
        case .processing:
            self.init(
                status: .processing,
                statusText: Self.processingText,
                tone: .active,
                mic: .processing,
                micAccessibilityLabel: Self.transcribingLabel,
                cancelTitle: Self.cancelButtonTitle,
                trailingAction: nil,
                insertLastEnabled: false
            )
        case .inserted(let kind, _):
            self.init(
                status: .inserted,
                statusText: Self.insertedText(for: kind),
                tone: .success,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: nil,
                trailingAction: nil,
                insertLastEnabled: true
            )
        case .nothingToInsert(let reason, _):
            self.init(
                status: .nothingToInsert,
                statusText: Self.nothingText(for: reason),
                tone: .neutral,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: nil,
                trailingAction: nil,
                insertLastEnabled: true
            )
        case .error(let message, _):
            self.init(
                status: .error,
                statusText: message,
                tone: .failure,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: nil,
                trailingAction: nil,
                insertLastEnabled: true
            )
        case .fallbackAvailable(let reason):
            self.init(
                status: .fallbackAvailable,
                statusText: Self.fallbackText(for: reason),
                tone: .warning,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: Self.dismissFallbackTitle,
                trailingAction: .openApp,
                insertLastEnabled: true
            )
        case .waitingForApp:
            self.init(
                status: .waitingForApp,
                statusText: Self.waitingForAppText,
                tone: .neutral,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: Self.stopWaitingTitle,
                trailingAction: .openApp,
                insertLastEnabled: true
            )
        case .pendingInsert:
            self.init(
                status: .pendingInsert,
                statusText: Self.pendingInsertText,
                tone: .success,
                mic: .ready,
                micAccessibilityLabel: Self.dictateLabel,
                cancelTitle: Self.dismissPendingTitle,
                trailingAction: nil,
                insertLastEnabled: false,
                pendingInsertVisible: true
            )
        }
    }
}
