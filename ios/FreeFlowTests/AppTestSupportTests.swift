import XCTest
@testable import FreeFlow

// Fakes shared by the App*Tests files. All data is synthetic.

final class AppFakeMicrophone: AppMicrophoneAccess {
    var permission: AppMicrophonePermission
    var grantsOnRequest: Bool
    private(set) var requestCount = 0

    init(permission: AppMicrophonePermission = .granted, grantsOnRequest: Bool = true) {
        self.permission = permission
        self.grantsOnRequest = grantsOnRequest
    }

    func requestPermission() async -> Bool {
        requestCount += 1
        permission = grantsOnRequest ? .granted : .denied
        return grantsOnRequest
    }
}

struct AppFakeKeychainError: Error, Equatable {}

/// Behaves like SharedKeychain: nil or blank deletes.
final class AppFakeCredentialStore: AppCredentialStore {
    var storedAPIKey: String?
    var storedTranscriptionAPIKey: String?
    var readFailure: SharedKeychain.Failure?
    /// Fails only the transcription key's read; it is a keychain item of its own.
    var transcriptionReadFailure: SharedKeychain.Failure?
    var failsWrites = false
    private(set) var writeCount = 0

    func apiKey() -> Result<String?, SharedKeychain.Failure> {
        if let readFailure {
            return .failure(readFailure)
        }
        return .success(storedAPIKey)
    }

    func setAPIKey(_ value: String?) throws {
        writeCount += 1
        if failsWrites {
            throw AppFakeKeychainError()
        }
        storedAPIKey = Self.normalized(value)
    }

    func transcriptionAPIKey() -> Result<String?, SharedKeychain.Failure> {
        if let failure = readFailure ?? transcriptionReadFailure {
            return .failure(failure)
        }
        return .success(storedTranscriptionAPIKey)
    }

    func setTranscriptionAPIKey(_ value: String?) throws {
        writeCount += 1
        if failsWrites {
            throw AppFakeKeychainError()
        }
        storedTranscriptionAPIKey = Self.normalized(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Records validator calls; answers from a per-URL table or a default.
actor AppValidationRecorder {
    struct Call: Equatable {
        let key: String
        let baseURL: String
    }

    private(set) var calls: [Call] = []
    private let defaultResult: Bool
    private let results: [String: Bool]

    init(defaultResult: Bool = true, results: [String: Bool] = [:]) {
        self.defaultResult = defaultResult
        self.results = results
    }

    func validate(_ key: String, _ baseURL: String) -> Bool {
        calls.append(Call(key: key, baseURL: baseURL))
        return results[baseURL] ?? defaultResult
    }
}

final class AppFakeRecorder: AppAudioRecording {
    var onFirstAudio: (@Sendable () -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onInterruption: (@Sendable () -> Void)?

    var startError: Error?
    /// stop() returns nil, as when nothing was recorded.
    var recordsNothing = false
    var frameCount: Int64 = 24_000
    private(set) var startedURL: URL?
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    func start(writingTo fileURL: URL) throws {
        if let startError {
            throw startError
        }
        startedURL = fileURL
    }

    func stop() -> AppRecordingSummary? {
        stopCount += 1
        guard !recordsNothing, let startedURL else { return nil }
        return AppRecordingSummary(fileURL: startedURL, frameCount: frameCount)
    }

    func cancel() {
        cancelCount += 1
    }
}

/// Collects what a RecorderModel writes, and hands it fakes.
final class AppRecorderSpy {
    /// A configuration from the real resolver, with a synthetic key and
    /// default everything else.
    static func makeConfiguration() -> DictationConfiguration? {
        let suiteName = "freeflow.app-tests.config.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return DictationConfiguration.resolve(defaults: defaults, apiKey: "synthetic-key", transcriptionAPIKey: nil)
    }

    var configuration: DictationConfiguration? = AppRecorderSpy.makeConfiguration()
    /// The data-sharing consent the recorder sees.
    var hasConsent = true
    let microphone: AppFakeMicrophone
    var recorders: [AppFakeRecorder] = []
    var nextRecorderStartError: Error?
    var nextRecorderRecordsNothing = false
    var results: [Result<DictationResult, Error>] = []
    /// Keeps each pipeline run going this long (cancellation ends it early),
    /// so a test can act while a recorder is still processing.
    var processingDelay: TimeInterval = 0
    private(set) var processedURLs: [URL] = []
    /// Pipeline runs that have returned or thrown, and how many of them
    /// ended because their task was cancelled during `processingDelay`.
    private(set) var endedRuns = 0
    private(set) var cancelledRuns = 0
    private(set) var history: [HistoryEntry] = []
    private(set) var pending: [PendingDictation] = []
    /// When set, the awaited session lives in this store, as in the app, so
    /// the app model and its recorders read the same value.
    var awaitedSessionStore: PendingDictationStore? {
        didSet {
            if let awaitedSessionStore, let localAwaitedSessionID {
                awaitedSessionStore.awaitedSessionID = localAwaitedSessionID
            }
        }
    }
    private var localAwaitedSessionID: UUID?
    var awaitedSessionID: UUID? {
        get {
            if let awaitedSessionStore {
                return awaitedSessionStore.awaitedSessionID
            }
            return localAwaitedSessionID
        }
        set {
            if let awaitedSessionStore {
                awaitedSessionStore.awaitedSessionID = newValue
            } else {
                localAwaitedSessionID = newValue
            }
        }
    }
    private(set) var removedFiles: [URL] = []
    private(set) var microphoneMarkedGranted = 0
    var isOnline = true
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    init(microphone: AppFakeMicrophone = AppFakeMicrophone()) {
        self.microphone = microphone
    }

    var lastRecorder: AppFakeRecorder? {
        recorders.last
    }

    func dependencies(startTimeout: TimeInterval = 60, maximumDuration: TimeInterval = 300) -> RecorderDependencies {
        RecorderDependencies(
            configuration: { self.configuration },
            hasConsent: { self.hasConsent },
            microphone: microphone,
            markMicrophoneGranted: { self.microphoneMarkedGranted += 1 },
            makeRecorder: {
                let recorder = AppFakeRecorder()
                recorder.startError = self.nextRecorderStartError
                recorder.recordsNothing = self.nextRecorderRecordsNothing
                self.recorders.append(recorder)
                return recorder
            },
            makeRecordingURL: {
                FileManager.default.temporaryDirectory.appendingPathComponent("app-tests-\(UUID().uuidString).wav")
            },
            process: { url, _ in
                self.processedURLs.append(url)
                defer { self.endedRuns += 1 }
                if self.processingDelay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(self.processingDelay * 1_000_000_000))
                    } catch {
                        self.cancelledRuns += 1
                        throw error
                    }
                }
                guard !self.results.isEmpty else {
                    return DictationResult(rawTranscript: "", text: "", pressEnter: false, route: .empty, usedRawFallback: false)
                }
                return try self.results.removeFirst().get()
            },
            appendHistory: { self.history.append($0) },
            savePendingDictation: { self.pending.append($0) },
            awaitedSessionID: { self.awaitedSessionID },
            clearAwaitedSessionID: { self.awaitedSessionID = nil },
            isOnline: { self.isOnline },
            now: { self.now },
            removeFile: { self.removedFiles.append($0) },
            beginBackgroundWork: { {} },
            startTimeout: startTimeout,
            maximumDuration: maximumDuration
        )
    }
}

/// A throwaway App Group stand-in: a unique defaults suite and history file.
final class AppTestStores {
    let suiteName: String
    let defaults: UserDefaults
    let settings: SettingsStore
    let credentials = AppFakeCredentialStore()
    let history: HistoryStore
    let pendingDictations: PendingDictationStore
    let keyboardStatus: KeyboardStatusStore
    let microphone: AppFakeMicrophone
    let historyFileURL: URL

