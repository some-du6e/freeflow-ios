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
        XCTAssertTrue(ended(result, in: .inserted, trace: trace), "seen: \(trace)")
        try requireField(session, contains: MockProvider.transcript, trace: trace)
        try requireHistoryStatus("Inserted", in: session, trace: trace)
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
        XCTAssertTrue(ended(result, in: .inserted, trace: trace), "seen: \(trace)")
        try requireField(session, contains: MockProvider.transcript, trace: trace)
        try requireHistoryStatus("Inserted without cleanup", in: session, trace: trace)
        if let message = trace.texts[KeyboardDisplayState.inserted.rawValue] {
            XCTAssertEqual(message, "Inserted without cleanup")
        }

        let requests = try providerRequests()
        XCTAssertEqual(requests.transcriptions.first?["status"] as? Int, 200)
        XCTAssertFalse(requests.chats.isEmpty, "No cleanup request was made")
        XCTAssertTrue(requests.chats.allSatisfy { $0["status"] as? Int == 500 })
        report("Cleanup failed with HTTP 500 \(requests.chats.count) time(s); the raw transcript went in, "
            + "and History says \"Inserted without cleanup\" (seen: \(trace))")
    }

    @MainActor
    func testTranscriptionFailureShowsErrorAndLeavesFieldUnchanged() throws {
        var options = Self.synthetic
        options.apiKey = MockProvider.apiKey(for: .transcriptionError)
        let (session, trace) = try openIdleKeyboard(options)
        let before = session.field.textValue

        let result = try dictateByTapping(in: session, trace: trace)
        XCTAssertEqual(result, .error, "seen: \(trace)")
        try requireHistoryStatus("Failed", in: session, trace: trace)
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
        XCTAssertTrue(ended(result, in: .nothingToInsert, trace: trace), "seen: \(trace)")
        try requireHistoryStatus("Nothing to insert", in: session, trace: trace)
        if let message = trace.texts[KeyboardDisplayState.nothingToInsert.rawValue] {
            XCTAssertEqual(message, "Nothing to transcribe")
        }
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
        XCTAssertTrue(ended(result, in: .inserted, trace: trace), "seen: \(trace)")
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)

        // Insert last is enabled again once the inserted message clears.
        _ = session.keyboard.waitForStatus([.idle], timeout: 10, trace: trace)
        let afterDictation = KeyboardStateTrace()
        try tapKeyboardButton(FreeFlowAccessibilityID.Keyboard.insertLast, in: session)
        // The field is the proof. The 1.5 s "inserted" message often ends
        // before the tap returns, so it is reported when seen, not required.
        let copies = waitUntil(timeout: 10) {
            if let status = session.keyboard.status {
                afterDictation.note(state: status.state, text: status.text)
            }
            return session.field.textValue.components(separatedBy: MockProvider.cleanedText).count - 1 == 2
        }
        capture("inserted-last")
        XCTAssertTrue(copies, "Expected the text twice, field holds \"\(session.field.textValue)\"")
        if let message = afterDictation.texts[KeyboardDisplayState.inserted.rawValue] {
            XCTAssertEqual(message, "Inserted your last dictation")
        }
        XCTAssertEqual(try providerRequests().transcriptions.count, 1, "Insert last must not call the provider")
        report("Insert last added the text again with no provider call (states after the tap: \(afterDictation))")
    }

    /// The keyboard records a KeyboardStatus in the App Group only when its
    /// own `hasFullAccess` is true, and Home's setup checklist shows it. So
    /// "Full Access: On" on Home is Full Access as the extension sees it.
    @MainActor
    func testKeyboardReportsFullAccessToTheApp() throws {
        let (session, _) = try openIdleKeyboard(.dictationReady)
        let keyboardItem = element("freeflow.app.setup.keyboard", in: session.app)
        let fullAccessItem = element("freeflow.app.setup.fullAccess", in: session.app)
        // Home reloads the checklist every 1.5 s.
        let reported = waitUntil(timeout: 15) {
            keyboardItem.staticTexts["Added"].exists && fullAccessItem.staticTexts["On"].exists
        }
        capture("home-checklist")
        let details = [keyboardItem, fullAccessItem].map { item in
            item.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: ": ")
        }
        try require(
            reported,
            "Home doesn't show the keyboard's Full Access report: \(details.joined(separator: "; "))",
            evidence: [session.app]
        )
        report("The keyboard reported Full Access to the app; Home shows \(details.joined(separator: "; "))")
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
        XCTAssertTrue(ended(result, in: .inserted, trace: trace), "seen: \(trace)")
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)
        try requireHistoryStatus("Inserted", in: session, trace: trace)

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
            ended(result, in: .inserted, trace: trace),
            "Dictation through \(capturePath) ended in \(describe(session.keyboard.status)) (seen: \(trace))",
            evidence: session.keyboard.hosts
        )
        try requireField(session, contains: MockProvider.cleanedText, trace: trace)
        try requireHistoryStatus("Inserted", in: session, trace: trace)
        XCTAssertTrue(trace.saw(.recording, before: .processing), "seen: \(trace)")
        if trace.saw(.inserted) {
            XCTAssertTrue(trace.saw(.processing, before: .inserted), "seen: \(trace)")
        }

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
        let message = trace.saw(.inserted) ? "seen" : "missed between queries; History shows Inserted"
        report("States seen: \(trace) (the inserted message was \(message)); "
            + "the field holds \"\(session.field.textValue)\"")
    }
}
