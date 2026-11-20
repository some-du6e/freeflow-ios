import UIKit

/// A system-style key: a rounded cap with a symbol and/or a title. Keys are
/// plain UIKit controls, which sidesteps the system gesture gate's delay on
/// SwiftUI gestures.
final class KeyboardKeyButton: UIControl {
    enum Style: Equatable {
        case standard
        case prominent
    }

    var style: Style = .standard {
        didSet { updateAppearance() }
    }

    private let capView = UIView()
    private let contentStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(title: String?, symbolName: String?, accessibilityLabel label: String, identifier: String) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityIdentifier = identifier

        capView.isUserInteractionEnabled = false
        capView.layer.cornerRadius = 8.5
        capView.layer.cornerCurve = .continuous
        capView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capView)

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.7
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 5
        contentStack.isUserInteractionEnabled = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)

        // Hug the content unless the layout sets a width.
        let hugWidth = widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: 24)
        hugWidth.priority = UILayoutPriority(249)
        NSLayoutConstraint.activate([
            capView.leadingAnchor.constraint(equalTo: leadingAnchor),
            capView.trailingAnchor.constraint(equalTo: trailingAnchor),
            capView.topAnchor.constraint(equalTo: topAnchor),
            capView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            hugWidth,
        ])

        setContent(title: title, symbolName: symbolName)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    func setContent(title: String?, symbolName: String?) {
        titleLabel.text = title
        titleLabel.isHidden = title == nil
        iconView.image = symbolName.flatMap { UIImage(systemName: $0) }
        iconView.isHidden = iconView.image == nil
    }

    func setSymbol(_ symbolName: String) {
        iconView.image = UIImage(systemName: symbolName)
        iconView.isHidden = iconView.image == nil
    }

    private func updateAppearance() {
        let foreground: UIColor
        switch style {
        case .standard:
            capView.backgroundColor = isHighlighted ? KeyboardTheme.keyFillPressed : KeyboardTheme.keyFill
            foreground = .label
        case .prominent:
            capView.backgroundColor = isHighlighted ? KeyboardTheme.accentPressed : KeyboardTheme.accent
            foreground = KeyboardTheme.onAccent
        }
        titleLabel.textColor = foreground
        iconView.tintColor = foreground
        contentStack.alpha = isEnabled ? 1 : 0.4
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }
}

/// A round action beside the mic (Cancel, Done, Open FreeFlow): a circle
/// with a symbol and a short title underneath.
final class KeyboardRoundButton: UIControl {
    enum Style: Equatable {
        case secondary
        case primary
    }

    static let diameter: CGFloat = 52

    /// Exposed so the panel can center the circle, not the whole control,
    /// on the mic.
    let circleView = UIView()

    private let style: Style
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(symbolName: String, title: String, style: Style, identifier: String) {
        self.style = style
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = identifier

        circleView.isUserInteractionEnabled = false
        circleView.layer.cornerRadius = Self.diameter / 2
        circleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circleView)

        iconView.image = UIImage(systemName: symbolName)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        circleView.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.isUserInteractionEnabled = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            circleView.topAnchor.constraint(equalTo: topAnchor),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.widthAnchor.constraint(equalToConstant: Self.diameter),
            circleView.heightAnchor.constraint(equalToConstant: Self.diameter),
            iconView.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: circleView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.diameter),
            widthAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])

        setTitle(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
        accessibilityLabel = title
    }

    private func updateAppearance() {
        switch style {
        case .secondary:
            circleView.backgroundColor = isHighlighted ? KeyboardTheme.keyFillPressed : KeyboardTheme.keyFill
            iconView.tintColor = .label
        case .primary:
            circleView.backgroundColor = isHighlighted ? KeyboardTheme.accentPressed : KeyboardTheme.accent
            iconView.tintColor = KeyboardTheme.onAccent
        }
    }
}
