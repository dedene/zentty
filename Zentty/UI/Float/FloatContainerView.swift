import AppKit
import QuartzCore

/// The float's two-layer soft shadow (one `CALayer` holds one shadow).
/// Offsets are y-up: negative drops the shadow below the pane.
enum FloatShadowStyle {
    struct Layer: Equatable {
        var offsetY: CGFloat
        var radius: CGFloat
        var opacity: Float
    }

    static let resting: [Layer] = [
        Layer(offsetY: -22, radius: 60, opacity: 0.55),
        Layer(offsetY: -3, radius: 10, opacity: 0.40),
    ]
    static let lifted: [Layer] = [
        Layer(offsetY: -30, radius: 80, opacity: 0.60),
        Layer(offsetY: -6, radius: 16, opacity: 0.45),
    ]
}

/// Hosts one floating `PaneContainerView`. Its frame is the pane frame grown
/// by `chromeOutset` on every side, so the move band (centred on the top
/// border) and the border legends, which sit half outside the pane, stay
/// inside it. The shadows live on sibling layers behind the pane with a
/// rounded `shadowPath`: never on the terminal's Metal layer.
///
/// Gestures latch through `hitTest`: a left-mouse-down in the band, a resize
/// zone, or anywhere with ⌃⌘ returns this view, so AppKit sends the whole
/// press (drags, up, the ⌃-click menu question) here and the terminal never
/// sees it. See `FloatContainerView+Gestures.swift`.
@MainActor
final class FloatContainerView: NSView {
    static let chromeOutset: CGFloat = 10

    let paneID: PaneID
    private(set) weak var hostedContainer: PaneContainerView?
    private(set) var isLifted = false
    /// The pane's frame in the superview's coordinates (the model frame; a
    /// lift draws it larger without changing it).
    private(set) var paneFrame: CGRect = .zero
    /// Lift scale (1 = resting). Drawn by bounds scaling: the frame grows,
    /// the bounds keep the unscaled size, so nothing inside is laid out anew.
    private(set) var liftScale: CGFloat = 1
    private let shadowLayers: [CALayer]

    /// A press landed on the float (focus and raise right away).
    var onPressed: (() -> Void)?
    var onGestureBegan: ((FloatGestureKind) -> Void)?
    /// The live pane frame while dragging (float-layer coordinates).
    var onGestureChanged: ((CGRect) -> Void)?
    /// Outcome plus the release velocity (pt/s).
    var onGestureEnded: ((FloatGestureOutcome, CGVector) -> Void)?
    var onGestureCancelled: (() -> Void)?
    /// The live move entered (true) or left (false) dock mode.
    var onDockModeChanged: ((Bool) -> Void)?
    /// The press being tracked (see `+Gestures`).
    var activeGesture: ActiveFloatGesture?
    /// Where the last press was let go (superview coordinates), set just
    /// before `onGestureEnded`: a dock release resolves here, not at the last
    /// drag sample.
    var lastReleasePoint: CGPoint?
    var gestureMonitors: [Any] = []

