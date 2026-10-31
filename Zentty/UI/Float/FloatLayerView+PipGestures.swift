import AppKit
import QuartzCore

/// PiP drag and two-finger swipe. While a PiP is dragged its frame is
/// view-transient (`interactiveFrames`); on release it settles at its corner
/// and the store hears the corner it was sent to through
/// `onPipMoveRequested` (a no-op ask when it stays put).
extension FloatLayerView {
    /// A swipe's bounce: there and back in one motion.
    static let pipBounceDuration: CFTimeInterval = 0.42
    static let pipBounceTiming = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.3, 1)

    func wirePipGestures(of pip: PipContainerView) {
        pip.onDragBegan = { [weak self] paneID in
            self?.pipDragBegan(paneID)
        }
        pip.onDragChanged = { [weak self] paneID, frame in
            self?.pipDragChanged(paneID, frame: frame)
        }
        pip.onDragEnded = { [weak self] paneID, frame, velocity in
            self?.pipDragEnded(paneID, frame: frame, velocity: velocity)
        }
        pip.onDragCancelled = { [weak self] paneID in
            self?.pipDragCancelled(paneID)
        }
        pip.onSwipe = { [weak self] paneID, action in
            self?.pipSwiped(paneID, action: action)
        }
    }

    /// Where PiPs live: the layer above the pill bar. The release corner is
    /// the quadrant of this rect.
    var pipCanvas: CGRect {
        let inset = min(max(0, bottomInset), bounds.height)
        return CGRect(x: bounds.minX, y: bounds.minY + inset, width: bounds.width, height: bounds.height - inset)
    }

    // MARK: - Drag

    private func pipDragBegan(_ paneID: PaneID) {
        guard let pip = pipHosts[paneID] else { return }
        pip.layer?.removeAnimation(forKey: Self.settleAnimationKey)
        interactiveFrames[paneID] = pip.modelFrame
        // Above the floats while it moves (layer order only: no re-parent).
        pip.layer?.zPosition = 1
        guard !FloatMotion.reduceMotion else { return }
        let resting = pip.frame
        pip.setLifted(true)
        animateSettle(
            pip,
            fromVisibleFrame: resting,
            velocity: .zero,
            spring: false,
            duration: FloatMotion.liftDuration,
            timing: FloatMotion.liftTiming
        )
    }

    private func pipDragChanged(_ paneID: PaneID, frame: CGRect) {
        guard let pip = pipHosts[paneID] else { return }
        let clamped = FloatLayout.clamped(frame, in: bounds)
        interactiveFrames[paneID] = clamped
        pip.apply(frame: clamped, contentSize: pip.contentSize)
    }

    /// Momentum projection picks the corner: the quadrant the PiP's centre
    /// would coast to.
    private func pipDragEnded(_ paneID: PaneID, frame: CGRect, velocity: CGVector) {
        guard let pip = pipHosts[paneID] else { return }
        let released = interactiveFrames.removeValue(forKey: paneID) ?? FloatLayout.clamped(frame, in: bounds)
        let corner = FloatThrowProjection.pipReleaseCorner(
            center: CGPoint(x: released.midX, y: released.midY),
            velocity: velocity,
            in: pipCanvas
        )
        movePip(pip, to: corner, velocity: velocity)
    }

    private func pipDragCancelled(_ paneID: PaneID) {
        interactiveFrames.removeValue(forKey: paneID)
        guard let pip = pipHosts[paneID] else { return }
        settlePip(pip, velocity: .zero)
    }

    // MARK: - Swipe

    /// Reduce Motion: no rubber band and no bounce; a flick still moves it.
    private func pipSwiped(_ paneID: PaneID, action: PipSwipeResolver.Action) {
        guard let pip = pipHosts[paneID], pip.drag == nil else { return }
        let reduceMotion = FloatMotion.reduceMotion
        switch action {
        case .none:
            break
        case .follow(let offset):
            guard !reduceMotion else { return }
            pip.layer?.removeAnimation(forKey: Self.settleAnimationKey)
            pip.setSwipeOffset(offset)
        case .settle:
            guard pip.swipeOffset != .zero else { return }
            settlePip(pip, velocity: .zero)
        case .bounce(let toward):
            onPipTouched?(paneID)
            guard !reduceMotion else {
                settlePip(pip, velocity: .zero)
                return
            }
            bounce(pip, toward: toward)
        case .flick(let corner):
            movePip(pip, to: corner, velocity: .zero)
        }
    }

    // MARK: - Settle

    /// Settles `pip` at its resting frame, then asks the store for `corner`.
    /// When the store moves it, the re-render springs it from the same
    /// drawn frame into its new slot (`mountPip` takes the pending entry);
    /// when it stays (same corner, a blocked command) it is already home.
    private func movePip(_ pip: PipContainerView, to corner: FloatCorner, velocity: CGVector) {
        let paneID = pip.paneID
        let visible = pip.frame
        onPipTouched?(paneID)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak pip] in
            pip?.layer?.zPosition = 0
        }
        settlePip(pip, velocity: velocity, resetsLayerOrder: false)
        if corner != pip.corner {
            pendingPipEntries[paneID] = PipEntry(fromFrame: visible, velocity: velocity)
            onPipMoveRequested?(paneID, corner)
            pendingPipEntries.removeValue(forKey: paneID)
        }
        CATransaction.commit()
        onPipSettledForTesting?(paneID, corner)
    }

    /// Drops the lift and the rubber band and springs the drawing from where
    /// it was to the resting frame. Reduce Motion: a short ease.
    private func settlePip(_ pip: PipContainerView, velocity: CGVector, resetsLayerOrder: Bool = true) {
        let visible = pip.frame
        if resetsLayerOrder {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak pip] in
                pip?.layer?.zPosition = 0
            }
        }
        pip.setLifted(false)
        pip.setSwipeOffset(.zero)
        pip.apply(frame: pipRestingFrames[pip.paneID] ?? pip.modelFrame, contentSize: pip.contentSize)
        let reduceMotion = FloatMotion.reduceMotion
        animateSettle(
            pip,
            fromVisibleFrame: visible,
            velocity: velocity,
            spring: !reduceMotion,
            duration: FloatMotion.reducedDuration,
            timing: FloatMotion.reducedTiming
        )
        if resetsLayerOrder {
            CATransaction.commit()
        }
    }

    /// Toward a wall it already touches: from the rubber band out to
    /// `toward` and back home.
    private func bounce(_ pip: PipContainerView, toward: CGVector) {
        let offset = pip.swipeOffset
        pip.setSwipeOffset(.zero)
        guard let layer = pip.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [offset, toward, .zero].map {
            NSValue(caTransform3D: CATransform3DMakeTranslation($0.dx, $0.dy, 0))
        }
        animation.keyTimes = [0, 0.35, 1]
        animation.timingFunctions = [Self.pipBounceTiming, Self.pipBounceTiming]
        animation.duration = Self.pipBounceDuration
        layer.add(animation, forKey: Self.settleAnimationKey)
    }
}
