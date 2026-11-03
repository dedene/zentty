import CoreGraphics
import XCTest
@testable import Zentty

/// Which mode changes owe motion between two canvas renders.
final class FloatModeTransitionTests: XCTestCase {
    private let worklaneID = WorklaneID("wl")
    private let f = PaneID("f")
    private let g = PaneID("g")

    func test_minimize_flies_into_a_new_pill() {
        let plan = plan(old: [float(f)], new: [float(f, .minimized(order: 0))], newPills: [f])

        XCTAssertEqual(plan.departures, [f: .toPill])
        XCTAssertEqual(plan.pillArrivals, [f])
        XCTAssertTrue(plan.entries.isEmpty)
    }

    func test_pip_evicted_or_minimized_flies_into_its_pill() {
        let plan = plan(old: [float(f, .pip(corner: .bottomRight, order: 0))], new: [float(f, .minimized(order: 0))], newPills: [f])

        XCTAssertEqual(plan.departures, [f: .toPill])
        XCTAssertEqual(plan.pillArrivals, [f])
    }

    func test_restore_and_auto_pop_grow_out_of_the_pill() {
        let toFloat = plan(old: [float(f, .minimized(order: 0))], oldPills: [f], new: [float(f)])
        XCTAssertEqual(toFloat.entries, [f: .fromPill])
        XCTAssertTrue(toFloat.departures.isEmpty)

        let toPip = plan(old: [float(f, .minimized(order: 0))], oldPills: [f], new: [float(f, .pip(corner: .topLeft, order: 0))])
        XCTAssertEqual(toPip.entries, [f: .fromPill])
    }

    func test_float_and_pip_swap_has_its_own_motion() {
        let plan = plan(old: [float(f)], new: [float(f, .pip(corner: .bottomRight, order: 0))])
        XCTAssertTrue(plan.isEmpty)
    }

    func test_closing_a_float_fades_it() {
        let plan = plan(old: [float(f), float(g)], new: [float(g)])
        XCTAssertEqual(plan.departures, [f: .close])
    }

    func test_docking_leaves_the_motion_to_the_strip() {
        let plan = plan(old: [float(f)], new: [], strip: [f])
        XCTAssertTrue(plan.isEmpty)
    }

    func test_hide_all_and_show_all() {
        let floats = [float(f), float(g, .pip(corner: .bottomLeft, order: 0))]

        let hide = plan(old: floats, new: floats, newHidden: true)
        XCTAssertEqual(hide.departures, [f: .hide, g: .hide])

        let show = plan(old: floats, oldHidden: true, new: floats)
        XCTAssertEqual(show.entries, [f: .reveal, g: .reveal])
    }

    func test_pills_stay_put_while_floats_hide() {
        let floats = [float(f), float(g, .minimized(order: 0))]
        let plan = plan(old: floats, oldPills: [g], new: floats, newPills: [g], newHidden: true)
        XCTAssertEqual(plan.departures, [f: .hide])
        XCTAssertTrue(plan.pillArrivals.isEmpty)
    }

    func test_a_new_float_is_revealed() {
        let plan = plan(old: [float(f)], new: [float(f), float(g)])
        XCTAssertEqual(plan.entries, [g: .reveal])
    }

    func test_a_worklane_switch_or_first_render_has_no_motion() {
        let switched = FloatModeTransition.plan(
            from: FloatLayerContent(floats: [float(f)], floatsHidden: false, focusedFloatID: nil, worklaneID: WorklaneID("other")),
            oldPillIDs: [],
            to: content([float(g)]),
            newPillIDs: [],
            stripPaneIDs: []
        )
        XCTAssertTrue(switched.isEmpty)

        let first = FloatModeTransition.plan(
            from: .empty,
            oldPillIDs: [],
            to: content([float(g)]),
            newPillIDs: [],
            stripPaneIDs: []
        )
        XCTAssertTrue(first.isEmpty)
    }

    func test_pictures_follow_the_pill_bar_and_hide_floats() {
        let floats = [float(f), float(g, .minimized(order: 0))]
        XCTAssertEqual(
            FloatModeTransition.pictures(of: content(floats), pillIDs: [g]),
            [f: .float, g: .pill]
        )
        XCTAssertEqual(
            FloatModeTransition.pictures(of: content(floats, hidden: true), pillIDs: [g]),
            [g: .pill]
        )
    }

    // MARK: - Fixtures

    private func float(_ id: PaneID, _ mode: FloatingPaneMode = .floating) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: id, title: id.rawValue),
            mode: mode,
            floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            stackOrder: 0,
            origin: nil,
            sequence: 0
        )
    }

    private func content(_ floats: [FloatingPaneState], hidden: Bool = false) -> FloatLayerContent {
        FloatLayerContent(floats: floats, floatsHidden: hidden, focusedFloatID: nil, worklaneID: worklaneID)
    }

    private func plan(
        old: [FloatingPaneState],
        oldPills: Set<PaneID> = [],
        oldHidden: Bool = false,
        new: [FloatingPaneState],
        newPills: Set<PaneID> = [],
        newHidden: Bool = false,
        strip: Set<PaneID> = []
    ) -> FloatModeTransitionPlan {
        FloatModeTransition.plan(
            from: content(old, hidden: oldHidden),
            oldPillIDs: oldPills,
            to: content(new, hidden: newHidden),
            newPillIDs: newPills,
            stripPaneIDs: strip
        )
    }
}
