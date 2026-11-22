import XCTest

/// The keyboard's fallback round trip from Safari, first in the UI bundle,
/// with a fresh keyboard process. See FreeFlowSafariFallbackTestCase.
final class FreeFlowFallbackFromSafariTests: FreeFlowSafariFallbackTestCase {
    @MainActor
    func testFallbackRoundTripFromSafari() throws {
        try runFallbackRoundTripFromSafari()
    }
}
