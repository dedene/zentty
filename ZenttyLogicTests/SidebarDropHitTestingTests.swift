import AppKit
import CoreGraphics
import XCTest
@testable import Zentty

final class SidebarPaneDropHitTestingTests: XCTestCase {
    func test_target_returns_hovered_non_active_worklane() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .existingWorklane(WorklaneID("B"))
        )
    }

    func test_target_excludes_active_worklane() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("B"),
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_target_returns_new_worklane_below_last_row() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 60),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 3)
        )
    }

    func test_target_returns_none_outside_rows_and_new_worklane_zone() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 300),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_target_maps_empty_sidebar_lower_area_to_new_worklane() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 32),
                worklaneFrames: [],
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 0)
        )
    }

    func test_target_above_first_row_returns_new_worklane_at_index_0() {
        // A.maxY = 224; top zone extends 40pt above it.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 225),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 0)
        )
    }

    func test_target_returns_none_far_above_first_row() {
        // Beyond the 40pt top zone (A.maxY = 224 → zone caps at 264).
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 270),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_target_top_zone_steal_band_inside_first_row() {
        // y=220 is inside A (180-224) but within the 6pt steal band of its
        // top edge → new worklane above, not a drop into A.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 220),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 0)
        )
    }

    func test_target_gap_between_first_and_second_row_returns_index_1() {
        // Between A (minY=180) and B (maxY=174): mid is 177.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 177),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 1)
        )
    }

    func test_target_gap_between_second_and_third_row_returns_index_2() {
        // Between B (minY=130, maxY=174) and C (minY=80, maxY=124): mid is 127
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 127),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 2)
        )
    }

    func test_target_steal_band_overrides_pane_boundary_near_row_edge() {
        // y=172 sits inside B (130-174) within the 6pt steal band of its top
        // edge. The nearby pane boundary at 170 must lose to the gap zone.
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 152), PaneInsertionBoundary(y: 170)]),
        ]
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 172),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .newWorklane(insertionIndex: 1)
        )
    }

    func test_target_gap_stays_stable_with_placeholder_open() {
        // Placeholder open at gap 1 shifts B and C down by 50pt; the cursor
        // (unmoved, y=177) still sits between A and shifted-B → still index 1.
        let shiftedFrames: [(WorklaneID, CGRect)] = [
            (WorklaneID("A"), CGRect(x: 0, y: 180, width: 220, height: 44)),
            (WorklaneID("B"), CGRect(x: 0, y: 80, width: 220, height: 44)),
            (WorklaneID("C"), CGRect(x: 0, y: 30, width: 220, height: 44)),
        ]
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 177),
                worklaneFrames: shiftedFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                previousNewWorklaneIndex: 1
            ),
            .newWorklane(insertionIndex: 1)
        )
    }

    func test_target_hysteresis_keeps_gap_target_near_row_edge() {
        // y=165 is 9pt inside B's top edge: outside the 6pt enter band but
        // inside the 12pt exit band.
        let cursor = CGPoint(x: 20, y: 165)

        // Without an active gap → plain row hover.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: cursor,
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .existingWorklane(WorklaneID("B"))
        )

        // With gap 1 active, the wider exit band keeps the gap target.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: cursor,
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                previousNewWorklaneIndex: 1
            ),
            .newWorklane(insertionIndex: 1)
        )
    }

    func test_target_single_worklane_offers_top_and_bottom_zones() {
        let singleFrame: [(WorklaneID, CGRect)] = [
            (WorklaneID("A"), CGRect(x: 0, y: 180, width: 220, height: 44)),
        ]
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 230),
                worklaneFrames: singleFrame,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 0)
        )
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 170),
                worklaneFrames: singleFrame,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .newWorklane(insertionIndex: 1)
        )
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 200),
                worklaneFrames: singleFrame,
                activeWorklaneID: nil,
                sidebarBottomY: 0
            ),
            .existingWorklane(WorklaneID("A"))
        )
    }

    func test_pane_boundary_hit_inside_worklane() {
        // Pane boundaries must be inside the worklane frames:
        // A frame 180‑224, boundaries at [184, 202, 220]
        // B frame 130‑174, boundaries at [134, 152, 170]
        // C frame  80‑124, boundaries at [ 84, 102, 120]
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("A"), [PaneInsertionBoundary(y: 184), PaneInsertionBoundary(y: 202), PaneInsertionBoundary(y: 220)]),
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 152), PaneInsertionBoundary(y: 170)]),
            (WorklaneID("C"), [PaneInsertionBoundary(y: 84), PaneInsertionBoundary(y: 102), PaneInsertionBoundary(y: 120)]),
        ]
        // Cursor at 152 (gap boundary of B, inside B's frame 130‑174).
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 1)
        )
    }

    func test_pane_boundary_snaps_mid_pane_to_closest_edge() {
        // B frame 130‑174, pane boundaries at [134, 152, 170].
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 152), PaneInsertionBoundary(y: 170)]),
        ]
        // Cursor at 150: closer to 152 (dist 2) than 134 (dist 16) → paneIndex 1.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 150),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 1)
        )
        // Cursor at 140: closer to 134 (dist 6) than 152 (dist 12) → paneIndex 0.
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 140),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 0)
        )
    }

    func test_whole_row_hover_excludes_active_worklane() {
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 202),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0
            ),
            .none
        )
    }

    func test_pane_boundary_allows_active_worklane_pane_target() {
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("A"), [PaneInsertionBoundary(y: 184), PaneInsertionBoundary(y: 202)]),
        ]
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 202),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: WorklaneID("A"),
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .existingWorklaneAtPaneIndex(WorklaneID("A"), paneIndex: 1)
        )
    }

    func test_pane_boundary_only_uses_boundaries_for_containing_worklane() {
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("A"), [PaneInsertionBoundary(y: 152)]),
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 170)]),
        ]
        XCTAssertEqual(
            SidebarPaneDropHitTesting.target(
                cursorInStrip: CGPoint(x: 20, y: 152),
                worklaneFrames: worklaneFrames,
                activeWorklaneID: nil,
                sidebarBottomY: 0,
                paneBoundaries: paneBoundaries
            ),
            .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 0)
        )
    }

    func test_insertionLineY_for_pane_boundary() {
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 152)]),
        ]
        let lineY = SidebarPaneDropHitTesting.insertionLineY(
            for: .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 1),
            paneBoundaries: paneBoundaries
        )
        XCTAssertEqual(lineY, 152)
    }

    func test_insertionLineTarget_for_pane_boundary_includes_worklane_and_y() {
        let paneBoundaries: [(WorklaneID, [PaneInsertionBoundary])] = [
            (WorklaneID("B"), [PaneInsertionBoundary(y: 134), PaneInsertionBoundary(y: 152)]),
        ]
        let target = SidebarPaneDropHitTesting.insertionLineTarget(
            for: .existingWorklaneAtPaneIndex(WorklaneID("B"), paneIndex: 1),
            paneBoundaries: paneBoundaries
        )
        XCTAssertEqual(
            target,
            SidebarPaneInsertionLineTarget(worklaneID: WorklaneID("B"), y: 152)
        )
    }

    func test_insertionLineY_nil_for_whole_row_hover() {
        let lineY = SidebarPaneDropHitTesting.insertionLineY(
            for: .existingWorklane(WorklaneID("B")),
            paneBoundaries: []
        )
        XCTAssertNil(lineY)
    }

    func test_insertionLineY_nil_for_new_worklane() {
        let lineY = SidebarPaneDropHitTesting.insertionLineY(
            for: .newWorklane(insertionIndex: 0),
            paneBoundaries: []
        )
        XCTAssertNil(lineY)
    }

    func test_insertionLineTarget_nil_for_whole_row_hover() {
        let target = SidebarPaneDropHitTesting.insertionLineTarget(
            for: .existingWorklane(WorklaneID("B")),
            paneBoundaries: []
        )
        XCTAssertNil(target)
    }

    private var worklaneFrames: [(WorklaneID, CGRect)] {
        [
            (WorklaneID("A"), CGRect(x: 0, y: 180, width: 220, height: 44)),
            (WorklaneID("B"), CGRect(x: 0, y: 130, width: 220, height: 44)),
            (WorklaneID("C"), CGRect(x: 0, y: 80, width: 220, height: 44)),
        ]
    }
}
