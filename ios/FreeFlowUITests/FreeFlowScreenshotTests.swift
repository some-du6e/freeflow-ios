import XCTest

/// Screenshots for design review, named like `kb-recording-hold-dark`.
///
/// CI runs this class twice, in light and in dark mode, and says which
/// through `TEST_RUNNER_FREEFLOW_APPEARANCE`. The keyboard states come from
/// the `-FreeFlowUITestKeyboardState` hook, which makes a DEBUG simulator
/// keyboard show a fixed state (KeyboardDebugDisplayState).
final class FreeFlowScreenshotTests: FreeFlowKeyboardTestCase {
    /// Hook values, one per screenshot, with the status text each must show,
    /// so a variant the keyboard doesn't parse (it falls back to a default)
    /// can't pass as the state it names. Messages are synthetic.
    static let keyboardStates: [(hook: String, text: String)] = [
        ("idle", "Tap the mic to dictate, or hold to talk"),
        ("setup-needed:fullAccess", "Turn on Allow Full Access in Settings to dictate"),
        ("setup-needed:microphone", "Open FreeFlow to allow the microphone"),
        ("setup-needed:apiKey", "Open FreeFlow to add your API key"),
        ("starting", "Starting the microphone\u{2026}"),
        ("recording:tap", "Listening\u{2026} tap the mic to stop"),
        ("recording:hold", "Listening\u{2026} release to stop"),
        ("processing", "Transcribing\u{2026}"),
        ("inserted:dictation", "Inserted"),
        ("inserted:rawFallback", "Inserted without cleanup"),
        ("inserted:returnOnly", "Pressed return"),
        ("inserted:lastDictation", "Inserted your last dictation"),
        ("inserted:handoff", "Inserted from FreeFlow"),
        ("nothing-to-insert:emptyTranscript", "Nothing to transcribe"),
        ("nothing-to-insert:noAudio", "No audio was recorded"),
        ("nothing-to-insert:noHistory", "Nothing to insert yet"),
        ("error", "Request timed out \u{2014} try again"),
        ("error:The synthetic provider is unavailable. Try again later.",
         "The synthetic provider is unavailable. Try again later."),
        ("fallback-available:captureUnavailable", "Can't record in the keyboard here. Record in FreeFlow instead."),
        ("fallback-available:lowMemory", "Not enough memory to record here. Record in FreeFlow instead."),
        ("fallback-available:openFailed", "Couldn't open FreeFlow. Open it from your Home Screen."),
        ("waiting-for-app", "Waiting for FreeFlow. Finish recording there, then swipe back."),
        ("pending-insert", "FreeFlow finished. Tap Insert from FreeFlow to add it here."),
    ]

    private var appearance: String {
        ProcessInfo.processInfo.environment["FREEFLOW_APPEARANCE"] ?? "light"
    }

    @MainActor
    func testKeyboardStateScreenshots() throws {
        var missing: [String] = []
        for (hookValue, text) in Self.keyboardStates {
            var options = FreeFlowLaunchOptions.dictationReady
            options.keyboardState = hookValue
            let session = try openFreeFlowKeyboard(options)
            let expected = String(hookValue.split(separator: ":").first ?? "")
            let shown = waitUntil(timeout: 10) {
                guard let status = session.keyboard.status else { return false }
                return status.state == expected && status.text == text
            }
            let name = "kb-\(Self.slug(hookValue))-\(appearance)"
            captureNamed(name)
            if !shown {
                missing.append("\(hookValue) showed \(describe(session.keyboard.status))")
            }
        }
        XCTAssertTrue(missing.isEmpty, "States the keyboard didn't show: \(missing.joined(separator: "; "))")
        report("Captured \(Self.keyboardStates.count) keyboard states in \(appearance) mode")
    }

