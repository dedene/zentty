import AppKit

@MainActor
final class PaneDragZoneView: NSView {
    static let height: CGFloat = 15

    var paneID: PaneID

    /// All point callbacks deliver coordinates in the DragZoneView's own local space.
    /// The receiver is responsible for converting to whatever target space it needs.
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

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.pop()
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
            let location = recognizer.location(in: self)
            dragOrigin = location
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

            let current = recognizer.location(in: self)
            onDragMoved?(current)

        case .ended:
            if isDragActivated {
                let current = recognizer.location(in: self)
                onDragEnded?(current)
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
