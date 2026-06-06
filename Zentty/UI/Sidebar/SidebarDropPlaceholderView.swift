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
        // Centered anchor so the pop-in scales about the middle (a bubble),
        // not the bottom-left corner.
        shapeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        layer?.addSublayer(shapeLayer)
    }

    /// Suppress implicit frame animation: a freshly inserted placeholder
    /// would otherwise slide in from frame .zero (the bottom of the list)
    /// during the animated room-making layout pass. The placeholder pops in
    /// place; only the neighboring rows slide.
    override func animation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "frameOrigin" || key == "frameSize" { return nil }
        return super.animation(forKey: key)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.bounds = bounds
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.path = CGPath(
            roundedRect: bounds,
            cornerWidth: ShellMetrics.sidebarRowCornerRadius,
            cornerHeight: ShellMetrics.sidebarRowCornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// Pop/bubble the dashed area into place in situ. `delay` lets the
    /// surrounding rows start sliding apart first; backwards fill keeps the
    /// shape invisible until the pop begins. `fade` is false for gap-to-gap
    /// hops, where the placeholder is already visible and only needs a light
    /// scale refresh at its new slot.
    func popIn(delay: CFTimeInterval, fade: Bool) {
        alphaValue = 1
        let beginTime = CACurrentMediaTime() + delay

        let spring = CASpringAnimation(keyPath: "transform")
        let fromScale: CGFloat = fade ? 0.85 : 0.92
        spring.fromValue = CATransform3DMakeScale(fromScale, fromScale, 1)
        spring.toValue = CATransform3DIdentity
        // Near-critically damped (ζ≈0.9): snaps in fast with no perceptible
        // overshoot — anything past scale 1.0 would push the full-width shape
        // beyond the sidebar clip edge and truncate it.
        spring.mass = 1.0
        spring.stiffness = 550
        spring.damping = 42
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        spring.beginTime = beginTime
        spring.fillMode = .backwards
        shapeLayer.add(spring, forKey: "placeholderPopScale")

        if fade {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.18
            fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fadeIn.beginTime = beginTime
            fadeIn.fillMode = .backwards
            shapeLayer.add(fadeIn, forKey: "placeholderPopFade")
        }
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

@MainActor
final class SidebarPaneDropPresenter {
    private weak var targetStack: NSStackView?
    private weak var lineContainer: NSView?
    private var dropPlaceholder: SidebarDropPlaceholderView?
    private var dropPlaceholderGeneration = 0
    private var insertionLine: PaneDragInsertionLineView?
    private var insertionLineFrame: CGRect?

    init(targetStack: NSStackView, lineContainer: NSView) {
        self.targetStack = targetStack
        self.lineContainer = lineContainer
    }

    func setHighlightedDropTargetWorklane(
        _ worklaneID: WorklaneID?,
        buttons: [SidebarWorklaneRowButton]
    ) {
        for button in buttons {
            button.setDropTargetHighlighted(button.worklaneID == worklaneID)
        }
    }

    func showInsertionLine(
        _ target: SidebarPaneInsertionLineTarget,
        buttons: [SidebarWorklaneRowButton]
    ) {
        guard let lineContainer,
              let targetButton = buttons.first(where: { $0.worklaneID == target.worklaneID })
        else {
            hideInsertionLine()
            return
        }

        let rowFrame = lineContainer.convert(targetButton.bounds, from: targetButton)
        let horizontalInset = ShellMetrics.sidebarPaneRowHorizontalInset
        let lineHeight: CGFloat = 4
        let frame = CGRect(
            x: rowFrame.minX + horizontalInset,
            y: target.y - lineHeight / 2,
            width: max(0, rowFrame.width - (horizontalInset * 2)),
            height: lineHeight
        )
        guard insertionLineFrame != frame else { return }
        hideInsertionLine()

        let line = PaneDragInsertionLineView()
        line.setOrientation(.horizontal)
        lineContainer.addSubview(line)

        line.frame = frame
        line.layer?.cornerRadius = lineHeight / 2
        line.layer?.zPosition = 1_000
        line.startPulsing()
        line.alphaValue = 0.9

        insertionLine = line
        insertionLineFrame = frame
    }

    func hideInsertionLine() {
        guard let line = insertionLine else { return }
        line.removeFromSuperview()
        insertionLine = nil
        insertionLineFrame = nil
    }

    func showNewWorklanePlaceholder(atIndex insertionIndex: Int) {
        guard let targetStack else { return }
        dropPlaceholderGeneration += 1

        let placeholder: SidebarDropPlaceholderView
        let isNewPlaceholder: Bool
        if let existing = dropPlaceholder {
            placeholder = existing
            isNewPlaceholder = false
            placeholder.layer?.removeAnimation(forKey: "placeholderScaleOut")
            placeholder.alphaValue = 1
            if targetStack.arrangedSubviews.contains(existing) {
                targetStack.removeArrangedSubview(existing)
            }
        } else {
            placeholder = SidebarDropPlaceholderView()
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            dropPlaceholder = placeholder
            isNewPlaceholder = true
        }

        let clampedIndex = max(0, min(insertionIndex, targetStack.arrangedSubviews.count))
        targetStack.insertArrangedSubview(placeholder, at: clampedIndex)
        if isNewPlaceholder {
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: targetStack.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: targetStack.trailingAnchor),
                placeholder.heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCompactRowHeight),
            ])
        }
        // Slide the surrounding rows apart instead of snapping. Model frames
        // settle immediately (only the presentation layer animates), so drag
        // hit-testing sees final geometry throughout. The placeholder itself
        // suppresses frame animation and pops in place instead.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            targetStack.superview?.layoutSubtreeIfNeeded()
        }
        if isNewPlaceholder {
            // Let the gap visibly open first, then bubble into it.
            placeholder.popIn(delay: 0.06, fade: true)
        } else {
            // Gap-to-gap hop: light scale refresh at the new slot.
            placeholder.popIn(delay: 0, fade: false)
        }
    }

    func hideNewWorklanePlaceholder() {
        guard let placeholder = dropPlaceholder else { return }
        dropPlaceholderGeneration += 1
        let generation = dropPlaceholderGeneration
        placeholder.animateOut { [weak self] in
            guard let self, self.dropPlaceholderGeneration == generation else { return }
            // Slide the rows back together once the fade-out completes.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.targetStack?.removeArrangedSubview(placeholder)
                placeholder.removeFromSuperview()
                self.targetStack?.superview?.layoutSubtreeIfNeeded()
            }
            self.dropPlaceholder = nil
        }
    }

    /// Live frame of the placeholder converted to targetView coordinates,
    /// or nil when no placeholder is showing.
    func newWorklanePlaceholderFrame(in targetView: NSView) -> CGRect? {
        guard let placeholder = dropPlaceholder, placeholder.superview != nil else { return nil }
        return targetView.convert(placeholder.bounds, from: placeholder)
    }
}
