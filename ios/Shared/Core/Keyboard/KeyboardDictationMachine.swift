import Foundation

/// Why the keyboard can't dictate yet, in the order the user has to fix it.
enum KeyboardDictationSetupIssue: String, Equatable, CaseIterable {
    /// Allow Full Access is off: no network, no shared keychain, and no
    /// writes to the App Group.
    case fullAccess
    /// The containing app doesn't hold microphone permission, which the
    /// in-keyboard WebKit capture relies on.
    case microphone
    /// No readable API key, so there is no `DictationConfiguration`.
    case apiKey
}

/// What the keyboard checks before it lets capture start.
struct KeyboardDictationSetup: Equatable {
    /// Below this much `os_proc_available_memory()`, recording inside the
    /// keyboard risks a silent jetsam kill, so the keyboard offers to record
    /// in the app instead.
    static let minimumAvailableMemoryBytes = 32 * 1024 * 1024

    var hasFullAccess: Bool
    /// `AVAudioApplication.shared.recordPermission == .granted`, or the app's
    /// `microphonePermissionGranted` flag: a keyboard process can cache a
    /// stale "undetermined" permission from before the app was granted.
    var microphoneGranted: Bool
    /// `SettingsStore.dictationConfiguration() != nil`.
    var hasAPIKey: Bool
    /// nil when iOS reports no limit (`os_proc_available_memory()` returns 0
    /// in the simulator), which doesn't block capture.
    var availableMemoryBytes: Int?

    var blockingIssue: KeyboardDictationSetupIssue? {
        if !hasFullAccess { return .fullAccess }
        if !microphoneGranted { return .microphone }
        if !hasAPIKey { return .apiKey }
        return nil
    }

    var hasMemoryToRecord: Bool {
        guard let availableMemoryBytes else { return true }
        return availableMemoryBytes >= Self.minimumAvailableMemoryBytes
    }
}

/// `WebAudioCaptureFailure` without its payloads, so Core can decide what each
/// failure means. Raw values are what `KeyboardStatus.lastCaptureFailure`
/// records (failure kinds only, never user content).
enum KeyboardDictationCaptureFailure: String, Equatable, CaseIterable {
    case pageUnavailable
    case startTimedOut
    case permissionDenied
    case unsupported
    case interrupted
    case noAudio
    case fileError
}

/// A finished recording, as far as the keyboard's decisions need it.
struct KeyboardDictationAudio: Equatable {
    var fileURL: URL
    var duration: TimeInterval
}

/// The host field when something is about to be inserted. Read from
/// `textDocumentProxy` just before insertion and never stored.
struct KeyboardDictationDocument: Equatable {
    var identifier: UUID?
    var textBeforeCursor: String?
}

/// A history entry the keyboard wants written. The controller turns it into a
/// `HistoryEntry` with a fresh ID, which keeps the machine deterministic.
struct KeyboardDictationHistoryDraft: Equatable {
    var createdAt: Date
    var status: HistoryEntry.Status
    var rawTranscript: String
    var text: String
    var route: DictationRoute?
    var errorMessage: String?
    var durationSeconds: Double
    /// Cleanup or translation failed and `text` is the raw transcript.
    var usedRawFallback = false

    func makeEntry(id: UUID = UUID()) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: createdAt,
            source: .keyboard,
            status: status,
            rawTranscript: rawTranscript,
            text: text,
            route: route,
            usedRawFallback: usedRawFallback,
            errorMessage: errorMessage,
            durationSeconds: durationSeconds
        )
    }
}

enum KeyboardDictationEvent: Equatable {
    /// Fresh setup facts. The controller sends this on appear and right
    /// before every mic press.
    case setupChanged(KeyboardDictationSetup)
    case appeared
    case disappeared
    /// `documentID` is `textDocumentProxy.documentIdentifier` at the press.
    case micPressBegan(documentID: UUID?)
    /// The finger lifted or the system cancelled the touch.
    case micPressEnded
    case doneTapped
    case cancelTapped
    /// The fallback CTA. `newSessionID` is used unless a session is already
    /// being waited on.
    case openAppTapped(newSessionID: UUID)
    /// The responder chain had no UIApplication to open FreeFlow with.
    case appOpenFailed
    /// `text` is `HistoryStore.latestInsertableText()`.
    case insertLastTapped(text: String?, document: KeyboardDictationDocument)
    /// The first non-silent audio arrived.
    case captureStarted
    case captureFinished(KeyboardDictationAudio)
    case captureFailed(KeyboardDictationCaptureFailure)
    case pipelineFinished(attempt: Int, result: DictationResult, document: KeyboardDictationDocument)
    /// `message` is `DictationPipeline.userFacingMessage(for:isOnline:)`.
    case pipelineFailed(attempt: Int, message: String)
    /// The handoff check found the app's result for the awaited session,
    /// fresh or expired, and left it in the store (`KeyboardHandoffCheck`);
    /// the machine checks freshness itself.
    /// `expectedDocumentID` is the field the keyboard opened the app from,
    /// if this process knows it; the result is auto-inserted only when the
    /// current field matches it.
    case handoffResultArrived(PendingDictation, expectedDocumentID: UUID?, document: KeyboardDictationDocument)
    /// The `pending-insert` CTA: insert the held handoff result into the
    /// current field, which the tap makes an explicit choice.
    case insertPendingTapped(document: KeyboardDictationDocument)
    /// The store is still waiting on `sessionID` and has no result yet.
    /// `openedAt` is when this keyboard opened the app for it, if known.
    case handoffPending(sessionID: UUID, openedAt: Date?)
    /// The store isn't waiting on any session.
    case handoffAbsent
    /// A deadline from `nextWakeUp` passed.
    case tick
}

