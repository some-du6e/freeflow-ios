import XCTest
@testable import FreeFlow

final class AppRecorderModelTests: XCTestCase {
    // MARK: Keyboard handoff

    @MainActor
    func testHandoffSavesPendingDictationAndWritesHandedOffHistory() async throws {
        let spy = AppRecorderSpy()
        let session = UUID()
        spy.awaitedSessionID = session
        spy.results = [.success(appSyntheticResult(text: "Hello from the synthetic test.", pressEnter: true))]
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(model.phase.accessibilityName, "starting")
        XCTAssertEqual(spy.microphoneMarkedGranted, 1)

        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        let isRecording = await appWaitUntil { model.phase == .recording }
        XCTAssertTrue(isRecording)

        recorder.onLevel?(0.6)
        let showsLevel = await appWaitUntil { model.level == 0.6 }
        XCTAssertTrue(showsLevel)

        model.stop()
        XCTAssertEqual(recorder.stopCount, 1)
        let finished = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")

        XCTAssertEqual(spy.pending.count, 1)
        let pending = try XCTUnwrap(spy.pending.first)
        XCTAssertEqual(pending.sessionID, session)
        XCTAssertEqual(pending.text, "Hello from the synthetic test.")
        XCTAssertTrue(pending.pressEnter)
        XCTAssertEqual(pending.createdAt, spy.now)
        XCTAssertTrue(pending.isFresh(now: spy.now))

        let entry = try XCTUnwrap(spy.history.first)
        XCTAssertEqual(spy.history.count, 1)
        XCTAssertEqual(entry.status, .handedOff)
        XCTAssertEqual(entry.source, .app)
        XCTAssertEqual(entry.text, "Hello from the synthetic test.")
        XCTAssertEqual(entry.rawTranscript, "synthetic raw words")
        XCTAssertEqual(entry.route, .cleanup)
        XCTAssertNil(entry.usedRawFallback)
        XCTAssertEqual(entry.durationSeconds, 1.5, accuracy: 0.001)

        // The audio is deleted once processed, and the keyboard is still
        // waiting for the session, so it must not be cleared.
        XCTAssertEqual(spy.removedFiles, [recorder.startedURL].compactMap { $0 })
        model.close()
        XCTAssertEqual(spy.awaitedSessionID, session)
    }

