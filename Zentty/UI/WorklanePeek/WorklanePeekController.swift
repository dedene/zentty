import AppKit
import QuartzCore

/// Subset of `WorklaneStore` surface the Worklane Peek needs. Lets logic
/// tests substitute a fake without dragging in the entire store.
@MainActor
protocol WorklanePeekWorklaneAccess: AnyObject {
    var worklanes: [WorklaneState] { get }
    var activeWorklaneID: WorklaneID { get }
    func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID)
}

extension WorklaneStore: WorklanePeekWorklaneAccess {}

/// How the view layer should move between the previous and current selection.
/// `.animated` triggers the spring camera pan; `.hardCut` skips animation
/// entirely so wraps from the last pane to the first don't sweep across the
/// whole list.
enum WorklanePeekSelectionTransition: Equatable {
    case animated
    case hardCut
}

@MainActor
protocol WorklanePeekControllerDelegate: AnyObject {
    func peekDidArm(_ controller: WorklanePeekController)
    func peekDidOpen(_ controller: WorklanePeekController)
    func peekDidUpdateSelection(
        _ controller: WorklanePeekController,
        transition: WorklanePeekSelectionTransition
    )
    func peekDidClose(_ controller: WorklanePeekController)
}

/// State machine for the Worklane Peek gesture.
///
/// Driven by Ctrl+Tab key events from two sources: the existing menu shortcut
/// on the first tap (when `.idle`), and the local `WorklanePeekKeyMonitor`
/// on subsequent taps once `.armed`. Side effects flow back to the
/// `WorklaneStore` for instant switches and final commit.
@MainActor
final class WorklanePeekController {
    enum Phase: Equatable {
        case idle
        /// Tap-versus-hold disambiguation window. The pane step from tap 1
        /// is deferred until either the user releases Ctrl (commit step) or
        /// the hold timer fires (open peek at the original pane, step is
        /// abandoned).
        case armed(armedAt: CFTimeInterval, pendingDirection: WorklanePeekDirection)
        case peeking(WorklanePeekSelectionState, traversal: WorklanePeekTraversal)
    }

    typealias Scheduler = (
        _ delay: TimeInterval,
        _ work: @escaping () -> Void
    ) -> () -> Void

    weak var delegate: WorklanePeekControllerDelegate?

    private(set) var phase: Phase = .idle

    private let worklaneAccess: WorklanePeekWorklaneAccess
    private let clock: () -> CFTimeInterval
    private let scheduler: Scheduler
    private let holdThreshold: TimeInterval
    private var pendingHoldTimerCancel: (() -> Void)?

    init(
        worklaneAccess: WorklanePeekWorklaneAccess,
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
    /// the key monitor (tap 2+, when armed or peeking). Phase-driven dispatch
    /// keeps the entry point uniform.
    func handleTab(forward: Bool) {
        let direction: WorklanePeekDirection = forward ? .forward : .backward

        switch phase {
        case .idle:
            // Defer the pane step until tap-vs-hold is disambiguated. The
            // pane only changes if the user releases Ctrl within the hold
            // window; if they keep holding, peek opens at the
            // *current* pane and the deferred step is abandoned.
            let armedAt = clock()
            phase = .armed(armedAt: armedAt, pendingDirection: direction)
            scheduleHoldTimer(for: armedAt)
            delegate?.peekDidArm(self)

        case let .armed(_, pendingDirection):
            // 2nd tap inside the hold window. We now know the user is
            // navigating fast, not holding. Commit the deferred step from
            // tap 1, open peek, then advance once more for tap 2 so each
            // tap still maps to one pane forward.
            cancelPendingHoldTimer()
            performInstantSwitch(direction: pendingDirection)
            openPeek()
            if case let .peeking(selection, traversal) = phase {
                let updated = selection.advancing(by: direction, traversal: traversal)
                if updated != selection {
                    let transition: WorklanePeekSelectionTransition =
                        traversal.wrapsAround(from: selection.current, direction: direction)
                            ? .hardCut : .animated
                    phase = .peeking(updated, traversal: traversal)
                    delegate?.peekDidUpdateSelection(self, transition: transition)
                }
            }

        case .peeking:
            advanceSelection(direction: direction)
        }
    }

    /// Called by the key monitor when Ctrl is released. Acts as commit while
    /// in peek, or completes the deferred tap step while armed.
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
        case let .peeking(selection, _):
            commit(focusing: selection.current)
        }
    }

    /// Called by the key monitor when Escape is pressed. Cancels peek
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
        case let .peeking(selection, _):
            commit(focusing: selection.original)
        }
    }

    /// Called by the overlay view when the user clicks a visible pane.
    /// Commits at that pane and closes peek.
    func handleClick(at reference: WorklaneStore.PaneReference) {
        guard case .peeking = phase else { return }
        commit(focusing: reference)
    }

    // MARK: - Internals

    private func performInstantSwitch(direction: WorklanePeekDirection) {
        // Move to the next pane in the linear traversal (same step the
        // peek picker would take). Naturally wraps across worklane
        // boundaries when crossing the end of a worklane's panes — the
        // gesture's granularity stays "one pane forward" regardless of
        // whether the user taps or holds.
        guard let current = currentPaneReference() else { return }
        let traversal = WorklanePeekTraversal.from(worklanes: worklaneAccess.worklanes)
        guard let next = traversal.step(from: current, direction: direction) else { return }
        worklaneAccess.selectWorklaneAndFocusPane(
            worklaneID: next.worklaneID,
            paneID: next.paneID
        )
    }

    private func openPeek() {
        guard let origin = currentPaneReference() else {
            phase = .idle
            return
        }
        let traversal = WorklanePeekTraversal.from(worklanes: worklaneAccess.worklanes)
        let selection = WorklanePeekSelectionState.opening(at: origin)
        phase = .peeking(selection, traversal: traversal)
        TerminalViewportDiagnostics.shared.record(
            .peekOpened,
            context: TerminalViewportDiagnostics.Context(
                paneID: origin.paneID,
                worklaneID: origin.worklaneID,
                laneRole: .activeCanvas
            )
        )
        delegate?.peekDidOpen(self)
    }

    private func advanceSelection(direction: WorklanePeekDirection) {
        guard case let .peeking(selection, traversal) = phase else { return }
        let updated = selection.advancing(by: direction, traversal: traversal)
        guard updated != selection else { return }
        let transition: WorklanePeekSelectionTransition =
            traversal.wrapsAround(from: selection.current, direction: direction)
                ? .hardCut : .animated
        phase = .peeking(updated, traversal: traversal)
        delegate?.peekDidUpdateSelection(self, transition: transition)
    }

    private func commit(focusing reference: WorklaneStore.PaneReference) {
        cancelPendingHoldTimer()
        phase = .idle
        TerminalViewportDiagnostics.shared.record(
            .peekCommit,
            context: TerminalViewportDiagnostics.Context(
                paneID: reference.paneID,
                worklaneID: reference.worklaneID,
                laneRole: .activeCanvas
            )
        )
        worklaneAccess.selectWorklaneAndFocusPane(
            worklaneID: reference.worklaneID,
            paneID: reference.paneID
        )
        delegate?.peekDidClose(self)
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
        // Hold detected — open peek at the *current* pane. The deferred
        // tap step is intentionally abandoned: pure tap-and-hold should
        // zoom out where you are without moving focus.
        openPeek()
    }

    private func cancelPendingHoldTimer() {
        pendingHoldTimerCancel?()
        pendingHoldTimerCancel = nil
    }
}
