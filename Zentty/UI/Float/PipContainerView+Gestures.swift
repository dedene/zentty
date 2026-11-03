import AppKit

/// One press on a PiP, from mouse-down to mouse-up.
struct PipDrag {
    var session: FloatDragSession
    /// The pointer left the click threshold: it is a drag, not a click.
    var didBegin: Bool
}

/// Click, drag and two-finger swipe. A press is a click until the pointer
/// moves past `FloatDragSession.clickThreshold`; then it drags. The view
/// only reports: the float layer lifts, moves and settles it, and the store
/// decides the corner. Escape or the window resigning key cancels a press
/// like a float's.
extension PipContainerView {
    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        drag = PipDrag(
            session: FloatDragSession(
                startMouse: pointerLocation(event),
                startFrame: modelFrame,
                timestamp: event.timestamp
            ),
            didBegin: false
        )
        installDragCancellation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var current = drag else { return }
        current.session.move(to: pointerLocation(event), timestamp: event.timestamp)
        let begins = !current.didBegin && !current.session.isClick
        if begins {
            current.didBegin = true
        }
        drag = current
        if begins {
            onDragBegan?(paneID)
        }
        guard current.didBegin, drag != nil else { return }
        onDragChanged?(paneID, current.session.currentFrame)
    }

    override func mouseUp(with event: NSEvent) {
        guard var current = drag else { return }
        // The release is a sample: pausing before letting go reads as slow.
        current.session.move(to: pointerLocation(event), timestamp: event.timestamp)
        endDragTracking()
        guard current.didBegin || !current.session.isClick else {
            onClicked?(paneID)
            return
        }
        onDragEnded?(paneID, current.session.currentFrame, current.session.velocity)
    }

    /// The pointer in the superview's coordinates (the model frame's).
    private func pointerLocation(_ event: NSEvent) -> CGPoint {
        (superview ?? self).convert(event.locationInWindow, from: nil)
    }

    /// Drops a press without a release (Escape, the window resigning key,
    /// the PiP unmounting mid-drag). No-op when nothing is tracked.
    func cancelDrag() {
        guard drag != nil else { return }
        endDragTracking()
        onDragCancelled?(paneID)
    }

    private func endDragTracking() {
        drag = nil
        if let monitor = dragEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            dragEscapeMonitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    /// Escape is swallowed (it must not reach the focused terminal) and
    /// cancels; so does the window resigning key, which can lose the release.
    private func installDragCancellation() {
        if dragEscapeMonitor == nil {
            dragEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleDragKeyDown(event) ?? event
            }
        }
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(dragWindowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    /// The Escape monitor's step: nil (swallowed) when it cancelled a press.
    func handleDragKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53, drag != nil else { return event }
        cancelDrag()
        return nil
    }

    @objc private func dragWindowDidResignKey(_ notification: Notification) {
        cancelDrag()
    }

    var isDragCancellationArmedForTesting: Bool {
        dragEscapeMonitor != nil
    }

    // MARK: - Two-finger swipe

    /// Never forwarded: the scaled terminal must not scroll and the strip
    /// must not switch panes from a swipe on a PiP.
    override func scrollWheel(with event: NSEvent) {
        handleSwipe(PipSwipeResolver.Event(event))
    }

    func handleSwipe(_ event: PipSwipeResolver.Event) {
        let action = swipeResolver.handle(event, corner: corner)
        if swipeResolver.isLocked {
            installSwipeCaptureMonitor()
        }
        if action != .none {
            onSwipe?(paneID, action)
        }
    }

    /// After a flick the PiP is gone from under the pointer: the rest of the
    /// gesture (and its momentum) would scroll the terminal or switch strip
    /// panes there. Swallow it until the resolver lets go.
    private func installSwipeCaptureMonitor() {
        guard swipeCaptureMonitor == nil else { return }
        swipeCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.captureSwipeTail(event) ? nil : event
        }
    }

    /// Whether `event` is the tail of a finished swipe (and so is dropped).
    @discardableResult
    func captureSwipeTail(_ event: NSEvent) -> Bool {
        guard event.window == nil || event.window === window else { return false }
        let captured = swipeResolver.captures(PipSwipeResolver.Event(event))
        if !swipeResolver.isLocked {
            removeSwipeCaptureMonitor()
        }
        return captured
    }

    func removeSwipeCaptureMonitor() {
        guard let monitor = swipeCaptureMonitor else { return }
        NSEvent.removeMonitor(monitor)
        swipeCaptureMonitor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeSwipeCaptureMonitor()
            cancelDrag()
        }
    }

    var isSwipeCaptureActiveForTesting: Bool {
        swipeCaptureMonitor != nil
    }
}

extension PipSwipeResolver.Event {
    init(_ event: NSEvent) {
        self.init(
            phase: PipSwipeResolver.Phase(event.phase),
            momentumPhase: PipSwipeResolver.Phase(event.momentumPhase),
            delta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY),
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            timestamp: event.timestamp
        )
    }
}

extension PipSwipeResolver.Phase {
    init(_ phase: NSEvent.Phase) {
        if phase.contains(.began) {
            self = .began
        } else if phase.contains(.changed) {
            self = .changed
        } else if phase.contains(.ended) {
            self = .ended
        } else if phase.contains(.cancelled) {
            self = .cancelled
        } else if phase.contains(.stationary) {
            self = .stationary
        } else if phase.contains(.mayBegin) {
            self = .mayBegin
        } else {
            self = .none
        }
    }
}
