import CoreGraphics
import XCTest
@testable import Zentty

/// Focus invariants with floats: `focusedFloatID` only names a shown
/// `.floating` float, and history, cycling, strip moves and splits never land
/// keyboard focus on a PiP, a pill or a hidden float, nor drop it to nothing.
@MainActor
final class WorklaneStoreFloatFocusTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")

    // MARK: - Fixtures

    private func column(_ id: String) -> PaneColumnState {
        PaneColumnState(
            id: PaneColumnID("col_\(id)"),
            panes: [PaneState(id: PaneID(id), title: id)],
            width: 400,
            focusedPaneID: PaneID(id),
            lastFocusedPaneID: PaneID(id)
        )
    }

    private func makeStore(tiles: [String], focused: String? = nil) -> WorklaneStore {
        let columns = tiles.map(column)
        let focusedColumn = (focused ?? tiles.last).map { PaneColumnID("col_\($0)") }
        let worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(columns: columns, focusedColumnID: focusedColumn),
            nextPaneNumber: tiles.count + 1
        )
        return WorklaneStore(worklanes: [worklane], activeWorklaneID: worklaneID)
    }

    private func worklane(_ store: WorklaneStore) -> WorklaneState {
        store.worklanes[0]
    }

    private func addFloat(_ store: WorklaneStore) -> PaneID {
        guard let id = store.newFloat(
            request: TerminalSessionRequest(workingDirectory: "/tmp"),
            canvas: canvas,
            lifetime: .persistent
        ) else {
            XCTFail("newFloat returned nil")
            return PaneID("missing")
        }
        return id
    }

    /// Commits the debounced history entry so back/forward can see it.
    private func commitHistory(_ store: WorklaneStore) {
        store.focusHistoryController.commitPending()
    }

    private func split(
        _ store: WorklaneStore,
        isHorizontal: Bool,
        preserveFocusPaneID: PaneID? = nil
    ) -> PaneID? {
        store.splitWithLayout(
            placement: .afterFocused,
            isHorizontal: isHorizontal,
            layout: .none,
            availableWidth: canvas.width,
            leadingVisibleInset: 0,
            availableSize: canvas.size,
            minimumSizeByPaneID: [:],
            preserveFocusPaneID: preserveFocusPaneID,
            sessionRequest: TerminalSessionRequest(isLaunchDeferred: true)
        )
    }

    // MARK: - Sidebar-order cycling

    func test_cycling_visits_tile_then_floats_in_creation_order_both_ways() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        store.focusPane(id: PaneID("a"))

        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, first)
        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, second)
        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))

        store.send(.focusPreviousPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, second)
        store.send(.focusPreviousPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, first)
        store.send(.focusPreviousPaneBySidebarOrder)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_cycling_skips_hidden_floats_and_keeps_them_hidden() {
        let store = makeStore(tiles: ["a", "b"])
        let float = addFloat(store)
        store.setFloatsHidden(true)
        store.focusPane(id: PaneID("b"))

        store.send(.focusNextPaneBySidebarOrder)

        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
        XCTAssertTrue(worklane(store).floatsHidden)
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).floatingPane(id: float)?.mode, .floating)
    }

    func test_cycling_skips_pip_and_minimized_floats() {
        let store = makeStore(tiles: ["a", "b"])
        let pip = addFloat(store)
        let pill = addFloat(store)
        store.pipPane(pip, corner: .bottomRight)
        store.minimizePane(pill)
        store.focusPane(id: PaneID("b"))

        store.send(.focusNextPaneBySidebarOrder)

        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
        XCTAssertEqual(worklane(store).floatingPane(id: pip)?.mode.isFloating, false)
        XCTAssertEqual(worklane(store).floatingPane(id: pill)?.mode.isFloating, false)
    }

    // MARK: - History back / forward

    func test_navigateBack_skips_minimized_float_without_restoring_it() {
        let store = makeStore(tiles: ["a", "b"], focused: "a")
        let float = addFloat(store)
        commitHistory(store)
        store.focusPane(id: PaneID("b"))
        commitHistory(store)
        store.minimizePane(float)

        store.navigateBack()

        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).floatingPane(id: float)?.mode.isFloating, false)
    }

    func test_navigateBack_skips_hidden_float_without_unhiding() {
        let store = makeStore(tiles: ["a", "b"], focused: "a")
        _ = addFloat(store)
        commitHistory(store)
        store.focusPane(id: PaneID("b"))
        commitHistory(store)
        store.setFloatsHidden(true)

        store.navigateBack()

        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
        XCTAssertTrue(worklane(store).floatsHidden)
    }

    // MARK: - Strip focus moves

    func test_strip_focus_move_in_float_only_worklane_keeps_float_focus() {
        let store = makeStore(tiles: ["only"])
        let id = PaneID("only")
        store.floatPane(id, canvas: canvas, tileFrame: nil)

        for command in [PaneCommand.focusLeft, .focusRight, .focusUp, .focusDown, .focusFirst, .focusLast] {
            store.send(command)
            XCTAssertEqual(worklane(store).focusedFloatID, id, "\(command)")
            XCTAssertEqual(worklane(store).focusedPaneID, id, "\(command)")
        }
    }

    func test_strip_focus_move_from_float_with_tiles_returns_to_strip() {
        let store = makeStore(tiles: ["a"])
        _ = addFloat(store)

        store.send(.focusLeft)

        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    // MARK: - Split preserving focus

    func test_split_preserving_pip_float_keeps_prior_strip_focus() {
        let store = makeStore(tiles: ["a"])
        let leader = addFloat(store)
        store.pipPane(leader, corner: .bottomRight)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))

        let newPaneID = split(store, isHorizontal: true, preserveFocusPaneID: leader)

        XCTAssertNotNil(newPaneID)
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_split_preserving_hidden_float_keeps_prior_strip_focus() {
        let store = makeStore(tiles: ["a"])
        let leader = addFloat(store)
        store.setFloatsHidden(true)

        _ = split(store, isHorizontal: true, preserveFocusPaneID: leader)

        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_split_preserving_floating_float_keeps_it_focused() {
        let store = makeStore(tiles: ["a"])
        let leader = addFloat(store)

        let newPaneID = split(store, isHorizontal: true, preserveFocusPaneID: leader)

        XCTAssertNotNil(newPaneID)
        XCTAssertEqual(worklane(store).focusedFloatID, leader)
        XCTAssertEqual(worklane(store).focusedPaneID, leader)
    }

    // MARK: - Un-hide

    func test_unhide_in_float_only_worklane_gives_focus_back_to_front_float() {
        let store = makeStore(tiles: ["only"])
        let id = PaneID("only")
        store.floatPane(id, canvas: canvas, tileFrame: nil)
        store.setFloatsHidden(true)
        XCTAssertNil(worklane(store).focusedPaneID)

        store.setFloatsHidden(false)

        XCTAssertEqual(worklane(store).focusedFloatID, id)
        XCTAssertEqual(worklane(store).focusedPaneID, id)
    }

    func test_unhide_with_tiles_leaves_strip_focus() {
        let store = makeStore(tiles: ["a"])
        _ = addFloat(store)
        store.setFloatsHidden(true)

        store.setFloatsHidden(false)

        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    // MARK: - Split Down from a float

    func test_split_down_from_float_ignores_strip_min_height() {
        let store = makeStore(tiles: ["a"])
        let float = addFloat(store)
        store.updatePaneViewportHeight(100)
        let stripBefore = worklane(store).paneStripState

        store.send(.splitVertically)

        XCTAssertEqual(worklane(store).paneStripState, stripBefore, "the strip is untouched")
        XCTAssertEqual(worklane(store).floatingPanes.count, 2, "a new float opens beside the focused one")
        XCTAssertNotEqual(worklane(store).focusedPaneID, float)
        XCTAssertTrue(worklane(store).floatOwnsFocus)
    }

    func test_ipc_split_down_in_float_only_worklane_returns_nil_and_keeps_focus() {
        let store = makeStore(tiles: ["only"])
        let id = PaneID("only")
        store.floatPane(id, canvas: canvas, tileFrame: nil)
        let before = worklane(store)

        let newPaneID = split(store, isHorizontal: false)

        XCTAssertNil(newPaneID)
        XCTAssertEqual(worklane(store), before)
        XCTAssertEqual(worklane(store).focusedPaneID, id)
    }
}
