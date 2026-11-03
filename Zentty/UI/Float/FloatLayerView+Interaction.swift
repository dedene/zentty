import AppKit
import QuartzCore

/// Float gestures and lift motion. Frames stay view-transient while a
/// gesture runs (`interactiveFrames`); the store hears exactly one outcome on
/// mouse-up through `onFloatGestureEnded`.
extension FloatLayerView {
    static let settleAnimationKey = "zentty.float.settle"

    /// The next mount of `paneID` starts at `fromTileFrame` (layer
    /// coordinates) and animates to its float frame with the strip reflow.
    /// Consumed by the next render; dropped if that render doesn't mount it.
    func prepareLift(paneID: PaneID, fromTileFrame: CGRect) {
        pendingLiftSources[paneID] = fromTileFrame
    }

    func wireGestures(of host: FloatContainerView) {
        let paneID = host.paneID
        host.onPressed = { [weak self] in
            self?.onFloatSelected?(paneID)
        }
        host.onGestureBegan = { [weak self] kind in
            self?.floatGestureBegan(paneID, kind: kind)
        }
        host.onGestureChanged = { [weak self] frame in
            self?.floatGestureChanged(paneID, frame: frame)
        }
        host.onGestureEnded = { [weak self] outcome, velocity in
            self?.floatGestureEnded(paneID, outcome: outcome, velocity: velocity)
        }
        host.onGestureCancelled = { [weak self] in
            self?.floatGestureCancelled(paneID)
        }
        host.onDockModeChanged = { [weak self] isDockMode in
            self?.floatDockModeChanged(paneID, isDockMode: isDockMode)
        }
    }

    // MARK: - Gesture phases

    private func floatGestureBegan(_ paneID: PaneID, kind: FloatGestureKind) {
        guard let host = floatHost(paneID) else { return }
        host.layer?.removeAnimation(forKey: Self.settleAnimationKey)
        host.layer?.removeAnimation(forKey: Self.fadeAnimationKey)
        interactiveFrames[paneID] = host.paneFrame
        guard kind == .move, !FloatMotion.reduceMotion else { return }
        let restingFrame = host.frame
        host.setLifted(true, animated: true)
        host.applyLiftScale(FloatMotion.liftScale(forWidth: host.paneFrame.width))
        animateSettle(
            host,
            fromVisibleFrame: restingFrame,
            velocity: .zero,
            spring: false,
            duration: FloatMotion.liftDuration,
            timing: FloatMotion.liftTiming
        )
    }

    private func floatGestureChanged(_ paneID: PaneID, frame: CGRect) {
        guard let host = floatHost(paneID) else { return }
        interactiveFrames[paneID] = frame
        host.setPaneFrame(frame)
        updateDock(host)
        updateFloatMouseOcclusion()
    }

    private func floatGestureEnded(_ paneID: PaneID, outcome: FloatGestureOutcome, velocity: CGVector) {
        let lastFrame = interactiveFrames.removeValue(forKey: paneID)
        let outcome = resolveDockRelease(paneID, outcome: outcome)
        if let host = floatHost(paneID) {
            let finalFrame: CGRect
            switch outcome {
            case .move(let frame), .resize(let frame), .dock(_, let frame):
                finalFrame = frame
            case .click:
                finalFrame = lastFrame ?? host.paneFrame
            case .throwToPip:
                // The float stays where it was let go; the PiP mount flies
                // it into the corner, seeded with the throw's velocity.
                finalFrame = lastFrame ?? host.paneFrame
                pendingPipEntries[paneID] = PipEntry(fromFrame: finalFrame, velocity: velocity)
            }
            settle(host, to: finalFrame, velocity: velocity)
            updateFloatMouseOcclusion()
        }
        onFloatGestureEnded?(paneID, outcome, bounds)
    }

    private func floatGestureCancelled(_ paneID: PaneID) {
        interactiveFrames.removeValue(forKey: paneID)
        endDockMode(paneID)
        guard let host = floatHost(paneID) else { return }
        settle(host, to: storeFrame(for: paneID) ?? host.paneFrame, velocity: .zero)
        updateFloatMouseOcclusion()
    }

    // MARK: - Settle

