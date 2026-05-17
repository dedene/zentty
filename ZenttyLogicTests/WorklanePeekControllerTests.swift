import XCTest
@testable import Zentty

@MainActor
final class WorklanePeekControllerTests: XCTestCase {

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
    final class FakeWorklaneAccess: WorklanePeekWorklaneAccess {
        var worklanes: [WorklaneState] = []
        var activeWorklaneID: WorklaneID = WorklaneID("")
        var focusCalls: [(worklaneID: WorklaneID, paneID: PaneID)] = []

        func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID) {
            focusCalls.append((worklaneID, paneID))
            activeWorklaneID = worklaneID
            if let i = worklanes.firstIndex(where: { $0.id == worklaneID }) {
                worklanes[i].paneStripState.focusPane(id: paneID)
            }
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

        func make() -> WorklanePeekController.Scheduler {
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

    final class TestClock {
        var now: CFTimeInterval = 0
    }

    @MainActor
    final class RecordingDelegate: WorklanePeekControllerDelegate {
        var armed = 0
        var opened = 0
        var updates = 0
        var ended = 0
        var closed = 0
        var transitions: [WorklanePeekSelectionTransition] = []

        func peekDidArm(_ controller: WorklanePeekController) { armed += 1 }
        func peekDidOpen(_ controller: WorklanePeekController) { opened += 1 }
        func peekDidUpdateSelection(
            _ controller: WorklanePeekController,
            transition: WorklanePeekSelectionTransition
        ) {
            updates += 1
            transitions.append(transition)
        }
        func peekDidEnd(_ controller: WorklanePeekController) { ended += 1 }
        func peekDidClose(_ controller: WorklanePeekController) { closed += 1 }
    }

    private struct Harness {
        let access: FakeWorklaneAccess
        let scheduler: TestScheduler
        let delegate: RecordingDelegate
        let controller: WorklanePeekController
        let time: TestClock
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

        let time = TestClock()
        let clock: () -> CFTimeInterval = { time.now }

        let controller = WorklanePeekController(
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
            time: time
        )
    }

    // MARK: - First tap (idle → armed) — step is deferred

    func test_first_tab_in_idle_arms_without_stepping() {
        // The first tap only ARMS — we don't yet know if it's a tap or a
        // hold. The pane step is deferred until disambiguation (release ⇒
        // step; hold timer ⇒ no step, visual at original).
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)

        XCTAssertEqual(harness.access.focusCalls.count, 0, "step should be deferred")
        XCTAssertEqual(harness.delegate.armed, 1)
        XCTAssertEqual(harness.delegate.opened, 0)
        if case .armed = harness.controller.phase {} else {
            XCTFail("expected armed phase, got \(harness.controller.phase)")
        }
        XCTAssertTrue(harness.scheduler.hasPending, "hold timer should be scheduled")
    }

    func test_quick_tap_release_performs_deferred_step() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true) // arm only
        harness.controller.handleCtrlReleased()      // release → run deferred step