    @MainActor
    func testHandoffWithNothingToInsertStillAnswersTheKeyboard() async throws {
        let spy = AppRecorderSpy()
        let session = UUID()
        spy.awaitedSessionID = session
        spy.results = [.success(appSyntheticResult(raw: "", text: "", route: .empty))]
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        let finished = await appWaitUntil { model.phase.accessibilityName == "nothing-to-insert" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertEqual(spy.pending.map(\.sessionID), [session])
        XCTAssertEqual(spy.pending.first?.text, "")
        XCTAssertEqual(spy.history.first?.status, .nothingToInsert)
    }

    @MainActor
    func testRawFallbackIsStillHandedOff() async throws {
        let spy = AppRecorderSpy()
        let session = UUID()
        spy.awaitedSessionID = session
        spy.results = [.success(appSyntheticResult(text: "synthetic raw words", route: .cleanup, usedRawFallback: true))]
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        _ = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertEqual(spy.history.first?.status, .handedOff)
        // `.handedOff` can't say the text is raw, so History keeps the flag.
        XCTAssertEqual(spy.history.first?.usedRawFallback, true)
        guard case .finished(let outcome) = model.phase else {
            return XCTFail("phase is \(model.phase)")
        }
        XCTAssertTrue(outcome.usedRawFallback)
        XCTAssertTrue(outcome.handedOff)
    }

    @MainActor
    func testCancellingAHandoffTellsTheKeyboardToStopWaiting() async throws {
        let spy = AppRecorderSpy()
        let session = UUID()
        spy.awaitedSessionID = session
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        model.close()

        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertNil(spy.awaitedSessionID)
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertTrue(spy.history.isEmpty)
    }

    @MainActor
    func testCancellingLeavesANewerAwaitedSessionAlone() {
        let spy = AppRecorderSpy()
        let newer = UUID()
        spy.awaitedSessionID = newer
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        model.close()

        XCTAssertEqual(spy.awaitedSessionID, newer)
    }

    @MainActor
    func testHandoffIsNotSavedOnceTheKeyboardStopsWaiting() async throws {
        // The user tapped Stop waiting (or dictated in the keyboard) while the
        // app was still transcribing: no keyboard will take the result, so
        // its text must not be left in the App Group.
        let spy = AppRecorderSpy()
        let session = UUID()
        spy.awaitedSessionID = session
        spy.processingDelay = 0.2
        spy.results = [.success(appSyntheticResult(text: "Synthetic words.", pressEnter: true))]
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        XCTAssertEqual(model.phase, .processing)
        // The keyboard stops waiting while the app transcribes.
        spy.awaitedSessionID = nil
        let finished = await appWaitUntil { model.phase.accessibilityName == "not-handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")

        XCTAssertTrue(spy.pending.isEmpty, "Nothing is saved for a keyboard that stopped waiting")
        guard case .finished(let outcome) = model.phase else {
            return XCTFail("phase is \(model.phase)")
        }
        XCTAssertEqual(outcome.text, "Synthetic words.", "The result is still shown, with Copy")
        XCTAssertTrue(outcome.keyboardStoppedWaiting)
        XCTAssertFalse(outcome.handedOff)
        XCTAssertFalse(outcome.pressEnter, "Nothing will press return")
        XCTAssertEqual(spy.history.first?.status, .notInserted)
        XCTAssertEqual(spy.history.first?.text, "Synthetic words.")

        model.close()
        XCTAssertNil(spy.awaitedSessionID)
    }

    @MainActor
    func testHandoffForASessionTheKeyboardDoesNotAwaitIsNotSaved() async throws {
        let spy = AppRecorderSpy()
        let other = UUID()
        spy.awaitedSessionID = other
        spy.results = [.success(appSyntheticResult())]
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        let finished = await appWaitUntil { model.phase.accessibilityName == "not-handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertTrue(spy.pending.isEmpty)

        model.close()
        XCTAssertEqual(spy.awaitedSessionID, other, "Another session's wait is left alone")
    }

    @MainActor
    func testStoppedWaitingWithNothingToInsertSavesNothing() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult(raw: "", text: "", pressEnter: true, route: .empty))]
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        let finished = await appWaitUntil { model.phase.accessibilityName == "nothing-to-insert" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertEqual(spy.history.first?.status, .nothingToInsert)
    }

    // MARK: In-app

