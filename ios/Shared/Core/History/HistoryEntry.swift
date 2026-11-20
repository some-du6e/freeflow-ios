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
        self.errorMessage = errorMessage
        self.durationSeconds = durationSeconds
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
