import Foundation

/// Capture timing the keyboard depends on. It lives in Core, apart from WebAudioCapture, so the
/// macOS tests can check it against `KeyboardDictationMachine`'s backstops.
enum CaptureTiming {
    /// How long `WebAudioCapture.stop()` waits by default for the page's final chunk before it
    /// finishes with the audio already received; whatever the page sends after that is lost. CI
    /// pages have stalled at stop for 1.7 s and more. When the whole web content process is held
    /// up, WebKit keeps capturing into its buffers, and the late chunks are the end of what the
    /// user said. When only the page's script stalls, WebKit keeps reusing the two buffers its
    /// queued callbacks read, so those deliver repeats of the latest audio instead, which the page
    /// counts as late callbacks; a longer wait keeps more of them. This must stay under
    /// `KeyboardDictationMachine.stopBackstop`, with time left to finish the file, or the keyboard
    /// gives up on a recording that was about to arrive.
    static let stopTimeout: TimeInterval = 2.5
}
