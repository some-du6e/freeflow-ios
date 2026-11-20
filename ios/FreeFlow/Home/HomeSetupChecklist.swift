import Foundation

/// The setup checklist on Home and in Settings: API key, microphone,
/// keyboard added, and Full Access. The app can't see the keyboard directly;
/// the last two come from the status the keyboard writes to the App Group,
/// which it can only do once it has Full Access.
struct HomeSetupChecklist: Equatable {
    enum APIKeyState: Equatable {
        case saved
        case missing
        /// The shared keychain couldn't be read.
        case unreadable(SharedKeychain.Failure)
    }

    enum ItemState: Equatable {
        case done
        case needsAction
        /// Not known yet, e.g. Full Access before the keyboard has reported.
        case unknown
    }

    enum Action: Equatable {
        case none
        /// Go to the API key settings.
        case addAPIKey
        /// Show the microphone prompt (the button says "Continue").
        case requestMicrophone
        /// Open the app's page in the Settings app.
        case openSystemSettings
    }

    struct Item: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case apiKey
            case microphone
            case keyboard
            case fullAccess
        }

        var kind: Kind
        var title: String
        var detail: String
        var state: ItemState
        var action: Action

        var id: String { kind.rawValue }

        var systemImage: String {
            switch kind {
            case .apiKey: "key.fill"
            case .microphone: "mic.fill"
            case .keyboard: "keyboard.fill"
            case .fullAccess: "lock.open.fill"
            }
        }
    }

    var items: [Item]

    var isComplete: Bool {
        items.allSatisfy { $0.state == .done }
    }

    var remainingCount: Int {
        items.filter { $0.state != .done }.count
    }

    static func make(
        apiKey: APIKeyState,
        microphone: AppMicrophonePermission,
        keyboardStatus: KeyboardStatus?
    ) -> HomeSetupChecklist {
        HomeSetupChecklist(items: [
            apiKeyItem(apiKey),
            microphoneItem(microphone),
            keyboardItem(keyboardStatus),
            fullAccessItem(keyboardStatus),
        ])
    }

    private static func apiKeyItem(_ state: APIKeyState) -> Item {
        switch state {
        case .saved:
            Item(kind: .apiKey, title: "API Key", detail: "Saved", state: .done, action: .none)
        case .missing:
            Item(kind: .apiKey, title: "API Key", detail: "API key required", state: .needsAction, action: .addAPIKey)
        case .unreadable(let failure):
            Item(kind: .apiKey, title: "API Key", detail: keychainDetail(failure), state: .needsAction, action: .addAPIKey)
        }
    }

    private static func keychainDetail(_ failure: SharedKeychain.Failure) -> String {
        switch failure {
        case .missingEntitlement:
            "This build can't use the shared keychain."
        case .unavailable:
            "The keychain is locked. Unlock your iPhone and try again."
        case .unexpected:
            "The keychain couldn't be read."
        }
    }

    private static func microphoneItem(_ permission: AppMicrophonePermission) -> Item {
        switch permission {
        case .granted:
            Item(kind: .microphone, title: "Microphone", detail: "Granted", state: .done, action: .none)
        case .undetermined:
            Item(
                kind: .microphone,
                title: "Microphone",
                detail: "FreeFlow needs access to your microphone to record audio for transcription.",
                state: .needsAction,
                action: .requestMicrophone
            )
        case .denied:
            Item(
                kind: .microphone,
                title: "Microphone",
                detail: "Microphone access is off. Turn it on in Settings.",
                state: .needsAction,
                action: .openSystemSettings
            )
        }
    }

    private static func keyboardItem(_ status: KeyboardStatus?) -> Item {
        if status != nil {
            return Item(kind: .keyboard, title: "Keyboard", detail: "Added", state: .done, action: .none)
        }
        return Item(
            kind: .keyboard,
            title: "Keyboard",
            detail: "Add FreeFlow in Settings > Keyboards, then switch to it once.",
            state: .needsAction,
            action: .openSystemSettings
        )
    }

    private static func fullAccessItem(_ status: KeyboardStatus?) -> Item {
        guard let status else {
            return Item(
                kind: .fullAccess,
                title: "Full Access",
                detail: "Turn on Allow Full Access for FreeFlow. It shows here once the keyboard has opened.",
                state: .unknown,
                action: .openSystemSettings
            )
        }
        if status.hasFullAccess {
            return Item(kind: .fullAccess, title: "Full Access", detail: "On", state: .done, action: .none)
        }
        return Item(
            kind: .fullAccess,
            title: "Full Access",
            detail: "Turn on Allow Full Access for FreeFlow.",
            state: .needsAction,
            action: .openSystemSettings
        )
    }
}
