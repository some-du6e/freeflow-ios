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
    func testABusyRecorderAdoptsTheAwaitedSession() async throws {
        let spy = AppRecorderSpy()
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let first = UUID()
        let second = UUID()

        app.startDictation(mode: .handoff(sessionID: first))
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        XCTAssertTrue(recorder.isBusy)

        // The keyboard stopped waiting for the first session and asked again.
        stores.pendingDictations.awaitedSessionID = second
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(second.uuidString)"))
        await app.handle(url: url)

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(recorder.mode, .handoff(sessionID: second))
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
    func testABusyInAppRecorderNeverAdoptsAHandoff() async throws {
        // "Dictate Without the Keyboard", then the user switches apps while it
        // transcribes and the keyboard there falls back to the app.
        let spy = AppRecorderSpy()
        spy.processingDelay = 5
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
        // keyboard nor the test field.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(spy.pending.isEmpty)
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
        XCTAssertEqual(store.take(sessionID: session, now: now), .fresh(waiting))

        // An expired one loses its text, so the keyboard can still say it expired.
        store.awaitedSessionID = session
        store.save(PendingDictation(sessionID: session, createdAt: now.addingTimeInterval(-600), text: "Synthetic old.", pressEnter: true))
        app.sceneBecameActive()
        XCTAssertEqual(
            store.take(sessionID: session, now: now),
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
