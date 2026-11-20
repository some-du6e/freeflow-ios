import XCTest
@testable import FreeFlow

/// The setup checklist and history labels.
final class AppPresentationTests: XCTestCase {
    private let seen = KeyboardStatus(
        lastSeenAt: Date(timeIntervalSince1970: 1_900_000_000),
        hasFullAccess: true,
        microphonePermission: .granted,
        inKeyboardCaptureWorked: true,
        lastCaptureFailure: nil
    )

    func testEverythingDoneCompletesTheChecklist() {
        let checklist = HomeSetupChecklist.make(apiKey: .saved, microphone: .granted, keyboardStatus: seen)

        XCTAssertTrue(checklist.isComplete)
        XCTAssertEqual(checklist.remainingCount, 0)
        XCTAssertEqual(checklist.items.map(\.kind), [.apiKey, .microphone, .keyboard, .fullAccess])
        XCTAssertTrue(checklist.items.allSatisfy { $0.action == .none })
    }

    func testFreshInstallNeedsEverything() {
        let checklist = HomeSetupChecklist.make(apiKey: .missing, microphone: .undetermined, keyboardStatus: nil)

        XCTAssertFalse(checklist.isComplete)
        XCTAssertEqual(checklist.remainingCount, 4)
        XCTAssertEqual(checklist.items.map(\.action), [.addAPIKey, .requestMicrophone, .openSystemSettings, .openSystemSettings])
        XCTAssertEqual(checklist.items[3].state, .unknown, "Full Access is unknown until the keyboard reports")
    }

    func testDeniedMicrophoneAndMissingFullAccess() {
        var status = seen
        status.hasFullAccess = false
        let checklist = HomeSetupChecklist.make(apiKey: .saved, microphone: .denied, keyboardStatus: status)

        XCTAssertEqual(checklist.items[1].action, .openSystemSettings)
        XCTAssertEqual(checklist.items[1].state, .needsAction)
        XCTAssertEqual(checklist.items[2].state, .done)
        XCTAssertEqual(checklist.items[3].state, .needsAction)
        XCTAssertEqual(checklist.remainingCount, 2)
    }

    func testUnreadableKeychainExplainsWhy() {
        let checklist = HomeSetupChecklist.make(apiKey: .unreadable(.unavailable), microphone: .granted, keyboardStatus: seen)

        XCTAssertEqual(checklist.items[0].state, .needsAction)
        XCTAssertTrue(checklist.items[0].detail.contains("locked"))
    }

    func testHistoryStatusTitles() {
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.inserted), "Inserted")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.handedOff), "Sent to the keyboard")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.rawFallback), "Inserted without cleanup")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.failed), "Failed")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.nothingToInsert), "Nothing to insert")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.notInserted), "Not inserted")
        XCTAssertEqual(HistoryEntryPresentation.statusTitle(.cancelled), "Cancelled")
        XCTAssertEqual(HistoryEntryPresentation.sourceTitle(.keyboard), "Keyboard")
        XCTAssertEqual(HistoryEntryPresentation.routeTitle(.macro), "Voice macro")
        XCTAssertNil(HistoryEntryPresentation.routeTitle(.empty))
        XCTAssertNil(HistoryEntryPresentation.routeTitle(nil))
    }

    func testHistoryCopyAndDisplayText() {
        let cleaned = entry(raw: "um synthetic words", text: "Synthetic words.")
        XCTAssertEqual(HistoryEntryPresentation.copyText(for: cleaned), "Synthetic words.")
        XCTAssertTrue(HistoryEntryPresentation.showsRawTranscript(cleaned))
        XCTAssertEqual(HistoryEntryPresentation.displayText(for: cleaned), "Synthetic words.")

        let rawOnly = entry(raw: "synthetic raw", text: "")
        XCTAssertEqual(HistoryEntryPresentation.copyText(for: rawOnly), "synthetic raw")
        XCTAssertEqual(HistoryEntryPresentation.displayText(for: rawOnly), "synthetic raw")

        let same = entry(raw: "Same.", text: "Same.")
        XCTAssertFalse(HistoryEntryPresentation.showsRawTranscript(same))

        let failed = entry(raw: "", text: "", status: .failed)
        XCTAssertNil(HistoryEntryPresentation.copyText(for: failed))
        XCTAssertEqual(HistoryEntryPresentation.displayText(for: failed), "(no transcript)")
    }

    private func entry(raw: String, text: String, status: HistoryEntry.Status = .inserted) -> HistoryEntry {
        HistoryEntry(
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            source: .keyboard,
            status: status,
            rawTranscript: raw,
            text: text,
            route: .cleanup,
            durationSeconds: 2
        )
    }
}
