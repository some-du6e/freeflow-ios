import UIKit

/// The keyboard's root input view. `UIDevice.playInputClick()` only sounds
/// when the controller's input view adopts `UIInputViewAudioFeedback` and
/// enables clicks; it follows the user's keyboard-click setting.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        true
    }
}

/// Colors for the keyboard panel. The mic and accents follow the app icon's
/// lavender and purple (the app's AccentColor); keys follow the system
/// keyboard so the panel sits on the system's own backdrop.
enum KeyboardTheme {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? rgb(0xAB94F9) : rgb(0x6545D3)
    }

    static let accentPressed = UIColor { traits in
        traits.userInterfaceStyle == .dark ? rgb(0x8F75EE) : rgb(0x4F33B5)
    }

    /// Text and symbols drawn on `accent`.
    static let onAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? rgb(0x1C1240) : .white
    }

    static let keyFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? rgb(0x575757) : .white
    }

    static let keyFillPressed = UIColor { traits in
        traits.userInterfaceStyle == .dark ? rgb(0x3C3C3C) : rgb(0xB5B9C2)
    }

    /// Top-left to bottom-right fill of the mic button.
    static func micGradient(for traits: UITraitCollection) -> [CGColor] {
        if traits.userInterfaceStyle == .dark {
            return [rgb(0xC1B1FF).cgColor, rgb(0x7C5FE6).cgColor]
        }
        return [rgb(0x9D87F7).cgColor, rgb(0x6545D3).cgColor]
    }

    static func micGlow(for traits: UITraitCollection) -> CGColor {
        accent.resolvedColor(with: traits).cgColor
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
