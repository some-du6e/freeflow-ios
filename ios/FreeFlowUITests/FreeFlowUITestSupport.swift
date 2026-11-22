import XCTest

/// Accessibility identifiers shared with the app and the keyboard (DESIGN.md §5.1).
enum FreeFlowAccessibilityID {
    enum Keyboard {
        static let mic = "freeflow.keyboard.mic"
        static let cancel = "freeflow.keyboard.cancel"
        static let done = "freeflow.keyboard.done"
        static let globe = "freeflow.keyboard.globe"
        static let space = "freeflow.keyboard.space"
        static let delete = "freeflow.keyboard.delete"
        static let returnKey = "freeflow.keyboard.return"
        static let insertLast = "freeflow.keyboard.insertLast"
        static let openApp = "freeflow.keyboard.openApp"
        /// The Insert from FreeFlow CTA of the `pending-insert` state.
        static let insertPending = "freeflow.keyboard.insertPending"
        /// A label whose accessibilityValue is a `KeyboardDisplayState` raw value.
        static let status = "freeflow.keyboard.status"
    }

    enum App {
        static let testField = "freeflow.app.testField"
        static let homeTab = "freeflow.app.tab.home"
        static let historyTab = "freeflow.app.tab.history"
        static let settingsTab = "freeflow.app.tab.settings"
        static let dictateInApp = "freeflow.app.dictateInApp"
    }

    enum Onboarding {
        static let continueButton = "freeflow.onboarding.continue"
        static let apiKeyField = "freeflow.onboarding.apiKeyField"
        /// "A key is saved. Enter a new one to replace it."
        static let apiKeySavedHint = "freeflow.onboarding.apiKeySavedHint"
        static let microphone = "freeflow.onboarding.microphone"
        static let openSettings = "freeflow.onboarding.openSettings"
    }

    enum Recorder {
        static let done = "freeflow.recorder.done"
        /// Shown when a dictate URL's session isn't the one the keyboard awaits.
        static let start = "freeflow.recorder.start"
        static let stop = "freeflow.recorder.stop"
        static let cancel = "freeflow.recorder.cancel"
        static let status = "freeflow.recorder.status"
        static let result = "freeflow.recorder.result"
        /// The top bar's caption: who the recording is for.
        static let caption = "freeflow.recorder.caption"
    }
}

/// The machine states the keyboard reports through `freeflow.keyboard.status`.
enum KeyboardDisplayState: String, CaseIterable {
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
    case pendingInsert = "pending-insert"
}

/// The keyboard states a test saw while it waited, in order and without
/// repeats, with the status text shown in each.
final class KeyboardStateTrace: CustomStringConvertible {
    private(set) var states: [String] = []
    private(set) var texts: [String: String] = [:]

    func note(state: String, text: String) {
        if states.last != state {
            states.append(state)
        }
        if !text.isEmpty {
            texts[state] = text
        }
    }

    func saw(_ state: KeyboardDisplayState) -> Bool {
        states.contains(state.rawValue)
    }

    /// Whether `earlier` was seen before `later`.
    func saw(_ earlier: KeyboardDisplayState, before later: KeyboardDisplayState) -> Bool {
        guard let first = states.firstIndex(of: earlier.rawValue),
              let second = states.lastIndex(of: later.rawValue) else {
            return false
        }
        return first < second
    }

    var description: String {
        states.isEmpty ? "(none)" : states.joined(separator: " -> ")
    }
}

/// Bundle identifiers the tests drive or inspect.
enum FreeFlowBundleID {
    static let app = "com.zachlatta.freeflow.ios"
    static let keyboard = "com.zachlatta.freeflow.ios.keyboard"
    static let settings = "com.apple.Preferences"
    static let springboard = "com.apple.springboard"
    static let safari = "com.apple.mobilesafari"
}

/// The local OpenAI-compatible mock that CI starts before the tests
/// (.github/scripts/mock-openai-server.py, DESIGN.md §5.3). The simulator
/// shares the Mac's network stack, so 127.0.0.1 is the runner itself.
enum MockProvider {
    static let origin = "http://127.0.0.1:8765"
    static let baseURL = "\(origin)/v1"
    static let apiKey = "ui-test-key"
    /// What the mock's transcription endpoint returns.
    static let transcript = "hello from the free flow mock"
    /// What the mock's chat completions endpoint returns.
    static let cleanedText = "Hello from the FreeFlow mock."

    /// Behaviors the mock selects from a suffix on the API key.
    enum Scenario: String {
        case slow
        case transcriptionError = "transcription-error"
        case emptyTranscript = "empty-transcript"
        case chatError = "chat-error"
        /// The transcript ends in "press enter", so the result asks for return.
        case pressEnter = "press-enter"
    }

    static func apiKey(for scenario: Scenario) -> String {
        "\(apiKey)/\(scenario.rawValue)"
    }

    struct Response {
        let status: Int
        let body: Data
    }

    /// A blocking HTTP call from the test runner to the mock, for setup and
    /// assertions. The mock's debug endpoints need no API key.
    static func send(
        _ method: String,
        _ path: String,
        apiKey: String? = nil,
        timeout: TimeInterval = 10
    ) -> Result<Response, Error> {
        guard let url = URL(string: origin + path) else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                box.result = .success(Response(status: status, body: data ?? Data()))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return .failure(URLError(.timedOut))
        }
        return box.result ?? .failure(URLError(.unknown))
    }

    /// Request metadata the mock recorded after `since` (a `last_seq` value).
    static func recordedRequests(since: Int = 0) -> Result<[[String: Any]], Error> {
        send("GET", "/v1/debug/requests?since=\(since)").flatMap { response -> Result<[[String: Any]], Error> in
            guard response.status == 200,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let requests = object["requests"] as? [[String: Any]] else {
                return .failure(URLError(.cannotParseResponse))
            }
            return .success(requests)
        }
    }

    /// Clears the mock's request log, so a test sees only its own requests.
    static func resetRecordedRequests() -> Result<Response, Error> {
        send("POST", "/v1/debug/reset")
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<Response, Error>?
    }
}

