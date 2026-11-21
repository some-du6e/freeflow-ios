#if DEBUG
import XCTest
@testable import FreeFlow

/// `WebAudioCaptureUITestSwitch`: while its App Group flag is on,
/// `WebAudioCapture.start()` fails as `.unsupported` before it touches the
/// page, so the e2e tests can reach the keyboard's fallback to the app. Each
/// test turns the flag off again, so no later capture test fails to start.
final class CaptureUITestSwitchTests: XCTestCase {
    private static let key = WebAudioCaptureUITestSwitch.defaultsKey

    @MainActor
    func testStartFailsAsUnsupportedWhileTheSwitchIsOn() throws {
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier))
        appGroup.set(true, forKey: Self.key)
        defer { appGroup.removeObject(forKey: Self.key) }
        let capture = WebAudioCapture()
        let delegate = CaptureStartRecorder()
        capture.delegate = delegate

        capture.start()
        XCTAssertEqual(delegate.failures, [WebAudioCaptureUITestSwitch.failure])
        // No session started: a second start fails the same way instead of
        // being ignored as "already running".
        capture.start()
        XCTAssertEqual(delegate.failures, [WebAudioCaptureUITestSwitch.failure, WebAudioCaptureUITestSwitch.failure])
        XCTAssertEqual(delegate.otherCallbacks, 0)
        XCTAssertEqual(WebAudioCaptureUITestSwitch.failure, .unsupported("capture is switched off for UI tests"))
    }

    /// With the switch off, the same unattached capture fails the ordinary
    /// way, so the switch alone made the start above unsupported.
    @MainActor
    func testStartIgnoresTheSwitchWhileItIsOff() throws {
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier))
        appGroup.set(false, forKey: Self.key)
        defer { appGroup.removeObject(forKey: Self.key) }
        let capture = WebAudioCapture()
        let delegate = CaptureStartRecorder()
        capture.delegate = delegate

        capture.start()

        XCTAssertEqual(delegate.failures, [.pageUnavailable])
        XCTAssertFalse(WebAudioCaptureUITestSwitch.isOn())
    }

    func testTheSwitchReadsTheAppGroupFlag() throws {
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier))
        appGroup.removeObject(forKey: Self.key)
        defer { appGroup.removeObject(forKey: Self.key) }

        XCTAssertFalse(WebAudioCaptureUITestSwitch.isOn(), "Off when the flag was never set")
        appGroup.set(true, forKey: Self.key)
        XCTAssertTrue(WebAudioCaptureUITestSwitch.isOn())
        XCTAssertFalse(WebAudioCaptureUITestSwitch.isOn(nil), "Off without an App Group")
        XCTAssertEqual(Self.key, "ios_debug_capture_unavailable")
    }
}

@MainActor
private final class CaptureStartRecorder: WebAudioCaptureDelegate {
    private(set) var failures: [WebAudioCaptureFailure] = []
    private(set) var otherCallbacks = 0

    func webAudioCaptureDidBecomeReady(_ capture: WebAudioCapture) {
        otherCallbacks += 1
    }

    func webAudioCaptureDidStart(_ capture: WebAudioCapture) {
        otherCallbacks += 1
    }

    func webAudioCapture(_ capture: WebAudioCapture, didUpdateLevel level: Float) {
        otherCallbacks += 1
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFinish audio: CapturedAudio) {
        otherCallbacks += 1
    }

    func webAudioCapture(_ capture: WebAudioCapture, didFail failure: WebAudioCaptureFailure) {
        failures.append(failure)
    }
}
#endif
