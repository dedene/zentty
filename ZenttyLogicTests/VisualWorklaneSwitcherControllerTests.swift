import XCTest
@testable import Zentty

@MainActor
final class VisualWorklaneSwitcherControllerTests: XCTestCase {

    // MARK: - Fixtures

    private func makePane(_ id: String) -> PaneState {
        PaneState(id: PaneID(id), title: id)
    }

    private func makeWorklane(_ id: String, panes: [String], focused: String?) -> WorklaneState {
        let paneStates = panes.map { makePane($0) }
        let focusedID = focused.map { PaneID($0) }
        return WorklaneState(
            id: WorklaneID(id),
            title: id,
            paneStripState: PaneStripState(panes: paneStates, focusedPaneID: focusedID)
        )
    }

    private func ref(_ worklane: String, _ pane: String) -> WorklaneStore.PaneReference {
        WorklaneStore.PaneReference(worklaneID: WorklaneID(worklane), paneID: PaneID(pane))
    }

    // MARK: - Test scaffolding

    @MainActor
    final class FakeWorklaneAccess: VisualSwitcherWorklaneAccess {
        var worklanes: [WorklaneState] = []
        var activeWorklaneID: WorklaneID = WorklaneID("")

        var nextSwitchCount = 0
        var previousSwitchCount = 0
        var focusCalls: [(worklaneID: WorklaneID, paneID: PaneID)] = []

        func selectNextWorklane() {
            nextSwitchCount += 1
            advanceActive(by: 1)
        }

        func selectPreviousWorklane() {
            previousSwitchCount += 1
            advanceActive(by: -1)
        }

        func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID) {
            focusCalls.append((worklaneID, paneID))
            activeWorklaneID = worklaneID
            if let i = worklanes.firstIndex(where: { $0.id == worklaneID }) {
                worklanes[i].paneStripState.focusPane(id: paneID)
            }
        }

