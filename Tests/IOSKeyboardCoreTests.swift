import Foundation

/// Tests for the Foundation-only keyboard dictation state machine and panel
/// helpers in ios/Shared/Core/Keyboard. Times are offsets from the reference
/// date so threshold arithmetic is exact; text, files and IDs are invented.
enum IOSKeyboardCoreTests {
    static func run() {
        testSetupIssuesComeInFixOrder()
        testMemoryGate()
        testSetupChangesMoveTheRestingState()
        testPressWithUnknownSetupDoesNothing()
        testPressWhileSetupNeededShowsTheIssue()
        testPressWithLowMemoryOffersTheFallback()
        testTapToToggleRecordsAndInserts()
        testHoldToTalkStopsOnRelease()
        testHoldThresholdBoundary()
        testHoldStateArrivesWithoutRelease()
        testDoneStopsRecording()
        testSecondPressDuringHoldOrProcessingIsIgnored()
        testCancelDiscardsCaptureOrTask()
        testAutoStopAfterFiveMinutes()
        testCaptureFailuresBeforeAudioOfferTheFallback()
        testPermissionDeniedNeedsSetup()
        testCaptureFailuresAfterAudio()
        testStartAndStopBackstops()
        testStrayCaptureCallbacks()
        testMicPressRetriesFromResultStates()
        testEmptyTranscriptIsNothingToInsert()
        testPressEnterInsertsNewline()
        testPressEnterAloneInsertsOnlyNewline()
        testRawFallbackIsReported()
        testChangedFieldIsNotInserted()
        testUnknownDocumentStillInserts()
        testHiddenKeyboardDoesNotInsert()
        testStaleAndCancelledPipelineResultsAreIgnored()
        testPipelineFailureShowsTruncatedMessage()
        testMessageFormattingMatchesMacOS()
        testTimedStatesExpireToTheRestingState()
        testInsertLast()
        testFallbackHandoffFlow()
        testHandoffResultInsertion()
        testHandoffFieldMatchGatesAutoInsert()
        testExpiredHandoffResultEndsTheWait()
        testHandoffCTANeverPressesReturn()
        testUnconfirmedFieldWithNothingToInsertShowsNoCTA()
        testHeldHandoffResultSurvivesForInsertLast()
        testPendingInsertExpiresAndDismisses()
        testOfferLetsGoOnceSeenAndLeft()
        testHandoffWaitEnds()
        testBlockedPressesKeepWaitingForTheApp()
        testHandoffAdoptionCountsFromTheOpenTime()
        testInsertLastPrefersTheNewestSource()
        testRememberedTextCoversHistoryOff()
        testHandoffLedger()
        testReopeningFromAnotherFieldNeverAutoInserts()
        testHandoffCheckReadsTheStore()
        testDisappearingCancelsCapture()
        testHapticsNeedFullAccess()
        testDisplayForEveryPhase()
        testDisplayWording()
        testDebugStatesCoverEveryStatus()
        testDeleteRepeatTiming()
        testWordDeletionCounts()
        testReturnKeyKinds()
        testWaveformShape()
        testHandoffURL()
        testAccessibilityIdentifiersAndStatusNames()
        testHistoryDraftMakesKeyboardEntry()
    }

    // MARK: Fixtures

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private static let fieldA = UUID(uuidString: "0A0A0A0A-0000-4000-8000-00000000000A")!
    private static let fieldB = UUID(uuidString: "0B0B0B0B-0000-4000-8000-00000000000B")!
    private static let sessionOne = UUID(uuidString: "5E551000-0000-4000-8000-000000000001")!
    private static let sessionTwo = UUID(uuidString: "5E551000-0000-4000-8000-000000000002")!
    /// Unlike the two above, its first 8 characters differ, for log wording.
    private static let sessionThree = UUID(uuidString: "7A1E0000-0000-4000-8000-000000000003")!
    private static let samplePending = PendingDictation(
        sessionID: sessionOne,
        createdAt: t0,
        text: "Recorded in the app.",
        pressEnter: false
    )
    private static let ready = KeyboardDictationSetup(
        hasFullAccess: true,
        microphoneGranted: true,
        hasAPIKey: true,
        availableMemoryBytes: 64 * 1024 * 1024
    )
    private static let noAPIKey = KeyboardDictationSetup(
        hasFullAccess: true,
        microphoneGranted: true,
        hasAPIKey: false,
        availableMemoryBytes: nil
    )
    private static let fallbackText = "Can't record in the keyboard here. Record in FreeFlow instead."

    private static func at(_ seconds: TimeInterval) -> Date {
        t0 + seconds
    }

    private static func status(_ machine: KeyboardDictationMachine) -> KeyboardDictationStatus {
        KeyboardDictationDisplay(machine: machine).status
    }

    private static func text(_ machine: KeyboardDictationMachine) -> String {
        KeyboardDictationDisplay(machine: machine).statusText
    }

    private static func insertions(_ effects: [KeyboardDictationEffect]) -> [String] {
        effects.compactMap { effect in
            if case .insert(let text) = effect { return text }
            return nil
        }
    }

    private static func sampleAudio(_ name: String = "freeflow-keyboard-test") -> KeyboardDictationAudio {
        KeyboardDictationAudio(fileURL: URL(fileURLWithPath: "/tmp/\(name).wav"), duration: 2.5)
    }

    private static func result(
        _ text: String,
        raw: String? = nil,
        pressEnter: Bool = false,
        route: DictationRoute = .cleanup,
        rawFallback: Bool = false
    ) -> DictationResult {
        DictationResult(
            rawTranscript: raw ?? text,
            text: text,
            pressEnter: pressEnter,
            route: route,
            usedRawFallback: rawFallback
        )
    }

    private static func document(_ identifier: UUID? = fieldA, before: String? = "Dear Sam,") -> KeyboardDictationDocument {
        KeyboardDictationDocument(identifier: identifier, textBeforeCursor: before)
    }

    private static func draft(
        _ status: HistoryEntry.Status,
        at seconds: TimeInterval,
        raw: String,
        text: String,
        route: DictationRoute? = .cleanup,
        rawFallback: Bool = false
    ) -> KeyboardDictationHistoryDraft {
        KeyboardDictationHistoryDraft(
            createdAt: at(seconds),
            status: status,
            rawTranscript: raw,
            text: text,
            route: route,
            errorMessage: nil,
            durationSeconds: 2.5,
            usedRawFallback: rawFallback
        )
    }

    /// The text a `.rememberForInsertLast` effect kept, as Insert last sees it.
    private static func remembered(_ effects: [KeyboardDictationEffect]) -> KeyboardRememberedText? {
        var remembered: KeyboardRememberedText?
        for effect in effects {
            if case .rememberForInsertLast(let text, let time) = effect {
                remembered = KeyboardRememberedText(text: text, savedAt: time)
            }
        }
        return remembered
    }

    private static func readyMachine(_ setup: KeyboardDictationSetup = ready) -> KeyboardDictationMachine {
        var machine = KeyboardDictationMachine()
        _ = machine.handle(.setupChanged(setup), now: t0)
        _ = machine.handle(.appeared, now: t0)
        return machine
    }

