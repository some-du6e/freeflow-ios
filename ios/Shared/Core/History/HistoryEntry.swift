import Foundation

/// One dictation, kept on the device in the App Group so the app's History
/// screen and the keyboard's "insert last" key can read it. Text only: no
/// audio, prompts, or surrounding-document text are stored.
struct HistoryEntry: Codable, Equatable, Identifiable {
    enum Source: String, Codable, Equatable {
        case keyboard
        case app
    }

    enum Status: String, Codable, Equatable {
        /// Text was inserted into the field.
        case inserted
        /// The transcript or cleanup result was empty.
        case nothingToInsert
        /// Cleanup or translation failed and the raw transcript was inserted.
        case rawFallback
        /// Transcription failed; `errorMessage` says why.
        case failed
        case cancelled
        /// Recorded in the app for a keyboard waiting to insert the result.
        case handedOff
        /// Finished, but the field changed before insertion.
        case notInserted
    }

    var id: UUID
    var createdAt: Date
    var source: Source
    var status: Status
    var rawTranscript: String
    var text: String
    var route: DictationRoute?
    /// True when cleanup or translation failed and `text` is the raw
    /// transcript, whatever `route` says. Optional so history saved before
    /// this field existed still decodes (the key is simply missing); nil
    /// means there was no fallback.
    var usedRawFallback: Bool?
    var errorMessage: String?
    var durationSeconds: Double

    init(
        id: UUID = UUID(),
        createdAt: Date,
        source: Source,
        status: Status,
        rawTranscript: String,
        text: String,
        route: DictationRoute? = nil,
        usedRawFallback: Bool = false,
        errorMessage: String? = nil,
        durationSeconds: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.status = status
        self.rawTranscript = rawTranscript
        self.text = text
        self.route = route
        // Stored only when set, so entries without a fallback encode exactly
        // as before.
        self.usedRawFallback = usedRawFallback ? true : nil
        self.errorMessage = errorMessage
        self.durationSeconds = durationSeconds
    }

    /// The text is the raw transcript because cleanup or translation failed.
    /// Entries written before `usedRawFallback` existed still say so through
    /// the keyboard's `.rawFallback` status.
    var fellBackToRawTranscript: Bool {
        usedRawFallback == true || status == .rawFallback
    }
}

extension HistoryEntry {
    /// An entry for a finished dictation, recording its raw and final text
    /// and route. `status` defaults to `Status.forInsertion(of:)`; pass
    /// `.handedOff` or `.notInserted` when the text wasn't inserted.
    init(
        result: DictationResult,
        source: Source,
        status: Status? = nil,
        createdAt: Date,
        durationSeconds: Double
    ) {
        self.init(
            createdAt: createdAt,
            source: source,
            status: status ?? .forInsertion(of: result),
            rawTranscript: result.rawTranscript,
            text: result.text,
            route: result.route,
            usedRawFallback: result.usedRawFallback,
            durationSeconds: durationSeconds
        )
    }
}

extension HistoryEntry.Status {
    /// What an inserted result means: nothing to insert, the raw-transcript
    /// fallback, or a normal insertion. Both the keyboard and the app's
    /// recorder use this, so "press enter" alone (return, but no text) is
    /// `.nothingToInsert` whichever wrote it. Whitespace counts as no text,
    /// as it does for the keyboard's insertion.
    static func forInsertion(of result: DictationResult) -> HistoryEntry.Status {
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .nothingToInsert
        }
        return result.usedRawFallback ? .rawFallback : .inserted
    }
}

/// Pure (de)serialization and trimming for the history file. The macOS app
/// keeps the newest 20 runs; so does iOS.
enum HistoryLog {
    static let maxEntries = 20

    static func decode(_ data: Data?) -> [HistoryEntry] {
        guard let data, let entries = try? makeDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func encode(_ entries: [HistoryEntry]) throws -> Data {
        try makeEncoder().encode(entries)
    }

    /// Newest first, trimmed to `maxEntries`.
    static func appending(_ entry: HistoryEntry, to entries: [HistoryEntry]) -> [HistoryEntry] {
        var updated = entries.filter { $0.id != entry.id }
        updated.insert(entry, at: 0)
        updated.sort { $0.createdAt > $1.createdAt }
        return Array(updated.prefix(maxEntries))
    }

    /// The newest entry text worth re-inserting ("Paste Again" on macOS).
    static func latestInsertableText(in entries: [HistoryEntry]) -> String? {
        entries.first(where: { !$0.text.isEmpty && $0.status != .failed && $0.status != .cancelled })?.text
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
