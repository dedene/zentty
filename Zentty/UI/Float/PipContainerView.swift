import AppKit
import QuartzCore

/// Hosts a PiP: the float's live `PaneContainerView` at its full float size,
/// drawn smaller by bounds scaling. The terminal's viewport sync stays
/// suspended (the `.pip` owner) while it is here, so the grid keeps the
/// float's columns and rows (spike 0a).
///
/// Layers, back to front: drop shadow and needs-input glow (sibling layers),
/// `clipView` (unscaled, rounded, draws the ring) holding `scaleView`
/// (`bounds` = float size, `frame` = PiP size) and the bottom status strip,
/// then the hover legend on the top border. The chrome is unscaled, so it
/// reads at PiP size.
///
/// Owns every click: the scaled terminal must never receive mouse events at
/// scaled coordinates. Only the legend buttons are passed through.
@MainActor
final class PipContainerView: NSView {
    let paneID: PaneID
    var onClicked: ((PaneID) -> Void)?
    var onActionRequested: ((PaneID, PaneBorderAction) -> Void)?
    private(set) var contentSize: CGSize = .zero
    private(set) weak var hostedContainer: PaneContainerView?
    private(set) var isHovered = false
    private(set) var status: PillBarItem?

    private var theme = ZenttyTheme.fallback(for: nil)
    private let clipView = NSView()
    private let scaleView = NSView()
    private let statusStrip = PipStatusStripView()
    private let actionsView = PaneBorderActionsView()
    private let shadowLayer = CALayer()
    private let glowLayer = CALayer()
    private var hoverArea: NSTrackingArea?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Frames inside are set by `applyGeometry`; autoresizing would reset
        // the scale view's bounds (and with it the scale).
        autoresizesSubviews = false

        for decoration in [shadowLayer, glowLayer] {
            decoration.zPosition = -1
            layer?.addSublayer(decoration)
        }
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: PipChrome.shadowOffsetY)
        shadowLayer.shadowRadius = PipChrome.shadowRadius
        shadowLayer.shadowOpacity = PipChrome.shadowOpacity
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = PipChrome.glowRadius
        glowLayer.shadowOpacity = PipChrome.glowOpacity
        glowLayer.borderWidth = PipChrome.ringWidth
        glowLayer.cornerRadius = PipChrome.cornerRadius + PipChrome.ringWidth
        glowLayer.isHidden = true

        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        clipView.layer?.cornerRadius = PipChrome.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        clipView.layer?.borderWidth = PipChrome.ringWidth
        clipView.autoresizesSubviews = false
        addSubview(clipView)

        scaleView.wantsLayer = true
        scaleView.autoresizesSubviews = false
        clipView.addSubview(scaleView)
        clipView.addSubview(statusStrip)

        actionsView.isHidden = true
        actionsView.onAction = { [weak self] action in
            guard let self else { return }
            self.onActionRequested?(self.paneID, action)
        }
        addSubview(actionsView)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(PipChrome.accessibilityLabel(for: nil))
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hosting (viewport suspension order, spike 0a)

    /// Enter PiP: freezes the grid (the `.pip` suspension owner) before the
    /// container is re-parented and scaled, then hosts it at `contentSize`.
    /// The container must sit unscaled when this is called.
    func host(_ container: PaneContainerView, contentSize: CGSize) {
        guard container.superview !== scaleView else { return }
        container.suspendTerminalViewportSync(by: .pip)
        container.removeFromSuperview()
        container.frame = CGRect(origin: .zero, size: contentSize)
        scaleView.addSubview(container)
        hostedContainer = container
    }

    /// Leave PiP: call once the container sits at its final unscaled frame
    /// elsewhere. Drops the PiP's suspension; sync resumes unless another
    /// owner (a lift still landing) holds it.
    func relinquishHostedContainer() {
        hostedContainer?.resumeTerminalViewportSync(by: .pip)
        hostedContainer = nil
    }

    /// Places the PiP at `frame` and scales `contentSize` into it.
    func apply(frame: CGRect, contentSize: CGSize) {
        self.contentSize = contentSize
        if self.frame != frame {
            self.frame = frame
        }
        applyGeometry()
    }

    /// Every frame change (including animator steps) re-applies the scale:
    /// AppKit drops a bounds scale when the frame changes under it.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            applyGeometry()
            updateTrackingAreas()
        }
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    private func applyGeometry() {
        let local = bounds
        if clipView.frame != local {
            clipView.frame = local
        }
        if scaleView.frame != local {
            scaleView.frame = local
        }
        if contentSize.width > 0, contentSize.height > 0 {
            let scaledBounds = CGRect(origin: .zero, size: contentSize)
            if scaleView.bounds != scaledBounds {
                scaleView.bounds = scaledBounds
            }
            if let hostedContainer, hostedContainer.frame != scaledBounds {
                hostedContainer.frame = scaledBounds
            }
        }
        statusStrip.frame = PipChrome.statusStripFrame(in: local)
        actionsView.frame = PipChrome.legendFrame(in: local)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = local
        shadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: local.size),
            cornerWidth: PipChrome.cornerRadius,
            cornerHeight: PipChrome.cornerRadius,
            transform: nil
        )
        let ringRect = local.insetBy(dx: -PipChrome.ringWidth, dy: -PipChrome.ringWidth)
        glowLayer.frame = ringRect
        glowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: ringRect.size),
            cornerWidth: glowLayer.cornerRadius,
            cornerHeight: glowLayer.cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    // MARK: - Status and theme

    func configure(status: PillBarItem?, theme: ZenttyTheme) {
        guard status != self.status || theme != self.theme else { return }
        self.status = status
        self.theme = theme
        statusStrip.configure(status: status, theme: theme)
        setAccessibilityLabel(PipChrome.accessibilityLabel(for: status))
        applyColors()
        renderActions()
    }

    private func applyColors() {
        let showsRing = PipChrome.showsRing(for: status)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipView.layer?.backgroundColor = theme.paneOpaqueBackdrop.cgColor
        clipView.layer?.borderColor = (showsRing ? theme.statusNeedsInput : theme.paneBorderUnfocused).cgColor
        glowLayer.isHidden = !showsRing
        glowLayer.borderColor = theme.statusNeedsInput.cgColor
        glowLayer.shadowColor = theme.statusNeedsInput.cgColor
        CATransaction.commit()
    }

    // MARK: - Hover legend

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        renderActions()
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        actionsView.updateShortcutTooltips(shortcutManager)
    }

    private func renderActions() {
        let visible = PaneBorderActionsLayout.isVisible(kind: .pip, isHovered: isHovered, isFocused: false)
        actionsView.isHidden = !visible
        guard visible else { return }
        actionsView.render(actions: PipChrome.actions, isFocused: false, theme: theme)
        actionsView.layer?.backgroundColor = theme.paneOpaqueBackdrop.cgColor
        actionsView.layer?.cornerRadius = 4
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: PipChrome.hoverRect(in: bounds),
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    // MARK: - Mouse ownership

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if !actionsView.isHidden, actionsView.frame.contains(local),
           let hit = actionsView.hitTest(local) {
            return hit
        }
        guard frame.contains(point) else {
            return nil
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClicked?(paneID)
    }

    override func scrollWheel(with event: NSEvent) {
        // Swallowed: a scaled terminal must not scroll from here.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func accessibilityPerformPress() -> Bool {
        onClicked?(paneID)
        return true
    }

    // MARK: - Testing

    /// The view that carries the bounds scale (its `bounds` = float size).
    var scaleViewForTesting: NSView {
        scaleView
    }

    var statusStripForTesting: PipStatusStripView {
        statusStrip
    }

    var actionsViewForTesting: PaneBorderActionsView {
        actionsView
    }

    var glowLayerForTesting: CALayer {
        glowLayer
    }

    var ringColorForTesting: CGColor? {
        clipView.layer?.borderColor
    }
}

