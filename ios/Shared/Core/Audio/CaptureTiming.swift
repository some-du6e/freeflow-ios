import Foundation

/// Capture timing the keyboard depends on. It lives in Core, apart from WebAudioCapture, so the
/// macOS tests can check it against `KeyboardDictationMachine`'s backstops.
enum CaptureTiming {
    /// How long `WebAudioCapture.stop()` waits by default for the page's final chunk before it
    /// finishes with the audio already received. Whatever the page sends after that is lost, and
    /// a page that stalls at stop is holding the end of what the user said: CI pages have stalled
    /// for 1.7 s and more. It must stay under `KeyboardDictationMachine.stopBackstop`, with time
    /// left to finish the file, or the keyboard gives up on a recording that was about to arrive.
    static let stopTimeout: TimeInterval = 2.5
}
