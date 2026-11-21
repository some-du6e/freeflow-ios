import XCTest

/// Screenshots for design review, named like `kb-recording-hold-dark`.
///
/// CI runs this class twice, in light and in dark mode, and says which
/// through `TEST_RUNNER_FREEFLOW_APPEARANCE`. The keyboard states come from
/// the `-FreeFlowUITestKeyboardState` hook, which makes a DEBUG simulator
/// keyboard show a fixed state (KeyboardDebugDisplayState).
final class FreeFlowScreenshotTests: FreeFlowKeyboardTestCase {
    /// Hook values, one per screenshot. Messages are synthetic.
    static let keyboardStates = [
        "idle",
        "setup-needed:fullAccess",
        "setup-needed:microphone",
        "setup-needed:apiKey",
        "starting",
        "recording:tap",
        "recording:hold",
        "processing",
        "inserted:dictation",
        "inserted:rawFallback",
        "inserted:returnOnly",
        "inserted:lastDictation",
        "inserted:handoff",
        "nothing-to-insert:emptyTranscript",
        "nothing-to-insert:noAudio",
        "nothing-to-insert:noHistory",
        "error",
        "error:The synthetic provider is unavailable. Try again later.",
        "fallback-available:captureUnavailable",
        "fallback-available:lowMemory",
        "fallback-available:openFailed",
        "waiting-for-app",
        "pending-insert",
    ]

    private var appearance: String {
        ProcessInfo.processInfo.environment["FREEFLOW_APPEARANCE"] ?? "light"
    }

    @MainActor
    func testKeyboardStateScreenshots() throws {
        var missing: [String] = []
        for hookValue in Self.keyboardStates {
            var options = FreeFlowLaunchOptions.dictationReady
            options.keyboardState = hookValue
            let session = try openFreeFlowKeyboard(options)
            let expected = String(hookValue.split(separator: ":").first ?? "")
            let shown = waitUntil(timeout: 10) { session.keyboard.status?.state == expected }
            let name = "kb-\(Self.slug(hookValue))-\(appearance)"
            captureNamed(name)
            if !shown {
                missing.append("\(hookValue) showed \(describe(session.keyboard.status))")
            }
        }
        XCTAssertTrue(missing.isEmpty, "States the keyboard didn't show: \(missing.joined(separator: "; "))")
        report("Captured \(Self.keyboardStates.count) keyboard states in \(appearance) mode")
    }

    /// `recording:hold` becomes `recording-hold`; an error message becomes
    /// `message`.
    static func slug(_ hookValue: String) -> String {
        let parts = hookValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return hookValue }
        if parts[0] == "error" {
            return "error-message"
        }
        return "\(parts[0])-\(parts[1])"
    }
}
