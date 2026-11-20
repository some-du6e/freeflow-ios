import XCTest

/// Drives the FreeFlow keyboard inside the app's own test field, the way a
/// person would: focus the field, switch keyboards with the globe key, tap.
///
/// Wave 1 targets the placeholder keyboard, whose mic button inserts
/// "FreeFlow". The full dictation flow through the mock provider builds on
/// `openFreeFlowKeyboard()` and `tapKeyboardButton(_:)`.
final class FreeFlowKeyboardTests: FreeFlowUITestCase {
    private static let placeholderText = "FreeFlow"

    @MainActor
    func testKeyboardInsertsTextIntoTestField() throws {
        let session = try openFreeFlowKeyboard()
        let field = session.field
        let before = field.textValue

        switch session.mic {
        case .element(let mic, let host):
            tap(mic, named: "freeflow.keyboard.mic", host: host)
        case .hidden:
            // A last look, in case the extension finished loading meanwhile.
            if let mic = session.keyboard.keyboardElement(FreeFlowAccessibilityID.Keyboard.mic) {
                tap(mic, named: "freeflow.keyboard.mic", host: "app or SpringBoard (late)")
            } else {
                report("XCUITest can't see the keyboard's elements; tapping the keyboard area by coordinates")
                let point = session.keyboard.tapKeyboardCenterColumn {
                    field.textValue.contains(Self.placeholderText)
                }
                report(point.map { "A coordinate tap at \($0) inserted the text" }
                    ?? "No coordinate tap inserted the text")
            }
        }

        let inserted = waitUntil(timeout: 10) { field.textValue.contains(Self.placeholderText) }
        capture("after-mic-tap", hierarchyOf: [session.app])
        try require(
            inserted,
            "The test field does not contain \"\(Self.placeholderText)\" (before: \"\(before)\", "
                + "now: \"\(field.textValue)\")",
            evidence: session.keyboard.hosts
        )
        report("The test field now contains \"\(field.textValue)\"")
    }

    // MARK: Shared steps

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
        capture("launched")

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
        capture("freeflow-keyboard", hierarchyOf: keyboard.hosts)

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
    private func tap(_ element: XCUIElement, named identifier: String, host: String?) {
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
    private func focus(_ field: XCUIElement, keyboard: KeyboardDriver) throws {
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
        capture("field-focused", hierarchyOf: [keyboard.app])
        try require(
            visible,
            "No software keyboard appeared after focusing the test field. Is a hardware keyboard connected?",
            evidence: keyboard.hosts
        )
    }
}
