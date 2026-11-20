import Foundation

/// A fixed display state for UI-test screenshots. In DEBUG simulator builds
/// the keyboard reads `ios_debug_keyboard_state` from the App Group defaults
/// (or its own defaults) and, when it parses, shows that state instead of the
/// live one and ignores dictation input.
///
/// Values are a `KeyboardDictationStatus` raw value with an optional variant
/// after a colon:
/// - `setup-needed:fullAccess|microphone|apiKey` (default fullAccess)
/// - `recording:hold|tap` (default tap)
/// - `inserted:dictation|rawFallback|returnOnly|lastDictation|handoff`
/// - `nothing-to-insert:emptyTranscript|noAudio|noHistory`
/// - `error:<message>` (default a synthetic timeout message)
/// - `fallback-available:captureUnavailable|lowMemory|openFailed`
enum KeyboardDebugDisplayState {
    static let defaultsKey = "ios_debug_keyboard_state"
    static let sampleErrorMessage = "Request timed out — try again"
    static let sampleSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    /// A machine showing the requested state, or nil when `rawValue` doesn't
    /// name one. Message states never expire.
    static func machine(for rawValue: String, now: Date) -> KeyboardDictationMachine? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, let status = KeyboardDictationStatus(rawValue: name) else {
            return nil
        }
        let variant = parts.count > 1 ? parts[1] : ""
        let setup = KeyboardDictationSetup(
            hasFullAccess: true,
            microphoneGranted: true,
            hasAPIKey: true,
            availableMemoryBytes: nil
        )

        let phase: KeyboardDictationMachine.Phase
        switch status {
        case .idle:
            phase = .idle
        case .setupNeeded:
            phase = .setupNeeded(KeyboardDictationSetupIssue(rawValue: variant) ?? .fullAccess)
        case .starting:
            phase = .starting(KeyboardDictationMachine.Recording(
                attempt: 1,
                startedAt: now,
                audioStartedAt: nil,
                gesture: .latched,
                documentID: nil
            ))
        case .recording:
            phase = .recording(KeyboardDictationMachine.Recording(
                attempt: 1,
                startedAt: now,
                audioStartedAt: now,
                gesture: variant == "hold" ? .holding : .latched,
                documentID: nil
            ))
        case .processing:
            phase = .processing(KeyboardDictationMachine.Processing(
                attempt: 1,
                stoppedAt: now,
                documentID: nil,
                heardAudio: true,
                audio: nil
            ))
        case .inserted:
            phase = .inserted(
                KeyboardDictationMachine.InsertedKind(rawValue: variant) ?? .dictation,
                until: .distantFuture
            )
        case .nothingToInsert:
            phase = .nothingToInsert(
                KeyboardDictationMachine.NothingReason(rawValue: variant) ?? .emptyTranscript,
                until: .distantFuture
            )
        case .error:
            let message = variant.isEmpty ? sampleErrorMessage : KeyboardDictationMachine.displayMessage(variant)
            phase = .error(message: message, until: .distantFuture)
        case .fallbackAvailable:
            phase = .fallbackAvailable(KeyboardDictationMachine.FallbackReason(rawValue: variant) ?? .captureUnavailable)
        case .waitingForApp:
            phase = .waitingForApp(sessionID: sampleSessionID, since: now, nextCheck: .distantFuture)
        }
        return KeyboardDictationMachine(phase: phase, setup: setup, isVisible: true, attempt: 1)
    }
}
