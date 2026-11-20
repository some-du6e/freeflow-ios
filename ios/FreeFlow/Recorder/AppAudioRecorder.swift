import AVFoundation
import os.log

private let recorderLog = OSLog(subsystem: "com.zachlatta.freeflow.ios", category: "Recorder")

/// A finished recording on disk.
struct AppRecordingSummary: Equatable {
    let fileURL: URL
    let frameCount: Int64

    var duration: TimeInterval {
        Double(frameCount) / AppRecordingWAVWriter.sampleRate
    }
}

/// What RecorderModel needs from a recorder, so tests can substitute a fake.
/// Callbacks may arrive on any thread.
protocol AppAudioRecording: AnyObject {
    /// The first audio with a non-zero level arrived.
    var onFirstAudio: (@Sendable () -> Void)? { get set }
    /// Display level in 0...1, already smoothed.
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    /// The system interrupted the recording (a call, Siri, a route change the
    /// engine couldn't recover from, or a write failure).
    var onInterruption: (@Sendable () -> Void)? { get set }

    func start(writingTo fileURL: URL) throws
    /// Finishes the file. nil when nothing usable was recorded, in which case
    /// the file is already deleted.
    func stop() -> AppRecordingSummary?
    /// Stops and deletes the file.
    func cancel()
}

/// The app's own recorder: the keyboard's fallback and the in-app "try
/// without the keyboard". AVAudioEngine taps the microphone under a
/// `.playAndRecord` session and AppRecordingWAVWriter writes 16 kHz mono
/// Int16 WAV, the format the macOS app uploads.
///
/// Call `start`, `stop` and `cancel` on the main thread. The tap runs on an
/// audio thread; `lock` guards everything the two share.
final class AppAudioRecorder: AppAudioRecording {
    static let fileNamePrefix = "FreeFlowRecording-"

    var onFirstAudio: (@Sendable () -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onInterruption: (@Sendable () -> Void)?

    private let usesSyntheticInput: Bool
    private let lock = NSLock()
    // Guarded by `lock`.
    private var writer: AppRecordingWAVWriter?
    private var meter = AppRecorderLevelMeter()
    private var hasReportedFirstAudio = false
    private var writeFailed = false
    // Main thread only.
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var sessionActive = false
    private var syntheticTimer: DispatchSourceTimer?
    private var syntheticPhase: Double = 0

    /// `usesSyntheticInput` replaces the microphone with a 440 Hz tone that
    /// goes through the same converter and writer. DEBUG UI tests turn it on
    /// with `-FreeFlowUITestSyntheticCapture YES` for runners without a mic.
    init(usesSyntheticInput: Bool = false) {
        self.usesSyntheticInput = usesSyntheticInput
    }

    deinit {
        syntheticTimer?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fileNamePrefix)\(UUID().uuidString).wav")
    }

    /// Deletes recordings left in the temporary directory by a crash or a
    /// kill mid-recording. Call at launch, before any recording starts.
    static func removeLeftoverRecordings(in directory: URL = FileManager.default.temporaryDirectory) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasPrefix(fileNamePrefix) && name.hasSuffix(".wav") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: AppAudioRecording

    func start(writingTo fileURL: URL) throws {
        let writer = try AppRecordingWAVWriter(fileURL: fileURL)
        lock.withLock {
            self.writer = writer
            meter = AppRecorderLevelMeter()
            hasReportedFirstAudio = false
            writeFailed = false
        }

        if usesSyntheticInput {
            startSyntheticInput()
            os_log(.info, log: recorderLog, "recording started (synthetic input)")
            return
        }

        do {
            try activateSession()
            try startEngine()
        } catch {
            tearDownCapture()
            discardWriter()
            os_log(.error, log: recorderLog, "recording failed to start: %{public}@", String(describing: type(of: error)))
            throw error
        }
        installObservers()
        os_log(.info, log: recorderLog, "recording started")
    }

