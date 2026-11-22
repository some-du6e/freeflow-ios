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
    /// The transcript after "press enter" was stripped and whitespace
    /// trimmed: what macOS records as the raw transcript, and what is
    /// inserted when cleanup or translation fails.
    var rawTranscript: String
    /// Trimmed text to insert before `TranscriptRouting.insertionText`
    /// spacing. Empty means "nothing to insert"; `route` is then `.empty`.
    var text: String
    /// A trailing "press enter" was spoken. It is set even when `text` is
    /// empty: macOS still presses Enter for a bare "press enter".
    var pressEnter: Bool
    var route: DictationRoute
    /// True when cleanup or translation failed and the raw transcript is used.
    var usedRawFallback: Bool
}

/// Transcribes a recorded WAV and turns the transcript into insertable text,
/// using the shared macOS services (TranscriptionService and
/// PostProcessingService) with the same routing and silent fallbacks as the
/// macOS `processTranscript`:
///
/// 1. Strip a trailing "press enter"; an empty transcript is `.empty`.
/// 2. A voice macro whose command matches inserts its payload.
/// 3. Preserve exact wording inserts the raw transcript, or a verbatim
///    translation when an output language is set.
/// 4. Otherwise cleanup runs with the context-off `AppContext`.
///
/// Every LLM failure, including an unusable base URL, falls back to the raw
/// transcript and never throws. Transcription errors and cancellation throw.
final class DictationPipeline: Sendable {
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

    /// Throws transcription errors, and `CancellationError` when the calling
    /// task is cancelled (macOS checks for cancellation at the same points).
    /// LLM failures fall back to the raw transcript exactly as on macOS and
    /// never throw.
    func run(audioFileURL: URL, configuration: DictationConfiguration) async throws -> DictationResult {
        let transcript = try await transcribe(audioFileURL, configuration)
        try Task.checkCancellation()

        let command = TranscriptRouting.strippingPressEnter(
            from: transcript,
            enabled: configuration.pressEnterVoiceCommandEnabled
        )
        let rawTranscript = command.text
        guard !rawTranscript.isEmpty else {
            return DictationResult(
                rawTranscript: "",
                text: "",
                pressEnter: command.pressEnter,
                route: .empty,
                usedRawFallback: false
            )
        }

        let processed = await process(rawTranscript, configuration: configuration)
        try Task.checkCancellation()

        // macOS trims the final transcript, macro payloads included, before
        // inserting it, and treats an empty result as "nothing to insert".
        let text = processed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationResult(
            rawTranscript: rawTranscript,
            text: text,
            pressEnter: command.pressEnter,
            route: text.isEmpty ? .empty : processed.route,
            usedRawFallback: processed.usedRawFallback
        )
    }

    /// The short message to show for an error thrown by `run`, using
    /// TranscriptionErrorPresentationCore like macOS. Cancellation reads
    /// "Cancelled", the macOS status for a cancelled dictation.
    static func userFacingMessage(for error: Error, isOnline: Bool) -> String {
        if isCancellation(error) {
            return "Cancelled"
        }
        return TranscriptionErrorPresentationCore.message(for: error, isOnline: isOnline)
    }

    /// True for an error that means the run was cancelled rather than failed.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    /// The cleanup base URL in the form PostProcessingService joins with
    /// "/chat/completions" and force-unwraps, or nil when that join would
    /// not be a usable URL. Uses TranscriptionService's rules (http or https
    /// with a host) and drops trailing slashes so the join can't produce
    /// "//". A query or fragment is rejected, since the join would append
    /// the path after it.
    static func validatedLLMBaseURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }

        components.scheme = scheme
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        guard
            let normalized = components.string,
            URL(string: "\(normalized)/chat/completions") != nil
        else {
            return nil
        }
        return normalized
    }

    /// The macOS context-off context (`AppState.disabledContext`). Its
    /// activity is filtered out of the prompt, so cleanup gets no CONTEXT
    /// section. iOS v1 sends no document text to providers.
    static var contextOffAppContext: AppContext {
        AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: "Active window context disabled.",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "Disabled in Settings"
        )
    }

    private struct ProcessedTranscript {
        var text: String
        var route: DictationRoute
        var usedRawFallback: Bool
    }

    /// The macOS `processTranscript` routing after the empty check. Edit Mode
    /// is out of scope for iOS v1.
    private func process(_ rawTranscript: String, configuration: DictationConfiguration) async -> ProcessedTranscript {
        if let macro = TranscriptRouting.matchingMacro(for: rawTranscript, in: configuration.voiceMacros) {
            return ProcessedTranscript(text: macro.payload, route: .macro, usedRawFallback: false)
        }

        if configuration.preserveExactWording {
            let targetLanguage = configuration.outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetLanguage.isEmpty else {
                return ProcessedTranscript(text: rawTranscript, route: .verbatim, usedRawFallback: false)
            }
            guard let service = makePostProcessingService(for: configuration) else {
                return ProcessedTranscript(text: rawTranscript, route: .translation, usedRawFallback: true)
            }
            do {
                let result = try await service.translateVerbatim(
                    transcript: rawTranscript,
                    targetLanguage: targetLanguage
                )
                return ProcessedTranscript(text: result.transcript, route: .translation, usedRawFallback: false)
            } catch {
                return ProcessedTranscript(text: rawTranscript, route: .translation, usedRawFallback: true)
            }
        }

        guard let service = makePostProcessingService(for: configuration) else {
            return ProcessedTranscript(text: rawTranscript, route: .cleanup, usedRawFallback: true)
        }
        do {
            let result = try await service.postProcess(
                transcript: rawTranscript,
                context: Self.contextOffAppContext,
                customVocabulary: configuration.customVocabulary,
                customSystemPrompt: configuration.customSystemPrompt,
                outputLanguage: configuration.outputLanguage,
                dictationLanguage: configuration.dictationLanguageName
            )
            return ProcessedTranscript(text: result.transcript, route: .cleanup, usedRawFallback: false)
        } catch {
            return ProcessedTranscript(text: rawTranscript, route: .cleanup, usedRawFallback: true)
        }
    }

    /// nil when the base URL would crash PostProcessingService's
    /// force-unwrapped request URL.
    private func makePostProcessingService(for configuration: DictationConfiguration) -> PostProcessingService? {
        guard let baseURL = Self.validatedLLMBaseURL(configuration.baseURL) else {
            return nil
        }
        return PostProcessingService(
            apiKey: configuration.apiKey,
            baseURL: baseURL,
            preferredModel: configuration.postProcessingModel,
            preferredFallbackModel: configuration.postProcessingFallbackModel,
            instructionExecutionGuardEnabled: configuration.instructionExecutionGuardEnabled,
            transport: transport
        )
    }
}