    /// Drops the lift and puts the float at `frame` (its model), then springs
    /// the drawing from where it was let go. Reduce Motion: a short ease, no
    /// overshoot.
    private func settle(_ host: FloatContainerView, to frame: CGRect, velocity: CGVector) {
        let visibleFrame = host.frame
        host.setLifted(false, animated: true)
        host.applyLiftScale(1)
        host.setPaneFrame(frame)
        let reduceMotion = FloatMotion.reduceMotion
        animateSettle(
            host,
            fromVisibleFrame: visibleFrame,
            velocity: velocity,
            spring: !reduceMotion,
            duration: FloatMotion.reducedDuration,
            timing: FloatMotion.reducedTiming
        )
    }

    /// Animates the view's layer from looking like `fromVisibleFrame` to its
    /// model frame with a presentation-only transform (AppKit resets model
    /// transforms on layout; an added animation is left alone). Floats use
    /// it to settle, PiPs to enter and leave their corner.
    func animateSettle(
        _ host: NSView,
        fromVisibleFrame: CGRect,
        velocity: CGVector,
        spring: Bool,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) {
        let modelFrame = host.frame
        guard let layer = host.layer, fromVisibleFrame != modelFrame,
              modelFrame.width > 0, modelFrame.height > 0 else {
            return
        }
        let from = Self.transform(mapping: modelFrame, to: fromVisibleFrame, anchorPoint: layer.anchorPoint)
        let animation: CABasicAnimation
        if spring {
            let parameters = FloatSnapSpring.parameters(
                from: CGPoint(x: fromVisibleFrame.midX, y: fromVisibleFrame.midY),
                to: CGPoint(x: modelFrame.midX, y: modelFrame.midY),
                gestureVelocity: velocity
            )
            let springAnimation = CASpringAnimation(keyPath: "transform")
            springAnimation.mass = parameters.mass
            springAnimation.stiffness = parameters.stiffness
            springAnimation.damping = parameters.damping
            springAnimation.initialVelocity = parameters.initialVelocity
            springAnimation.duration = springAnimation.settlingDuration
            animation = springAnimation
        } else {
            animation = CABasicAnimation(keyPath: "transform")
            animation.duration = duration
            animation.timingFunction = timing
        }
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(animation, forKey: Self.settleAnimationKey)
    }

    /// Reduce Motion stand-in for a fly between two places (float ↔ PiP):
    /// the view appears at its model frame with a short fade, nothing moves
    /// or scales. Shares the settle key, so a new gesture cancels it.
    func crossfadeIn(_ view: NSView) {
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = FloatMotion.reducedDuration
        animation.timingFunction = FloatMotion.reducedTiming
        layer.add(animation, forKey: Self.settleAnimationKey)
    }

    /// The layer transform that draws a layer laid out at `model` as `visible`
    /// (both in superlayer coordinates), for a layer with `anchorPoint`.
    static func transform(mapping model: CGRect, to visible: CGRect, anchorPoint: CGPoint) -> CATransform3D {
        let scaleX = visible.width / model.width
        let scaleY = visible.height / model.height
        let anchorX = anchorPoint.x * model.width
        let anchorY = anchorPoint.y * model.height
        // world(p) = origin + anchor + T(p - anchor); solve for T = S then +d.
        let dx = (visible.minX - model.minX) - (1 - scaleX) * anchorX
        let dy = (visible.minY - model.minY) - (1 - scaleY) * anchorY
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), scaleX, scaleY, 1)
    }

    // MARK: - Lift in place

    /// The container was just mounted at its tile frame with the tile's grid.
    /// Grow it to `frame` with the strip reflow; the grid follows once it
    /// lands.
    func animateLiftInPlace(paneID: PaneID, container: PaneContainerView, to frame: CGRect) {
        interactiveFrames.removeValue(forKey: paneID)
        guard let host = floatHost(paneID) else { return }
        container.suspendTerminalViewportSync(by: .floatLiftInPlace)
        layoutSubtreeIfNeeded()
        let motion = FloatMotion.reflowMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            context.timingFunction = motion.timing
            context.allowsImplicitAnimation = true
            host.setPaneFrame(frame)
            host.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self, weak container] in
            Task { @MainActor [weak self, weak container] in
                guard let self, let container else { return }
                // Always drop this lift's own hold. Sync resumes only if no
                // one else (a move's lift scale, a PiP) still scales it.
                let resumed = container.resumeTerminalViewportSync(by: .floatLiftInPlace)
                guard self.mountedContainer(paneID) === container,
                      container.superview is FloatContainerView else {
                    return
                }
                if resumed {
                    container.forceTerminalViewportSync()
                }
                self.onLiftInPlaceFinishedForTesting?(paneID)
            }
        }
    }
}
