import XCTest

/// The same round trip last in the UI bundle, its name sorting after
/// FreeFlowUITests. By then one keyboard process has served every keyboard
/// test, the case in which a long-lived process lost FreeFlow's result. See
/// FreeFlowSafariFallbackTestCase.
final class FreeFlowWarmKeyboardFallbackTests: FreeFlowSafariFallbackTestCase {
    @MainActor
    func testFallbackRoundTripWithAWarmKeyboard() throws {
        try runFallbackRoundTripFromSafari()
    }
}
