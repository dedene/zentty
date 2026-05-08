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

@MainActor
final class SidebarPaneDropPresenter {
    private weak var targetStack: NSStackView?
    private weak var lineContainer: NSView?
    private var dropPlaceholder: SidebarDropPlaceholderView?
    private var dropPlaceholderGeneration = 0
    private var insertionLine: PaneDragInsertionLineView?
    private var insertionLineY: CGFloat?

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

    func showInsertionLine(atY y: CGFloat) {
        guard insertionLineY != y, let lineContainer else { return }
        hideInsertionLine()

        let line = PaneDragInsertionLineView()
        line.setOrientation(.horizontal)
        lineContainer.addSubview(line)

        let width = lineContainer.bounds.width
        let lineHeight: CGFloat = 4
        line.frame = CGRect(x: 0, y: y - lineHeight / 2, width: width, height: lineHeight)
        line.startPulsing()
        line.alphaValue = 0.9

        insertionLine = line
        insertionLineY = y
    }

    func hideInsertionLine() {
        guard let line = insertionLine else { return }
        line.removeFromSuperview()
        insertionLine = nil
        insertionLineY = nil
    }

    func showNewWorklanePlaceholder(atIndex insertionIndex: Int) {
        guard let targetStack else { return }
        dropPlaceholderGeneration += 1

        let placeholder: SidebarDropPlaceholderView
        let shouldAnimateIn: Bool
        if let existing = dropPlaceholder {
            placeholder = existing
            shouldAnimateIn = false
            placeholder.layer?.removeAnimation(forKey: "placeholderScaleOut")
            placeholder.alphaValue = 1
            if targetStack.arrangedSubviews.contains(existing) {
                targetStack.removeArrangedSubview(existing)
            }
        } else {
            placeholder = SidebarDropPlaceholderView()
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            dropPlaceholder = placeholder
            shouldAnimateIn = true
        }

        let clampedIndex = max(0, min(insertionIndex, targetStack.arrangedSubviews.count))
        targetStack.insertArrangedSubview(placeholder, at: clampedIndex)
        if shouldAnimateIn {
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: targetStack.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: targetStack.trailingAnchor),
                placeholder.heightAnchor.constraint(equalToConstant: ShellMetrics.sidebarCompactRowHeight),
            ])
            placeholder.animateIn()
        }
    }

    func hideNewWorklanePlaceholder() {
        guard let placeholder = dropPlaceholder else { return }
        dropPlaceholderGeneration += 1
        let generation = dropPlaceholderGeneration
        placeholder.animateOut { [weak self] in
            guard let self, self.dropPlaceholderGeneration == generation else { return }
            self.targetStack?.removeArrangedSubview(placeholder)
            placeholder.removeFromSuperview()
            self.dropPlaceholder = nil
        }
    }
}
