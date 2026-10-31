import CoreGraphics
import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreFloatToggleTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")

    private func makeStore(tiles: [String], focused: String) -> WorklaneStore {
        let columns = tiles.map { id in
            PaneColumnState(
                id: PaneColumnID("col_\(id)"),
                panes: [PaneState(id: PaneID(id), title: id)],
                width: 400,
                focusedPaneID: PaneID(id),
                lastFocusedPaneID: PaneID(id)
            )
        }
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(columns: columns, focusedColumnID: PaneColumnID("col_\(focused)")),
            nextPaneNumber: tiles.count + 1
        )
        return WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)
    }

    func test_toggle_floats_the_focused_tile_in_place() throws {
        let store = makeStore(tiles: ["a", "b"], focused: "b")
        let tileFrame = CGRect(x: 600, y: 0, width: 600, height: 800)

        store.toggleFloat(canvas: canvas, tileFrame: { $0 == PaneID("b") ? tileFrame : nil })

        let worklane = store.worklanes[0]
        let float = try XCTUnwrap(worklane.floatingPane(id: PaneID("b")))
        XCTAssertEqual(float.mode, .floating)
        XCTAssertEqual(
            float.floatFrame.resolved(in: canvas),
            FloatLayout.liftedFrame(tileFrame: tileFrame, canvas: canvas)
        )
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [PaneID("a")])
        XCTAssertEqual(worklane.focusedPaneID, PaneID("b"))
    }

    func test_toggle_docks_a_focused_float_back_to_its_origin() {
        let store = makeStore(tiles: ["a", "b", "c"], focused: "b")
        store.toggleFloat(canvas: canvas, tileFrame: { _ in nil })

        store.toggleFloat(canvas: canvas, tileFrame: { _ in nil })

        let worklane = store.worklanes[0]
        XCTAssertTrue(worklane.floatingPanes.isEmpty)
        XCTAssertEqual(worklane.paneStripState.panes.map(\.id), [PaneID("a"), PaneID("b"), PaneID("c")])
        XCTAssertEqual(worklane.focusedPaneID, PaneID("b"))
    }

    func test_toggle_with_empty_canvas_falls_back_to_the_store_estimate() throws {
        let store = makeStore(tiles: ["a", "b"], focused: "a")

        store.toggleFloat(canvas: .zero, tileFrame: { _ in nil })

        let float = try XCTUnwrap(store.worklanes[0].floatingPane(id: PaneID("a")))
        XCTAssertGreaterThan(float.floatFrame.width, 0)
        XCTAssertGreaterThan(float.floatFrame.height, 0)
    }
}
