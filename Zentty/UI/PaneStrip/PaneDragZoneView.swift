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
    private var isPointerInside = false
    private var isDragActive = false

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
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isPointerInside = true
        animateHover(visible: true)
        invalidatePointerAffordances()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerInside = false
        animateHover(visible: isDragActive)
        invalidatePointerAffordances()
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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resolvedCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        resolvedCursor.set()
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        activateDrag(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard isDragActive else {
            return
        }
        onDragMoved?(event.locationInWindow)
        invalidatePointerAffordances()
    }

    override func mouseUp(with event: NSEvent) {
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard isDragActive else {
            return
        }
        onDragEnded?(event.locationInWindow)
        resetDragState()
    }

    override func mouseCancelled(with event: NSEvent?) {
        guard isDragActive else {
            return
        }
        onDragCancelled?()
        resetDragState()
    }

    private func activateDrag(at windowPoint: CGPoint) {
        guard !isDragActive else {
            return
        }
        isDragActive = true
        animateHover(visible: true)
        invalidatePointerAffordances()
        onDragActivated?(paneID, windowPoint)
    }

    private func resetDragState() {
        isDragActive = false
        animateHover(visible: isPointerInside)
        invalidatePointerAffordances()
    }

    private var resolvedCursor: NSCursor {
        isDragActive ? .closedHand : .openHand
    }

    private func invalidatePointerAffordances() {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)

        guard isPointerInside else {
            return
        }

        resolvedCursor.set()
    }

    /// Re-checks the actual mouse position and corrects hover state.
    /// Call after keyboard-driven focus changes where `mouseExited` never fires.
    func revalidateHoverState() {
        guard let window else { return }
        let mouseInLocal = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let shouldBeInside = bounds.contains(mouseInLocal)
        guard shouldBeInside != isPointerInside else { return }
        isPointerInside = shouldBeInside
        animateHover(visible: shouldBeInside || isDragActive)
        invalidatePointerAffordances()
    }

    #if DEBUG
    var cursorDescriptionForTesting: String {
        if isDragActive {
            "closedHand"
        } else if isPointerInside {
            "openHand"
        } else {
            "openHand"
        }
    }
    #endif
}