enum KeyboardDictationEffect: Equatable {
    case startCapture
    case stopCapture
    case cancelCapture
    case runPipeline(attempt: Int, audioFileURL: URL)
    case cancelPipeline
    case deleteAudio(URL)
    case insert(String)
    case recordHistory(KeyboardDictationHistoryDraft)
    /// Mark `sessionID` as awaited and open `freeflow://dictate?session=`.
    case openApp(sessionID: UUID)
    /// Stop waiting for the app's result for `sessionID`:
    /// `KeyboardHandoffCheck.stopAwaiting` forgets that session if the store
    /// still names it, and removes that session's result.
    case stopAwaitingApp(sessionID: UUID)
    /// Ask the store whether the app's result has arrived
    /// (`KeyboardHandoffCheck.check`).
    case checkForAppResult
    /// Keep this text in memory for Insert last, so it works even with Keep
    /// History off (macOS Paste Again uses the last transcript the same way).
    /// Never persisted.
    case rememberForInsertLast(text: String, at: Date)
    /// A light haptic on start and stop; only emitted with Full Access.
    case haptic
    /// For `KeyboardStatus.inKeyboardCaptureWorked` and `lastCaptureFailure`.
    case reportCapture(worked: Bool, failure: KeyboardDictationCaptureFailure?)
    /// Show this message to VoiceOver users (the status line shows it too).
    case announce(String)
}

/// The keyboard's dictation state machine: a pure reducer from events (with
/// an injected `now`) to the next state and the effects the keyboard
/// controller carries out. Deadlines are exposed through `nextWakeUp`; the
/// controller sends `.tick` when one passes.
///
/// Gestures follow the macOS shortcuts: pressing the mic starts capture at
/// once. Releasing before `holdToTalkThreshold` latches tap-to-toggle, and
/// the next press stops (like the toggle shortcut); releasing later stops
/// (hold to talk).
struct KeyboardDictationMachine: Equatable {
    // MARK: Timing, in seconds

    static let holdToTalkThreshold: TimeInterval = 0.35
    static let maximumRecordingDuration: TimeInterval = 5 * 60
    /// The capture's first-audio watchdog for the keyboard's first start
    /// after it attaches the capture, which can wait on WebKit's GPU process
    /// launching cold (2.19 s was measured on CI simulators). Later starts
    /// use `WebAudioCapture.startTimeout` (2 s).
    static let firstStartCaptureTimeout: TimeInterval = 4
    /// `WebAudioCapture` reports why a start failed after its own watchdog.
    /// This covers a capture that never answers at all, so it outlasts the
    /// longest watchdog; otherwise it would preempt the capture's report.
    static let startBackstop: TimeInterval = firstStartCaptureTimeout + 2
    /// How long to wait for the finished recording after asking to stop.
    static let stopBackstop: TimeInterval = 5
    static let insertedDisplayDuration: TimeInterval = 1.5
    static let nothingToInsertDisplayDuration: TimeInterval = 3
    /// Matches the macOS overlay's error toast.
    static let errorDisplayDuration: TimeInterval = 6
    static let handoffCheckInterval: TimeInterval = 1
    /// How long an Insert from FreeFlow offer must have been on screen for
    /// hiding the keyboard to end it. A briefer offer keeps its result in the
    /// store for the next keyboard: in CI, Safari showed the keyboard for an
    /// instant on return and dropped it, and iOS stopped that process.
    static let offerReleaseGrace: TimeInterval = 2
    /// Time the app gets to transcribe after its recorder stops.
    static let handoffProcessingMargin: TimeInterval = 120
    /// How long to wait for the app after opening it: as long as its recorder
    /// can run, plus time to transcribe. A delivered result then stays fresh
    /// for `PendingDictation.maxAge`, which the store checks.
    static let handoffWaitLimit: TimeInterval = maximumRecordingDuration + handoffProcessingMargin
    /// Error text is cut to this many characters, like the macOS overlay.
    static let maximumMessageLength = 90

    // MARK: Messages

    static let fieldChangedMessage = "The text field changed, so nothing was inserted. Tap Insert last to add it."
    static let fieldChangedReturnMessage = "The text field changed, so return wasn't pressed."
    /// The app's result was older than `PendingDictation.maxAge` when the
    /// keyboard found it.
    static let handoffExpiredMessage = "The FreeFlow result expired. Tap Insert last to add it."
    static let handoffExpiredEmptyMessage = "The FreeFlow result expired."
    static let interruptedMessage = "Recording stopped unexpectedly. Try again."
    static let fileErrorMessage = "Couldn't save the recording. Try again."
    static let stopTimedOutMessage = "The recording didn't finish. Try again."
    static let genericErrorMessage = "Something went wrong"

