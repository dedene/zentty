import AppKit

/// Icon-only leading chrome button that opens the Agent History palette.
/// Sits directly after the notification inbox in `LeadingChromeControlsBar`
/// and mirrors the inbox button's hover / pressed styling.
@MainActor
final class HistoryToolbarButton: NSButton {
    static let buttonSize: CGFloat = 28
    private static let iconPointSize: CGFloat = 14
    private static let symbolName = "clock.arrow.circlepath"
    private static let title = "Agent History"

    var onClick: (() -> Void)?

    private var isHovered = false
    private var isPalettePresented = false
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
        if let symbol = NSImage(
            systemSymbolName: Self.symbolName,
            accessibilityDescription: Self.title
        )?.withSymbolConfiguration(config) {
            symbol.isTemplate = true
            image = symbol
        }
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(Self.title)
        toolTip = Self.title

        target = self
        action = #selector(handleClick)
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        toolTip = CommandTooltipFormatter.title(
            Self.title,
            commandID: .showAgentHistory,
            shortcutManager: shortcutManager
        )
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
        applyEmphasis(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        applyEmphasis(animated: true)
    }

    // MARK: - Action

    @objc private func handleClick() {
        onClick?()
    }

    // MARK: - Public API

    func configure(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        applyEmphasis(animated: animated)
        performThemeAnimation(animated: animated) {
            self.layer?.borderColor = NSColor.clear.cgColor
            self.layer?.borderWidth = 1.0
            self.layer?.shadowColor = theme.underlapShadow.cgColor
            self.layer?.shadowOpacity = 0.10
            self.layer?.shadowRadius = 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }

    /// Pressed state while the Agent History palette is open.
    func setPalettePresented(_ presented: Bool, animated: Bool = true) {
        guard isPalettePresented != presented else { return }
        isPalettePresented = presented
        applyEmphasis(animated: animated)
    }

    var isPalettePresentedForTesting: Bool {
        isPalettePresented
    }

    private func applyEmphasis(animated: Bool) {
        guard let theme = currentTheme else { return }
        let isEmphasized = isHovered || isHighlighted || isPalettePresented
        contentTintColor = theme.primaryText.withAlphaComponent(isEmphasized ? 1.0 : 0.82)
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = ChromeGeometry.iconButtonHoverBackground(
                theme: theme, isHovered: isEmphasized
            ).cgColor
        }
    }
}
