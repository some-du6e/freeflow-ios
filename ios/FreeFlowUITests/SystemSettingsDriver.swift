import XCTest

/// What the FreeFlow keyboard page showed, and what the driver changed.
struct SettingsKeyboardSwitches: CustomStringConvertible {
    var path = ""
    var keyboardInitially: Bool?
    var fullAccessInitially: Bool?
    var keyboardNow: Bool?
    var fullAccessNow: Bool?
    var actions: [String] = []

    var description: String {
        func show(_ value: Bool?) -> String { value.map { $0 ? "on" : "off" } ?? "not found" }
        return """
        path: \(path)
        keyboard switch: \(show(keyboardInitially)) -> \(show(keyboardNow))
        Allow Full Access: \(show(fullAccessInitially)) -> \(show(fullAccessNow))
        actions: \(actions.isEmpty ? "none" : actions.joined(separator: "; "))
        """
    }
}

enum SettingsNavigationError: Error, CustomStringConvertible {
    case pageNotFound(String)
    var description: String {
        switch self {
        case .pageNotFound(let detail): return "Could not open the FreeFlow keyboard page in Settings: \(detail)"
        }
    }
}

/// Reads, and if needed sets, the FreeFlow keyboard's switches in the Settings
/// app. CI enables the keyboard and Full Access before the tests run
/// (.github/scripts/prepare-ios-simulator.sh); this is how the tests confirm
/// that took, and the fallback when it didn't.
@MainActor
struct SystemSettingsDriver {
    let settings = XCUIApplication(bundleIdentifier: FreeFlowBundleID.settings)
    let springboard = XCUIApplication(bundleIdentifier: FreeFlowBundleID.springboard)

    /// Opens the FreeFlow keyboard page, reads both switches and, when
    /// `turnOn` is set, turns on whichever is off. `capture` receives a step
    /// name at each screen worth a screenshot.
    func inspectFreeFlowKeyboard(turnOn: Bool, capture: (String) -> Void) throws -> SettingsKeyboardSwitches {
        var result = SettingsKeyboardSwitches()
        let page = try openFreeFlowKeyboardPage(addIfMissing: turnOn, capture: capture)
        result.path = page.path
        capture("settings-freeflow-keyboard-page")

        // The General path's page has no keyboard switch: being in the
        // Keyboards list is what "enabled" means there.
        result.keyboardInitially = page.keyboardListed ?? switchValue(keyboardSwitch)
        result.fullAccessInitially = switchValue(fullAccessSwitch)
        if page.keyboardListed == false {
            result.actions.append("added the FreeFlow keyboard under Add New Keyboard")
        }

        if turnOn, page.keyboardListed == nil, result.keyboardInitially == false {
            flip(keyboardSwitch)
            result.actions.append("turned the FreeFlow keyboard on")
            _ = waitForValue(keyboardSwitch, true)
        }
        if turnOn, switchValue(fullAccessSwitch) == false {
            flip(fullAccessSwitch)
            result.actions.append("turned Allow Full Access on")
            let allow = settings.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) {
                capture("settings-full-access-alert")
                allow.tap()
                result.actions.append("accepted the Full Access alert")
            }
            _ = waitForValue(fullAccessSwitch, true)
        }

