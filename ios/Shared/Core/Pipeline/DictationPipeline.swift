import Foundation

/// Which processing path produced the final text, mirroring the order of the
/// macOS `processTranscript` (Sources/AppState.swift:2707-2802).
enum DictationRoute: String, Codable, Equatable {
    case empty
    case macro
    case verbatim
    case translation
    case cleanup
}

struct DictationResult: Equatable {
    var rawTranscript: String
    /// Text to insert before `TranscriptRouting.insertionText` spacing.
    /// Empty means "nothing to insert".
    var text: String
    var pressEnter: Bool
    var route: DictationRoute
    /// True when cleanup or translation failed and the raw transcript is used.
    var usedRawFallback: Bool
}

/// Transcribes a recorded WAV and turns the transcript into insertable text,
/// using the shared macOS services (TranscriptionService and
/// PostProcessingService) with the same routing and silent fallbacks.
///
/// CONTRACT STUB: owned by the shared-pipeline agent, which implements
/// `run` and the default transcriber and adds tests. Keep the signatures.
final class DictationPipeline {
    typealias Transcribe = @Sendable (_ audioFileURL: URL, _ configuration: DictationConfiguration) async throws -> String
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transcribe: Transcribe
    private let transport: Transport

    init(
        transcribe: @escaping Transcribe = DictationPipeline.transcribeWithService,
        transport: @escaping Transport = { try await LLMAPITransport.data(for: $0) }
    ) {
        self.transcribe = transcribe
        self.transport = transport
    }

    /// Uploads the file with TranscriptionService using the configuration's
    /// transcription URL, key, model and language.
    static let transcribeWithService: Transcribe = { audioFileURL, configuration in
        let service = try TranscriptionService(
            apiKey: configuration.transcriptionAPIKey,
            baseURL: configuration.transcriptionBaseURL,
            transcriptionModel: configuration.transcriptionModel,
            language: configuration.transcriptionLanguageCode
        )
        return try await service.transcribe(fileURL: audioFileURL)
    }

    /// Throws transcription errors; LLM failures fall back to the raw
    /// transcript exactly as on macOS and never throw.
    func run(audioFileURL: URL, configuration: DictationConfiguration) async throws -> DictationResult {
        let raw = try await transcribe(audioFileURL, configuration)
        return DictationResult(rawTranscript: raw, text: raw, pressEnter: false, route: .verbatim, usedRawFallback: false)
    }

    /// The short message to show for an error thrown by `run`, using
    /// TranscriptionErrorPresentationCore like macOS.
    static func userFacingMessage(for error: Error, isOnline: Bool) -> String {
        TranscriptionErrorPresentationCore.message(for: error, isOnline: isOnline)
    }
}
