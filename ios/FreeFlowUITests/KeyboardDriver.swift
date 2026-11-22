import XCTest

/// Drives the system keyboard switcher and the FreeFlow keyboard from a UI test.
///
/// The keyboard extension runs in its own process, and iOS hosts its view
/// inside the app that has focus. Its accessibility elements can surface in
/// that app's hierarchy or in SpringBoard's, so every lookup searches both.
@MainActor
struct KeyboardDriver {
    /// The labels iOS gives the globe key that cycles keyboards.
    static let globeLabels = ["Next keyboard", "Next Keyboard"]
    /// The FreeFlow keyboard's display name in the input-mode list.
    static let keyboardDisplayName = "FreeFlow"
    /// How long a keyboard switch may take to show FreeFlow's view.
    static let extensionLaunchGrace: TimeInterval = 15

    let app: XCUIApplication
    let springboard = XCUIApplication(bundleIdentifier: FreeFlowBundleID.springboard)

    /// The apps to search for keyboard elements, and to dump on failure.
    var hosts: [XCUIApplication] { [app, springboard] }

    /// A FreeFlow keyboard element by accessibility identifier, in whichever
    /// process exposes it, or nil if none does right now.
    func keyboardElement(_ identifier: String) -> XCUIElement? {
        for host in hosts {
            let element = host.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if element.exists {
                return element
            }
        }
        return nil
    }

    func waitForKeyboardElement(_ identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = keyboardElement(identifier) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return keyboardElement(identifier)
    }

    /// Whether a system keyboard's keys are showing. A third-party keyboard
    /// draws buttons, not `.key` elements, so this also tells the two apart.
    var systemKeysVisible: Bool {
        app.keys.firstMatch.exists
    }