    func stop() -> AppRecordingSummary? {
        tearDownCapture()
        let (writer, failed) = lock.withLock { () -> (AppRecordingWAVWriter?, Bool) in
            let writer = self.writer
            self.writer = nil
            return (writer, writeFailed)
        }
        guard let writer else { return nil }
        let frames = writer.finish()
        os_log(.info, log: recorderLog, "recording stopped: %lld frames, write failed: %{public}@", frames, String(failed))
        guard !failed, frames > 0 else {
            try? FileManager.default.removeItem(at: writer.fileURL)
            return nil
        }
        return AppRecordingSummary(fileURL: writer.fileURL, frameCount: frames)
    }

    func cancel() {
        tearDownCapture()
        discardWriter()
        os_log(.info, log: recorderLog, "recording cancelled")
    }

    // MARK: Capture

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        sessionActive = true
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        try installTap(on: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// Taps the input node in its current hardware format; the writer
    /// converts. A format with no channels or rate means there is no input,
    /// and tapping it would raise an Objective-C exception.
    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppAudioRecorderError.noInputAvailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    private func tearDownCapture() {
        removeObservers()
        syntheticTimer?.cancel()
        syntheticTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func discardWriter() {
        let writer = lock.withLock { () -> AppRecordingWAVWriter? in
            let writer = self.writer
            self.writer = nil
            return writer
        }
        guard let writer else { return }
        writer.finish()
        try? FileManager.default.removeItem(at: writer.fileURL)
    }

    /// Runs on the tap's audio thread (or the synthetic timer's queue).
    private func handle(_ buffer: AVAudioPCMBuffer) {
        var level: Float?
        var reportFirstAudio = false
        var reportFailure = false

        lock.lock()
        if let writer, !writeFailed {
            do {
                if let converted = try writer.append(buffer) {
                    level = meter.consume(converted)
                    if meter.hasHeardAudio && !hasReportedFirstAudio {
                        hasReportedFirstAudio = true
                        reportFirstAudio = true
                    }
                }
            } catch {
                writeFailed = true
                reportFailure = true
            }
        }
        lock.unlock()

        if reportFirstAudio {
            onFirstAudio?()
        }
        if let level {
            onLevel?(level)
        }
        if reportFailure {
            os_log(.error, log: recorderLog, "recording write failed")
            onInterruption?()
        }
    }

    // MARK: Interruptions and route changes

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else {
                return
            }
            os_log(.info, log: recorderLog, "recording interrupted by the system")
            self?.onInterruption?()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            os_log(.info, log: recorderLog, "media services were reset")
            self?.onInterruption?()
        })

        if let engine {
            observers.append(center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                // AVAudioEngine must not be released inside its own
                // notification callout, so rebuild on the next turn.
                DispatchQueue.main.async { [weak self] in
                    self?.rebuildEngineAfterConfigurationChange()
                }
            })
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// A route change (headphones, Bluetooth) stops the engine and may change
    /// the hardware format. The stopped engine keeps its old tap format, and
    /// tapping it with a different hardware rate raises an exception, so start
    /// a fresh engine, which reads the current format, and keep writing the
    /// same file. The writer makes a new converter when the format changes.
    private func rebuildEngineAfterConfigurationChange() {
        // Nil when the recording already stopped or was cancelled.
        guard let oldEngine = engine else { return }
        os_log(.info, log: recorderLog, "audio configuration changed; rebuilding the engine")
        removeObservers()
        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        engine = nil
        do {
            try startEngine()
            installObservers()
        } catch {
            os_log(.error, log: recorderLog, "engine rebuild failed: %{public}@", String(describing: type(of: error)))
            onInterruption?()
        }
    }

    // MARK: Synthetic input

    private func startSyntheticInput() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return }
        let queue = DispatchQueue(label: "com.zachlatta.freeflow.ios.recorder.synthetic")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.emitSyntheticBuffer(format: format)
        }
        syntheticTimer = timer
        timer.resume()
    }

    /// 100 ms of a 440 Hz sine at -10 dBFS, continuous across buffers.
    private func emitSyntheticBuffer(format: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(format.sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = frameCount
        let step = 2 * Double.pi * 440 / format.sampleRate
        var phase = lock.withLock { syntheticPhase }
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(phase) * 0.316)
            phase += step
            if phase > 2 * Double.pi {
                phase -= 2 * Double.pi
            }
        }
        lock.withLock { syntheticPhase = phase }
        handle(buffer)
    }
}