        XCTAssertEqual(harness.access.focusCalls.count, 1)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w1"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("b"))
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.delegate.ended, 1)
        XCTAssertEqual(harness.delegate.closed, 0)
    }

    func test_quick_tap_release_at_end_of_worklane_crosses_into_next() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)
        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w2"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("c"))
    }

    func test_quick_tap_release_backward_steps_to_previous_pane() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c", "d"], focused: "d"),
            ],
            active: "w2"
        )

        harness.controller.handleTab(forward: false)
        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w2"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("c"))
    }

    func test_escape_while_armed_aborts_deferred_step() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true) // arm only
        harness.controller.handleEscape()            // abort

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.count, 0, "no step should run on abort")
        XCTAssertFalse(harness.scheduler.hasPending)
        XCTAssertEqual(harness.delegate.ended, 1)
        XCTAssertEqual(harness.delegate.closed, 0)
    }

    // MARK: - Hold timer fires (armed → visualMode)

    func test_hold_timer_opens_visual_at_original_pane_with_no_step() {
        // Pure tap-and-hold: visual zooms out where the user IS, no pane
        // movement. The deferred tap step is intentionally abandoned.
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c", "d"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.access.focusCalls.count, 0, "hold should not perform the deferred step")
        XCTAssertEqual(harness.delegate.opened, 1)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "a"))
        XCTAssertEqual(selection.original, ref("w1", "a"))
    }

    func test_hold_timer_failure_to_resolve_current_pane_ends_monitor_lifecycle() {
        let harness = makeHarness(worklanes: [], active: "missing")

        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.delegate.ended, 1)
        XCTAssertEqual(harness.delegate.closed, 0)
    }

    // MARK: - Second tap commits deferred + opens visual + advances once

    func test_second_tab_while_armed_runs_deferred_step_opens_visual_and_advances() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
                makeWorklane("w3", panes: ["e"], focused: "e"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true) // arm — no focus call
        XCTAssertEqual(harness.access.focusCalls.count, 0)
        harness.controller.handleTab(forward: true)

        // Tap 1's deferred step ran (a → c). Visual opened at (w2, c).
        // Tap 2 advanced selection to (w3, e).
        XCTAssertEqual(harness.access.focusCalls.count, 1, "deferred step should fire on tap 2")
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w2"))
        XCTAssertEqual(harness.delegate.opened, 1)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w3", "e"))
        XCTAssertEqual(selection.original, ref("w2", "c"))
        XCTAssertFalse(harness.scheduler.hasPending, "hold timer should be cancelled")
    }

    // MARK: - In peek: navigation

    func test_tab_in_peek_advances_selection() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )

        harness.controller.handleTab(forward: true) // arm
        harness.scheduler.fireAll()                  // hold: visual at (w1,a)
        XCTAssertEqual(harness.delegate.opened, 1)

        harness.controller.handleTab(forward: true) // advance to (w1,b)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "b"))
        XCTAssertEqual(harness.delegate.updates, 1)
    }

    func test_shift_tab_in_peek_moves_backward() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()                  // visual at (w1,a)

        harness.controller.handleTab(forward: false) // shift-tab: wrap to (w2,c)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w2", "c"))
        XCTAssertEqual(harness.delegate.transitions, [.hardCut])
    }

    // MARK: - Wrap behavior

    func test_tab_at_last_pane_reports_hardCut_transition() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "b"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()                  // visual at (w1,b)

        harness.controller.handleTab(forward: true)  // wrap to (w1,a)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "a"))
        XCTAssertEqual(harness.delegate.transitions, [.hardCut])
    }

    func test_within_list_step_reports_animated_transition() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b", "c"], focused: "a"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()                  // visual at (w1,a)

        harness.controller.handleTab(forward: true)  // (w1,a) -> (w1,b), no wrap
        XCTAssertEqual(harness.delegate.transitions, [.animated])
    }

    // MARK: - Commit / Cancel

    func test_ctrl_release_in_peek_commits_current_selection() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()                  // visual at (w1,a)
        harness.controller.handleTab(forward: true) // advance to (w1,b)

        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.controller.phase, .idle)
        // Only the commit fires a focus call — no deferred step happened
        // because the gesture transitioned to hold (peek).
        XCTAssertEqual(harness.access.focusCalls.count, 1)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w1"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("b"))
        XCTAssertEqual(harness.delegate.closed, 1)
    }

    func test_escape_in_peek_restores_original_focus() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()                  // visual at (w1,a) — original
        harness.controller.handleTab(forward: true) // advance to (w1,b)

        harness.controller.handleEscape()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("w1"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("a"))
    }

    // MARK: - Click

    func test_click_in_peek_preview_selects_clicked_pane_without_committing() {
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

        XCTAssertEqual(harness.access.focusCalls.count, 0)
        XCTAssertEqual(harness.delegate.closed, 0)
        XCTAssertEqual(harness.delegate.transitions, [.animated])
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected peeking phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "b"))
    }

    func test_ctrl_release_after_click_commits_preview_selected_pane() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["a", "b"], focused: "a"),
                makeWorklane("w2", panes: ["c"], focused: "c"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        harness.controller.handleClick(at: ref("w1", "b"))
        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(harness.access.focusCalls.count, 1)
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

    func test_single_worklane_tap_release_steps_within_lane() {
        let harness = makeHarness(
            worklanes: [makeWorklane("only", panes: ["a", "b"], focused: "a")],
            active: "only"
        )

        harness.controller.handleTab(forward: true)
        harness.controller.handleCtrlReleased()

        XCTAssertEqual(harness.access.focusCalls.last?.worklaneID, WorklaneID("only"))
        XCTAssertEqual(harness.access.focusCalls.last?.paneID, PaneID("b"))
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func test_single_worklane_hold_opens_visual_at_current_pane() {
        // With a single worklane, hold zooms out at the user's current pane
        // — no step performed.
        let harness = makeHarness(
            worklanes: [makeWorklane("only", panes: ["a", "b"], focused: "a")],
            active: "only"
        )

        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        XCTAssertEqual(harness.access.focusCalls.count, 0)
        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected visualMode phase after hold")
        }
        XCTAssertEqual(selection.current, ref("only", "a"))
    }

    // MARK: - Spatial swipe navigation

    func test_spatial_swipe_right_moves_to_focused_pane_in_next_column() {
        let harness = makeHarness(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("w1"),
                    title: "w1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("left"),
                                panes: [makePane("a")],
                                width: 400,
                                focusedPaneID: PaneID("a")
                            ),
                            PaneColumnState(
                                id: PaneColumnID("right"),
                                panes: [makePane("b"), makePane("c")],
                                width: 400,
                                focusedPaneID: PaneID("c"),
                                lastFocusedPaneID: PaneID("c")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("left")
                    )
                ),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        harness.controller.handleSpatialSwipe(.right)

        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected peeking phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "c"))
        XCTAssertEqual(harness.access.focusCalls.count, 0)
    }

    func test_spatial_swipe_down_moves_within_vertical_column_before_worklane() {
        let harness = makeHarness(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("w1"),
                    title: "w1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [makePane("top"), makePane("middle"), makePane("bottom")],
                                width: 400,
                                focusedPaneID: PaneID("top"),
                                lastFocusedPaneID: PaneID("top")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("stack")
                    )
                ),
                makeWorklane("w2", panes: ["other"], focused: "other"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        harness.controller.handleSpatialSwipe(.down)

        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected peeking phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "middle"))
    }

    func test_spatial_swipe_down_at_bottom_moves_to_next_worklane_focused_pane() {
        let harness = makeHarness(
            worklanes: [
                WorklaneState(
                    id: WorklaneID("w1"),
                    title: "w1",
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("stack"),
                                panes: [makePane("top"), makePane("bottom")],
                                width: 400,
                                focusedPaneID: PaneID("bottom"),
                                lastFocusedPaneID: PaneID("bottom")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("stack")
                    )
                ),
                makeWorklane("w2", panes: ["other"], focused: "other"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        harness.controller.handleSpatialSwipe(.down)

        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected peeking phase")
        }
        XCTAssertEqual(selection.current, ref("w2", "other"))
    }

    func test_spatial_swipe_at_outer_edge_does_not_wrap() {
        let harness = makeHarness(
            worklanes: [
                makeWorklane("w1", panes: ["only"], focused: "only"),
            ],
            active: "w1"
        )
        harness.controller.handleTab(forward: true)
        harness.scheduler.fireAll()

        harness.controller.handleSpatialSwipe(.up)

        guard case let .peeking(selection, _) = harness.controller.phase else {
            return XCTFail("expected peeking phase")
        }
        XCTAssertEqual(selection.current, ref("w1", "only"))
        XCTAssertEqual(harness.delegate.updates, 0)
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
        let controller = WorklanePeekController(
            worklaneAccess: access,
            holdThreshold: 0.05  // 50ms — the production path also uses 200ms by default
        )
        controller.delegate = delegate

        controller.handleTab(forward: true)

        // Wait long enough for the real Timer-based hold scheduler to fire.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(delegate.opened, 1, "real Timer-based scheduler should fire and open peek")
        if case .peeking = controller.phase {} else {
            XCTFail("expected visualMode after timer fired, got \(controller.phase)")
        }
    }

    // MARK: - Stale hold-timer firing after gesture restart

    func test_stale_hold_timer_does_not_open_visual_for_new_arming() throws {
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
        let staleWork = try XCTUnwrap(harness.scheduler.pending.values.first?.work)
        harness.controller.handleCtrlReleased()          // disarmed
        harness.time.now += 1
        harness.controller.handleTab(forward: true)      // armed again
        let currentWork = try XCTUnwrap(harness.scheduler.pending.values.first?.work)

        staleWork()
        XCTAssertEqual(harness.delegate.opened, 0)
        if case .armed = harness.controller.phase {} else {
            XCTFail("expected stale hold timer to leave current arming intact, got \(harness.controller.phase)")
        }
        XCTAssertTrue(harness.scheduler.hasPending, "current hold timer should remain armed")

        currentWork()
        XCTAssertEqual(harness.delegate.opened, 1)
    }
}
