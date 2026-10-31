import AppKit

/// Dock mode (⌥ during a float move): the coordinator draws the target under
/// the pointer, the float turns translucent, and a release over a target
/// becomes a `.dock` outcome instead of a move.
extension FloatLayerView {
    /// Float opacity while it is being docked.
    static let dockModeAlpha: CGFloat = 0.55

    func floatDockModeChanged(_ paneID: PaneID, isDockMode: Bool) {
        guard let host = floatHost(paneID) else { return }
        if isDockMode {
            let cursor = host.activeGesture?.session.lastMouse
                ?? CGPoint(x: host.paneFrame.midX, y: host.paneFrame.midY)
            dockCoordinator.enter(paneID: paneID, cursor: cursor)
            setDockAlpha(Self.dockModeAlpha, on: host)
        } else {
            endDockMode(paneID)
        }
    }

    /// Follows the pointer of a live dock-mode move.
    func updateDock(_ host: FloatContainerView) {
        guard dockCoordinator.isActive, let gesture = host.activeGesture, gesture.isDockMode else { return }
        dockCoordinator.update(cursor: gesture.session.lastMouse)
    }

    /// A move released in dock mode becomes `.dock` when the coordinator
    /// still resolves a target at the release point; otherwise the plain
    /// outcome stands (the float stays where it dropped, also when it was let
    /// go outside the canvas). Always leaves dock mode.
    func resolveDockRelease(_ paneID: PaneID, outcome: FloatGestureOutcome) -> FloatGestureOutcome {
        guard dockCoordinator.isActive else {
            endDockMode(paneID)
            return outcome
        }
        var resolved = outcome
        if case .move(let frame) = outcome,
           let target = dockCoordinator.commit(
               cursor: floatHost(paneID)?.lastReleasePoint ?? dockCoordinator.lastCursor
           ) {
            resolved = .dock(target: target, frame: frame)
        }
        endDockMode(paneID)
        return resolved
    }

    func endDockMode(_ paneID: PaneID) {
        dockCoordinator.cancel()
        if let host = floatHost(paneID) {
            setDockAlpha(1, on: host)
        }
    }

    private func setDockAlpha(_ alpha: CGFloat, on host: FloatContainerView) {
        guard host.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatMotion.reduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            host.alphaValue = alpha
        }
    }
}
