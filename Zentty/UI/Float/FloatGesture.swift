import AppKit

/// What a press on a float drives.
enum FloatGestureKind: Equatable, Sendable {
    case move
    case resize(FloatResizeHandle)
}

/// What a finished float gesture asks the store to do.
enum FloatGestureOutcome: Equatable, Sendable {
    /// The pointer barely moved: nothing changes.
    case click
    /// Commit the float at `frame` (float-layer coordinates).
    case move(frame: CGRect)
    case resize(frame: CGRect)
    /// Released fast enough toward a corner: becomes a PiP there.
    case throwToPip(corner: FloatCorner)
    /// Released in dock mode over a target: dock there. `frame` is where it
    /// was dropped (it stays a float there if the dock is refused).
    case dock(target: FloatDockTarget, frame: CGRect)
}

/// Pure ownership and outcome rules for float gestures. Coordinates are
/// y-up; `outsetBounds` is the float container's bounds (the pane grown by
/// `FloatContainerView.chromeOutset`), so the band straddles the border.
enum FloatGesture {
    /// Move/resize band, centred on the border line.
    static let band: CGFloat = 20
    static let cornerZone: CGFloat = 18
    static let anywhereMoveModifiers: NSEvent.ModifierFlags = [.control, .command]
    /// Held during a move (at mouse-down or toggled mid-drag): dock mode.
    static let dockModifier: NSEvent.ModifierFlags = .option

    /// Which gesture a press at `point` starts, or nil when the press belongs
    /// to the terminal (or to a legend button). Only left-mouse-downs are
    /// owned: every other event (hover, scroll, right click) passes through.
    static func ownership(
        at point: CGPoint,
        outsetBounds: CGRect,
        eventType: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        isOverBorderChrome: Bool
    ) -> FloatGestureKind? {
        guard eventType == .leftMouseDown, !isOverBorderChrome, outsetBounds.contains(point) else {
            return nil
        }
        let relevant = modifiers.intersection(.deviceIndependentFlagsMask)
        if relevant.isSuperset(of: anywhereMoveModifiers) {
            return .move
        }
        switch FloatFrameRegion.region(at: point, bounds: outsetBounds, band: band, cornerZone: cornerZone) {
        case .move:
            return .move
        case .resize(let handle):
            return .resize(handle)
        case .passthrough:
            return nil
        }
    }

    /// Whether a press starting `kind` with `modifiers` starts in dock mode.
    /// Only moves dock; ⌥ during a resize means nothing.
    static func startsDockMode(kind: FloatGestureKind, modifiers: NSEvent.ModifierFlags) -> Bool {
        kind == .move && modifiers.contains(dockModifier)
    }

    /// The live frame while dragging (also the basis of the end frame).
    static func liveFrame(session: FloatDragSession, kind: FloatGestureKind, canvas: CGRect) -> CGRect {
        switch kind {
        case .move:
            return FloatLayout.clamped(session.currentFrame, in: canvas)
        case .resize(let handle):
            return FloatLayout.clamped(
                FloatResizeMath.resizeAnchored(
                    handle: handle,
                    delta: session.translation,
                    frame: session.startFrame,
                    minSize: FloatResizeMath.minimumFloatSize,
                    canvas: canvas
                ),
                in: canvas
            )
        }
    }

    /// In dock mode a move never throws: the dock target (if any) is decided
    /// by the float layer, and without one the float stays where it dropped.
    static func outcome(
        session: FloatDragSession,
        kind: FloatGestureKind,
        canvas: CGRect,
        dockMode: Bool = false
    ) -> FloatGestureOutcome {
        guard !session.isClick else {
            return .click
        }
        switch kind {
        case .move:
            if !dockMode, let corner = FloatThrowProjection.throwCorner(
                velocity: session.velocity,
                position: session.currentCenter,
                in: canvas
            ) {
                return .throwToPip(corner: corner)
            }
            return .move(frame: wholePoints(liveFrame(session: session, kind: kind, canvas: canvas)))
        case .resize:
            return .resize(frame: wholePoints(liveFrame(session: session, kind: kind, canvas: canvas)))
        }
    }

    private static func wholePoints(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }
}
