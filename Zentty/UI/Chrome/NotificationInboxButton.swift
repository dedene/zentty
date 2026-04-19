import AppKit
import CoreText

@MainActor
final class NotificationInboxButton: NSButton {
    static let buttonSize: CGFloat = 28
    private static let iconSize: CGFloat = 14
    private static let badgeSize: CGFloat = 12
    private static let badgeFontSize: CGFloat = 8

    var onClick: (() -> Void)?

    private let badgeLayer = CALayer()
    private let badgeCountLayer = BadgeCountLayer()
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
        if let trayImage = NSImage(
            systemSymbolName: "tray.fill",
            accessibilityDescription: "Inbox"
        )?.withSymbolConfiguration(config) {
            trayImage.isTemplate = true
            image = trayImage
        }
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("Inbox")
        toolTip = "Inbox"

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
        badgeLayer.cornerRadius = size / 2
        badgeLayer.isHidden = true
        badgeLayer.zPosition = 10

        badgeCountLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        badgeCountLayer.fontSize = Self.badgeFontSize

        badgeLayer.addSublayer(badgeCountLayer)
        layer?.addSublayer(badgeLayer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        badgeCountLayer.contentsScale = scale
        badgeCountLayer.setNeedsDisplay()
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
        badgeCountLayer.text = count <= 99 ? "\(count)" : "99+"
        alphaValue = count == 0 ? 0.4 : 1.0

        configure(theme: theme, animated: false)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        let enabledAlpha: CGFloat = isHovered ? 1.0 : (currentCount > 0 ? 0.96 : 0.82)
        contentTintColor = theme.primaryText.withAlphaComponent(enabledAlpha)
        badgeCountLayer.textColor = theme.notificationBadgeText

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
            self.badgeLayer.backgroundColor = theme.notificationBadgeBackground.cgColor
        }
    }
}

/// Draws a short numeric badge string centered on the layer's cap-height
/// midline rather than on the font's full ascender/descender bounds, so the
/// digits sit visually centered inside a circular badge regardless of font.
private final class BadgeCountLayer: CALayer {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var fontSize: CGFloat = 8 {
        didSet {
            guard fontSize != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var textColor: NSColor = .white {
        didSet {
            setNeedsDisplay()
        }
    }

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
        if let other = layer as? BadgeCountLayer {
            text = other.text
            fontSize = other.fontSize
            textColor = other.textColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull()]
    }

    override func draw(in ctx: CGContext) {
        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        // CoreText reads color from the CoreText foreground attribute, not the
        // AppKit `.foregroundColor` key — and not always from the context's
        // fill color when the attributed string has none. Bake the colour in
        // explicitly, in sRGB, so it always renders.
        let resolvedColor = (textColor.usingColorSpace(.sRGB) ?? textColor).cgColor
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: resolvedColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        // CALayer's CGContext is top-down (y grows downward). Pre-flip the
        // text matrix so glyph paths (defined y-up in font space) render
        // right-side-up, then place the baseline measured from the top such
        // that the cap-height block sits centered in the badge.
        let x = (bounds.width - typographicWidth) / 2
        let baselineFromTop = (bounds.height + font.capHeight) / 2

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baselineFromTop)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