    // MARK: State

    enum Gesture: Equatable {
        /// The finger that started dictation is still down and hasn't
        /// reached `holdToTalkThreshold`.
        case pressing(since: Date)
        /// Held past the threshold: hold to talk, so releasing stops.
        case holding
        /// Released quickly: tap to toggle, so the next press stops.
        case latched
    }

    struct Recording: Equatable {
        var attempt: Int
        var startedAt: Date
        /// When the first audio arrived; nil while starting.
        var audioStartedAt: Date?
        var gesture: Gesture
        var documentID: UUID?
    }

    struct Processing: Equatable {
        var attempt: Int
        var stoppedAt: Date
        var documentID: UUID?
        /// Whether audio had started before the stop.
        var heardAudio: Bool
        /// nil until capture delivers the finished recording.
        var audio: KeyboardDictationAudio?
    }

    enum InsertedKind: String, Equatable, CaseIterable {
        case dictation
        case rawFallback
        case returnOnly
        case lastDictation
        case handoff
        /// The Insert from FreeFlow CTA added a result that ended in "press
        /// enter". The CTA inserts text only, so return wasn't pressed.
        case handoffWithoutReturn
    }

    enum NothingReason: String, Equatable, CaseIterable {
        case emptyTranscript
        case noAudio
        case noHistory
        /// The app's result was only "press enter", and the keyboard couldn't
        /// confirm it's the field the user dictated for.
        case returnNotPressed
    }

    enum FallbackReason: String, Equatable, CaseIterable {
        case captureUnavailable
        case lowMemory
        case openFailed
    }

    enum Phase: Equatable {
        case idle
        case setupNeeded(KeyboardDictationSetupIssue)
        case starting(Recording)
        case recording(Recording)
        case processing(Processing)
        case inserted(InsertedKind, until: Date)
        case nothingToInsert(NothingReason, until: Date)
        case error(message: String, until: Date)
        case fallbackAvailable(FallbackReason)
        case waitingForApp(sessionID: UUID, since: Date, nextCheck: Date)
        /// The app handed a result back, but the keyboard isn't sure it's the
        /// same field, so it waits for an explicit tap. Holds the result until
        /// it's inserted or `until` (its freshness deadline) passes.
        case pendingInsert(PendingDictation, until: Date)
    }

    private(set) var phase: Phase
    /// nil until the controller reports setup for the first time.
    private(set) var setup: KeyboardDictationSetup?
    private(set) var isVisible: Bool
    /// Increments with every capture start, so late pipeline results from a
    /// cancelled dictation are recognized and dropped.
    private(set) var attempt: Int
    /// When the Insert from FreeFlow offer last came on screen. Read only
    /// while the offer shows; each arrival and appearance sets it again.
    private(set) var offerShownAt: Date?

    init(
        phase: Phase = .idle,
        setup: KeyboardDictationSetup? = nil,
        isVisible: Bool = false,
        attempt: Int = 0
    ) {
        self.phase = phase
        self.setup = setup
        self.isVisible = isVisible
        self.attempt = attempt
    }

    // MARK: Queries

    /// The recording in progress, while starting or recording.
    var activeRecording: Recording? {
        switch phase {
        case .starting(let recording), .recording(let recording):
            return recording
        case .idle, .setupNeeded, .processing, .inserted, .nothingToInsert, .error,
             .fallbackAvailable, .waitingForApp, .pendingInsert:
            return nil
        }
    }

