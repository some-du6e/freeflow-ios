import XCTest
@testable import FreeFlow

/// The app model: URL handling, setup state, consent withdrawal, and the
/// microphone flag the keyboard reads.
final class AppModelTests: XCTestCase {
    func testDictateURLs() throws {
        let session = UUID()
        XCTAssertEqual(
            FreeFlowURLRoute(url: try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))),
            .dictate(sessionID: session)
        )
        XCTAssertEqual(
            FreeFlowURLRoute(url: try XCTUnwrap(URL(string: "FREEFLOW://Dictate?session=\(session.uuidString.lowercased())"))),
            .dictate(sessionID: session)
        )
        XCTAssertEqual(
            FreeFlowURLRoute(url: try XCTUnwrap(URL(string: "freeflow:dictate?session=\(session.uuidString)"))),
            .dictate(sessionID: session)
        )
        XCTAssertEqual(FreeFlowURLRoute(url: try XCTUnwrap(URL(string: "freeflow://dictate"))), .dictate(sessionID: nil))
        XCTAssertEqual(
            FreeFlowURLRoute(url: try XCTUnwrap(URL(string: "freeflow://dictate?session=not-a-uuid"))),
            .dictate(sessionID: nil)
        )
    }

    func testOtherURLsAreIgnored() throws {
        for string in ["freeflow://settings", "freeflow://", "https://dictate.invalid/?session=x", "other://dictate"] {
            XCTAssertNil(FreeFlowURLRoute(url: try XCTUnwrap(URL(string: string))), string)
        }
    }

    @MainActor
    func testDictateURLForTheAwaitedSessionRecordsAtOnce() async throws {
        let spy = AppRecorderSpy()
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let session = UUID()
        // The keyboard writes the session to the App Group, then opens the URL.
        stores.pendingDictations.awaitedSessionID = session
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

        await app.handle(url: url)

        let recorder = try XCTUnwrap(app.activeRecorder)
        XCTAssertEqual(recorder.mode, .handoff(sessionID: session))
        XCTAssertTrue(recorder.startsOnAppear)
        XCTAssertEqual(recorder.phase, .idle, "The recorder starts when it appears")
        recorder.startIfNeeded()
        XCTAssertEqual(recorder.phase, .starting)
        XCTAssertEqual(spy.recorders.count, 1)
    }

    @MainActor
    func testDictateURLWithoutASessionWaitsForStart() async throws {
        // Nothing FreeFlow sends; any app could open it.
        let spy = AppRecorderSpy()
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let url = try XCTUnwrap(URL(string: "freeflow://dictate"))

        await app.handle(url: url)

        let recorder = try XCTUnwrap(app.activeRecorder)
        XCTAssertEqual(recorder.mode, .inApp)
        XCTAssertFalse(recorder.startsOnAppear)
        recorder.startIfNeeded()
        XCTAssertEqual(recorder.phase, .idle, "Opening the recorder must not record")
        XCTAssertTrue(spy.recorders.isEmpty)

        recorder.start()
        XCTAssertEqual(recorder.phase, .starting, "The Start button records")
    }

    @MainActor
    func testDictateURLForASessionTheKeyboardDoesNotAwaitWaitsForStart() async throws {
        // Any app can make up a session; only the one the keyboard wrote to
        // the App Group records on its own.
        let spy = AppRecorderSpy()
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        var pauses = 0
        app.awaitedSessionRereads = 3
        app.pauseBeforeRereadingAwaitedSession = { pauses += 1 }

        for awaited in [nil, UUID()] as [UUID?] {
            pauses = 0
            stores.pendingDictations.awaitedSessionID = awaited
            let session = UUID()
            let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

            await app.handle(url: url)

            let recorder = try XCTUnwrap(app.activeRecorder)
            XCTAssertEqual(recorder.mode, .handoff(sessionID: session))
            XCTAssertFalse(recorder.startsOnAppear)
            recorder.startIfNeeded()
            XCTAssertEqual(recorder.phase, .idle, "Opening the recorder must not record")
            XCTAssertEqual(pauses, 3, "The awaited session is re-read before giving up")
            XCTAssertEqual(stores.pendingDictations.awaitedSessionID, awaited)
        }
        XCTAssertTrue(spy.recorders.isEmpty)
        XCTAssertTrue(spy.pending.isEmpty)
    }

    @MainActor
    func testAwaitedSessionThatArrivesLateStillRecordsAtOnce() async throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        let session = UUID()
        var pauses = 0
        // The keyboard's App Group write shows up on the second re-read.
        app.pauseBeforeRereadingAwaitedSession = {
            pauses += 1
            if pauses == 2 {
                stores.pendingDictations.awaitedSessionID = session
            }
        }
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

        await app.handle(url: url)

        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(app.activeRecorder?.mode, .handoff(sessionID: session))
        XCTAssertEqual(app.activeRecorder?.startsOnAppear, true)
    }

    @MainActor
    func testUnknownURLLeavesTheAppAlone() async throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        let url = try XCTUnwrap(URL(string: "freeflow://somewhere-else"))

        await app.handle(url: url)

        XCTAssertNil(app.activeRecorder)
    }

    @MainActor
    func testAnAwaitedSessionReplacesABusyRecorderForAnotherSession() async throws {
        // In Alice's chat the keyboard opened the app for a first session.
        // The user said "on my way, press enter" and swiped back while it
        // was transcribing. In Bob's chat the keyboard stopped waiting (a mic
        // press), capture failed again, and it opened the app for a second
        // session from Bob's field. Alice's message must never be handed to
        // that session, where the keyboard would insert it into Bob's field
        // and press return. The second session records on its own.
        let first = UUID()
        let second = UUID()
        let firstURL = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(first.uuidString)"))
        let secondURL = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(second.uuidString)"))
        // A recorder opened for the awaited first session, and one opened by
        // a link nobody awaited and then started with a tap: neither may hand
        // its audio to the second session.
        for keyboardAwaitedTheFirst in [true, false] {
            let spy = AppRecorderSpy()
            spy.processingDelay = 0.3
            spy.results = [.success(appSyntheticResult(text: "On my way.", pressEnter: true))]
            let stores = AppTestStores()
            defer { stores.tearDown() }
            let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
            app.pauseBeforeRereadingAwaitedSession = {}
            stores.pendingDictations.awaitedSessionID = keyboardAwaitedTheFirst ? first : nil

            await app.handle(url: firstURL)
            let busy = try XCTUnwrap(app.activeRecorder)
            XCTAssertEqual(busy.startsOnAppear, keyboardAwaitedTheFirst)
            if keyboardAwaitedTheFirst {
                busy.startIfNeeded()
            } else {
                busy.start()
            }
            try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
            _ = await appWaitUntil { busy.phase == .recording }
            busy.appDidEnterBackground()
            XCTAssertEqual(busy.phase, .processing)

            stores.pendingDictations.awaitedSessionID = second
            await app.handle(url: secondURL)

            let fresh = try XCTUnwrap(app.activeRecorder)
            XCTAssertFalse(fresh === busy, "The second session gets a recorder of its own")
            XCTAssertEqual(fresh.mode, .handoff(sessionID: second))
            XCTAssertTrue(fresh.startsOnAppear)
            XCTAssertEqual(busy.mode, .handoff(sessionID: first), "A recorder never changes sessions")

            // The first recording is dropped: its transcription is cancelled
            // and nothing it said is saved for the keyboard or kept.
            let ended = await appWaitUntil { spy.endedRuns == 1 }
            XCTAssertTrue(ended, "The first recording's transcription must end")
            XCTAssertEqual(spy.cancelledRuns, 1, "It is cancelled, not finished")
            let leaked = await appWaitUntil(timeout: 0.3) { !spy.pending.isEmpty || !spy.history.isEmpty }
            XCTAssertFalse(leaked, "Nothing from the first recording is handed off or kept in History")
            XCTAssertEqual(stores.pendingDictations.awaitedSessionID, second, "The keyboard still waits for the second session")

            // What the keyboard gets for the second session is its own recording.
            spy.results = [.success(appSyntheticResult(text: "Running late.", pressEnter: true))]
            fresh.startIfNeeded()
            try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
            _ = await appWaitUntil { fresh.phase == .recording }
            fresh.stop()
            let handedOff = await appWaitUntil { fresh.phase.accessibilityName == "handed-off" }
            XCTAssertTrue(handedOff, "phase is \(fresh.phase)")
            XCTAssertEqual(spy.pending.map(\.sessionID), [second])
            XCTAssertEqual(spy.pending.map(\.text), ["Running late."])
        }
    }

    @MainActor
    func testABusyRecorderKeepsTheSessionItServes() async throws {
        // "Open FreeFlow" while the keyboard waits reopens the same session,
        // so the transcription under way is still the one the keyboard wants.
        let spy = AppRecorderSpy()
        spy.processingDelay = 0.2
        spy.results = [.success(appSyntheticResult(text: "Still for this field.", pressEnter: true))]
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let session = UUID()
        stores.pendingDictations.awaitedSessionID = session
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

        await app.handle(url: url)
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
        _ = await appWaitUntil { recorder.phase == .recording }
        recorder.appDidEnterBackground()
        XCTAssertEqual(recorder.phase, .processing)

        await app.handle(url: url)

        XCTAssertTrue(app.activeRecorder === recorder)
        let handedOff = await appWaitUntil { recorder.phase.accessibilityName == "handed-off" }
        XCTAssertTrue(handedOff, "phase is \(recorder.phase)")
        XCTAssertEqual(spy.cancelledRuns, 0)
        XCTAssertEqual(spy.pending.map(\.sessionID), [session])
        XCTAssertEqual(spy.pending.first?.pressEnter, true)
    }

    @MainActor
    func testABusyRecorderIgnoresAURLTheKeyboardDidNotSend() async throws {
        let spy = AppRecorderSpy()
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        app.pauseBeforeRereadingAwaitedSession = {}
        let first = UUID()
        stores.pendingDictations.awaitedSessionID = first

        app.startDictation(mode: .handoff(sessionID: first))
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        XCTAssertTrue(recorder.isBusy)

        for string in ["freeflow://dictate?session=\(UUID().uuidString)", "freeflow://dictate"] {
            let url = try XCTUnwrap(URL(string: string))
            await app.handle(url: url)

            XCTAssertTrue(app.activeRecorder === recorder, string)
            XCTAssertEqual(recorder.mode, .handoff(sessionID: first), "The result still goes to the session the keyboard awaits")
        }
        XCTAssertEqual(spy.recorders.count, 1)
        XCTAssertEqual(stores.pendingDictations.awaitedSessionID, first)
    }

    @MainActor
    func testAnAwaitedSessionReplacesABusyInAppRecorder() async throws {
        // "Dictate Without the Keyboard", then the user switches apps while it
        // transcribes and the keyboard there falls back to the app.
        let spy = AppRecorderSpy()
        // Short, so a run that wasn't cancelled would finish within the test.
        spy.processingDelay = 0.3
        spy.results = [.success(appSyntheticResult(text: "Meant for the test field."))]
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))

        app.startDictation(mode: .inApp)
        let inApp = try XCTUnwrap(app.activeRecorder)
        inApp.startIfNeeded()
        try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
        _ = await appWaitUntil { inApp.phase == .recording }
        inApp.appDidEnterBackground()
        XCTAssertEqual(inApp.phase, .processing)

        let session = UUID()
        stores.pendingDictations.awaitedSessionID = session
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))
        await app.handle(url: url)

        let handoff = try XCTUnwrap(app.activeRecorder)
        XCTAssertFalse(handoff === inApp, "The keyboard's request gets its own recorder")
        XCTAssertEqual(handoff.mode, .handoff(sessionID: session))
        XCTAssertTrue(handoff.startsOnAppear)
        XCTAssertEqual(inApp.mode, .inApp)

        // The replaced in-app run is cancelled: its text reaches neither the
        // keyboard, nor the test field, nor History.
        let ended = await appWaitUntil { spy.endedRuns == 1 }
        XCTAssertTrue(ended, "The in-app run must end")
        XCTAssertEqual(spy.cancelledRuns, 1, "The in-app run is cancelled, not finished")
        let leaked = await appWaitUntil(timeout: 0.3) {
            !spy.pending.isEmpty || !spy.history.isEmpty || !app.testFieldText.isEmpty
        }
        XCTAssertFalse(leaked, "Nothing from the in-app run is handed off, kept in History or inserted")
        XCTAssertEqual(app.testFieldText, "")
        XCTAssertEqual(stores.pendingDictations.awaitedSessionID, session)
    }

    @MainActor
    func testReopeningTheSameSessionKeepsTheKeyboardWaiting() async throws {
        let spy = AppRecorderSpy()
        spy.nextRecorderStartError = AppAudioRecorderError.noInputAvailable
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let session = UUID()
        spy.awaitedSessionID = session
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

        await app.handle(url: url)
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        XCTAssertEqual(recorder.phase, .failed(message: RecorderModel.startFailedMessage, retry: .recordAgain))

        // The keyboard's "Open FreeFlow" while waiting reopens the same session.
        spy.nextRecorderStartError = nil
        await app.handle(url: url)

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(spy.awaitedSessionID, session, "The keyboard must still be waiting for this session")
        XCTAssertEqual(recorder.phase, .starting, "A failed recording gets another try")
    }

    @MainActor
    func testReopeningASessionTheKeyboardDoesNotAwaitStartsNothing() async throws {
        let spy = AppRecorderSpy()
        spy.nextRecorderStartError = AppAudioRecorderError.noInputAvailable
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        app.pauseBeforeRereadingAwaitedSession = {}
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(UUID().uuidString)"))

        await app.handle(url: url)
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.start()
        XCTAssertEqual(recorder.phase, .failed(message: RecorderModel.startFailedMessage, retry: .recordAgain))

        spy.nextRecorderStartError = nil
        await app.handle(url: url)

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(recorder.phase, .failed(message: RecorderModel.startFailedMessage, retry: .recordAgain), "Only a tap retries")
        XCTAssertEqual(spy.recorders.count, 1)
    }

    @MainActor
    func testUnclaimedHandoffResultsAreDiscardedWhenTheAppStartsOrBecomesActive() throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let store = stores.pendingDictations
        let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))

        // A result no keyboard waits for, left by an earlier run.
        store.save(PendingDictation(sessionID: UUID(), createdAt: now, text: "Synthetic orphan.", pressEnter: false))
        let app = FreeFlowAppModel(environment: stores.environment())
        XCTAssertNil(stores.defaults.object(forKey: PendingDictationStore.pendingDictationKey), "Discarded at launch")

        // The keyboard stopped waiting after the app saved its result.
        let session = UUID()
        store.save(PendingDictation(sessionID: session, createdAt: now, text: "Synthetic late result.", pressEnter: false))
        app.sceneBecameActive()
        XCTAssertNil(stores.defaults.object(forKey: PendingDictationStore.pendingDictationKey))

        // A fresh result the keyboard still waits for stays.
        store.awaitedSessionID = session
        let waiting = PendingDictation(sessionID: session, createdAt: now, text: "Synthetic handoff.", pressEnter: true)
        store.save(waiting)
        app.sceneBecameActive()
        XCTAssertEqual(store.result(for: session, now: now), .fresh(waiting))

        // An expired one loses its text, so the keyboard can still say it expired.
        store.awaitedSessionID = session
        store.save(PendingDictation(sessionID: session, createdAt: now.addingTimeInterval(-600), text: "Synthetic old.", pressEnter: true))
        app.sceneBecameActive()
        XCTAssertEqual(
            store.result(for: session, now: now),
            .expired(PendingDictation(sessionID: session, createdAt: now.addingTimeInterval(-600), text: "", pressEnter: false))
        )
        XCTAssertEqual(store.awaitedSessionID, session, "The app never clears the keyboard's wait here")
    }

    @MainActor
    func testReopeningTheSameSessionKeepsAFinishedResult() async throws {
        let spy = AppRecorderSpy()
        spy.results = [.success(appSyntheticResult())]
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let session = UUID()
        spy.awaitedSessionID = session

        app.startDictation(mode: .handoff(sessionID: session))
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        try XCTUnwrap(spy.lastRecorder).onFirstAudio?()
        _ = await appWaitUntil { recorder.phase == .recording }
        recorder.stop()
        _ = await appWaitUntil { recorder.phase.accessibilityName == "handed-off" }

        app.startDictation(mode: .handoff(sessionID: session))

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(spy.pending.count, 1)
        XCTAssertEqual(spy.recorders.count, 1)
    }

    @MainActor
    func testClosingOtherPresentationsBumpsTheGeneration() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        let generation = app.presentationResetGeneration

        app.closeOtherPresentations()

        XCTAssertEqual(app.presentationResetGeneration, generation + 1)
    }

    @MainActor
    func testPresentationWaitStopsWhenTheConditionHolds() async {
        var checks = 0
        let started = Date()
        await FreeFlowPresentation.wait(timeout: 5) {
            checks += 1
            return checks >= 3
        }
        XCTAssertEqual(checks, 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)

        let timedOut = Date()
        await FreeFlowPresentation.wait(timeout: 0.1) { false }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(timedOut), 0.1)
    }

    @MainActor
    func testAnIdleRecorderIsReplaced() throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())

        app.startDictation(mode: .inApp)
        let first = try XCTUnwrap(app.activeRecorder)
        app.startDictation(mode: .handoff(sessionID: UUID()))

        XCTAssertFalse(app.activeRecorder === first)
    }

    @MainActor
    func testClosingTheRecorderRefreshesScreens() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        let generation = app.refreshGeneration

        app.startDictation(mode: .inApp)
        app.closeRecorder()

        XCTAssertNil(app.activeRecorder)
        XCTAssertGreaterThan(app.refreshGeneration, generation)
    }

    @MainActor
    func testCompletingAndRerunningSetup() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        XCTAssertFalse(app.hasCompletedSetup)

        app.selectedTab = .history
        app.completeOnboarding()
        XCTAssertTrue(app.hasCompletedSetup)
        XCTAssertTrue(stores.settings.hasCompletedSetup)
        XCTAssertEqual(app.selectedTab, .home)
        XCTAssertTrue(FreeFlowAppModel(environment: stores.environment()).hasCompletedSetup, "Read back on relaunch")

        app.rerunSetup()
        XCTAssertFalse(app.hasCompletedSetup)
        XCTAssertFalse(stores.settings.hasCompletedSetup)
        XCTAssertEqual(stores.settings.string(FreeFlowAppSettingKey.onboardingStep), "welcome")
    }

    @MainActor
    func testWithdrawingConsentDeletesTheKeysAndRestartsSetup() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        stores.credentials.storedAPIKey = "synthetic-key"
        stores.credentials.storedTranscriptionAPIKey = "synthetic-transcription-key"
        stores.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
        stores.settings.hasCompletedSetup = true
        let app = FreeFlowAppModel(environment: stores.environment())

        app.withdrawConsent()

        XCTAssertNil(stores.credentials.storedAPIKey)
        XCTAssertNil(stores.credentials.storedTranscriptionAPIKey)
        XCTAssertFalse(app.environment.hasDataSharingConsent)
        XCTAssertFalse(app.hasCompletedSetup)
        XCTAssertEqual(app.environment.apiKeyState(), .missing)
    }

    @MainActor
    func testTheRecorderReadsTheConsentFromSetup() {
        // The live recorder's gate is the flag onboarding's consent page sets.
        // A reinstall clears it with the App Group even when the API key
        // survives in the keychain.
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let dependencies = RecorderDependencies.live(environment: stores.environment())
        XCTAssertFalse(dependencies.hasConsent(), "Not agreed to in this install yet")

        stores.settings.set(true, for: FreeFlowAppSettingKey.dataSharingConsent)
        XCTAssertTrue(dependencies.hasConsent())

        stores.settings.removeValue(for: FreeFlowAppSettingKey.dataSharingConsent)
        XCTAssertFalse(dependencies.hasConsent(), "Withdrawing consent applies at once")
    }

    @MainActor
    func testARecorderWaitingForConsentReturnsToSetup() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())

        // Mid-onboarding (a freeflow:// link opened the recorder over it):
        // closing shows setup again, where consent comes next.
        app.startDictation(mode: .inApp)
        app.closeRecorderAndReturnToSetup()
        XCTAssertNil(app.activeRecorder)
        XCTAssertFalse(app.hasCompletedSetup)

        // After setup: it starts over from Welcome, like Re-run Setup.
        app.completeOnboarding()
        app.startDictation(mode: .inApp)
        app.closeRecorderAndReturnToSetup()
        XCTAssertNil(app.activeRecorder)
        XCTAssertFalse(app.hasCompletedSetup)
        XCTAssertEqual(stores.settings.string(FreeFlowAppSettingKey.onboardingStep), OnboardingStep.welcome.rawValue)
    }

    @MainActor
    func testMicrophoneFlagMirrorsThePermission() {
        let microphone = AppFakeMicrophone(permission: .granted)
        let stores = AppTestStores(microphone: microphone)
        defer { stores.tearDown() }

        let app = FreeFlowAppModel(environment: stores.environment())
        XCTAssertTrue(stores.settings.microphonePermissionGranted)

        microphone.permission = .denied
        app.sceneBecameActive()
        XCTAssertFalse(stores.settings.microphonePermissionGranted)
    }

    @MainActor
    func testUITestMicrophoneOverrideIsLeftAlone() {
        let stores = AppTestStores(microphone: AppFakeMicrophone(permission: .undetermined))
        defer { stores.tearDown() }
        stores.settings.microphonePermissionGranted = true

        let app = FreeFlowAppModel(environment: stores.environment(), microphoneFlagIsOverridden: true)
        app.sceneBecameActive()

        XCTAssertTrue(stores.settings.microphonePermissionGranted)
    }

    @MainActor
    func testInsertingIntoTheTestFieldAppendsAndPressesReturn() {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())

        app.insertIntoTestField("First synthetic line.", pressEnter: true)
        XCTAssertTrue(app.testFieldText.hasPrefix("First synthetic line."))
        XCTAssertTrue(app.testFieldText.hasSuffix("\n"))

        app.insertIntoTestField("Second.", pressEnter: false)
        XCTAssertTrue(app.testFieldText.contains("Second."))
        XCTAssertFalse(app.testFieldText.hasSuffix("\n"))
    }

    @MainActor
    func testTabsCarryTheDesignIdentifiers() {
        let identifiers = FreeFlowAppTab.allCases.map { FreeFlowTabsView.makeTabBarItem(for: $0).accessibilityIdentifier }
        XCTAssertEqual(identifiers, ["freeflow.app.tab.home", "freeflow.app.tab.history", "freeflow.app.tab.settings"])
        XCTAssertEqual(FreeFlowAppTab.allCases.map(\.title), ["Home", "History", "Settings"])
        XCTAssertEqual(FreeFlowTabsView.makeTabBarItem(for: .settings).tag, FreeFlowAppTab.settings.rawValue)
    }
}
