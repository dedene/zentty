import AppKit
import QuartzCore

final class SidebarBookmarksButton: NSButton {
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private(set) var isHovered = false
    private(set) var isPopoverPresented = false

    static let buttonSize: CGFloat = 28
    private static let iconSize: CGFloat = 16
    private static let iconVisualTopOffset: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.buttonSize, height: Self.buttonSize)
    }

    override var isHighlighted: Bool {
        didSet {
            applyCurrentAppearance(animated: true)
        }
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
        setAccessibilityLabel("Bookmarks and presets")
        toolTip = "Bookmarks & presets"
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        heightAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = true
        iconView.imageScaling = .scaleNone
        addSubview(iconView)

        if let cell = cell as? NSButtonCell {
            cell.alignment = .center
            cell.imagePosition = .noImage
        }

        updateSymbolImage()
        layoutIconView()
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        toolTip = CommandTooltipFormatter.title(
            "Bookmarks & Presets",
            commandID: .openBookmarksPopover,
            shortcutManager: shortcutManager
        )
    }

    override func layout() {
        super.layout()
        layoutIconView()
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
        guard !isHovered else { return }
        isHovered = true
        applyCurrentAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        applyCurrentAppearance(animated: true)
    }

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        applyCurrentAppearance(animated: animated)
    }

    func setPopoverPresented(_ presented: Bool, animated: Bool = true) {
        guard isPopoverPresented != presented else { return }
        isPopoverPresented = presented
        updateSymbolImage()
        applyCurrentAppearance(animated: animated)
    }

    private func updateSymbolImage() {
        let symbolName = isPopoverPresented ? "bookmark.fill" : "bookmark"
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Bookmarks and presets"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        needsLayout = true
    }

    private func layoutIconView() {
        let size = NSSize(width: Self.iconSize, height: Self.iconSize)
        let visualTopOffset = isFlipped ? -Self.iconVisualTopOffset : Self.iconVisualTopOffset
        iconView.frame = NSRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2) + visualTopOffset,
            width: size.width,
            height: size.height
        )
    }

    private func applyCurrentAppearance(animated: Bool) {
        let isEmphasized = isHovered || isHighlighted || isPopoverPresented
        let iconColor = isEmphasized
            ? currentTheme.secondaryText.withAlphaComponent(0.96)
            : currentTheme.tertiaryText.withAlphaComponent(0.68)
        let backgroundColor: NSColor
        if isEmphasized {
            let mix: CGFloat = currentTheme.sidebarBackground.isDarkThemeColor ? 0.12 : 0.18
            backgroundColor = currentTheme.sidebarBackground
                .mixed(towards: currentTheme.primaryText, amount: mix)
                .withAlphaComponent(min(1, currentTheme.sidebarBackground.alphaComponent + 0.10))
        } else {
            backgroundColor = .clear
        }

        iconView.contentTintColor = iconColor
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = backgroundColor.cgColor
        }
    }
}
