import XCTest

/// Shared steps for tests that drive the FreeFlow keyboard in the app's own
/// test field, the way a person would: focus the field, switch keyboards with
/// the globe key, tap the keyboard's buttons, and dictate through the CI
/// mock provider.
class FreeFlowKeyboardTestCase: FreeFlowUITestCase {
    /// Where the keyboard's mic button is, as far as XCUITest can tell.
    enum MicButton {
        case element(XCUIElement, host: String)
        /// The FreeFlow keyboard is up but exposes no accessibility elements.
        case hidden
    }

    struct KeyboardSession {
        let app: XCUIApplication
        let field: XCUIElement
        let keyboard: KeyboardDriver
        let mic: MicButton
    }

    /// The states a dictation can end in.
    static let finalStates: Set<KeyboardDisplayState> = [
        .inserted, .nothingToInsert, .error, .fallbackAvailable, .setupNeeded,
    ]

    // MARK: Opening the keyboard

    /// Launches the app, focuses the test field, and switches to the FreeFlow
    /// keyboard, enabling it in Settings first if CI's setup didn't.
    @MainActor
    func openFreeFlowKeyboard(_ options: FreeFlowLaunchOptions = .dictationReady) throws -> KeyboardSession {
        let app = launchFreeFlow(options)
        let keyboard = KeyboardDriver(app: app)
        let field = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(
            field.waitForExistence(timeout: Self.firstQueryTimeout),
            "The test field did not appear after launch",
            evidence: [app]
        )

        try focus(field, keyboard: keyboard)
        var outcome = keyboard.switchToFreeFlow()
        if case .notReached(let reason) = outcome {
            report("Could not reach the FreeFlow keyboard (\(reason)); enabling it in Settings")
            let settings = SystemSettingsDriver()
            let switches = try settings.inspectFreeFlowKeyboard(turnOn: true) { step in
                capture(step, hierarchyOf: [settings.settings])
            }
            report("Settings fallback:\n\(switches)")
            // Turning on Full Access kills the containing app, so launch it
            // again, with the same arguments, instead of activating it.
            app.launch()
            try require(
                field.waitForExistence(timeout: Self.firstQueryTimeout),
                "The test field did not appear after relaunching the app",
                evidence: [app]
            )
            try focus(field, keyboard: keyboard)
            outcome = keyboard.switchToFreeFlow()
        }

        switch outcome {
        case .found(let mic, let how):
            let inApp = element(FreeFlowAccessibilityID.Keyboard.mic, in: app).exists
            report("Reached the FreeFlow keyboard with \(how)")
            return KeyboardSession(app: app, field: field, keyboard: keyboard,
                                   mic: .element(mic, host: inApp ? "app" : "SpringBoard"))
        case .customKeyboardWithoutElements(let how):
            report("Reached a keyboard without accessibility elements with \(how)")
            return KeyboardSession(app: app, field: field, keyboard: keyboard, mic: .hidden)
        case .notReached(let reason):
            try require(false, "Could not switch to the FreeFlow keyboard: \(reason)", evidence: keyboard.hosts)
            throw RequirementFailure(message: reason)
        }
    }

    /// Taps a FreeFlow keyboard button by accessibility identifier.
    @MainActor
    func tapKeyboardButton(_ identifier: String, in session: KeyboardSession, timeout: TimeInterval = 10) throws {
        let button = session.keyboard.waitForKeyboardElement(identifier, timeout: timeout)
        try require(button != nil, "The keyboard has no \(identifier) element", evidence: session.keyboard.hosts)
        if let button {
            tap(button, named: identifier, host: nil)
        }
    }

