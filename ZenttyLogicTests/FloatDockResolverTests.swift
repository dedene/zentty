import CoreGraphics
import XCTest
@testable import Zentty

final class FloatDockResolverTests: XCTestCase {
    private let dragged = PaneID("float")
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)

    // MARK: - Fixtures (y-up, float-layer coordinates)

    /// A single-pane column at `x`, 400 wide, full height.
    private func column(_ id: String, x: CGFloat, width: CGFloat = 400) -> ColumnPresentation {
        let frame = CGRect(x: x, y: 0, width: width, height: 800)
        return ColumnPresentation(
            columnID: PaneColumnID("col_\(id)"),
            frame: frame,
            panes: [PanePresentation(paneID: PaneID(id), columnID: PaneColumnID("col_\(id)"), frame: frame, emphasis: 1, isFocused: false)]
        )
    }

    /// A column at `x` holding `ids` stacked top to bottom, 6pt apart.
    private func stack(_ columnID: String, _ ids: [String], x: CGFloat) -> ColumnPresentation {
        let gap: CGFloat = 6
        let height = (800 - gap * CGFloat(ids.count - 1)) / CGFloat(ids.count)
        let panes = ids.enumerated().map { index, id in
            let top = 800 - CGFloat(index) * (height + gap)
            return PanePresentation(
                paneID: PaneID(id),
                columnID: PaneColumnID(columnID),
                frame: CGRect(x: x, y: top - height, width: 400, height: height),
                emphasis: 1,
                isFocused: false
            )
        }
        return ColumnPresentation(
            columnID: PaneColumnID(columnID),
            frame: CGRect(x: x, y: 0, width: 400, height: 800),
            panes: panes
        )
    }

    /// [A][B] with an 8pt gap between them (A 0–400, B 408–808).
    private var twoColumns: [ColumnPresentation] {
        [column("a", x: 0), column("b", x: 408)]
    }

    private func resolve(
        _ cursor: CGPoint,
        _ columns: [ColumnPresentation],
        previous: FloatDockHits = .none,
        dwell: Bool = false
    ) -> FloatDockResolver.Result {
        FloatDockResolver.resolve(FloatDockResolver.Input(
            cursor: cursor,
            columns: columns,
            draggedPaneID: dragged,
            previous: previous,
            splitDwellSatisfied: dwell
        ))
    }

    // MARK: - Targets

    func test_empty_strip_targets_first_column_gap() {
        let result = resolve(CGPoint(x: 600, y: 400), [])
        XCTAssertEqual(result.target, .columnGap(index: 0))
        XCTAssertEqual(result.hits, .none)
    }

    func test_gap_between_columns_uses_raw_index() {
        let result = resolve(CGPoint(x: 404, y: 400), twoColumns)
        XCTAssertEqual(result.hits.gap, ReorderGapHit(reducedIndex: 1))
        XCTAssertEqual(result.target, .columnGap(index: 1), "no source adjustment: a float has no strip slot")
    }

    func test_gap_after_last_column_targets_end() {
        let result = resolve(CGPoint(x: 900, y: 400), twoColumns)
        XCTAssertEqual(result.target, .columnGap(index: 2))
    }

    func test_gap_hysteresis_keeps_previous_index() {
        // Stacks, so no horizontal split edge competes with the gap. 20pt into
        // the right column: outside the 16pt activation, inside the 24pt
        // retention, and clear of the stack gaps.
        let columns = [stack("col_s", ["s1", "s2"], x: 0), stack("col_t", ["t1", "t2"], x: 408)]
        let cursor = CGPoint(x: 428, y: 200)
        XCTAssertNil(resolve(cursor, columns).hits.gap)

        let held = resolve(cursor, columns, previous: FloatDockHits(gap: ReorderGapHit(reducedIndex: 1)))
        XCTAssertEqual(held.hits.gap, ReorderGapHit(reducedIndex: 1))
        XCTAssertEqual(held.target, .columnGap(index: 1))
    }

    func test_stack_gap_targets_stack() {
        let columns = [stack("col_s", ["s1", "s2"], x: 0), column("b", x: 408)]
        let between = (columns[0].panes[0].frame.minY + columns[0].panes[1].frame.maxY) / 2

        let result = resolve(CGPoint(x: 200, y: between), columns)

        XCTAssertEqual(result.hits.stack, StackReorderGapHit(columnID: PaneColumnID("col_s"), paneIndex: 1))
        XCTAssertEqual(result.target, .stackGap(columnID: PaneColumnID("col_s"), paneIndex: 1))
    }

    func test_split_needs_dwell() {
        // Near B's top edge, away from the column gaps.
        let result = resolve(CGPoint(x: 608, y: 760), twoColumns)

        XCTAssertEqual(result.pendingSplit?.targetPaneID, PaneID("b"))
        XCTAssertNil(result.hits.split)
        XCTAssertNil(result.target, "a split waits for the dwell")
    }

    func test_split_after_dwell_targets_split() {
        let result = resolve(CGPoint(x: 608, y: 760), twoColumns, dwell: true)

        XCTAssertEqual(result.target, .split(target: PaneID("b"), axis: .vertical, leading: true))
        XCTAssertNil(result.pendingSplit)
    }

    func test_prospective_split_suppresses_adjacent_gap() {
        // 10pt inside B's left edge: in gap 1's activation band, but also on
        // B's leading horizontal split edge, which wins.
        let cursor = CGPoint(x: 418, y: 400)
        let result = resolve(cursor, twoColumns)

        XCTAssertNil(result.hits.gap)
        XCTAssertEqual(result.pendingSplit?.axis, .horizontal)
        XCTAssertEqual(result.pendingSplit?.leading, true)
        XCTAssertEqual(
            resolve(cursor, twoColumns, dwell: true).target,
            .split(target: PaneID("b"), axis: .horizontal, leading: true)
        )
    }

    func test_horizontal_split_only_on_single_pane_column() {
        // Near the left edge of the bottom pane of a two-pane stack (away from
        // the stack gaps): only a vertical split can apply, and that edge is
        // too far, so nothing targets it.
        let columns = [column("a", x: 0), stack("col_s", ["s1", "s2"], x: 408)]
        let lower = columns[1].panes[1].frame
        let result = resolve(CGPoint(x: lower.minX + 40, y: lower.midY), columns, dwell: true)

        XCTAssertNotEqual(result.hits.split?.axis, .horizontal)
        if case .split(_, .horizontal, _) = result.target {
            XCTFail("no horizontal split on a multi-pane column")
        }
    }

    func test_dead_zone_has_no_target() {
        XCTAssertNil(resolve(CGPoint(x: 200, y: 400), twoColumns, dwell: true).target)
    }

    func test_outcomes_are_never_duplicate() {
        let cursors = [CGPoint(x: 404, y: 400), CGPoint(x: 608, y: 760)]
        for cursor in cursors {
            guard case .commit(let outcome) = resolve(cursor, twoColumns, dwell: true).resolution else {
                XCTFail("expected a commit at \(cursor)")
                continue
            }
            switch outcome {
            case .reorder(_, _, let isDuplicate),
                 .reorderInColumn(_, _, _, let isDuplicate),
                 .splitDrop(_, _, _, _, let isDuplicate),
                 .crossWorklane(_, _, _, let isDuplicate),
                 .newWorklane(_, _, let isDuplicate):
                XCTAssertFalse(isDuplicate)
            }
        }
    }

    func test_sidebar_outcomes_map_to_nil() {
        XCTAssertNil(FloatDockResolver.target(for: .crossWorklane(
            paneID: dragged, worklaneID: WorklaneID("wl"), paneIndex: nil, isDuplicate: false
        )))
        XCTAssertNil(FloatDockResolver.target(for: .newWorklane(paneID: dragged, insertionIndex: 0, isDuplicate: false)))
        XCTAssertEqual(
            FloatDockResolver.target(for: .reorder(paneID: dragged, columnIndex: 3, isDuplicate: false)),
            .columnGap(index: 3)
        )
    }

    // MARK: - Preview geometry

    func test_preview_geometry_column_line_centred_on_gap() {
        let geometry = FloatDockResolver.previewGeometry(for: .columnGap(index: 1), columns: twoColumns, canvas: canvas)
        XCTAssertEqual(geometry, .columnLine(CGRect(x: 401, y: 0, width: 6, height: 800)))
    }

    func test_preview_geometry_edge_line_stays_in_canvas() {
        let geometry = FloatDockResolver.previewGeometry(for: .columnGap(index: 0), columns: twoColumns, canvas: canvas)
        XCTAssertEqual(geometry?.frame.minX, 0)
    }

    func test_preview_geometry_split_half() {
        let upper = FloatDockResolver.previewGeometry(
            for: .split(target: PaneID("b"), axis: .vertical, leading: true),
            columns: twoColumns,
            canvas: canvas
        )
        XCTAssertEqual(upper, .splitHalf(CGRect(x: 408, y: 400, width: 400, height: 400)))

        let right = FloatDockResolver.previewGeometry(
            for: .split(target: PaneID("a"), axis: .horizontal, leading: false),
            columns: twoColumns,
            canvas: canvas
        )
        XCTAssertEqual(right, .splitHalf(CGRect(x: 200, y: 0, width: 200, height: 800)))
    }

    func test_preview_geometry_stack_line_and_empty_strip() {
        let columns = [stack("col_s", ["s1", "s2"], x: 0)]
        let stackLine = FloatDockResolver.previewGeometry(
            for: .stackGap(columnID: PaneColumnID("col_s"), paneIndex: 1),
            columns: columns,
            canvas: canvas
        )
        XCTAssertEqual(stackLine, .stackLine(CGRect(x: 0, y: 397, width: 400, height: 6)))

        XCTAssertEqual(
            FloatDockResolver.previewGeometry(for: .columnGap(index: 0), columns: [], canvas: canvas),
            .emptyStrip(canvas.insetBy(dx: 8, dy: 8))
        )
        XCTAssertNil(FloatDockResolver.previewGeometry(
            for: .split(target: PaneID("gone"), axis: .vertical, leading: true),
            columns: twoColumns,
            canvas: canvas
        ))
    }
}
