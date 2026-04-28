import AppKit

final class SidebarResizeHandleView: NSView {
    var onPan: ((NSPanGestureRecognizer) -> Void)?

    private var panRecognizer: NSPanGestureRecognizer?
    private var trackingArea: NSTrackingArea?
    private(set) var isEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("Resize sidebar")
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
        panRecognizer = recognizer
        updateIndicatorAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidatePointerAffordances()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else {
            return
        }

        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled else {
            return
        }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        guard isEnabled else {
            return
        }

        NSCursor.resizeLeftRight.set()
    }

    func apply(theme _: ZenttyTheme, animated: Bool) {
        updateIndicatorAppearance(animated: animated)
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        panRecognizer?.isEnabled = isEnabled
        isHidden = !isEnabled
        invalidatePointerAffordances()
        updateIndicatorAppearance(animated: false)
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard isEnabled else {
            return
        }
        onPan?(recognizer)
    }

    private func updateIndicatorAppearance(animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func invalidatePointerAffordances() {
        updateTrackingAreas()
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    var fillAlpha: CGFloat {
        (layer?.backgroundColor)
            .flatMap { NSColor(cgColor: $0) }?
            .alphaComponent ?? 0
    }
}