    /// Capture or processing is under way.
    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .processing:
            return true
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp, .pendingInsert:
            return false
        }
    }

    var isWaitingForApp: Bool {
        waitingSessionID != nil
    }

    /// The session this keyboard waits for, while it waits.
    var waitingSessionID: UUID? {
        if case .waitingForApp(let sessionID, _, _) = phase { return sessionID }
        return nil
    }

    /// The handoff session this keyboard still has a use for in the store:
    /// the one it waits for, or the one whose result it offers with Insert
    /// from FreeFlow. An offered result stays in the store until it is used
    /// or let go, so a keyboard process that iOS stops while offering it
    /// doesn't lose it; the next keyboard finds it and offers it again.
    var handoffSessionID: UUID? {
        switch phase {
        case .waitingForApp(let sessionID, _, _):
            return sessionID
        case .pendingInsert(let pending, _):
            return pending.sessionID
        case .idle, .setupNeeded, .starting, .recording, .processing, .inserted, .nothingToInsert, .error,
             .fallbackAvailable:
            return nil
        }
    }

    /// When the controller should send `.tick` next, if ever.
    var nextWakeUp: Date? {
        switch phase {
        case .starting(let recording):
            let deadlines: [Date?] = [recording.startedAt + Self.startBackstop, holdDeadline(for: recording)]
            return deadlines.compactMap { $0 }.min()
        case .recording(let recording):
            let deadlines: [Date?] = [
                recording.startedAt + Self.maximumRecordingDuration,
                holdDeadline(for: recording),
            ]
            return deadlines.compactMap { $0 }.min()
        case .processing(let processing):
            return processing.audio == nil ? processing.stoppedAt + Self.stopBackstop : nil
        case .inserted(_, let until), .nothingToInsert(_, let until), .error(_, let until):
            return until
        case .waitingForApp(_, let since, let nextCheck):
            let limit = since + Self.handoffWaitLimit
            return isVisible ? min(nextCheck, limit) : limit
        case .pendingInsert(_, let until):
            return until
        case .idle, .setupNeeded, .fallbackAvailable:
            return nil
        }
    }

    // MARK: Reducer

    mutating func handle(_ event: KeyboardDictationEvent, now: Date) -> [KeyboardDictationEffect] {
        switch event {
        case .setupChanged(let newSetup):
            return setupChanged(newSetup)
        case .appeared:
            isVisible = true
            let effects = expireMessageLettingGoOfAnOffer(now: now)
            if case .pendingInsert = phase {
                offerShownAt = now
            }
            return effects
        case .disappeared:
            return disappeared(now: now)
        case .micPressBegan(let documentID):
            return micPressBegan(documentID: documentID, now: now)
        case .micPressEnded:
            return micPressEnded(now: now)
        case .doneTapped:
            return stop(now: now)
        case .cancelTapped:
            return cancel()
        case .openAppTapped(let newSessionID):
            return openApp(newSessionID: newSessionID, now: now)
        case .appOpenFailed:
            return appOpenFailed()
        case .insertLastTapped(let text, let document):
            return insertLast(text: text, document: document, now: now)
        case .captureStarted:
            return captureStarted(now: now)
        case .captureFinished(let audio):
            return captureFinished(audio, now: now)
        case .captureFailed(let failure):
            return captureFailed(failure, now: now)
        case .pipelineFinished(let finishedAttempt, let result, let document):
            return pipelineFinished(attempt: finishedAttempt, result: result, document: document, now: now)
        case .pipelineFailed(let failedAttempt, let message):
            return pipelineFailed(attempt: failedAttempt, message: message, now: now)
        case .handoffResultArrived(let pending, let expectedDocumentID, let document):
            return handoffResultArrived(pending, expectedDocumentID: expectedDocumentID, document: document, now: now)
        case .insertPendingTapped(let document):
            return insertPendingTapped(document: document, now: now)
        case .handoffPending(let sessionID, let openedAt):
            return handoffPending(sessionID: sessionID, openedAt: openedAt, now: now)
        case .handoffAbsent:
            switch phase {
            case .waitingForApp, .pendingInsert:
                // Nothing awaited any more: another keyboard used or let go of
                // the result. An offer here ends too; Insert last has the text.
                phase = restingPhase
                offerShownAt = nil
            case .idle, .setupNeeded, .starting, .recording, .processing, .inserted, .nothingToInsert, .error,
                 .fallbackAvailable:
                break
            }
            return []
        case .tick:
            return tick(now: now)
        }
    }

    // MARK: Helpers shared with the display

    /// One line of at most `maximumMessageLength` characters, cut with an
    /// ellipsis like the macOS overlay's error toast.
    static func displayMessage(_ message: String) -> String {
        let singleLine = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return genericErrorMessage }
        guard singleLine.count > maximumMessageLength else { return singleLine }
        return String(singleLine.prefix(maximumMessageLength - 1)) + "…"
    }

    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only a known identifier that differs counts as a different field.
    static func documentChanged(from start: UUID?, to current: UUID?) -> Bool {
        guard let start, let current else { return false }
        return start != current
    }

    /// A provable field match: both identifiers are known and equal. An
    /// unknown identifier on either side is treated as "not the same field",
    /// so a handed-back result is never auto-inserted on a guess.
    static func documentMatches(expected: UUID?, current: UUID?) -> Bool {
        guard let expected, let current else { return false }
        return expected == current
    }

    // MARK: Transitions

    private var restingPhase: Phase {
        if let issue = setup?.blockingIssue { return .setupNeeded(issue) }
        return .idle
    }

    private var announcement: KeyboardDictationEffect {
        .announce(KeyboardDictationDisplay(machine: self).statusText)
    }

    private var hapticEffects: [KeyboardDictationEffect] {
        setup?.hasFullAccess == true ? [.haptic] : []
    }

    private func holdDeadline(for recording: Recording) -> Date? {
        if case .pressing(let since) = recording.gesture {
            return since + Self.holdToTalkThreshold
        }
        return nil
    }

    private mutating func updateRecording(_ change: (inout Recording) -> Void) {
        switch phase {
        case .starting(var recording):
            change(&recording)
            phase = .starting(recording)
        case .recording(var recording):
            change(&recording)
            phase = .recording(recording)
        case .idle, .setupNeeded, .processing, .inserted, .nothingToInsert, .error,
             .fallbackAvailable, .waitingForApp, .pendingInsert:
            break
        }
    }

    private mutating func expireMessage(now: Date) {
        switch phase {
        case .inserted(_, let until), .nothingToInsert(_, let until), .error(_, let until),
             .pendingInsert(_, let until):
            if now >= until { phase = restingPhase }
        case .idle, .setupNeeded, .starting, .recording, .processing, .fallbackAvailable,
             .waitingForApp:
            break
        }
    }

    /// `expireMessage`, letting go of the store's copy of an Insert from
    /// FreeFlow offer when the offer expires.
    private mutating func expireMessageLettingGoOfAnOffer(now: Date) -> [KeyboardDictationEffect] {
        guard case .pendingInsert(let pending, _) = phase else {
            expireMessage(now: now)
            return []
        }
        expireMessage(now: now)
        if case .pendingInsert = phase {
            return []
        }
        return [.stopAwaitingApp(sessionID: pending.sessionID)]
    }

    private mutating func setupChanged(_ newSetup: KeyboardDictationSetup) -> [KeyboardDictationEffect] {
        setup = newSetup
        switch phase {
        case .idle, .setupNeeded:
            phase = restingPhase
        case .starting, .recording, .processing, .inserted, .nothingToInsert, .error,
             .fallbackAvailable, .waitingForApp, .pendingInsert:
            break
        }
        return []
    }

    private mutating func disappeared(now: Date) -> [KeyboardDictationEffect] {
        isVisible = false
        let offerShown = offerShownAt
        offerShownAt = nil
        switch phase {
        case .starting, .recording:
            phase = restingPhase
            return [.cancelCapture]
        case .processing(let processing):
            // A finished recording keeps processing; its result is kept for
            // Insert last because the field is gone.
            guard processing.audio == nil else { return [] }
            phase = restingPhase
            return [.cancelCapture]
        case .pendingInsert(let pending, _):
            // Seen and left: the offer ends and its result leaves the store,
            // so it doesn't come back in another app later. Insert last has
            // the text. An offer gone almost at once keeps it for the next
            // keyboard (`offerReleaseGrace`).
            guard let shownAt = offerShown, now.timeIntervalSince(shownAt) >= Self.offerReleaseGrace else {
                return []
            }
            phase = restingPhase
            return [.stopAwaitingApp(sessionID: pending.sessionID)]
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp:
            return []
        }
    }

    private mutating func micPressBegan(documentID: UUID?, now: Date) -> [KeyboardDictationEffect] {
        if let recording = activeRecording {
            // A press while holding is a second finger, so only a latched
            // (tapped) recording stops here.
            return recording.gesture == .latched ? stop(now: now) : []
        }
        if case .processing = phase { return [] }
        guard let setup else { return [] }

        // A press that can't record doesn't replace a dictation the app is
        // still recording, or a result it offers: keep it and only say why.
        if let issue = setup.blockingIssue {
            if handoffSessionID != nil {
                return [.announce(KeyboardDictationDisplay.setupText(for: issue))]
            }
            phase = .setupNeeded(issue)
            return [announcement]
        }
        guard setup.hasMemoryToRecord else {
            if handoffSessionID != nil {
                return [.announce(KeyboardDictationDisplay.fallbackText(for: .lowMemory))]
            }
            phase = .fallbackAvailable(.lowMemory)
            return [announcement]
        }

        let replacedHandoff = handoffSessionID
        attempt += 1
        phase = .starting(Recording(
            attempt: attempt,
            startedAt: now,
            audioStartedAt: nil,
            gesture: .pressing(since: now),
            documentID: documentID
        ))
        if let replacedHandoff {
            return [.stopAwaitingApp(sessionID: replacedHandoff), .startCapture]
        }
        return [.startCapture]
    }

    private mutating func micPressEnded(now: Date) -> [KeyboardDictationEffect] {
        guard let recording = activeRecording else { return [] }
        switch recording.gesture {
        case .pressing(let since):
            if now.timeIntervalSince(since) >= Self.holdToTalkThreshold {
                return stop(now: now)
            }
            updateRecording { $0.gesture = .latched }
            return []
        case .holding:
            return stop(now: now)
        case .latched:
            return []
        }
    }

    private mutating func stop(now: Date) -> [KeyboardDictationEffect] {
        guard let recording = activeRecording else { return [] }
        phase = .processing(Processing(
            attempt: recording.attempt,
            stoppedAt: now,
            documentID: recording.documentID,
            heardAudio: recording.audioStartedAt != nil,
            audio: nil
        ))
        return hapticEffects + [.stopCapture]
    }

    private mutating func cancel() -> [KeyboardDictationEffect] {
        switch phase {
        case .starting, .recording:
            phase = restingPhase
            return [.cancelCapture]
        case .processing(let processing):
            phase = restingPhase
            if let audio = processing.audio {
                return [.cancelPipeline, .deleteAudio(audio.fileURL)]
            }
            return [.cancelCapture]
        case .waitingForApp(let sessionID, _, _):
            phase = restingPhase
            return [.stopAwaitingApp(sessionID: sessionID)]
        case .pendingInsert(let pending, _):
            // Dismiss. The held result was remembered for Insert last when it
            // arrived, so Insert last can still add it, even with Keep History
            // off; the copy in the store goes.
            phase = restingPhase
            return [.stopAwaitingApp(sessionID: pending.sessionID)]
        case .fallbackAvailable, .inserted, .nothingToInsert, .error:
            phase = restingPhase
            return []
        case .idle, .setupNeeded:
            return []
        }
    }

    private mutating func openApp(newSessionID: UUID, now: Date) -> [KeyboardDictationEffect] {
        let sessionID: UUID
        switch phase {
        case .fallbackAvailable:
            sessionID = newSessionID
        case .waitingForApp(let waitingSessionID, _, _):
            sessionID = waitingSessionID
        case .idle, .setupNeeded, .starting, .recording, .processing, .inserted, .nothingToInsert,
             .error, .pendingInsert:
            return []
        }
        phase = .waitingForApp(sessionID: sessionID, since: now, nextCheck: now + Self.handoffCheckInterval)
        return [.openApp(sessionID: sessionID)]
    }

    private mutating func appOpenFailed() -> [KeyboardDictationEffect] {
        guard let sessionID = waitingSessionID else { return [] }
        phase = .fallbackAvailable(.openFailed)
        return [.stopAwaitingApp(sessionID: sessionID), announcement]
    }

    private mutating func insertLast(
        text: String?,
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard !isBusy else { return [] }
        // Choosing Insert last ends the wait, so a late handoff result can't
        // be inserted on top of what the user just inserted.
        var effects: [KeyboardDictationEffect] = handoffSessionID.map { [.stopAwaitingApp(sessionID: $0)] } ?? []

        guard let text, Self.hasContent(text) else {
            phase = .nothingToInsert(.noHistory, until: now + Self.nothingToInsertDisplayDuration)
            effects.append(announcement)
            return effects
        }
        effects.append(.insert(TranscriptRouting.insertionText(for: text, precedingText: document.textBeforeCursor)))
        phase = .inserted(.lastDictation, until: now + Self.insertedDisplayDuration)
        effects.append(announcement)
        return effects
    }

    private mutating func captureStarted(now: Date) -> [KeyboardDictationEffect] {
        guard case .starting(var recording) = phase else { return [] }
        recording.audioStartedAt = now
        phase = .recording(recording)
        return hapticEffects + [.reportCapture(worked: true, failure: nil)]
    }

    private mutating func captureFinished(_ audio: KeyboardDictationAudio, now: Date) -> [KeyboardDictationEffect] {
        switch phase {
        case .processing(var processing):
            if let current = processing.audio {
                // A repeated callback must not delete the file being uploaded.
                return current.fileURL == audio.fileURL ? [] : [.deleteAudio(audio.fileURL)]
            }
            processing.audio = audio
            phase = .processing(processing)
            return [.runPipeline(attempt: processing.attempt, audioFileURL: audio.fileURL)]
        case .starting(let recording), .recording(let recording):
            // Capture ended by itself but kept what it recorded.
            phase = .processing(Processing(
                attempt: recording.attempt,
                stoppedAt: now,
                documentID: recording.documentID,
                heardAudio: recording.audioStartedAt != nil,
                audio: audio
            ))
            return [.runPipeline(attempt: recording.attempt, audioFileURL: audio.fileURL)]
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp, .pendingInsert:
            return [.deleteAudio(audio.fileURL)]
        }
    }

    private mutating func captureFailed(
        _ failure: KeyboardDictationCaptureFailure,
        now: Date
    ) -> [KeyboardDictationEffect] {
        let heardAudio: Bool
        switch phase {
        case .starting:
            heardAudio = false
        case .recording:
            heardAudio = true
        case .processing(let processing):
            guard processing.audio == nil else { return [] }
            heardAudio = processing.heardAudio
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp, .pendingInsert:
            return []
        }

        switch failure {
        case .pageUnavailable, .startTimedOut, .unsupported:
            phase = .fallbackAvailable(.captureUnavailable)
        case .permissionDenied:
            phase = .setupNeeded(.microphone)
        case .interrupted:
            if heardAudio {
                phase = .error(message: Self.interruptedMessage, until: now + Self.errorDisplayDuration)
            } else {
                phase = .fallbackAvailable(.captureUnavailable)
            }
        case .noAudio:
            phase = .nothingToInsert(.noAudio, until: now + Self.nothingToInsertDisplayDuration)
        case .fileError:
            phase = .error(message: Self.fileErrorMessage, until: now + Self.errorDisplayDuration)
        }

        var effects: [KeyboardDictationEffect] = []
        if failure != .noAudio {
            effects.append(.reportCapture(worked: heardAudio, failure: failure))
        }
        effects.append(announcement)
        return effects
    }

    private func historyDraft(
        _ status: HistoryEntry.Status,
        result: DictationResult,
        audio: KeyboardDictationAudio,
        now: Date
    ) -> KeyboardDictationHistoryDraft {
        KeyboardDictationHistoryDraft(
            createdAt: now,
            status: status,
            rawTranscript: result.rawTranscript,
            text: result.text,
            route: result.route,
            errorMessage: nil,
            durationSeconds: audio.duration,
            usedRawFallback: result.usedRawFallback
        )
    }

    private mutating func pipelineFinished(
        attempt finishedAttempt: Int,
        result: DictationResult,
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard case .processing(let processing) = phase,
              processing.attempt == finishedAttempt,
              let audio = processing.audio else {
            return []
        }
        var effects: [KeyboardDictationEffect] = [.deleteAudio(audio.fileURL)]
        let hasText = Self.hasContent(result.text)

        guard hasText || result.pressEnter else {
            effects.append(.recordHistory(historyDraft(.nothingToInsert, result: result, audio: audio, now: now)))
            phase = .nothingToInsert(.emptyTranscript, until: now + Self.nothingToInsertDisplayDuration)
            effects.append(announcement)
            return effects
        }

        if !isVisible || Self.documentChanged(from: processing.documentID, to: document.identifier) {
            effects.append(.recordHistory(historyDraft(.notInserted, result: result, audio: audio, now: now)))
            if hasText {
                effects.append(.rememberForInsertLast(text: result.text, at: now))
            }
            let message = hasText ? Self.fieldChangedMessage : Self.fieldChangedReturnMessage
            phase = .error(message: message, until: now + Self.errorDisplayDuration)
            effects.append(announcement)
            return effects
        }

        if hasText {
            effects.append(.insert(TranscriptRouting.insertionText(
                for: result.text,
                precedingText: document.textBeforeCursor
            )))
        }
        if result.pressEnter {
            effects.append(.insert("\n"))
        }
        // The rule the app's recorder uses too: return alone inserted no text.
        let status = HistoryEntry.Status.forInsertion(of: result)
        effects.append(.recordHistory(historyDraft(status, result: result, audio: audio, now: now)))
        if hasText {
            effects.append(.rememberForInsertLast(text: result.text, at: now))
        }

        let kind: InsertedKind
        if !hasText {
            kind = .returnOnly
        } else if result.usedRawFallback {
            kind = .rawFallback
        } else {
            kind = .dictation
        }
        phase = .inserted(kind, until: now + Self.insertedDisplayDuration)
        effects.append(announcement)
        return effects
    }

    private mutating func pipelineFailed(
        attempt failedAttempt: Int,
        message: String,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard case .processing(let processing) = phase,
              processing.attempt == failedAttempt,
              let audio = processing.audio else {
            return []
        }
        let shown = Self.displayMessage(message)
        phase = .error(message: shown, until: now + Self.errorDisplayDuration)
        let draft = KeyboardDictationHistoryDraft(
            createdAt: now,
            status: .failed,
            rawTranscript: "",
            text: "",
            route: nil,
            errorMessage: shown,
            durationSeconds: audio.duration
        )
        return [.deleteAudio(audio.fileURL), .recordHistory(draft), announcement]
    }

    private mutating func handoffResultArrived(
        _ pending: PendingDictation,
        expectedDocumentID: UUID?,
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard !isBusy else { return [] }
        // The check reads the result without removing it, so a keyboard that
        // iOS stops before it acts loses nothing. Every outcome but the offer
        // below is final, so it lets go of the session and its result.
        var effects: [KeyboardDictationEffect] = [.stopAwaitingApp(sessionID: pending.sessionID)]
        let hasText = Self.hasContent(pending.text)

        guard pending.isFresh(now: now) else {
            // Too old to insert on its own. End the wait now and say so,
            // instead of waiting for a result that was already used up. The
            // text stays in memory for Insert last, even with Keep History off.
            if hasText {
                effects.append(.rememberForInsertLast(text: pending.text, at: now))
            }
            let message = hasText ? Self.handoffExpiredMessage : Self.handoffExpiredEmptyMessage
            phase = .error(message: message, until: now + Self.errorDisplayDuration)
            effects.append(announcement)
            return effects
        }

        // Auto-insert only into the same field the keyboard opened the app
        // from, and only there press return for "press enter".
        if Self.documentMatches(expected: expectedDocumentID, current: document.identifier) {
            return effects + performHandoffInsertion(pending, pressEnter: pending.pressEnter, document: document, now: now)
        }
        // A field the keyboard can't confirm. With no text there is nothing to
        // offer: return alone could submit a field the user didn't dictate
        // for.
        guard hasText else {
            let reason: NothingReason = pending.pressEnter ? .returnNotPressed : .emptyTranscript
            phase = .nothingToInsert(reason, until: now + Self.nothingToInsertDisplayDuration)
            effects.append(announcement)
            return effects
        }
        // Hold the text for an explicit tap, so it never lands in a field the
        // user didn't dictate into. Remember it now: after Dismiss, expiry or
        // a new dictation, Insert last can still add it. The result stays in
        // the store, still awaited, until the tap, Dismiss, a new dictation,
        // Insert last, expiry or hiding the keyboard once the offer has shown
        // for `offerReleaseGrace` lets it go, so a keyboard that iOS stops
        // while offering it doesn't lose it.
        phase = .pendingInsert(pending, until: pending.createdAt + PendingDictation.maxAge)
        offerShownAt = isVisible ? now : nil
        return [.rememberForInsertLast(text: pending.text, at: now), announcement]
    }

    private mutating func insertPendingTapped(
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard case .pendingInsert(let pending, _) = phase else { return [] }
        let letGo = KeyboardDictationEffect.stopAwaitingApp(sessionID: pending.sessionID)
        guard pending.isFresh(now: now) else {
            phase = restingPhase
            return [letGo]
        }
        // The tap is the user's consent to insert the text into the current
        // field, but not to press return in it. The store's copy goes after
        // the text is in, so a keyboard stopped in between offers it again
        // rather than losing it.
        return performHandoffInsertion(pending, pressEnter: false, document: document, now: now) + [letGo]
    }

    /// Inserts a handoff result and moves to `inserted`. `pressEnter` is
    /// whether to press return after the text; only a confirmed field gets
    /// it. Sets the phase before reading `announcement` so the announcement
    /// reflects the new state.
    private mutating func performHandoffInsertion(
        _ pending: PendingDictation,
        pressEnter: Bool,
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        let hasText = Self.hasContent(pending.text)
        guard hasText || pressEnter else {
            phase = .nothingToInsert(.emptyTranscript, until: now + Self.nothingToInsertDisplayDuration)
            return [announcement]
        }

        var effects: [KeyboardDictationEffect] = []
        if hasText {
            effects.append(.insert(TranscriptRouting.insertionText(
                for: pending.text,
                precedingText: document.textBeforeCursor
            )))
        }
        if pressEnter {
            effects.append(.insert("\n"))
        }
        if hasText {
            effects.append(.rememberForInsertLast(text: pending.text, at: now))
        }
        let kind: InsertedKind
        if !hasText {
            kind = .returnOnly
        } else if pending.pressEnter && !pressEnter {
            kind = .handoffWithoutReturn
        } else {
            kind = .handoff
        }
        phase = .inserted(kind, until: now + Self.insertedDisplayDuration)
        effects.append(announcement)
        return effects
    }

    private mutating func handoffPending(
        sessionID: UUID,
        openedAt: Date?,
        now: Date
    ) -> [KeyboardDictationEffect] {
        switch phase {
        case .waitingForApp(let waitingSessionID, let since, _) where waitingSessionID == sessionID:
            phase = .waitingForApp(sessionID: sessionID, since: since, nextCheck: now + Self.handoffCheckInterval)
            return []
        case .starting, .recording, .processing, .pendingInsert:
            // A result is already held or capture is under way; don't adopt.
            return []
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp:
            // Another keyboard process may have opened the app; count from
            // then when known, and let go of sessions that have long ended.
            let since = openedAt ?? now
            guard now.timeIntervalSince(since) < Self.handoffWaitLimit else {
                if isWaitingForApp { phase = restingPhase }
                return [.stopAwaitingApp(sessionID: sessionID)]
            }
            phase = .waitingForApp(sessionID: sessionID, since: since, nextCheck: now + Self.handoffCheckInterval)
            return []
        }
    }

    private mutating func tick(now: Date) -> [KeyboardDictationEffect] {
        switch phase {
        case .starting(let recording) where now.timeIntervalSince(recording.startedAt) >= Self.startBackstop:
            phase = .fallbackAvailable(.captureUnavailable)
            return [.cancelCapture, .reportCapture(worked: false, failure: .startTimedOut), announcement]
        case .starting(let recording), .recording(let recording):
            if now.timeIntervalSince(recording.startedAt) >= Self.maximumRecordingDuration {
                return stop(now: now)
            }
            if case .pressing(let since) = recording.gesture,
               now.timeIntervalSince(since) >= Self.holdToTalkThreshold {
                updateRecording { $0.gesture = .holding }
            }
            return []
        case .processing(let processing):
            guard processing.audio == nil,
                  now.timeIntervalSince(processing.stoppedAt) >= Self.stopBackstop else {
                return []
            }
            phase = .error(message: Self.stopTimedOutMessage, until: now + Self.errorDisplayDuration)
            return [.cancelCapture, announcement]
        case .inserted, .nothingToInsert, .error, .pendingInsert:
            return expireMessageLettingGoOfAnOffer(now: now)
        case .waitingForApp(let sessionID, let since, let nextCheck):
            if now.timeIntervalSince(since) >= Self.handoffWaitLimit {
                phase = restingPhase
                return [.stopAwaitingApp(sessionID: sessionID)]
            }
            guard isVisible, now >= nextCheck else { return [] }
            phase = .waitingForApp(sessionID: sessionID, since: since, nextCheck: now + Self.handoffCheckInterval)
            return [.checkForAppResult]
        case .idle, .setupNeeded, .fallbackAvailable:
            return []
        }
    }
}
