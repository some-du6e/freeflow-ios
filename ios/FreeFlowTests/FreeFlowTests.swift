import XCTest
@testable import FreeFlow

final class FreeFlowTests: XCTestCase {
    /// Proves the shared macOS source file is compiled into the app target.
    func testParsesSyntheticTranscriptionResponse() throws {
        let response = Data(#"{"text":"Synthetic test sentence.","segments":[{"no_speech_prob":0.01}]}"#.utf8)

        XCTAssertEqual(try TranscriptionResponseParser.parse(response), "Synthetic test sentence.")
    }

    func testSharedIdentifiersDeriveFromBundleIdentifier() throws {
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)

        XCTAssertEqual(FreeFlowIdentifiers.appGroupIdentifier, "group.\(bundleIdentifier)")
        XCTAssertTrue(
            FreeFlowIdentifiers.keychainAccessGroup.hasSuffix("\(bundleIdentifier).shared"),
            "Unexpected keychain access group \(FreeFlowIdentifiers.keychainAccessGroup)"
        )
    }

    /// The app and keyboard exchange data through this container, so the
    /// simulator build must carry the App Group entitlement.
    func testAppGroupContainerIsAvailable() throws {
        let identifier = FreeFlowIdentifiers.appGroupIdentifier
        let container = try XCTUnwrap(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier),
            "No container for \(identifier). Was the app signed without its entitlements?"
        )

        let probe = container.appending(path: "freeflow-tests-\(UUID().uuidString).txt")
        let contents = Data("synthetic probe".utf8)
        try contents.write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }

        XCTAssertEqual(try Data(contentsOf: probe), contents)
    }
}
