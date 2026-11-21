import XCTest

/// The same round trip last in the UI bundle, its name sorting after
/// FreeFlowUITests. By then one keyboard process has served every keyboard
/// test for minutes. The lost result first showed up here, though runs in
/// either order lost it the same way. See FreeFlowSafariFallbackTestCase.
final class FreeFlowWarmKeyboardFallbackTests: FreeFlowSafariFallbackTestCase {
    @MainActor
    func testFallbackRoundTripWithAWarmKeyboard() throws {
        try runFallbackRoundTripFromSafari()
    }
}
