import Foundation

/// Identifiers that the FreeFlow app and its keyboard extension share.
///
/// Each bundle's Info.plist carries these values. Xcode expands them from
/// `FREEFLOW_BUNDLE_ID_PREFIX` and the signing team's `AppIdentifierPrefix`,
/// the same build settings the entitlements files use, so the values match
/// the entitlements each bundle is signed with.
enum FreeFlowIdentifiers {
    static let appGroupInfoKey = "FreeFlowAppGroupIdentifier"
    static let keychainAccessGroupInfoKey = "FreeFlowKeychainAccessGroup"

    /// The App Group container shared by the app and the keyboard.
    static let appGroupIdentifier = infoValue(for: appGroupInfoKey)

    /// The keychain access group shared by the app and the keyboard.
    static let keychainAccessGroup = infoValue(for: keychainAccessGroupInfoKey)

    /// Reads a required string from `Bundle.main`'s Info.plist. A missing
    /// value means the bundle was built from a misconfigured Info.plist.
    static func infoValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            preconditionFailure("\(key) is missing from \(Bundle.main.bundleURL.lastPathComponent)/Info.plist")
        }
        return value
    }
}
