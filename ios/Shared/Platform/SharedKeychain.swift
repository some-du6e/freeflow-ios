import Foundation
import Security

/// API keys in a keychain access group shared by the app and the keyboard.
/// The keyboard can read it only with Full Access.
///
/// CONTRACT STUB: owned by the shared-pipeline agent, which implements the
/// Security calls and simulator tests. Keep the signatures.
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

    init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    static var shared: SharedKeychain {
        SharedKeychain(accessGroup: FreeFlowIdentifiers.keychainAccessGroup)
    }

    /// nil when no value is stored.
    func read(_ account: FreeFlowSecretAccount) -> Result<String?, Failure> {
        .success(nil)
    }

    /// Stores `value`, or deletes the item when `value` is nil or blank.
    func write(_ value: String?, for account: FreeFlowSecretAccount) throws {}
}