    init(microphone: AppFakeMicrophone = AppFakeMicrophone()) {
        let suiteName = "freeflow.app-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let historyFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-app-tests-\(UUID().uuidString).json")
        self.suiteName = suiteName
        self.defaults = defaults
        self.historyFileURL = historyFileURL
        settings = SettingsStore(defaults: defaults, keychain: SharedKeychain(accessGroup: nil))
        history = HistoryStore(fileURL: historyFileURL, settings: settings)
        pendingDictations = PendingDictationStore(defaults: defaults)
        keyboardStatus = KeyboardStatusStore(defaults: defaults)
        self.microphone = microphone
    }

    func environment(
        validator: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
        recorderSpy: AppRecorderSpy? = nil
    ) -> FreeFlowAppEnvironment {
        let spy = recorderSpy ?? AppRecorderSpy(microphone: microphone)
        spy.awaitedSessionStore = pendingDictations
        return FreeFlowAppEnvironment(
            settings: settings,
            credentials: credentials,
            history: history,
            pendingDictations: pendingDictations,
            keyboardStatus: keyboardStatus,
            microphone: microphone,
            validateAPIKey: validator,
            makeRecorderDependencies: { _ in spy.dependencies() }
        )
    }

    /// Keys currently stored in the suite's own domain.
    var storedKeys: Set<String> {
        Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyFileURL)
    }
}

/// Polls `condition` on the main actor until it holds or time runs out.
@MainActor
func appWaitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            return false
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

func appSyntheticResult(
    raw: String = "synthetic raw words",
    text: String = "Synthetic cleaned words.",
    pressEnter: Bool = false,
    route: DictationRoute = .cleanup,
    usedRawFallback: Bool = false
) -> DictationResult {
    DictationResult(rawTranscript: raw, text: text, pressEnter: pressEnter, route: route, usedRawFallback: usedRawFallback)
}

/// What a recorder inserted into the test field.
@MainActor
final class AppInsertionLog {
    private(set) var texts: [String] = []
    private(set) var pressEnters: [Bool] = []

    func record(_ text: String, pressEnter: Bool) {
        texts.append(text)
        pressEnters.append(pressEnter)
    }
}
