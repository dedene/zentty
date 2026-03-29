import AppKit

@MainActor
final class PaneNavigationButtons: NSView {
    static let buttonSize: CGFloat = 28
    static let totalWidth: CGFloat = buttonSize * 2
    private static let iconSize: CGFloat = 12

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private let backButton = HoverableIconButton()
    private let forwardButton = HoverableIconButton()
    private var currentTheme: ZenttyTheme?

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

        configureButton(
            backButton, symbolName: "chevron.left",
            label: "Navigate Back", tip: "Navigate Back"
        )
        configureButton(
            forwardButton, symbolName: "chevron.right",
            label: "Navigate Forward", tip: "Navigate Forward"
        )

        backButton.onHoverChanged = { [weak self] in self?.applyAppearances(animated: true) }
        forwardButton.onHoverChanged = { [weak self] in self?.applyAppearances(animated: true) }

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

    private func configureButton(
        _ button: HoverableIconButton, symbolName: String, label: String, tip: String
    ) {
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
        button.toolTip = tip

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
        currentTheme = theme
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        applyAppearances(animated: false)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        performThemeAnimation(animated: animated) {
            for button in [self.backButton, self.forwardButton] {
                button.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                    theme: theme, isHovered: button.isHovered
                ).cgColor
                button.layer?.borderColor = NSColor.clear.cgColor
                button.layer?.borderWidth = 1.0
                button.layer?.shadowColor = theme.underlapShadow.cgColor
                button.layer?.shadowOpacity = 0.10
                button.layer?.shadowRadius = 5
                button.layer?.shadowOffset = CGSize(width: 0, height: -1)
            }
        }
    }

    // MARK: - Private

    private func applyAppearances(animated: Bool) {
        guard let theme = currentTheme else { return }
        applyAppearance(to: backButton, enabled: backButton.isEnabled, theme: theme, animated: animated)
        applyAppearance(to: forwardButton, enabled: forwardButton.isEnabled, theme: theme, animated: animated)
    }

    private func applyAppearance(
        to button: HoverableIconButton, enabled: Bool, theme: ZenttyTheme, animated: Bool
    ) {
        let tint: NSColor
        if enabled {
            let alpha: CGFloat = button.isHovered ? 1.0 : 0.82
            tint = theme.primaryText.withAlphaComponent(alpha)
        } else {
            tint = theme.tertiaryText
        }
        button.contentTintColor = tint
        performThemeAnimation(animated: animated) {
            button.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: button.isHovered && enabled
            ).cgColor
        }
    }
}

@MainActor
final class PaneLayoutMenuButton: NSButton {
    static let buttonSize: CGFloat = 28
    private static let iconSize: CGFloat = 13

    private(set) var isHovered = false
    private var trackingAreaValue: NSTrackingArea?
    private var currentTheme: ZenttyTheme?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("Arrange panes")
        toolTip = "Arrange Panes"

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
        if let image = NSImage(
            systemSymbolName: "square.split.2x2",
            accessibilityDescription: "Arrange panes"
        )?.withSymbolConfiguration(config) {
            image.isTemplate = true
            self.image = image
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }
        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else { return }
        isHovered = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        updateHoverAppearance()
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        contentTintColor = theme.primaryText.withAlphaComponent(isHovered ? 1.0 : 0.82)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme,
                isHovered: self.isHovered
            ).cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 1.0
            self.layer?.shadowColor = theme.underlapShadow.cgColor
            self.layer?.shadowOpacity = 0.10
            self.layer?.shadowRadius = 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func updateHoverAppearance() {
        guard let currentTheme else { return }
        contentTintColor = currentTheme.primaryText.withAlphaComponent(isHovered ? 1.0 : 0.82)
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: currentTheme,
                isHovered: self.isHovered
            ).cgColor
        }
    }
}

// MARK: - HoverableIconButton

private final class HoverableIconButton: NSButton {
    var onHoverChanged: (() -> Void)?
    private(set) var isHovered = false
    private var trackingAreaValue: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }
        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else { return }
        isHovered = true
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        onHoverChanged?()
    }
}
