import AppKit

@MainActor
final class PaneDragZoneView: NSView {
    static let height: CGFloat = 15
    private static let activationDistance: CGFloat = 6
    private static let highlightInset: CGFloat = 2

    var paneID: PaneID

    /// All point callbacks deliver coordinates in WINDOW space.
    /// The receiver converts from window to whatever target space it needs.
    var onDragActivated: ((PaneID, CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onDragCancelled: (() -> Void)?

    /// Fallback context menu for the pane. The terminal can consume right-clicks
    /// when the inner app enables mouse reporting (e.g. Claude Code); the drag
    /// zone never forwards events to the terminal, so the menu is always reachable here.
    var contextMenuProvider: (() -> NSMenu?)?

    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isDragActive = false
    private var dragStartPointInWindow: CGPoint?

    private let highlightLayer = CAShapeLayer()
    private let gripImageView = NSImageView()

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true

        // Subtle highlight background — fades in on hover
        highlightLayer.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        highlightLayer.opacity = 0
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
        highlightLayer.frame = bounds
        highlightLayer.path = Self.highlightPath(
            in: bounds.insetBy(dx: Self.highlightInset, dy: Self.highlightInset),
            clippedToTopRoundedBounds: bounds,
            radius: ChromeGeometry.paneRadius
        )
        CATransaction.commit()

        let imageSize = gripImageView.intrinsicContentSize
        gripImageView.frame = CGRect(
            x: (bounds.width - imageSize.width) / 2,
            y: (bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private static func highlightPath(
        in rect: CGRect,
        clippedToTopRoundedBounds bounds: CGRect,
        radius: CGFloat
    ) -> CGPath {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGPath(rect: .zero, transform: nil)
        }

        let radius = min(max(0, radius), bounds.width / 2)
        let topY = bounds.maxY
        let centerY = topY - radius
        guard radius > 0, rect.maxY > centerY else {
            return CGPath(rect: rect, transform: nil)
        }

        let leftCenter = CGPoint(x: bounds.minX + radius, y: centerY)
        let rightCenter = CGPoint(x: bounds.maxX - radius, y: centerY)
        let maxY = min(rect.maxY, topY)
        let yOffset = maxY - centerY
        let topInsetX = sqrt(max(0, (radius * radius) - (yOffset * yOffset)))
        let leftTopX = max(rect.minX, leftCenter.x - topInsetX)
        let rightTopX = min(rect.maxX, rightCenter.x + topInsetX)

        let leftSideYOffset = sqrt(max(0, (radius * radius) - pow(leftCenter.x - rect.minX, 2)))
        let rightSideYOffset = sqrt(max(0, (radius * radius) - pow(rect.maxX - rightCenter.x, 2)))
        let leftSideY = min(maxY, centerY + leftSideYOffset)
        let rightSideY = min(maxY, centerY + rightSideYOffset)

        let rightSideAngle = atan2(rightSideY - rightCenter.y, rect.maxX - rightCenter.x)
        let rightTopAngle = atan2(maxY - rightCenter.y, rightTopX - rightCenter.x)
        let leftTopAngle = atan2(maxY - leftCenter.y, leftTopX - leftCenter.x)
        let leftSideAngle = atan2(leftSideY - leftCenter.y, rect.minX - leftCenter.x)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rightSideY))
        path.addArc(
            center: rightCenter,
            radius: radius,
            startAngle: rightSideAngle,
            endAngle: rightTopAngle,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: leftTopX, y: maxY))
        path.addArc(
            center: leftCenter,
            radius: radius,
            startAngle: leftTopAngle,
            endAngle: leftSideAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
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

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        dragStartPointInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !isDragActive,
           let dragStartPointInWindow,
           shouldActivateDrag(from: dragStartPointInWindow, to: event.locationInWindow) {
            activateDrag(at: dragStartPointInWindow)
        }
        guard isDragActive else { return }
        onDragMoved?(event.locationInWindow)
        invalidatePointerAffordances()
    }

    override func mouseUp(with event: NSEvent) {
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        dragStartPointInWindow = nil
        guard isDragActive else {
            return
        }
        onDragEnded?(event.locationInWindow)
        resetDragState()
    }

    #if swift(>=5.10)
    override func mouseCancelled(with event: NSEvent?) {
        dragStartPointInWindow = nil
        guard isDragActive else {
            return
        }
        onDragCancelled?()
    }
    #endif
    func _dummy_mouseCancelled(with event: NSEvent?) {
        dragStartPointInWindow = nil
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
        dragStartPointInWindow = nil
        animateHover(visible: isPointerInside)
        invalidatePointerAffordances()
    }

    private func shouldActivateDrag(from start: CGPoint, to current: CGPoint) -> Bool {
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        let activationDistanceSquared = Self.activationDistance * Self.activationDistance

        return (deltaX * deltaX) + (deltaY * deltaY) >= activationDistanceSquared
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
