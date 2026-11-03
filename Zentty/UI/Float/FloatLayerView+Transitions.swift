import AppKit
import QuartzCore

/// How a mounted float or PiP leaves (`FloatModeTransitionPlan.Departure`
/// with its target resolved in layer coordinates).
enum FloatDeparture: Equatable {
    /// Flies into `frame` (the pill) while it fades out.
    case toFrame(CGRect)
    case close
    case hide
}

/// How a float or PiP mounts (`FloatModeTransitionPlan.Entry` resolved).
enum FloatEntry: Equatable {
    /// Grows out of `frame` (the pill) while it fades in from 0.2.
    case fromFrame(CGRect)
    case reveal
}

/// Mode-change motion the canvas hands the layer for its next render (see
/// `FloatModeTransition`). A leaving float or PiP keeps drawing as a passive
/// copy of itself: its host view stays in the layer, out of the layer's
/// bookkeeping, hit-transparent, until its fade ends. The model has already
/// moved on. Motion is presentation only (AppKit resets model transforms), and
/// nothing is resized, so terminal grids never see the scaled sizes.
extension FloatLayerView {
    static let fadeAnimationKey = "zentty.float.fade"
    static let departureAnimationKey = "zentty.float.departure"

    @MainActor
    enum TransitionMotion {
        /// Float ⇄ pill (the mockup's `minimize`/`restore`).
        static let morphDuration: CFTimeInterval = 0.38
        /// Opacity the arriving picture starts from in a morph.
        static let morphStartOpacity: Float = 0.2
        static let closeDuration: CFTimeInterval = 0.16
        static let closeScale: CGFloat = 0.96
        static let closeTiming = CAMediaTimingFunction(name: .easeIn)
        /// Hide/Show Floating Panes.
        static let hideDuration: CFTimeInterval = 0.18
        static let hideScale: CGFloat = 0.97
        static let hideTiming = CAMediaTimingFunction(name: .default)
    }

    /// Motion for the next render's departures and entries. Consumed by that
    /// render; dropped if it doesn't unmount or mount the pane.
    func prepareTransitions(departures: [PaneID: FloatDeparture], entries: [PaneID: FloatEntry]) {
        pendingDepartures.merge(departures) { _, new in new }
        pendingEntries.merge(entries) { _, new in new }
    }

    /// Where each mounted float's pane rect and each PiP is drawn (layer
    /// coordinates), for the canvas's before-picture.
    func pictureFrames() -> [PaneID: CGRect] {
        var frames: [PaneID: CGRect] = [:]
        for (paneID, host) in floatHosts {
            frames[paneID] = host.paneFrame
        }
        for (paneID, pip) in pipHosts {
            frames[paneID] = pip.frame
        }
        return frames
    }

    // MARK: - Departures