    /// Taps a keyboard element, at its frame's center when XCUITest says it
    /// isn't hittable (remote keyboard views can report that wrongly).
    @MainActor
    func tap(_ element: XCUIElement, named identifier: String, host: String?) {
        let hittable = element.isHittable
        if let host {
            report("XCUITest sees the keyboard's \(identifier) in the \(host) hierarchy (hittable: \(hittable))")
        }
        if hittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Focuses `field` and waits for a software keyboard: the system keys,
    /// FreeFlow's mic, or at least the globe of the bar under the keyboard.
    @MainActor
    func focus(_ field: XCUIElement, keyboard: KeyboardDriver) throws {
        field.tap()
        // System keys or FreeFlow's mic mean a keyboard is up. A globe alone
        // can be a keyboard whose elements XCUITest can't see, so it counts
        // only once neither shows up.
        var visible = waitUntil(timeout: 20) {
            keyboard.systemKeysVisible
                || keyboard.keyboardElement(FreeFlowAccessibilityID.Keyboard.mic) != nil
        }
        if !visible {
            visible = keyboard.globeKey != nil
        }
        try require(
            visible,
            "No software keyboard appeared after focusing the test field. Is a hardware keyboard connected?",
            evidence: keyboard.hosts
        )
    }

    // MARK: Dictating

    /// Waits for the keyboard to settle in `idle`, failing with the status
    /// text if it reports something else, such as a missing setup step.
    @MainActor
    func requireIdle(_ session: KeyboardSession, trace: KeyboardStateTrace) throws {
        let state = session.keyboard.waitForStatus([.idle], timeout: 10, trace: trace)
        try require(
            state == .idle,
            "The keyboard isn't ready to dictate: \(describe(session.keyboard.status)) (seen: \(trace))",
            evidence: session.keyboard.hosts
        )
    }

    /// Taps the mic and waits until the keyboard is recording.
    @MainActor
    func startTapDictation(in session: KeyboardSession, trace: KeyboardStateTrace) throws {
        try tapKeyboardButton(FreeFlowAccessibilityID.Keyboard.mic, in: session)
        let targets = Self.finalStates.union([.recording])
        let state = session.keyboard.waitForStatus(targets, timeout: 20, trace: trace)
        try require(
            state == .recording,
            "The keyboard didn't start recording: \(describe(session.keyboard.status)) (seen: \(trace))",
            evidence: session.keyboard.hosts
        )
    }

    /// Waits for the dictation to end and returns its final state: one of
    /// `finalStates`, or `idle` once it has processed. The keyboard shows
    /// "inserted" for only 1.5 s, which can pass between two of XCUITest's
    /// slower queries; callers then confirm the outcome with
    /// `requireHistoryStatus`.
    @MainActor
    func waitForDictationResult(in session: KeyboardSession, trace: KeyboardStateTrace) -> KeyboardDisplayState? {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let state = session.keyboard.waitForStatus(
                Self.finalStates.union([.idle]),
                timeout: max(1, deadline.timeIntervalSinceNow),
                trace: trace
            )
            if state != .idle || trace.saw(.processing) {
                return state
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    /// Whether a dictation that should end in `expected` did: the keyboard
    /// showed it, or went from processing back to idle after showing it.
    func ended(_ result: KeyboardDisplayState?, in expected: KeyboardDisplayState, trace: KeyboardStateTrace) -> Bool {
        result == expected || (result == .idle && trace.saw(.processing))
    }

    /// Waits for Home's Recent card to show the History entry the keyboard
    /// wrote, with `title` as its status ("Inserted", "Inserted without
    /// cleanup", "Nothing to insert", "Failed"). Unlike the keyboard's short
    /// status message, it stays.
    @MainActor
    func requireHistoryStatus(_ title: String, in session: KeyboardSession, trace: KeyboardStateTrace) throws {
        let predicate = NSPredicate(
            format: "label == %@ AND identifier != %@",
            title,
            FreeFlowAccessibilityID.Keyboard.status
        )
        let row = session.app.staticTexts.matching(predicate).firstMatch
        try require(
            row.waitForExistence(timeout: 10),
            "Home's Recent card shows no \"\(title)\" entry (seen: \(trace))",
            evidence: [session.app]
        )
    }

    /// Records for `seconds` by tapping the mic, then taps Done and waits for
    /// the result.
    @MainActor
    func dictateByTapping(
        in session: KeyboardSession,
        recordFor seconds: TimeInterval = 2,
        trace: KeyboardStateTrace
    ) throws -> KeyboardDisplayState? {
        try startTapDictation(in: session, trace: trace)
        capture("recording")
        Thread.sleep(forTimeInterval: seconds)
        try tapKeyboardButton(FreeFlowAccessibilityID.Keyboard.done, in: session)
        let result = waitForDictationResult(in: session, trace: trace)
        capture("result-\(result?.rawValue ?? "none")")
        return result
    }

    /// Waits until the test field contains `text`.
    @MainActor
    func requireField(_ session: KeyboardSession, contains text: String, trace: KeyboardStateTrace) throws {
        let found = waitUntil(timeout: 10) { session.field.textValue.contains(text) }
        try require(
            found,
            "The test field doesn't contain \"\(text)\"; it holds \"\(session.field.textValue)\" (seen: \(trace))",
            evidence: session.keyboard.hosts
        )
    }

    func describe(_ status: (state: String, text: String)?) -> String {
        guard let status else { return "the FreeFlow keyboard isn't showing" }
        return "\(status.state) (\"\(status.text)\")"
    }

    // MARK: The mock provider's request log

    struct ProviderRequests {
        let all: [[String: Any]]

        var transcriptions: [[String: Any]] {
            all.filter { ($0["path"] as? String)?.hasSuffix("/audio/transcriptions") == true }
        }

        var chats: [[String: Any]] {
            all.filter { ($0["path"] as? String)?.hasSuffix("/chat/completions") == true }
        }
    }

    /// Clears the mock's request log so a test sees only its own requests.
    func resetProviderRequests() throws {
        switch MockProvider.resetRecordedRequests() {
        case .success(let response):
            XCTAssertEqual(response.status, 200, "The mock provider didn't clear its request log")
        case .failure(let error):
            throw RequirementFailure(message: "The mock provider at \(MockProvider.origin) isn't reachable: \(error)")
        }
    }

    func providerRequests() throws -> ProviderRequests {
        switch MockProvider.recordedRequests() {
        case .success(let requests):
            return ProviderRequests(all: requests)
        case .failure(let error):
            throw RequirementFailure(message: "Couldn't read the mock provider's request log: \(error)")
        }
    }

    /// Asserts that every request came from the keyboard extension, not the
    /// app, by its User-Agent, which CFNetwork builds from the bundle name.
    func assertFromKeyboard(_ requests: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        for request in requests {
            let agent = request["user_agent"] as? String ?? ""
            XCTAssertTrue(
                agent.hasPrefix("FreeFlowKeyboard/"),
                "\(request["path"] as? String ?? "?") came from \"\(agent)\", not the keyboard",
                file: file,
                line: line
            )
        }
    }

    /// A one-line summary of a transcription request's upload, for reports.
    func describeUpload(_ request: [String: Any]) -> String {
        let wav = request["wav"] as? [String: Any] ?? [:]
        let parts: [String] = [
            "status \(request["status"] as? Int ?? 0)",
            "\(wav["sample_rate"] as? Int ?? 0) Hz",
            "\(wav["channels"] as? Int ?? 0) ch",
            "\(wav["bits"] as? Int ?? 0)-bit",
            "\(wav["duration_s"] as? Double ?? 0) s",
            "peak \(wav["peak_dbfs"] as? Double ?? -999) dBFS",
            "UA \(request["user_agent"] as? String ?? "?")",
        ]
        return parts.joined(separator: ", ")
    }

    /// Asserts a transcription upload was a valid 16 kHz mono 16-bit WAV of
    /// at least `minimumSeconds`.
    func assertValidUpload(
        _ request: [String: Any],
        minimumSeconds: Double,
        maximumSeconds: Double = 600,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let wav = request["wav"] as? [String: Any] ?? [:]
        XCTAssertTrue(wav["problem"] is NSNull || wav["problem"] == nil,
                      "The mock rejected the WAV: \(wav["problem"] ?? "")", file: file, line: line)
        XCTAssertEqual(wav["sample_rate"] as? Int, 16000, "sample rate", file: file, line: line)
        XCTAssertEqual(wav["channels"] as? Int, 1, "channels", file: file, line: line)
        XCTAssertEqual(wav["bits"] as? Int, 16, "bits per sample", file: file, line: line)
        let duration = wav["duration_s"] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(duration, minimumSeconds, "WAV duration", file: file, line: line)
        XCTAssertLessThanOrEqual(duration, maximumSeconds, "WAV duration", file: file, line: line)
    }
}
