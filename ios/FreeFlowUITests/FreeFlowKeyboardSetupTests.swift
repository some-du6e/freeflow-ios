import XCTest

/// Confirms in the Settings app that the FreeFlow keyboard is enabled with
/// Full Access. CI turns both on before the tests run
/// (.github/scripts/prepare-ios-simulator.sh configure); this test shows
/// whether that took, and turns on whatever is still off so the keyboard
/// tests can run anyway.
///
/// XCTest runs classes in name order, so this runs before
/// FreeFlowKeyboardTests and sees the state CI left, untouched.
final class FreeFlowKeyboardSetupTests: FreeFlowUITestCase {
    @MainActor
    func testSettingsShowFreeFlowKeyboardWithFullAccess() throws {
        let driver = SystemSettingsDriver()
        let switches = try driver.inspectFreeFlowKeyboard(turnOn: true) { step in
            capture(step, hierarchyOf: [driver.settings])
        }
        let verdict: String
        if switches.keyboardInitially == true && switches.fullAccessInitially == true {
            verdict = "CI setup took effect"
        } else if !switches.actions.isEmpty {
            verdict = "CI setup did NOT take effect; Settings fallback: \(switches.actions.joined(separator: ", "))"
        } else {
            verdict = "could not read every switch, so CI setup is unconfirmed"
        }
        let keyboardState = describe(switches.keyboardInitially)
        let fullAccessState = describe(switches.fullAccessInitially)
        report("Settings before any change (\(switches.path)): keyboard \(keyboardState), "
            + "Full Access \(fullAccessState); \(verdict)")
        report("Settings details:\n\(switches)")

        XCTAssertEqual(switches.keyboardNow, true, "The FreeFlow keyboard is not enabled:\n\(switches)")
        XCTAssertEqual(switches.fullAccessNow, true, "Full Access is not on for the FreeFlow keyboard:\n\(switches)")
    }

    private func describe(_ value: Bool?) -> String {
        value.map { $0 ? "on" : "off" } ?? "missing"
    }
}
