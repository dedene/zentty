import AppKit

/// What the title-bar hide-all capsule shows for a worklane: the number of
/// floats and PiPs (pills don't count) and whether they are hidden. Nil when
/// there is nothing to hide.
struct FloatVisibilityCapsuleState: Equatable {
    let count: Int
    let isHidden: Bool

    init?(worklane: WorklaneState?) {
        guard let worklane else { return nil }
        let count = worklane.floatingPanes.count { float in
            if case .minimized = float.mode { return false }
            return true
        }
        guard count > 0 else { return nil }
        self.init(count: count, isHidden: worklane.floatsHidden)
    }

    init(count: Int, isHidden: Bool) {
        self.count = count
        self.isHidden = isHidden
    }

    /// What a click does, so it reads as the tooltip and the VoiceOver label.
    var actionTitle: String {
        isHidden ? "Show floating panes" : "Hide floating panes"
    }

    var symbolName: String {
        isHidden ? "eye.slash" : "eye"
    }

    var countText: String {
        count > 99 ? "99+" : "\(count)"
    }
}

/// Title-bar capsule in the style of the server and Open With capsules: eye
/// icon, divider, count. The whole capsule is one button. Hidden floats show
/// the eye-slash in the accent colour.
@MainActor
final class FloatVisibilityCapsuleView: NSButton {
    static let height: CGFloat = 30
    static let iconSegmentWidth: CGFloat = 36
    static let countSegmentWidth: CGFloat = 30
    static let width: CGFloat = iconSegmentWidth + 1 + countSegmentWidth
    private static let segmentInset: CGFloat = 2
    private static let iconPointSize: CGFloat = 13

    var onToggle: (() -> Void)?

    private(set) var capsuleState = FloatVisibilityCapsuleState(count: 0, isHidden: false)
    private(set) var isHovered = false
    private(set) var isPressed = false
    private let hoverBackgroundView = NSView()
    private let iconView = NSImageView()
    private let dividerView = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private var theme = ZenttyTheme.fallback(for: nil)
    private var shortcutManager = ShortcutManager(shortcuts: .default)
    private var trackingAreaValue: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// One button: the icon, divider and count never take the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 8)
        setAccessibilityRole(.button)

        hoverBackgroundView.wantsLayer = true
        hoverBackgroundView.layer?.cornerCurve = .continuous
        dividerView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countLabel.alignment = .center
        countLabel.isSelectable = false
        countLabel.setAccessibilityElement(false)
        [hoverBackgroundView, dividerView, iconView, countLabel].forEach(addSubview)

        target = self
        action = #selector(handleClick)
        render(capsuleState)
    }

    func render(_ state: FloatVisibilityCapsuleState) {
        capsuleState = state
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
        let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.actionTitle)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        iconView.image = image
        countLabel.stringValue = state.countText
        setAccessibilityLabel(state.actionTitle)
        setAccessibilityValue(state.count == 1 ? "1 floating pane" : "\(state.count) floating panes")
        updateToolTip()
        applyAppearance(animated: false)
        needsLayout = true
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        self.theme = theme
        applyAppearance(animated: animated)
    }

    func updateShortcutTooltip(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        updateToolTip()
    }

    override func layout() {
        super.layout()
        let inset = Self.segmentInset
        hoverBackgroundView.frame = bounds.insetBy(dx: inset, dy: inset)
        hoverBackgroundView.layer?.cornerRadius = hoverBackgroundView.frame.height / 2
        let iconSize = iconView.image?.size ?? NSSize(width: 18, height: 12)
        iconView.frame = NSRect(
            x: floor((Self.iconSegmentWidth - iconSize.width) / 2) + 1,
            y: floor((bounds.height - iconSize.height) / 2),
            width: iconSize.width,
            height: iconSize.height
        )
        dividerView.frame = NSRect(x: Self.iconSegmentWidth, y: 7, width: 1, height: max(0, bounds.height - 14))
        let labelHeight = countLabel.intrinsicContentSize.height
        countLabel.frame = NSRect(
            x: Self.iconSegmentWidth + 1,
            y: floor((bounds.height - labelHeight) / 2),
            width: Self.countSegmentWidth - 2,
            height: labelHeight
        )
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaValue = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else { return }
        isHovered = true
        applyAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        applyAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyAppearance(animated: false)
        super.mouseDown(with: event)
        isPressed = false
        applyAppearance(animated: true)
    }

    @objc private func handleClick() {
        onToggle?()
    }

    // MARK: - Appearance

    /// The eye-slash uses the accent blue (the working-status colour) so a
    /// hidden set reads at a glance; the shown eye matches the other capsules.
    var iconTint: NSColor {
        capsuleState.isHidden ? theme.statusRunning : theme.openWithChromePrimaryTint
    }

    private func applyAppearance(animated: Bool) {
        let hoverBackground: NSColor = if isPressed {
            theme.openWithChromePressedBackground
        } else {
            ChromeGeometry.iconButtonHoverBackground(theme: theme, isHovered: isHovered)
        }
        let iconTint = iconTint
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = self.theme.openWithChromeBackground.cgColor
            self.layer?.borderWidth = 1
            self.layer?.borderColor = self.theme.openWithChromeBorder.cgColor
            self.layer?.shadowColor = self.theme.openWithPopoverShadow.withAlphaComponent(0.45).cgColor
            self.hoverBackgroundView.layer?.backgroundColor = hoverBackground.cgColor
            self.dividerView.layer?.backgroundColor = self.theme.openWithChromeDivider.cgColor
            self.iconView.contentTintColor = iconTint
            self.countLabel.textColor = self.theme.openWithChromeChevronTint
        }
    }

    private func updateToolTip() {
        toolTip = CommandTooltipFormatter.title(
            capsuleState.actionTitle,
            commandID: .toggleFloatsHidden,
            shortcutManager: shortcutManager
        )
    }
}
