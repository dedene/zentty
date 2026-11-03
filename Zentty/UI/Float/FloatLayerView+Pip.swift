import AppKit
import QuartzCore

/// Where a PiP flies in from: the float's frame (layer coordinates) and the
/// throw velocity that sent it (pt/s, zero for a button or shortcut).
struct PipEntry: Equatable {
    var fromFrame: CGRect
    var velocity: CGVector
    /// Out of a pill: the PiP also fades in from 0.2 (a morph).
    var fadesIn = false
}

/// PiP mounting: the enter/leave order from spike 0a, the unscaled prime of
/// a fresh container, and the corner spring in and out.
extension FloatLayerView {
    /// Mounts `container` as a PiP at `frame`, scaling `contentSize` (the
    /// float's unscaled size) into it. With `animatesMoves`, a mounted PiP
    /// whose slot changed (a neighbour left its corner, the pill bar came
    /// or went) springs to it; a PiP under a drag stays under the pointer.
    ///
    /// Order (spike 0a): a fresh container is first primed unscaled at the
    /// float size, so its grid matches the float and not whatever the
    /// surface last synced (a tile, an old canvas, a recipe default). Then
    /// `.pip` suspends sync, the container is re-parented and scaled.
    func mountPip(
        _ container: PaneContainerView,
        paneID: PaneID,
        frame: CGRect,
        contentSize: CGSize,
        isNew: Bool,
        animatesMoves: Bool = false
    ) {
        let floatHost = floatHosts[paneID]
        let entry = pendingPipEntries.removeValue(forKey: paneID)
            ?? floatHost.map { PipEntry(fromFrame: $0.paneFrame, velocity: .zero) }

        let pip: PipContainerView
        let isNewPip: Bool
        if let existing = pipHosts[paneID] {
            pip = existing
            isNewPip = false
        } else {
            pip = makePipHost(paneID)
            isNewPip = true
        }
        if isNew {
            primeUnscaled(container, contentSize: contentSize)
        }
        pip.host(container, contentSize: contentSize)
        if let floatHost = floatHosts.removeValue(forKey: paneID) {
            floatHost.cancelGesture()
            floatHost.relinquishHostedContainer()
            floatHost.removeFromSuperview()
        }
        if isNewPip {
            // A float's gesture frame; a PiP's own drag frame is kept.
            interactiveFrames.removeValue(forKey: paneID)
        }
        let previousFrame = pipRestingFrames[paneID]
        pipRestingFrames[paneID] = frame
        if let corner = pipCorner(paneID) {
            pip.corner = corner
        }
        pip.configure(status: content.pipStatusByPaneID[paneID], theme: currentTheme)
        let drawnBefore = pip.frame
        let dragFrame = interactiveFrames[paneID]
        pip.apply(frame: dragFrame ?? frame, contentSize: contentSize)
        let moved = previousFrame != nil && previousFrame != frame
        if let entry, isNewPip || moved {
            animateEnter(pip, from: entry, isModeChange: isNewPip)
        } else if animatesMoves, moved, dragFrame == nil {
            animateEnter(pip, from: PipEntry(fromFrame: drawnBefore, velocity: .zero), isModeChange: false)
        }
    }

    private func pipCorner(_ paneID: PaneID) -> FloatCorner? {
        guard let float = content.floats.first(where: { $0.pane.id == paneID }),
              case .pip(let corner, _) = float.mode else {
            return nil
        }
        return corner
    }

    /// Refreshes the PiPs' status strips without a canvas render.
    func updatePipStatuses(_ statuses: [PaneID: PillBarItem]) {
        for (paneID, pip) in pipHosts {
            guard let status = statuses[paneID] else { continue }
            pip.configure(status: status, theme: currentTheme)
        }
    }

    private func makePipHost(_ paneID: PaneID) -> PipContainerView {
        let pip = PipContainerView(paneID: paneID)
        pip.onClicked = { [weak self] id in
            self?.onPipClicked?(id)
        }
        pip.onActionRequested = { [weak self] id, action in
            self?.onFloatActionRequested?(id, action)
        }
        wirePipGestures(of: pip)
        if let shortcutManager {
            pip.updateShortcutTooltips(shortcutManager)
        }
        pipHosts[paneID] = pip
        addSubview(pip)
        return pip
    }

    /// Lets a freshly created container sync its grid at the float size
    /// while it still sits unscaled in this layer (`owner` is the suspension
    /// it was created under). Runs in one pass with the re-parent into the
    /// PiP or peek, so it is never drawn here. Needs a window: without one
    /// the backing scale (and so the grid) would be a guess.
    func primeUnscaled(
        _ container: PaneContainerView,
        contentSize: CGSize,
        owner: TerminalViewportSuspensionOwner = .pip
    ) {
        guard window != nil, contentSize.width > 0, contentSize.height > 0 else { return }
        container.frame = CGRect(origin: .zero, size: contentSize)
        if container.superview !== self {
            container.removeFromSuperview()
            addSubview(container)
        }
        if container.resumeTerminalViewportSync(by: owner) {
            container.forceTerminalViewportSync()
        }
    }

    // MARK: - Motion

    /// The PiP springs from the float's frame into its corner (the throw's
    /// velocity carries over). Reduce Motion: a float becoming a PiP
    /// (`isModeChange`) crossfades in at its corner; a PiP moving between
    /// slots (restack, drag, swipe) takes a short ease, no overshoot.
    private func animateEnter(_ pip: PipContainerView, from entry: PipEntry, isModeChange: Bool) {
        guard entry.fromFrame.width > 0, entry.fromFrame.height > 0 else { return }
        let reduceMotion = FloatMotion.reduceMotion
        if reduceMotion, isModeChange {
            crossfadeIn(pip)
        } else {
            if entry.fadesIn, let layer = pip.layer {
                addFadeIn(
                    to: layer,
                    from: TransitionMotion.morphStartOpacity,
                    duration: TransitionMotion.morphDuration
                )
            }
            animateSettle(
                pip,
                fromVisibleFrame: entry.fromFrame,
                velocity: entry.velocity,
                spring: !reduceMotion,
                duration: FloatMotion.reducedDuration,
                timing: FloatMotion.reducedTiming
            )
        }
        onPipMotionForTesting?(pip.paneID, entry.fromFrame)
    }

    /// The float springs from the PiP's corner back to its last float frame.
    /// The host's model frame is already final and the grid unscaled; only
    /// the drawing moves. Reduce Motion: a short crossfade in place.
    func animateRestore(_ host: FloatContainerView, fromPipFrame pipFrame: CGRect) {
        let paneFrame = host.paneFrame
        guard paneFrame.width > 0, paneFrame.height > 0, pipFrame.width > 0, pipFrame.height > 0 else { return }
        let visible = Self.rect(host.frame, mapping: paneFrame, onto: pipFrame)
        if FloatMotion.reduceMotion {
            // Reduce Motion: the float fades in where it lands.
            crossfadeIn(host)
        } else {
            animateSettle(
                host,
                fromVisibleFrame: visible,
                velocity: .zero,
                spring: true,
                duration: FloatMotion.reducedDuration,
                timing: FloatMotion.reducedTiming
            )
        }
        onPipMotionForTesting?(host.paneID, visible)
    }

    /// `rect` moved by the scale-and-translate that takes `source` onto
    /// `target` (the float host's outset frame drawn where its pane rect
    /// lands on the PiP).
    static func rect(_ rect: CGRect, mapping source: CGRect, onto target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return CGRect(
            x: target.minX + (rect.minX - source.minX) * scaleX,
            y: target.minY + (rect.minY - source.minY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}
