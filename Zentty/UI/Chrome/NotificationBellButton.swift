import AppKit

@MainActor
final class NotificationBellButton: NSButton {
    static let buttonSize: CGFloat = 28
    private static let iconSize: CGFloat = 14
    private static let badgeSize: CGFloat = 12
    private static let badgeFontSize: CGFloat = 8

    var onClick: (() -> Void)?

    private let badgeLayer = CALayer()
    private let badgeTextLayer = CATextLayer()
    private var currentCount: Int = 0
    private var isHovered = false
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

    // MARK: - Setup

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
        if let bellImage = NSImage(
            systemSymbolName: "bell.fill",
            accessibilityDescription: "Notifications"
        )?.withSymbolConfiguration(config) {
            bellImage.isTemplate = true
            image = bellImage
        }
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("Notifications")
        toolTip = "Notifications"

        target = self
        action = #selector(handleClick)

        setupBadge()
    }

    private func setupBadge() {
        let size = Self.badgeSize
        // Position top-right, slightly outside the button bounds.
        badgeLayer.frame = CGRect(
            x: Self.buttonSize - size + 1,
            y: Self.buttonSize - size + 1,
            width: size,
            height: size
        )
        badgeLayer.backgroundColor = NSColor.systemRed.cgColor
        badgeLayer.cornerRadius = size / 2
        badgeLayer.isHidden = true
        badgeLayer.zPosition = 10

        // Vertically center the text by offsetting the frame down by ~1pt.
        // CATextLayer renders text from the top, so we shift the frame to
        // visually center the font within the circle.
        let textInset: CGFloat = 1
        badgeTextLayer.frame = CGRect(x: 0, y: -textInset, width: size, height: size)
        badgeTextLayer.font = NSFont.systemFont(ofSize: Self.badgeFontSize, weight: .bold) as CTFont
        badgeTextLayer.fontSize = Self.badgeFontSize
        badgeTextLayer.foregroundColor = NSColor.white.cgColor
        badgeTextLayer.alignmentMode = .center
        badgeTextLayer.truncationMode = .end

        badgeLayer.addSublayer(badgeTextLayer)
        layer?.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        badgeTextLayer.contentsScale = scale
    }

    // MARK: - Hover Tracking

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

    private func updateHoverAppearance() {
        guard let theme = currentTheme else { return }
        let enabledAlpha: CGFloat = isHovered ? 1.0 : (currentCount > 0 ? 0.96 : 0.82)
        contentTintColor = theme.primaryText.withAlphaComponent(enabledAlpha)
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: self.isHovered
            ).cgColor
        }
    }

    // MARK: - Action

    @objc private func handleClick() {
        onClick?()
    }

    // MARK: - Public API

    func update(count: Int, theme: ZenttyTheme) {
        currentCount = count
        badgeLayer.isHidden = count == 0
        badgeTextLayer.string = count <= 99 ? "\(count)" : "99+"
        alphaValue = count == 0 ? 0.4 : 1.0

        configure(theme: theme, animated: false)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        let enabledAlpha: CGFloat = isHovered ? 1.0 : (currentCount > 0 ? 0.96 : 0.82)
        contentTintColor = theme.primaryText.withAlphaComponent(enabledAlpha)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: self.isHovered
            ).cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 1.0
            self.layer?.shadowColor = theme.underlapShadow.cgColor
            self.layer?.shadowOpacity = 0.10
            self.layer?.shadowRadius = 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }
}