        result.keyboardNow = page.keyboardListed != nil ? true : switchValue(keyboardSwitch)
        result.fullAccessNow = switchValue(fullAccessSwitch)
        if !result.actions.isEmpty {
            capture("settings-after-changes")
        }
        return result
    }

    // MARK: Navigation

    /// The page the driver reached. On the General path, `keyboardListed`
    /// says whether FreeFlow was already in the Keyboards list (false means
    /// the driver added it); on the Apps path the page has a switch instead.
    private struct KeyboardPage {
        let path: String
        let keyboardListed: Bool?
    }

    /// Settings > Apps > FreeFlow > Keyboards on iOS 18 and later, else
    /// General > Keyboard > Keyboards > FreeFlow.
    private func openFreeFlowKeyboardPage(addIfMissing: Bool, capture: (String) -> Void) throws -> KeyboardPage {
        launchAtRoot()
        capture("settings-root")
        if tapRow(["Apps"]), tapRow([KeyboardDriver.keyboardDisplayName]), tapRow(["Keyboards"]),
           fullAccessSwitch.waitForExistence(timeout: 5) || keyboardSwitch.exists {
            return KeyboardPage(path: "Settings > Apps > FreeFlow > Keyboards", keyboardListed: nil)
        }
        capture("settings-apps-path-failed")

        launchAtRoot()
        guard tapRow(["General"]) else {
            throw SettingsNavigationError.pageNotFound("no General row")
        }
        guard tapRow(["Keyboard"]) else {
            throw SettingsNavigationError.pageNotFound("no Keyboard row in General")
        }
        guard tapRow(["Keyboards"]) else {
            throw SettingsNavigationError.pageNotFound("no Keyboards row in General > Keyboard")
        }
        capture("settings-keyboards-list")
        let listed = tapRow([KeyboardDriver.keyboardDisplayName], contains: true, maxSwipes: 2)
        if !listed {
            guard addIfMissing else {
                throw SettingsNavigationError.pageNotFound("FreeFlow is not in the keyboard list")
            }
            guard tapRow(["Add New Keyboard…", "Add New Keyboard..."], prefix: true) else {
                throw SettingsNavigationError.pageNotFound("FreeFlow is not in the keyboard list and there is no Add New Keyboard row")
            }
            capture("settings-add-new-keyboard")
            guard tapRow([KeyboardDriver.keyboardDisplayName], contains: true) else {
                throw SettingsNavigationError.pageNotFound("FreeFlow is not under Third-Party Keyboards")
            }
            guard tapRow([KeyboardDriver.keyboardDisplayName], contains: true, maxSwipes: 2) else {
                throw SettingsNavigationError.pageNotFound("FreeFlow was added but its row did not appear")
            }
        }
        guard fullAccessSwitch.waitForExistence(timeout: 5) || keyboardSwitch.exists else {
            throw SettingsNavigationError.pageNotFound("the FreeFlow keyboard page has no switches")
        }
        return KeyboardPage(path: "Settings > General > Keyboard > Keyboards > FreeFlow", keyboardListed: listed)
    }

    private func launchAtRoot() {
        settings.terminate()
        settings.launch()
        _ = settings.cells.firstMatch.waitForExistence(timeout: 30)
        dismissSystemAlerts()
        // Settings can restore the last page it showed; walk back to the root.
        for _ in 0..<6 {
            let back = settings.navigationBars.buttons.element(boundBy: 0)
            guard !settings.cells.staticTexts["General"].exists, back.exists, back.isHittable else {
                break
            }
            back.tap()
        }
    }

    private func dismissSystemAlerts() {
        for app in [settings, springboard] {
            for label in ["Not Now", "Cancel", "Later"] {
                let button = app.alerts.buttons[label]
                if button.exists {
                    button.tap()
                }
            }
        }
    }

    /// Taps the first row labeled with one of `labels`, scrolling down to
    /// find it. Rows can be cells, buttons or bare text depending on the iOS
    /// version, so all three are tried.
    private func tapRow(_ labels: [String], prefix: Bool = false, contains: Bool = false, maxSwipes: Int = 8) -> Bool {
        let predicate: NSPredicate
        if contains {
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: labels.map {
                NSPredicate(format: "label CONTAINS %@", $0)
            })
        } else if prefix {
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: labels.map {
                NSPredicate(format: "label BEGINSWITH %@", $0)
            })
        } else {
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: labels.flatMap {
                [NSPredicate(format: "label == %@", $0), NSPredicate(format: "label BEGINSWITH %@", "\($0),")]
            })
        }
        _ = settings.cells.firstMatch.waitForExistence(timeout: 5)
        for _ in 0...maxSwipes {
            let candidates = [
                settings.cells.containing(predicate).firstMatch,
                settings.buttons.matching(predicate).firstMatch,
                settings.staticTexts.matching(predicate).firstMatch,
            ]
            for candidate in candidates where candidate.exists && candidate.isHittable {
                candidate.tap()
                Thread.sleep(forTimeInterval: 1)
                return true
            }
            settings.swipeUp()
        }
        return false
    }

    // MARK: Switches

    private var keyboardSwitch: XCUIElement {
        let predicate = NSPredicate(
            format: "label BEGINSWITH %@ AND NOT (label CONTAINS[c] %@)",
            KeyboardDriver.keyboardDisplayName,
            "Full Access"
        )
        return settings.switches.matching(predicate).firstMatch
    }

    private var fullAccessSwitch: XCUIElement {
        settings.switches.matching(NSPredicate(format: "label CONTAINS[c] %@", "Full Access")).firstMatch
    }

    private func switchValue(_ element: XCUIElement) -> Bool? {
        guard element.exists else {
            return nil
        }
        return element.textValue == "1"
    }

    private func flip(_ element: XCUIElement) {
        let before = switchValue(element)
        // Taps during a push transition get swallowed; let the page settle.
        Thread.sleep(forTimeInterval: 1)
        // The tappable part is the inner switch on recent iOS versions.
        let inner = element.switches.firstMatch
        if inner.exists {
            inner.tap()
        } else {
            element.tap()
        }
        // Full Access asks for confirmation first, which counts as a change.
        let changed = waitUntilSettled(timeout: 2) {
            switchValue(element) != before || settings.alerts.firstMatch.exists
        }
        if !changed {
            // Otherwise tap the toggle itself, at the row's right edge.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    private func waitUntilSettled(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    private func waitForValue(_ element: XCUIElement, _ expected: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if switchValue(element) == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return switchValue(element) == expected
    }
}
