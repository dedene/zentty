import AppKit

@MainActor
final class PaneNavigationButtons: NSView {
    static let buttonSize: CGFloat = 28
    static let totalWidth: CGFloat = buttonSize * 2
    private static let iconSize: CGFloat = 12

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        configureButton(backButton, symbolName: "chevron.left", label: "Navigate Back")
        configureButton(forwardButton, symbolName: "chevron.right", label: "Navigate Forward")

        backButton.target = self
        backButton.action = #selector(handleBack)
        forwardButton.target = self
        forwardButton.action = #selector(handleForward)

        addSubview(backButton)
        addSubview(forwardButton)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        forwardButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backButton.topAnchor.constraint(equalTo: topAnchor),
            backButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            forwardButton.topAnchor.constraint(equalTo: topAnchor),
            forwardButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
    }

    private func configureButton(_ button: NSButton, symbolName: String, label: String) {
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.wantsLayer = true
        button.layer?.cornerRadius = ChromeGeometry.pillRadius
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(label)

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
    }

    // MARK: - Actions

    @objc private func handleBack() {
        onBack?()
    }

    @objc private func handleForward() {
        onForward?()
    }

    // MARK: - Public API

    func update(canGoBack: Bool, canGoForward: Bool, theme: ZenttyTheme) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        backButton.contentTintColor = canGoBack
            ? theme.primaryText.withAlphaComponent(0.82)
            : theme.tertiaryText
        forwardButton.contentTintColor = canGoForward
            ? theme.primaryText.withAlphaComponent(0.82)
            : theme.tertiaryText
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            for button in [self.backButton, self.forwardButton] {
                button.layer?.backgroundColor = NSColor.clear.cgColor
                button.layer?.borderColor = NSColor.clear.cgColor
                button.layer?.borderWidth = 1.0
                button.layer?.shadowColor = theme.underlapShadow.cgColor
                button.layer?.shadowOpacity = 0.10
                button.layer?.shadowRadius = 5
                button.layer?.shadowOffset = CGSize(width: 0, height: -1)
            }
        }
    }
}
