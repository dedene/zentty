import XCTest
@testable import Zentty

final class VisualSwitcherSelectionStateTests: XCTestCase {

    // MARK: - Helpers

    private func ref(_ worklane: String, _ pane: String) -> WorklaneStore.PaneReference {
        WorklaneStore.PaneReference(
            worklaneID: WorklaneID(worklane),
            paneID: PaneID(pane)
        )
    }

    private func traversal(_ pairs: [(String, String)]) -> VisualSwitcherTraversal {
        VisualSwitcherTraversal(references: pairs.map { ref($0.0, $0.1) })
    }

    // MARK: - Step within / across worklanes

    func test_step_forward_within_worklane() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w1", "p3")])
        XCTAssertEqual(t.step(from: ref("w1", "p1"), direction: .forward), ref("w1", "p2"))
    }

    func test_step_backward_within_worklane() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w1", "p3")])
        XCTAssertEqual(t.step(from: ref("w1", "p3"), direction: .backward), ref("w1", "p2"))
    }

    func test_step_forward_crosses_worklane_boundary() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w2", "p1")])
        XCTAssertEqual(t.step(from: ref("w1", "p2"), direction: .forward), ref("w2", "p1"))
    }

    func test_step_backward_crosses_worklane_boundary() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w2", "p1")])
        XCTAssertEqual(t.step(from: ref("w2", "p1"), direction: .backward), ref("w1", "p2"))
    }

    // MARK: - Wrap

    func test_step_forward_at_end_wraps_to_start() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        XCTAssertEqual(t.step(from: ref("w2", "p1"), direction: .forward), ref("w1", "p1"))
    }

    func test_step_backward_at_start_wraps_to_end() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        XCTAssertEqual(t.step(from: ref("w1", "p1"), direction: .backward), ref("w2", "p1"))
    }

    func test_wrapsAround_detects_last_pane_forward() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        XCTAssertTrue(t.wrapsAround(from: ref("w2", "p1"), direction: .forward))
        XCTAssertFalse(t.wrapsAround(from: ref("w1", "p1"), direction: .forward))
    }

    func test_wrapsAround_detects_first_pane_backward() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        XCTAssertTrue(t.wrapsAround(from: ref("w1", "p1"), direction: .backward))
        XCTAssertFalse(t.wrapsAround(from: ref("w2", "p1"), direction: .backward))
    }

    // MARK: - Boundary detection

    func test_crossesWorklaneBoundary_forward_at_last_pane_in_worklane() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w2", "p1")])
        XCTAssertTrue(t.crossesWorklaneBoundary(from: ref("w1", "p2"), direction: .forward))
        XCTAssertFalse(t.crossesWorklaneBoundary(from: ref("w1", "p1"), direction: .forward))
    }

    func test_crossesWorklaneBoundary_on_wrap_around() {
        // Single-worklane wrap stays in the same worklane → no boundary cross.
        let single = traversal([("w1", "p1"), ("w1", "p2")])
        XCTAssertFalse(single.crossesWorklaneBoundary(from: ref("w1", "p2"), direction: .forward))

        // Multi-worklane wrap from the last pane back to the first crosses
        // a worklane boundary (last lane → first lane).
        let multi = traversal([("w1", "p1"), ("w2", "p1")])
        XCTAssertTrue(multi.crossesWorklaneBoundary(from: ref("w2", "p1"), direction: .forward))
    }

    // MARK: - Edge cases

    func test_step_returns_nil_for_unknown_reference() {
        let t = traversal([("w1", "p1")])
        XCTAssertNil(t.step(from: ref("wX", "pX"), direction: .forward))
    }

    func test_step_in_single_pane_traversal_returns_self() {
        let t = traversal([("w1", "p1")])
        XCTAssertEqual(t.step(from: ref("w1", "p1"), direction: .forward), ref("w1", "p1"))
        XCTAssertEqual(t.step(from: ref("w1", "p1"), direction: .backward), ref("w1", "p1"))
    }

    func test_step_in_empty_traversal_returns_nil() {
        let t = VisualSwitcherTraversal(references: [])
        XCTAssertNil(t.step(from: ref("w1", "p1"), direction: .forward))
    }

    // MARK: - SelectionState

    func test_selection_advancing_changes_current_keeps_original() {
        let t = traversal([("w1", "p1"), ("w1", "p2"), ("w2", "p1")])
        let initial = VisualSwitcherSelectionState.opening(at: ref("w1", "p1"))
        let advanced = initial.advancing(by: .forward, traversal: t)
        XCTAssertEqual(advanced.current, ref("w1", "p2"))
        XCTAssertEqual(advanced.original, ref("w1", "p1"))
    }

    func test_selection_advancing_wraps_and_keeps_original() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        var s = VisualSwitcherSelectionState.opening(at: ref("w1", "p1"))
        s = s.advancing(by: .backward, traversal: t)
        XCTAssertEqual(s.current, ref("w2", "p1"))
        XCTAssertEqual(s.original, ref("w1", "p1"))
    }

    func test_selection_unknown_current_does_not_advance() {
        let t = traversal([("w1", "p1"), ("w2", "p1")])
        let initial = VisualSwitcherSelectionState.opening(at: ref("wX", "pX"))
        let advanced = initial.advancing(by: .forward, traversal: t)
        XCTAssertEqual(advanced, initial)
    }
}
