#if DEBUG
import Foundation

/// DEBUG builds only. `-FreeFlowUITestCaptureUnavailable YES` sets this App
/// Group bool, and while it is on, `WebAudioCapture.start()` fails at once
/// with `.unsupported`, as it does where the platform can't capture. UI tests
/// use it to reach the keyboard's fallback to the app (DESIGN §5.4). Release
/// builds compile none of this.
enum WebAudioCaptureUITestSwitch {
    static let defaultsKey = "ios_debug_capture_unavailable"

    /// What `start()` reports while the switch is on.
    static let failure = WebAudioCaptureFailure.unsupported("capture is switched off for UI tests")

    /// Read at every `start()`, like the synthetic source's flag.
    static func isOn(
        _ defaults: UserDefaults? = UserDefaults(suiteName: FreeFlowIdentifiers.appGroupIdentifier)
    ) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }
}
#endif