        private func advanceActive(by offset: Int) {
            guard !worklanes.isEmpty,
                  let i = worklanes.firstIndex(where: { $0.id == activeWorklaneID })
            else { return }
            let count = worklanes.count
            let next = (i + offset + count) % count
            activeWorklaneID = worklanes[next].id
        }
    }

    @MainActor
    final class TestScheduler {
        struct PendingWork {
            let delay: TimeInterval
            let work: () -> Void
        }

        private var nextID = 0
        private(set) var pending: [Int: PendingWork] = [:]

        func make() -> VisualWorklaneSwitcherController.Scheduler {
            return { [weak self] delay, work in
                guard let self else { return {} }
                self.nextID += 1
                let id = self.nextID
                self.pending[id] = PendingWork(delay: delay, work: work)
                return { [weak self] in self?.pending.removeValue(forKey: id) }
            }
        }

        func fireAll() {
            let snapshot = pending
            pending.removeAll()
            for entry in snapshot.values {
                entry.work()
            }
        }

        var hasPending: Bool { !pending.isEmpty }
    }

    @MainActor
    final class RecordingDelegate: VisualWorklaneSwitcherControllerDelegate {
        var armed = 0
        var opened = 0
        var updates = 0
        var closed = 0

        func switcherDidArm(_ controller: VisualWorklaneSwitcherController) { armed += 1 }
        func switcherDidOpenVisualMode(_ controller: VisualWorklaneSwitcherController) { opened += 1 }
        func switcherDidUpdateSelection(_ controller: VisualWorklaneSwitcherController) { updates += 1 }
        func switcherDidCloseVisualMode(_ controller: VisualWorklaneSwitcherController) { closed += 1 }
    }

    private struct Harness {
        let access: FakeWorklaneAccess
        let scheduler: TestScheduler
        let delegate: RecordingDelegate
        let controller: VisualWorklaneSwitcherController
        var time: CFTimeInterval
    }

    private func makeHarness(
        worklanes: [WorklaneState],
        active: String,
        holdThreshold: TimeInterval = 0.2
    ) -> Harness {
        let access = FakeWorklaneAccess()
        access.worklanes = worklanes
        access.activeWorklaneID = WorklaneID(active)

        let scheduler = TestScheduler()
        let delegate = RecordingDelegate()

        var nowBox = CFTimeInterval(0)
        let clock: () -> CFTimeInterval = { nowBox }

        let controller = VisualWorklaneSwitcherController(
            worklaneAccess: access,
            clock: clock,
            scheduler: scheduler.make(),
            holdThreshold: holdThreshold
        )
        controller.delegate = delegate

        return Harness(
            access: access,
            scheduler: scheduler,
            delegate: delegate,
            controller: controller,
            time: nowBox
        )
    }

    // MARK: - First tap (idle → armed)

    func test_first_tab_in_idle_does_instant_switch_and_arms() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)

        XCTAssertEqual(harness.access.nextSwitchCount, 1)
        XCTAssertEqual(harness.access.activeWorklaneID, WorklaneID("w2"))
        XCTAssertEqual(harness.delegate.armed, 1)
        XCTAssertEqual(harness.delegate.opened, 0)
        if case .armed = harness.controller.phase {} else {
            XCTFail("expected armed phase, got \(harness.controller.phase)")
        }
        XCTAssertTrue(harness.scheduler.hasPending, "hold timer should be scheduled")
    }

    func test_first_tab_backward_uses_previous_switch() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w2"
        )

        harness.controller.handleTab(forward: false)

        XCTAssertEqual(harness.access.previousSwitchCount, 1)
        XCTAssertEqual(harness.access.activeWorklaneID, WorklaneID("w1"))
    }

    // MARK: - Hold timer fires (armed → visualMode)

    func test_hold_timer_fires_opens_visual_at_focused_pane() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c", "d"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)
        // Active is now w2 (focused: c).
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.delegate.opened, 1)
        guard case let .visualMode(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w2", "c"))
        XCTAssertEqual(selection.original, ref("w2", "c"))
    }

    // MARK: - Second tap opens visual without re-switching

    func test_second_tab_while_armed_opens_visual_without_extra_switch() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
                makeWorklane("w3", panes: ["e"], focused: "e"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)
        XCTAssertEqual(harness.access.nextSwitchCount, 1) // w1 → w2
        harness.controller.handleTab(forward: true)

        XCTAssertEqual(harness.access.nextSwitchCount, 1, "second tap should not re-switch")
        XCTAssertEqual(harness.delegate.opened, 1)
        guard case let .visualMode(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w2", "c"))
        XCTAssertFalse(harness.scheduler.hasPending, "hold timer should be cancelled")
    }

    // MARK: - In visual mode: navigation

    func test_tab_in_visual_mode_advances_selection() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true) // w1→w2 (instant)
        harness.scheduler.fireAll()                  // open visual at (w2,c)
        XCTAssertEqual(harness.delegate.opened, 1)

        harness.controller.handleTab(forward: true) // advance pane
        guard case let .visualMode(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        // After (w2,c), forward wraps to (w1,a) (only one pane in w2).
        XCTAssertEqual(selection.current, ref("w1", "a"))
        XCTAssertEqual(harness.delegate.updates, 1)
    }

    func test_shift_tab_in_visual_mode_moves_backward() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll() // visual at (w2,c)

        harness.controller.handleTab(forward: false) // backward
        guard case let .visualMode(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "b"))
    }

    // MARK: - Commit / Cancel

    func test_ctrl_release_in_visual_mode_commits_current_selection() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll() // visual at (w2,c)
        harness.controller.handleTab(forward: true) // wraps to (w1,a)

        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.count, 1)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w1"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("a"))
        XCTAssertEqual(harness.delegate.closed, 1)
    }

    func test_escape_in_visual_mode_restores_original_focus() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll() // visual at (w2,c) — original = (w2,c)
        harness.controller.handleTab(forward: true) // navigate to (w1,a)

        harness.controller.handleEscape()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w2"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("c"))
    }

    func test_ctrl_release_while_armed_just_disarms() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true) // armed
        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.count, 0, "no commit when only armed")
        XCTAssertFalse(harness.scheduler.hasPending)
        XCTAssertEqual(harness.delegate.opened, 0)
        XCTAssertEqual(harness.delegate.closed, 0)
    }

    // MARK: - Click

    func test_click_in_visual_mode_commits_at_clicked_pane() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll() // visual at (w2,c)

        harness.controller.handleClick(at: ref("w1", "b"))

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w1"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("b"))
    }

    func test_click_in_idle_is_ignored() {
        let harness = makeHarness(
            worklanes: [makeWorklane("w1", panes: ["a"], focused: "a")],
            active: "w1"
        )
        harness.controller.handleClick(at: ref("w1", "a"))

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.count, 0)
    }

    // MARK: - Single-worklane case

    func test_single_worklane_first_tap_no_op_but_arms() {
        // selectNextWorklane is recorded but no actual lane change happens
        // (only one worklane). The controller still arms, so a hold opens
        // visual on the lone lane.
        let harness = makeHarness(
            worklanes: [makeWorklane("only", panes: ["a", "b"], focused: "a")],
            active: "only"
        )

        harness.controller.handleTab(forward: true)

        XCTAssertEqual(harness.access.nextSwitchCount, 1)
        XCTAssertEqual(harness.access.activeWorklaneID, WorklaneID("only"))
        if case .armed = harness.controller.phase {} else {
            XCTFail("expected armed phase")
        }

        harness.scheduler.fireAll()

        guard case let .visualMode(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase after hold")
        }
        XCTAssertEqual(selection.current, ref("only", "a"))
    }

    // MARK: - Hold-timer cancellation

    func test_hold_timer_does_not_open_visual_after_explicit_cancel() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true) // armed
        harness.controller.handleCtrlReleased()      // disarms

        XCTAssertFalse(harness.scheduler.hasPending,
                       "cancel should drain the pending timer")
        // Even if a stale timer were to fire, the phase guard prevents opening.
        harness.scheduler.fireAll()
        XCTAssertEqual(harness.delegate.opened, 0)
    }

    // MARK: - End-to-end with the production Timer-based scheduler

    func test_real_scheduler_actually_fires_hold_timer() async {
        let access = FakeWorklaneAccess()
        access.worklanes = [
            makeWorklane("w1", panes: ["a"], focused: "a"),
            makeWorklane("w2", panes: ["c"], focused: "c"),
        ]
        access.activeWorklaneID = WorklaneID("w1")
        let delegate = RecordingDelegate()
        let controller = VisualWorklaneSwitcherController(
            worklaneAccess: access,
            holdThreshold: 0.05  // 50ms — the production path also uses 200ms by default
        )
        controller.delegate = delegate

        controller.handleTab(forward: true)

        // Wait long enough for the real Timer-based hold scheduler to fire.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(delegate.opened, 1, "real Timer-based scheduler should fire and open visual mode")
        if case .visualMode = controller.phase {} else {
            XCTFail("expected visualMode after timer fired, got \(controller.phase)")
        }
    }

    // MARK: - Stale hold-timer firing after gesture restart

    func test_stale_hold_timer_does_not_open_visual_for_new_arming() {
        // Although the implementation cancels pending timers on re-arm, this
        // verifies the armedAt guard inside handleHoldTimerFired so a leaked
        // closure can't re-trigger the gesture.
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)      // armed @ t=0
        harness.controller.handleCtrlReleased()          // disarmed
        harness.controller.handleTab(forward: true)      // armed again

        // Only the most recent pending timer should fire.
        harness.scheduler.fireAll()
        XCTAssertEqual(harness.delegate.opened, 1)
    }
}
