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
