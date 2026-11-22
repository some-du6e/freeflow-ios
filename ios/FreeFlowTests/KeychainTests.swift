import Security
import XCTest
@testable import FreeFlow

/// SharedKeychain against the simulator keychain, in the access group the
/// app is signed with (FAKETEAMID.com.zachlatta.freeflow.ios.shared in CI).
final class KeychainTests: XCTestCase {
    func testRoundTripInSharedAccessGroup() throws {
        let keychain = makeKeychain()

        XCTAssertEqual(keychain.read(.apiKey), .success(nil))
        try keychain.write("ios-test-key-1", for: .apiKey)
        XCTAssertEqual(keychain.read(.apiKey), .success("ios-test-key-1"))
        XCTAssertEqual(keychain.read(.transcriptionAPIKey), .success(nil), "Each account must be its own item")
    }

    func testOverwriteUpdatesTheSingleItem() throws {
        let keychain = makeKeychain()

        try keychain.write("ios-test-first", for: .apiKey)
        try keychain.write("  ios-test-second\n", for: .apiKey)
        XCTAssertEqual(keychain.read(.apiKey), .success("ios-test-second"))
        XCTAssertEqual(try matchingItems(keychain, .apiKey).count, 1)
    }

    func testBlankOrNilDeletes() throws {
        let keychain = makeKeychain()

        try keychain.write("ios-test-value", for: .transcriptionAPIKey)
        try keychain.write("   ", for: .transcriptionAPIKey)
        XCTAssertEqual(keychain.read(.transcriptionAPIKey), .success(nil))

        try keychain.write("ios-test-value", for: .transcriptionAPIKey)
        try keychain.write(nil, for: .transcriptionAPIKey)
        XCTAssertEqual(keychain.read(.transcriptionAPIKey), .success(nil))
        XCTAssertNoThrow(try keychain.write(nil, for: .transcriptionAPIKey), "Deleting a missing item must succeed")
    }

    func testItemsAreThisDeviceOnlyAndNotSynchronized() throws {
        let keychain = makeKeychain()
        try keychain.write("ios-test-value", for: .apiKey)

        let attributes = try XCTUnwrap(try matchingItems(keychain, .apiKey).first)
        XCTAssertEqual(attributes[kSecAttrAccessGroup as String] as? String, FreeFlowIdentifiers.keychainAccessGroup)
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, keychain.service)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "groq_api_key")
        XCTAssertFalse((attributes[kSecAttrSynchronizable as String] as? Bool) ?? false)
    }

    /// The simulator enforces keychain-access-groups, so a group the app
    /// isn't signed with must fail the way a stripped entitlement would.
    func testUnentitledAccessGroupReportsMissingEntitlement() {
        let keychain = makeKeychain(accessGroup: "FAKETEAMID.com.zachlatta.freeflow.ios.not-entitled")

        XCTAssertThrowsError(try keychain.write("ios-test-value", for: .apiKey)) { error in
            XCTAssertEqual(error as? SharedKeychain.Failure, .missingEntitlement)
        }
    }

    func testStatusMapping() {
        XCTAssertEqual(SharedKeychain.failure(for: -34018), .missingEntitlement)
        XCTAssertEqual(SharedKeychain.failure(for: errSecMissingEntitlement), .missingEntitlement)
        XCTAssertEqual(SharedKeychain.failure(for: -25291), .unavailable)
        XCTAssertEqual(SharedKeychain.failure(for: -25308), .unavailable)
        XCTAssertEqual(SharedKeychain.failure(for: errSecDecode), .unexpected(errSecDecode))
    }

    /// The production configuration, on the real item. Whatever the item
    /// held before is restored, so later UI tests see an untouched keychain.
    func testSharedKeychainRoundTrip() throws {
        let keychain = SharedKeychain.shared
        XCTAssertEqual(keychain.accessGroup, FreeFlowIdentifiers.keychainAccessGroup)
        XCTAssertEqual(keychain.service, "FreeFlow")
        XCTAssertEqual(SharedKeychain.service, "FreeFlow")

        let previous = try keychain.read(.transcriptionAPIKey).get()
        addTeardownBlock {
            try? keychain.write(previous, for: .transcriptionAPIKey)
        }
        try keychain.write("ios-test-shared-key", for: .transcriptionAPIKey)
        XCTAssertEqual(keychain.read(.transcriptionAPIKey), .success("ios-test-shared-key"))
    }

    func testSettingsStoreResolvesKeysFromKeychain() throws {
        let keychain = makeKeychain()
        let suite = "FreeFlowTests.Keychain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let settings = SettingsStore(defaults: defaults, keychain: keychain)

        XCTAssertNil(settings.dictationConfiguration(), "No key means setup is needed")
        try settings.setAPIKey("ios-main-key")
        try settings.setTranscriptionAPIKey("ios-stt-key")
        XCTAssertEqual(settings.apiKey(), .success("ios-main-key"))

        let configuration = try XCTUnwrap(settings.dictationConfiguration())
        XCTAssertEqual(configuration.apiKey, "ios-main-key")
        XCTAssertEqual(configuration.transcriptionAPIKey, "ios-stt-key")

        try settings.setAPIKey(nil)
        XCTAssertNil(settings.dictationConfiguration())
    }

    // MARK: - Helpers

    /// A keychain with its own service, so tests never touch the real keys.
    private func makeKeychain(
        accessGroup: String? = FreeFlowIdentifiers.keychainAccessGroup
    ) -> SharedKeychain {
        let keychain = SharedKeychain(accessGroup: accessGroup, service: "FreeFlowTests.\(UUID().uuidString)")
        addTeardownBlock {
            for account in FreeFlowSecretAccount.allCases {
                try? keychain.write(nil, for: account)
            }
        }
        return keychain
    }

    private func matchingItems(
        _ keychain: SharedKeychain,
        _ account: FreeFlowSecretAccount
    ) throws -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychain.service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let accessGroup = keychain.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result as? [[String: Any]] ?? []
    }
}
