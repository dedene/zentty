import AppKit

@MainActor
final class PaneDragZoneView: NSView {
    static let height: CGFloat = 15

    var paneID: PaneID

    /// All point callbacks deliver coordinates in WINDOW space.
    /// The receiver converts from window to whatever target space it needs.
    var onDragActivated: ((PaneID, CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onDragCancelled: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragOrigin: CGPoint?
    private var dragTimestamp: CFTimeInterval?
    private var isDragActivated = false

    private static let activationDistance: CGFloat = 4
    private static let activationDelay: TimeInterval = 0.15

    private let highlightLayer = CALayer()
    private let gripImageView = NSImageView()

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true

        // Subtle highlight background — fades in on hover
        highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        highlightLayer.opacity = 0
        highlightLayer.cornerRadius = 3
        layer?.addSublayer(highlightLayer)

        // Ellipsis icon via SF Symbols
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        if let image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Drag to reorder"
        )?.withSymbolConfiguration(config) {
            image.isTemplate = true
            gripImageView.image = image
            gripImageView.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        }
        gripImageView.alphaValue = 0
        gripImageView.imageScaling = .scaleNone
        addSubview(gripImageView)

        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset: CGFloat = 2
        highlightLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        CATransaction.commit()

        let imageSize = gripImageView.intrinsicContentSize
        gripImageView.frame = CGRect(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.openHand.push()
        animateHover(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.pop()
        animateHover(visible: false)
    }

    private func animateHover(visible: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = visible ? 1.0 : 0.0
        fade.duration = visible ? 0.15 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false

        highlightLayer.add(fade, forKey: "hoverFade")
        highlightLayer.opacity = visible ? 1.0 : 0.0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.15 : 0.12
            gripImageView.animator().alphaValue = visible ? 1.0 : 0.0
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // MARK: - Pan Gesture

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {

        switch recognizer.state {
        case .began:
            dragOrigin = recognizer.location(in: nil)
            dragTimestamp = CACurrentMediaTime()
            isDragActivated = false

        case .changed:
            guard let origin = dragOrigin else { return }

            if !isDragActivated {
                let translation = recognizer.translation(in: self)
                let distance = hypot(translation.x, translation.y)
                let elapsed = CACurrentMediaTime() - (dragTimestamp ?? CACurrentMediaTime())

                guard distance >= Self.activationDistance || elapsed >= Self.activationDelay else {
                    return
                }

                isDragActivated = true
                onDragActivated?(paneID, origin)
            }

            onDragMoved?(recognizer.location(in: nil))

        case .ended:
            if isDragActivated {
                onDragEnded?(recognizer.location(in: nil))
            }
            resetDragState()

        case .cancelled, .failed:
            if isDragActivated {
                onDragCancelled?()
            }
            resetDragState()

        default:
            break
        }
    }

    private func resetDragState() {
        dragOrigin = nil
        dragTimestamp = nil
        isDragActivated = false
    }
}
