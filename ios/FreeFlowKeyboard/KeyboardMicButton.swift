import UIKit

/// The big mic: a lavender-to-purple circle with a soft glow, like the app
/// icon. It shows the mic glyph when ready, pulsing dots while starting,
/// white glowing waveform bars while recording, and a spinner while
/// transcribing. The controller reads touch down and touch up to tell a tap
/// from a hold.
final class KeyboardMicButton: UIControl {
    private let circleView = UIView()
    private let gradientLayer = CAGradientLayer()
    private let micIcon = UIImageView()
    private let waveformView = KeyboardWaveformView()
    private let dotsView = KeyboardStartingDotsView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var currentMic: KeyboardDictationDisplay.Mic?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        // startsMediaSession keeps VoiceOver from speaking over the recording.
        accessibilityTraits = [.button, .startsMediaSession]
        accessibilityIdentifier = KeyboardAccessibilityID.mic
        accessibilityLabel = KeyboardDictationDisplay.dictateLabel
        accessibilityHint = "Tap to start and stop, or touch and hold to talk."

        layer.shadowOffset = CGSize(width: 0, height: 5)
        layer.shadowRadius = 14
        layer.shadowOpacity = 0.45

        circleView.isUserInteractionEnabled = false
        circleView.clipsToBounds = true
        circleView.translatesAutoresizingMaskIntoConstraints = false
        gradientLayer.startPoint = CGPoint(x: 0.2, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.8, y: 1)
        circleView.layer.addSublayer(gradientLayer)
        addSubview(circleView)

        micIcon.image = UIImage(systemName: "mic.fill")
        micIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        micIcon.tintColor = .white
        micIcon.contentMode = .center
        spinner.color = .white
        spinner.hidesWhenStopped = true

        for content in [micIcon, waveformView, dotsView, spinner] as [UIView] {
            content.isUserInteractionEnabled = false
            content.translatesAutoresizingMaskIntoConstraints = false
            circleView.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            circleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            circleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            circleView.topAnchor.constraint(equalTo: topAnchor),
            circleView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(updateColors))
        updateColors()
        apply(.ready, accessibilityLabel: KeyboardDictationDisplay.dictateLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let pressed = isHighlighted
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: {
                    self.transform = pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
                },
                completion: nil
            )
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2
        circleView.layer.cornerRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = circleView.bounds
        CATransaction.commit()
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }

    func apply(_ mic: KeyboardDictationDisplay.Mic, accessibilityLabel label: String) {
        accessibilityLabel = label
        guard mic != currentMic else { return }
        currentMic = mic

        micIcon.isHidden = !(mic == .ready || mic == .unavailable)
        circleView.alpha = mic == .unavailable ? 0.55 : 1

        waveformView.isHidden = mic != .recording
        if mic == .recording {
            waveformView.reset()
        }

        dotsView.isHidden = mic != .starting
        if mic == .starting {
            dotsView.startAnimating()
        } else {
            dotsView.stopAnimating()
        }

        if mic == .processing {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    /// The capture's display level, 0...1. Ignored unless recording.
    func setLevel(_ level: Float) {
        guard currentMic == .recording else { return }
        waveformView.setLevel(level, time: CACurrentMediaTime())
    }

    @objc private func updateColors() {
        gradientLayer.colors = KeyboardTheme.micGradient(for: traitCollection)
        layer.shadowColor = KeyboardTheme.micGlow(for: traitCollection)
    }
}

/// Nine white, softly glowing bars in the macOS overlay's shape
/// (`KeyboardWaveformShape`), driven by the capture level.
final class KeyboardWaveformView: UIView {
    static let barWidth: CGFloat = 4.5
    static let barSpacing: CGFloat = 4
    static let minimumBarHeight: CGFloat = 5
    static let maximumBarHeight: CGFloat = 44

    private var barLayers: [CALayer] = []
    private var amplitudes = [Double](repeating: 0, count: KeyboardWaveformShape.barCount)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for _ in 0..<KeyboardWaveformShape.barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.white.cgColor
            bar.cornerRadius = Self.barWidth / 2
            bar.shadowColor = UIColor.white.cgColor
            bar.shadowOpacity = 0.85
            bar.shadowRadius = 3.5
            bar.shadowOffset = .zero
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(KeyboardWaveformShape.barCount)
        return CGSize(
            width: count * Self.barWidth + (count - 1) * Self.barSpacing,
            height: Self.maximumBarHeight
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars(animated: false)
    }

    func reset() {
        amplitudes = [Double](repeating: 0, count: KeyboardWaveformShape.barCount)
        layoutBars(animated: false)
    }

    func setLevel(_ level: Float, time: TimeInterval) {
        amplitudes = KeyboardWaveformShape.amplitudes(level: level, time: time)
        layoutBars(animated: true)
    }

    private func layoutBars(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let originX = (bounds.width - intrinsicContentSize.width) / 2
        for (index, bar) in barLayers.enumerated() {
            let amplitude = index < amplitudes.count ? CGFloat(amplitudes[index]) : 0
            let height = Self.minimumBarHeight + (Self.maximumBarHeight - Self.minimumBarHeight) * amplitude
            let frame = CGRect(
                x: originX + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                y: (bounds.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            bar.frame = frame
            bar.shadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: frame.size),
                cornerRadius: Self.barWidth / 2
            ).cgPath
        }
        CATransaction.commit()
    }
}

/// Three white dots that pulse in turn while the microphone starts, like the
/// macOS overlay's starting state.
final class KeyboardStartingDotsView: UIView {
    private static let dotSize: CGFloat = 8
    private static let pulseKey = "freeflow.pulse"
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for _ in 0..<3 {
            let dot = UIView()
            dot.backgroundColor = .white
            dot.layer.cornerRadius = Self.dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
                dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            ])
            stack.addArrangedSubview(dot)
            dots.append(dot)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func startAnimating() {
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAnimation(forKey: Self.pulseKey)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = now + Double(index) * 0.25
            pulse.fillMode = .backwards
            dot.layer.add(pulse, forKey: Self.pulseKey)
        }
    }

    func stopAnimating() {
        for dot in dots {
            dot.layer.removeAnimation(forKey: Self.pulseKey)
        }
    }
}
