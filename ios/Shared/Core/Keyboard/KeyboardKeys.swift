import Foundation

/// Delete-key repeat, like the system keyboard: one character on press,
/// repeats after `initialDelay` every `repeatInterval`, and whole words once
/// the key has been held for `wordDeletionDelay`.
enum KeyboardDeleteRepeat {
    static let initialDelay: TimeInterval = 0.5
    static let repeatInterval: TimeInterval = 0.1
    static let wordDeletionDelay: TimeInterval = 2

    enum Unit: Equatable {
        case character
        case word
    }

    static func unit(afterHolding duration: TimeInterval) -> Unit {
        duration >= wordDeletionDelay ? .word : .character
    }

    /// How many `deleteBackward()` calls one repeat makes. A word repeat
    /// removes the spaces before the cursor and the word before them, and
    /// stops at a line break. Unknown context deletes one character.
    static func deletionCount(for unit: Unit, textBeforeCursor: String?) -> Int {
        guard unit == .word, let text = textBeforeCursor, let last = text.last, !last.isNewline else {
            return 1
        }
        var count = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            guard character.isWhitespace, !character.isNewline else { break }
            count += 1
            index = previous
        }
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard !text[previous].isWhitespace else { break }
            count += 1
            index = previous
        }
        return max(count, 1)
    }
}

/// The return key's label for the host field's `returnKeyType`. Cases and raw
/// values mirror `UIReturnKeyType`, so Core stays Foundation-only.
enum KeyboardReturnKeyKind: Int, Equatable, CaseIterable {
    case standard = 0
    case go
    case google
    case join
    case next
    case route
    case search
    case send
    case yahoo
    case done
    case emergencyCall
    /// `UIReturnKeyType.continue`.
    case proceed

    /// nil or an unknown raw value means the standard return key.
    init(returnKeyTypeRawValue rawValue: Int?) {
        self = rawValue.flatMap(KeyboardReturnKeyKind.init(rawValue:)) ?? .standard
    }

    /// Lowercase, as on the system keyboard.
    var title: String {
        switch self {
        case .standard:
            return "return"
        case .go:
            return "go"
        case .google, .search, .yahoo:
            return "search"
        case .join:
            return "join"
        case .next:
            return "next"
        case .route:
            return "route"
        case .send:
            return "send"
        case .done:
            return "done"
        case .emergencyCall:
            return "emergency"
        case .proceed:
            return "continue"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .standard:
            return "Return"
        case .go:
            return "Go"
        case .google, .search, .yahoo:
            return "Search"
        case .join:
            return "Join"
        case .next:
            return "Next"
        case .route:
            return "Route"
        case .send:
            return "Send"
        case .done:
            return "Done"
        case .emergencyCall:
            return "Emergency call"
        case .proceed:
            return "Continue"
        }
    }

    /// The system keyboard tints every return key except the standard one.
    var isProminent: Bool {
        self != .standard
    }
}

/// The recording waveform's bar heights, using the macOS overlay's nine-bar
/// shape and travelling pulse (Sources/RecordingOverlay.swift, `WaveformView`).
enum KeyboardWaveformShape {
    static let multipliers: [Double] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]
    static var barCount: Int { multipliers.count }

    /// Heights in 0...1 for a display level in 0...1. `time` (seconds) adds
    /// the pulse; nil draws the plain level.
    static func amplitudes(level: Float, time: TimeInterval?) -> [Double] {
        let clampedLevel = min(max(Double(level), 0), 1)
        return multipliers.indices.map { index in
            let base = min(clampedLevel * multipliers[index], 1)
            guard let time else { return base }
            let travelingWave = 0.5 + 0.5 * sin(time * 6.2 - Double(index) * 0.78)
            let shimmer = 0.5 + 0.5 * sin(time * 3.1 + Double(index) * 0.5)
            let pulse = travelingWave * 0.22 + shimmer * 0.06
            let saturationRelief = base * (0.74 + pulse)
            let quietPulse = (1 - base) * (0.04 + pulse * 0.28)
            return min(saturationRelief + quietPulse, 1)
        }
    }
}

/// The URL the keyboard opens for the record-in-the-app fallback:
/// `freeflow://dictate?session=<uuid>`.
enum KeyboardHandoffURL {
    static let scheme = "freeflow"
    static let dictateHost = "dictate"
    static let sessionQueryName = "session"

    static func dictate(sessionID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = dictateHost
        components.queryItems = [URLQueryItem(name: sessionQueryName, value: sessionID.uuidString)]
        guard let url = components.url else {
            preconditionFailure("A fixed scheme, host and UUID always form a URL")
        }
        return url
    }

    /// The session in a `freeflow://dictate?session=` URL, or nil for any
    /// other URL.
    static func sessionID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == dictateHost,
              let value = components.queryItems?.first(where: { $0.name == sessionQueryName })?.value else {
            return nil
        }
        return UUID(uuidString: value)
    }
}
