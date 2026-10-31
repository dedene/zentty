import CoreGraphics
import XCTest
@testable import Zentty

final class WorklaneStateFloatAccessorTests: XCTestCase {
    private let tileA = PaneState(id: PaneID("tile-a"), title: "a")
    private let tileB = PaneState(id: PaneID("tile-b"), title: "b")
    private let floatX = PaneState(id: PaneID("float-x"), title: "x")
    private let floatY = PaneState(id: PaneID("float-y"), title: "y")

    private func float(
        _ pane: PaneState,
        mode: FloatingPaneMode = .floating,
        stackOrder: Int,
        sequence: Int = 0
    ) -> FloatingPaneState {
        FloatingPaneState(
            pane: pane,
            mode: mode,
            floatFrame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            stackOrder: stackOrder,
            origin: FloatOrigin(columnIndex: 0),
            sequence: sequence
        )
    }

    private func worklane(
        tiles: [PaneState],
        focusedTile: PaneID? = nil,
        floats: [FloatingPaneState] = [],
        floatsHidden: Bool = false,
        focusedFloatID: PaneID? = nil
    ) -> WorklaneState {
        WorklaneState(
            id: WorklaneID("w"),
            title: nil,
            paneStripState: PaneStripState(panes: tiles, focusedPaneID: focusedTile ?? tiles.first?.id),
            floatingPanes: floats,
            floatsHidden: floatsHidden,
            focusedFloatID: focusedFloatID
        )
    }

    func test_defaults_have_no_floats() {
        let state = WorklaneState(
            id: WorklaneID("w"),
            title: nil,
            paneStripState: PaneStripState(panes: [tileA])
        )
        XCTAssertEqual(state.floatingPanes, [])
        XCTAssertFalse(state.floatsHidden)
        XCTAssertNil(state.focusedFloatID)
        XCTAssertEqual(state.visibleFloatCount, 0)
    }

    func test_allPanes_lists_strip_then_floats_in_creation_order() {
        // Stored order, stack order and creation order all differ on purpose:
        // allPanes numbers by `sequence`, never by z-order.
        let state = worklane(
            tiles: [tileA, tileB],
            floats: [
                float(floatY, stackOrder: 1, sequence: 1),
                float(floatX, stackOrder: 2, sequence: 0),
            ]
        )
        XCTAssertEqual(state.allPanes.map(\.id), [tileA.id, tileB.id, floatX.id, floatY.id])
    }

    func test_floatsByStackOrder_lists_floats_back_to_front() {
        let state = worklane(
            tiles: [tileA],
            floats: [
                float(floatX, stackOrder: 2, sequence: 0),
                float(floatY, stackOrder: 1, sequence: 1),
            ]
        )
        XCTAssertEqual(state.floatsByStackOrder.map(\.pane.id), [floatY.id, floatX.id])
    }

    func test_float_ties_keep_stored_order() {
        let state = worklane(
            tiles: [],
            floats: [float(floatY, stackOrder: 0), float(floatX, stackOrder: 0)]
        )
        XCTAssertEqual(state.allPanes.map(\.id), [floatY.id, floatX.id])
        XCTAssertEqual(state.floatsByStackOrder.map(\.pane.id), [floatY.id, floatX.id])
    }

    func test_pane_id_finds_float() {
        let state = worklane(tiles: [tileA], floats: [float(floatX, stackOrder: 0)])
        XCTAssertEqual(state.pane(id: floatX.id)?.title, "x")
        XCTAssertEqual(state.pane(id: tileA.id)?.title, "a")
        XCTAssertNil(state.pane(id: PaneID("missing")))
        XCTAssertEqual(state.floatingPane(id: floatX.id)?.pane.id, floatX.id)
        XCTAssertNil(state.floatingPane(id: tileA.id))
        XCTAssertTrue(state.isFloating(floatX.id))
        XCTAssertFalse(state.isFloating(tileA.id))
    }

    func test_isFloating_true_for_every_float_mode() {
        let state = worklane(
            tiles: [tileA],
            floats: [
                float(floatX, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 0),
                float(floatY, mode: .minimized(order: 0), stackOrder: 1),
            ]
        )
        XCTAssertTrue(state.isFloating(floatX.id))
        XCTAssertTrue(state.isFloating(floatY.id))
    }

    func test_updatePane_mutates_float_copy() {
        var state = worklane(tiles: [tileA], floats: [float(floatX, stackOrder: 0)])

        let updatedFloat = state.updatePane(id: floatX.id) { $0.title = "renamed" }
        XCTAssertTrue(updatedFloat)
        XCTAssertEqual(state.floatingPanes.first?.pane.title, "renamed")

        let updatedTile = state.updatePane(id: tileA.id) { $0.title = "tile renamed" }
        XCTAssertTrue(updatedTile)
        XCTAssertEqual(state.paneStripState.panes.first?.title, "tile renamed")

        let updatedMissing = state.updatePane(id: PaneID("missing")) { $0.title = "nope" }
        XCTAssertFalse(updatedMissing)
    }

