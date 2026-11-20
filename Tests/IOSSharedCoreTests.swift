import Foundation

/// Tests for the Foundation-only iOS settings, pipeline, history and handoff
/// helpers in ios/Shared/Core (everything except Audio and Keyboard).
enum IOSSharedCoreTests {
    static func run() async {
        testConfigurationRequiresAPIKey()
        testConfigurationFallsBackLikeMacOS()
        testConfigurationReadsStoredValues()
        testHistoryKeepsNewestTwenty()
        testHistoryRoundTripsAndSkipsFailedEntries()
        testPendingDictationFreshness()
        testLanguageNames()

        testConfigurationNormalizesTranscriptionLanguage()
        testConfigurationResetsDeprecatedFallbackModel()
        testConfigurationMigratesRetiredGroqModelsOnlyOnGroq()
        testPressEnterStripping()
        testMacroMatching()
        testInsertionTrailingSpace()
        testInsertionLeadingSpace()
        testValidatedLLMBaseURL()
        testHistoryEntryFromResult()
        testUserFacingMessages()

        await testEmptyTranscriptSkipsProviders()
        await testPressEnterOnlyTranscript()
        await testMacroRoute()
        await testVerbatimRoute()
        await testTranslationRoute()
        await testTranslationFailureFallsBackToRaw()
        await testTranslationRetriesFallbackModelOnRateLimit()
        await testCleanupRequest()
        await testCleanupPromptOptions()
        await testCleanupRetriesFallbackModelOnEmptyOutput()
        await testCleanupRetriesFallbackModelOnRateLimit()
        await testCleanupServerErrorFallsBackToRawWithoutRetry()
        await testCleanupFallsBackToRawWhenBothModelsReturnNothing()
        await testCleanupTransportErrorFallsBackToRaw()
        await testCleanupEmptySentinelMeansNothingToInsert()
        await testInstructionGuard()
        await testBothModelsCoolingDownSkipsCleanup()
        await testUnusableBaseURLFallsBackWithoutRequests()
        await testBaseURLTrailingSlashesAreDropped()
        await testTranscriberGetsAudioAndConfiguration()
        await testTranscriptionErrorsPropagate()
        await testDefaultTranscriberRejectsInvalidURLWithoutNetwork()
        await testCancellationDuringCleanupThrows()
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "FreeFlowTests.IOSSharedCore.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private static func testConfigurationRequiresAPIKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expect(
            DictationConfiguration.resolve(defaults: defaults, apiKey: nil, transcriptionAPIKey: nil) == nil,
            "A missing API key must mean setup is needed"
        )
        TestSupport.expect(
            DictationConfiguration.resolve(defaults: defaults, apiKey: "  \n", transcriptionAPIKey: "unused") == nil,
            "A blank API key must mean setup is needed"
        )
    }

    private static func testConfigurationFallsBackLikeMacOS() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        guard let configuration = DictationConfiguration.resolve(
            defaults: defaults,
            apiKey: " key-main ",
            transcriptionAPIKey: ""
        ) else {
            TestSupport.expect(false, "A non-empty API key must resolve")
            return
        }
        TestSupport.expectEqual(configuration.apiKey, "key-main")
        TestSupport.expectEqual(configuration.baseURL, FreeFlowSettingDefaults.apiBaseURL)
        TestSupport.expectEqual(configuration.transcriptionAPIKey, "key-main")
        TestSupport.expectEqual(configuration.transcriptionBaseURL, FreeFlowSettingDefaults.apiBaseURL)
        TestSupport.expectEqual(configuration.transcriptionModel, FreeFlowSettingDefaults.transcriptionModel)
        TestSupport.expectEqual(configuration.postProcessingModel, FreeFlowSettingDefaults.postProcessingModel)
        TestSupport.expectEqual(configuration.postProcessingFallbackModel, FreeFlowSettingDefaults.postProcessingFallbackModel)
        TestSupport.expectEqual(configuration.transcriptionLanguageCode, "")
        TestSupport.expectEqual(configuration.dictationLanguageName, "")
        TestSupport.expect(!configuration.preserveExactWording, "Cleanup must be on by default")
        TestSupport.expect(configuration.instructionExecutionGuardEnabled, "The instruction guard must default on")
        TestSupport.expect(configuration.pressEnterVoiceCommandEnabled, "'press enter' must default on")
        TestSupport.expectEqual(configuration.voiceMacros, [])
    }

    private static func testConfigurationReadsStoredValues() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("https://llm.example.invalid/v1", forKey: FreeFlowSettingKey.apiBaseURL)
        defaults.set("https://stt.example.invalid/v1", forKey: FreeFlowSettingKey.transcriptionAPIURL)
        defaults.set("es", forKey: FreeFlowSettingKey.transcriptionLanguage)
        defaults.set("French", forKey: FreeFlowSettingKey.outputLanguage)
        defaults.set(true, forKey: FreeFlowSettingKey.preserveExactWording)
        defaults.set(false, forKey: FreeFlowSettingKey.pressEnterVoiceCommandEnabled)
        let macro = VoiceMacro(command: "sign off", payload: "Thanks,\nSam")
        defaults.set(VoiceMacroCodec.encode([macro]), forKey: FreeFlowSettingKey.voiceMacros)

        guard let configuration = DictationConfiguration.resolve(
            defaults: defaults,
            apiKey: "key-main",
            transcriptionAPIKey: "key-stt"
        ) else {
            TestSupport.expect(false, "Stored settings must resolve")
            return
        }
        TestSupport.expectEqual(configuration.baseURL, "https://llm.example.invalid/v1")
        TestSupport.expectEqual(configuration.transcriptionBaseURL, "https://stt.example.invalid/v1")
        TestSupport.expectEqual(configuration.transcriptionAPIKey, "key-stt")
        TestSupport.expectEqual(configuration.dictationLanguageName, "Spanish")
        TestSupport.expectEqual(configuration.outputLanguage, "French")
        TestSupport.expect(configuration.preserveExactWording, "A stored exact-wording choice must be read")
        TestSupport.expect(!configuration.pressEnterVoiceCommandEnabled, "A stored 'press enter' choice must be read")
        TestSupport.expectEqual(configuration.voiceMacros, [macro])
    }

    private static func testHistoryKeepsNewestTwenty() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var entries: [HistoryEntry] = []
        for index in 0..<25 {
            let entry = HistoryEntry(
                createdAt: start.addingTimeInterval(TimeInterval(index)),
                source: .keyboard,
                status: .inserted,
                rawTranscript: "raw \(index)",
                text: "text \(index)",
                durationSeconds: 1
            )
            entries = HistoryLog.appending(entry, to: entries)
        }
        TestSupport.expectEqual(entries.count, HistoryLog.maxEntries)
        TestSupport.expectEqual(entries.first?.text, "text 24")
        TestSupport.expectEqual(entries.last?.text, "text 5")
    }

    private static func testHistoryRoundTripsAndSkipsFailedEntries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = HistoryEntry(createdAt: now, source: .app, status: .inserted, rawTranscript: "a", text: "Hello there.", route: .cleanup, durationSeconds: 2)
        let failed = HistoryEntry(createdAt: now.addingTimeInterval(5), source: .keyboard, status: .failed, rawTranscript: "", text: "", errorMessage: "Request timed out", durationSeconds: 1)
        let entries = HistoryLog.appending(failed, to: HistoryLog.appending(older, to: []))

        guard let data = try? HistoryLog.encode(entries) else {
            TestSupport.expect(false, "History must encode")
            return
        }
        let decoded = HistoryLog.decode(data)
        TestSupport.expectEqual(decoded, entries)
        TestSupport.expectEqual(HistoryLog.latestInsertableText(in: decoded), "Hello there.")
        TestSupport.expectEqual(HistoryLog.decode(Data("not json".utf8)), [])
        TestSupport.expectEqual(HistoryLog.decode(nil), [])
    }

    private static func testPendingDictationFreshness() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = PendingDictation(sessionID: UUID(), createdAt: created, text: "Hi", pressEnter: false)
        TestSupport.expect(pending.isFresh(now: created.addingTimeInterval(30)), "A 30 s old result must be fresh")
        TestSupport.expect(!pending.isFresh(now: created.addingTimeInterval(PendingDictation.maxAge + 1)), "An expired result must not be inserted")
        TestSupport.expect(!pending.isFresh(now: created.addingTimeInterval(-60)), "A result from the future must not be trusted")
    }

    private static func testLanguageNames() {
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguageName(forCode: ""), "")
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguageName(forCode: "de"), "German")
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguageName(forCode: " DE "), "German")
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguageName(forCode: "xx"), "")
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguages.count, 30)
        TestSupport.expectEqual(LanguageOptions.outputLanguages.first, "")
    }

    // MARK: - Configuration migrations (macOS AppState.init equivalents)

    private static func testConfigurationNormalizesTranscriptionLanguage() {
        for (stored, code, name) in [(" ES ", "es", "Spanish"), ("xx", "", ""), ("", "", ""), ("zh", "zh", "Chinese")] {
            let (defaults, suite) = makeDefaults()
            defaults.set(stored, forKey: FreeFlowSettingKey.transcriptionLanguage)
            let configuration = DictationConfiguration.resolve(defaults: defaults, apiKey: "key", transcriptionAPIKey: nil)
            TestSupport.expect(
                configuration?.transcriptionLanguageCode == code,
                "Stored language '\(stored)' must resolve to code '\(code)'"
            )
            TestSupport.expect(
                configuration?.dictationLanguageName == name,
                "Stored language '\(stored)' must resolve to name '\(name)'"
            )
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static func testConfigurationResetsDeprecatedFallbackModel() {
        let deprecated = "meta-llama/llama-4-scout-17b-16e-instruct"
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(" \(deprecated) ", forKey: FreeFlowSettingKey.postProcessingFallbackModel)
        defaults.set(deprecated, forKey: FreeFlowSettingKey.postProcessingModel)

        let configuration = DictationConfiguration.resolve(defaults: defaults, apiKey: "key", transcriptionAPIKey: nil)
        TestSupport.expectEqual(configuration?.postProcessingFallbackModel, FreeFlowSettingDefaults.postProcessingFallbackModel)
        TestSupport.expectEqual(
            defaults.string(forKey: FreeFlowSettingKey.postProcessingFallbackModel),
            FreeFlowSettingDefaults.postProcessingFallbackModel
        )
        // macOS resets only the fallback model.
        TestSupport.expectEqual(configuration?.postProcessingModel, deprecated)

        let (customDefaults, customSuite) = makeDefaults()
        defer { customDefaults.removePersistentDomain(forName: customSuite) }
        customDefaults.set("ios-custom-fallback", forKey: FreeFlowSettingKey.postProcessingFallbackModel)
        DictationConfiguration.migrateLegacyModelSettings(in: customDefaults)
        TestSupport.expectEqual(customDefaults.string(forKey: FreeFlowSettingKey.postProcessingFallbackModel), "ios-custom-fallback")

        // The migration also runs without an API key, for the app's launch.
        let (keylessDefaults, keylessSuite) = makeDefaults()
        defer { keylessDefaults.removePersistentDomain(forName: keylessSuite) }
        keylessDefaults.set(deprecated, forKey: FreeFlowSettingKey.postProcessingFallbackModel)
        DictationConfiguration.migrateLegacyModelSettings(in: keylessDefaults)
        TestSupport.expectEqual(
            keylessDefaults.string(forKey: FreeFlowSettingKey.postProcessingFallbackModel),
            FreeFlowSettingDefaults.postProcessingFallbackModel
        )
    }

    private static func testConfigurationMigratesRetiredGroqModelsOnlyOnGroq() {
        let (groqDefaults, groqSuite) = makeDefaults()
        defer { groqDefaults.removePersistentDomain(forName: groqSuite) }
        groqDefaults.set("qwen/qwen3.6-27b", forKey: FreeFlowSettingKey.postProcessingModel)
        groqDefaults.set("QWEN3.6-27B", forKey: FreeFlowSettingKey.postProcessingFallbackModel)

        let onGroq = DictationConfiguration.resolve(defaults: groqDefaults, apiKey: "key", transcriptionAPIKey: nil)
        TestSupport.expectEqual(onGroq?.postProcessingModel, "qwen/qwen3.8-27b")
        TestSupport.expectEqual(onGroq?.postProcessingFallbackModel, "qwen/qwen3.8-27b")
        TestSupport.expectEqual(groqDefaults.string(forKey: FreeFlowSettingKey.postProcessingModel), "qwen/qwen3.8-27b")
        TestSupport.expectEqual(groqDefaults.string(forKey: FreeFlowSettingKey.postProcessingFallbackModel), "qwen/qwen3.8-27b")

        let (otherDefaults, otherSuite) = makeDefaults()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        otherDefaults.set("https://llm.example.invalid/v1", forKey: FreeFlowSettingKey.apiBaseURL)
        otherDefaults.set("qwen/qwen3.6-27b", forKey: FreeFlowSettingKey.postProcessingModel)

        let elsewhere = DictationConfiguration.resolve(defaults: otherDefaults, apiKey: "key", transcriptionAPIKey: nil)
        TestSupport.expectEqual(elsewhere?.postProcessingModel, "qwen/qwen3.6-27b")
        TestSupport.expectEqual(otherDefaults.string(forKey: FreeFlowSettingKey.postProcessingModel), "qwen/qwen3.6-27b")
    }

    // MARK: - Transcript routing rules

    private static func testPressEnterStripping() {
        let cases: [(input: String, enabled: Bool, text: String, pressEnter: Bool)] = [
            ("Send the report press enter", true, "Send the report", true),
            ("Send the report, press enter.", true, "Send the report", true),
            ("Press Enter", true, "", true),
            ("PRESS ENTER!!!", true, "", true),
            ("press\tenter", true, "", true),
            ("first line\npress enter", true, "first line", true),
            ("hello - press enter", true, "hello", true),
            ("Press enter… ", true, "", true),
            ("press enter press enter", true, "press enter", true),
            ("press enter please", true, "press enter please", false),
            ("I pressed enter", true, "I pressed enter", false),
            ("Decompress enter", true, "Decompress enter", false),
            ("  Send it press enter  ", false, "Send it press enter", false),
            ("  hello  ", true, "hello", false),
        ]
        for testCase in cases {
            let result = TranscriptRouting.strippingPressEnter(from: testCase.input, enabled: testCase.enabled)
            TestSupport.expect(
                result.text == testCase.text && result.pressEnter == testCase.pressEnter,
                "'\(testCase.input)' (enabled: \(testCase.enabled)) gave ('\(result.text)', \(result.pressEnter))"
            )
        }
    }

    private static func testMacroMatching() {
        let signOff = VoiceMacro(command: "Sign off", payload: "Thanks,\nSam")
        let hyphenated = VoiceMacro(command: "sign-off", payload: "Hyphenated")
        let blank = VoiceMacro(command: "  ", payload: "Never")
        let macros = [blank, signOff, hyphenated]

        for transcript in ["sign off", "Sign off.", "  SIGN OFF!  "] {
            TestSupport.expect(
                TranscriptRouting.matchingMacro(for: transcript, in: macros) == signOff,
                "'\(transcript)' must match the 'Sign off' macro"
            )
        }
        for transcript in ["signoff", "Sign-off"] {
            TestSupport.expect(
                TranscriptRouting.matchingMacro(for: transcript, in: macros) == hyphenated,
                "'\(transcript)' must match the hyphenated macro, as on macOS"
            )
        }
        for transcript in ["sign off now", "sign  off", "", "...", "  "] {
            TestSupport.expect(
                TranscriptRouting.matchingMacro(for: transcript, in: macros) == nil,
                "'\(transcript)' must not match any macro"
            )
        }

        let first = VoiceMacro(command: "hello", payload: "first")
        let second = VoiceMacro(command: "Hello!", payload: "second")
        TestSupport.expectEqual(TranscriptRouting.matchingMacro(for: "hello", in: [first, second]), first)
        TestSupport.expectEqual(TranscriptRouting.normalizedMacroText("  Sign-Off, now!  "), "signoff now")
    }

    private static func testInsertionTrailingSpace() {
        let cases: [(text: String, expected: String)] = [
            ("Hello there.", "Hello there. "),
            ("Really?", "Really? "),
            ("Wow!", "Wow! "),
            ("Hello", "Hello"),
            ("Done…", "Done…"),
            ("Thanks,\nSam", "Thanks,\nSam"),
            ("", ""),
        ]
        for testCase in cases {
            let result = TranscriptRouting.insertionText(for: testCase.text, precedingText: nil)
            TestSupport.expect(
                result == testCase.expected,
                "'\(testCase.text)' must insert as '\(testCase.expected)', got '\(result)'"
            )
        }
        TestSupport.expectEqual(TranscriptRouting.insertionText(for: "", precedingText: "word"), "")
    }

    private static func testInsertionLeadingSpace() {
        let cases: [(preceding: String?, text: String, expected: String)] = [
            ("previous", "next words", " next words"),
            ("End.", "Next.", " Next. "),
            ("Room", "42", " 42"),
            ("4", "items", " items"),
            ("Done…", "next", " next"),
            ("50%", "next", " next"),
            ("«quote»", "next", " next"),
            ("”", "next", " next"),
            ("\"hi\"", "she said", " she said"),
            ("the students'", "books", " books"),
            ("Great 👍", "thanks", " thanks"),
            ("네", "안녕하세요", " 안녕하세요"),
            ("да", "Привет", " Привет"),
            (nil, "next", "next"),
            ("", "next", "next"),
            ("previous ", "next", "next"),
            ("line\n", "Next", "Next"),
            ("note (", "aside", "aside"),
            ("he said \"", "quote", "quote"),
            ("“", "next", "next"),
            ("email@", "handle", "handle"),
            ("path/", "text", "text"),
            ("well-", "next", "next"),
            ("issue #", "42", "42"),
            ("items", ", and more", ", and more"),
            ("你好", "世界", "世界"),
            ("你好", "world", "world"),
            ("hello", "世界", "世界"),
            ("はい", "ありがとう", "ありがとう"),
            ("สวัสดี", "ครับ", "ครับ"),
        ]
        for testCase in cases {
            let result = TranscriptRouting.insertionText(for: testCase.text, precedingText: testCase.preceding)
            TestSupport.expect(
                result == testCase.expected,
                "'\(testCase.text)' after '\(testCase.preceding ?? "nil")' must insert as '\(testCase.expected)', got '\(result)'"
            )
        }
    }

    private static func testValidatedLLMBaseURL() {
        let valid: [(input: String, expected: String)] = [
            ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1"),
            (" https://api.groq.com/openai/v1/ ", "https://api.groq.com/openai/v1"),
            ("HTTPS://llm.example.invalid/v1//", "https://llm.example.invalid/v1"),
            ("http://127.0.0.1:8765/v1", "http://127.0.0.1:8765/v1"),
            ("https://llm.example.invalid", "https://llm.example.invalid"),
            ("https://llm.example.invalid/", "https://llm.example.invalid"),
        ]
        for testCase in valid {
            TestSupport.expect(
                DictationPipeline.validatedLLMBaseURL(testCase.input) == testCase.expected,
                "'\(testCase.input)' must normalize to '\(testCase.expected)'"
            )
        }
        let invalid = [
            "", "   ", "not a url", "llm.example.invalid/v1", "ftp://llm.example.invalid/v1",
            "https://", "https:///v1", "https://llm.example.invalid/v1?mode=1", "https://llm.example.invalid/v1#part",
        ]
        for input in invalid {
            TestSupport.expect(
                DictationPipeline.validatedLLMBaseURL(input) == nil,
                "'\(input)' must be rejected as a cleanup base URL"
            )
        }
    }

    private static func testHistoryEntryFromResult() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cleaned = DictationResult(rawTranscript: "raw words", text: "Clean words.", pressEnter: false, route: .cleanup, usedRawFallback: false)
        let fallback = DictationResult(rawTranscript: "raw words", text: "raw words", pressEnter: true, route: .cleanup, usedRawFallback: true)
        let empty = DictationResult(rawTranscript: "", text: "", pressEnter: true, route: .empty, usedRawFallback: false)

        let entry = HistoryEntry(result: cleaned, source: .keyboard, createdAt: createdAt, durationSeconds: 3)
        TestSupport.expectEqual(entry.status, .inserted)
        TestSupport.expectEqual(entry.rawTranscript, "raw words")
        TestSupport.expectEqual(entry.text, "Clean words.")
        TestSupport.expectEqual(entry.route, .cleanup)
        TestSupport.expectEqual(entry.source, .keyboard)
        TestSupport.expectEqual(entry.createdAt, createdAt)
        TestSupport.expectEqual(entry.durationSeconds, 3)
        TestSupport.expectEqual(HistoryEntry(result: fallback, source: .keyboard, createdAt: createdAt, durationSeconds: 1).status, .rawFallback)
        TestSupport.expectEqual(HistoryEntry(result: empty, source: .keyboard, createdAt: createdAt, durationSeconds: 1).status, .nothingToInsert)
        TestSupport.expectEqual(HistoryEntry(result: cleaned, source: .app, status: .handedOff, createdAt: createdAt, durationSeconds: 1).status, .handedOff)
    }

    private static func testUserFacingMessages() {
        TestSupport.expectEqual(DictationPipeline.userFacingMessage(for: URLError(.timedOut), isOnline: true), "Request timed out — try again")
        TestSupport.expectEqual(DictationPipeline.userFacingMessage(for: URLError(.timedOut), isOnline: false), "No internet — check connection")
        TestSupport.expectEqual(DictationPipeline.userFacingMessage(for: URLError(.notConnectedToInternet), isOnline: true), "No internet — check connection")
        TestSupport.expectEqual(
            DictationPipeline.userFacingMessage(for: TranscriptionError.submissionFailed("Synthetic rejection."), isOnline: true),
            "Submission failed: Synthetic rejection."
        )
        TestSupport.expectEqual(DictationPipeline.userFacingMessage(for: CancellationError(), isOnline: true), "Cancelled")
        TestSupport.expectEqual(DictationPipeline.userFacingMessage(for: URLError(.cancelled), isOnline: true), "Cancelled")
        TestSupport.expect(DictationPipeline.isCancellation(CancellationError()), "CancellationError is a cancellation")
        TestSupport.expect(DictationPipeline.isCancellation(URLError(.cancelled)), "A cancelled URL request is a cancellation")
        TestSupport.expect(!DictationPipeline.isCancellation(URLError(.timedOut)), "A timeout is a failure, not a cancellation")
    }

    // MARK: - Pipeline routing

    private static func testEmptyTranscriptSkipsProviders() async {
        for transcript in ["", "  \n "] {
            let provider = FakeChatProvider { _, _ in .content("unused") }
            let result = await runPipeline(transcript: transcript, configuration: makeConfiguration(), provider: provider)
            TestSupport.expectEqual(
                result,
                DictationResult(rawTranscript: "", text: "", pressEnter: false, route: .empty, usedRawFallback: false)
            )
            TestSupport.expectEqual(provider.requests.count, 0)
        }
    }

    private static func testPressEnterOnlyTranscript() async {
        let provider = FakeChatProvider { _, _ in .content("unused") }
        let result = await runPipeline(transcript: "Press enter.", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "", text: "", pressEnter: true, route: .empty, usedRawFallback: false)
        )
        TestSupport.expectEqual(provider.requests.count, 0)

        let disabledProvider = FakeChatProvider { _, _ in .content("Press enter.") }
        let disabled = await runPipeline(
            transcript: "Press enter.",
            configuration: makeConfiguration(pressEnterCommand: false),
            provider: disabledProvider
        )
        TestSupport.expectEqual(
            disabled,
            DictationResult(rawTranscript: "Press enter.", text: "Press enter.", pressEnter: false, route: .cleanup, usedRawFallback: false)
        )
        TestSupport.expectEqual(disabledProvider.requests.count, 1)
    }

    private static func testMacroRoute() async {
        let macros = [
            VoiceMacro(command: "sign off", payload: "  Thanks,\nSam  "),
            VoiceMacro(command: "blank", payload: "   "),
        ]
        let provider = FakeChatProvider { _, _ in .content("unused") }

        let plain = await runPipeline(transcript: "Sign off.", configuration: makeConfiguration(macros: macros), provider: provider)
        TestSupport.expectEqual(
            plain,
            DictationResult(rawTranscript: "Sign off.", text: "Thanks,\nSam", pressEnter: false, route: .macro, usedRawFallback: false)
        )

        // Macros run before preserve exact wording and translation, as on macOS.
        let preserved = await runPipeline(
            transcript: "sign off",
            configuration: makeConfiguration(preserveExactWording: true, outputLanguage: "French", macros: macros),
            provider: provider
        )
        TestSupport.expectEqual(preserved?.route, .macro)
        TestSupport.expectEqual(preserved?.text, "Thanks,\nSam")

        let withEnter = await runPipeline(
            transcript: "Sign off, press enter.",
            configuration: makeConfiguration(macros: macros),
            provider: provider
        )
        TestSupport.expectEqual(
            withEnter,
            DictationResult(rawTranscript: "Sign off", text: "Thanks,\nSam", pressEnter: true, route: .macro, usedRawFallback: false)
        )

        let blank = await runPipeline(transcript: "Blank", configuration: makeConfiguration(macros: macros), provider: provider)
        TestSupport.expectEqual(
            blank,
            DictationResult(rawTranscript: "Blank", text: "", pressEnter: false, route: .empty, usedRawFallback: false)
        )
        TestSupport.expectEqual(provider.requests.count, 0)
    }

    private static func testVerbatimRoute() async {
        let provider = FakeChatProvider { _, _ in .content("unused") }
        let result = await runPipeline(
            transcript: "  um so like the build is green  ",
            configuration: makeConfiguration(preserveExactWording: true),
            provider: provider
        )
        TestSupport.expectEqual(
            result,
            DictationResult(
                rawTranscript: "um so like the build is green",
                text: "um so like the build is green",
                pressEnter: false,
                route: .verbatim,
                usedRawFallback: false
            )
        )
        TestSupport.expectEqual(provider.requests.count, 0)
    }

    private static func testTranslationRoute() async {
        let provider = FakeChatProvider { _, _ in .content("\"euh la réunion est passée à midi\"") }
        let result = await runPipeline(
            transcript: "um the meeting moved to noon",
            configuration: makeConfiguration(preserveExactWording: true, outputLanguage: "French"),
            provider: provider
        )
        TestSupport.expectEqual(
            result,
            DictationResult(
                rawTranscript: "um the meeting moved to noon",
                text: "euh la réunion est passée à midi",
                pressEnter: false,
                route: .translation,
                usedRawFallback: false
            )
        )
        let requests = provider.requests
        TestSupport.expectEqual(requests.map(\.model), [primaryModel])
        TestSupport.expectEqual(requests.first?.systemPrompt, PostProcessingService.verbatimTranslationSystemPrompt(targetLanguage: "French"))
        TestSupport.expect(
            requests.first?.userPrompt.contains("<<<TRANSCRIPT\num the meeting moved to noon\nTRANSCRIPT") == true,
            "The translation request must carry the raw transcript"
        )
        TestSupport.expectEqual(requests.first?.url, "https://llm.example.invalid/v1/chat/completions")
        TestSupport.expectEqual(requests.first?.authorization, "Bearer ios-synthetic-key")
    }

    private static func testTranslationFailureFallsBackToRaw() async {
        let provider = FakeChatProvider { _, _ in .status(500) }
        let result = await runPipeline(
            transcript: "the meeting moved to noon",
            configuration: makeConfiguration(preserveExactWording: true, outputLanguage: "French"),
            provider: provider
        )
        TestSupport.expectEqual(
            result,
            DictationResult(
                rawTranscript: "the meeting moved to noon",
                text: "the meeting moved to noon",
                pressEnter: false,
                route: .translation,
                usedRawFallback: true
            )
        )
        // Only 429 and empty output retry the fallback model.
        TestSupport.expectEqual(provider.requests.map(\.model), [primaryModel])
    }

    private static func testTranslationRetriesFallbackModelOnRateLimit() async {
        let primary = "ios-pipeline-translation-429-primary"
        let fallback = "ios-pipeline-translation-429-fallback"
        let provider = FakeChatProvider { model, _ in model == primary ? .status(429) : .content("la réunion est à midi") }
        let result = await runPipeline(
            transcript: "the meeting is at noon",
            configuration: makeConfiguration(primaryModel: primary, fallbackModel: fallback, preserveExactWording: true, outputLanguage: "French"),
            provider: provider
        )
        TestSupport.expectEqual(result?.text, "la réunion est à midi")
        TestSupport.expectEqual(result?.route, .translation)
        TestSupport.expectEqual(result?.usedRawFallback, false)
        TestSupport.expectEqual(provider.requests.map(\.model), [primary, fallback])
    }

    private static func testCleanupRequest() async {
        let provider = FakeChatProvider { _, _ in .content("So the Zed build is ready.") }
        let result = await runPipeline(
            transcript: "um so the zed build is ready",
            configuration: makeConfiguration(customVocabulary: "Zed, FreeFlow; zed\nGroq"),
            provider: provider
        )
        TestSupport.expectEqual(
            result,
            DictationResult(
                rawTranscript: "um so the zed build is ready",
                text: "So the Zed build is ready.",
                pressEnter: false,
                route: .cleanup,
                usedRawFallback: false
            )
        )

        let requests = provider.requests
        TestSupport.expectEqual(requests.count, 1)
        TestSupport.expectEqual(requests.first?.url, "https://llm.example.invalid/v1/chat/completions")
        TestSupport.expectEqual(requests.first?.authorization, "Bearer ios-synthetic-key")
        TestSupport.expectEqual(requests.first?.model, primaryModel)
        let vocabularyBlock = """
        The following vocabulary must be treated as high-priority terms while rewriting.
        Use these spellings exactly in the output when relevant:
        Zed, FreeFlow, Groq
        """
        TestSupport.expectEqual(requests.first?.systemPrompt, PostProcessingService.defaultSystemPrompt + "\n\n" + vocabularyBlock)
        let userPrompt = requests.first?.userPrompt ?? ""
        TestSupport.expect(
            userPrompt.contains("<<<RAW_TRANSCRIPTION\num so the zed build is ready\nRAW_TRANSCRIPTION"),
            "The cleanup request must carry the raw transcript"
        )
        TestSupport.expect(!userPrompt.contains("CONTEXT:"), "iOS cleanup must send no context")
    }

    private static func testCleanupPromptOptions() async {
        let customProvider = FakeChatProvider { _, _ in .content("Hola equipo, el informe está listo.") }
        let custom = await runPipeline(
            transcript: "hola equipo el informe esta listo",
            configuration: makeConfiguration(transcriptionLanguageCode: "es", customSystemPrompt: "Synthetic custom cleanup prompt."),
            provider: customProvider
        )
        TestSupport.expectEqual(custom?.text, "Hola equipo, el informe está listo.")
        TestSupport.expectEqual(
            customProvider.requests.first?.systemPrompt,
            PostProcessingService.applyDictationLanguage("Synthetic custom cleanup prompt.", language: "Spanish")
        )

        let outputProvider = FakeChatProvider { _, _ in .content("Le rapport est prêt.") }
        let output = await runPipeline(
            transcript: "the report is ready",
            configuration: makeConfiguration(outputLanguage: "French", transcriptionLanguageCode: "es"),
            provider: outputProvider
        )
        TestSupport.expectEqual(output?.text, "Le rapport est prêt.")
        TestSupport.expectEqual(output?.route, .cleanup)
        TestSupport.expectEqual(
            outputProvider.requests.first?.systemPrompt,
            PostProcessingService.applyOutputLanguage(PostProcessingService.defaultSystemPrompt, language: "French")
        )
    }

    private static func testCleanupRetriesFallbackModelOnEmptyOutput() async {
        let primary = primaryModel
        let provider = FakeChatProvider { model, _ in model == primary ? .content("  ") : .content("The quarterly numbers look good.") }
        let result = await runPipeline(transcript: "the quarterly numbers look good", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(
                rawTranscript: "the quarterly numbers look good",
                text: "The quarterly numbers look good.",
                pressEnter: false,
                route: .cleanup,
                usedRawFallback: false
            )
        )
        let requests = provider.requests
        TestSupport.expectEqual(requests.map(\.model), [primaryModel, fallbackModel])
        TestSupport.expectEqual(requests.first?.systemPrompt, requests.last?.systemPrompt)
    }

    private static func testCleanupRetriesFallbackModelOnRateLimit() async {
        // Unique names: a 429 cools the model down in the shared LLMCooldownManager.
        let primary = "ios-pipeline-cleanup-429-primary"
        let fallback = "ios-pipeline-cleanup-429-fallback"
        let provider = FakeChatProvider { model, _ in model == primary ? .status(429) : .content("The build is ready.") }
        let result = await runPipeline(
            transcript: "the build is ready",
            configuration: makeConfiguration(primaryModel: primary, fallbackModel: fallback),
            provider: provider
        )
        TestSupport.expectEqual(result?.text, "The build is ready.")
        TestSupport.expectEqual(result?.usedRawFallback, false)
        TestSupport.expectEqual(provider.requests.map(\.model), [primary, fallback])
    }

    private static func testCleanupServerErrorFallsBackToRawWithoutRetry() async {
        let provider = FakeChatProvider { _, _ in .status(500) }
        let result = await runPipeline(transcript: "the build is ready", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .cleanup, usedRawFallback: true)
        )
        TestSupport.expectEqual(provider.requests.map(\.model), [primaryModel])
    }

    private static func testCleanupFallsBackToRawWhenBothModelsReturnNothing() async {
        let provider = FakeChatProvider { _, _ in .content("") }
        let result = await runPipeline(transcript: "the build is ready", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .cleanup, usedRawFallback: true)
        )
        TestSupport.expectEqual(provider.requests.map(\.model), [primaryModel, fallbackModel])
    }

    private static func testCleanupTransportErrorFallsBackToRaw() async {
        let provider = FakeChatProvider { _, _ in .failure(.notConnectedToInternet) }
        let result = await runPipeline(transcript: "the build is ready", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .cleanup, usedRawFallback: true)
        )
        TestSupport.expectEqual(provider.requests.count, 1)
    }

    private static func testCleanupEmptySentinelMeansNothingToInsert() async {
        let provider = FakeChatProvider { _, _ in .content("EMPTY") }
        let result = await runPipeline(transcript: "uh hmm", configuration: makeConfiguration(), provider: provider)
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "uh hmm", text: "", pressEnter: false, route: .empty, usedRawFallback: false)
        )
        TestSupport.expectEqual(provider.requests.count, 1)
    }

    private static func testInstructionGuard() async {
        let transcript = "write an email to the team about the launch"
        let primary = primaryModel
        let answering = FakeChatProvider { model, _ in
            model == primary ? .content("Sure! Here is a draft for the team.") : .content("Here is the email for the team.")
        }
        // Both models answer the instruction, so cleanup keeps the raw
        // transcript. PostProcessingService reports that as a success, and
        // macOS shows no failure for it either.
        let guarded = await runPipeline(transcript: transcript, configuration: makeConfiguration(), provider: answering)
        TestSupport.expectEqual(
            guarded,
            DictationResult(rawTranscript: transcript, text: transcript, pressEnter: false, route: .cleanup, usedRawFallback: false)
        )
        TestSupport.expectEqual(answering.requests.map(\.model), [primaryModel, fallbackModel])

        let unguardedProvider = FakeChatProvider { _, _ in .content("Sure! Here is a draft for the team.") }
        let unguarded = await runPipeline(
            transcript: transcript,
            configuration: makeConfiguration(instructionGuard: false),
            provider: unguardedProvider
        )
        TestSupport.expectEqual(unguarded?.text, "Sure! Here is a draft for the team.")
        TestSupport.expectEqual(unguardedProvider.requests.map(\.model), [primaryModel])
    }

    private static func testBothModelsCoolingDownSkipsCleanup() async {
        let primary = "ios-pipeline-cooling-primary"
        let fallback = "ios-pipeline-cooling-fallback"
        await LLMCooldownManager.shared.setCooldown(primary, retryAfterSeconds: 120)
        await LLMCooldownManager.shared.setCooldown(fallback, retryAfterSeconds: 120)
        let provider = FakeChatProvider { _, _ in .content("unused") }
        let result = await runPipeline(
            transcript: "the build is ready",
            configuration: makeConfiguration(primaryModel: primary, fallbackModel: fallback),
            provider: provider
        )
        // macOS parity: PostProcessingService returns the raw text as a success.
        TestSupport.expectEqual(
            result,
            DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .cleanup, usedRawFallback: false)
        )
        TestSupport.expectEqual(provider.requests.count, 0)
    }

    private static func testUnusableBaseURLFallsBackWithoutRequests() async {
        for baseURL in ["", "not a url", "ftp://llm.example.invalid/v1", "https://", "llm.example.invalid/v1"] {
            let provider = FakeChatProvider { _, _ in .content("unused") }
            let cleanup = await runPipeline(
                transcript: "the build is ready",
                configuration: makeConfiguration(baseURL: baseURL),
                provider: provider
            )
            TestSupport.expect(
                cleanup == DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .cleanup, usedRawFallback: true),
                "Base URL '\(baseURL)' must fall back to the raw transcript"
            )
            let translation = await runPipeline(
                transcript: "the build is ready",
                configuration: makeConfiguration(baseURL: baseURL, preserveExactWording: true, outputLanguage: "French"),
                provider: provider
            )
            TestSupport.expect(
                translation == DictationResult(rawTranscript: "the build is ready", text: "the build is ready", pressEnter: false, route: .translation, usedRawFallback: true),
                "Base URL '\(baseURL)' must fall back to the untranslated transcript"
            )
            TestSupport.expect(provider.requests.isEmpty, "Base URL '\(baseURL)' must not send a request")
        }
    }

    private static func testBaseURLTrailingSlashesAreDropped() async {
        let provider = FakeChatProvider { _, _ in .content("The build is ready.") }
        let result = await runPipeline(
            transcript: "the build is ready",
            configuration: makeConfiguration(baseURL: "HTTPS://llm.example.invalid/v1//"),
            provider: provider
        )
        TestSupport.expectEqual(result?.text, "The build is ready.")
        TestSupport.expectEqual(provider.requests.first?.url, "https://llm.example.invalid/v1/chat/completions")
    }

    private static func testTranscriberGetsAudioAndConfiguration() async {
        let seen = Recorder<TranscribeCall>()
        let configuration = makeConfiguration()
        let provider = FakeChatProvider(reply: { _, _ in .content("The build is ready.") })
        let pipeline = DictationPipeline(
            transcribe: { audioFileURL, passedConfiguration in
                seen.record(TranscribeCall(audioFileURL: audioFileURL, configuration: passedConfiguration))
                return "the build is ready"
            },
            transport: provider.transport
        )
        do {
            let result = try await pipeline.run(audioFileURL: syntheticAudioURL, configuration: configuration)
            TestSupport.expectEqual(result.text, "The build is ready.")
        } catch {
            TestSupport.expect(false, "Unexpected pipeline error: \(error)")
        }
        TestSupport.expectEqual(seen.values, [TranscribeCall(audioFileURL: syntheticAudioURL, configuration: configuration)])
    }

    private static func testTranscriptionErrorsPropagate() async {
        let provider = FakeChatProvider { _, _ in .content("unused") }
        let pipeline = DictationPipeline(
            transcribe: { _, _ in throw TranscriptionError.submissionFailed("Synthetic provider rejected the upload.") },
            transport: provider.transport
        )
        do {
            _ = try await pipeline.run(audioFileURL: syntheticAudioURL, configuration: makeConfiguration())
            TestSupport.expect(false, "A transcription error must propagate")
        } catch TranscriptionError.submissionFailed(let message) {
            TestSupport.expectEqual(message, "Synthetic provider rejected the upload.")
        } catch {
            TestSupport.expect(false, "Unexpected error: \(error)")
        }
        TestSupport.expectEqual(provider.requests.count, 0)
    }

    private static func testDefaultTranscriberRejectsInvalidURLWithoutNetwork() async {
        var configuration = makeConfiguration()
        configuration.transcriptionBaseURL = "ftp://stt.example.invalid/v1"
        let provider = FakeChatProvider { _, _ in .content("unused") }
        let pipeline = DictationPipeline(transport: provider.transport)
        do {
            _ = try await pipeline.run(audioFileURL: syntheticAudioURL, configuration: configuration)
            TestSupport.expect(false, "An invalid transcription URL must throw")
        } catch TranscriptionError.invalidBaseURL(let message) {
            TestSupport.expectEqual(message, "Provider URL must use http or https.")
            TestSupport.expectEqual(
                DictationPipeline.userFacingMessage(for: TranscriptionError.invalidBaseURL(message), isOnline: true),
                "Invalid provider URL: Provider URL must use http or https."
            )
        } catch {
            TestSupport.expect(false, "Unexpected error: \(error)")
        }
        TestSupport.expectEqual(provider.requests.count, 0)
    }

    private static func testCancellationDuringCleanupThrows() async {
        let entered = Flag()
        let pipeline = DictationPipeline(
            transcribe: { _, _ in "the build is ready" },
            transport: { _ in
                entered.set()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }
        )
        let configuration = makeConfiguration()
        let task = Task {
            try await pipeline.run(audioFileURL: syntheticAudioURL, configuration: configuration)
        }
        var waitedMilliseconds = 0
        while !entered.isSet && waitedMilliseconds < 5_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            waitedMilliseconds += 1
        }
        TestSupport.expect(entered.isSet, "Cleanup must start before the cancel")
        task.cancel()
        do {
            _ = try await task.value
            TestSupport.expect(false, "A cancelled run must not return a result")
        } catch {
            TestSupport.expect(DictationPipeline.isCancellation(error), "A cancelled run must throw a cancellation, got \(error)")
        }
    }

    // MARK: - Fakes

    private static let primaryModel = "ios-pipeline-primary"
    private static let fallbackModel = "ios-pipeline-fallback"
    private static let syntheticAudioURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ios-pipeline-synthetic.wav")

    private static func makeConfiguration(
        baseURL: String = "https://llm.example.invalid/v1",
        primaryModel: String = IOSSharedCoreTests.primaryModel,
        fallbackModel: String = IOSSharedCoreTests.fallbackModel,
        preserveExactWording: Bool = false,
        outputLanguage: String = "",
        transcriptionLanguageCode: String = "",
        customSystemPrompt: String = "",
        customVocabulary: String = "",
        instructionGuard: Bool = true,
        pressEnterCommand: Bool = true,
        macros: [VoiceMacro] = []
    ) -> DictationConfiguration {
        DictationConfiguration(
            apiKey: "ios-synthetic-key",
            baseURL: baseURL,
            transcriptionAPIKey: "ios-synthetic-stt-key",
            transcriptionBaseURL: "https://stt.example.invalid/v1",
            transcriptionModel: "whisper-large-v3",
            transcriptionLanguageCode: transcriptionLanguageCode,
            postProcessingModel: primaryModel,
            postProcessingFallbackModel: fallbackModel,
            customSystemPrompt: customSystemPrompt,
            customVocabulary: customVocabulary,
            outputLanguage: outputLanguage,
            preserveExactWording: preserveExactWording,
            instructionExecutionGuardEnabled: instructionGuard,
            pressEnterVoiceCommandEnabled: pressEnterCommand,
            voiceMacros: macros
        )
    }

    /// Runs the pipeline with a canned transcript; nil (after a failed
    /// expectation) if it threw.
    private static func runPipeline(
        transcript: String,
        configuration: DictationConfiguration,
        provider: FakeChatProvider
    ) async -> DictationResult? {
        let pipeline = DictationPipeline(
            transcribe: { _, _ in transcript },
            transport: provider.transport
        )
        do {
            return try await pipeline.run(audioFileURL: syntheticAudioURL, configuration: configuration)
        } catch {
            TestSupport.expect(false, "Unexpected pipeline error: \(error)")
            return nil
        }
    }

    private struct TranscribeCall: Equatable {
        let audioFileURL: URL
        let configuration: DictationConfiguration
    }

    /// A canned OpenAI-compatible chat-completions provider that records
    /// every request it receives.
    private final class FakeChatProvider: @unchecked Sendable {
        enum Reply {
            case content(String)
            case status(Int)
            case failure(URLError.Code)
        }

        struct Request {
            let url: String
            let authorization: String
            let model: String
            let systemPrompt: String
            let userPrompt: String
        }

        private let lock = NSLock()
        private var recorded: [Request] = []
        private let reply: @Sendable (_ model: String, _ attempt: Int) -> Reply

        init(reply: @escaping @Sendable (_ model: String, _ attempt: Int) -> Reply) {
            self.reply = reply
        }

        var requests: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var transport: DictationPipeline.Transport {
            { [self] request in try self.respond(to: request) }
        }

        private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let messages = body["messages"] as? [[String: Any]] ?? []
            let model = body["model"] as? String ?? ""
            let captured = Request(
                url: request.url?.absoluteString ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
                model: model,
                systemPrompt: Self.content(of: "system", in: messages),
                userPrompt: Self.content(of: "user", in: messages)
            )
            lock.lock()
            let attempt = recorded.count
            recorded.append(captured)
            lock.unlock()

            let url = request.url ?? URL(fileURLWithPath: "/")
            switch reply(model, attempt) {
            case .content(let content):
                let data = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": content]]]
                ])
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .status(let statusCode):
                let data = Data(#"{"error":{"message":"synthetic failure"}}"#.utf8)
                return (data, HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
            case .failure(let code):
                throw URLError(code)
            }
        }

        private static func content(of role: String, in messages: [[String: Any]]) -> String {
            let message = messages.first { $0["role"] as? String == role }
            return message?["content"] as? String ?? ""
        }
    }

    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []

        func record(_ value: Value) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