    @MainActor
    func testInAppResultIsInsertedIntoTheTestField() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult(text: "Typed into the field.", pressEnter: true))]
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)
        let insertions = AppInsertionLog()
        model.onInsertIntoTestField = { text, pressEnter in
            insertions.record(text, pressEnter: pressEnter)
        }

        try await recordAndStop(model, spy: spy)
        let finished = await appWaitUntil { model.phase.accessibilityName == "done" }
        XCTAssertTrue(finished, "phase is \(model.phase)")

        XCTAssertEqual(insertions.texts, ["Typed into the field."])
        XCTAssertEqual(insertions.pressEnters, [true])
        XCTAssertTrue(spy.pending.isEmpty)
        XCTAssertEqual(spy.history.first?.status, .inserted)
        XCTAssertEqual(spy.history.first?.source, .app)
    }

    @MainActor
    func testInAppRawFallbackIsRecorded() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult(usedRawFallback: true))]
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)
        model.onInsertIntoTestField = { _, _ in }

        try await recordAndStop(model, spy: spy)
        _ = await appWaitUntil { model.phase.accessibilityName == "done" }
        XCTAssertEqual(spy.history.first?.status, .rawFallback)
        XCTAssertEqual(spy.history.first?.usedRawFallback, true)
    }

    @MainActor
    func testInAppReturnOnlyIsNothingToInsertLikeTheKeyboard() async throws {
        // "press enter" alone: return goes into the test field, and History
        // gets the keyboard's status for the same result.
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult(raw: "", text: "", pressEnter: true, route: .empty))]
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)
        let insertions = AppInsertionLog()
        model.onInsertIntoTestField = { text, pressEnter in
            insertions.record(text, pressEnter: pressEnter)
        }

        try await recordAndStop(model, spy: spy)
        let finished = await appWaitUntil { model.phase.accessibilityName == "done" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertEqual(insertions.texts, [""])
        XCTAssertEqual(insertions.pressEnters, [true])
        XCTAssertEqual(spy.history.first?.status, .nothingToInsert)
        XCTAssertEqual(
            spy.history.first?.status,
            HistoryEntry.Status.forInsertion(of: appSyntheticResult(raw: "", text: "", pressEnter: true, route: .empty))
        )
    }

    @MainActor
    func testInAppWithoutADestinationIsNotInserted() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        _ = await appWaitUntil { model.phase.accessibilityName == "done" }
        XCTAssertEqual(spy.history.first?.status, .notInserted)
    }

    // MARK: Gating

    @MainActor
    func testRecorderOpenedByALinkRecordsOnlyAfterStart() {
        for mode in [RecorderMode.inApp, .handoff(sessionID: UUID())] {
            let spy = AppRecorderSpy()
            let model = RecorderModel(mode: mode, dependencies: spy.dependencies(), startsOnAppear: false)

            model.startIfNeeded()
            XCTAssertEqual(model.phase, .idle, "Appearing must not record")
            XCTAssertEqual(model.phase.accessibilityName, "idle")
            XCTAssertTrue(spy.recorders.isEmpty)
            XCTAssertEqual(spy.microphoneMarkedGranted, 0)

            model.start()
            XCTAssertEqual(model.phase, .starting)
            XCTAssertEqual(spy.recorders.count, 1)
            model.start()
            XCTAssertEqual(spy.recorders.count, 1, "Start records once")
        }
    }

    /// The top bar says the recording is for the keyboard only when the
    /// keyboard asked for it.
    @MainActor
    func testTopBarSaysWhoTheRecordingIsFor() {
        let spy = AppRecorderSpy()
        let inApp = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)
        XCTAssertEqual(inApp.topBarCaption, "Dictate without the keyboard")

        let awaited = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: true)
        XCTAssertTrue(awaited.isForWaitingKeyboard)
        XCTAssertEqual(awaited.topBarCaption, "Dictating for the FreeFlow keyboard")

        let link = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: false)
        link.startIfNeeded()
        XCTAssertFalse(link.isForWaitingKeyboard)
        XCTAssertEqual(link.topBarCaption, "Opened from a link", "A link the keyboard didn't ask for")
        XCTAssertEqual(RecorderModel.linkCaption, "Opened from a link")

        link.resumeForAwaitedSession()
        XCTAssertTrue(link.isForWaitingKeyboard)
        XCTAssertEqual(link.topBarCaption, "Dictating for the FreeFlow keyboard", "The keyboard asked for it after all")
    }

    /// The keyboard's App Group write arrived after the app stopped
    /// re-reading it, so the recorder opened idle. Start then records for the
    /// keyboard, and the caption says so from the start.
    @MainActor
    func testStartForASessionTheKeyboardAwaitsAfterAllIsForTheKeyboard() {
        let spy = AppRecorderSpy()
        let session = UUID()
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: false)
        model.startIfNeeded()
        XCTAssertEqual(model.topBarCaption, "Opened from a link")

        spy.awaitedSessionID = session
        model.start()

        XCTAssertTrue(model.isForWaitingKeyboard)
        XCTAssertEqual(model.topBarCaption, "Dictating for the FreeFlow keyboard")
    }

    /// A link's recording that the keyboard never waited for keeps the
    /// link's caption to the end, next to "Not sent to the keyboard".
    @MainActor
    func testLinkRecordingTheKeyboardNeverAwaitedKeepsTheLinkCaption() async throws {
        let spy = AppRecorderSpy()
        spy.awaitedSessionID = nil
        spy.results = [.success(appSyntheticResult(text: "Hello from the synthetic test.", pressEnter: false))]
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: false)

        model.startIfNeeded()
        model.start()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        let isRecording = await appWaitUntil { model.phase == .recording }
        XCTAssertTrue(isRecording)
        model.stop()
        let finished = await appWaitUntil { model.phase.accessibilityName == "not-handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")

        XCTAssertEqual(model.topBarCaption, "Opened from a link")
        XCTAssertTrue(spy.pending.isEmpty, "Nothing is handed to a keyboard")
    }

    @MainActor
    func testKeyboardAskingAgainStartsAWaitingRecorder() {
        let spy = AppRecorderSpy()
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: false)

        model.startIfNeeded()
        model.resumeForAwaitedSession()

        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(spy.recorders.count, 1)
    }

    @MainActor
    func testMissingConfigurationNeedsSetupAndNeverRecords() {
        let spy = AppRecorderSpy()
        spy.configuration = nil
        let model = RecorderModel(mode: .handoff(sessionID: UUID()), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()

        XCTAssertEqual(model.phase, .setupNeeded)
        XCTAssertEqual(model.phase.accessibilityName, "setup-needed")
        XCTAssertTrue(spy.recorders.isEmpty)
    }

    @MainActor
    func testWithoutConsentNothingRecordsOrUploads() {
        // After a reinstall the API key can survive in the keychain while the
        // consent, kept in the App Group, is gone, and any app's freeflow://
        // link can open the recorder over onboarding. Start must not record,
        // ask for the microphone, or send anything before consent.
        let recorders: [(mode: RecorderMode, startsOnAppear: Bool)] = [
            (.inApp, false),
            (.handoff(sessionID: UUID()), false),
            (.handoff(sessionID: UUID()), true),
        ]
        for (mode, startsOnAppear) in recorders {
            let spy = AppRecorderSpy(microphone: AppFakeMicrophone(permission: .undetermined))
            spy.hasConsent = false
            spy.awaitedSessionID = mode.sessionID
            let model = RecorderModel(mode: mode, dependencies: spy.dependencies(), startsOnAppear: startsOnAppear)

            model.startIfNeeded()
            model.start()
            model.resumeForAwaitedSession()
            model.retry()

            XCTAssertEqual(model.phase, .consentNeeded, "\(mode)")
            XCTAssertEqual(model.phase.accessibilityName, "consent-needed")
            XCTAssertFalse(model.isBusy)
            XCTAssertTrue(spy.recorders.isEmpty, "No recording starts")
            XCTAssertEqual(spy.microphone.requestCount, 0, "Not even the microphone prompt")
            XCTAssertEqual(spy.microphoneMarkedGranted, 0)
            XCTAssertTrue(spy.processedURLs.isEmpty, "Nothing is sent to the provider")
            XCTAssertTrue(spy.history.isEmpty)
            XCTAssertTrue(spy.pending.isEmpty)
        }
    }

    @MainActor
    func testARecordingIsNotSentOnceConsentIsGone() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        _ = await appWaitUntil { model.phase == .recording }
        spy.hasConsent = false
        model.stop()

        XCTAssertEqual(model.phase, .consentNeeded)
        XCTAssertTrue(spy.processedURLs.isEmpty, "Nothing is sent to the provider")
        model.close()
        XCTAssertEqual(spy.removedFiles, [recorder.startedURL].compactMap { $0 }, "The recording is deleted")
    }

    @MainActor
    func testUndeterminedPermissionWaitsForContinueThenRecords() async throws {
        let spy = AppRecorderSpy(microphone: AppFakeMicrophone(permission: .undetermined, grantsOnRequest: true))
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        XCTAssertEqual(model.phase, .needsPermission)
        XCTAssertEqual(model.phase.accessibilityName, "needs-permission")
        XCTAssertTrue(spy.recorders.isEmpty)
        XCTAssertEqual(spy.microphone.requestCount, 0, "The prompt waits for the Continue button")

        await model.requestMicrophonePermission()

        XCTAssertEqual(spy.microphone.requestCount, 1)
        XCTAssertEqual(spy.microphoneMarkedGranted, 1)
        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(spy.recorders.count, 1)
    }

    @MainActor
    func testDeniedPermissionPromptShowsOpenSettingsState() async {
        let spy = AppRecorderSpy(microphone: AppFakeMicrophone(permission: .undetermined, grantsOnRequest: false))
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        await model.requestMicrophonePermission()

        XCTAssertEqual(model.phase, .permissionDenied)
        XCTAssertEqual(model.phase.accessibilityName, "permission-denied")
        XCTAssertEqual(spy.microphoneMarkedGranted, 0)
    }

    @MainActor
    func testPreviouslyDeniedPermissionDoesNotPrompt() {
        let spy = AppRecorderSpy(microphone: AppFakeMicrophone(permission: .denied))
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()

        XCTAssertEqual(model.phase, .permissionDenied)
        XCTAssertEqual(spy.microphone.requestCount, 0)
    }

    // MARK: Failures

    @MainActor
    func testTranscriptionErrorShowsTheMacOSMessageAndCanRetry() async throws {
        let spy = AppRecorderSpy()
        spy.results = [
            .failure(URLError(.notConnectedToInternet)),
            .success(appSyntheticResult(text: "Second try.")),
        ]
        let session = UUID()
        spy.awaitedSessionID = session
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        try await recordAndStop(model, spy: spy)
        let failed = await appWaitUntil { model.phase.accessibilityName == "error" }
        XCTAssertTrue(failed, "phase is \(model.phase)")
        XCTAssertEqual(model.phase, .failed(message: "No internet — check connection", retry: .processAgain))
        XCTAssertEqual(spy.history.first?.status, .failed)
        XCTAssertEqual(spy.history.first?.errorMessage, "No internet — check connection")
        XCTAssertTrue(spy.removedFiles.isEmpty, "The recording is kept for Try Again")

        model.retry()
        let retried = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(retried, "phase is \(model.phase)")
        XCTAssertEqual(spy.processedURLs.count, 2)
        XCTAssertEqual(spy.processedURLs.first, spy.processedURLs.last)
        XCTAssertEqual(spy.pending.first?.text, "Second try.")
        XCTAssertEqual(spy.removedFiles.count, 1)
    }

    @MainActor
    func testRecordingWithNoAudioFailsWithRecordAgain() async throws {
        let spy = AppRecorderSpy()
        spy.nextRecorderRecordsNothing = true
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        _ = await appWaitUntil { model.phase == .recording }
        model.stop()

        XCTAssertEqual(model.phase, .failed(message: RecorderModel.noAudioRecordedMessage, retry: .recordAgain))
        XCTAssertTrue(spy.processedURLs.isEmpty)

        spy.nextRecorderRecordsNothing = false
        model.retry()
        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(spy.recorders.count, 2)
    }

    @MainActor
    func testStartFailureIsReported() {
        let spy = AppRecorderSpy()
        spy.nextRecorderStartError = AppAudioRecorderError.noInputAvailable
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()

        XCTAssertEqual(model.phase, .failed(message: RecorderModel.startFailedMessage, retry: .recordAgain))
    }

    @MainActor
    func testNoAudioWithinTheStartTimeoutFails() async throws {
        let spy = AppRecorderSpy()
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(startTimeout: 0.05), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        let failed = await appWaitUntil { model.phase.accessibilityName == "error" }

        XCTAssertTrue(failed, "phase is \(model.phase)")
        XCTAssertEqual(model.phase, .failed(message: RecorderModel.noAudioBuffersMessage, retry: .recordAgain))
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    @MainActor
    func testFirstAudioCancelsTheStartTimeout() async throws {
        let spy = AppRecorderSpy()
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(startTimeout: 0.2), startsOnAppear: true)

        model.startIfNeeded()
        try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
        _ = await appWaitUntil { model.phase == .recording }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(model.phase, .recording)
    }

    // MARK: Leaving the app

    @MainActor
    func testLeavingTheAppStopsAndProcesses() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let session = UUID()
        spy.awaitedSessionID = session
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        _ = await appWaitUntil { model.phase == .recording }

        model.appDidEnterBackground()

        XCTAssertEqual(recorder.stopCount, 1)
        let finished = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
    }

    @MainActor
    func testSystemInterruptionStopsAndProcesses() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let session = UUID()
        spy.awaitedSessionID = session
        let model = RecorderModel(mode: .handoff(sessionID: session), dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        _ = await appWaitUntil { model.phase == .recording }

        recorder.onInterruption?()

        let finished = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertEqual(recorder.stopCount, 1)
    }

    @MainActor
    func testRecordingStopsAtTheMaximumDuration() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let session = UUID()
        spy.awaitedSessionID = session
        let model = RecorderModel(
            mode: .handoff(sessionID: session),
            dependencies: spy.dependencies(maximumDuration: 0.1),
            startsOnAppear: true
        )

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()

        let finished = await appWaitUntil { model.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(finished, "phase is \(model.phase)")
        XCTAssertEqual(recorder.stopCount, 1)
    }

    @MainActor
    func testLateCallbacksAfterCloseAreIgnored() async throws {
        let spy = AppRecorderSpy()
        let model = RecorderModel(mode: .inApp, dependencies: spy.dependencies(), startsOnAppear: true)

        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        model.close()
        recorder.onFirstAudio?()
        recorder.onLevel?(0.9)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.phase, .starting)
        XCTAssertEqual(model.level, 0)
    }

    // MARK: Presentation

    @MainActor
    func testElapsedTimeFormatting() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RecorderView.elapsedText(since: start, now: start), "0:00")
        XCTAssertEqual(RecorderView.elapsedText(since: start, now: start.addingTimeInterval(65.4)), "1:05")
        XCTAssertEqual(RecorderView.elapsedText(since: nil, now: start), "0:00")
    }

    func testOutcomeTreatsPressEnterAsSomethingToInsert() {
        let enterOnly = RecorderOutcome(text: "", rawTranscript: "press enter", pressEnter: true, route: .empty, usedRawFallback: false, handedOff: true)
        XCTAssertFalse(enterOnly.isNothingToInsert)
        XCTAssertEqual(RecorderPhase.finished(enterOnly).accessibilityName, "handed-off")

        let blank = RecorderOutcome(text: "  ", rawTranscript: "", pressEnter: false, route: .empty, usedRawFallback: false, handedOff: false)
        XCTAssertTrue(blank.isNothingToInsert)
        XCTAssertEqual(RecorderPhase.finished(blank).accessibilityName, "nothing-to-insert")
    }

    func testAccessibilityNamesForEveryPhase() {
        XCTAssertEqual(RecorderPhase.idle.accessibilityName, "idle")
        XCTAssertEqual(RecorderPhase.requestingPermission.accessibilityName, "needs-permission")
        XCTAssertEqual(RecorderPhase.setupNeeded.accessibilityName, "setup-needed")
        XCTAssertEqual(RecorderPhase.consentNeeded.accessibilityName, "consent-needed")
        XCTAssertEqual(RecorderPhase.recording.accessibilityName, "recording")
        XCTAssertEqual(RecorderPhase.processing.accessibilityName, "processing")
        XCTAssertEqual(RecorderPhase.failed(message: "x", retry: .recordAgain).accessibilityName, "error")
        let done = RecorderOutcome(text: "Hi.", rawTranscript: "hi", pressEnter: false, route: .cleanup, usedRawFallback: false, handedOff: false)
        XCTAssertEqual(RecorderPhase.finished(done).accessibilityName, "done")
        var notHandedOff = done
        notHandedOff.keyboardStoppedWaiting = true
        XCTAssertEqual(RecorderPhase.finished(notHandedOff).accessibilityName, "not-handed-off")
    }

    // MARK: Helpers

    @MainActor
    private func recordAndStop(_ model: RecorderModel, spy: AppRecorderSpy) async throws {
        model.startIfNeeded()
        let recorder = try XCTUnwrap(spy.lastRecorder)
        recorder.onFirstAudio?()
        let isRecording = await appWaitUntil { model.phase == .recording }
        XCTAssertTrue(isRecording, "phase is \(model.phase)")
        model.stop()
    }
}
