import Foundation

/// Capture timing the keyboard depends on. It lives in Core, apart from WebAudioCapture, so the
/// macOS tests can check it against `KeyboardDictationMachine`'s backstops.
enum CaptureTiming {
    /// How long `WebAudioCapture.stop()` waits by default for the page's final chunk before it
    /// finishes with the audio already received; whatever the page sends after that is dropped.
    /// CI pages have stalled at stop for 1.7 s and more. The DEBUG synthetic source catches up
    /// after a stall, so there the late chunks are audio a shorter wait would cut. The microphone
    /// can't: while the page's script is stalled, WebKit keeps refilling the two buffers its
    /// queued callbacks read, so those deliver repeats of the latest audio, which the page counts
    /// as late callbacks, and a longer wait keeps more of them. This must stay under
    /// `KeyboardDictationMachine.stopBackstop`, with time left to finish the file, or the keyboard
    /// gives up on a recording that was about to arrive.
    static let stopTimeout: TimeInterval = 2.5

    /// The longest a microphone session waits at stop. For the reason above, a longer wait
    /// can't recover a real microphone's audio lost in a stall: it only appends repeats of
    /// the audio after Done, which would show up as repeated words. A page that answers
    /// within this keeps its final chunks. The longer `stopTimeout` applies only to the
    /// DEBUG synthetic source, which does catch up.
    static let microphoneStopTimeout: TimeInterval = 1.0
}
