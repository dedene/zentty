import AppKit
import QuartzCore

@MainActor
final class SidebarDropPlaceholderView: NSView {
    private let shapeLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        shapeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
        shapeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        shapeLayer.lineWidth = 1.5
        shapeLayer.lineDashPattern = [6, 4]
        shapeLayer.cornerRadius = ShellMetrics.sidebarRowCornerRadius

        layer?.addSublayer(shapeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        shapeLayer.frame = bounds
        shapeLayer.path = CGPath(
            roundedRect: bounds,
            cornerWidth: ShellMetrics.sidebarRowCornerRadius,
            cornerHeight: ShellMetrics.sidebarRowCornerRadius,
            transform: nil
        )
    }

    func animateIn() {
        alphaValue = 0
        layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.alphaValue = 1
        }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = CATransform3DMakeScale(0.95, 0.95, 1)
        spring.toValue = CATransform3DIdentity
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 22
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer?.add(spring, forKey: "placeholderScaleIn")
    }

    func animateOut(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            self.alphaValue = 0
        }, completionHandler: {
            completion?()
        })

        let spring = CASpringAnimation(keyPath: "transform")
        spring.toValue = CATransform3DMakeScale(0.95, 0.95, 1)
        spring.mass = 1.0
        spring.stiffness = 300
        spring.damping = 22
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer?.add(spring, forKey: "placeholderScaleOut")
    }
}
