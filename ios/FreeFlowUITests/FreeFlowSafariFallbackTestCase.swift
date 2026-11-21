import XCTest

/// The keyboard's fallback to the app, end to end from a real host app
/// (DESIGN §5.4). The DEBUG switch `-FreeFlowUITestCaptureUnavailable` makes
/// the keyboard's capture fail to start, so it offers to record in FreeFlow.
/// Its Open FreeFlow button opens `freeflow://dictate?session=` through the
/// responder chain (KeyboardAppOpener) with the session it now awaits.
/// FreeFlow records at once and hands the result back through the App Group.
///
/// Back in Safari, the keyboard can't confirm it is the field FreeFlow was
/// opened from: on the CI simulator, Safari's address field comes back with
/// a new document identifier, so the keyboard holds the result for Insert
/// from FreeFlow instead of inserting it on its own (KeyboardDictationMachine
/// .documentMatches). The test requires that path. The mock's press-enter
/// scenario makes the result ask for return, which Insert from FreeFlow must
/// not press.
///
/// The round trip runs twice in each CI run: first in the UI bundle, with a
/// fresh keyboard process (FreeFlowFallbackFromSafariTests), and last, after
/// the other keyboard tests have kept one keyboard process alive for
/// minutes (FreeFlowWarmKeyboardFallbackTests). When Safari came back, briefly
/// showed the keyboard and then dropped the address edit, the brief
/// keyboard's check took FreeFlow's result out of the store, and iOS stopped
/// that keyboard process before it could use it. The next keyboard found the
/// session still awaited and nothing stored, and waited for good (CI,
/// 2026-11-21, in either order). The check now leaves the result in the store
/// until the keyboard uses it or lets it go, and an offer hidden within
/// KeyboardDictationMachine.offerReleaseGrace of showing keeps it for the
/// next keyboard (KeyboardHandoffCheck, KeyboardDictationMachine
/// .handoffSessionID). Both runs must succeed. Running before
/// FreeFlowKeyboardSetupTests, the first one repairs the keyboard's setup
/// in Settings itself when CI's simulator preparation didn't take, as
/// openFreeFlowKeyboard does.
///
/// The app's synthetic tone stands in for speech, so this doesn't replace
/// the check on a physical iPhone that AGENTS.md asks for.
class FreeFlowSafariFallbackTestCase: FreeFlowKeyboardTestCase {
    static let fallbackText = "Can't record in the keyboard here. Record in FreeFlow instead."
    static let pendingInsertText = "FreeFlow finished. Tap Insert from FreeFlow to add it here."
    static let insertedWithoutReturnText = "Inserted from FreeFlow. Return wasn't pressed."

