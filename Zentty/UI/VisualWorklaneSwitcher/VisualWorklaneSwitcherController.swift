import AppKit
import QuartzCore

/// Subset of `WorklaneStore` surface the visual switcher needs. Lets logic
/// tests substitute a fake without dragging in the entire store.
@MainActor
protocol VisualSwitcherWorklaneAccess: AnyObject {
    var worklanes: [WorklaneState] { get }
    var activeWorklaneID: WorklaneID { get }
    func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID)
}

extension WorklaneStore: VisualSwitcherWorklaneAccess {}

@MainActor
protocol VisualWorklaneSwitcherControllerDelegate: AnyObject {
    func switcherDidArm(_ controller: VisualWorklaneSwitcherController)
    func switcherDidOpenVisualMode(_ controller: VisualWorklaneSwitcherController)
    func switcherDidUpdateSelection(_ controller: VisualWorklaneSwitcherController)
    func switcherDidCloseVisualMode(_ controller: VisualWorklaneSwitcherController)
}

/// State machine for the visual worklane switcher gesture.
///
/// Driven by Ctrl+Tab key events from two sources: the existing menu shortcut
/// on the first tap (when `.idle`), and the local `VisualSwitcherKeyMonitor`
/// on subsequent taps once `.armed`. Side effects flow back to the
/// `WorklaneStore` for instant switches and final commit.
@MainActor
final class VisualWorklaneSwitcherController {
    enum Phase: Equatable {
        case idle
        /// Tap-versus-hold disambiguation window. The pane step from tap 1
        /// is deferred until either the user releases Ctrl (commit step) or
        /// the hold timer fires (open visual at the original pane, step is
        /// abandoned).
        case armed(armedAt: CFTimeInterval, pendingDirection: VisualSwitcherDirection)
        case visualMode(VisualSwitcherSelectionState, traversal: VisualSwitcherTraversal)
    }

    typealias Scheduler = (
        _ delay: TimeInterval,
        _ work: @escaping () -> Void
    ) -> () -> Void

    weak var delegate: VisualWorklaneSwitcherControllerDelegate?

    private(set) var phase: Phase = .idle

    private let worklaneAccess: VisualSwitcherWorklaneAccess
    private let clock: () -> CFTimeInterval
    private let scheduler: Scheduler
    private let holdThreshold: TimeInterval
    private var pendingHoldTimerCancel: (() -> Void)?

    init(
        worklaneAccess: VisualSwitcherWorklaneAccess,
        clock: @escaping () -> CFTimeInterval = { CACurrentMediaTime() },
        scheduler: Scheduler? = nil,
        holdThreshold: TimeInterval = 0.2
    ) {
        self.worklaneAccess = worklaneAccess
        self.clock = clock
        self.scheduler = scheduler ?? { delay, work in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                work()
            }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
        self.holdThreshold = holdThreshold
    }

    // MARK: - Public events

    /// Called by both the menu shortcut (tap 1, when phase is `.idle`) and by
    /// the key monitor (tap 2+, when armed or visual). Phase-driven dispatch
    /// keeps the entry point uniform.
    func handleTab(forward: Bool) {
        let direction: VisualSwitcherDirection = forward ? .forward : .backward

        switch phase {
        case .idle:
            // Defer the pane step until tap-vs-hold is disambiguated. The
            // pane only changes if the user releases Ctrl within the hold
            // window; if they keep holding, visual mode opens at the
            // *current* pane and the deferred step is abandoned.
            let armedAt = clock()
            phase = .armed(armedAt: armedAt, pendingDirection: direction)
            scheduleHoldTimer(for: armedAt)
            delegate?.switcherDidArm(self)

        case let .armed(_, pendingDirection):
            // 2nd tap inside the hold window. We now know the user is
            // navigating fast, not holding. Commit the deferred step from
            // tap 1, open visual, then advance once more for tap 2 so each
            // tap still maps to one pane forward.
            cancelPendingHoldTimer()
            performInstantSwitch(direction: pendingDirection)
            openVisualMode()
            if case let .visualMode(selection, traversal) = phase {
                let updated = selection.advancing(by: direction, traversal: traversal)
                if updated != selection {
                    phase = .visualMode(updated, traversal: traversal)
                    delegate?.switcherDidUpdateSelection(self)
                }
            }

        case .visualMode:
            advanceSelection(direction: direction)
        }
    }

