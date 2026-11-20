import UIKit

/// A finished in-keyboard recording: 16 kHz mono 16-bit WAV on disk.
struct CapturedAudio: Equatable {
    let fileURL: URL
    let frameCount: Int
    let sampleRate: Int
    /// Gain applied at stop, in dB (0 when the audio was left unchanged).
    let appliedGainDB: Float

    var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0
    }
}

enum WebAudioCaptureFailure: Error, Equatable {
    /// The capture page isn't loaded, or its web process went away.
    case pageUnavailable
    /// No audio arrived within `WebAudioCapture.startTimeout` of `start()`.
    case startTimedOut
    /// WebKit refused the microphone (NotAllowedError), usually because the
    /// containing app doesn't hold microphone permission.
    case permissionDenied
    /// The page reports the platform can't capture, e.g. Lockdown Mode.
    case unsupported(String)
    /// Capture stopped on its own mid-recording (track ended, page hidden,
    /// native side unresponsive, audio context interrupted).
    case interrupted(String)
    /// Stopped with less than 0.01 s of audio.
    case noAudio
    case fileError
}

@MainActor
protocol WebAudioCaptureDelegate: AnyObject {
    func webAudioCaptureDidBecomeReady(_ capture: WebAudioCapture)
    /// The first non-silent audio arrived; show the recording state.
    func webAudioCaptureDidStart(_ capture: WebAudioCapture)
    /// Display level in 0...1, already smoothed for a waveform.
    func webAudioCapture(_ capture: WebAudioCapture, didUpdateLevel level: Float)
    func webAudioCapture(_ capture: WebAudioCapture, didFinish audio: CapturedAudio)
    func webAudioCapture(_ capture: WebAudioCapture, didFail failure: WebAudioCaptureFailure)
}

/// Microphone capture for the keyboard through a hidden WKWebView, because a
/// keyboard extension can't record with AVAudioSession itself. See
/// ios/README.md for how it works and why.
///
/// CONTRACT STUB: owned by the capture agent, which implements it. Keep the
/// signatures and the delegate contract.
@MainActor
final class WebAudioCapture: NSObject {
    enum State: Equatable {
        case detached
        case loading
        case ready
        case starting
        case capturing
        case stopping
    }

    /// Matches the macOS AudioRecorder buffer watchdog.
    static let startTimeout: TimeInterval = 2.0

    weak var delegate: WebAudioCaptureDelegate?
    private(set) var state: State = .detached

    var isReady: Bool { state == .ready }

    override init() {
        super.init()
    }

    /// Adds the hidden web view to `view` (it must stay in the window while
    /// capturing) and preloads the page. Safe to call repeatedly.
    func attach(to view: UIView) {}

    /// Cancels any capture and removes the web view.
    func detach() {}

    /// Starts capture. Results arrive through the delegate.
    func start() {
        delegate?.webAudioCapture(self, didFail: .pageUnavailable)
    }

    /// Stops gracefully; the delegate receives `didFinish` or `didFail`.
    func stop() {}

    /// Stops and discards the recording without a delegate callback.
    func cancel() {}
}
