import AppKit
import QuartzCore

enum SidebarCreateWorklaneButtonPresentation {
    case capsule
    case band
}

final class SidebarCreateWorklaneButton: NSButton {
    private static let defaultTitle = "New worklane"
    private static let iconWidth: CGFloat = 16
    private static let titleRenderSlack: CGFloat = 0

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: SidebarCreateWorklaneButton.defaultTitle)
    private let backgroundLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var presentation: SidebarCreateWorklaneButtonPresentation = .capsule
    private var backgroundColorForTesting = NSColor.clear
    private var borderColorForTesting = NSColor.clear
    private(set) var isHovered = false

    override var isHighlighted: Bool {
        didSet {
            applyCurrentAppearance(animated: true)
        }
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = SidebarTextMetrics.labelFittingWidth(
            for: titleLabel.stringValue,
            font: titleLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        )
        let contentWidth = Self.iconWidth
            + ShellMetrics.sidebarCreateWorklaneIconSpacing
            + titleWidth
            + Self.titleRenderSlack
        return NSSize(
            width: contentWidth + (ShellMetrics.sidebarCreateWorklaneHorizontalInset * 2),
            height: ShellMetrics.sidebarCreateWorklaneButtonHeight
        )
    }

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
        setAccessibilityLabel(Self.defaultTitle)
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        font = NSFont.systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = ShellMetrics.sidebarHeaderControlCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(backgroundLayer)
        backgroundLayer.cornerCurve = .continuous
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCreateWorklaneButtonHeight).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New worklane"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = true
        iconView.imageScaling = .scaleNone
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)

        if let cell = cell as? NSButtonCell {
            cell.alignment = .left
            cell.imagePosition = .noImage
        }
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        toolTip = CommandTooltipFormatter.title(
            "New Worklane",
            commandID: .newWorklane,
            shortcutManager: shortcutManager
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(ShellMetrics.sidebarHeaderControlCornerRadius, bounds.height / 2)
        layoutContent()
        layoutBackgroundLayer()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else {
            return
        }

        isHovered = true
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else {
            return
        }

        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        titleLabel.stringValue = Self.defaultTitle
        invalidateIntrinsicContentSize()
        applyCurrentAppearance(animated: animated)
    }

    func setPresentation(_ presentation: SidebarCreateWorklaneButtonPresentation, animated: Bool) {
        guard self.presentation != presentation else {
            return
        }
        self.presentation = presentation
        applyCurrentAppearance(animated: animated)
    }

    var titleText: String {
        titleLabel.stringValue
    }

    var minimumUntruncatedWidth: CGFloat {
        intrinsicContentSize.width
    }

    var titleFitsWithoutTruncation: Bool {
        let requiredWidth = SidebarTextMetrics.labelFittingWidth(
            for: titleLabel.stringValue,
            font: titleLabel.font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        )
        return titleLabel.frame.width + 0.5 >= requiredWidth + Self.titleRenderSlack
    }

    var iconAlpha: CGFloat {
        iconView.contentTintColor?.alphaComponent ?? 0
    }

    var titleAlpha: CGFloat {
        titleLabel.textColor?.alphaComponent ?? 0
    }

    var backgroundAlpha: CGFloat {
        backgroundColorForTesting.alphaComponent
    }

    var backgroundWidthForTesting: CGFloat {
        backgroundLayer.frame.width
    }

    var borderAlpha: CGFloat {
        borderColorForTesting.alphaComponent
    }

    var usesPointingHandCursorForTesting: Bool {
        true
    }

    func contentMinX(in view: NSView) -> CGFloat {
        view.convert(contentFrameForTesting, from: self).minX
    }

    func contentMidX(in view: NSView) -> CGFloat {
        view.convert(contentFrameForTesting, from: self).midX
    }

    func setHoveredForTesting(_ isHovered: Bool) {
        self.isHovered = isHovered
        applyCurrentAppearance(animated: false)
    }

    private func applyCurrentAppearance(animated: Bool) {
        let isEmphasized = isHovered || isHighlighted
        let titleColor = isEmphasized
            ? currentTheme.primaryText.withAlphaComponent(0.96)
            : currentTheme.secondaryText.withAlphaComponent(0.90)
        let iconColor = isEmphasized
            ? currentTheme.secondaryText.withAlphaComponent(0.92)
            : currentTheme.tertiaryText.withAlphaComponent(0.68)
        let backgroundColor: NSColor
        let borderColor = NSColor.clear
        let shadowColor = NSColor.clear
        let shadowOpacity: Float = 0
        if isEmphasized {
            let hoverMix: CGFloat = currentTheme.sidebarBackground.isDarkThemeColor ? 0.13 : 0.18
            backgroundColor = currentTheme.sidebarBackground
                .mixed(towards: currentTheme.primaryText, amount: hoverMix)
                .withAlphaComponent(min(1, currentTheme.sidebarBackground.alphaComponent + 0.10))
        } else {
            backgroundColor = .clear
        }

        titleLabel.textColor = titleColor
        iconView.contentTintColor = iconColor
        backgroundColorForTesting = backgroundColor
        borderColorForTesting = borderColor

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
            self.backgroundLayer.backgroundColor = backgroundColor.cgColor
            self.backgroundLayer.borderColor = borderColor.cgColor
            self.backgroundLayer.borderWidth = borderColor.alphaComponent > 0 ? 0.5 : 0
            self.layer?.shadowColor = shadowColor.cgColor
            self.layer?.shadowOpacity = shadowOpacity
            self.layer?.shadowRadius = 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    private func layoutContent() {
        let inset = ShellMetrics.sidebarCreateWorklaneHorizontalInset
        let iconSize = NSSize(width: Self.iconWidth, height: 16)
        iconView.frame = NSRect(
            x: inset,
            y: floor((bounds.height - iconSize.height) / 2),
            width: iconSize.width,
            height: iconSize.height
        )

        let titleX = iconView.frame.maxX + ShellMetrics.sidebarCreateWorklaneIconSpacing
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(
            x: titleX,
            y: floor((bounds.height - titleHeight) / 2),
            width: max(0, bounds.width - titleX - inset),
            height: titleHeight
        )
    }

    private func layoutBackgroundLayer() {
        let intrinsicWidth = min(bounds.width, intrinsicContentSize.width)
        backgroundLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: intrinsicWidth,
            height: bounds.height
        )
        backgroundLayer.cornerRadius = min(ShellMetrics.sidebarHeaderControlCornerRadius, bounds.height / 2)
    }

    private var contentFrameForTesting: NSRect {
        NSRect(
            x: ShellMetrics.sidebarCreateWorklaneHorizontalInset,
            y: 0,
            width: max(0, titleLabel.frame.maxX - ShellMetrics.sidebarCreateWorklaneHorizontalInset),
            height: bounds.height
        )
    }
}
