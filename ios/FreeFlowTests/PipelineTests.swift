import XCTest
@testable import FreeFlow

/// DictationPipeline on the iOS runtime, with a canned chat-completions
/// transport. The full routing matrix runs in the macOS `make test` runner
/// (Tests/IOSSharedCoreTests.swift); these cover the iOS Foundation, whose
/// URL parsing differs from older macOS releases.
final class PipelineTests: XCTestCase {
    private let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("ios-pipeline-synthetic.wav")

    func testCleanupRoute() async throws {
        let provider = CannedProvider { _ in .content("The build is ready.") }
        let pipeline = DictationPipeline(transcribe: { _, _ in "the build is ready" }, transport: provider.transport)

        let result = try await pipeline.run(audioFileURL: audioURL, configuration: makeConfiguration())
        XCTAssertEqual(result, DictationResult(
            rawTranscript: "the build is ready",
            text: "The build is ready.",
            pressEnter: false,
            route: .cleanup,
            usedRawFallback: false
        ))
        XCTAssertEqual(provider.urls, ["https://llm.example.invalid/v1/chat/completions"])
    }

    func testServerErrorFallsBackToRawTranscript() async throws {
        let provider = CannedProvider { _ in .status(503) }
        let pipeline = DictationPipeline(transcribe: { _, _ in "the build is ready press enter" }, transport: provider.transport)

        let result = try await pipeline.run(audioFileURL: audioURL, configuration: makeConfiguration())
        XCTAssertEqual(result, DictationResult(
            rawTranscript: "the build is ready",
            text: "the build is ready",
            pressEnter: true,
            route: .cleanup,
            usedRawFallback: true
        ))
    }

    /// PostProcessingService force-unwraps the URL it builds from the base
    /// URL. None of these may crash: each either falls back to the raw
    /// transcript without a request, or sends a well-formed one.
    func testUnusualBaseURLsNeverCrash() async throws {
        let baseURLs = [
            "", "not a url", "https://", "ftp://llm.example.invalid/v1", "https://llm example.invalid/v1",
            "https://llm.example.invalid/v 1", "https://llm.example.invalid/v1?mode=1", "https://llm.example.invalid/ünï/v1",
        ]
        for baseURL in baseURLs {
            let provider = CannedProvider { _ in .content("The build is ready.") }
            let pipeline = DictationPipeline(transcribe: { _, _ in "the build is ready" }, transport: provider.transport)
            var configuration = makeConfiguration()
            configuration.baseURL = baseURL

            let result = try await pipeline.run(audioFileURL: audioURL, configuration: configuration)
            let urls = provider.urls
            if urls.isEmpty {
                XCTAssertEqual(result.text, "the build is ready", "'\(baseURL)' must fall back to the raw transcript")
                XCTAssertTrue(result.usedRawFallback, "'\(baseURL)' must report the raw fallback")
            } else {
                XCTAssertEqual(result.text, "The build is ready.", "'\(baseURL)'")
                for url in urls {
                    XCTAssertTrue(url.hasSuffix("/chat/completions"), "'\(baseURL)' sent \(url)")
                    XCTAssertFalse(url.contains("//chat"), "'\(baseURL)' sent \(url)")
                }
            }
        }
    }

    func testTranscriptionErrorPropagates() async {
        let provider = CannedProvider { _ in .content("unused") }
        let pipeline = DictationPipeline(
            transcribe: { _, _ in throw URLError(.notConnectedToInternet) },
            transport: provider.transport
        )

        do {
            _ = try await pipeline.run(audioFileURL: audioURL, configuration: makeConfiguration())
            XCTFail("A transcription error must propagate")
        } catch {
            XCTAssertEqual(DictationPipeline.userFacingMessage(for: error, isOnline: false), "No internet — check connection")
        }
        XCTAssertEqual(provider.urls, [])
    }

    func testDefaultTranscriberRejectsAnInvalidURLWithoutNetwork() async {
        var configuration = makeConfiguration()
        configuration.transcriptionBaseURL = "ftp://stt.example.invalid/v1"
        let provider = CannedProvider { _ in .content("unused") }
        let pipeline = DictationPipeline(transport: provider.transport)

        do {
            _ = try await pipeline.run(audioFileURL: audioURL, configuration: configuration)
            XCTFail("An invalid transcription URL must throw")
        } catch {
            XCTAssertEqual(
                DictationPipeline.userFacingMessage(for: error, isOnline: true),
                "Invalid provider URL: Provider URL must use http or https."
            )
        }
        XCTAssertEqual(provider.urls, [])
    }

    func testInsertionSpacing() {
        XCTAssertEqual(TranscriptRouting.insertionText(for: "Next one.", precedingText: "Done."), " Next one. ")
        XCTAssertEqual(TranscriptRouting.insertionText(for: "next", precedingText: "word "), "next")
        XCTAssertEqual(TranscriptRouting.insertionText(for: "世界", precedingText: "你好"), "世界")
    }

    // MARK: - Helpers

    private func makeConfiguration() -> DictationConfiguration {
        DictationConfiguration(
            apiKey: "ios-synthetic-key",
            baseURL: "https://llm.example.invalid/v1",
            transcriptionAPIKey: "ios-synthetic-key",
            transcriptionBaseURL: "https://stt.example.invalid/v1",
            transcriptionModel: "whisper-large-v3",
            transcriptionLanguageCode: "",
            postProcessingModel: "ios-xctest-primary",
            postProcessingFallbackModel: "ios-xctest-fallback",
            customSystemPrompt: "",
            customVocabulary: "",
            outputLanguage: "",
            preserveExactWording: false,
            instructionExecutionGuardEnabled: true,
            pressEnterVoiceCommandEnabled: true,
            voiceMacros: []
        )
    }
}

/// Answers chat-completions requests with canned replies and records the
/// URLs it was sent.
private final class CannedProvider: @unchecked Sendable {
    enum Reply {
        case content(String)
        case status(Int)
    }

    private let lock = NSLock()
    private var recordedURLs: [String] = []
    private let reply: @Sendable (_ model: String) -> Reply

    init(reply: @escaping @Sendable (_ model: String) -> Reply) {
        self.reply = reply
    }

    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    var transport: DictationPipeline.Transport {
        { [self] request in try self.respond(to: request) }
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        lock.lock()
        recordedURLs.append(url.absoluteString)
        lock.unlock()

        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        switch reply(body?["model"] as? String ?? "") {
        case .content(let content):
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .status(let statusCode):
            let data = Data(#"{"error":{"message":"synthetic failure"}}"#.utf8)
            return (data, HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
        }
    }
}
