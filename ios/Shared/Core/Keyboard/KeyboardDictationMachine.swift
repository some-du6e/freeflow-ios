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

    func makeEntry(id: UUID = UUID()) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: createdAt,
            source: .keyboard,
            status: status,
            rawTranscript: rawTranscript,
            text: text,
            route: route,
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
    /// `PendingDictationStore.take` returned the app's result.
    case handoffResultArrived(PendingDictation, document: KeyboardDictationDocument)
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
    /// Clear `PendingDictationStore.awaitedSessionID`.
    case stopAwaitingApp
    /// Ask `PendingDictationStore` whether the app's result has arrived.
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
    /// `WebAudioCapture` reports `.startTimedOut` after its own 2 s watchdog.
    /// This covers a capture that never answers at all.
    static let startBackstop: TimeInterval = 4
    /// How long to wait for the finished recording after asking to stop.
    static let stopBackstop: TimeInterval = 5
    static let insertedDisplayDuration: TimeInterval = 1.5
    static let nothingToInsertDisplayDuration: TimeInterval = 3
    /// Matches the macOS overlay's error toast.
    static let errorDisplayDuration: TimeInterval = 6
    static let handoffCheckInterval: TimeInterval = 1
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
    }

    enum NothingReason: String, Equatable, CaseIterable {
        case emptyTranscript
        case noAudio
        case noHistory
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
    }

    private(set) var phase: Phase
    /// nil until the controller reports setup for the first time.
    private(set) var setup: KeyboardDictationSetup?
    private(set) var isVisible: Bool
    /// Increments with every capture start, so late pipeline results from a
    /// cancelled dictation are recognized and dropped.
    private(set) var attempt: Int

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
             .fallbackAvailable, .waitingForApp:
            return nil
        }
    }

    /// Capture or processing is under way.
    var isBusy: Bool {
        switch phase {
        case .starting, .recording, .processing:
            return true
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp:
            return false
        }
    }

    var isWaitingForApp: Bool {
        if case .waitingForApp = phase { return true }
        return false
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
            expireMessage(now: now)
            return []
        case .disappeared:
            return disappeared()
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
        case .handoffResultArrived(let pending, let document):
            return handoffResultArrived(pending, document: document, now: now)
        case .handoffPending(let sessionID, let openedAt):
            return handoffPending(sessionID: sessionID, openedAt: openedAt, now: now)
        case .handoffAbsent:
            if case .waitingForApp = phase { phase = restingPhase }
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
             .fallbackAvailable, .waitingForApp:
            break
        }
    }

    private mutating func expireMessage(now: Date) {
        switch phase {
        case .inserted(_, let until), .nothingToInsert(_, let until), .error(_, let until):
            if now >= until { phase = restingPhase }
        case .idle, .setupNeeded, .starting, .recording, .processing, .fallbackAvailable,
             .waitingForApp:
            break
        }
    }

    private mutating func setupChanged(_ newSetup: KeyboardDictationSetup) -> [KeyboardDictationEffect] {
        setup = newSetup
        switch phase {
        case .idle, .setupNeeded:
            phase = restingPhase
        case .starting, .recording, .processing, .inserted, .nothingToInsert, .error,
             .fallbackAvailable, .waitingForApp:
            break
        }
        return []
    }

    private mutating func disappeared() -> [KeyboardDictationEffect] {
        isVisible = false
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
        // still recording: keep waiting and only say why.
        if let issue = setup.blockingIssue {
            if isWaitingForApp {
                return [.announce(KeyboardDictationDisplay.setupText(for: issue))]
            }
            phase = .setupNeeded(issue)
            return [announcement]
        }
        guard setup.hasMemoryToRecord else {
            if isWaitingForApp {
                return [.announce(KeyboardDictationDisplay.fallbackText(for: .lowMemory))]
            }
            phase = .fallbackAvailable(.lowMemory)
            return [announcement]
        }

        let replacesHandoff = isWaitingForApp
        attempt += 1
        phase = .starting(Recording(
            attempt: attempt,
            startedAt: now,
            audioStartedAt: nil,
            gesture: .pressing(since: now),
            documentID: documentID
        ))
        return replacesHandoff ? [.stopAwaitingApp, .startCapture] : [.startCapture]
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
        case .waitingForApp:
            phase = restingPhase
            return [.stopAwaitingApp]
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
             .error:
            return []
        }
        phase = .waitingForApp(sessionID: sessionID, since: now, nextCheck: now + Self.handoffCheckInterval)
        return [.openApp(sessionID: sessionID)]
    }

    private mutating func appOpenFailed() -> [KeyboardDictationEffect] {
        guard case .waitingForApp = phase else { return [] }
        phase = .fallbackAvailable(.openFailed)
        return [.stopAwaitingApp, announcement]
    }

    private mutating func insertLast(
        text: String?,
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard !isBusy else { return [] }
        // Choosing Insert last ends the wait, so a late handoff result can't
        // be inserted on top of what the user just inserted.
        var effects: [KeyboardDictationEffect] = isWaitingForApp ? [.stopAwaitingApp] : []

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
             .waitingForApp:
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
             .waitingForApp:
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
            durationSeconds: audio.duration
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
        // The same statuses as the pipeline's HistoryEntry.Status.forInsertion:
        // return alone inserted no text.
        let status: HistoryEntry.Status
        if !hasText {
            status = .nothingToInsert
        } else {
            status = result.usedRawFallback ? .rawFallback : .inserted
        }
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
        document: KeyboardDictationDocument,
        now: Date
    ) -> [KeyboardDictationEffect] {
        guard !isBusy else { return [] }
        var effects: [KeyboardDictationEffect] = [.stopAwaitingApp]

        guard pending.isFresh(now: now) else {
            if case .waitingForApp = phase { phase = restingPhase }
            return effects
        }
        let hasText = Self.hasContent(pending.text)
        guard hasText || pending.pressEnter else {
            phase = .nothingToInsert(.emptyTranscript, until: now + Self.nothingToInsertDisplayDuration)
            effects.append(announcement)
            return effects
        }

        if hasText {
            effects.append(.insert(TranscriptRouting.insertionText(
                for: pending.text,
                precedingText: document.textBeforeCursor
            )))
        }
        if pending.pressEnter {
            effects.append(.insert("\n"))
        }
        if hasText {
            effects.append(.rememberForInsertLast(text: pending.text, at: now))
        }
        phase = .inserted(hasText ? .handoff : .returnOnly, until: now + Self.insertedDisplayDuration)
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
        case .starting, .recording, .processing:
            return []
        case .idle, .setupNeeded, .inserted, .nothingToInsert, .error, .fallbackAvailable,
             .waitingForApp:
            // Another keyboard process may have opened the app; count from
            // then when known, and let go of sessions that have long ended.
            let since = openedAt ?? now
            guard now.timeIntervalSince(since) < Self.handoffWaitLimit else {
                if isWaitingForApp { phase = restingPhase }
                return [.stopAwaitingApp]
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
        case .inserted, .nothingToInsert, .error:
            expireMessage(now: now)
            return []
        case .waitingForApp(let sessionID, let since, let nextCheck):
            if now.timeIntervalSince(since) >= Self.handoffWaitLimit {
                phase = restingPhase
                return [.stopAwaitingApp]
            }
            guard isVisible, now >= nextCheck else { return [] }
            phase = .waitingForApp(sessionID: sessionID, since: since, nextCheck: now + Self.handoffCheckInterval)
            return [.checkForAppResult]
        case .idle, .setupNeeded, .fallbackAvailable:
            return []
        }
    }
}
