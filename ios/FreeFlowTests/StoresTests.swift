import XCTest
@testable import FreeFlow

/// HistoryStore, PendingDictationStore and KeyboardStatusStore with temporary
/// files and defaults suites, so the real App Group data is never touched.
final class StoresTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - HistoryStore

    func testHistoryAppendsNewestFirstAndKeepsTwenty() throws {
        let (store, _) = try makeHistoryStore()

        for index in 0..<25 {
            store.append(entry(index))
        }
        let entries = store.load()
        XCTAssertEqual(entries.count, HistoryLog.maxEntries)
        XCTAssertEqual(entries.first?.text, "Synthetic text 24.")
        XCTAssertEqual(entries.last?.text, "Synthetic text 5.")

        let fileURL = try XCTUnwrap(store.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reopened = HistoryStore(fileURL: fileURL, settings: try makeSettings())
        XCTAssertEqual(reopened.load(), entries, "History must survive a new process")
    }

    func testHistoryReadsTheOtherProcessesWrites() throws {
        let (app, settings) = try makeHistoryStore()
        let keyboard = HistoryStore(fileURL: app.fileURL, settings: settings)

        app.append(entry(1))
        keyboard.append(entry(2))
        app.append(entry(3))
        XCTAssertEqual(keyboard.load().map(\.text), ["Synthetic text 3.", "Synthetic text 2.", "Synthetic text 1."])
    }

    func testHistoryAppendIsIgnoredWhileKeepHistoryIsOff() throws {
        let (store, settings) = try makeHistoryStore()
        settings.historyEnabled = false

        store.append(entry(1))
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL).path))

        settings.historyEnabled = true
        store.append(entry(2))
        XCTAssertEqual(store.load().map(\.text), ["Synthetic text 2."])
    }

    func testHistoryClearRemovesTheFile() throws {
        let (store, _) = try makeHistoryStore()
        store.append(entry(1))

        store.clear()
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL).path))
        store.clear()
    }

    func testHistoryRecoversFromACorruptFile() throws {
        let (store, _) = try makeHistoryStore()
        let fileURL = try XCTUnwrap(store.fileURL)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(store.load(), [])
        store.append(entry(1))
        XCTAssertEqual(store.load().map(\.text), ["Synthetic text 1."])
    }

    func testHistoryFileIsProtectedUntilFirstUnlock() throws {
        let (store, _) = try makeHistoryStore()
        store.append(entry(1))

        let attributes = try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(store.fileURL).path)
        // The simulator doesn't enforce data protection and may not report it.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }

    func testHistoryLatestInsertableText() throws {
        let (store, _) = try makeHistoryStore()
        XCTAssertNil(store.latestInsertableText())

        store.append(entry(1))
        store.append(HistoryEntry(
            createdAt: start.addingTimeInterval(2),
            source: .keyboard,
            status: .failed,
            rawTranscript: "",
            text: "",
            errorMessage: "Request timed out — try again",
            durationSeconds: 1
        ))
        XCTAssertEqual(store.latestInsertableText(), "Synthetic text 1.")
    }

    func testHistoryWithoutAContainerIsInert() throws {
        let store = HistoryStore(fileURL: nil, settings: try makeSettings())
        store.append(entry(1))
        store.clear()
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(store.latestInsertableText())
    }

    func testSharedHistoryLivesInTheAppGroup() throws {
        let container = try XCTUnwrap(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FreeFlowIdentifiers.appGroupIdentifier)
        )
        let fileURL = try XCTUnwrap(HistoryStore.shared.fileURL)
        XCTAssertTrue(fileURL.standardizedFileURL.path.hasPrefix(container.standardizedFileURL.path))
        XCTAssertEqual(fileURL.lastPathComponent, "history.json")
    }

    // MARK: - PendingDictationStore

    func testPendingResultIsTakenOnce() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        let pending = PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: true)

        store.save(pending)
        XCTAssertNotNil(defaults.data(forKey: "ios_pending_dictation"))
        XCTAssertEqual(store.take(sessionID: session, now: start.addingTimeInterval(10)), .fresh(pending))
        XCTAssertEqual(store.take(sessionID: session, now: start.addingTimeInterval(11)), PendingDictationTake.none)
        XCTAssertNil(defaults.data(forKey: "ios_pending_dictation"))
    }

    func testPendingResultForAnotherSessionIsLeftUntilStale() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let pending = PendingDictation(sessionID: UUID(), createdAt: start, text: "Synthetic handoff.", pressEnter: false)
        store.save(pending)

        XCTAssertEqual(store.take(sessionID: UUID(), now: start.addingTimeInterval(10)), PendingDictationTake.none)
        XCTAssertNotNil(defaults.data(forKey: "ios_pending_dictation"), "A fresh result for another session stays")

        XCTAssertEqual(store.take(sessionID: UUID(), now: start.addingTimeInterval(PendingDictation.maxAge + 1)), PendingDictationTake.none)
        XCTAssertNil(defaults.data(forKey: "ios_pending_dictation"), "A stale result is removed")
    }

    func testStalePendingResultIsReportedAsExpired() throws {
        // Not the same answer as "not delivered yet": the keyboard must stop
        // waiting instead of showing "Waiting for FreeFlow" for minutes.
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        let pending = PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: false)
        store.save(pending)

        XCTAssertEqual(store.take(sessionID: session, now: start.addingTimeInterval(PendingDictation.maxAge + 1)), .expired(pending))
        XCTAssertNil(defaults.data(forKey: "ios_pending_dictation"), "An expired result is removed too")
        XCTAssertEqual(store.take(sessionID: session, now: start.addingTimeInterval(PendingDictation.maxAge + 2)), PendingDictationTake.none)
    }

    func testUnreadablePendingResultIsRemoved() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: "ios_pending_dictation")

        XCTAssertEqual(store.take(sessionID: UUID(), now: start), PendingDictationTake.none)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))
    }

    func testPendingResultReplacesTheEarlierOne() throws {
        let store = PendingDictationStore(defaults: try makeDefaults())
        let session = UUID()
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "First.", pressEnter: false))
        let second = PendingDictation(sessionID: session, createdAt: start.addingTimeInterval(1), text: "Second.", pressEnter: false)
        store.save(second)

        XCTAssertEqual(store.take(sessionID: session, now: start.addingTimeInterval(2)), .fresh(second))
    }

    func testDiscardResultKeepsTheAwaitedSession() throws {
        // Clear History and Keep History off: the text goes, but a handoff
        // that is still recording keeps its session.
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        store.awaitedSessionID = session
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: false))

        store.discardResult()
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))
        XCTAssertEqual(store.awaitedSessionID, session)
        store.discardResult()
    }

    func testDiscardUnclaimedResult() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        let now = start.addingTimeInterval(30)

        // Nothing awaited: nobody can ever take it.
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "Synthetic orphan.", pressEnter: false))
        store.discardUnclaimedResult(now: now)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))

        // Another session awaited.
        store.awaitedSessionID = UUID()
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "Synthetic orphan.", pressEnter: false))
        store.discardUnclaimedResult(now: now)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))

        // Unreadable.
        defaults.set(Data("not json".utf8), forKey: "ios_pending_dictation")
        store.discardUnclaimedResult(now: now)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))

        // Fresh and awaited: kept for the keyboard.
        store.awaitedSessionID = session
        let fresh = PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: true)
        store.save(fresh)
        store.discardUnclaimedResult(now: now)
        XCTAssertEqual(store.take(sessionID: session, now: now), .fresh(fresh))

        // Expired and awaited: the text goes, a marker stays, so the keyboard
        // still learns that it expired.
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: true))
        let late = start.addingTimeInterval(PendingDictation.maxAge + 1)
        store.discardUnclaimedResult(now: late)
        let marker = PendingDictation(sessionID: session, createdAt: start, text: "", pressEnter: false)
        let stored = try XCTUnwrap(defaults.data(forKey: "ios_pending_dictation"))
        XCTAssertEqual(try JSONDecoder().decode(PendingDictation.self, from: stored), marker)
        store.discardUnclaimedResult(now: late)
        XCTAssertEqual(store.take(sessionID: session, now: late), .expired(marker))
        XCTAssertEqual(store.awaitedSessionID, session, "The awaited session is never touched")

        // Nothing stored: nothing happens.
        store.discardUnclaimedResult(now: late)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))
    }

    func testAwaitedSessionRoundTrips() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        XCTAssertNil(store.awaitedSessionID)

        store.awaitedSessionID = session
        XCTAssertEqual(store.awaitedSessionID, session)
        XCTAssertEqual(defaults.string(forKey: "ios_awaited_dictation_session"), session.uuidString)
        XCTAssertEqual(PendingDictationStore(defaults: defaults).awaitedSessionID, session)

        store.awaitedSessionID = nil
        XCTAssertNil(store.awaitedSessionID)
        XCTAssertNil(defaults.object(forKey: "ios_awaited_dictation_session"))
    }

    func testPendingClearRemovesBothKeys() throws {
        let defaults = try makeDefaults()
        let store = PendingDictationStore(defaults: defaults)
        let session = UUID()
        store.awaitedSessionID = session
        store.save(PendingDictation(sessionID: session, createdAt: start, text: "Synthetic handoff.", pressEnter: false))

        store.clear()
        XCTAssertNil(store.awaitedSessionID)
        XCTAssertEqual(store.take(sessionID: session, now: start), PendingDictationTake.none)
        XCTAssertNil(defaults.object(forKey: "ios_pending_dictation"))
    }

    // MARK: - KeyboardStatusStore

    func testKeyboardStatusRoundTrips() throws {
        let defaults = try makeDefaults()
        let store = KeyboardStatusStore(defaults: defaults)
        XCTAssertNil(store.load())

        let status = KeyboardStatus(
            lastSeenAt: start,
            hasFullAccess: true,
            microphonePermission: .granted,
            inKeyboardCaptureWorked: true,
            lastCaptureFailure: nil
        )
        store.record(status)
        XCTAssertNotNil(defaults.data(forKey: "ios_keyboard_status"))
        XCTAssertEqual(store.load(), status)
        XCTAssertEqual(KeyboardStatusStore(defaults: defaults).load(), status)
    }

    func testKeyboardStatusKeepsTheLastCaptureResult() throws {
        let store = KeyboardStatusStore(defaults: try makeDefaults())
        store.record(KeyboardStatus(
            lastSeenAt: start,
            hasFullAccess: true,
            microphonePermission: .granted,
            inKeyboardCaptureWorked: false,
            lastCaptureFailure: "startTimedOut"
        ))

        // A fresh keyboard process hasn't tried capture yet.
        let later = KeyboardStatus(
            lastSeenAt: start.addingTimeInterval(60),
            hasFullAccess: true,
            microphonePermission: .granted,
            inKeyboardCaptureWorked: nil,
            lastCaptureFailure: nil
        )
        store.record(later)
        let merged = try XCTUnwrap(store.load())
        XCTAssertEqual(merged.lastSeenAt, later.lastSeenAt)
        XCTAssertEqual(merged.inKeyboardCaptureWorked, false)
        XCTAssertEqual(merged.lastCaptureFailure, "startTimedOut")

        // A new capture result replaces the old one, failure included.
        var worked = later
        worked.inKeyboardCaptureWorked = true
        store.record(worked)
        XCTAssertEqual(store.load(), worked)
    }

    func testKeyboardStatusClear() throws {
        let store = KeyboardStatusStore(defaults: try makeDefaults())
        store.record(KeyboardStatus(
            lastSeenAt: start,
            hasFullAccess: false,
            microphonePermission: .undetermined,
            inKeyboardCaptureWorked: nil,
            lastCaptureFailure: nil
        ))

        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - Helpers

    private func entry(_ index: Int) -> HistoryEntry {
        HistoryEntry(
            createdAt: start.addingTimeInterval(TimeInterval(index)),
            source: .keyboard,
            status: .inserted,
            rawTranscript: "synthetic raw \(index)",
            text: "Synthetic text \(index).",
            route: .cleanup,
            durationSeconds: 2
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "FreeFlowTests.Stores.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func makeSettings() throws -> SettingsStore {
        SettingsStore(
            defaults: try makeDefaults(),
            keychain: SharedKeychain(accessGroup: nil, service: "FreeFlowTests.Stores.unused")
        )
    }

    private func makeHistoryStore() throws -> (HistoryStore, SettingsStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeFlowTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = try makeSettings()
        let fileURL = directory.appendingPathComponent("Library/Application Support/FreeFlow/history.json")
        return (HistoryStore(fileURL: fileURL, settings: settings), settings)
    }
}