    init(paneID: PaneID) {
        self.paneID = paneID
        self.shadowLayers = FloatShadowStyle.resting.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadowLayer in shadowLayers {
            shadowLayer.zPosition = -1
            shadowLayer.shadowColor = NSColor.black.cgColor
            shadowLayer.backgroundColor = nil
            layer?.addSublayer(shadowLayer)
        }
        applyShadowStyle(FloatShadowStyle.resting, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPaneFrame(_ paneFrame: CGRect) {
        self.paneFrame = paneFrame
        applyGeometry()
    }

    /// Draws the float `scale` times larger about its centre (lift on move).
    /// Viewport sync is suspended before scaling and resumed only once the
    /// bounds are unscaled again, so the terminal grid never changes.
    func applyLiftScale(_ scale: CGFloat) {
        guard liftScale != scale else { return }
        if scale != 1 {
            hostedContainer?.suspendTerminalViewportSync(by: .floatLiftScale)
        }
        liftScale = scale
        applyGeometry()
        if scale == 1 {
            hostedContainer?.resumeTerminalViewportSync(by: .floatLiftScale)
        }
    }

    /// The container leaves this host (to a PiP, or the float unmounts):
    /// drops the lift scale's suspension on it without laying it out here.
    func relinquishHostedContainer() {
        hostedContainer?.resumeTerminalViewportSync(by: .floatLiftScale)
        hostedContainer = nil
        liftScale = 1
    }

    private func applyGeometry() {
        let outset = paneFrame.insetBy(dx: -Self.chromeOutset, dy: -Self.chromeOutset)
        let target = liftScale == 1 ? outset : FloatMotion.scaled(outset, by: liftScale)
        if frame != target {
            frame = target
        }
        // Bounds must be re-set after every frame change, or AppKit drops
        // the scale (spike 0a).
        let unscaledBounds = CGRect(origin: .zero, size: outset.size)
        if bounds != unscaledBounds {
            bounds = unscaledBounds
        }
        layoutHostedContainer()
    }

    /// Re-parents `container` into this host at the pane rect. Removing a
    /// focused terminal from its old parent makes it resign first responder;
    /// the float layer's focus sync takes it back.
    func host(_ container: PaneContainerView) {
        if container.superview !== self {
            container.removeFromSuperview()
            addSubview(container)
        }
        hostedContainer = container
        layoutHostedContainer()
    }

    /// Swaps between the resting and the deeper lifted shadow. The lift
    /// scale itself comes with the move gesture (Task 11).
    func setLifted(_ lifted: Bool, animated: Bool) {
        guard isLifted != lifted else { return }
        isLifted = lifted
        applyShadowStyle(lifted ? FloatShadowStyle.lifted : FloatShadowStyle.resting, animated: animated)
    }

    override func layout() {
        super.layout()
        layoutHostedContainer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if activeGesture != nil {
            return self
        }
        let actionsHit = superview.flatMap { hostedContainer?.hitTestBorderActions(point, from: $0) }
        if let event = Self.currentEvent(),
           gestureKind(at: convert(point, from: superview), event: event, isOverBorderChrome: actionsHit != nil) != nil {
            return self
        }
        if let actionsHit {
            return actionsHit
        }
        if let hostedContainer, let superview,
           let legendHit = hostedContainer.hitTestBorderContext(point, from: superview) {
            return legendHit
        }
        // The rest of the outset is transparent.
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// This view is only the hit view for presses it owns, and none of them
    /// opens a context menu (⌃⌘-drag must not become a ⌃-click menu).
    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func gestureKind(at pointInSelf: CGPoint, event: NSEvent, isOverBorderChrome: Bool) -> FloatGestureKind? {
        FloatGesture.ownership(
            at: pointInSelf,
            outsetBounds: bounds,
            eventType: event.type,
            modifiers: event.modifierFlags,
            isOverBorderChrome: isOverBorderChrome
        )
    }

    /// The event being dispatched. AppKit hit-tests a mouse-down while it is
    /// `NSApp.currentEvent`.
    private static func currentEvent() -> NSEvent? {
        NSApp?.currentEvent
    }

    var shadowLayersForTesting: [CALayer] {
        shadowLayers
    }

    private var paneRectInBounds: CGRect {
        bounds.insetBy(dx: Self.chromeOutset, dy: Self.chromeOutset)
    }

    private func layoutHostedContainer() {
        let paneRect = paneRectInBounds
        if let hostedContainer, hostedContainer.frame != paneRect {
            hostedContainer.frame = paneRect
        }
        updateShadowGeometry(paneRect: paneRect)
    }

    private func updateShadowGeometry(paneRect: CGRect) {
        guard paneRect.width > 0, paneRect.height > 0 else { return }
        let radius = ChromeGeometry.paneRadius
        let path = CGPath(
            roundedRect: CGRect(origin: .zero, size: paneRect.size),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        CATransaction.begin()
        // Inside an implicit AppKit animation (lift in place) the shadow
        // follows the pane with the same curve; otherwise it snaps.
        let context = NSAnimationContext.current
        if context.allowsImplicitAnimation {
            CATransaction.setAnimationDuration(context.duration)
            if let timing = context.timingFunction {
                CATransaction.setAnimationTimingFunction(timing)
            }
        } else {
            CATransaction.setDisableActions(true)
        }
        for shadowLayer in shadowLayers where shadowLayer.frame != paneRect || shadowLayer.shadowPath != path {
            shadowLayer.frame = paneRect
            shadowLayer.shadowPath = path
        }
        CATransaction.commit()
    }

    private func applyShadowStyle(_ style: [FloatShadowStyle.Layer], animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(FloatMotionDefaults.shadowDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        for (shadowLayer, spec) in zip(shadowLayers, style) {
            shadowLayer.shadowOffset = CGSize(width: 0, height: spec.offsetY)
            shadowLayer.shadowRadius = spec.radius
            shadowLayer.shadowOpacity = spec.opacity
        }
        CATransaction.commit()
    }
}

private enum FloatMotionDefaults {
    static let shadowDuration: CFTimeInterval = 0.2
}
