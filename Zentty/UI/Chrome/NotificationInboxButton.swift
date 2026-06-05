import AppKit
import CoreText

@MainActor
final class NotificationInboxButton: NSButton {
    static let buttonSize: CGFloat = 28
    static let buttonWidth: CGFloat = 44
    private static let iconPointSize: CGFloat = 14
    private static let iconFallbackSize = NSSize(width: 21, height: 14)
    private static let iconToBadgeSpacing: CGFloat = 4
    private static let badgeSize: CGFloat = 14
    private static let badgeFontSize: CGFloat = 9

    var onClick: (() -> Void)?

    private let trayIconView = PassthroughImageView()
    private let badgeLayer = CutoutCountBadgeLayer()
    private var trayIconSize = NotificationInboxButton.iconFallbackSize
    private var currentCount: Int = 0
    private var isHovered = false
    private var isPopoverPresented = false
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

        let config = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
        if let image = NSImage(
            systemSymbolName: "tray.fill",
            accessibilityDescription: "Inbox"
        )?.withSymbolConfiguration(config) {
            image.isTemplate = true
            trayIconSize = image.size
            trayIconView.image = image
        }
        imagePosition = .noImage
        setAccessibilityLabel("Inbox")
        toolTip = "Notification Inbox"

        trayIconView.imageScaling = .scaleProportionallyDown
        addSubview(trayIconView)

        badgeLayer.frame = CGRect(x: 0, y: 0, width: Self.badgeSize, height: Self.badgeSize)
        badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        badgeLayer.fontSize = Self.badgeFontSize
        badgeLayer.isHidden = true
        badgeLayer.zPosition = 10
        layer?.addSublayer(badgeLayer)

        target = self
        action = #selector(handleClick)
    }

    override func layout() {
        super.layout()
        updateContentFrames()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        badgeLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        badgeLayer.setNeedsDisplay()
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
        let isEmphasized = isHovered || isHighlighted || isPopoverPresented
        let enabledAlpha: CGFloat = isEmphasized ? 1.0 : (currentCount > 0 ? 0.96 : 0.82)
        let tint = theme.primaryText.withAlphaComponent(enabledAlpha)
        contentTintColor = tint
        trayIconView.contentTintColor = tint
        badgeLayer.fillColor = tint
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: isEmphasized
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
        updateBadgeText()
        alphaValue = count == 0 && !isPopoverPresented ? 0.4 : 1.0

        configure(theme: theme, animated: false)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        let isEmphasized = isHovered || isHighlighted || isPopoverPresented
        let enabledAlpha: CGFloat = isEmphasized ? 1.0 : (currentCount > 0 ? 0.96 : 0.82)
        let tint = theme.primaryText.withAlphaComponent(enabledAlpha)
        contentTintColor = tint
        trayIconView.contentTintColor = tint
        badgeLayer.fillColor = tint
        updateBadgeText()
        updateContentFrames()
        alphaValue = currentCount == 0 && !isPopoverPresented ? 0.4 : 1.0

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: isEmphasized
            ).cgColor
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 1.0
            self.layer?.shadowColor = theme.underlapShadow.cgColor
            self.layer?.shadowOpacity = 0.10
            self.layer?.shadowRadius = 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func updateBadgeText() {
        let countText: String
        if currentCount <= 0 {
            countText = ""
        } else if currentCount <= 99 {
            countText = "\(currentCount)"
        } else {
            countText = "99+"
        }

        badgeLayer.text = countText
        badgeLayer.isHidden = countText.isEmpty
    }

    private func updateContentFrames() {
        let showsBadge = currentCount > 0
        let badgeWidth = showsBadge ? badgeWidth(for: currentCount) : 0
        let badgeSpacing = showsBadge ? Self.iconToBadgeSpacing : 0
        let contentWidth = trayIconSize.width + badgeSpacing + badgeWidth
        let contentHeight = showsBadge ? max(trayIconSize.height, Self.badgeSize) : trayIconSize.height
        let originX = floor((bounds.width - contentWidth) / 2)
        let originY = floor((bounds.height - contentHeight) / 2)

        trayIconView.frame = CGRect(
            x: originX,
            y: originY + floor((contentHeight - trayIconSize.height) / 2),
            width: trayIconSize.width,
            height: trayIconSize.height
        )

        badgeLayer.frame = CGRect(
            x: trayIconView.frame.maxX + badgeSpacing,
            y: originY + floor((contentHeight - Self.badgeSize) / 2),
            width: badgeWidth,
            height: Self.badgeSize
        )
    }

    private func badgeWidth(for count: Int) -> CGFloat {
        if count <= 9 {
            return Self.badgeSize
        }
        return count <= 99 ? 18 : 22
    }

    func setPopoverPresented(_ presented: Bool, animated: Bool = true) {
        guard isPopoverPresented != presented else { return }
        isPopoverPresented = presented
        guard let currentTheme else { return }
        configure(theme: currentTheme, animated: animated)
    }

    var isPopoverPresentedForTesting: Bool {
        isPopoverPresented
    }