    /// Onboarding from its first page, Home, Settings, the in-app recorder
    /// and History with the recording it made. The mock key is stored before
    /// launch, so no page calls a real provider, and the slow scenario keeps
    /// the recorder's processing state on screen.
    @MainActor
    func testAppScreenshots() throws {
        var options = FreeFlowLaunchOptions.dictationReady
        options.skipOnboarding = false
        options.syntheticCapture = true
        options.apiKey = MockProvider.apiKey(for: .slow)
        let app = launchFreeFlow(options)

        let primary = app.buttons.matching(NSPredicate(
            format: "identifier IN %@",
            [FreeFlowAccessibilityID.Onboarding.continueButton, FreeFlowAccessibilityID.Onboarding.microphone]
        )).firstMatch
        for page in ["welcome", "consent", "api-key", "microphone", "keyboard", "try-it", "done"] {
            try require(
                primary.waitForExistence(timeout: Self.firstQueryTimeout),
                "The \(page) onboarding page has no primary button",
                evidence: [app]
            )
            _ = waitUntil(timeout: 10) { primary.isEnabled }
            // Let the page's transition finish before the screenshot.
            Thread.sleep(forTimeInterval: 0.8)
            captureNamed("app-onboarding-\(page)-\(appearance)")
            primary.tap()
            Thread.sleep(forTimeInterval: 1)
        }

        let field = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(field.waitForExistence(timeout: 30), "Home didn't appear after onboarding", evidence: [app])
        Thread.sleep(forTimeInterval: 1)
        captureNamed("app-home-\(appearance)")

        try tapTab(FreeFlowAccessibilityID.App.settingsTab, in: app)
        for section in 1...4 {
            captureNamed("app-settings-\(section)-\(appearance)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
        }

        try tapTab(FreeFlowAccessibilityID.App.homeTab, in: app)
        try recordInApp(app, flow: "in-app", expecting: "done")
        let close = element(FreeFlowAccessibilityID.Recorder.done, in: app)
        if close.waitForExistence(timeout: 5) {
            close.tap()
        }
        try tapTab(FreeFlowAccessibilityID.App.historyTab, in: app)
        Thread.sleep(forTimeInterval: 1)
        captureNamed("app-history-\(appearance)")
    }

    @MainActor
    func testRecorderErrorScreenshot() throws {
        var options = FreeFlowLaunchOptions.dictationReady
        options.syntheticCapture = true
        options.apiKey = MockProvider.apiKey(for: .transcriptionError)
        let app = launchFreeFlow(options)
        let field = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(field.waitForExistence(timeout: Self.firstQueryTimeout), "Home didn't appear", evidence: [app])
        try recordInApp(app, flow: "failing", expecting: "error")
    }

    /// The app's half of the keyboard fallback (DESIGN §5.4): the URL the
    /// keyboard opens starts the recorder for that session, which hands the
    /// result back through the App Group and says to swipe back.
    @MainActor
    func testRecorderHandoffScreenshot() throws {
        var options = FreeFlowLaunchOptions.dictationReady
        options.syntheticCapture = true
        let app = launchFreeFlow(options)
        let field = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(field.waitForExistence(timeout: Self.firstQueryTimeout), "Home didn't appear", evidence: [app])

        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(UUID().uuidString)"))
        XCUIDevice.shared.system.open(url)
        // iOS may ask before opening an app by its URL scheme.
        let springboard = XCUIApplication(bundleIdentifier: FreeFlowBundleID.springboard)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) {
            open.tap()
        }
        let status = element(FreeFlowAccessibilityID.Recorder.status, in: app)
        let start = element(FreeFlowAccessibilityID.Recorder.start, in: app)
        // The keyboard isn't awaiting this URL's session, so the recorder may
        // open idle with a Start button; earlier builds started at once.
        _ = waitUntil(timeout: 20) { start.exists || status.textValue == "recording" }
        if start.exists {
            captureNamed("app-recorder-handoff-idle-\(appearance)")
            start.tap()
        }
        try require(
            waitUntil(timeout: 20) { status.textValue == "recording" },
            "The dictate URL's recorder didn't record (status \(status.textValue))",
            evidence: [app, springboard]
        )
        Thread.sleep(forTimeInterval: 1.5)
        captureNamed("app-recorder-handoff-recording-\(appearance)")
        element(FreeFlowAccessibilityID.Recorder.stop, in: app).tap()
        try require(
            waitUntil(timeout: 45) { ["handed-off", "done"].contains(status.textValue) },
            "The dictate URL's recorder ended in \(status.textValue)",
            evidence: [app]
        )
        report("The dictate URL's recorder ended in \(status.textValue)")
        Thread.sleep(forTimeInterval: 0.5)
        captureNamed("app-recorder-handed-off-\(appearance)")
    }

    /// Opens the in-app recorder from Home, records the synthetic tone for a
    /// moment, stops, and screenshots the recording, processing and final
    /// states.
    @MainActor
    private func recordInApp(_ app: XCUIApplication, flow: String, expecting finalState: String) throws {
        let dictate = element(FreeFlowAccessibilityID.App.dictateInApp, in: app)
        try require(dictate.waitForExistence(timeout: 10), "Home has no Dictate Without the Keyboard button",
                    evidence: [app])
        dictate.tap()
        let status = element(FreeFlowAccessibilityID.Recorder.status, in: app)
        try require(
            waitUntil(timeout: 20) { status.textValue == "recording" },
            "The recorder didn't start recording (status \(status.textValue))",
            evidence: [app]
        )
        Thread.sleep(forTimeInterval: 1.5)
        captureNamed("app-recorder-\(flow)-recording-\(appearance)")
        element(FreeFlowAccessibilityID.Recorder.stop, in: app).tap()
        if waitUntil(timeout: 10, { status.textValue == "processing" }) {
            captureNamed("app-recorder-\(flow)-processing-\(appearance)")
        }
        try require(
            waitUntil(timeout: 45) { status.textValue == finalState },
            "The recorder ended in \(status.textValue), not \(finalState)",
            evidence: [app]
        )
        Thread.sleep(forTimeInterval: 0.5)
        captureNamed("app-recorder-\(flow)-\(finalState)-\(appearance)")
    }

    @MainActor
    private func tapTab(_ identifier: String, in app: XCUIApplication) throws {
        let tab = app.buttons[identifier]
        try require(tab.waitForExistence(timeout: 10), "There is no \(identifier) tab", evidence: [app])
        tab.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// `recording:hold` becomes `recording-hold`; an error message becomes
    /// `message`.
    static func slug(_ hookValue: String) -> String {
        let parts = hookValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return hookValue }
        if parts[0] == "error" {
            return "error-message"
        }
        return "\(parts[0])-\(parts[1])"
    }
}
