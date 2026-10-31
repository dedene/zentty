import AppKit

/// One press on a float, from mouse-down to mouse-up.
struct ActiveFloatGesture {
    let kind: FloatGestureKind
    var session: FloatDragSession
    /// The pointer left the click threshold: the gesture is visible.
    var didBegin: Bool
    /// A plain press on the cwd legend: a click copies the path.
    let startedOverLegend: Bool
    /// ⌥ is held during a move: the float docks where it is released.
    var isDockMode = false
}

/// Move, resize and throw. The container only gets these events for presses
/// `hitTest` latched (band, resize zone, ⌃⌘ anywhere), so the terminal
/// underneath never sees any phase of them. Frames go out through the
/// callbacks; the float layer owns what is drawn and what is committed.
extension FloatContainerView {
    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        let pointInSuperview = superview.convert(event.locationInWindow, from: nil)
        let actionsHit = hostedContainer?.hitTestBorderActions(pointInSuperview, from: superview)
        guard let kind = gestureKind(
            at: convert(event.locationInWindow, from: nil),
            event: event,
            isOverBorderChrome: actionsHit != nil
        ) else {
            super.mouseDown(with: event)
            return
        }
        cancelGesture()
        let overLegend = !event.modifierFlags.isSuperset(of: FloatGesture.anywhereMoveModifiers)
            && hostedContainer?.hitTestBorderContext(pointInSuperview, from: superview) != nil
        activeGesture = ActiveFloatGesture(
            kind: kind,
            session: FloatDragSession(startMouse: pointInSuperview, startFrame: paneFrame, timestamp: event.timestamp),
            didBegin: false,
            startedOverLegend: overLegend,
            isDockMode: FloatGesture.startsDockMode(kind: kind, modifiers: event.modifierFlags)
        )
        installGestureMonitors()
        onPressed?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var gesture = activeGesture, let superview else { return }
        gesture.session.move(to: superview.convert(event.locationInWindow, from: nil), timestamp: event.timestamp)
        let starts = !gesture.didBegin && !gesture.session.isClick
        if starts {
            gesture.didBegin = true
        }
        activeGesture = gesture
        if starts {
            onGestureBegan?(gesture.kind)
            if gesture.isDockMode, activeGesture != nil {
                onDockModeChanged?(true)
            }
        }
        // Drags carry the live modifiers: a missed flags change can't leave
        // dock mode stuck.
        setDockMode(event.modifierFlags.contains(FloatGesture.dockModifier))
        guard let current = activeGesture, current.didBegin else { return }
        onGestureChanged?(FloatGesture.liveFrame(session: current.session, kind: current.kind, canvas: superview.bounds))
    }

    override func mouseUp(with event: NSEvent) {
        guard var gesture = activeGesture, let superview else { return }
        // The release itself is a sample: a pause before letting go reads as
        // a slow release, not as the last fast drag.
        gesture.session.move(to: superview.convert(event.locationInWindow, from: nil), timestamp: event.timestamp)
        endGestureTracking()
        let outcome = FloatGesture.outcome(
            session: gesture.session,
            kind: gesture.kind,
            canvas: superview.bounds,
            dockMode: gesture.isDockMode
        )
        if outcome == .click, gesture.startedOverLegend {
            hostedContainer?.onBorderContextClicked?(paneID)
        }
        onGestureEnded?(outcome, gesture.session.velocity)
    }

    /// Drops a live press without committing anything (Escape, the window
    /// resigning key, unmount). No-op when nothing is being tracked.
    func cancelGesture() {
        guard activeGesture != nil else { return }
        endGestureTracking()
        onGestureCancelled?()
    }

    var isGestureActiveForTesting: Bool {
        activeGesture != nil
    }

    var isDockModeForTesting: Bool {
        activeGesture?.isDockMode ?? false
    }

    /// Enters or leaves dock mode on the live move (⌥ toggled). Resizes
    /// never dock. The layer hears it once the drag has begun; a press that
    /// is still a click just remembers it.
    func setDockMode(_ isDockMode: Bool) {
        guard var gesture = activeGesture, gesture.kind == .move, gesture.isDockMode != isDockMode else {
            return
        }
        gesture.isDockMode = isDockMode
        activeGesture = gesture
        if gesture.didBegin {
            onDockModeChanged?(isDockMode)
        }
    }

    private func endGestureTracking() {
        activeGesture = nil
        for monitor in gestureMonitors {
            NSEvent.removeMonitor(monitor)
        }
        gestureMonitors.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    private func installGestureMonitors() {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self, self.activeGesture != nil else { return event }
            self.cancelGesture()
            return nil
        }) {
            gestureMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            guard let self, self.activeGesture != nil else { return event }
            self.setDockMode(event.modifierFlags.contains(FloatGesture.dockModifier))
            return event
        }) {
            gestureMonitors.append(monitor)
        }
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(gestureWindowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    @objc private func gestureWindowDidResignKey(_ notification: Notification) {
        cancelGesture()
    }
}
