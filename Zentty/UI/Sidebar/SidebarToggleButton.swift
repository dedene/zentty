import AppKit
import QuartzCore

enum SidebarToggleVisuals {
    static func contentTintColor(theme: ZenttyTheme, isHovered: Bool) -> NSColor {
        let alpha: CGFloat = isHovered ? 0.96 : 0.82
        return theme.primaryText.withAlphaComponent(alpha)
    }
}

enum SidebarToggleIconFactory {
    static let imageSize = NSSize(width: 15, height: 15)
    private static let symbolName = "sidebar.left"

    static func makeImage(
        symbolProvider: (String, String?) -> NSImage? = { name, description in
            NSImage(systemSymbolName: name, accessibilityDescription: description)
        }
    ) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: imageSize.width, weight: .semibold)
        if let symbolImage = symbolProvider(symbolName, "Toggle sidebar")?.withSymbolConfiguration(configuration) {
            symbolImage.isTemplate = true
            return symbolImage
        }

        let fallbackImage = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.withAlphaComponent(0.16).setFill()

            let outlineRect = rect.insetBy(dx: 1.25, dy: 1.5)
            let outlinePath = NSBezierPath(roundedRect: outlineRect, xRadius: 2.5, yRadius: 2.5)
            outlinePath.lineWidth = 1.35
            outlinePath.stroke()

            let sidebarRect = NSRect(
                x: outlineRect.minX + 0.75,
                y: outlineRect.minY + 0.75,
                width: 3.0,
                height: outlineRect.height - 1.5
            )
            NSBezierPath(roundedRect: sidebarRect, xRadius: 1.2, yRadius: 1.2).fill()

            let dividerPath = NSBezierPath()
            dividerPath.lineWidth = 1.25
            dividerPath.move(to: NSPoint(x: sidebarRect.maxX + 1.6, y: outlineRect.minY + 0.75))
            dividerPath.line(to: NSPoint(x: sidebarRect.maxX + 1.6, y: outlineRect.maxY - 0.75))
            dividerPath.stroke()
            return true
        }
        fallbackImage.isTemplate = true
        return fallbackImage
    }
}

final class SidebarToggleButton: NSButton {
    static let buttonSize: CGFloat = 28
    static let spacingFromTrafficLights: CGFloat = 12
    private(set) var isActive = true
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
        image = SidebarToggleIconFactory.makeImage()
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("Toggle sidebar")
        toolTip = "Toggle Sidebar"
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        toolTip = CommandTooltipFormatter.title(
            "Toggle Sidebar",
            commandID: .toggleSidebar,
            shortcutManager: shortcutManager
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // The toggle slides by animating its enclosing LeadingChromeControlsBar's
    // leading constraint. The button's own frame never changes relative to its
    // superview, so observe the superview frame and reconcile the cached hover
    // flag against the actual cursor position.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if let oldSuperview = superview {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: oldSuperview
            )
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: superview
            )
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

    @objc private func handleFrameDidChange() {
        reconcileHoverWithCursor()
    }

    private func reconcileHoverWithCursor() {
        let pointInLocal: NSPoint
        #if DEBUG
        if let provider = cursorLocationProvider {
            pointInLocal = provider()
        } else {
            guard let window else { return }
            pointInLocal = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        #else
        guard let window else { return }
        pointInLocal = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        #endif

        let shouldBeHovered = bounds.contains(pointInLocal)
        guard shouldBeHovered != isHovered else { return }
        isHovered = shouldBeHovered
        updateHoverAppearance()
    }

    #if DEBUG
    /// Test-only override for the cursor location query. Returns view-local coordinates.
    var cursorLocationProvider: (() -> NSPoint)?
    #endif

    private func updateHoverAppearance() {
        guard let theme = currentTheme else { return }
        contentTintColor = SidebarToggleVisuals.contentTintColor(
            theme: theme, isHovered: isHovered
        )
        performThemeAnimation(animated: true) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: self.isHovered
            ).cgColor
        }
    }

    func configure(theme: ZenttyTheme, isActive: Bool, animated: Bool) {
        self.isActive = isActive
        self.currentTheme = theme
        contentTintColor = SidebarToggleVisuals.contentTintColor(
            theme: theme, isHovered: isHovered
        )

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
