import XCTest

/// End-to-end dictation in the FreeFlow keyboard, through CI's mock provider
/// (.github/scripts/mock-openai-server.py, DESIGN §5.3).
///
/// Each test resets the app and the mock's request log, focuses the app's
/// test field, switches to FreeFlow with the globe key and dictates. The
/// first test records through WebKit's simulator microphone (the real
/// in-keyboard path); the rest feed the capture page's synthetic tone, so
/// they check the pipeline's routes and the keyboard's states without
/// depending on WebKit's audio.
final class FreeFlowKeyboardTests: FreeFlowKeyboardTestCase {
    private static var synthetic: FreeFlowLaunchOptions {
        var options = FreeFlowLaunchOptions.dictationReady
        options.syntheticCapture = true
        return options
    }

    /// The whole path a user takes: mic, speak, Done, cleaned text inserted.
    @MainActor
    func testDictationThroughWebKitCaptureInsertsCleanedText() throws {
        try runCleanedDictation(.dictationReady, capturePath: "WebKit getUserMedia (simulator mock microphone)")
    }

    @MainActor
    func testDictationThroughSyntheticCaptureInsertsCleanedText() throws {
        try runCleanedDictation(Self.synthetic, capturePath: "the page's synthetic tone")
    }

    @MainActor
    func testPreserveExactWordingInsertsRawTranscript() throws {
        var options = Self.synthetic
        options.preserveExactWording = true
        let (session, trace) = try openIdleKeyboard(options)

        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .inserted, "seen: \(trace)")
        try requireField(session, contains: MockProvider.transcript, trace: trace)
        XCTAssertFalse(session.field.textValue.contains(MockProvider.cleanedText), "Cleanup ran anyway")

        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.count, 1)
        XCTAssertEqual(requests.chats.count, 0, "Preserve exact wording must skip the cleanup request")
        report("Inserted the raw transcript with no cleanup request (seen: \(trace))")
    }

    @MainActor
    func testCleanupFailureInsertsRawTranscriptWithoutCleanup() throws {
        var options = Self.synthetic
        options.apiKey = MockProvider.apiKey(for: .chatError)
        let (session, trace) = try openIdleKeyboard(options)

        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .inserted, "seen: \(trace)")
        try requireField(session, contains: MockProvider.transcript, trace: trace)
        XCTAssertEqual(trace.texts[KeyboardDisplayState.inserted.rawValue], "Inserted without cleanup")

        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.first?["status"] as? Int, 200)
        XCTAssertFalse(requests.chats.isEmpty, "No cleanup request was made")
        XCTAssertTrue(requests.chats.allSatisfy { $0["status"] as? Int == 500 })
        report("Cleanup failed with HTTP 500 \(requests.chats.count) time(s); the raw transcript went in "
            + "with \"\(trace.texts[KeyboardDisplayState.inserted.rawValue] ?? "?")\"")
    }

    @MainActor
    func testTranscriptionFailureShowsErrorAndLeavesFieldUnchanged() throws {
        var options = Self.synthetic
        options.apiKey = MockProvider.apiKey(for: .transcriptionError)
        let (session, trace) = try openIdleKeyboard(options)
        let before = session.field.textValue

        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .error, "seen: \(trace)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(session.field.textValue, before, "The field changed after a failed transcription")

        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.first?["status"] as? Int, 500)
        XCTAssertEqual(requests.chats.count, 0)
        report("Transcription failed with HTTP 500; the keyboard said \"\(trace.texts["error"] ?? "?")\"")
    }

    @MainActor
    func testEmptyTranscriptShowsNothingToInsert() throws {
        var options = Self.synthetic
        options.apiKey = MockProvider.apiKey(for: .emptyTranscript)
        let (session, trace) = try openIdleKeyboard(options)
        let before = session.field.textValue

        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .nothingToInsert, "seen: \(trace)")
        XCTAssertEqual(trace.texts[KeyboardDisplayState.nothingToInsert.rawValue], "Nothing to transcribe")
        XCTAssertEqual(session.field.textValue, before)
        XCTAssertEqual(try providerRequests().chats.count, 0)
    }

    @MainActor
    func testCancelDuringRecordingInsertsNothingAndCallsNoProvider() throws {
        let (session, trace) = try openIdleKeyboard(Self.synthetic)
        let before = session.field.textValue

        try startTapDictation(in: session, trace: trace)
        Thread.sleep(forTimeInterval: 1)
        try tapKeyboardButton(FreeFlowAccessibilityID.Keyboard.cancel, in: session)
        let state = session.keyboard.waitForStatus([.idle], timeout: 10, trace: trace)
        capture("cancelled")
        XCTAssertEqual(state, .idle, "seen: \(trace)")
        XCTAssertFalse(trace.saw(.processing), "Cancel during recording still processed: \(trace)")

        // Give a stray upload time to arrive before checking there was none.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(session.field.textValue, before)
        XCTAssertEqual(try providerRequests().all.count, 0, "Cancel still called the provider")
        report("Cancel stopped the recording with no provider call (seen: \(trace))")
    }

    @MainActor
    func testInsertLastReinsertsPreviousResult() throws {
        let (session, trace) = try openIdleKeyboard(Self.synthetic)
        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .inserted, "seen: \(trace)")
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)

        // Insert last is enabled again once the inserted message clears.
        _ = session.keyboard.waitForStatus([.idle], timeout: 10, trace: trace)
        try tapKeyboardButton(FreeFlowAccessibilityID.Keyboard.insertLast, in: session)
        let again = session.keyboard.waitForStatus([.inserted], timeout: 10, trace: trace)
        capture("inserted-last")
        XCTAssertEqual(again, .inserted, "seen: \(trace)")
        XCTAssertEqual(trace.texts[KeyboardDisplayState.inserted.rawValue], "Inserted your last dictation")
        let copies = waitUntil(timeout: 5) {
            session.field.textValue.components(separatedBy: MockProvider.cleanedText).count - 1 == 2
        }
        XCTAssertTrue(copies, "Expected the text twice, field holds \"\(session.field.textValue)\"")
        XCTAssertEqual(try providerRequests().transcriptions.count, 1, "Insert last must not call the provider")
    }

    /// Hold to talk: press and hold the mic, release to stop.
    @MainActor
    func testHoldToTalkRecordsWhileHeld() throws {
        let (session, trace) = try openIdleKeyboard(Self.synthetic)
        guard let mic = session.keyboard.keyboardElement(FreeFlowAccessibilityID.Keyboard.mic) else {
            throw RequirementFailure(message: "The keyboard has no mic button")
        }
        let held: TimeInterval = 3
        mic.press(forDuration: held)
        let result = waitForDictationResult(in: session, trace: trace)
        capture("result-\(result?.rawValue ?? "none")")
        XCTAssertEqual(result, .inserted, "seen: \(trace)")
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)

        // The recording ends at release, so it can't be longer than the hold.
        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.count, 1)
        if let upload = requests.transcriptions.first {
            assertValidUpload(upload, minimumSeconds: 1, maximumSeconds: held + 0.5)
            report("Held the mic \(held) s; uploaded \(describeUpload(upload)) (seen: \(trace))")
        }
    }

    // MARK: Steps

    /// Clears the mock's log, opens the keyboard and waits for `idle`.
    @MainActor
    private func openIdleKeyboard(_ options: FreeFlowLaunchOptions) throws -> (KeyboardSession, KeyboardStateTrace) {
        try resetProviderRequests()
        let session = try openFreeFlowKeyboard(options)
        let trace = KeyboardStateTrace()
        try requireIdle(session, trace: trace)
        capture("keyboard-ready")
        return (session, trace)
    }

    /// Dictates with cleanup on and checks the keyboard, the field and the
    /// requests the mock received.
    @MainActor
    private func runCleanedDictation(_ options: FreeFlowLaunchOptions, capturePath: String) throws {
        let (session, trace) = try openIdleKeyboard(options)

        let result = try dictateByTapping(in: session, recordFor: 2, trace: trace)
        try require(
            result == .inserted,
            "Dictation through \(capturePath) ended in \(describe(session.keyboard.status)) (seen: \(trace))",
            evidence: session.keyboard.hosts
        )
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)
        XCTAssertTrue(trace.saw(.recording, before: .processing), "seen: \(trace)")
        XCTAssertTrue(trace.saw(.processing, before: .inserted), "seen: \(trace)")

        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.count, 1, "transcription requests")
        XCTAssertEqual(requests.chats.count, 1, "cleanup requests")
        assertFromKeyboard(requests.all)
        if let upload = requests.transcriptions.first {
            XCTAssertEqual(upload["status"] as? Int, 200)
            assertValidUpload(upload, minimumSeconds: 1)
            report("Capture through \(capturePath) worked; uploaded \(describeUpload(upload))")
        }
        if let chat = requests.chats.first {
            XCTAssertEqual(chat["status"] as? Int, 200)
            XCTAssertEqual((chat["chat"] as? [String: Any])?["kind"] as? String, "cleanup")
        }
        report("States seen: \(trace); the field holds \"\(session.field.textValue)\"")
    }
}
