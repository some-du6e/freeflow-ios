import UIKit

/// The dictation-first keyboard surface:
/// - top: the status line and Insert last;
/// - middle: the mic, with Cancel on its left and Done or Open FreeFlow on
///   its right;
/// - bottom: globe (only when iOS asks for one), space, delete and return.
///
/// It only renders a `KeyboardDictationDisplay`; the controller owns the
/// behavior. The controller builds a fresh panel each time the keyboard
/// appears and drops it when the keyboard disappears.
final class KeyboardPanelView: UIView {
    static let micDiameter: CGFloat = 104
    /// From the mic's center to a side button's center.
    static let sideButtonOffset: CGFloat = 100

    let statusLabel = UILabel()
    let insertLastButton = KeyboardKeyButton(
        title: "Insert last",
        symbolName: "arrow.uturn.backward",
        accessibilityLabel: "Insert last dictation",
        identifier: KeyboardAccessibilityID.insertLast
    )
    let micButton = KeyboardMicButton()
    let cancelButton = KeyboardRoundButton(
        symbolName: "xmark",
        title: KeyboardDictationDisplay.cancelButtonTitle,
        style: .secondary,
        identifier: KeyboardAccessibilityID.cancel
    )
    let doneButton = KeyboardRoundButton(
        symbolName: "checkmark",
        title: "Done",
        style: .primary,
        identifier: KeyboardAccessibilityID.done
    )
    let openAppButton = KeyboardRoundButton(
        symbolName: "arrow.up.forward.app",
        title: KeyboardDictationDisplay.openAppTitle,
        style: .primary,
        identifier: KeyboardAccessibilityID.openApp
    )
    let globeKey = KeyboardKeyButton(
        title: nil,
        symbolName: "globe",
        accessibilityLabel: "Next keyboard",
        identifier: KeyboardAccessibilityID.globe
    )
    let spaceKey = KeyboardKeyButton(
        title: "space",
        symbolName: nil,
        accessibilityLabel: "Space",
        identifier: KeyboardAccessibilityID.space
    )
    let deleteKey = KeyboardKeyButton(
        title: nil,
        symbolName: "delete.left",
        accessibilityLabel: "Delete",
        identifier: KeyboardAccessibilityID.delete
    )
    let returnKey = KeyboardKeyButton(
        title: KeyboardReturnKeyKind.standard.title,
        symbolName: nil,
        accessibilityLabel: KeyboardReturnKeyKind.standard.accessibilityLabel,
        identifier: KeyboardAccessibilityID.returnKey
    )

    private let bottomRow = UIStackView()
    private let middleGuide = UILayoutGuide()
    private let statusFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private let longStatusFont = UIFont.systemFont(ofSize: 12, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        configureStatusLabel()
        configureLayout()
        configureKeys(showsGlobe: false, returnKind: .standard, returnEnabled: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Rendering

    func apply(_ display: KeyboardDictationDisplay) {
        if statusLabel.text != display.statusText {
            statusLabel.text = display.statusText
            statusLabel.font = display.statusText.count > 64 ? longStatusFont : statusFont
        }
        statusLabel.accessibilityLabel = display.statusText
        statusLabel.accessibilityValue = display.status.rawValue
        statusLabel.textColor = Self.color(for: display.tone)

        micButton.apply(display.mic, accessibilityLabel: display.micAccessibilityLabel)
        if let cancelTitle = display.cancelTitle {
            cancelButton.setTitle(cancelTitle)
            cancelButton.isHidden = false
        } else {
            cancelButton.isHidden = true
        }
        doneButton.isHidden = display.trailingAction != .done
        openAppButton.isHidden = display.trailingAction != .openApp
        insertLastButton.isEnabled = display.insertLastEnabled
    }

    func configureKeys(showsGlobe: Bool, returnKind: KeyboardReturnKeyKind, returnEnabled: Bool) {
        globeKey.isHidden = !showsGlobe
        returnKey.setContent(title: returnKind.title, symbolName: nil)
        returnKey.accessibilityLabel = returnKind.accessibilityLabel
        returnKey.style = returnKind.isProminent ? .prominent : .standard
        returnKey.isEnabled = returnEnabled
    }

    func setLevel(_ level: Float) {
        micButton.setLevel(level)
    }

    private static func color(for tone: KeyboardDictationDisplay.Tone) -> UIColor {
        switch tone {
        case .neutral:
            return .secondaryLabel
        case .active:
            return .label
        case .success:
            return KeyboardTheme.accent
        case .warning:
            return .systemOrange
        case .failure:
            return .systemRed
        }
    }

    // MARK: Layout

    private func configureStatusLabel() {
        statusLabel.accessibilityIdentifier = KeyboardAccessibilityID.status
        statusLabel.font = statusFont
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 3
        statusLabel.lineBreakMode = .byTruncatingTail
        // The status line wraps into whatever Insert last leaves free.
        statusLabel.setContentCompressionResistancePriority(UILayoutPriority(100), for: .horizontal)
        statusLabel.setContentHuggingPriority(UILayoutPriority(100), for: .horizontal)
    }

    private func configureLayout() {
        bottomRow.axis = .horizontal
        bottomRow.alignment = .fill
        bottomRow.distribution = .fill
        bottomRow.spacing = 6
        for key in [globeKey, spaceKey, deleteKey, returnKey] {
            bottomRow.addArrangedSubview(key)
        }
        spaceKey.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let views: [UIView] = [statusLabel, insertLastButton, micButton, cancelButton, doneButton, openAppButton, bottomRow]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(middleGuide)

        // Fixed sizes give way (999) rather than conflict while iOS sizes
        // the keyboard; the mic shrinks to fit short or landscape keyboards.
        let micSize = micButton.heightAnchor.constraint(equalToConstant: Self.micDiameter)
        micSize.priority = .defaultHigh
        let rowHeight = bottomRow.heightAnchor.constraint(equalToConstant: 44)
        rowHeight.priority = UILayoutPriority(999)
        let globeWidth = globeKey.widthAnchor.constraint(equalToConstant: 46)
        globeWidth.priority = UILayoutPriority(999)
        let deleteWidth = deleteKey.widthAnchor.constraint(equalToConstant: 54)
        deleteWidth.priority = UILayoutPriority(999)
        let returnWidth = returnKey.widthAnchor.constraint(equalToConstant: 92)
        returnWidth.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.heightAnchor.constraint(equalToConstant: 44),
            statusLabel.trailingAnchor.constraint(equalTo: insertLastButton.leadingAnchor, constant: -10),

            insertLastButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            insertLastButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            insertLastButton.heightAnchor.constraint(equalToConstant: 32),

            middleGuide.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            middleGuide.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -6),
            middleGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            middleGuide.trailingAnchor.constraint(equalTo: trailingAnchor),

            micButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: middleGuide.centerYAnchor),
            micButton.widthAnchor.constraint(equalTo: micButton.heightAnchor),
            micButton.heightAnchor.constraint(lessThanOrEqualTo: middleGuide.heightAnchor),
            micSize,

            cancelButton.centerXAnchor.constraint(equalTo: micButton.centerXAnchor, constant: -Self.sideButtonOffset),
            cancelButton.circleView.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            doneButton.centerXAnchor.constraint(equalTo: micButton.centerXAnchor, constant: Self.sideButtonOffset),
            doneButton.circleView.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            openAppButton.centerXAnchor.constraint(equalTo: micButton.centerXAnchor, constant: Self.sideButtonOffset),
            openAppButton.circleView.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),

            bottomRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bottomRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bottomRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            rowHeight,
            globeWidth,
            deleteWidth,
            returnWidth,
        ])
    }
}