    /// `view` (a float or PiP host, its container still inside) leaves with
    /// `departure`; `paneFrame` is a float host's pane rect.
    func beginDeparture(_ view: NSView, paneID: PaneID, departure: FloatDeparture, paneFrame: CGRect?) {
        finishDeparture(paneID)
        guard let layer = view.layer, window != nil, view.frame.width > 0, view.frame.height > 0 else {
            view.removeFromSuperview()
            return
        }
        (view as? FloatContainerView)?.isDeparting = true
        (view as? PipContainerView)?.isDeparting = true
        muteMouseTracking(ofDeparting: view)
        departingViews[paneID] = view

        let model = view.frame
        // A settle or spring still in flight: leave from where it is drawn.
        let startTransform = layer.presentation()?.transform ?? CATransform3DIdentity
        let startOpacity = layer.presentation()?.opacity ?? 1
        layer.removeAllAnimations()

        var visible: CGRect
        var duration: CFTimeInterval
        var timing: CAMediaTimingFunction
        switch departure {
        case .toFrame(let target):
            visible = paneFrame.map { Self.rect(model, mapping: $0, onto: target) } ?? target
            duration = TransitionMotion.morphDuration
            timing = FloatMotion.reflowTiming
        case .close:
            visible = FloatMotion.scaled(model, by: TransitionMotion.closeScale)
            duration = TransitionMotion.closeDuration
            timing = TransitionMotion.closeTiming
        case .hide:
            visible = FloatMotion.scaled(model, by: TransitionMotion.hideScale)
            duration = TransitionMotion.hideDuration
            timing = TransitionMotion.hideTiming
        }
        if FloatMotion.reduceMotion {
            // Reduce Motion: a short fade where it is, nothing moves.
            visible = model
            duration = FloatMotion.reducedDuration
            timing = FloatMotion.reducedTiming
        }

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: startTransform)
        transform.toValue = NSValue(
            caTransform3D: Self.transform(mapping: model, to: visible, anchorPoint: layer.anchorPoint)
        )
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = startOpacity
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        // Ends on the animation's own clock (a slowed layer, a debugger),
        // never before the copy is fully faded.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.departingViews[paneID] === view else { return }
                self.finishDeparture(paneID)
            }
        }
        layer.add(group, forKey: Self.departureAnimationKey)
        CATransaction.commit()
        onDepartureForTesting?(paneID, departure)
    }

    /// Drops `paneID`'s leaving copy now (its fade ended, or the pane mounts
    /// again and needs its terminal back).
    func finishDeparture(_ paneID: PaneID) {
        guard let view = departingViews.removeValue(forKey: paneID) else { return }
        view.layer?.removeAnimation(forKey: Self.departureAnimationKey)
        view.removeFromSuperview()
    }

    var departingPaneIDsForTesting: Set<PaneID> {
        Set(departingViews.keys)
    }

    // MARK: - Entries

    /// Motion for a float or PiP this render mounted fresh. A pending lift in
    /// place wins (it has its own motion); a PiP entering from a pill was
    /// handed to its spring already (`pendingPipEntries`).
    func animateEntry(_ paneID: PaneID, entry: FloatEntry) {
        if let host = floatHosts[paneID] {
            switch entry {
            case .fromFrame(let pillFrame):
                let visible = Self.rect(host.frame, mapping: host.paneFrame, onto: pillFrame)
                animateMorphIn(host, fromVisibleFrame: visible)
            case .reveal:
                animateReveal(host)
            }
        } else if let pip = pipHosts[paneID], entry == .reveal {
            animateReveal(pip)
        } else {
            return
        }
        onEntryForTesting?(paneID, entry)
    }

    /// Grows `view` from `fromVisibleFrame` (the pill) to its frame while it
    /// fades in from 0.2. Reduce Motion: a short crossfade in place.
    private func animateMorphIn(_ view: NSView, fromVisibleFrame: CGRect) {
        guard let layer = view.layer, view.frame.width > 0, view.frame.height > 0,
              fromVisibleFrame.width > 0, fromVisibleFrame.height > 0 else { return }
        guard !FloatMotion.reduceMotion else {
            crossfadeIn(view)
            return
        }
        animateSettle(
            view,
            fromVisibleFrame: fromVisibleFrame,
            velocity: .zero,
            spring: false,
            duration: TransitionMotion.morphDuration,
            timing: FloatMotion.reflowTiming
        )
        addFadeIn(to: layer, from: TransitionMotion.morphStartOpacity, duration: TransitionMotion.morphDuration)
    }

    /// Fades `view` in while it grows from 97%. Reduce Motion: the fade only.
    private func animateReveal(_ view: NSView) {
        guard let layer = view.layer, view.frame.width > 0, view.frame.height > 0 else { return }
        guard !FloatMotion.reduceMotion else {
            crossfadeIn(view)
            return
        }
        animateSettle(
            view,
            fromVisibleFrame: FloatMotion.scaled(view.frame, by: TransitionMotion.hideScale),
            velocity: .zero,
            spring: false,
            duration: TransitionMotion.hideDuration,
            timing: TransitionMotion.hideTiming
        )
        addFadeIn(to: layer, from: 0, duration: TransitionMotion.hideDuration)
    }

    /// Opacity from `start` to 1 under the fade key (a gesture drops it).
    func addFadeIn(to layer: CALayer, from start: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = start
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = FloatMotion.reflowTiming
        layer.add(animation, forKey: Self.fadeAnimationKey)
    }
}
