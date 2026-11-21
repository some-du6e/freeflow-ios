import Foundation
import UIKit

enum RecorderMode: Equatable {
    /// "Try without the keyboard": the result goes into the app's test field.
    case inApp
    /// The keyboard's fallback (DESIGN §5.4): the result is saved for the
    /// keyboard that opened `freeflow://dictate?session=<uuid>`.
    case handoff(sessionID: UUID)

    var sessionID: UUID? {
        if case .handoff(let sessionID) = self {
            return sessionID
        }
        return nil
    }
}

struct RecorderOutcome: Equatable {
    var text: String
    var rawTranscript: String
    var pressEnter: Bool
    var route: DictationRoute
    var usedRawFallback: Bool
    /// Saved for the keyboard rather than inserted in the app.
    var handedOff: Bool
    /// A keyboard handoff the keyboard is no longer waiting for (or never
    /// was), so the result was saved nowhere and is only shown, with Copy.
    var keyboardStoppedWaiting = false

    /// Nothing to type: no text and no "press enter".
    var isNothingToInsert: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pressEnter
    }
}

enum RecorderRetry: Equatable {
    /// Record again from the start.
    case recordAgain
    /// Send the same recording through the pipeline again.
    case processAgain
}

enum RecorderPhase: Equatable {
    case idle
    /// The permission was never asked; show the "Continue" pre-prompt.
    case needsPermission
    case requestingPermission
    case permissionDenied
    /// No usable API key.
    case setupNeeded
    /// The data-sharing consent isn't given in this install, so nothing may
    /// record or reach the provider (App Review 5.1.2(i)). A reinstall clears
    /// the consent with the App Group but can keep the API key in the
    /// keychain.
    case consentNeeded
    /// Waiting for the first audio.
    case starting
    case recording
    case processing
    case finished(RecorderOutcome)
    case failed(message: String, retry: RecorderRetry)

    /// The machine-readable state that `freeflow.recorder.status` exposes
    /// as its accessibility value, for UI tests.
    var accessibilityName: String {
        switch self {
        case .idle: "idle"
        case .needsPermission, .requestingPermission: "needs-permission"
        case .permissionDenied: "permission-denied"
        case .setupNeeded: "setup-needed"
        case .consentNeeded: "consent-needed"
        case .starting: "starting"
        case .recording: "recording"
        case .processing: "processing"
        case .finished(let outcome):
            if outcome.isNothingToInsert {
                "nothing-to-insert"
            } else if outcome.handedOff {
                "handed-off"
            } else if outcome.keyboardStoppedWaiting {
                "not-handed-off"
            } else {
                "done"
            }
        case .failed: "error"
        }
    }
}

/// Everything the recorder touches outside itself; `live` is the real app.
struct RecorderDependencies {
    var configuration: () -> DictationConfiguration?
    /// Whether the user agreed to the data-sharing page in onboarding
    /// (`FreeFlowAppEnvironment.hasDataSharingConsent`).
    var hasConsent: () -> Bool
    var microphone: AppMicrophoneAccess
    /// Records that the app holds microphone permission, for the keyboard.
    var markMicrophoneGranted: () -> Void
    var makeRecorder: () -> AppAudioRecording
    var makeRecordingURL: () -> URL
    var process: (URL, DictationConfiguration) async throws -> DictationResult
    var appendHistory: (HistoryEntry) -> Void
    var savePendingDictation: (PendingDictation) -> Void
    var awaitedSessionID: () -> UUID?
    var clearAwaitedSessionID: () -> Void
    var isOnline: () -> Bool
    var now: () -> Date
    var removeFile: (URL) -> Void
    /// Keeps the app running while a result finishes processing after the
    /// user leaves; returns the function that ends it.
    var beginBackgroundWork: @MainActor () -> (@MainActor () -> Void)
    /// No audio within this long fails the start, like the macOS watchdog.
    var startTimeout: TimeInterval = 2
    /// Recording stops on its own after this long, like the keyboard.
    var maximumDuration: TimeInterval = 300

