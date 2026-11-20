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
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguageName(forCode: "xx"), "")
        TestSupport.expectEqual(LanguageOptions.transcriptionLanguages.count, 30)
        TestSupport.expectEqual(LanguageOptions.outputLanguages.first, "")
    }
}