/// The PiP's bottom overlay: status dot, name, and the status word on the
/// right, over a gradient that fades the terminal out underneath.
@MainActor
final class PipStatusStripView: NSView {
    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let statusFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    private let gradientLayer = CAGradientLayer()
    private let dotLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private(set) var status: PillBarItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // y-up layer: transparent at the top, opaque from 45% down.
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.locations = [0, 0.45, 1]
        layer?.addSublayer(gradientLayer)
        dotLayer.cornerRadius = PipChrome.statusDotSize / 2
        layer?.addSublayer(dotLayer)
        for label in [nameLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        nameLabel.font = Self.nameFont
        statusLabel.font = Self.statusFont
        statusLabel.alignment = .right
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(status: PillBarItem?, theme: ZenttyTheme) {
        self.status = status
        nameLabel.stringValue = status?.name ?? ""
        statusLabel.stringValue = status?.statusWord ?? ""
        statusLabel.isHidden = status?.statusWord == nil
        nameLabel.textColor = theme.primaryText
        statusLabel.textColor = SidebarWorklaneRowStyleResolver.statusTextColor(
            attentionState: status?.attention,
            theme: theme
        )
        let backdrop = theme.paneOpaqueBackdrop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [
            backdrop.withAlphaComponent(0).cgColor,
            backdrop.withAlphaComponent(0.95).cgColor,
            backdrop.withAlphaComponent(0.95).cgColor,
        ]
        dotLayer.backgroundColor = PillView.dotColor(for: status?.attention, theme: theme).cgColor
        CATransaction.commit()
        PillView.updatePulse(on: dotLayer, attention: status?.attention)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let padding = PipChrome.statusHorizontalPadding
        let dot = PipChrome.statusDotSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        dotLayer.frame = CGRect(x: padding, y: ((height - dot) / 2).rounded(), width: dot, height: dot)
        CATransaction.commit()

        let statusSize = statusLabel.isHidden ? .zero : statusLabel.intrinsicContentSize
        let statusWidth = min(ceil(statusSize.width), bounds.width / 2)
        statusLabel.frame = CGRect(
            x: bounds.maxX - padding - statusWidth,
            y: ((height - statusSize.height) / 2).rounded(),
            width: statusWidth,
            height: statusSize.height
        )
        let nameX = padding + dot + PipChrome.statusGap
        let nameMaxX = statusLabel.isHidden ? bounds.maxX - padding : statusLabel.frame.minX - PipChrome.statusGap
        let nameSize = nameLabel.intrinsicContentSize
        nameLabel.frame = CGRect(
            x: nameX,
            y: ((height - nameSize.height) / 2).rounded(),
            width: max(0, min(ceil(nameSize.width), nameMaxX - nameX)),
            height: nameSize.height
        )
    }

    var nameForTesting: String {
        nameLabel.stringValue
    }

    var statusWordForTesting: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    var dotLayerForTesting: CALayer {
        dotLayer
    }
}