    /// The globe key, from the system keyboard or the bottom bar Face ID
    /// iPhones draw under every keyboard.
    var globeKey: XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", Self.globeLabels, Self.globeLabels)
        for host in hosts {
            for query in [host.buttons, host.keys] {
                let globe = query.matching(predicate).firstMatch
                if globe.exists {
                    return globe
                }
            }
        }
        return nil
    }

    /// Dismisses a one-time keyboard introduction if one covers the keys.
    func dismissKeyboardIntroduction() -> Bool {
        for host in hosts {
            for label in ["Continue", "OK", "Not Now"] {
                let button = host.buttons[label]
                if button.exists && button.isHittable {
                    button.tap()
                    return true
                }
            }
        }
        return false
    }

    enum SwitchOutcome {
        /// FreeFlow's mic button is in the accessibility hierarchy.
        case found(XCUIElement, how: String)
        /// FreeFlow is up, but XCUITest can't see its elements: the system
        /// keys gave way to a keyboard without any, or FreeFlow was picked
        /// from the keyboard list. FreeFlow is the only third-party keyboard
        /// enabled, so that keyboard is FreeFlow.
        case customKeyboardWithoutElements(how: String)
        case notReached(String)
    }

    /// Switches from whatever keyboard is up to FreeFlow: taps the globe up to
    /// `maxGlobeTaps` times, then tries the long-press keyboard list.
    func switchToFreeFlow(maxGlobeTaps: Int = 4) -> SwitchOutcome {
        let mic = FreeFlowAccessibilityID.Keyboard.mic
        // With no system keys up, FreeFlow may already be the active keyboard
        // and still loading, so give it the extension's launch time.
        let firstWait = systemKeysVisible ? 2 : Self.extensionLaunchGrace
        if let element = waitForKeyboardElement(mic, timeout: firstWait) {
            return .found(element, how: "already the active keyboard")
        }
        var taps = 0
        while taps < maxGlobeTaps, let globe = globeKey {
            let systemKeysWereVisible = systemKeysVisible
            // The globe's value names the keyboard a tap switches to.
            let next = globe.textValue
            globe.tap()
            taps += 1
            if let element = waitForKeyboardElement(mic, timeout: 4) {
                return .found(element, how: "\(taps) globe tap(s); the globe named \"\(next)\" as next")
            }
            if dismissKeyboardIntroduction(), let element = waitForKeyboardElement(mic, timeout: 3) {
                return .found(element, how: "\(taps) globe tap(s) and a dismissed introduction")
            }
            if systemKeysWereVisible, !systemKeysVisible {
                // The first launch of the extension process on a cold CI
                // simulator can take a while; give its view time to load
                // before concluding XCUITest can't see it.
                if let element = waitForKeyboardElement(mic, timeout: Self.extensionLaunchGrace) {
                    return .found(element, how: "\(taps) globe tap(s), after the extension loaded")
                }
                return .customKeyboardWithoutElements(how: "\(taps) globe tap(s)")
            }
        }
        if let globe = globeKey {
            globe.press(forDuration: 1.2)
            // List rows read "<keyboard>, <language>". Only cells and buttons
            // count: the app's own "FreeFlow" title is static text.
            let predicate = NSPredicate(format: "label BEGINSWITH %@", Self.keyboardDisplayName)
            for host in hosts {
                for query in [host.cells, host.buttons] {
                    let entry = query.matching(predicate).firstMatch
                    guard entry.waitForExistence(timeout: 1) else {
                        continue
                    }
                    entry.tap()
                    if let element = waitForKeyboardElement(mic, timeout: Self.extensionLaunchGrace) {
                        return .found(element, how: "the globe's long-press keyboard list")
                    }
                    if !systemKeysVisible {
                        return .customKeyboardWithoutElements(how: "the globe's long-press keyboard list")
                    }
                    return .notReached("picked \"\(entry.label)\" from the keyboard list, but the system keys stayed up")
                }
            }
        }
        if taps == 0 && globeKey == nil {
            return .notReached("no globe key: is FreeFlow enabled as a second keyboard?")
        }
        return .notReached("FreeFlow did not come up after \(taps) globe tap(s) and the keyboard list")
    }

    /// For a keyboard whose elements XCUITest can't see: taps a column of
    /// points up the middle of the keyboard area until `done` holds. The
    /// placeholder keyboard centers its mic button, so one of them hits it.
    func tapKeyboardCenterColumn(until done: () -> Bool) -> CGPoint? {
        let screen = app.windows.firstMatch.frame
        guard screen.height > 0 else { return nil }
        // Stay above the system's bottom bar and below the text field.
        var y = screen.maxY - 90
        while y >= screen.maxY - 360 {
            let point = CGPoint(x: screen.midX, y: y)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y))
                .tap()
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                if done() {
                    return point
                }
                Thread.sleep(forTimeInterval: 0.3)
            } while Date() < deadline
            y -= 20
        }
        return nil
    }

    /// The keyboard's reported machine state (`freeflow.keyboard.status`).
    var displayState: KeyboardDisplayState? {
        guard let status = keyboardElement(FreeFlowAccessibilityID.Keyboard.status) else {
            return nil
        }
        return KeyboardDisplayState(rawValue: status.textValue)
    }

    /// The status element's state name and the text it shows, or nil when
    /// the FreeFlow keyboard isn't showing.
    var status: (state: String, text: String)? {
        // One snapshot query reads both, with no separate existence check:
        // each query takes up to a second while the keyboard is busy, and
        // short states would pass between them.
        for host in hosts {
            let element = host.descendants(matching: .any)
                .matching(identifier: FreeFlowAccessibilityID.Keyboard.status).firstMatch
            if let snapshot = try? element.snapshot() {
                return ((snapshot.value as? String) ?? "", snapshot.label)
            }
        }
        return nil
    }

    /// Polls the status until it is one of `targets`, noting every state it
    /// passes through in `trace`. Returns the target reached, or nil.
    func waitForStatus(
        _ targets: Set<KeyboardDisplayState>,
        timeout: TimeInterval,
        trace: KeyboardStateTrace
    ) -> KeyboardDisplayState? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let status {
                trace.note(state: status.state, text: status.text)
                if let state = KeyboardDisplayState(rawValue: status.state), targets.contains(state) {
                    return state
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }

    /// Waits until the keyboard reports one of `states`, returning it.
    func waitForDisplayState(_ states: Set<KeyboardDisplayState>, timeout: TimeInterval) -> KeyboardDisplayState? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let state = displayState, states.contains(state) {
                return state
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return displayState.flatMap { states.contains($0) ? $0 : nil }
    }
}