    /// Tap to toggle: pressed at 0 s, released at 0.25 s, audio from 0.5 s.
    private static func recordingMachine(documentID: UUID? = fieldA) -> KeyboardDictationMachine {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: documentID), now: at(0))
        _ = machine.handle(.micPressEnded, now: at(0.25))
        _ = machine.handle(.captureStarted, now: at(0.5))
        return machine
    }

    /// Stopped with Done at 3 s; the recording arrived at 3.25 s.
    private static func processingMachine(
        _ audio: KeyboardDictationAudio,
        documentID: UUID? = fieldA
    ) -> KeyboardDictationMachine {
        var machine = recordingMachine(documentID: documentID)
        _ = machine.handle(.doneTapped, now: at(3))
        _ = machine.handle(.captureFinished(audio), now: at(3.25))
        return machine
    }

    // MARK: Setup gating

    private static func testSetupIssuesComeInFixOrder() {
        let nothing = KeyboardDictationSetup(hasFullAccess: false, microphoneGranted: false, hasAPIKey: false, availableMemoryBytes: nil)
        TestSupport.expectEqual(nothing.blockingIssue, .fullAccess)
        let onlyAccessMissing = KeyboardDictationSetup(hasFullAccess: false, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: nil)
        TestSupport.expectEqual(onlyAccessMissing.blockingIssue, .fullAccess)
        let noMicrophone = KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: false, hasAPIKey: false, availableMemoryBytes: nil)
        TestSupport.expectEqual(noMicrophone.blockingIssue, .microphone)
        TestSupport.expectEqual(noAPIKey.blockingIssue, .apiKey)
        TestSupport.expectEqual(ready.blockingIssue, nil)
    }

    private static func testMemoryGate() {
        func setup(_ bytes: Int?) -> KeyboardDictationSetup {
            KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: bytes)
        }
        TestSupport.expectEqual(KeyboardDictationSetup.minimumAvailableMemoryBytes, 33_554_432)
        TestSupport.expect(setup(nil).hasMemoryToRecord, "An unreported limit (the simulator) must not block capture")
        TestSupport.expect(!setup(33_554_431).hasMemoryToRecord, "Less than 32 MB free must block capture")
        TestSupport.expect(setup(33_554_432).hasMemoryToRecord, "32 MB free must allow capture")
    }

    private static func testSetupChangesMoveTheRestingState() {
        var machine = KeyboardDictationMachine()
        TestSupport.expectEqual(status(machine), .idle)

        let noAccess = KeyboardDictationSetup(hasFullAccess: false, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: nil)
        TestSupport.expectEqual(machine.handle(.setupChanged(noAccess), now: t0), [])
        TestSupport.expectEqual(machine.phase, .setupNeeded(.fullAccess))
        TestSupport.expectEqual(status(machine), .setupNeeded)
        TestSupport.expectEqual(text(machine), "Turn on Allow Full Access in Settings to dictate")

        _ = machine.handle(.setupChanged(noAPIKey), now: t0)
        TestSupport.expectEqual(machine.phase, .setupNeeded(.apiKey))
        TestSupport.expectEqual(text(machine), "Open FreeFlow to add your API key")

        _ = machine.handle(.setupChanged(ready), now: t0)
        TestSupport.expectEqual(machine.phase, .idle)

        var recording = recordingMachine()
        _ = recording.handle(.setupChanged(noAPIKey), now: at(1))
        TestSupport.expectEqual(status(recording), .recording)
    }

    private static func testPressWithUnknownSetupDoesNothing() {
        var machine = KeyboardDictationMachine()
        TestSupport.expectEqual(machine.handle(.micPressBegan(documentID: fieldA), now: t0), [])
        TestSupport.expectEqual(machine.phase, .idle)
        TestSupport.expectEqual(machine.attempt, 0)
    }

    private static func testPressWhileSetupNeededShowsTheIssue() {
        let noMicrophone = KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: false, hasAPIKey: true, availableMemoryBytes: nil)
        var machine = readyMachine(noMicrophone)
        TestSupport.expectEqual(machine.phase, .setupNeeded(.microphone))

        let effects = machine.handle(.micPressBegan(documentID: fieldA), now: t0)
        TestSupport.expectEqual(effects, [.announce("Open FreeFlow to allow the microphone")])
        TestSupport.expectEqual(machine.phase, .setupNeeded(.microphone))
        TestSupport.expectEqual(machine.attempt, 0)

        _ = machine.handle(.setupChanged(ready), now: at(1))
        TestSupport.expectEqual(machine.handle(.micPressBegan(documentID: fieldA), now: at(1)), [.startCapture])
        TestSupport.expectEqual(machine.attempt, 1)
    }

    private static func testPressWithLowMemoryOffersTheFallback() {
        let lowMemory = KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: 20 * 1024 * 1024)
        var machine = readyMachine(lowMemory)
        TestSupport.expectEqual(machine.phase, .idle)

        let effects = machine.handle(.micPressBegan(documentID: fieldA), now: t0)
        TestSupport.expectEqual(effects, [.announce("Not enough memory to record here. Record in FreeFlow instead.")])
        TestSupport.expectEqual(machine.phase, .fallbackAvailable(.lowMemory))
        TestSupport.expectEqual(machine.attempt, 0)
        let display = KeyboardDictationDisplay(machine: machine)
        TestSupport.expectEqual(display.status, .fallbackAvailable)
        TestSupport.expectEqual(display.trailingAction, .openApp)
    }

    // MARK: Gestures

    private static func testTapToToggleRecordsAndInserts() {
        var machine = readyMachine()
        var effects = machine.handle(.micPressBegan(documentID: fieldA), now: at(0))
        TestSupport.expectEqual(effects, [.startCapture])
        TestSupport.expectEqual(status(machine), .starting)
        TestSupport.expectEqual(machine.attempt, 1)
        TestSupport.expectEqual(machine.nextWakeUp, at(0.35))

        effects = machine.handle(.micPressEnded, now: at(0.25))
        TestSupport.expectEqual(effects, [])
        TestSupport.expectEqual(machine.activeRecording?.gesture, .latched)
        TestSupport.expectEqual(machine.nextWakeUp, at(6))

        effects = machine.handle(.captureStarted, now: at(0.5))
        TestSupport.expectEqual(effects, [.haptic, .reportCapture(worked: true, failure: nil)])
        TestSupport.expectEqual(status(machine), .recording)
        TestSupport.expectEqual(text(machine), "Listening… tap the mic to stop")
        TestSupport.expectEqual(machine.nextWakeUp, at(300))

        effects = machine.handle(.micPressBegan(documentID: fieldA), now: at(4))
        TestSupport.expectEqual(effects, [.haptic, .stopCapture])
        TestSupport.expectEqual(status(machine), .processing)
        TestSupport.expectEqual(machine.nextWakeUp, at(9))
        TestSupport.expectEqual(machine.handle(.micPressEnded, now: at(4.25)), [])

        let audio = sampleAudio()
        effects = machine.handle(.captureFinished(audio), now: at(4.5))
        TestSupport.expectEqual(effects, [.runPipeline(attempt: 1, audioFileURL: audio.fileURL)])
        TestSupport.expectEqual(machine.nextWakeUp, nil)

        let finished = result("Hello world.", raw: "hello world")
        effects = machine.handle(
            .pipelineFinished(attempt: 1, result: finished, document: document(fieldA, before: "Note:")),
            now: at(5)
        )
        TestSupport.expectEqual(effects, [
            .deleteAudio(audio.fileURL),
            .insert(TranscriptRouting.insertionText(for: "Hello world.", precedingText: "Note:")),
            .recordHistory(draft(.inserted, at: 5, raw: "hello world", text: "Hello world.")),
            .rememberForInsertLast(text: "Hello world.", at: at(5)),
            .announce("Inserted"),
        ])
        TestSupport.expectEqual(machine.phase, .inserted(.dictation, until: at(6.5)))

        _ = machine.handle(.tick, now: at(6.25))
        TestSupport.expectEqual(status(machine), .inserted)
        _ = machine.handle(.tick, now: at(6.5))
        TestSupport.expectEqual(machine.phase, .idle)
        TestSupport.expectEqual(machine.nextWakeUp, nil)
    }

    private static func testHoldToTalkStopsOnRelease() {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: fieldA), now: at(0))
        _ = machine.handle(.captureStarted, now: at(0.25))
        TestSupport.expectEqual(text(machine), "Listening…")

        TestSupport.expectEqual(machine.handle(.micPressEnded, now: at(2)), [.haptic, .stopCapture])
        TestSupport.expectEqual(status(machine), .processing)
    }

    private static func testHoldThresholdBoundary() {
        TestSupport.expectEqual(KeyboardDictationMachine.holdToTalkThreshold, 0.35)

        var quick = readyMachine()
        _ = quick.handle(.micPressBegan(documentID: nil), now: at(0))
        TestSupport.expectEqual(quick.handle(.micPressEnded, now: at(0.34)), [])
        TestSupport.expectEqual(quick.activeRecording?.gesture, .latched)

        var held = readyMachine()
        _ = held.handle(.micPressBegan(documentID: nil), now: at(0))
        TestSupport.expectEqual(held.handle(.micPressEnded, now: at(0.35)), [.haptic, .stopCapture])
        TestSupport.expectEqual(status(held), .processing)
    }

    private static func testHoldStateArrivesWithoutRelease() {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = machine.handle(.captureStarted, now: at(0.25))
        TestSupport.expectEqual(machine.nextWakeUp, at(0.35))

        TestSupport.expectEqual(machine.handle(.tick, now: at(0.35)), [])
        TestSupport.expectEqual(machine.activeRecording?.gesture, .holding)
        TestSupport.expectEqual(text(machine), "Listening… release to stop")
        TestSupport.expectEqual(machine.nextWakeUp, at(300))

        TestSupport.expectEqual(machine.handle(.micPressEnded, now: at(1)), [.haptic, .stopCapture])
    }

    private static func testDoneStopsRecording() {
        var idle = readyMachine()
        TestSupport.expectEqual(idle.handle(.doneTapped, now: t0), [])
        TestSupport.expectEqual(idle.phase, .idle)

        var machine = recordingMachine()
        TestSupport.expectEqual(machine.handle(.doneTapped, now: at(2)), [.haptic, .stopCapture])
        TestSupport.expectEqual(status(machine), .processing)

        // Done before any audio stops too; capture then reports no audio.
        var starting = readyMachine()
        _ = starting.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = starting.handle(.micPressEnded, now: at(0.25))
        TestSupport.expectEqual(starting.handle(.doneTapped, now: at(1)), [.haptic, .stopCapture])
        TestSupport.expectEqual(starting.handle(.captureFailed(.noAudio), now: at(1.25)), [.announce("No audio was recorded")])
        TestSupport.expectEqual(starting.phase, .nothingToInsert(.noAudio, until: at(4.25)))
    }

    private static func testSecondPressDuringHoldOrProcessingIsIgnored() {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: nil), now: at(0))
        TestSupport.expectEqual(machine.handle(.micPressBegan(documentID: nil), now: at(0.25)), [])
        TestSupport.expectEqual(status(machine), .starting)
        TestSupport.expectEqual(machine.attempt, 1)

        var processing = processingMachine(sampleAudio())
        TestSupport.expectEqual(processing.handle(.micPressBegan(documentID: nil), now: at(4)), [])
        TestSupport.expectEqual(processing.handle(.micPressEnded, now: at(4.25)), [])
        TestSupport.expectEqual(status(processing), .processing)
    }

    private static func testCancelDiscardsCaptureOrTask() {
        var starting = readyMachine()
        _ = starting.handle(.micPressBegan(documentID: nil), now: at(0))
        TestSupport.expectEqual(starting.handle(.cancelTapped, now: at(0.5)), [.cancelCapture])
        TestSupport.expectEqual(starting.phase, .idle)

        var recording = recordingMachine()
        TestSupport.expectEqual(recording.handle(.cancelTapped, now: at(2)), [.cancelCapture])
        TestSupport.expectEqual(recording.phase, .idle)
        TestSupport.expectEqual(recording.handle(.micPressEnded, now: at(2.25)), [])

        var stopping = recordingMachine()
        _ = stopping.handle(.doneTapped, now: at(2))
        TestSupport.expectEqual(stopping.handle(.cancelTapped, now: at(2.25)), [.cancelCapture])
        TestSupport.expectEqual(stopping.phase, .idle)

        let audio = sampleAudio()
        var processing = processingMachine(audio)
        TestSupport.expectEqual(processing.handle(.cancelTapped, now: at(4)), [.cancelPipeline, .deleteAudio(audio.fileURL)])
        TestSupport.expectEqual(processing.phase, .idle)
        TestSupport.expectEqual(
            processing.handle(.pipelineFinished(attempt: 1, result: result("Late."), document: document()), now: at(5)),
            []
        )
        TestSupport.expectEqual(processing.handle(.pipelineFailed(attempt: 1, message: "Late"), now: at(5)), [])
        TestSupport.expectEqual(processing.phase, .idle)

        // Cancelling back to rest respects missing setup.
        var cancelledWithoutKey = recordingMachine()
        _ = cancelledWithoutKey.handle(.setupChanged(noAPIKey), now: at(1))
        _ = cancelledWithoutKey.handle(.cancelTapped, now: at(2))
        TestSupport.expectEqual(cancelledWithoutKey.phase, .setupNeeded(.apiKey))

        var idle = readyMachine()
        TestSupport.expectEqual(idle.handle(.cancelTapped, now: t0), [])
    }

    private static func testAutoStopAfterFiveMinutes() {
        TestSupport.expectEqual(KeyboardDictationMachine.maximumRecordingDuration, 300)

        var machine = recordingMachine()
        TestSupport.expectEqual(machine.nextWakeUp, at(300))
        TestSupport.expectEqual(machine.handle(.tick, now: at(299.5)), [])
        TestSupport.expectEqual(status(machine), .recording)
        TestSupport.expectEqual(machine.handle(.tick, now: at(300)), [.haptic, .stopCapture])
        TestSupport.expectEqual(status(machine), .processing)

        var held = readyMachine()
        _ = held.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = held.handle(.captureStarted, now: at(0.5))
        _ = held.handle(.tick, now: at(1))
        TestSupport.expectEqual(held.activeRecording?.gesture, .holding)
        TestSupport.expectEqual(held.handle(.tick, now: at(300)), [.haptic, .stopCapture])
        TestSupport.expectEqual(held.handle(.micPressEnded, now: at(301)), [])
        TestSupport.expectEqual(status(held), .processing)
    }

    // MARK: Capture failures

    private static func testCaptureFailuresBeforeAudioOfferTheFallback() {
        let failures: [KeyboardDictationCaptureFailure] = [.pageUnavailable, .startTimedOut, .unsupported, .interrupted]
        for failure in failures {
            var machine = readyMachine()
            _ = machine.handle(.micPressBegan(documentID: nil), now: at(0))
            let effects = machine.handle(.captureFailed(failure), now: at(0.5))
            TestSupport.expectEqual(machine.phase, .fallbackAvailable(.captureUnavailable))
            TestSupport.expectEqual(effects, [.reportCapture(worked: false, failure: failure), .announce(fallbackText)])

            let display = KeyboardDictationDisplay(machine: machine)
            TestSupport.expectEqual(display.status, .fallbackAvailable)
            TestSupport.expectEqual(display.trailingAction, .openApp)
            TestSupport.expectEqual(display.cancelTitle, "Not now")
            TestSupport.expectEqual(machine.handle(.micPressEnded, now: at(1)), [])
        }

        var dismissed = readyMachine()
        _ = dismissed.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = dismissed.handle(.captureFailed(.pageUnavailable), now: at(0.5))
        TestSupport.expectEqual(dismissed.handle(.cancelTapped, now: at(1)), [])
        TestSupport.expectEqual(dismissed.phase, .idle)
    }

    private static func testPermissionDeniedNeedsSetup() {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: nil), now: at(0))
        let effects = machine.handle(.captureFailed(.permissionDenied), now: at(0.5))
        TestSupport.expectEqual(machine.phase, .setupNeeded(.microphone))
        TestSupport.expectEqual(status(machine), .setupNeeded)
        TestSupport.expectEqual(text(machine), "Open FreeFlow to allow the microphone")
        TestSupport.expectEqual(effects, [
            .reportCapture(worked: false, failure: .permissionDenied),
            .announce("Open FreeFlow to allow the microphone"),
        ])
    }

    private static func testCaptureFailuresAfterAudio() {
        var interrupted = recordingMachine()
        var effects = interrupted.handle(.captureFailed(.interrupted), now: at(2))
        TestSupport.expectEqual(interrupted.phase, .error(message: "Recording stopped unexpectedly. Try again.", until: at(8)))
        TestSupport.expectEqual(effects, [
            .reportCapture(worked: true, failure: .interrupted),
            .announce("Recording stopped unexpectedly. Try again."),
        ])

        var fileError = recordingMachine()
        _ = fileError.handle(.doneTapped, now: at(2))
        effects = fileError.handle(.captureFailed(.fileError), now: at(2.25))
        TestSupport.expectEqual(fileError.phase, .error(message: "Couldn't save the recording. Try again.", until: at(8.25)))
        TestSupport.expectEqual(effects.first, .reportCapture(worked: true, failure: .fileError))

        var pageGone = recordingMachine()
        _ = pageGone.handle(.captureFailed(.pageUnavailable), now: at(2))
        TestSupport.expectEqual(pageGone.phase, .fallbackAvailable(.captureUnavailable))

        var denied = recordingMachine()
        _ = denied.handle(.captureFailed(.permissionDenied), now: at(2))
        TestSupport.expectEqual(denied.phase, .setupNeeded(.microphone))

        var tooShort = recordingMachine()
        _ = tooShort.handle(.doneTapped, now: at(0.75))
        effects = tooShort.handle(.captureFailed(.noAudio), now: at(1))
        TestSupport.expectEqual(effects, [.announce("No audio was recorded")])
        TestSupport.expectEqual(tooShort.phase, .nothingToInsert(.noAudio, until: at(4)))
    }

    private static func testStartAndStopBackstops() {
        // The capture's own watchdog, up to the first start's 4 s, must get to
        // report why a start failed before the backstop gives up.
        TestSupport.expect(
            KeyboardDictationMachine.startBackstop > KeyboardDictationMachine.firstStartCaptureTimeout,
            "The start backstop must outlast the capture's first-start watchdog"
        )
        var silent = readyMachine()
        _ = silent.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = silent.handle(.micPressEnded, now: at(0.25))
        TestSupport.expectEqual(silent.handle(.tick, now: at(4)), [])
        TestSupport.expectEqual(silent.handle(.tick, now: at(5.5)), [])
        TestSupport.expectEqual(silent.handle(.tick, now: at(6)), [
            .cancelCapture,
            .reportCapture(worked: false, failure: .startTimedOut),
            .announce(fallbackText),
        ])
        TestSupport.expectEqual(silent.phase, .fallbackAvailable(.captureUnavailable))

        var stuck = recordingMachine()
        _ = stuck.handle(.doneTapped, now: at(2))
        TestSupport.expectEqual(stuck.nextWakeUp, at(7))
        TestSupport.expectEqual(stuck.handle(.tick, now: at(6.5)), [])
        TestSupport.expectEqual(stuck.handle(.tick, now: at(7)), [
            .cancelCapture,
            .announce("The recording didn't finish. Try again."),
        ])
        TestSupport.expectEqual(stuck.phase, .error(message: "The recording didn't finish. Try again.", until: at(13)))
    }

    private static func testStrayCaptureCallbacks() {
        var machine = readyMachine()
        TestSupport.expectEqual(machine.handle(.captureStarted, now: t0), [])
        TestSupport.expectEqual(machine.handle(.captureFailed(.startTimedOut), now: t0), [])
        let stray = sampleAudio("freeflow-keyboard-stray")
        TestSupport.expectEqual(machine.handle(.captureFinished(stray), now: t0), [.deleteAudio(stray.fileURL)])
        TestSupport.expectEqual(machine.phase, .idle)

        let audio = sampleAudio()
        var processing = processingMachine(audio)
        TestSupport.expectEqual(processing.handle(.captureFinished(audio), now: at(4)), [])
        TestSupport.expectEqual(processing.handle(.captureFinished(stray), now: at(4)), [.deleteAudio(stray.fileURL)])
        TestSupport.expectEqual(processing.handle(.captureFailed(.interrupted), now: at(4)), [])
        TestSupport.expectEqual(processing.handle(.captureStarted, now: at(4)), [])
        TestSupport.expectEqual(status(processing), .processing)

        // Capture that ends by itself with audio still gets transcribed.
        var ended = recordingMachine()
        TestSupport.expectEqual(ended.handle(.captureFinished(audio), now: at(2)), [.runPipeline(attempt: 1, audioFileURL: audio.fileURL)])
        TestSupport.expectEqual(status(ended), .processing)
    }

    private static func testMicPressRetriesFromResultStates() {
        var fallback = readyMachine()
        _ = fallback.handle(.micPressBegan(documentID: nil), now: at(0))
        _ = fallback.handle(.captureFailed(.startTimedOut), now: at(2))
        TestSupport.expectEqual(fallback.handle(.micPressBegan(documentID: nil), now: at(3)), [.startCapture])
        TestSupport.expectEqual(fallback.attempt, 2)

        var failed = recordingMachine()
        _ = failed.handle(.captureFailed(.interrupted), now: at(2))
        TestSupport.expectEqual(status(failed), .error)
        TestSupport.expectEqual(failed.handle(.micPressBegan(documentID: nil), now: at(3)), [.startCapture])
        TestSupport.expectEqual(status(failed), .starting)
    }

    // MARK: Pipeline results

    private static func testEmptyTranscriptIsNothingToInsert() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        let empty = DictationResult(rawTranscript: "", text: "", pressEnter: false, route: .empty, usedRawFallback: false)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: empty, document: document()), now: at(4))
        TestSupport.expectEqual(effects, [
            .deleteAudio(audio.fileURL),
            .recordHistory(draft(.nothingToInsert, at: 4, raw: "", text: "", route: .empty)),
            .announce("Nothing to transcribe"),
        ])
        TestSupport.expectEqual(machine.phase, .nothingToInsert(.emptyTranscript, until: at(7)))

        var spaces = processingMachine(audio)
        let blank = spaces.handle(.pipelineFinished(attempt: 1, result: result("  \n"), document: document()), now: at(4))
        TestSupport.expectEqual(insertions(blank), [])
        TestSupport.expectEqual(status(spaces), .nothingToInsert)
    }

    private static func testPressEnterInsertsNewline() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        let finished = result("Ship it.", raw: "ship it press enter", pressEnter: true)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: finished, document: document(before: nil)), now: at(4))
        TestSupport.expectEqual(effects, [
            .deleteAudio(audio.fileURL),
            .insert(TranscriptRouting.insertionText(for: "Ship it.", precedingText: nil)),
            .insert("\n"),
            .recordHistory(draft(.inserted, at: 4, raw: "ship it press enter", text: "Ship it.")),
            .rememberForInsertLast(text: "Ship it.", at: at(4)),
            .announce("Inserted"),
        ])
    }

    private static func testPressEnterAloneInsertsOnlyNewline() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        let enterOnly = DictationResult(rawTranscript: "press enter", text: "", pressEnter: true, route: .empty, usedRawFallback: false)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: enterOnly, document: document()), now: at(4))
        TestSupport.expectEqual(effects, [
            .deleteAudio(audio.fileURL),
            .insert("\n"),
            .recordHistory(draft(.nothingToInsert, at: 4, raw: "press enter", text: "", route: .empty)),
            .announce("Pressed return"),
        ])
        TestSupport.expectEqual(machine.phase, .inserted(.returnOnly, until: at(5.5)))
    }

    private static func testRawFallbackIsReported() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        let fallback = result("um hello there", rawFallback: true)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: fallback, document: document()), now: at(4))
        TestSupport.expect(
            effects.contains(.recordHistory(draft(.rawFallback, at: 4, raw: "um hello there", text: "um hello there", rawFallback: true))),
            "A raw fallback must be recorded as rawFallback, with the fallback flag for History"
        )
        TestSupport.expect(
            effects.contains(.rememberForInsertLast(text: "um hello there", at: at(4))),
            "A raw fallback must be kept for Insert last"
        )
        TestSupport.expectEqual(insertions(effects), [TranscriptRouting.insertionText(for: "um hello there", precedingText: "Dear Sam,")])
        TestSupport.expectEqual(machine.phase, .inserted(.rawFallback, until: at(5.5)))
        TestSupport.expectEqual(text(machine), "Inserted without cleanup")
    }

    private static func testChangedFieldIsNotInserted() {
        let audio = sampleAudio()
        var machine = processingMachine(audio, documentID: fieldA)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: result("Hello."), document: document(fieldB)), now: at(4))
        TestSupport.expectEqual(effects, [
            .deleteAudio(audio.fileURL),
            .recordHistory(draft(.notInserted, at: 4, raw: "Hello.", text: "Hello.")),
            .rememberForInsertLast(text: "Hello.", at: at(4)),
            .announce(KeyboardDictationMachine.fieldChangedMessage),
        ])
        TestSupport.expectEqual(machine.phase, .error(message: KeyboardDictationMachine.fieldChangedMessage, until: at(10)))
        TestSupport.expect(KeyboardDictationMachine.fieldChangedMessage.contains("Insert last"), "The message must point to Insert last")
        TestSupport.expect(KeyboardDictationMachine.fieldChangedMessage.count <= 90, "The message must fit the 90-character limit")

        var enter = processingMachine(audio, documentID: fieldA)
        let enterOnly = DictationResult(rawTranscript: "press enter", text: "", pressEnter: true, route: .empty, usedRawFallback: false)
        let enterEffects = enter.handle(.pipelineFinished(attempt: 1, result: enterOnly, document: document(fieldB)), now: at(4))
        TestSupport.expectEqual(insertions(enterEffects), [])
        TestSupport.expect(
            !enterEffects.contains { if case .rememberForInsertLast = $0 { return true }; return false },
            "Return alone leaves nothing for Insert last"
        )
        TestSupport.expectEqual(enter.phase, .error(message: KeyboardDictationMachine.fieldChangedReturnMessage, until: at(10)))
    }

    private static func testUnknownDocumentStillInserts() {
        let audio = sampleAudio()
        var machine = processingMachine(audio, documentID: nil)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: result("Hi."), document: document(fieldB, before: "")), now: at(4))
        TestSupport.expectEqual(insertions(effects), [TranscriptRouting.insertionText(for: "Hi.", precedingText: "")])
        TestSupport.expectEqual(status(machine), .inserted)

        TestSupport.expect(!KeyboardDictationMachine.documentChanged(from: nil, to: fieldA), "An unknown start field must not block insertion")
        TestSupport.expect(!KeyboardDictationMachine.documentChanged(from: fieldA, to: nil), "An unknown current field must not block insertion")
        TestSupport.expect(!KeyboardDictationMachine.documentChanged(from: fieldA, to: fieldA), "The same field is unchanged")
        TestSupport.expect(KeyboardDictationMachine.documentChanged(from: fieldA, to: fieldB), "A different field is a change")
    }

    private static func testHiddenKeyboardDoesNotInsert() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        TestSupport.expectEqual(machine.handle(.disappeared, now: at(4)), [])
        TestSupport.expectEqual(status(machine), .processing)

        let effects = machine.handle(.pipelineFinished(attempt: 1, result: result("Hello."), document: document()), now: at(5))
        TestSupport.expectEqual(insertions(effects), [])
        TestSupport.expect(
            effects.contains(.recordHistory(draft(.notInserted, at: 5, raw: "Hello.", text: "Hello."))),
            "A result the keyboard couldn't insert must stay in history for Insert last"
        )
        TestSupport.expect(
            effects.contains(.rememberForInsertLast(text: "Hello.", at: at(5))),
            "A result the keyboard couldn't insert must stay available to Insert last"
        )
        TestSupport.expectEqual(status(machine), .error)

        _ = machine.handle(.appeared, now: at(20))
        TestSupport.expectEqual(machine.phase, .idle)
    }

    private static func testStaleAndCancelledPipelineResultsAreIgnored() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        TestSupport.expectEqual(machine.handle(.pipelineFinished(attempt: 2, result: result("Wrong."), document: document()), now: at(4)), [])
        TestSupport.expectEqual(machine.handle(.pipelineFailed(attempt: 0, message: "Old"), now: at(4)), [])
        TestSupport.expectEqual(status(machine), .processing)

        _ = machine.handle(.cancelTapped, now: at(4))
        _ = machine.handle(.micPressBegan(documentID: fieldA), now: at(5))
        TestSupport.expectEqual(machine.attempt, 2)
        _ = machine.handle(.micPressEnded, now: at(5.25))
        _ = machine.handle(.captureStarted, now: at(5.5))
        _ = machine.handle(.doneTapped, now: at(7))
        let second = sampleAudio("freeflow-keyboard-second")
        TestSupport.expectEqual(machine.handle(.captureFinished(second), now: at(7.25)), [.runPipeline(attempt: 2, audioFileURL: second.fileURL)])
        TestSupport.expectEqual(machine.handle(.pipelineFinished(attempt: 1, result: result("First."), document: document()), now: at(8)), [])
        let effects = machine.handle(.pipelineFinished(attempt: 2, result: result("Second."), document: document()), now: at(8))
        TestSupport.expectEqual(insertions(effects), [TranscriptRouting.insertionText(for: "Second.", precedingText: "Dear Sam,")])

        var stopping = recordingMachine()
        _ = stopping.handle(.doneTapped, now: at(2))
        TestSupport.expectEqual(stopping.handle(.pipelineFinished(attempt: 1, result: result("Early."), document: document()), now: at(2.5)), [])
        TestSupport.expectEqual(stopping.handle(.pipelineFailed(attempt: 1, message: "Early"), now: at(2.5)), [])
        TestSupport.expectEqual(status(stopping), .processing)
    }

    private static func testPipelineFailureShowsTruncatedMessage() {
        let audio = sampleAudio()
        var machine = processingMachine(audio)
        let long = String(repeating: "Provider error detail ", count: 8)
        let shown = KeyboardDictationMachine.displayMessage(long)
        TestSupport.expectEqual(shown.count, 90)
        TestSupport.expect(shown.hasSuffix("…"), "A cut message must end in an ellipsis")

        let effects = machine.handle(.pipelineFailed(attempt: 1, message: long), now: at(4))
        let failed = KeyboardDictationHistoryDraft(
            createdAt: at(4),
            status: .failed,
            rawTranscript: "",
            text: "",
            route: nil,
            errorMessage: shown,
            durationSeconds: 2.5
        )
        TestSupport.expectEqual(effects, [.deleteAudio(audio.fileURL), .recordHistory(failed), .announce(shown)])
        TestSupport.expectEqual(machine.phase, .error(message: shown, until: at(10)))
        TestSupport.expectEqual(KeyboardDictationDisplay(machine: machine).tone, .failure)
        TestSupport.expectEqual(machine.nextWakeUp, at(10))

        _ = machine.handle(.tick, now: at(9.5))
        TestSupport.expectEqual(status(machine), .error)
        _ = machine.handle(.tick, now: at(10))
        TestSupport.expectEqual(machine.phase, .idle)

        let timeout = DictationPipeline.userFacingMessage(for: URLError(.timedOut), isOnline: true)
        TestSupport.expectEqual(timeout, "Request timed out — try again")
        TestSupport.expectEqual(KeyboardDictationMachine.displayMessage(timeout), timeout)
    }

    private static func testMessageFormattingMatchesMacOS() {
        TestSupport.expectEqual(KeyboardDictationMachine.maximumMessageLength, 90)
        let exactly90 = String(repeating: "a", count: 90)
        TestSupport.expectEqual(KeyboardDictationMachine.displayMessage(exactly90), exactly90)
        let ninetyOne = String(repeating: "b", count: 91)
        TestSupport.expectEqual(KeyboardDictationMachine.displayMessage(ninetyOne), String(repeating: "b", count: 89) + "…")
        TestSupport.expectEqual(KeyboardDictationMachine.displayMessage("Line one\n  line two  "), "Line one line two")
        TestSupport.expectEqual(KeyboardDictationMachine.displayMessage(" \n "), "Something went wrong")
    }

    private static func testTimedStatesExpireToTheRestingState() {
        var machine = readyMachine()
        _ = machine.handle(.insertLastTapped(text: nil, document: document()), now: at(0))
        TestSupport.expectEqual(machine.nextWakeUp, at(3))

        // Hidden and shown again before the deadline: still showing.
        _ = machine.handle(.disappeared, now: at(1))
        _ = machine.handle(.appeared, now: at(2))
        TestSupport.expectEqual(status(machine), .nothingToInsert)

        // Setup changes wait for the message to finish, then show.
        _ = machine.handle(.setupChanged(noAPIKey), now: at(2.5))
        TestSupport.expectEqual(status(machine), .nothingToInsert)
        _ = machine.handle(.tick, now: at(3))
        TestSupport.expectEqual(machine.phase, .setupNeeded(.apiKey))

        // Shown again after the deadline: back to rest at once.
        var late = readyMachine()
        _ = late.handle(.insertLastTapped(text: "Again.", document: document()), now: at(0))
        _ = late.handle(.disappeared, now: at(0.5))
        _ = late.handle(.appeared, now: at(1.5))
        TestSupport.expectEqual(late.phase, .idle)
    }

    // MARK: Insert last

    private static func testInsertLast() {
        var machine = readyMachine()
        var effects = machine.handle(.insertLastTapped(text: nil, document: document()), now: at(1))
        TestSupport.expectEqual(effects, [.announce("Nothing to insert yet")])
        TestSupport.expectEqual(machine.phase, .nothingToInsert(.noHistory, until: at(4)))

        effects = machine.handle(.insertLastTapped(text: " \n", document: document()), now: at(1.5))
        TestSupport.expectEqual(effects, [.announce("Nothing to insert yet")])

        effects = machine.handle(.insertLastTapped(text: "Earlier dictation.", document: document(before: "Re:")), now: at(2))
        TestSupport.expectEqual(effects, [
            .insert(TranscriptRouting.insertionText(for: "Earlier dictation.", precedingText: "Re:")),
            .announce("Inserted your last dictation"),
        ])
        TestSupport.expectEqual(machine.phase, .inserted(.lastDictation, until: at(3.5)))

        var busy = recordingMachine()
        TestSupport.expectEqual(busy.handle(.insertLastTapped(text: "Earlier.", document: document()), now: at(1)), [])
        TestSupport.expect(!KeyboardDictationDisplay(machine: busy).insertLastEnabled, "Insert last must be disabled while recording")
        TestSupport.expectEqual(status(busy), .recording)
    }

    // MARK: Open-the-app fallback

    private static func testFallbackHandoffFlow() {
        var machine = readyMachine()
        _ = machine.handle(.micPressBegan(documentID: fieldA), now: at(0))
        _ = machine.handle(.captureFailed(.pageUnavailable), now: at(0.25))

        var effects = machine.handle(.openAppTapped(newSessionID: sessionOne), now: at(1))
        TestSupport.expectEqual(effects, [.openApp(sessionID: sessionOne)])
        TestSupport.expectEqual(machine.phase, .waitingForApp(sessionID: sessionOne, since: at(1), nextCheck: at(2)))
        let display = KeyboardDictationDisplay(machine: machine)
        TestSupport.expectEqual(display.status, .waitingForApp)
        TestSupport.expectEqual(display.trailingAction, .openApp)
        TestSupport.expectEqual(display.cancelTitle, "Stop waiting")

        // While visible, it checks the store every second.
        TestSupport.expectEqual(machine.nextWakeUp, at(2))
        TestSupport.expectEqual(machine.handle(.tick, now: at(1.5)), [])
        TestSupport.expectEqual(machine.handle(.tick, now: at(2)), [.checkForAppResult])
        effects = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: at(1)), now: at(2))
        TestSupport.expectEqual(effects, [])
        TestSupport.expectEqual(machine.phase, .waitingForApp(sessionID: sessionOne, since: at(1), nextCheck: at(3)))

        // Hidden (the user is in FreeFlow), only the wait limit remains.
        _ = machine.handle(.disappeared, now: at(2.5))
        TestSupport.expectEqual(machine.nextWakeUp, at(421))
        TestSupport.expectEqual(machine.handle(.tick, now: at(3)), [])

        // Back after longer than a result stays fresh, with the app still
        // transcribing: keep waiting rather than drop the session.
        _ = machine.handle(.appeared, now: at(200))
        TestSupport.expectEqual(machine.handle(.handoffPending(sessionID: sessionOne, openedAt: at(1)), now: at(200)), [])
        TestSupport.expectEqual(machine.handle(.tick, now: at(201)), [.checkForAppResult])
        TestSupport.expectEqual(status(machine), .waitingForApp)
        _ = machine.handle(.disappeared, now: at(202))

        // Opening again reuses the session being waited on.
        _ = machine.handle(.appeared, now: at(204))
        TestSupport.expectEqual(machine.handle(.openAppTapped(newSessionID: sessionTwo), now: at(205)), [.openApp(sessionID: sessionOne)])
        TestSupport.expectEqual(machine.phase, .waitingForApp(sessionID: sessionOne, since: at(205), nextCheck: at(206)))

        // With no way to open the app, say so and stop waiting.
        effects = machine.handle(.appOpenFailed, now: at(205))
        TestSupport.expectEqual(effects, [.stopAwaitingApp(sessionID: sessionOne), .announce("Couldn't open FreeFlow. Open it from your Home Screen.")])
        TestSupport.expectEqual(machine.phase, .fallbackAvailable(.openFailed))
        TestSupport.expectEqual(machine.handle(.openAppTapped(newSessionID: sessionTwo), now: at(206)), [.openApp(sessionID: sessionTwo)])

        var idle = readyMachine()
        TestSupport.expectEqual(idle.handle(.openAppTapped(newSessionID: sessionTwo), now: t0), [])
        TestSupport.expectEqual(idle.handle(.appOpenFailed, now: t0), [])
        TestSupport.expectEqual(idle.phase, .idle)
    }

    private static func testHandoffResultInsertion() {
        var machine = readyMachine()
        _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        TestSupport.expectEqual(machine.phase, .waitingForApp(sessionID: sessionOne, since: at(0), nextCheck: at(1)))

        // Same field as the open: auto-insert.
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "From the app.", pressEnter: true)
        let effects = machine.handle(
            .handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(before: "Hi")),
            now: at(12)
        )
        TestSupport.expectEqual(effects, [
            .stopAwaitingApp(sessionID: sessionOne),
            .insert(TranscriptRouting.insertionText(for: "From the app.", precedingText: "Hi")),
            .insert("\n"),
            .rememberForInsertLast(text: "From the app.", at: at(12)),
            .announce("Inserted from FreeFlow"),
        ])
        TestSupport.expectEqual(machine.phase, .inserted(.handoff, until: at(13.5)))

        // An expired result is never inserted, even into the same field; the
        // wait ends with a message (testExpiredHandoffResultEndsTheWait).
        var stale = readyMachine()
        _ = stale.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        let old = PendingDictation(sessionID: sessionOne, createdAt: at(0), text: "Old.", pressEnter: true)
        let staleEffects = stale.handle(.handoffResultArrived(old, expectedDocumentID: fieldA, document: document()), now: at(500))
        TestSupport.expectEqual(insertions(staleEffects), [])
        TestSupport.expectEqual(stale.phase, .error(message: KeyboardDictationMachine.handoffExpiredMessage, until: at(506)))

        var empty = readyMachine()
        let blank = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: " ", pressEnter: false)
        TestSupport.expectEqual(
            empty.handle(.handoffResultArrived(blank, expectedDocumentID: fieldA, document: document()), now: at(11)),
            [.stopAwaitingApp(sessionID: sessionOne), .announce("Nothing to transcribe")]
        )

        var enterOnly = readyMachine()
        let enter = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "", pressEnter: true)
        TestSupport.expectEqual(
            enterOnly.handle(.handoffResultArrived(enter, expectedDocumentID: fieldA, document: document()), now: at(11)),
            [.stopAwaitingApp(sessionID: sessionOne), .insert("\n"), .announce("Pressed return")]
        )

        var busy = recordingMachine()
        TestSupport.expectEqual(
            busy.handle(.handoffResultArrived(pending, expectedDocumentID: fieldA, document: document()), now: at(12)),
            []
        )
        TestSupport.expectEqual(busy.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(12)), [])
        TestSupport.expectEqual(status(busy), .recording)
    }

    private static func testHandoffFieldMatchGatesAutoInsert() {
        // Unknown field on either side is not a match, so it waits for a tap.
        var unknownExpected = readyMachine()
        _ = unknownExpected.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "Handed back.", pressEnter: false)
        let effects = unknownExpected.handle(
            .handoffResultArrived(pending, expectedDocumentID: nil, document: document(fieldA)),
            now: at(12)
        )
        // The offer leaves the result in the store until it is used.
        TestSupport.expectEqual(effects, [
            .rememberForInsertLast(text: "Handed back.", at: at(12)),
            .announce(KeyboardDictationDisplay.pendingInsertText),
        ])
        TestSupport.expectEqual(unknownExpected.phase, .pendingInsert(pending, until: at(10) + PendingDictation.maxAge))
        let display = KeyboardDictationDisplay(machine: unknownExpected)
        TestSupport.expectEqual(display.status, .pendingInsert)
        TestSupport.expect(display.pendingInsertVisible, "The CTA must show in pending-insert")
        TestSupport.expect(!display.insertLastEnabled, "Insert last gives way to the CTA")

        // A different field also waits.
        var mismatch = readyMachine()
        _ = mismatch.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        _ = mismatch.handle(
            .handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(fieldB)),
            now: at(12)
        )
        TestSupport.expectEqual(mismatch.phase, .pendingInsert(pending, until: at(10) + PendingDictation.maxAge))
        TestSupport.expectEqual(mismatch.nextWakeUp, at(10) + PendingDictation.maxAge)

        // The explicit tap inserts into the current field (its own spacing).
        // It lets go of the store's copy first, so a keyboard stopped part way
        // can't leave it for another to insert again.
        let tapEffects = mismatch.handle(.insertPendingTapped(document: document(fieldB, before: "Hi")), now: at(20))
        TestSupport.expectEqual(tapEffects, [
            .stopAwaitingApp(sessionID: sessionOne),
            .insert(TranscriptRouting.insertionText(for: "Handed back.", precedingText: "Hi")),
            .rememberForInsertLast(text: "Handed back.", at: at(20)),
            .announce("Inserted from FreeFlow"),
        ])
        TestSupport.expectEqual(mismatch.phase, .inserted(.handoff, until: at(21.5)))

        TestSupport.expect(KeyboardDictationMachine.documentMatches(expected: fieldA, current: fieldA), "Equal known fields match")
        TestSupport.expect(!KeyboardDictationMachine.documentMatches(expected: fieldA, current: fieldB), "Different fields don't match")
        TestSupport.expect(!KeyboardDictationMachine.documentMatches(expected: nil, current: fieldA), "An unknown expected field never matches")
        TestSupport.expect(!KeyboardDictationMachine.documentMatches(expected: fieldA, current: nil), "An unknown current field never matches")
    }

    private static func testExpiredHandoffResultEndsTheWait() {
        // `PendingDictationStore.result(for:now:)` reports `.expired` for an old result
        // (it used to say "nothing yet"), and the keyboard hands it over like
        // a fresh one. The wait must end at once, with a short message.
        var machine = readyMachine()
        _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: at(0)), now: at(0))
        TestSupport.expectEqual(status(machine), .waitingForApp)

        let expired = PendingDictation(sessionID: sessionOne, createdAt: at(20), text: "Kept for later.", pressEnter: false)
        let now = at(20) + PendingDictation.maxAge + 1
        let effects = machine.handle(
            .handoffResultArrived(expired, expectedDocumentID: fieldA, document: document(fieldA)),
            now: now
        )
        TestSupport.expectEqual(effects, [
            .stopAwaitingApp(sessionID: sessionOne),
            .rememberForInsertLast(text: "Kept for later.", at: now),
            .announce(KeyboardDictationMachine.handoffExpiredMessage),
        ])
        TestSupport.expect(!machine.isWaitingForApp, "An expired result must end the wait")
        TestSupport.expectEqual(status(machine), .error)
        TestSupport.expectEqual(text(machine), KeyboardDictationMachine.handoffExpiredMessage)
        TestSupport.expectEqual(insertions(effects), [])

        // Briefly: no more store checks, and the message clears like an error.
        let until = now + KeyboardDictationMachine.errorDisplayDuration
        TestSupport.expectEqual(machine.nextWakeUp, until)
        TestSupport.expectEqual(machine.handle(.tick, now: until), [])
        TestSupport.expectEqual(machine.phase, .idle)

        // Insert last still has the text with Keep History off (no history).
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: remembered(effects), history: []), "Kept for later.")

        // A new keyboard process, not waiting yet, says the same.
        var newProcess = readyMachine()
        _ = newProcess.handle(.handoffResultArrived(expired, expectedDocumentID: nil, document: document()), now: now)
        TestSupport.expectEqual(newProcess.phase, .error(message: KeyboardDictationMachine.handoffExpiredMessage, until: until))

        // Without text (or the app's expired marker), it only says it expired.
        var empty = readyMachine()
        _ = empty.handle(.handoffPending(sessionID: sessionOne, openedAt: at(0)), now: at(0))
        let marker = PendingDictation(sessionID: sessionOne, createdAt: at(20), text: "", pressEnter: false)
        TestSupport.expectEqual(
            empty.handle(.handoffResultArrived(marker, expectedDocumentID: fieldA, document: document()), now: now),
            [.stopAwaitingApp(sessionID: sessionOne), .announce(KeyboardDictationMachine.handoffExpiredEmptyMessage)]
        )
        TestSupport.expectEqual(empty.phase, .error(message: KeyboardDictationMachine.handoffExpiredEmptyMessage, until: until))
    }

    private static func testHandoffCTANeverPressesReturn() {
        // "On my way press enter" in the app, then back in a field the
        // keyboard can't confirm: the tap adds the text and never presses
        // return, which could send it to the wrong recipient.
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "On my way.", pressEnter: true)
        for expected in [fieldA, nil] as [UUID?] {
            var machine = readyMachine()
            _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
            let arrival = machine.handle(
                .handoffResultArrived(pending, expectedDocumentID: expected, document: document(fieldB)),
                now: at(12)
            )
            TestSupport.expectEqual(insertions(arrival), [])
            TestSupport.expectEqual(status(machine), .pendingInsert)

            let tap = machine.handle(.insertPendingTapped(document: document(fieldB, before: "Hi")), now: at(20))
            TestSupport.expectEqual(tap, [
                .stopAwaitingApp(sessionID: sessionOne),
                .insert(TranscriptRouting.insertionText(for: "On my way.", precedingText: "Hi")),
                .rememberForInsertLast(text: "On my way.", at: at(20)),
                .announce("Inserted from FreeFlow. Return wasn't pressed."),
            ])
            TestSupport.expectEqual(machine.phase, .inserted(.handoffWithoutReturn, until: at(21.5)))
        }

        // The confirmed field still gets return.
        var matched = readyMachine()
        let auto = matched.handle(
            .handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(fieldA, before: "Hi")),
            now: at(12)
        )
        TestSupport.expectEqual(insertions(auto), [TranscriptRouting.insertionText(for: "On my way.", precedingText: "Hi"), "\n"])
        TestSupport.expectEqual(matched.phase, .inserted(.handoff, until: at(13.5)))
    }

    private static func testUnconfirmedFieldWithNothingToInsertShowsNoCTA() {
        // Only "press enter", or nothing at all, in a field the keyboard
        // can't confirm: nothing to insert, and no CTA that would only press
        // return or do nothing.
        let enterOnly = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "", pressEnter: true)
        let blank = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: " ", pressEnter: false)
        let cases: [(PendingDictation, KeyboardDictationMachine.NothingReason)] = [
            (enterOnly, .returnNotPressed),
            (blank, .emptyTranscript),
        ]
        for (pending, reason) in cases {
            for (expected, current) in [(fieldA, fieldB), (nil, fieldA)] as [(UUID?, UUID?)] {
                var machine = readyMachine()
                _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
                let effects = machine.handle(
                    .handoffResultArrived(pending, expectedDocumentID: expected, document: document(current)),
                    now: at(11)
                )
                TestSupport.expectEqual(effects, [.stopAwaitingApp(sessionID: sessionOne), .announce(KeyboardDictationDisplay.nothingText(for: reason))])
                TestSupport.expectEqual(
                    machine.phase,
                    .nothingToInsert(reason, until: at(11) + KeyboardDictationMachine.nothingToInsertDisplayDuration)
                )
                TestSupport.expect(!KeyboardDictationDisplay(machine: machine).pendingInsertVisible, "Nothing to insert must not offer the CTA")
            }
        }
        TestSupport.expectEqual(
            KeyboardDictationDisplay.nothingText(for: .returnNotPressed),
            "Return wasn't pressed, since this may be a different field."
        )
    }

    private static func testHeldHandoffResultSurvivesForInsertLast() {
        // Keep History off, so the app wrote no history entry: the text held
        // in pending-insert must still reach Insert last after Dismiss, after
        // it expires, or after a new dictation.
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "Running late.", pressEnter: false)
        var machine = readyMachine()
        let arrival = machine.handle(
            .handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(fieldB)),
            now: at(12)
        )
        let kept = remembered(arrival)
        TestSupport.expectEqual(kept, KeyboardRememberedText(text: "Running late.", savedAt: at(12)))
        let lastText = KeyboardInsertLast.text(remembered: kept, history: [])
        TestSupport.expectEqual(lastText, "Running late.")

        var dismissed = machine
        TestSupport.expectEqual(dismissed.handle(.cancelTapped, now: at(20)), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(
            insertions(dismissed.handle(.insertLastTapped(text: lastText, document: document(fieldB, before: "Hi")), now: at(21))),
            [TranscriptRouting.insertionText(for: "Running late.", precedingText: "Hi")]
        )

        var expired = machine
        _ = expired.handle(.tick, now: at(10) + PendingDictation.maxAge)
        TestSupport.expectEqual(expired.phase, .idle)
        TestSupport.expectEqual(
            insertions(expired.handle(.insertLastTapped(text: lastText, document: document(fieldB, before: "Hi")), now: at(300))),
            [TranscriptRouting.insertionText(for: "Running late.", precedingText: "Hi")]
        )

        var redictated = machine
        TestSupport.expectEqual(
            redictated.handle(.micPressBegan(documentID: fieldB), now: at(20)),
            [.stopAwaitingApp(sessionID: sessionOne), .startCapture]
        )

        // Insert last from the offer lets go of the store's copy too.
        var insertedLastInstead = machine
        let insteadEffects = insertedLastInstead.handle(
            .insertLastTapped(text: lastText, document: document(fieldB, before: "Hi")),
            now: at(20)
        )
        TestSupport.expectEqual(insteadEffects.first, .stopAwaitingApp(sessionID: sessionOne))
        TestSupport.expectEqual(status(redictated), .starting)
    }

    private static func testPendingInsertExpiresAndDismisses() {
        func waiting() -> KeyboardDictationMachine {
            var machine = readyMachine()
            let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "Held.", pressEnter: false)
            _ = machine.handle(
                .handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(fieldB)),
                now: at(12)
            )
            return machine
        }
        let deadline = at(10) + PendingDictation.maxAge

        // Expires on a tick at its freshness deadline.
        var expiring = waiting()
        TestSupport.expectEqual(expiring.handle(.tick, now: deadline.addingTimeInterval(-1)), [])
        TestSupport.expectEqual(status(expiring), .pendingInsert)
        TestSupport.expectEqual(expiring.handle(.tick, now: deadline), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(expiring.phase, .idle)

        // Expires silently on reappearance if the deadline passed while hidden.
        var reappearing = waiting()
        _ = reappearing.handle(.disappeared, now: at(13))
        TestSupport.expectEqual(
            reappearing.handle(.appeared, now: deadline.addingTimeInterval(1)),
            [.stopAwaitingApp(sessionID: sessionOne)]
        )
        TestSupport.expectEqual(reappearing.phase, .idle)

        // A tap after expiry inserts nothing and returns to rest.
        var tappedLate = waiting()
        TestSupport.expectEqual(
            tappedLate.handle(.insertPendingTapped(document: document(fieldB)), now: deadline.addingTimeInterval(5)),
            [.stopAwaitingApp(sessionID: sessionOne)]
        )
        TestSupport.expectEqual(tappedLate.phase, .idle)

        // Dismiss drops the CTA; the result was remembered for Insert last
        // when it arrived (testHeldHandoffResultSurvivesForInsertLast).
        var dismissed = waiting()
        TestSupport.expectEqual(dismissed.handle(.cancelTapped, now: at(20)), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(dismissed.phase, .idle)

        // A mic press starts a new dictation from pending-insert.
        var redictates = waiting()
        TestSupport.expectEqual(
            redictates.handle(.micPressBegan(documentID: fieldB), now: at(20)),
            [.stopAwaitingApp(sessionID: sessionOne), .startCapture]
        )

        // Showing the offer again keeps it, and keeps the result in the store.
        var shownAgain = waiting()
        TestSupport.expectEqual(shownAgain.handle(.appeared, now: at(30)), [])
        TestSupport.expectEqual(status(shownAgain), .pendingInsert)
        TestSupport.expectEqual(status(redictates), .starting)

        // Still awaited with nothing stored, the offer stays: it holds the text.
        var held = waiting()
        TestSupport.expectEqual(held.handle(.handoffPending(sessionID: sessionOne, openedAt: at(1)), now: at(20)), [])
        TestSupport.expectEqual(status(held), .pendingInsert)

        // Another session awaited: another keyboard used this offer's session
        // or let it go, and opened FreeFlow again. The offer ends, and this
        // keyboard waits for the newer session as an idle one would, or lets
        // go of it if it ended long ago.
        var superseded = waiting()
        TestSupport.expectEqual(superseded.handle(.handoffPending(sessionID: sessionTwo, openedAt: at(15)), now: at(20)), [])
        TestSupport.expectEqual(superseded.phase, .waitingForApp(sessionID: sessionTwo, since: at(15), nextCheck: at(21)))
        var supersededLongAgo = waiting()
        let longAgo = at(20) - KeyboardDictationMachine.handoffWaitLimit
        TestSupport.expectEqual(
            supersededLongAgo.handle(.handoffPending(sessionID: sessionTwo, openedAt: longAgo), now: at(20)),
            [.stopAwaitingApp(sessionID: sessionTwo)]
        )
        TestSupport.expectEqual(supersededLongAgo.phase, .idle)

        // insertPendingTapped does nothing outside pending-insert.
        var idle = readyMachine()
        TestSupport.expectEqual(idle.handle(.insertPendingTapped(document: document()), now: at(1)), [])
    }

    private static func testOfferLetsGoOnceSeenAndLeft() {
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "Held.", pressEnter: false)
        let arrival = KeyboardDictationEvent.handoffResultArrived(pending, expectedDocumentID: fieldA, document: document(fieldB))
        let letGo = KeyboardDictationEffect.stopAwaitingApp(sessionID: sessionOne)
        let grace = KeyboardDictationMachine.offerReleaseGrace
        func offering() -> KeyboardDictationMachine {
            var machine = readyMachine()
            _ = machine.handle(arrival, now: at(12))
            return machine
        }

        // Safari showed the keyboard for an instant on return and dropped it
        // (CI, 2026-11-21): an offer hidden within the grace keeps its result
        // in the store, so the next keyboard, maybe in a new process, offers
        // it again.
        var flashed = offering()
        TestSupport.expectEqual(flashed.handle(.disappeared, now: at(12) + grace - 0.1), [])
        TestSupport.expectEqual(status(flashed), .pendingInsert)

        // Shown again, the check finds the same result, which keeps the offer
        // without letting go of it. Seen for the grace and then left, the
        // offer ends and its result leaves the store; Insert last has it.
        TestSupport.expectEqual(flashed.handle(.appeared, now: at(20)), [])
        TestSupport.expectEqual(
            flashed.handle(arrival, now: at(20)),
            [.rememberForInsertLast(text: "Held.", at: at(20)), .announce(KeyboardDictationDisplay.pendingInsertText)]
        )
        TestSupport.expectEqual(flashed.handle(.disappeared, now: at(20) + grace), [letGo])
        TestSupport.expectEqual(flashed.phase, .idle)
        TestSupport.expectEqual(flashed.handle(.appeared, now: at(30)), [])
        TestSupport.expectEqual(flashed.phase, .idle)

        // The grace counts from when the offer shows, not from its arrival.
        var arrivedHidden = readyMachine()
        _ = arrivedHidden.handle(.disappeared, now: at(11))
        _ = arrivedHidden.handle(arrival, now: at(12))
        TestSupport.expectEqual(arrivedHidden.handle(.appeared, now: at(30)), [])
        TestSupport.expectEqual(arrivedHidden.handle(.disappeared, now: at(31)), [])
        TestSupport.expectEqual(status(arrivedHidden), .pendingInsert)
        // Shown again with no new check, it counts from that appearance.
        TestSupport.expectEqual(arrivedHidden.handle(.appeared, now: at(40)), [])
        TestSupport.expectEqual(arrivedHidden.handle(.disappeared, now: at(40) + grace), [letGo])
        TestSupport.expectEqual(arrivedHidden.phase, .idle)

        // A press that can't record keeps the offer, as it keeps a wait for
        // the app, and only says why.
        var blocked = offering()
        let lowMemory = KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: 1024)
        _ = blocked.handle(.setupChanged(lowMemory), now: at(13))
        TestSupport.expectEqual(
            blocked.handle(.micPressBegan(documentID: fieldB), now: at(13)),
            [.announce("Not enough memory to record here. Record in FreeFlow instead.")]
        )
        _ = blocked.handle(.setupChanged(noAPIKey), now: at(14))
        TestSupport.expectEqual(
            blocked.handle(.micPressBegan(documentID: fieldB), now: at(14)),
            [.announce("Open FreeFlow to add your API key")]
        )
        TestSupport.expectEqual(status(blocked), .pendingInsert)
        TestSupport.expectEqual(blocked.attempt, 0)
        _ = blocked.handle(.setupChanged(ready), now: at(15))
        let tapped = blocked.handle(.insertPendingTapped(document: document(fieldB, before: nil)), now: at(15))
        TestSupport.expectEqual(insertions(tapped), [TranscriptRouting.insertionText(for: "Held.", precedingText: nil)])
        TestSupport.expectEqual(tapped.first, letGo)

        // Nothing awaited any more: another keyboard used the result or let
        // it go, so this offer ends too, and hiding the keyboard afterwards
        // has nothing to let go of.
        var usedElsewhere = offering()
        TestSupport.expectEqual(usedElsewhere.handle(.handoffAbsent, now: at(20)), [])
        TestSupport.expectEqual(usedElsewhere.phase, .idle)
        TestSupport.expectEqual(usedElsewhere.handle(.disappeared, now: at(30)), [])
    }

    private static func testHandoffWaitEnds() {
        var machine = readyMachine()
        _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        TestSupport.expectEqual(status(machine), .waitingForApp)

        var cancelled = machine
        TestSupport.expectEqual(cancelled.handle(.cancelTapped, now: at(1)), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(cancelled.phase, .idle)

        var forgotten = machine
        TestSupport.expectEqual(forgotten.handle(.handoffAbsent, now: at(1)), [])
        TestSupport.expectEqual(forgotten.phase, .idle)

        var replaced = machine
        TestSupport.expectEqual(replaced.handle(.micPressBegan(documentID: nil), now: at(1)), [.stopAwaitingApp(sessionID: sessionOne), .startCapture])
        TestSupport.expectEqual(status(replaced), .starting)

        var insertedLast = machine
        let effects = insertedLast.handle(.insertLastTapped(text: "Kept.", document: document()), now: at(1))
        TestSupport.expectEqual(effects.first, .stopAwaitingApp(sessionID: sessionOne))
        TestSupport.expectEqual(status(insertedLast), .inserted)

        // After the app recorder's longest run plus time to transcribe, give up.
        TestSupport.expectEqual(KeyboardDictationMachine.handoffWaitLimit, 420)
        TestSupport.expect(
            KeyboardDictationMachine.handoffWaitLimit > KeyboardDictationMachine.maximumRecordingDuration,
            "The wait must cover a full-length recording in the app"
        )
        var expired = machine
        TestSupport.expectEqual(expired.handle(.tick, now: at(419.5)), [.checkForAppResult])
        TestSupport.expectEqual(expired.handle(.tick, now: at(420)), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(expired.phase, .idle)

        // A different session found in the store replaces the one waited on.
        var other = machine
        _ = other.handle(.handoffPending(sessionID: sessionTwo, openedAt: nil), now: at(5))
        TestSupport.expectEqual(other.phase, .waitingForApp(sessionID: sessionTwo, since: at(5), nextCheck: at(6)))
    }

    private static func testBlockedPressesKeepWaitingForTheApp() {
        var machine = readyMachine()
        _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: nil), now: at(0))
        let waiting = machine.phase

        let lowMemory = KeyboardDictationSetup(hasFullAccess: true, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: 1024)
        _ = machine.handle(.setupChanged(lowMemory), now: at(1))
        TestSupport.expectEqual(machine.phase, waiting)
        TestSupport.expectEqual(
            machine.handle(.micPressBegan(documentID: nil), now: at(1)),
            [.announce("Not enough memory to record here. Record in FreeFlow instead.")]
        )
        TestSupport.expectEqual(machine.phase, waiting)

        _ = machine.handle(.setupChanged(noAPIKey), now: at(2))
        TestSupport.expectEqual(
            machine.handle(.micPressBegan(documentID: nil), now: at(2)),
            [.announce("Open FreeFlow to add your API key")]
        )
        TestSupport.expectEqual(machine.phase, waiting)
        TestSupport.expectEqual(machine.attempt, 0)

        _ = machine.handle(.setupChanged(ready), now: at(3))
        TestSupport.expectEqual(machine.handle(.micPressBegan(documentID: nil), now: at(3)), [.stopAwaitingApp(sessionID: sessionOne), .startCapture])
        TestSupport.expectEqual(status(machine), .starting)
    }

    private static func testHandoffAdoptionCountsFromTheOpenTime() {
        var adopted = readyMachine()
        TestSupport.expectEqual(adopted.handle(.handoffPending(sessionID: sessionOne, openedAt: at(100)), now: at(150)), [])
        TestSupport.expectEqual(adopted.phase, .waitingForApp(sessionID: sessionOne, since: at(100), nextCheck: at(151)))
        TestSupport.expectEqual(adopted.nextWakeUp, at(151))
        _ = adopted.handle(.disappeared, now: at(152))
        TestSupport.expectEqual(adopted.nextWakeUp, at(520))

        var nearlyOver = readyMachine()
        _ = nearlyOver.handle(.handoffPending(sessionID: sessionOne, openedAt: at(0)), now: at(419.5))
        TestSupport.expectEqual(status(nearlyOver), .waitingForApp)

        // A session opened longer ago than the wait limit has ended.
        var ended = readyMachine()
        TestSupport.expectEqual(ended.handle(.handoffPending(sessionID: sessionOne, openedAt: at(0)), now: at(420)), [.stopAwaitingApp(sessionID: sessionOne)])
        TestSupport.expectEqual(ended.phase, .idle)

        var endedWhileShowingAnother = readyMachine()
        _ = endedWhileShowingAnother.handle(.handoffPending(sessionID: sessionTwo, openedAt: nil), now: at(500))
        TestSupport.expectEqual(
            endedWhileShowingAnother.handle(.handoffPending(sessionID: sessionOne, openedAt: at(0)), now: at(501)),
            [.stopAwaitingApp(sessionID: sessionOne)]
        )
        TestSupport.expectEqual(endedWhileShowingAnother.phase, .idle)
    }

    private static func testInsertLastPrefersTheNewestSource() {
        let older = HistoryEntry(
            createdAt: at(10),
            source: .app,
            status: .handedOff,
            rawTranscript: "from history",
            text: "From history.",
            durationSeconds: 1
        )
        let failed = HistoryEntry(
            createdAt: at(30),
            source: .keyboard,
            status: .failed,
            rawTranscript: "",
            text: "",
            errorMessage: "Synthetic failure",
            durationSeconds: 1
        )
        let newer = HistoryEntry(
            createdAt: at(40),
            source: .app,
            status: .handedOff,
            rawTranscript: "newer from the app",
            text: "Newer from the app.",
            durationSeconds: 1
        )
        let remembered = KeyboardRememberedText(text: "Remembered.", savedAt: at(20))

        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: nil, history: []), nil)
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: remembered, history: []), "Remembered.")
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: nil, history: [failed, older]), "From history.")
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: remembered, history: [failed, older]), "Remembered.")
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: remembered, history: [newer, failed, older]), "Newer from the app.")
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: nil, history: [older, newer]), "Newer from the app.")
        TestSupport.expectEqual(KeyboardInsertLast.text(remembered: nil, history: [failed]), nil)
    }

    private static func testRememberedTextCoversHistoryOff() {
        // With Keep History off nothing new reaches history, so Insert last
        // must still find the dictation that couldn't be inserted.
        let audio = sampleAudio()
        var machine = processingMachine(audio, documentID: fieldA)
        let effects = machine.handle(.pipelineFinished(attempt: 1, result: result("Lost field."), document: document(fieldB)), now: at(4))
        var remembered: KeyboardRememberedText?
        for effect in effects {
            if case .rememberForInsertLast(let text, let time) = effect {
                remembered = KeyboardRememberedText(text: text, savedAt: time)
            }
        }
        TestSupport.expectEqual(remembered, KeyboardRememberedText(text: "Lost field.", savedAt: at(4)))

        let fromBeforeHistoryWasOff = HistoryEntry(
            createdAt: at(1),
            source: .keyboard,
            status: .inserted,
            rawTranscript: "older words",
            text: "Older words.",
            durationSeconds: 1
        )
        let text = KeyboardInsertLast.text(remembered: remembered, history: [fromBeforeHistoryWasOff])
        TestSupport.expectEqual(text, "Lost field.")

        let inserted = machine.handle(.insertLastTapped(text: text, document: document(fieldB, before: "Hi")), now: at(5))
        TestSupport.expectEqual(insertions(inserted), [TranscriptRouting.insertionText(for: "Lost field.", precedingText: "Hi")])
    }

    private static func testHandoffLedger() {
        let suite = "FreeFlowTests.IOSKeyboardCore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestSupport.expect(false, "A test defaults suite must open")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let ledger = KeyboardHandoffLedger(defaults: defaults)
        TestSupport.expect(ledger.openedAt(sessionID: sessionOne) == nil, "Nothing is recorded at first")
        TestSupport.expect(ledger.documentID(sessionID: sessionOne) == nil, "No field is recorded at first")

        ledger.recordOpen(sessionID: sessionOne, documentID: fieldA, at: at(42))
        TestSupport.expectEqual(ledger.openedAt(sessionID: sessionOne), at(42))
        TestSupport.expectEqual(ledger.documentID(sessionID: sessionOne), fieldA)
        TestSupport.expect(ledger.openedAt(sessionID: sessionTwo) == nil, "Another session has no open time")
        TestSupport.expect(ledger.documentID(sessionID: sessionTwo) == nil, "Another session has no field")

        // A later open with an unknown field clears the stored field.
        ledger.recordOpen(sessionID: sessionTwo, documentID: nil, at: at(50))
        TestSupport.expect(ledger.openedAt(sessionID: sessionOne) == nil, "Only the latest session is kept")
        TestSupport.expectEqual(ledger.openedAt(sessionID: sessionTwo), at(50))
        TestSupport.expect(ledger.documentID(sessionID: sessionTwo) == nil, "An unknown field reads back as nil")

        let reopened = KeyboardHandoffLedger(defaults: defaults)
        TestSupport.expectEqual(reopened.openedAt(sessionID: sessionTwo), at(50))

        // Opening again for the same session from the same field keeps the
        // field and renews the open time.
        ledger.recordOpen(sessionID: sessionThree, documentID: fieldA, at: at(60))
        ledger.recordOpen(sessionID: sessionThree, documentID: fieldA, at: at(70))
        TestSupport.expectEqual(ledger.documentID(sessionID: sessionThree), fieldA)
        TestSupport.expectEqual(ledger.openedAt(sessionID: sessionThree), at(70))

        // From another field, the session can't be tied to either field, and
        // it stays untied back in the first one.
        ledger.recordOpen(sessionID: sessionThree, documentID: fieldB, at: at(80))
        TestSupport.expect(ledger.documentID(sessionID: sessionThree) == nil, "A session opened from two fields has no field")
        TestSupport.expectEqual(ledger.openedAt(sessionID: sessionThree), at(80))
        ledger.recordOpen(sessionID: sessionThree, documentID: fieldA, at: at(90))
        TestSupport.expect(ledger.documentID(sessionID: sessionThree) == nil, "Back in the first field it stays untied")

        // A second open from an unknown field unties it too.
        ledger.recordOpen(sessionID: sessionOne, documentID: fieldA, at: at(100))
        ledger.recordOpen(sessionID: sessionOne, documentID: nil, at: at(110))
        TestSupport.expect(ledger.documentID(sessionID: sessionOne) == nil, "An unknown second field unties it")

        // A new session starts with its own field.
        ledger.recordOpen(sessionID: sessionTwo, documentID: fieldB, at: at(120))
        TestSupport.expectEqual(ledger.documentID(sessionID: sessionTwo), fieldB)
    }

    private static func testReopeningFromAnotherFieldNeverAutoInserts() {
        // Opened from field A, then again for the same session from field B
        // while FreeFlow was still processing, so nothing new was recorded:
        // the result can't be tied to either field, so neither gets it
        // inserted, or return pressed, on its own. Insert from FreeFlow
        // offers it in both.
        let suite = "FreeFlowTests.IOSKeyboardCore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestSupport.expect(false, "A test defaults suite must open")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = KeyboardHandoffLedger(defaults: defaults)
        ledger.recordOpen(sessionID: sessionOne, documentID: fieldA, at: at(0))
        ledger.recordOpen(sessionID: sessionOne, documentID: fieldB, at: at(15))

        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(18), text: "Running late.", pressEnter: true)
        for field in [fieldA, fieldB] {
            let store = SyntheticHandoffStore(awaited: sessionOne, take: .fresh(pending))
            let event = KeyboardHandoffCheck.check(store, ledger: ledger, now: at(20), document: document(field))
            TestSupport.expectEqual(event, .handoffResultArrived(pending, expectedDocumentID: nil, document: document(field)))
            var machine = readyMachine()
            let effects = machine.handle(event, now: at(20))
            TestSupport.expectEqual(insertions(effects), [])
            TestSupport.expectEqual(status(machine), .pendingInsert)
        }
    }

    private static func testHandoffCheckReadsTheStore() {
        // KeyboardViewController sends whatever `check` returns when it
        // appears and while it waits, and runs `stopAwaiting` for
        // `.stopAwaitingApp(sessionID:)`.
        let suite = "FreeFlowTests.IOSKeyboardCore.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            TestSupport.expect(false, "A test defaults suite must open")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = KeyboardHandoffLedger(defaults: defaults)
        ledger.recordOpen(sessionID: sessionOne, documentID: fieldA, at: at(5))
        let here = document(fieldA, before: "Hi")
        let pending = PendingDictation(sessionID: sessionOne, createdAt: at(10), text: "From the app.", pressEnter: true)
        var documentReads = 0
        func currentDocument() -> KeyboardDictationDocument {
            documentReads += 1
            return here
        }

        // Nothing awaited, with a fresh result: it stays, since the check
        // never deletes dictation text on one cross-process read that nobody
        // wants it (KeyboardHandoffCheck). It goes once expired, below.
        let unawaitedFresh = SyntheticHandoffStore(awaited: nil, take: .fresh(pending))
        let freshCheck = KeyboardHandoffCheck.checkAndReport(
            unawaitedFresh, ledger: ledger, now: at(12), document: currentDocument()
        )
        TestSupport.expectEqual(freshCheck.event, .handoffAbsent)
        TestSupport.expectEqual(unawaitedFresh.discards, 0)
        TestSupport.expectEqual(unawaitedFresh.reads, [])
        TestSupport.expectEqual(freshCheck.report, KeyboardHandoffCheckReport(
            outcome: .absent,
            awaitedSession: nil,
            stored: "a result for \(KeyboardHandoffCheck.shortID(sessionOne)), under 10 s old",
            removedResult: false
        ))

        // Nothing awaited, with an expired or unreadable result: nobody can
        // ever insert it, so it goes instead of keeping its text in the App
        // Group.
        let late = at(10) + PendingDictation.maxAge + 1
        let unawaitedExpired = SyntheticHandoffStore(awaited: nil, take: .fresh(pending))
        let expiredCheck = KeyboardHandoffCheck.checkAndReport(
            unawaitedExpired, ledger: ledger, now: late, document: currentDocument()
        )
        TestSupport.expectEqual(expiredCheck.event, .handoffAbsent)
        TestSupport.expectEqual(unawaitedExpired.discards, 1)
        TestSupport.expect(expiredCheck.report.removedResult, "The report says the expired result was removed")
        TestSupport.expectEqual(expiredCheck.report.summary, "absent (awaited none; stored a result for \(KeyboardHandoffCheck.shortID(sessionOne)), expired; removed it)")
        let unreadable = SyntheticHandoffStore(awaited: nil, take: PendingDictationTake.none, stored: .unreadable)
        TestSupport.expectEqual(
            KeyboardHandoffCheck.check(unreadable, ledger: ledger, now: at(12), document: currentDocument()),
            .handoffAbsent
        )
        TestSupport.expectEqual(unreadable.discards, 1)
        TestSupport.expectEqual(documentReads, 0)

        // Awaited, nothing yet: keep waiting, from when this keyboard opened the app.
        let waiting = SyntheticHandoffStore(awaited: sessionOne, take: PendingDictationTake.none)
        TestSupport.expectEqual(
            KeyboardHandoffCheck.check(waiting, ledger: ledger, now: at(12), document: currentDocument()),
            .handoffPending(sessionID: sessionOne, openedAt: at(5))
        )
        TestSupport.expectEqual(waiting.reads, [sessionOne])
        TestSupport.expectEqual(waiting.discards, 0)
        TestSupport.expectEqual(documentReads, 0)

        // A fresh result and an expired one both reach the machine, with the
        // field the app was opened from; an expired one is never "pending".
        // The check leaves the result in the store: the machine lets go of it
        // once it has used it, so a keyboard stopped in between loses nothing.
        let arrivals: [(PendingDictationTake, KeyboardHandoffCheckReport.Outcome)] = [
            (.fresh(pending), .arrived),
            (.expired(pending), .expired),
        ]
        for (taken, outcome) in arrivals {
            let store = SyntheticHandoffStore(awaited: sessionOne, take: taken)
            let checked = KeyboardHandoffCheck.checkAndReport(store, ledger: ledger, now: at(12), document: currentDocument())
            TestSupport.expectEqual(checked.event, .handoffResultArrived(pending, expectedDocumentID: fieldA, document: here))
            TestSupport.expectEqual(checked.report.outcome, outcome)
            TestSupport.expectEqual(checked.report.stored, "a result for it, under 10 s old")
            TestSupport.expect(!checked.report.removedResult, "The check never removes the result it hands over")
            TestSupport.expectEqual(store.discards, 0)
            TestSupport.expectEqual(store.peekResult(), .stored(sessionID: sessionOne, createdAt: at(10)))
        }
        TestSupport.expectEqual(documentReads, 2)

        // Awaited, with only another session's stale result stored: still
        // pending, and the report says the read dropped the stale one.
        let staleOther = SyntheticHandoffStore(
            awaited: sessionOne,
            take: PendingDictationTake.none,
            stored: .stored(sessionID: sessionThree, createdAt: at(0))
        )
        let staleCheck = KeyboardHandoffCheck.checkAndReport(staleOther, ledger: ledger, now: late, document: currentDocument())
        TestSupport.expectEqual(staleCheck.event, .handoffPending(sessionID: sessionOne, openedAt: at(5)))
        TestSupport.expectEqual(
            staleCheck.report.summary,
            "pending (awaited \(KeyboardHandoffCheck.shortID(sessionOne)); stored a result for \(KeyboardHandoffCheck.shortID(sessionThree)), expired; removed it)"
        )
        TestSupport.expectEqual(KeyboardHandoffCheck.shortID(sessionThree), "7A1E0000")

        // A session another keyboard process opened: no open time or field.
        let elsewhere = SyntheticHandoffStore(awaited: sessionTwo, take: PendingDictationTake.none)
        TestSupport.expectEqual(
            KeyboardHandoffCheck.check(elsewhere, ledger: ledger, now: at(12), document: currentDocument()),
            .handoffPending(sessionID: sessionTwo, openedAt: nil)
        )

        // Stopping the wait forgets the session and drops its result.
        let stopping = SyntheticHandoffStore(awaited: sessionOne, take: .fresh(pending))
        TestSupport.expect(KeyboardHandoffCheck.stopAwaiting(stopping, sessionID: sessionOne, now: at(12)), "Its own result goes")
        TestSupport.expect(stopping.awaitedSessionID == nil, "Nothing is awaited after stopping")
        TestSupport.expectEqual(stopping.discards, 1)

        // The machine names its session, so its own result goes even if the
        // store reads as awaiting nothing.
        let unawaitedOwn = SyntheticHandoffStore(awaited: nil, take: .fresh(pending))
        TestSupport.expect(KeyboardHandoffCheck.stopAwaiting(unawaitedOwn, sessionID: sessionOne, now: at(12)), "Its own result goes")
        TestSupport.expectEqual(unawaitedOwn.discards, 1)

        // A fresh result for another session stays for the keyboard that
        // awaits it; the app may be writing it now.
        let otherResult = PendingDictation(sessionID: sessionThree, createdAt: at(10), text: "Elsewhere.", pressEnter: false)
        let stoppingOther = SyntheticHandoffStore(awaited: sessionOne, take: .fresh(otherResult))
        TestSupport.expect(!KeyboardHandoffCheck.stopAwaiting(stoppingOther, sessionID: sessionOne, now: at(12)), "Another session's result stays")
        TestSupport.expect(stoppingOther.awaitedSessionID == nil, "Nothing is awaited after stopping")
        TestSupport.expectEqual(stoppingOther.discards, 0)

        // A newer wait, from another keyboard process, stays with its result.
        let newerWait = SyntheticHandoffStore(awaited: sessionThree, take: .fresh(otherResult))
        TestSupport.expect(!KeyboardHandoffCheck.stopAwaiting(newerWait, sessionID: sessionOne, now: at(12)), "The newer wait's result stays")
        TestSupport.expectEqual(newerWait.awaitedSessionID, sessionThree)
        TestSupport.expectEqual(newerWait.discards, 0)

        // Once expired, another session's result goes too.
        let stoppingExpired = SyntheticHandoffStore(awaited: sessionOne, take: .fresh(otherResult))
        TestSupport.expect(KeyboardHandoffCheck.stopAwaiting(stoppingExpired, sessionID: sessionOne, now: late), "A stale result goes")
        TestSupport.expectEqual(stoppingExpired.discards, 1)

        // The check's report for an awaited session with nothing yet.
        let waitingCheck = KeyboardHandoffCheck.checkAndReport(
            SyntheticHandoffStore(awaited: sessionOne, take: PendingDictationTake.none),
            ledger: ledger, now: at(12), document: currentDocument()
        )
        TestSupport.expectEqual(waitingCheck.report.summary, "pending (awaited \(KeyboardHandoffCheck.shortID(sessionOne)); stored nothing)")
        TestSupport.expectEqual(KeyboardHandoffCheck.shortID(sessionOne).count, 8)

        // What the keyboard then shows: an expired result ends the wait at
        // once, and nothing awaited returns it to rest.
        var machine = readyMachine()
        _ = machine.handle(.handoffPending(sessionID: sessionOne, openedAt: at(5)), now: at(5))
        let expired = SyntheticHandoffStore(awaited: sessionOne, take: .expired(pending))
        _ = machine.handle(KeyboardHandoffCheck.check(expired, ledger: ledger, now: late, document: currentDocument()), now: late)
        TestSupport.expect(!machine.isWaitingForApp, "An expired result must end the wait")
        TestSupport.expectEqual(status(machine), .error)

        var forgotten = readyMachine()
        _ = forgotten.handle(.handoffPending(sessionID: sessionOne, openedAt: at(5)), now: at(5))
        let cleared = SyntheticHandoffStore(awaited: nil, take: PendingDictationTake.none)
        _ = forgotten.handle(KeyboardHandoffCheck.check(cleared, ledger: ledger, now: at(6), document: currentDocument()), now: at(6))
        TestSupport.expectEqual(forgotten.phase, .idle)
    }

    // MARK: Lifecycle and feedback

    private static func testDisappearingCancelsCapture() {
        var starting = readyMachine()
        _ = starting.handle(.micPressBegan(documentID: nil), now: at(0))
        TestSupport.expectEqual(starting.handle(.disappeared, now: at(0.5)), [.cancelCapture])
        TestSupport.expectEqual(starting.phase, .idle)
        TestSupport.expect(!starting.isVisible, "The machine must know the keyboard is hidden")

        var recording = recordingMachine()
        TestSupport.expectEqual(recording.handle(.disappeared, now: at(2)), [.cancelCapture])
        TestSupport.expectEqual(recording.phase, .idle)

        var stopping = recordingMachine()
        _ = stopping.handle(.doneTapped, now: at(2))
        TestSupport.expectEqual(stopping.handle(.disappeared, now: at(2.25)), [.cancelCapture])
        TestSupport.expectEqual(stopping.phase, .idle)

        var idle = readyMachine()
        TestSupport.expectEqual(idle.handle(.disappeared, now: t0), [])
        TestSupport.expectEqual(idle.phase, .idle)
    }

    private static func testHapticsNeedFullAccess() {
        var machine = recordingMachine()
        let lostAccess = KeyboardDictationSetup(hasFullAccess: false, microphoneGranted: true, hasAPIKey: true, availableMemoryBytes: nil)
        _ = machine.handle(.setupChanged(lostAccess), now: at(1))
        TestSupport.expectEqual(machine.handle(.doneTapped, now: at(2)), [.stopCapture])
    }

    // MARK: Display

    private static func testDisplayForEveryPhase() {
        let recording = KeyboardDictationMachine.Recording(attempt: 1, startedAt: t0, audioStartedAt: t0, gesture: .latched, documentID: nil)
        let processing = KeyboardDictationMachine.Processing(attempt: 1, stoppedAt: t0, documentID: nil, heardAudio: true, audio: nil)
        typealias Expectation = (
            phase: KeyboardDictationMachine.Phase,
            status: KeyboardDictationStatus,
            mic: KeyboardDictationDisplay.Mic,
            cancelTitle: String?,
            trailing: KeyboardDictationDisplay.TrailingAction?,
            insertLast: Bool
        )
        let expectations: [Expectation] = [
            (.idle, .idle, .ready, nil, nil, true),
            (.setupNeeded(.apiKey), .setupNeeded, .unavailable, nil, nil, true),
            (.starting(recording), .starting, .starting, "Cancel", .done, false),
            (.recording(recording), .recording, .recording, "Cancel", .done, false),
            (.processing(processing), .processing, .processing, "Cancel", nil, false),
            (.inserted(.dictation, until: t0), .inserted, .ready, nil, nil, true),
            (.nothingToInsert(.noAudio, until: t0), .nothingToInsert, .ready, nil, nil, true),
            (.error(message: "Synthetic failure", until: t0), .error, .ready, nil, nil, true),
            (.fallbackAvailable(.captureUnavailable), .fallbackAvailable, .ready, "Not now", .openApp, true),
            (.waitingForApp(sessionID: sessionOne, since: t0, nextCheck: t0), .waitingForApp, .ready, "Stop waiting", .openApp, true),
            (.pendingInsert(samplePending, until: t0), .pendingInsert, .ready, "Dismiss", nil, false),
        ]
        for expectation in expectations {
            let display = KeyboardDictationDisplay(machine: KeyboardDictationMachine(phase: expectation.phase))
            TestSupport.expectEqual(display.status, expectation.status)
            TestSupport.expectEqual(display.mic, expectation.mic)
            TestSupport.expectEqual(display.cancelTitle, expectation.cancelTitle)
            TestSupport.expectEqual(display.trailingAction, expectation.trailing)
            TestSupport.expectEqual(display.insertLastEnabled, expectation.insertLast)
            TestSupport.expect(!display.statusText.isEmpty, "Every state needs status text")
            TestSupport.expect(display.statusText.count <= KeyboardDictationMachine.maximumMessageLength, "Status text must fit the status line")
        }
        TestSupport.expectEqual(Set(expectations.map { $0.status }), Set(KeyboardDictationStatus.allCases))

        // The CTA shows only in pending-insert.
        for expectation in expectations {
            let display = KeyboardDictationDisplay(machine: KeyboardDictationMachine(phase: expectation.phase))
            TestSupport.expectEqual(display.pendingInsertVisible, expectation.status == .pendingInsert)
        }

        let error = KeyboardDictationDisplay(machine: KeyboardDictationMachine(phase: .error(message: "Synthetic failure", until: t0)))
        TestSupport.expectEqual(error.statusText, "Synthetic failure")
        let starting = KeyboardDictationDisplay(machine: KeyboardDictationMachine(phase: .starting(recording)))
        TestSupport.expectEqual(starting.micAccessibilityLabel, "Stop dictation")
        TestSupport.expectEqual(KeyboardDictationDisplay(machine: KeyboardDictationMachine()).micAccessibilityLabel, "Dictate")
    }

    private static func testDisplayWording() {
        TestSupport.expectEqual(KeyboardDictationDisplay.idleText, "Tap the mic to dictate, or hold to talk")
        TestSupport.expectEqual(KeyboardDictationDisplay.setupText(for: .microphone), "Open FreeFlow to allow the microphone")
        TestSupport.expectEqual(KeyboardDictationDisplay.openAppTitle, "Open FreeFlow")
        var texts: [String] = []
        texts += KeyboardDictationSetupIssue.allCases.map(KeyboardDictationDisplay.setupText(for:))
        texts += KeyboardDictationMachine.InsertedKind.allCases.map(KeyboardDictationDisplay.insertedText(for:))
        texts += KeyboardDictationMachine.NothingReason.allCases.map(KeyboardDictationDisplay.nothingText(for:))
        texts += KeyboardDictationMachine.FallbackReason.allCases.map(KeyboardDictationDisplay.fallbackText(for:))
        texts += [
            KeyboardDictationMachine.fieldChangedMessage,
            KeyboardDictationMachine.fieldChangedReturnMessage,
            KeyboardDictationMachine.handoffExpiredMessage,
            KeyboardDictationMachine.handoffExpiredEmptyMessage,
            KeyboardDictationMachine.interruptedMessage,
            KeyboardDictationMachine.fileErrorMessage,
            KeyboardDictationMachine.stopTimedOutMessage,
            KeyboardDictationDisplay.waitingForAppText,
            KeyboardDictationDisplay.pendingInsertText,
        ]
        for text in texts {
            TestSupport.expect(!text.isEmpty && text.count <= 90, "'\(text)' must fit the status line")
        }
        TestSupport.expectEqual(Set(texts).count, texts.count)
        TestSupport.expectEqual(KeyboardDictationDisplay.insertPendingTitle, "Insert from FreeFlow")
    }

    private static func testDebugStatesCoverEveryStatus() {
        TestSupport.expectEqual(KeyboardDebugDisplayState.defaultsKey, "ios_debug_keyboard_state")
        for status in KeyboardDictationStatus.allCases {
            guard let machine = KeyboardDebugDisplayState.machine(for: status.rawValue, now: t0) else {
                TestSupport.expect(false, "'\(status.rawValue)' must force a display state")
                return
            }
            TestSupport.expectEqual(KeyboardDictationDisplay(machine: machine).status, status)
        }

        TestSupport.expectEqual(KeyboardDebugDisplayState.machine(for: "setup-needed:microphone", now: t0)?.phase, .setupNeeded(.microphone))
        TestSupport.expectEqual(KeyboardDebugDisplayState.machine(for: "setup-needed", now: t0)?.phase, .setupNeeded(.fullAccess))
        TestSupport.expectEqual(KeyboardDebugDisplayState.machine(for: "recording:hold", now: t0)?.activeRecording?.gesture, .holding)
        TestSupport.expectEqual(KeyboardDebugDisplayState.machine(for: "recording", now: t0)?.activeRecording?.gesture, .latched)
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: " inserted:rawFallback \n", now: t0)?.phase,
            .inserted(.rawFallback, until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "nothing-to-insert:noHistory", now: t0)?.phase,
            .nothingToInsert(.noHistory, until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "inserted:handoffWithoutReturn", now: t0)?.phase,
            .inserted(.handoffWithoutReturn, until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "nothing-to-insert:returnNotPressed", now: t0)?.phase,
            .nothingToInsert(.returnNotPressed, until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "error:Quota: exceeded", now: t0)?.phase,
            .error(message: "Quota: exceeded", until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "error", now: t0)?.phase,
            .error(message: "Request timed out — try again", until: .distantFuture)
        )
        TestSupport.expectEqual(
            KeyboardDebugDisplayState.machine(for: "fallback-available:lowMemory", now: t0)?.phase,
            .fallbackAvailable(.lowMemory)
        )
        TestSupport.expect(KeyboardDebugDisplayState.machine(for: "Recording", now: t0) == nil, "State names are case-sensitive")
        TestSupport.expect(KeyboardDebugDisplayState.machine(for: "", now: t0) == nil, "An empty value forces nothing")
        TestSupport.expect(KeyboardDebugDisplayState.machine(for: "bogus:value", now: t0) == nil, "Unknown names force nothing")
    }

    // MARK: Keys

    private static func testDeleteRepeatTiming() {
        TestSupport.expectEqual(KeyboardDeleteRepeat.initialDelay, 0.5)
        TestSupport.expectEqual(KeyboardDeleteRepeat.repeatInterval, 0.1)
        TestSupport.expectEqual(KeyboardDeleteRepeat.wordDeletionDelay, 2)
        TestSupport.expectEqual(KeyboardDeleteRepeat.unit(afterHolding: 0.6), .character)
        TestSupport.expectEqual(KeyboardDeleteRepeat.unit(afterHolding: 1.99), .character)
        TestSupport.expectEqual(KeyboardDeleteRepeat.unit(afterHolding: 2), .word)
        TestSupport.expectEqual(KeyboardDeleteRepeat.unit(afterHolding: 9), .word)
    }

    private static func testWordDeletionCounts() {
        func count(_ text: String?) -> Int {
            KeyboardDeleteRepeat.deletionCount(for: .word, textBeforeCursor: text)
        }
        TestSupport.expectEqual(count("Hello world"), 5)
        TestSupport.expectEqual(count("Hello world  "), 7)
        TestSupport.expectEqual(count("Hello, world!"), 6)
        TestSupport.expectEqual(count("one"), 3)
        TestSupport.expectEqual(count("   "), 3)
        TestSupport.expectEqual(count("first line\n"), 1)
        TestSupport.expectEqual(count("first line\nsecond"), 6)
        TestSupport.expectEqual(count("tab\tseparated"), 9)
        TestSupport.expectEqual(count("wave 👋🏽"), 1)
        TestSupport.expectEqual(count(""), 1)
        TestSupport.expectEqual(count(nil), 1)
        TestSupport.expectEqual(KeyboardDeleteRepeat.deletionCount(for: .character, textBeforeCursor: "Hello world"), 1)
    }

    private static func testReturnKeyKinds() {
        let expected: [(rawValue: Int, title: String, prominent: Bool)] = [
            (0, "return", false),
            (1, "go", true),
            (2, "search", true),
            (3, "join", true),
            (4, "next", true),
            (5, "route", true),
            (6, "search", true),
            (7, "send", true),
            (8, "search", true),
            (9, "done", true),
            (10, "emergency", true),
            (11, "continue", true),
        ]
        for item in expected {
            let kind = KeyboardReturnKeyKind(returnKeyTypeRawValue: item.rawValue)
            TestSupport.expectEqual(kind.rawValue, item.rawValue)
            TestSupport.expectEqual(kind.title, item.title)
            TestSupport.expectEqual(kind.isProminent, item.prominent)
            TestSupport.expect(!kind.accessibilityLabel.isEmpty, "Every return key needs a spoken label")
        }
        TestSupport.expectEqual(KeyboardReturnKeyKind.allCases.count, expected.count)
        TestSupport.expectEqual(KeyboardReturnKeyKind(returnKeyTypeRawValue: nil), .standard)
        TestSupport.expectEqual(KeyboardReturnKeyKind(returnKeyTypeRawValue: 99), .standard)
        TestSupport.expectEqual(KeyboardReturnKeyKind.send.accessibilityLabel, "Send")
        TestSupport.expectEqual(KeyboardReturnKeyKind.standard.accessibilityLabel, "Return")
    }

    private static func testWaveformShape() {
        TestSupport.expectEqual(KeyboardWaveformShape.barCount, 9)
        TestSupport.expectEqual(KeyboardWaveformShape.multipliers, [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35])
        TestSupport.expectEqual(KeyboardWaveformShape.amplitudes(level: 0, time: nil), Array(repeating: 0, count: 9))
        TestSupport.expectEqual(KeyboardWaveformShape.amplitudes(level: 1, time: nil), KeyboardWaveformShape.multipliers)
        TestSupport.expectEqual(KeyboardWaveformShape.amplitudes(level: 3, time: nil), KeyboardWaveformShape.multipliers)
        TestSupport.expectEqual(KeyboardWaveformShape.amplitudes(level: -1, time: nil), Array(repeating: 0, count: 9))

        let half = KeyboardWaveformShape.amplitudes(level: 0.5, time: nil)
        TestSupport.expectApproximatelyEqual(half[4], 0.5)
        TestSupport.expectApproximatelyEqual(half[0], 0.175)
        TestSupport.expectApproximatelyEqual(half[8], 0.175)

        for time in stride(from: 0.0, through: 2.0, by: 0.1) {
            for level: Float in [0, 0.3, 1] {
                let bars = KeyboardWaveformShape.amplitudes(level: level, time: time)
                TestSupport.expectEqual(bars.count, 9)
                TestSupport.expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 }, "Pulsed bars must stay within 0...1")
            }
        }
        let quiet = KeyboardWaveformShape.amplitudes(level: 0, time: 1)
        TestSupport.expect(quiet.allSatisfy { $0 > 0 && $0 < 0.4 }, "Silence must still pulse gently, as on macOS")
    }

    // MARK: Contracts with the app and UI tests

    private static func testHandoffURL() {
        let session = UUID(uuidString: "12345678-90AB-4CDE-8F01-234567890ABC")!
        let url = KeyboardHandoffURL.dictate(sessionID: session)
        TestSupport.expectEqual(url.absoluteString, "freeflow://dictate?session=12345678-90AB-4CDE-8F01-234567890ABC")
        TestSupport.expectEqual(KeyboardHandoffURL.sessionID(from: url), session)
        TestSupport.expectEqual(
            KeyboardHandoffURL.sessionID(from: URL(string: "freeflow://dictate?session=12345678-90ab-4cde-8f01-234567890abc")!),
            session
        )
        let rejected = [
            "freeflow://settings?session=12345678-90AB-4CDE-8F01-234567890ABC",
            "https://dictate.invalid/?session=12345678-90AB-4CDE-8F01-234567890ABC",
            "freeflow://dictate?session=not-a-uuid",
            "freeflow://dictate",
        ]
        for string in rejected {
            TestSupport.expect(KeyboardHandoffURL.sessionID(from: URL(string: string)!) == nil, "'\(string)' must not parse")
        }
    }

    private static func testAccessibilityIdentifiersAndStatusNames() {
        TestSupport.expectEqual(KeyboardAccessibilityID.mic, "freeflow.keyboard.mic")
        TestSupport.expectEqual(KeyboardAccessibilityID.cancel, "freeflow.keyboard.cancel")
        TestSupport.expectEqual(KeyboardAccessibilityID.done, "freeflow.keyboard.done")
        TestSupport.expectEqual(KeyboardAccessibilityID.globe, "freeflow.keyboard.globe")
        TestSupport.expectEqual(KeyboardAccessibilityID.space, "freeflow.keyboard.space")
        TestSupport.expectEqual(KeyboardAccessibilityID.delete, "freeflow.keyboard.delete")
        TestSupport.expectEqual(KeyboardAccessibilityID.returnKey, "freeflow.keyboard.return")
        TestSupport.expectEqual(KeyboardAccessibilityID.insertLast, "freeflow.keyboard.insertLast")
        TestSupport.expectEqual(KeyboardAccessibilityID.openApp, "freeflow.keyboard.openApp")
        TestSupport.expectEqual(KeyboardAccessibilityID.insertPending, "freeflow.keyboard.insertPending")
        TestSupport.expectEqual(KeyboardAccessibilityID.status, "freeflow.keyboard.status")
        TestSupport.expectEqual(KeyboardDictationStatus.allCases.map(\.rawValue), [
            "idle",
            "setup-needed",
            "starting",
            "recording",
            "processing",
            "inserted",
            "nothing-to-insert",
            "error",
            "fallback-available",
            "waiting-for-app",
            "pending-insert",
        ])
        TestSupport.expectEqual(KeyboardDictationCaptureFailure.startTimedOut.rawValue, "startTimedOut")
    }

    private static func testHistoryDraftMakesKeyboardEntry() {
        let id = UUID(uuidString: "41570000-0000-4000-8000-000000000001")!
        let entry = draft(.rawFallback, at: 4, raw: "raw words", text: "Raw words.").makeEntry(id: id)
        TestSupport.expectEqual(entry, HistoryEntry(
            id: id,
            createdAt: at(4),
            source: .keyboard,
            status: .rawFallback,
            rawTranscript: "raw words",
            text: "Raw words.",
            route: .cleanup,
            errorMessage: nil,
            durationSeconds: 2.5
        ))
        TestSupport.expectEqual(HistoryLog.latestInsertableText(in: [entry]), "Raw words.")

        let notInserted = draft(.notInserted, at: 5, raw: "keep me", text: "Keep me.").makeEntry()
        TestSupport.expectEqual(HistoryLog.latestInsertableText(in: [notInserted]), "Keep me.")
        TestSupport.expectEqual(notInserted.usedRawFallback, nil)
        TestSupport.expect(!notInserted.fellBackToRawTranscript, "A cleaned-up entry is not a raw fallback")

        // The fallback flag reaches History even when the status can't say it.
        let fallbackNotInserted = draft(.notInserted, at: 6, raw: "raw words", text: "raw words", rawFallback: true).makeEntry()
        TestSupport.expectEqual(fallbackNotInserted.usedRawFallback, true)
        TestSupport.expect(fallbackNotInserted.fellBackToRawTranscript, "History must know the text is the raw transcript")
    }
}

/// An in-memory `KeyboardHandoffStore` that answers `result(for:now:)` with
/// a canned result, leaving it in place as the real store does, and records
/// what the keyboard asked of it. What `peekResult` reports follows the
/// canned result unless `stored` says otherwise.
private final class SyntheticHandoffStore: KeyboardHandoffStore {
    var awaitedSessionID: UUID?
    private var nextTake: PendingDictationTake
    private var stored: PendingDictationPeek
    private(set) var reads: [UUID] = []
    private(set) var discards = 0

    init(awaited: UUID?, take: PendingDictationTake, stored: PendingDictationPeek? = nil) {
        awaitedSessionID = awaited
        nextTake = take
        switch take {
        case .fresh(let pending), .expired(let pending):
            self.stored = stored ?? .stored(sessionID: pending.sessionID, createdAt: pending.createdAt)
        case .none:
            self.stored = stored ?? PendingDictationPeek.none
        }
    }

    func result(for sessionID: UUID, now: Date) -> PendingDictationTake {
        reads.append(sessionID)
        return nextTake
    }

    func peekResult() -> PendingDictationPeek {
        stored
    }

    func discardResult() {
        discards += 1
        nextTake = PendingDictationTake.none
        stored = PendingDictationPeek.none
    }
}
