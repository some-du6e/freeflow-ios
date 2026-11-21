import XCTest

/// The keyboard's fallback to the app, end to end from a real host app
/// (DESIGN §5.4). The DEBUG switch `-FreeFlowUITestCaptureUnavailable` makes
/// the keyboard's capture fail to start, so it offers to record in FreeFlow.
/// Its Open FreeFlow button opens `freeflow://dictate?session=` through the
/// responder chain (KeyboardAppOpener) with the session it now awaits.
/// FreeFlow records at once, hands the result back through the App Group,
/// and the keyboard inserts it when Safari comes back: on its own in the
/// field it was opened from, or through Insert from FreeFlow, which never
/// presses return. The mock's press-enter scenario makes the result ask for
/// return, so the test can tell.
///
/// The app's synthetic tone stands in for speech, so this doesn't replace
/// the check on a physical iPhone that AGENTS.md asks for.
final class FreeFlowFallbackTests: FreeFlowKeyboardTestCase {
    static let fallbackText = "Can't record in the keyboard here. Record in FreeFlow instead."
    static let pendingInsertText = "FreeFlow finished. Tap Insert from FreeFlow to add it here."
    static let insertedWithoutReturnText = "Inserted from FreeFlow. Return wasn't pressed."

    @MainActor
    func testFallbackRoundTripFromSafari() throws {
        // Two app switches, a cold Safari and keyboard launches.
        executionTimeAllowance = 400
        try resetProviderRequests()
        var options = FreeFlowLaunchOptions.dictationReady
        options.captureUnavailable = true
        options.syntheticCapture = true
        options.apiKey = MockProvider.apiKey(for: .pressEnter)
        let app = launchFreeFlow(options)
        let testField = element(FreeFlowAccessibilityID.App.testField, in: app)
        try require(
            testField.waitForExistence(timeout: Self.firstQueryTimeout),
            "FreeFlow's Home didn't appear, so the launch hooks may not have run",
            evidence: [app]
        )

        let safari = XCUIApplication(bundleIdentifier: FreeFlowBundleID.safari)
        safari.launch()
        let keyboard = KeyboardDriver(app: safari)
        let addressField = try focusSafariAddressField(safari, keyboard: keyboard)
        let switched = keyboard.switchToFreeFlow()
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
        let springboard = XCUIApplication(bundleIdentifier: FreeFlowBundleID.springboard)
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
        if returned == .pendingInsert {
            try finishThroughInsertFromFreeFlow(safari: safari, keyboard: keyboard, trace: back)
        } else {
            // The field matched, so the keyboard inserted on its own and,
            // as the result asked, pressed return: Safari submits the text.
            let typed = waitUntil(timeout: 10) {
                back.saw(.inserted) || self.safariAddressText(safari).contains("FreeFlow")
            }
            captureNamed("fallback-auto-inserted")
            try require(
                typed,
                "The keyboard neither offered Insert from FreeFlow nor inserted the result: "
                    + "\(describe(keyboard.status)) (seen: \(back))",
                evidence: keyboard.hosts
            )
            if let message = back.texts[KeyboardDisplayState.inserted.rawValue] {
                XCTAssertEqual(message, "Inserted from FreeFlow")
            }
            report("The keyboard auto-inserted into the field it opened FreeFlow from (seen: \(back))")
        }

        // FreeFlow made the provider calls, not the keyboard, which never recorded.
        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.count, 1, "transcription requests")
        XCTAssertEqual(requests.chats.count, 1, "cleanup requests")
        for request in requests.all {
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
        report("Insert from FreeFlow inserted the text without return (states after the tap: \(afterTap))")
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
    /// element that worked. On iOS 26 the address bar sits at the bottom and
    /// is a button until tapped, so this tries the elements Safari has used.
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
            for candidate in candidates where candidate.element.waitForExistence(timeout: attempt == 1 ? 5 : 1) {
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