    /// The whole round trip; each subclass runs it at its point in the bundle.
    @MainActor
    func runFallbackRoundTripFromSafari() throws {
        // Two app switches, a cold Safari and keyboard launches.
        executionTimeAllowance = 400
        try resetProviderRequests()
        var options = FreeFlowLaunchOptions.dictationReady
        options.captureUnavailable = true
        options.syntheticCapture = true
        options.apiKey = MockProvider.apiKey(for: .pressEnter)
        let app = launchFreeFlow(options)
        defer {
            // Leave the keyboard able to record for whatever runs next, even
            // in a run of this test alone. (A failed XCTAssert stops the test
            // without running this; the next launch's reset clears it then.)
            let cleanup = XCUIApplication()
            cleanup.launchArguments = ["-FreeFlowUITestCaptureUnavailable", "NO"]
            cleanup.launch()
        }
        let testField = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(
            testField.waitForExistence(timeout: Self.firstQueryTimeout),
            "FreeFlow's Home didn't appear, so the launch hooks may not have run",
            evidence: [app]
        )

        let safari = XCUIApplication(bundleIdentifier: FreeFlowBundleID.safari)
        let springboard = XCUIApplication(bundleIdentifier: FreeFlowBundleID.springboard)
        try openSafariFromHomeScreen(safari, springboard: springboard)
        let keyboard = KeyboardDriver(app: safari)
        var addressField = try focusSafariAddressField(safari, keyboard: keyboard)
        var switched = keyboard.switchToFreeFlow()
        if case .notReached(let reason) = switched {
            report("Could not reach the FreeFlow keyboard in Safari (\(reason)); enabling it in Settings")
            let settings = SystemSettingsDriver()
            let switches = try settings.inspectFreeFlowKeyboard(turnOn: true) { step in
                capture(step, hierarchyOf: [settings.settings])
            }
            report("Settings fallback:\n\(switches)")
            // Turning on Full Access kills FreeFlow, so launch it again with
            // the same arguments.
            app.launch()
            try require(
                testField.waitForExistence(timeout: Self.firstQueryTimeout),
                "FreeFlow's Home didn't appear after the Settings fallback",
                evidence: [app]
            )
            try openSafariFromHomeScreen(safari, springboard: springboard)
            addressField = try focusSafariAddressField(safari, keyboard: keyboard)
            switched = keyboard.switchToFreeFlow()
        }
        guard case .found(_, let how) = switched else {
            try require(false, "Could not switch to FreeFlow in Safari: \(switched)", evidence: keyboard.hosts)
            return
        }
        report("Reached the FreeFlow keyboard in Safari's address field (\(addressField)) with \(how)")
        let trace = KeyboardStateTrace()
        try require(
            keyboard.waitForStatus([.idle], timeout: 15, trace: trace) == .idle,
            "The keyboard in Safari isn't ready: \(describe(keyboard.status)) (seen: \(trace))",
            evidence: keyboard.hosts
        )
        captureNamed("fallback-safari-keyboard")

        // Capture is switched off, so the mic offers FreeFlow instead.
        try tapInKeyboard(FreeFlowAccessibilityID.Keyboard.mic, keyboard: keyboard)
        try require(
            keyboard.waitForStatus([.fallbackAvailable], timeout: 15, trace: trace) == .fallbackAvailable,
            "The keyboard didn't offer FreeFlow: \(describe(keyboard.status)) (seen: \(trace))",
            evidence: keyboard.hosts
        )
        XCTAssertEqual(trace.texts[KeyboardDisplayState.fallbackAvailable.rawValue], Self.fallbackText)
        captureNamed("fallback-keyboard-offers-freeflow")

        // The responder-chain open, then FreeFlow on top.
        try tapInKeyboard(FreeFlowAccessibilityID.Keyboard.openApp, keyboard: keyboard)
        let openedAt = Date()
        var confirmedOpen = false
        let cameUp = waitUntil(timeout: 20) {
            let open = springboard.buttons["Open"]
            if open.exists {
                open.tap()
                confirmedOpen = true
            }
            return app.state == .runningForeground
        }
        if !cameUp {
            let shown = describe(keyboard.status)
            report("The responder-chain open didn't bring FreeFlow up within 20 s; the keyboard shows \(shown)")
            try require(false, "Open FreeFlow didn't open FreeFlow; the keyboard shows \(shown)",
                        evidence: keyboard.hosts + [app])
        }
        let openSeconds = String(format: "%.1f", Date().timeIntervalSince(openedAt))
        report("The responder-chain open brought FreeFlow up after \(openSeconds) s, "
            + (confirmedOpen ? "once SpringBoard's Open was tapped" : "with no confirmation prompt"))

        // The keyboard awaits this session, so FreeFlow records at once.
        let status = element(FreeFlowAccessibilityID.Recorder.status, in: app)
        try require(
            waitUntil(timeout: 25) { status.textValue == "recording" },
            "FreeFlow didn't start recording for the keyboard (status \(status.textValue))",
            evidence: [app]
        )
        XCTAssertFalse(element(FreeFlowAccessibilityID.Recorder.start, in: app).exists,
                       "The session the keyboard awaits must not wait for Start")
        XCTAssertEqual(element(FreeFlowAccessibilityID.Recorder.caption, in: app).label,
                       "Dictating for the FreeFlow keyboard")
        Thread.sleep(forTimeInterval: 2)
        captureNamed("fallback-app-recording")
        element(FreeFlowAccessibilityID.Recorder.stop, in: app).tap()
        try require(
            waitUntil(timeout: 45) { status.textValue == "handed-off" },
            "FreeFlow didn't hand the result to the keyboard (status \(status.textValue))",
            evidence: [app]
        )
        // The press-enter scenario reached the result, so the keyboard gets a
        // result that asks for return.
        let pressesReturn = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Then presses Return"))
        XCTAssertTrue(pressesReturn.firstMatch.exists, "The handed-off result doesn't ask for return")
        captureNamed("fallback-app-handed-off")

        // Back to Safari, as the recorder says.
        safari.activate()
        try require(safari.wait(for: .runningForeground, timeout: 15), "Safari didn't come back", evidence: [safari])
        var refocused = false
        if keyboard.waitForKeyboardElement(FreeFlowAccessibilityID.Keyboard.status, timeout: 10) == nil {
            // Safari didn't bring its keyboard back; a tap on the field starts a new edit.
            refocused = true
            _ = try focusSafariAddressField(safari, keyboard: keyboard)
            if case .notReached(let reason) = keyboard.switchToFreeFlow() {
                try require(false, "Could not switch back to FreeFlow in Safari: \(reason)", evidence: keyboard.hosts)
            }
        }
        report("Safari \(refocused ? "needed a tap on the address field" : "brought the keyboard back by itself")")

        let back = KeyboardStateTrace()
        let returned = keyboard.waitForStatus([.pendingInsert, .inserted], timeout: 20, trace: back)
        try require(
            returned == .pendingInsert,
            "Back in Safari the keyboard didn't hold the result for Insert from FreeFlow: "
                + "\(describe(keyboard.status)) (seen: \(back)). Still waiting for FreeFlow means the "
                + "result was lost on the way back (see the class comment). Inserted on its own means the field "
                + "kept its document identifier across the switch, which this test expects it not to on the CI "
                + "simulator.",
            evidence: keyboard.hosts
        )
        try finishThroughInsertFromFreeFlow(safari: safari, keyboard: keyboard, trace: back)

        // FreeFlow made the provider calls, not the keyboard, which never
        // recorded. Only provider calls count: Safari never loads the mock,
        // but nothing else should be checked against FreeFlow's User-Agent.
        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.count, 1, "transcription requests")
        XCTAssertEqual(requests.chats.count, 1, "cleanup requests")
        for request in requests.transcriptions + requests.chats {
            let agent = request["user_agent"] as? String ?? ""
            XCTAssertTrue(agent.hasPrefix("FreeFlow/"), "Expected FreeFlow's own User-Agent, got \(agent)")
        }
        if let upload = requests.transcriptions.first {
            assertValidUpload(upload, minimumSeconds: 1)
            report("FreeFlow uploaded \(describeUpload(upload))")
        }
    }

    // MARK: Steps

    /// The pending result waits for a tap. It goes into the field without
    /// return, though the result asked for one.
    @MainActor
    private func finishThroughInsertFromFreeFlow(
        safari: XCUIApplication,
        keyboard: KeyboardDriver,
        trace: KeyboardStateTrace
    ) throws {
        XCTAssertEqual(trace.texts[KeyboardDisplayState.pendingInsert.rawValue], Self.pendingInsertText)
        captureNamed("fallback-keyboard-pending-insert")
        try tapInKeyboard(FreeFlowAccessibilityID.Keyboard.insertPending, keyboard: keyboard)
        let afterTap = KeyboardStateTrace()
        _ = keyboard.waitForStatus([.inserted], timeout: 3, trace: afterTap)
        let inserted = waitUntil(timeout: 10) {
            self.safariAddressText(safari).contains(MockProvider.cleanedText)
        }
        captureNamed("fallback-inserted-from-freeflow")
        try require(
            inserted,
            "Insert from FreeFlow didn't put the text in Safari's address field; it holds "
                + "\"\(safariAddressText(safari))\" (seen: \(afterTap))",
            evidence: keyboard.hosts
        )
        // The "inserted" message lasts 1.5 s, so it is checked when seen.
        if let message = afterTap.texts[KeyboardDisplayState.inserted.rawValue] {
            XCTAssertEqual(message, Self.insertedWithoutReturnText)
        }
        // Return would have submitted the address field, ending the edit and
        // taking the keyboard away. Both are still there.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotNil(keyboard.keyboardElement(FreeFlowAccessibilityID.Keyboard.mic),
                        "The keyboard went away, so return was pressed")
        XCTAssertTrue(safariAddressText(safari).contains(MockProvider.cleanedText),
                      "The address field no longer holds the text, so it was submitted")
        report("Insert from FreeFlow inserted the text without return (states after the tap: \(afterTap); "
            + "message: \(afterTap.texts[KeyboardDisplayState.inserted.rawValue] ?? "missed between queries"))")
    }

    /// Opens Safari from the Home Screen, as a person would.
    /// XCUIApplication.launch() gives Safari 30 s, which a busy CI simulator
    /// used up once before Safari even started; this waits up to 90 s.
    @MainActor
    private func openSafariFromHomeScreen(_ safari: XCUIApplication, springboard: XCUIApplication) throws {
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["Safari"]
        try require(icon.waitForExistence(timeout: 30), "The Home Screen shows no Safari icon", evidence: [springboard])
        icon.tap()
        try require(
            safari.wait(for: .runningForeground, timeout: 90),
            "Safari didn't open within 90 s of a tap on its icon",
            evidence: [safari, springboard]
        )
    }

    /// Taps a FreeFlow keyboard button in whichever app hosts the keyboard.
    @MainActor
    private func tapInKeyboard(_ identifier: String, keyboard: KeyboardDriver) throws {
        let button = keyboard.waitForKeyboardElement(identifier, timeout: 10)
        try require(button != nil, "The keyboard has no \(identifier) element", evidence: keyboard.hosts)
        if let button {
            tap(button, named: identifier, host: nil)
        }
    }

    /// Focuses Safari's address field so a keyboard comes up, and names the
    /// element that worked. On iOS 26 the address bar sits at the bottom; the
    /// CI simulator's Safari exposes a text field named Address, and the rest
    /// are elements earlier versions used.
    @MainActor
    private func focusSafariAddressField(_ safari: XCUIApplication, keyboard: KeyboardDriver) throws -> String {
        try require(
            safari.wait(for: .runningForeground, timeout: 30),
            "Safari didn't come to the foreground",
            evidence: [safari]
        )
        let candidates: [(name: String, element: XCUIElement)] = [
            ("text field Address", safari.textFields["Address"]),
            ("text field URL", safari.textFields["URL"]),
            ("button Address", safari.buttons["Address"]),
            ("button URL", safari.buttons["URL"]),
            ("element URL", safari.otherElements["URL"]),
            ("button TabBarItemTitle", safari.buttons["TabBarItemTitle"]),
            ("the first text field", safari.textFields.firstMatch),
        ]
        for attempt in 1...3 {
            dismissSafariSheets(safari)
            for candidate in candidates
            where candidate.element.waitForExistence(timeout: attempt == 1 ? 5 : 1) && candidate.element.isHittable {
                candidate.element.tap()
                if waitUntil(timeout: 6, { self.keyboardIsUp(keyboard) }) {
                    return candidate.name
                }
            }
        }
        try require(false, "No Safari element brought up a keyboard", evidence: [safari, keyboard.springboard])
        return "none"
    }

    /// First-run sheets that would cover the address bar.
    @MainActor
    private func dismissSafariSheets(_ safari: XCUIApplication) {
        for label in ["Continue", "Not Now", "OK"] {
            let button = safari.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
            }
        }
    }

    @MainActor
    private func keyboardIsUp(_ keyboard: KeyboardDriver) -> Bool {
        keyboard.systemKeysVisible
            || keyboard.keyboardElement(FreeFlowAccessibilityID.Keyboard.mic) != nil
            || keyboard.globeKey != nil
    }

    /// The text in Safari's address field while it is being edited.
    @MainActor
    private func safariAddressText(_ safari: XCUIApplication) -> String {
        let focused = safari.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        if focused.exists {
            return focused.textValue
        }
        for field in [safari.textFields["Address"], safari.textFields["URL"], safari.textFields.firstMatch]
        where field.exists {
            return field.textValue
        }
        return ""
    }
}
