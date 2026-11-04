import CoreGraphics
import XCTest
@testable import Zentty

/// ⌥⌘H "Toggle Floating Panes": summons the worklane's floats from the strip,
/// dismisses them from a float, and opens one when there are none.
@MainActor
final class FloatToggleFloatingPanesTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")
    private let tileA = PaneID("a")
    private let tileB = PaneID("b")

    private func makeStore() -> WorklaneStore {
        let columns = [tileA, tileB].map { id in
            PaneColumnState(
                id: PaneColumnID("col_\(id.rawValue)"),
                panes: [PaneState(id: id, title: id.rawValue)],
                width: 400,
                focusedPaneID: id,
                lastFocusedPaneID: id
            )
        }
        var worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(columns: columns, focusedColumnID: PaneColumnID("col_b")),
            nextPaneNumber: 3
        )
        worklane.auxiliaryStateByPaneID[tileB] = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .local, path: "/tmp/b", home: nil, user: nil, host: nil)
        )
        return WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)
    }

    private func worklane(_ store: WorklaneStore) -> WorklaneState {
        store.worklanes[0]
    }

    private func addFloat(_ store: WorklaneStore) throws -> PaneID {
        try XCTUnwrap(store.newFloat(request: TerminalSessionRequest(workingDirectory: "/tmp"), canvas: canvas))
    }

    // MARK: - No floats at all

    func test_no_floats_opens_a_new_float_in_the_focused_panes_cwd() throws {
        let store = makeStore()

        let id = try XCTUnwrap(store.toggleFloatingPanes(canvas: canvas))

        let float = try XCTUnwrap(worklane(store).floatingPane(id: id))
        XCTAssertEqual(float.mode, .floating)
        XCTAssertEqual(float.pane.sessionRequest.workingDirectory, "/tmp/b")
        XCTAssertEqual(worklane(store).focusedPaneID, id)
        XCTAssertEqual(worklane(store).paneStripState.panes.map(\.id), [tileA, tileB], "the strip is untouched")
    }

    // MARK: - A float has focus

    func test_focused_float_hides_floats_and_pips_and_focus_returns_to_the_strip() throws {
        let store = makeStore()
        let pip = try addFloat(store)
        store.pipPane(pip)
        let float = try addFloat(store)
        XCTAssertTrue(worklane(store).floatOwnsFocus)

        XCTAssertNil(store.toggleFloatingPanes(canvas: canvas))

        XCTAssertTrue(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, tileB)
        XCTAssertEqual(worklane(store).floatingPane(id: float)?.mode, .floating, "hidden, not minimized")
        XCTAssertEqual(worklane(store).floatingPanes.count, 2, "nothing opened or closed")
    }

    // MARK: - Floats hidden

    func test_hidden_floats_show_and_refocus_the_last_focused_float() throws {
        let store = makeStore()
        let first = try addFloat(store)
        let second = try addFloat(store)
        store.focusFloat(first)
        store.toggleFloatingPanes(canvas: canvas)
        XCTAssertTrue(worklane(store).floatsHidden)

        XCTAssertEqual(store.toggleFloatingPanes(canvas: canvas), first)

        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, first, "the float focused before hiding")
        XCTAssertNotNil(worklane(store).floatingPane(id: second))
    }

    func test_hidden_pips_alone_show_without_taking_focus() throws {
        let store = makeStore()
        let pip = try addFloat(store)
        store.pipPane(pip)
        store.setFloatsHidden(true)

        store.toggleFloatingPanes(canvas: canvas)

        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, tileB, "PiPs never hold focus")
    }

    // MARK: - Shown, a tile has focus

    func test_tile_focus_with_shown_floats_focuses_the_front_float_without_hiding() throws {
        let store = makeStore()
        _ = try addFloat(store)
        let front = try addFloat(store)
        store.focusPane(id: tileA)
        XCTAssertFalse(worklane(store).floatOwnsFocus)

        XCTAssertEqual(store.toggleFloatingPanes(canvas: canvas), front)

        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, front)
        XCTAssertEqual(worklane(store).floatingPanes.count, 2, "no new float")
    }

    func test_tile_focus_with_only_shown_pips_hides_them_and_the_next_press_shows_them() throws {
        let store = makeStore()
        let pip = try addFloat(store)
        store.pipPane(pip)

        store.toggleFloatingPanes(canvas: canvas)
        XCTAssertTrue(worklane(store).floatsHidden)

        store.toggleFloatingPanes(canvas: canvas)
        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).floatingPane(id: pip)?.mode, .pip(corner: .bottomRight, order: 0))
    }

    // MARK: - Only pills

    func test_only_pills_restores_the_most_recent_pill() throws {
        let store = makeStore()
        let older = try addFloat(store)
        let newer = try addFloat(store)
        store.minimizePane(older)
        store.minimizePane(newer)

        XCTAssertEqual(store.toggleFloatingPanes(canvas: canvas), newer)

        XCTAssertEqual(worklane(store).floatingPane(id: newer)?.mode, .floating)
        XCTAssertEqual(worklane(store).focusedPaneID, newer)
        XCTAssertEqual(worklane(store).floatingPane(id: older)?.mode, .minimized(order: 0))
        XCTAssertEqual(worklane(store).floatingPanes.count, 2)
    }

    // MARK: - The capsule stays a pure hide/show toggle

    func test_capsule_toggle_hides_even_when_a_tile_has_focus() throws {
        let store = makeStore()
        _ = try addFloat(store)
        store.focusPane(id: tileA)

        store.toggleFloatsHidden()

        XCTAssertTrue(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, tileA)
    }
}
