import Foundation

/// Language choices, copied from the macOS app so both apps offer the same
/// options: `transcriptionLanguages` mirrors
/// `AppState.transcriptionLanguageOptions` and `outputLanguages` mirrors
/// `SettingsView.outputLanguageOptions`.
enum LanguageOptions {
    /// ISO code and English name. An empty code means auto-detect.
    static let transcriptionLanguages: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("no", "Norwegian"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("cs", "Czech"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("ca", "Catalan")
    ]

    /// English names. An empty value means "Same as spoken".
    static let outputLanguages: [String] = [
        "",
        "English",
        "Chinese (Simplified)",
        "Chinese (Traditional)",
        "Spanish",
        "French",
        "Japanese",
        "Korean",
        "German",
        "Portuguese",
    ]

    /// The English name the cleanup prompt expects for a transcription
    /// language code, or "" for auto-detect and unknown codes. Codes are
    /// matched case-insensitively, like macOS `dictationLanguageName(for:)`.
    static func transcriptionLanguageName(forCode code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }
        return transcriptionLanguages.first(where: { $0.code == normalized })?.name ?? ""
    }
}
