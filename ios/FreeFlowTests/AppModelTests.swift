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
    func testDictateURLWithASessionOpensAHandoffRecorder() throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())
        let session = UUID()

        app.handle(url: try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)")))

        let recorder = try XCTUnwrap(app.activeRecorder)
        XCTAssertEqual(recorder.mode, .handoff(sessionID: session))
        XCTAssertEqual(recorder.phase, .idle, "The recorder starts when it appears")
    }

    @MainActor
    func testDictateURLWithoutASessionRecordsInTheApp() throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())

        app.handle(url: try XCTUnwrap(URL(string: "freeflow://dictate")))

        XCTAssertEqual(app.activeRecorder?.mode, .inApp)
    }

    @MainActor
    func testUnknownURLLeavesTheAppAlone() throws {
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment())

        app.handle(url: try XCTUnwrap(URL(string: "freeflow://somewhere-else")))

        XCTAssertNil(app.activeRecorder)
    }

    @MainActor
    func testABusyRecorderAdoptsTheNewestSession() throws {
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

        app.handle(url: try XCTUnwrap(URL(string: "freeflow://dictate?session=\(second.uuidString)")))

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(recorder.mode, .handoff(sessionID: second))
    }

    @MainActor
    func testReopeningTheSameSessionKeepsTheKeyboardWaiting() throws {
        let spy = AppRecorderSpy()
        spy.nextRecorderStartError = AppAudioRecorderError.noInputAvailable
        let stores = AppTestStores()
        defer { stores.tearDown() }
        let app = FreeFlowAppModel(environment: stores.environment(recorderSpy: spy))
        let session = UUID()
        spy.awaitedSessionID = session
        let url = try XCTUnwrap(URL(string: "freeflow://dictate?session=\(session.uuidString)"))

        app.handle(url: url)
        let recorder = try XCTUnwrap(app.activeRecorder)
        recorder.startIfNeeded()
        XCTAssertEqual(recorder.phase, .failed(message: RecorderModel.startFailedMessage, retry: .recordAgain))

        // The keyboard's "Open FreeFlow" while waiting reopens the same session.
        spy.nextRecorderStartError = nil
        app.handle(url: url)

        XCTAssertTrue(app.activeRecorder === recorder)
        XCTAssertEqual(spy.awaitedSessionID, session, "The keyboard must still be waiting for this session")
        XCTAssertEqual(recorder.phase, .starting, "A failed recording gets another try")
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