/// The UI-test launch hooks the app reads in DEBUG builds (DESIGN.md §5.2).
/// Before the app implements them they are ignored, which is harmless.
struct FreeFlowLaunchOptions: Sendable {
    var reset = true
    var apiKey: String? = MockProvider.apiKey
    var baseURL: String? = MockProvider.baseURL
    var skipOnboarding = true
    var microphoneGranted = true
    var preserveExactWording: Bool?
    var syntheticCapture = false
    /// The keyboard's capture fails to start, so it offers to record in
    /// FreeFlow (`-FreeFlowUITestCaptureUnavailable`).
    var captureUnavailable = false
    /// A `KeyboardDebugDisplayState` value such as `recording:hold`, which a
    /// DEBUG keyboard shows instead of its live state; `live` clears it.
    var keyboardState: String?

    /// Set up, signed in to the mock provider, onboarding done.
    static let dictationReady = FreeFlowLaunchOptions()

    /// As if just installed: no key, no onboarding, no microphone flag.
    static let firstLaunch = FreeFlowLaunchOptions(
        reset: true,
        apiKey: nil,
        baseURL: nil,
        skipOnboarding: false,
        microphoneGranted: false
    )

    var launchArguments: [String] {
        var arguments: [String] = []
        if reset {
            arguments += ["-FreeFlowUITestReset", "YES"]
        }
        if let apiKey {
            arguments += ["-FreeFlowUITestAPIKey", apiKey]
        }
        if let baseURL {
            arguments += ["-FreeFlowUITestBaseURL", baseURL]
        }
        if skipOnboarding {
            arguments += ["-FreeFlowUITestSkipOnboarding", "YES"]
        }
        if microphoneGranted {
            arguments += ["-FreeFlowUITestMicrophoneGranted", "YES"]
        }
        if let preserveExactWording {
            arguments += ["-FreeFlowUITestPreserveExactWording", preserveExactWording ? "YES" : "NO"]
        }
        if syntheticCapture {
            arguments += ["-FreeFlowUITestSyntheticCapture", "YES"]
        }
        if captureUnavailable {
            arguments += ["-FreeFlowUITestCaptureUnavailable", "YES"]
        }
        if let keyboardState {
            arguments += ["-FreeFlowUITestKeyboardState", keyboardState]
        }
        return arguments
    }
}

/// Base class for FreeFlow UI tests: launching with the test hooks,
/// numbered screenshots, hierarchy dumps and polling waits.
class FreeFlowUITestCase: XCTestCase {
    /// A freshly booted CI simulator can take about 30 seconds to answer the
    /// first accessibility query, so first waits get plenty of headroom.
    static let firstQueryTimeout: TimeInterval = 120

    private var stepNumber = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        stepNumber = 0
    }

    @MainActor
    func launchFreeFlow(_ options: FreeFlowLaunchOptions = .dictationReady) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = options.launchArguments
        app.launch()
        return app
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Attaches a full-screen screenshot named "<test>-<NN>-<step>". With
    /// `hierarchyOf`, also attaches each app's accessibility hierarchy.
    @MainActor
    func capture(_ step: String, hierarchyOf apps: [XCUIApplication] = []) {
        stepNumber += 1
        let number = stepNumber < 10 ? "0\(stepNumber)" : "\(stepNumber)"
        let prefix = "\(testShortName)-\(number)-\(step)"
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = prefix
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for app in apps {
            // SpringBoard's application element has a blank label.
            let label = app.label.trimmingCharacters(in: .whitespaces)
            attachText(app.debugDescription, named: "\(prefix)-hierarchy-\(label.isEmpty ? "SpringBoard" : label)")
        }
    }

    /// Attaches a screenshot under exactly `name`, for the review set
    /// (e.g. `kb-recording-hold-dark`).
    @MainActor
    func captureNamed(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func attachText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Prints a line that CI logs can grep for, and attaches it to the test.
    /// Multi-line messages print on one line, joined with "; ".
    func report(_ message: String) {
        let oneLine = message.split(separator: "\n").joined(separator: "; ")
        print("FREEFLOW-E2E: \(testShortName): \(oneLine)")
        attachText(message, named: "\(testShortName)-report")
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @discardableResult
    func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return condition()
    }

    /// Fails the test after capturing the screen and hierarchies, so a CI
    /// failure always comes with evidence.
    @MainActor
    func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        evidence apps: [XCUIApplication],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if condition() {
            return
        }
        capture("failure", hierarchyOf: apps)
        XCTFail(message, file: file, line: line)
        throw RequirementFailure(message: message)
    }

    private var testShortName: String {
        // "-[FreeFlowUITests testSomething]" becomes "testSomething".
        let words = name.split(separator: " ")
        return words.last.map { String($0.dropLast()) } ?? name
    }

    struct RequirementFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

extension XCUIElement {
    /// The element's accessibility value as text ("" when it has none).
    var textValue: String {
        (value as? String) ?? ""
    }
}
