import Foundation

/// Pure text rules applied around the provider calls. The press-enter and
/// macro rules are copies of the macOS app's `processTranscript` helpers in
/// Sources/AppState.swift; keep them identical.
enum TranscriptRouting {
    /// Copied verbatim from `AppState.trailingPressEnterCommandPattern`
    /// (Sources/AppState.swift:285-287).
    static let trailingPressEnterCommandPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    /// Removes a trailing spoken "press enter" when the command is enabled,
    /// exactly like macOS `AppState.parseTranscriptCommands`: the returned
    /// text is always trimmed, and only the last "press enter" is removed.
    static func strippingPressEnter(
        from transcript: String,
        enabled: Bool
    ) -> (text: String, pressEnter: Bool) {
        let unchanged: (text: String, pressEnter: Bool) = (
            transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            false
        )
        guard enabled else { return unchanged }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard
            let match = trailingPressEnterCommandPattern.firstMatch(in: transcript, range: fullRange),
            let commandRange = Range(match.range, in: transcript)
        else {
            return unchanged
        }

        var strippedTranscript = transcript
        strippedTranscript.removeSubrange(commandRange)
        return (strippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// The macOS `AppState.normalize` used for macro matching: lowercased,
    /// punctuation removed, then trimmed. Inner whitespace is left as is.
    static func normalizedMacroText(_ text: String) -> String {
        let lowercased = text.lowercased()
        let strippedPunctuation = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return strippedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first macro whose command matches the whole transcript, compared
    /// the way macOS `findMatchingMacro` does (`normalizedMacroText` on both
    /// sides). A transcript that normalizes to "" matches nothing.
    static func matchingMacro(for transcript: String, in macros: [VoiceMacro]) -> VoiceMacro? {
        let normalizedTranscript = normalizedMacroText(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }
        return macros.first { normalizedMacroText($0.command) == normalizedTranscript }
    }

    /// Final text for `textDocumentProxy.insertText`.
    ///
    /// - The macOS trailing-space rule (`AppState.transcriptTextForInsertion`):
    ///   a space after a final ".", "!" or "?".
    /// - An iOS smart leading space (see `needsLeadingSpace`), because the
    ///   keyboard inserts at the cursor instead of pasting a whole dictation.
    static func insertionText(for text: String, precedingText: String?) -> String {
        guard !text.isEmpty else { return "" }
        var result = text
        if let last = result.last, ".!?".contains(last) {
            result += " "
        }
        if needsLeadingSpace(before: text, precedingText: precedingText) {
            result = " " + result
        }
        return result
    }

    /// True when `insertion` starts with a letter or digit and the text
    /// before the cursor ends in a word, a number, closing punctuation
    /// (`. , ! ? ; : ) ] } % …` and closing quotes) or an emoji. Nothing is
    /// added at the start of a field, after whitespace, after opening
    /// brackets or quotes, after joiners such as "-", "/" or "@", or next to
    /// scripts written without spaces between words (Chinese, Japanese,
    /// Thai and similar).
    static func needsLeadingSpace(before insertion: String, precedingText: String?) -> Bool {
        guard
            let preceding = precedingText,
            let previous = preceding.last,
            let first = insertion.first,
            isSpacedWordCharacter(first)
        else {
            return false
        }
        if isSpacedWordCharacter(previous) || closingPunctuation.contains(previous) {
            return true
        }
        if previous == "\"" || previous == "'" {
            return straightQuoteCloses(preceding)
        }
        return isEmoji(previous)
    }

    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "%", "…", "”", "’", "»",
    ]

    private static let openingPunctuation: Set<Character> = [
        "(", "[", "{", "“", "‘", "«", "„", "‚",
    ]

    /// A straight quote right after whitespace, an opening bracket or the
    /// start of the text opens a quotation; anywhere else it closes one.
    private static func straightQuoteCloses(_ text: String) -> Bool {
        guard let beforeQuote = text.dropLast().last else { return false }
        return !beforeQuote.isWhitespace && !openingPunctuation.contains(beforeQuote)
    }

    private static func isSpacedWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !isUnspacedScript(character)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
        }
    }

    /// Scripts that don't put spaces between words.
    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF, // Thai, Lao
             0x0F00...0x0FFF, // Tibetan
             0x1000...0x109F, // Myanmar
             0x1780...0x17FF, // Khmer
             0x2E80...0x2FDF, // CJK and Kangxi radicals
             0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3100...0x312F, // Bopomofo
             0x31A0...0x31FF, // Bopomofo extended, Katakana extensions
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x20000...0x3FFFF: // CJK Extension B and later
            return true
        default:
            return false
        }
    }
}
