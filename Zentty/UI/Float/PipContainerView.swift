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
/// scaled coordinates. Only the legend buttons are passed through. Drags
/// and two-finger swipes move it between corners (see `+Gestures`).
@MainActor
final class PipContainerView: NSView {
    let paneID: PaneID
    /// A press let go without moving.
    var onClicked: ((PaneID) -> Void)?
    var onActionRequested: ((PaneID, PaneBorderAction) -> Void)?
    /// A drag left the click threshold.
    var onDragBegan: ((PaneID) -> Void)?
    /// The dragged model frame (superview coordinates, unclamped).
    var onDragChanged: ((PaneID, CGRect) -> Void)?
    /// Let go after a drag: the model frame and the release velocity (pt/s).
    var onDragEnded: ((PaneID, CGRect, CGVector) -> Void)?
    /// A drag was dropped without a release (unmount).
    var onDragCancelled: ((PaneID) -> Void)?
    var onSwipe: ((PaneID, PipSwipeResolver.Action) -> Void)?
    /// The corner the PiP sits in (swipe direction is relative to it).
    var corner: FloatCorner = .bottomRight
    private(set) var contentSize: CGSize = .zero
    /// Where the PiP sits (superview coordinates). What is drawn adds the
    /// lift and the swipe's rubber band.
    private(set) var modelFrame: CGRect = .zero
    private(set) var isLifted = false
    private(set) var swipeOffset: CGVector = .zero
    /// The press being tracked, from mouse-down to mouse-up.
    var drag: PipDrag?
    var swipeResolver = PipSwipeResolver()
    /// Swallows the rest of a swipe that flicked or bounced (see `+Gestures`).
    var swipeCaptureMonitor: Any?
    private(set) weak var hostedContainer: PaneContainerView?
    private(set) var isHovered = false
    /// Drawing its way out after the model moved on: takes no events.
    var isDeparting = false
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
        applyShadow(lifted: false)
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
        // The legend only shows on hover; VoiceOver reaches its buttons as
        // custom actions (press restores, like a click).
        setAccessibilityCustomActions(PipChrome.actions.map { action in
            NSAccessibilityCustomAction(name: action.accessibilityLabel) { [weak self] in
                guard let self, let onActionRequested = self.onActionRequested else { return false }
                onActionRequested(self.paneID, action)
                return true
            }
        })
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
        modelFrame = frame
        applyDrawnFrame()
    }

    /// Lift for a drag: drawn `PipChrome.liftScale` larger about its centre
    /// with a deeper shadow. Bounds scaling, like a float's lift: the frame
    /// grows, the bounds keep the PiP size, nothing inside is laid out anew
    /// (the terminal is already frozen under `.pip`).
    func setLifted(_ lifted: Bool) {
        guard lifted != isLifted else { return }
        isLifted = lifted
        applyShadow(lifted: lifted)
        applyDrawnFrame()
    }

    /// The swipe's rubber band: drawn this far from the model frame.
    func setSwipeOffset(_ offset: CGVector) {
        guard offset != swipeOffset else { return }
        swipeOffset = offset
        applyDrawnFrame()
    }

    /// The frame drawn for the model frame, lift and swipe offset.
    var drawnFrame: CGRect {
        let lifted = isLifted ? FloatMotion.scaled(modelFrame, by: PipChrome.liftScale) : modelFrame
        return lifted.offsetBy(dx: swipeOffset.dx, dy: swipeOffset.dy)
    }

    private func applyDrawnFrame() {
        let target = drawnFrame
        if frame != target {
            frame = target
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
        // Lifted, the bounds keep the resting PiP size inside a larger frame.
        let unscaled = CGRect(origin: .zero, size: isLifted ? modelFrame.size : frame.size)
        if bounds != unscaled {
            bounds = unscaled
        }
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

    private func applyShadow(lifted: Bool) {
        let style = lifted ? PipChrome.liftedShadow : PipChrome.restingShadow
        CATransaction.begin()
        CATransaction.setAnimationDuration(FloatMotion.liftDuration)
        shadowLayer.shadowOffset = CGSize(width: 0, height: style.offsetY)
        shadowLayer.shadowRadius = style.radius
        shadowLayer.shadowOpacity = style.opacity
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
        guard !isHidden, !isDeparting else { return nil }
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

    var shadowLayerForTesting: CALayer {
        shadowLayer
    }
}
