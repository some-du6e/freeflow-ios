import Foundation
import Security

/// API keys in a keychain access group shared by the app and the keyboard.
/// The keyboard can read it only with Full Access.
///
/// Items are generic passwords (service "FreeFlow", account the
/// `FreeFlowSecretAccount` name) in `accessGroup`, readable after the first
/// unlock, never synchronized and never migrated to another device.
struct SharedKeychain {
    enum Failure: Error, Equatable {
        /// The bundle isn't signed with the access group (errSecMissingEntitlement).
        case missingEntitlement
        /// The keychain can't be read right now, e.g. a keyboard without Full
        /// Access or a locked device (errSecNotAvailable, errSecInteractionNotAllowed).
        case unavailable
        case unexpected(OSStatus)
    }

    /// Fixed service name, deliberately not the bundle ID, which differs
    /// between the app and the keyboard.
    static let service = "FreeFlow"

    let accessGroup: String?
    /// The items' service: `SharedKeychain.service` except in tests, which
    /// use their own so they never touch the real keys.
    let service: String

    init(accessGroup: String?) {
        self.init(accessGroup: accessGroup, service: Self.service)
    }

    init(accessGroup: String?, service: String) {
        self.accessGroup = accessGroup
        self.service = service
    }

    static var shared: SharedKeychain {
        SharedKeychain(accessGroup: FreeFlowIdentifiers.keychainAccessGroup)
    }

    /// nil when no value is stored.
    func read(_ account: FreeFlowSecretAccount) -> Result<String?, Failure> {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return .failure(.unexpected(errSecDecode))
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(trimmed.isEmpty ? nil : trimmed)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(Self.failure(for: status))
        }
    }

    /// Stores `value` with surrounding whitespace trimmed, or deletes the
    /// item when `value` is nil or blank. Deleting a missing item succeeds.
    /// Throws a `Failure`.
    func write(_ value: String?, for account: FreeFlowSecretAccount) throws {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account)
            return
        }

        let query = baseQuery(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // The other process added the item between the two calls.
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw Self.failure(for: status)
        }
    }

    static func failure(for status: OSStatus) -> Failure {
        switch status {
        case errSecMissingEntitlement:
            return .missingEntitlement
        case errSecNotAvailable, errSecInteractionNotAllowed:
            return .unavailable
        default:
            return .unexpected(status)
        }
    }

    private func delete(_ account: FreeFlowSecretAccount) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure(for: status)
        }
    }

    private func baseQuery(for account: FreeFlowSecretAccount) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