#if DEBUG
    var visualSnapshotForTesting: NotificationInboxButtonVisualSnapshot {
        NotificationInboxButtonVisualSnapshot(
            iconFrame: trayIconView.frame,
            badgeFrame: badgeLayer.frame,
            badgeText: badgeLayer.text,
            badgeFillColor: badgeLayer.fillColor,
            usesCutoutBadgeText: badgeLayer.usesCutoutText,
            hasLegacyNotificationBadgeBackground: hasVisibleNotificationBadgeBackgroundForTesting(theme: currentTheme)
        )
    }

    private func hasVisibleNotificationBadgeBackgroundForTesting(theme: ZenttyTheme?) -> Bool {
        guard let theme else { return false }
        guard let sublayers = layer?.sublayers else { return false }
        let badgeColor = theme.notificationBadgeBackground.usingColorSpace(.sRGB)?.cgColor
            ?? theme.notificationBadgeBackground.cgColor
        return sublayers.contains { layer in
            guard !layer.isHidden, let backgroundColor = layer.backgroundColor else {
                return false
            }
            return backgroundColor.matchesForTesting(badgeColor)
        }
    }
#endif
}

#if DEBUG
struct NotificationInboxButtonVisualSnapshot {
    let iconFrame: CGRect
    let badgeFrame: CGRect
    let badgeText: String
    let badgeFillColor: NSColor
    let usesCutoutBadgeText: Bool
    let hasLegacyNotificationBadgeBackground: Bool
}

private extension CGColor {
    func matchesForTesting(_ other: CGColor) -> Bool {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let lhs = converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let rhs = other.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let lhsComponents = lhs.components,
              let rhsComponents = rhs.components,
              lhsComponents.count == rhsComponents.count else {
            return false
        }
        return zip(lhsComponents, rhsComponents).allSatisfy { abs($0 - $1) < 0.001 }
    }
}
#endif

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class CutoutCountBadgeLayer: CALayer {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var fontSize: CGFloat = 9 {
        didSet {
            guard fontSize != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var fillColor: NSColor = .labelColor {
        didSet {
            setNeedsDisplay()
        }
    }

    let usesCutoutText = true

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
        if let other = layer as? CutoutCountBadgeLayer {
            text = other.text
            fontSize = other.fontSize
            fillColor = other.fillColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = [
            "contents": NSNull(),
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
    }

    override func draw(in ctx: CGContext) {
        guard !text.isEmpty else { return }

        let badgeRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        ctx.setFillColor((fillColor.usingColorSpace(.sRGB) ?? fillColor).cgColor)
        ctx.fillEllipse(in: badgeRect)

        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = (bounds.width - width) / 2
        let baselineFromTop = (bounds.height + font.capHeight) / 2

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baselineFromTop)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
