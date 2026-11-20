import Foundation

/// Pure text rules applied around the provider calls, mirroring the macOS
/// app's `processTranscript` helpers in Sources/AppState.swift.
///
/// CONTRACT STUB: owned by the shared-pipeline agent, which replaces these
/// bodies with the real rules and adds tests. Keep the signatures.
enum TranscriptRouting {
    /// Removes a trailing spoken "press enter" when the command is enabled,
    /// using the same pattern as macOS (`trailingPressEnterCommandPattern`).
    static func strippingPressEnter(
        from transcript: String,
        enabled: Bool
    ) -> (text: String, pressEnter: Bool) {
        (transcript, false)
    }

    /// The macro whose command matches the whole transcript, compared the way
    /// macOS does (lowercased, punctuation and surrounding whitespace removed).
    static func matchingMacro(for transcript: String, in macros: [VoiceMacro]) -> VoiceMacro? {
        nil
    }

    /// Final text for `textDocumentProxy.insertText`: the macOS trailing-space
    /// rule (a space after a final ".", "!" or "?"), plus a leading space when
    /// the text before the cursor ends in a non-whitespace character and the
    /// insertion starts with a letter or digit.
    static func insertionText(for text: String, precedingText: String?) -> String {
        text
    }
}