    /// Called by the key monitor when Ctrl is released. Acts as commit while
    /// in visual mode, or completes the deferred tap step while armed.
    func handleCtrlReleased() {
        switch phase {
        case .idle:
            break
        case let .armed(_, pendingDirection):
            // Released within the hold window — disambiguated as a quick
            // tap. Perform the deferred step now.
            cancelPendingHoldTimer()
            performInstantSwitch(direction: pendingDirection)
            phase = .idle
        case let .visualMode(selection, _):
            commit(focusing: selection.current)
        }
    }

    /// Called by the key monitor when Escape is pressed. Cancels visual mode
    /// (restoring the originally-focused pane) or aborts a pending tap step
    /// if pressed during the hold window.
    func handleEscape() {
        switch phase {
        case .idle:
            break
        case .armed:
            // Aborts the deferred step entirely.
            cancelPendingHoldTimer()
            phase = .idle
        case let .visualMode(selection, _):
            commit(focusing: selection.original)
        }
    }

    /// Called by the overlay view when the user clicks a visible pane.
    /// Commits at that pane and closes visual mode.
    func handleClick(at reference: WorklaneStore.PaneReference) {
        guard case .visualMode = phase else { return }
        commit(focusing: reference)
    }

    // MARK: - Internals

    private func performInstantSwitch(direction: VisualSwitcherDirection) {
        // Move to the next pane in the linear traversal (same step the
        // visual picker would take). Naturally wraps across worklane
        // boundaries when crossing the end of a worklane's panes — the
        // gesture's granularity stays "one pane forward" regardless of
        // whether the user taps or holds.
        guard let current = currentPaneReference() else { return }
        let traversal = VisualSwitcherTraversal.from(worklanes: worklaneAccess.worklanes)
        guard let next = traversal.step(from: current, direction: direction) else { return }
        worklaneAccess.selectWorklaneAndFocusPane(
            worklaneID: next.worklaneID,
            paneID: next.paneID
        )
    }

    private func openVisualMode() {
        guard let origin = currentPaneReference() else {
            phase = .idle
            return
        }
        let traversal = VisualSwitcherTraversal.from(worklanes: worklaneAccess.worklanes)
        let selection = VisualSwitcherSelectionState.opening(at: origin)
        phase = .visualMode(selection, traversal: traversal)
        delegate?.switcherDidOpenVisualMode(self)
    }

    private func advanceSelection(direction: VisualSwitcherDirection) {
        guard case let .visualMode(selection, traversal) = phase else { return }
        let updated = selection.advancing(by: direction, traversal: traversal)
        guard updated != selection else { return }
        phase = .visualMode(updated, traversal: traversal)
        delegate?.switcherDidUpdateSelection(self)
    }

    private func commit(focusing reference: WorklaneStore.PaneReference) {
        cancelPendingHoldTimer()
        phase = .idle
        worklaneAccess.selectWorklaneAndFocusPane(
            worklaneID: reference.worklaneID,
            paneID: reference.paneID
        )
        delegate?.switcherDidCloseVisualMode(self)
    }

    private func currentPaneReference() -> WorklaneStore.PaneReference? {
        let activeID = worklaneAccess.activeWorklaneID
        guard let worklane = worklaneAccess.worklanes.first(where: { $0.id == activeID }),
              let paneID = worklane.paneStripState.focusedPaneID
        else { return nil }
        return WorklaneStore.PaneReference(worklaneID: activeID, paneID: paneID)
    }

    private func scheduleHoldTimer(for armedAt: CFTimeInterval) {
        cancelPendingHoldTimer()
        pendingHoldTimerCancel = scheduler(holdThreshold) { [weak self] in
            // Both the default Timer-based scheduler and the test scheduler
            // invoke work on the main thread, so the assume-isolated synchronous
            // hop is safe and avoids the latency of an async Task dispatch.
            MainActor.assumeIsolated {
                self?.handleHoldTimerFired(armedAt: armedAt)
            }
        }
    }

    private func handleHoldTimerFired(armedAt: CFTimeInterval) {
        // Confirm the timer corresponds to the current arming, not a stale
        // closure left over from a previous gesture.
        guard case let .armed(actualArmedAt, _) = phase, actualArmedAt == armedAt else {
            return
        }
        pendingHoldTimerCancel = nil
        // Hold detected — open visual at the *current* pane. The deferred
        // tap step is intentionally abandoned: pure tap-and-hold should
        // zoom out where you are without moving focus.
        openVisualMode()
    }

    private func cancelPendingHoldTimer() {
        pendingHoldTimerCancel?()
        pendingHoldTimerCancel = nil
    }
}