    static func live(environment: FreeFlowAppEnvironment) -> RecorderDependencies {
        let settings = environment.settings
        let pendingDictations = environment.pendingDictations
        let history = environment.history
        #if DEBUG
        let usesSyntheticInput = settings.bool(FreeFlowAppSettingKey.debugSyntheticCapture, default: false)
        #else
        let usesSyntheticInput = false
        #endif
        return RecorderDependencies(
            configuration: { settings.dictationConfiguration() },
            hasConsent: { environment.hasDataSharingConsent },
            microphone: environment.microphone,
            markMicrophoneGranted: {
                if !settings.microphonePermissionGranted {
                    settings.microphonePermissionGranted = true
                }
            },
            makeRecorder: { AppAudioRecorder(usesSyntheticInput: usesSyntheticInput) },
            makeRecordingURL: { AppAudioRecorder.makeRecordingURL() },
            process: { audioFileURL, configuration in
                try await DictationPipeline().run(audioFileURL: audioFileURL, configuration: configuration)
            },
            appendHistory: { history.append($0) },
            savePendingDictation: { pendingDictations.save($0) },
            awaitedSessionID: { pendingDictations.awaitedSessionID },
            clearAwaitedSessionID: { pendingDictations.awaitedSessionID = nil },
            isOnline: { NetworkMonitor.shared.isOnline },
            now: { Date() },
            removeFile: { try? FileManager.default.removeItem(at: $0) },
            beginBackgroundWork: {
                let work = AppBackgroundWork()
                work.begin()
                return { work.end() }
            }
        )
    }
}

/// A UIKit background task, so processing can finish after the user swipes
/// back to the app they were dictating into.
@MainActor
final class AppBackgroundWork {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "FreeFlow dictation") { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Records with the app's microphone permission and runs the shared pipeline.
/// For a keyboard handoff it saves the result for the keyboard, while the
/// keyboard still waits for that session, and writes a `.handedOff` history
/// entry; otherwise it inserts into the test field.
@MainActor
final class RecorderModel: ObservableObject, Identifiable {
    static let startFailedMessage = "Couldn't start recording. Try again."
    /// macOS: AudioRecorderError.noAudioBuffersReceived.
    static let noAudioBuffersMessage = "No audio buffers were received from the microphone."
    /// macOS wording for a recording with no frames.
    static let noAudioRecordedMessage = "No audio recorded"
    /// Top bar captions: who the recording is for.
    static let inAppCaption = "Dictate without the keyboard"
    static let keyboardCaption = "Dictating for the FreeFlow keyboard"
    /// A `freeflow://` link the keyboard didn't ask for opened the recorder.
    static let linkCaption = "Opened from a link"

    // Identifiable through the default `ObjectIdentifier` id, which is
    // nonisolated; the app presents one recorder object per session.
    @Published private(set) var phase: RecorderPhase = .idle
    /// Fixed for the recorder's life: a newer keyboard session gets a new
    /// recorder, never this one's recording.
    let mode: RecorderMode
    /// Waveform level in 0...1.
    @Published private(set) var level: Float = 0
    @Published private(set) var recordingStartedAt: Date?

    /// Set by the app model for in-app recordings.
    var onInsertIntoTestField: (@MainActor (String, Bool) -> Void)?
    /// Whether recording starts as soon as the recorder appears. Only a tap
    /// in FreeFlow or the keyboard's awaited session start it; a recorder
    /// any other `freeflow://` link opened waits idle for its Start button.
    let startsOnAppear: Bool
    /// Whether the keyboard asked for this recording: it awaited the session
    /// when the recorder opened, or reopened FreeFlow for it since. A
    /// recorder any other link opened isn't, until then.
    @Published private(set) var isForWaitingKeyboard: Bool

    private let dependencies: RecorderDependencies
    private var recorder: AppAudioRecording?
    /// The finished recording, kept until it is processed or the recorder
    /// closes, so a failed upload can be retried.
    private var recordingURL: URL?
    private var recordedDuration: TimeInterval = 0
    private var processingTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var hasStarted = false
    private var isClosed = false
    /// Bumped whenever a recording or a processing run starts or the
    /// recorder closes, so late callbacks from an older one are ignored.
    private var generation = 0

    init(mode: RecorderMode, dependencies: RecorderDependencies, startsOnAppear: Bool) {
        self.mode = mode
        self.dependencies = dependencies
        self.startsOnAppear = startsOnAppear
        self.isForWaitingKeyboard = mode.sessionID != nil && startsOnAppear
    }

    /// The top bar's caption. Only a recording the keyboard asked for says
    /// it is for the keyboard; one that went to the keyboard anyway (it
    /// started waiting for the session after all) does too.
    var topBarCaption: String {
        guard mode.sessionID != nil else { return Self.inAppCaption }
        if isForWaitingKeyboard {
            return Self.keyboardCaption
        }
        if case .finished(let outcome) = phase, outcome.handedOff {
            return Self.keyboardCaption
        }
        return Self.linkCaption
    }