    func test_focusedPaneID_prefers_focused_float() {
        let state = worklane(
            tiles: [tileA, tileB],
            focusedTile: tileB.id,
            floats: [float(floatX, stackOrder: 0)],
            focusedFloatID: floatX.id
        )
        XCTAssertEqual(state.focusedPaneID, floatX.id)
    }

    func test_focusedPaneID_falls_back_to_strip_without_float_focus() {
        let state = worklane(
            tiles: [tileA, tileB],
            focusedTile: tileB.id,
            floats: [float(floatX, stackOrder: 0)]
        )
        XCTAssertEqual(state.focusedPaneID, tileB.id)
    }

    func test_focusedPaneID_ignores_pip_and_minimized_and_hidden() {
        let pip = worklane(
            tiles: [tileA],
            floats: [float(floatX, mode: .pip(corner: .topLeft, order: 0), stackOrder: 0)],
            focusedFloatID: floatX.id
        )
        XCTAssertEqual(pip.focusedPaneID, tileA.id)

        let minimized = worklane(
            tiles: [tileA],
            floats: [float(floatX, mode: .minimized(order: 0), stackOrder: 0)],
            focusedFloatID: floatX.id
        )
        XCTAssertEqual(minimized.focusedPaneID, tileA.id)

        let hidden = worklane(
            tiles: [tileA],
            floats: [float(floatX, stackOrder: 0)],
            floatsHidden: true,
            focusedFloatID: floatX.id
        )
        XCTAssertEqual(hidden.focusedPaneID, tileA.id)

        let stale = worklane(tiles: [tileA], focusedFloatID: PaneID("gone"))
        XCTAssertEqual(stale.focusedPaneID, tileA.id)
    }

    func test_hasLivePanes_true_for_float_only_worklane() {
        let floatOnly = worklane(tiles: [], floats: [float(floatX, mode: .minimized(order: 0), stackOrder: 0)])
        XCTAssertTrue(floatOnly.hasLivePanes)
        XCTAssertFalse(floatOnly.hasTiledPanes)

        let empty = worklane(tiles: [])
        XCTAssertFalse(empty.hasLivePanes)
        XCTAssertFalse(empty.hasTiledPanes)

        let tiled = worklane(tiles: [tileA])
        XCTAssertTrue(tiled.hasLivePanes)
        XCTAssertTrue(tiled.hasTiledPanes)
    }

    func test_visibleFloatCount_counts_floating_and_pip_only() {
        let floats = [
            float(floatX, stackOrder: 0),
            float(floatY, mode: .pip(corner: .bottomLeft, order: 0), stackOrder: 1),
            float(
                PaneState(id: PaneID("float-z"), title: "z"),
                mode: .minimized(order: 0),
                stackOrder: 2
            ),
        ]
        XCTAssertEqual(worklane(tiles: [tileA], floats: floats).visibleFloatCount, 2)
        XCTAssertEqual(worklane(tiles: [tileA], floats: floats, floatsHidden: true).visibleFloatCount, 0)
    }

    func test_normalizedRect_round_trips() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        let normalized = NormalizedRect(rect: rect, in: canvas)
        XCTAssertEqual(normalized.x, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(normalized.height, 0.5, accuracy: 0.000_001)

        let resolved = normalized.resolved(in: canvas)
        XCTAssertEqual(resolved.origin.x, rect.origin.x, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, rect.origin.y, accuracy: 0.001)
        XCTAssertEqual(resolved.width, rect.width, accuracy: 0.001)
        XCTAssertEqual(resolved.height, rect.height, accuracy: 0.001)
    }

    func test_normalizedRect_respects_canvas_origin_and_degenerate_canvas() {
        let canvas = CGRect(x: 200, y: 40, width: 800, height: 400)
        let rect = CGRect(x: 600, y: 240, width: 200, height: 100)
        let resolved = NormalizedRect(rect: rect, in: canvas).resolved(in: canvas)
        XCTAssertEqual(resolved.minX, 600, accuracy: 0.001)
        XCTAssertEqual(resolved.minY, 240, accuracy: 0.001)

        let degenerate = NormalizedRect(rect: rect, in: .zero)
        XCTAssertTrue(degenerate.x.isFinite)
        XCTAssertTrue(degenerate.width.isFinite)
    }

    func test_auxiliaryState_defaults_to_persistent_lifetime() {
        let aux = PaneAuxiliaryState()
        XCTAssertEqual(aux.lifetime, .persistent)
        XCTAssertFalse(aux.autoPopped)
    }

    func test_floats_change_may_move_focus() {
        XCTAssertTrue(WorklaneChange.floats(WorklaneID("w")).mayMoveFocus)
    }
}
