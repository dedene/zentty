import AppKit
import QuartzCore

/// A pill whose pane closed fades out where it sat, with the close motion of
/// a float (160ms, fade and shrink to 96%; Reduce Motion: a short fade).
/// Presentation only: it is out of the bar's pills at once, takes no events,
/// and the bar stays up until it is gone.
extension PillBarView {
    static let closingAnimationKey = "zentty.pill.closing"

    func beginClosing(_ view: PillView, paneID: PaneID) {
        finishClosing(paneID)
        view.onHoverChanged = nil
        view.onPress = nil
        view.onAction = nil
        guard window != nil, !view.isHidden, let layer = view.layer,
              view.frame.width > 0, view.frame.height > 0 else {
            view.removeFromSuperview()
            return
        }
        closingPills[paneID] = view

        let motion = FloatLayerView.TransitionMotion.self
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = layer.presentation()?.opacity ?? 1
        opacity.toValue = 0
        let group = CAAnimationGroup()
        if FloatMotion.reduceMotion {
            group.animations = [opacity]
            group.duration = FloatMotion.reducedDuration
            group.timingFunction = FloatMotion.reducedTiming
        } else {
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            transform.toValue = NSValue(caTransform3D: FloatLayerView.transform(
                mapping: view.frame,
                to: FloatMotion.scaled(view.frame, by: motion.closeScale),
                anchorPoint: layer.anchorPoint
            ))
            group.animations = [transform, opacity]
            group.duration = motion.closeDuration
            group.timingFunction = motion.closeTiming
        }
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, self.closingPills[paneID] === view else { return }
                self.finishClosing(paneID)
            }
        }
        layer.add(group, forKey: Self.closingAnimationKey)
        CATransaction.commit()
    }

    /// Drops `paneID`'s fading pill now (its fade ended, or the pane is a
    /// pill again).
    func finishClosing(_ paneID: PaneID) {
        guard let view = closingPills.removeValue(forKey: paneID) else { return }
        view.layer?.removeAnimation(forKey: Self.closingAnimationKey)
        view.removeFromSuperview()
        updateVisibility()
    }

    /// Shown while it has pills, or pills still fading out.
    func updateVisibility() {
        isHidden = content.isEmpty && closingPills.isEmpty
    }

    var closingPaneIDsForTesting: Set<PaneID> {
        Set(closingPills.keys)
    }
}
