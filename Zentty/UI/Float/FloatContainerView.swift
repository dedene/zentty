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
/// border, Task 11) and the border legends, which sit half outside the pane,
/// stay inside it. The shadows live on sibling layers behind the pane with a
/// rounded `shadowPath`: never on the terminal's Metal layer.
@MainActor
final class FloatContainerView: NSView {
    static let chromeOutset: CGFloat = 10

    let paneID: PaneID
    private(set) weak var hostedContainer: PaneContainerView?
    private(set) var isLifted = false
    private let shadowLayers: [CALayer]

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

    /// The pane's frame in the superview's coordinates.
    var paneFrame: CGRect {
        frame.insetBy(dx: Self.chromeOutset, dy: Self.chromeOutset)
    }

    func setPaneFrame(_ paneFrame: CGRect) {
        let target = paneFrame.insetBy(dx: -Self.chromeOutset, dy: -Self.chromeOutset)
        if frame != target {
            frame = target
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
        guard !isHidden else { return nil }
        if let hostedContainer, let superview,
           let chromeHit = hostedContainer.hitTestBorderChrome(point, from: superview) {
            return chromeHit
        }
        // The outset itself is transparent until the move band lands.
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
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
        CATransaction.setDisableActions(true)
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
