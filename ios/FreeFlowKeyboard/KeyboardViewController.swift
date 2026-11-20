import UIKit

/// Placeholder FreeFlow keyboard: a dictation button and, when iOS asks for
/// one, a globe key. The dictation button inserts fixed text for now.
final class KeyboardViewController: UIInputViewController {
    private let micButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureMicButton()
        configureNextKeyboardButton()
        layoutKeyboard()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }

    private func configureMicButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "mic.fill")
        configuration.title = "FreeFlow"
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        micButton.configuration = configuration
        micButton.accessibilityIdentifier = "freeflow.keyboard.mic"
        micButton.accessibilityLabel = "Dictate with FreeFlow"
        micButton.addTarget(self, action: #selector(micButtonTapped), for: .touchUpInside)
    }

    private func configureNextKeyboardButton() {
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.accessibilityLabel = "Next keyboard"
        // Tapping advances to the next keyboard; holding shows the keyboard list.
        nextKeyboardButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )
    }

    private func layoutKeyboard() {
        micButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(micButton)
        view.addSubview(nextKeyboardButton)

        // Below required so it yields to the height iOS gives the keyboard.
        let keyboardHeight = view.heightAnchor.constraint(equalToConstant: 216)
        keyboardHeight.priority = .defaultHigh

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            keyboardHeight,
            micButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            micButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            micButton.heightAnchor.constraint(equalToConstant: 56),
            nextKeyboardButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func micButtonTapped() {
        textDocumentProxy.insertText("FreeFlow")
    }
}