    /// Recording, processing, or waiting on the permission prompt.
    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .starting, .recording, .processing:
            true
        default:
            false
        }
    }

    var canStop: Bool {
        phase == .starting || phase == .recording
    }

    /// Called when the recorder appears. Starts once if `startsOnAppear`;
    /// otherwise it stays idle until `start()`.
    func startIfNeeded() {
        guard startsOnAppear else { return }
        start()
    }

    /// The idle recorder's Start button, and the start on appear.
    func start() {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true
        // The keyboard's App Group write can arrive after the link was
        // checked; if it now waits for this session, the recording is its.
        if let sessionID = mode.sessionID, dependencies.awaitedSessionID() == sessionID {
            isForWaitingKeyboard = true
        }
        begin()
    }

    /// The keyboard reopened the app for this recorder's session and is
    /// still waiting for it: start a recorder that was waiting for a tap, or
    /// give a failed recording another try.
    func resumeForAwaitedSession() {
        if mode.sessionID != nil {
            isForWaitingKeyboard = true
        }
        switch phase {
        case .idle:
            start()
        case .failed:
            retry()
        default:
            break
        }
    }

    /// The pre-prompt's "Continue" button (App Review 5.1.1(iv)).
    func requestMicrophonePermission() async {
        guard phase == .needsPermission else { return }
        phase = .requestingPermission
        let granted = await dependencies.microphone.requestPermission()
        guard phase == .requestingPermission, !isClosed else { return }
        if granted {
            dependencies.markMicrophoneGranted()
            startRecording()
        } else {
            phase = .permissionDenied
        }
    }

    func stop() {
        guard canStop, let recorder else { return }
        cancelTimers()
        self.recorder = nil
        level = 0
        guard let summary = recorder.stop() else {
            phase = .failed(message: Self.noAudioRecordedMessage, retry: .recordAgain)
            return
        }
        recordingURL = summary.fileURL
        recordedDuration = summary.duration
        process()
    }

    func retry() {
        guard case .failed(_, let retry) = phase else { return }
        switch retry {
        case .recordAgain:
            discardRecording()
            begin()
        case .processAgain:
            process()
        }
    }

    /// Cancel and Done both end here. Discards any recording in progress and
    /// the audio file. A handoff that never produced a result tells the
    /// keyboard to stop waiting by clearing its awaited session.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1
        cancelTimers()
        processingTask?.cancel()
        processingTask = nil
        recorder?.cancel()
        recorder = nil
        level = 0
        discardRecording()

        var delivered = false
        if case .finished(let outcome) = phase {
            delivered = outcome.handedOff
        }
        if !delivered, let sessionID = mode.sessionID, dependencies.awaitedSessionID() == sessionID {
            dependencies.clearAwaitedSessionID()
        }
    }

    /// The app has no background audio mode, so leaving the app ends the
    /// recording. Process what was said rather than lose it.
    func appDidEnterBackground() {
        if canStop {
            stop()
        }
    }

    // MARK: Recording

    private func begin() {
        guard !isClosed else { return }
        // Before the microphone prompt too: nothing records until setup's
        // consent page has been agreed to.
        guard dependencies.hasConsent() else {
            phase = .consentNeeded
            return
        }
        guard dependencies.configuration() != nil else {
            phase = .setupNeeded
            return
        }
        switch dependencies.microphone.permission {
        case .granted:
            dependencies.markMicrophoneGranted()
            startRecording()
        case .undetermined:
            phase = .needsPermission
        case .denied:
            phase = .permissionDenied
        }
    }

    private func startRecording() {
        generation += 1
        let currentGeneration = generation
        let recorder = dependencies.makeRecorder()
        let fileURL = dependencies.makeRecordingURL()
        recorder.onFirstAudio = { [weak self] in
            Task { @MainActor [weak self] in
                self?.receivedFirstAudio(generation: currentGeneration)
            }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.received(level: level, generation: currentGeneration)
            }
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordingInterrupted(generation: currentGeneration)
            }
        }

        level = 0
        phase = .starting
        do {
            try recorder.start(writingTo: fileURL)
        } catch {
            phase = .failed(message: Self.startFailedMessage, retry: .recordAgain)
            return
        }
        self.recorder = recorder
        recordingStartedAt = dependencies.now()

        let startTimeout = dependencies.startTimeout
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(startTimeout))
            guard !Task.isCancelled else { return }
            self?.startTimedOut(generation: currentGeneration)
        }
        let maximumDuration = dependencies.maximumDuration
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maximumDuration))
            guard !Task.isCancelled else { return }
            self?.reachedMaximumDuration(generation: currentGeneration)
        }
    }

    private func receivedFirstAudio(generation callbackGeneration: Int) {
        guard callbackGeneration == generation, phase == .starting else { return }
        startWatchdog?.cancel()
        startWatchdog = nil
        phase = .recording
    }

    private func received(level newLevel: Float, generation callbackGeneration: Int) {
        guard callbackGeneration == generation, canStop else { return }
        level = newLevel
    }

    private func startTimedOut(generation callbackGeneration: Int) {
        guard callbackGeneration == generation, phase == .starting else { return }
        cancelTimers()
        recorder?.cancel()
        recorder = nil
        level = 0
        phase = .failed(message: Self.noAudioBuffersMessage, retry: .recordAgain)
    }

    private func reachedMaximumDuration(generation callbackGeneration: Int) {
        guard callbackGeneration == generation else { return }
        stop()
    }

    private func recordingInterrupted(generation callbackGeneration: Int) {
        guard callbackGeneration == generation else { return }
        if phase == .recording {
            stop()
        } else if phase == .starting {
            startTimedOut(generation: callbackGeneration)
        }
    }

    private func cancelTimers() {
        startWatchdog?.cancel()
        startWatchdog = nil
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    // MARK: Processing

    private func process() {
        guard !isClosed, let fileURL = recordingURL else { return }
        // Nothing reaches the provider without consent, even a recording
        // made before it was withdrawn.
        guard dependencies.hasConsent() else {
            phase = .consentNeeded
            return
        }
        guard let configuration = dependencies.configuration() else {
            phase = .setupNeeded
            return
        }
        generation += 1
        let currentGeneration = generation
        phase = .processing

        let run = dependencies.process
        let endBackgroundWork = dependencies.beginBackgroundWork()
        processingTask = Task { [weak self] in
            let outcome: Result<DictationResult, Error>
            do {
                outcome = .success(try await run(fileURL, configuration))
            } catch {
                outcome = .failure(error)
            }
            self?.finishProcessing(outcome, generation: currentGeneration)
            endBackgroundWork()
        }
    }

    private func finishProcessing(_ outcome: Result<DictationResult, Error>, generation callbackGeneration: Int) {
        guard callbackGeneration == generation, phase == .processing else { return }
        processingTask = nil
        switch outcome {
        case .success(let result):
            deliver(result)
        case .failure(let error):
            if error is CancellationError {
                return
            }
            let message = DictationPipeline.userFacingMessage(for: error, isOnline: dependencies.isOnline())
            dependencies.appendHistory(historyEntry(status: .failed, result: nil, errorMessage: message))
            phase = .failed(message: message, retry: .processAgain)
        }
    }

    private func deliver(_ result: DictationResult) {
        var outcome = RecorderOutcome(
            text: result.text,
            rawTranscript: result.rawTranscript,
            pressEnter: result.pressEnter,
            route: result.route,
            usedRawFallback: result.usedRawFallback,
            handedOff: false
        )

        let status: HistoryEntry.Status
        switch mode {
        case .handoff(let sessionID) where dependencies.awaitedSessionID() == sessionID:
            // Saved even when empty, so the waiting keyboard learns that
            // there is nothing to insert instead of waiting for a result.
            dependencies.savePendingDictation(PendingDictation(
                sessionID: sessionID,
                createdAt: dependencies.now(),
                text: result.text,
                pressEnter: result.pressEnter
            ))
            outcome.handedOff = true
            status = outcome.isNothingToInsert ? .nothingToInsert : .handedOff
        case .handoff:
            // The keyboard stopped waiting (or never asked), so no keyboard
            // would ever take a saved result and its text would linger in the
            // App Group. Only show it, with Copy; nothing presses return.
            outcome.keyboardStoppedWaiting = true
            outcome.pressEnter = false
            status = outcome.isNothingToInsert ? .nothingToInsert : .notInserted
        case .inApp:
            if outcome.isNothingToInsert {
                status = .nothingToInsert
            } else if let insert = onInsertIntoTestField {
                insert(result.text, result.pressEnter)
                // The keyboard's rule: return alone inserted no text.
                status = .forInsertion(of: result)
            } else {
                status = .notInserted
            }
        }

        dependencies.appendHistory(historyEntry(status: status, result: result, errorMessage: nil))
        discardRecording()
        phase = .finished(outcome)
    }

    private func historyEntry(status: HistoryEntry.Status, result: DictationResult?, errorMessage: String?) -> HistoryEntry {
        HistoryEntry(
            createdAt: dependencies.now(),
            source: .app,
            status: status,
            rawTranscript: result?.rawTranscript ?? "",
            text: result?.text ?? "",
            route: result?.route,
            usedRawFallback: result?.usedRawFallback ?? false,
            errorMessage: errorMessage,
            durationSeconds: recordedDuration
        )
    }

    private func discardRecording() {
        if let recordingURL {
            dependencies.removeFile(recordingURL)
        }
        recordingURL = nil
    }
}
