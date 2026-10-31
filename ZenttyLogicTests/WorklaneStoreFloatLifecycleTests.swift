import CoreGraphics
import XCTest
@testable import Zentty

/// Close, reopen, transfer and command flows that must treat floats as live
/// panes (audit sweep A over the store core).
@MainActor
final class WorklaneStoreFloatLifecycleTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let mainID = WorklaneID("wl_main")
    private let otherID = WorklaneID("wl_other")

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

    private func worklaneState(_ id: WorklaneID, tiles: [String]) -> WorklaneState {
        WorklaneState(
            id: id,
            title: nil,
            paneStripState: PaneStripState(
                columns: tiles.map(column),
                focusedColumnID: tiles.last.map { PaneColumnID("col_\($0)") }
            ),
            nextPaneNumber: tiles.count + 1,
            auxiliaryStateByPaneID: Dictionary(uniqueKeysWithValues: tiles.map {
                (PaneID($0), PaneAuxiliaryState(raw: PaneRawState(), presentation: PanePresentationState()))
            })
        )
    }

    private func makeStore(tiles: [String], otherTiles: [String]? = nil) -> WorklaneStore {
        var worklanes = [worklaneState(mainID, tiles: tiles)]
        if let otherTiles {
            worklanes.append(worklaneState(otherID, tiles: otherTiles))
        }
        return WorklaneStore(worklanes: worklanes, activeWorklaneID: mainID)
    }

    private func main(_ store: WorklaneStore) -> WorklaneState? {
        store.worklanes.first { $0.id == mainID }
    }

    private func stripIDs(_ store: WorklaneStore) -> [String] {
        main(store)?.paneStripState.panes.map(\.id.rawValue) ?? []
    }

    private func addFloat(_ store: WorklaneStore, lifetime: PaneLifetime = .persistent) -> PaneID {
        guard let id = store.newFloat(
            request: TerminalSessionRequest(workingDirectory: "/tmp"),
            canvas: canvas,
            lifetime: lifetime
        ) else {
            XCTFail("newFloat returned nil")
            return PaneID("missing")
        }
        return id
    }

    private func recordChanges(_ store: WorklaneStore) -> (subscription: WorklaneChangeSubscription, changes: () -> [WorklaneChange]) {
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }
        return (subscription, { changes })
    }

    // MARK: - Close

    func test_close_last_tile_with_floats_keeps_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)
        store.minimizePane(floatID)

        let result = store.closePane(id: PaneID("a"))

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.count, 2)
        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(stripIDs(store), [])
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
        XCTAssertNil(main(store)?.auxiliaryStateByPaneID[PaneID("a")])
    }

    func test_close_last_tile_hands_focus_to_front_float() {
        let store = makeStore(tiles: ["a"])
        let back = addFloat(store)
        let front = addFloat(store)
        store.focusPane(id: PaneID("a"))

        _ = store.closePane(id: PaneID("a"))

        XCTAssertTrue(main(store)?.isFloating(back) == true)
        XCTAssertEqual(main(store)?.focusedPaneID, front)
    }

    func test_close_float_returns_closed_and_clears_aux() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)
        XCTAssertNotNil(main(store)?.auxiliaryStateByPaneID[floatID])
        let recorder = recordChanges(store)

        let result = store.closePane(id: floatID)

        XCTAssertEqual(result, .closed)
        XCTAssertFalse(main(store)?.isFloating(floatID) == true)
        XCTAssertNil(main(store)?.auxiliaryStateByPaneID[floatID])
        XCTAssertEqual(stripIDs(store), ["a"])
        XCTAssertEqual(main(store)?.focusedPaneID, PaneID("a"))
        XCTAssertTrue(recorder.changes().contains(.floats(mainID)))
        withExtendedLifetime(recorder.subscription) {}
    }

    func test_closeFocusedPane_closes_focused_float_only() {
        let store = makeStore(tiles: ["a", "b"])
        let floatID = addFloat(store)

        let result = store.closeFocusedPane()

        XCTAssertEqual(result, .closed)
        XCTAssertFalse(main(store)?.isFloating(floatID) == true)
        XCTAssertEqual(stripIDs(store), ["a", "b"])
    }

    func test_close_float_keeps_pip_orders_dense() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        store.pipPane(first)
        store.pipPane(second)

        _ = store.closePane(id: first)

        XCTAssertEqual(main(store)?.floatingPane(id: second)?.mode, .pip(corner: .bottomRight, order: 0))
    }

    func test_shell_exit_of_float_removes_it() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        let result = store.closePaneFromShellExit(id: floatID)

        XCTAssertEqual(result, .closed)
        XCTAssertFalse(main(store)?.isFloating(floatID) == true)
        XCTAssertNil(main(store)?.auxiliaryStateByPaneID[floatID])
        XCTAssertEqual(stripIDs(store), ["a"])
        XCTAssertEqual(main(store)?.focusedPaneID, PaneID("a"))
    }

    func test_shell_exit_of_last_tile_keeps_float_only_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)

        let result = store.closePaneFromShellExit(id: PaneID("a"))

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(store.worklanes.count, 2)
        XCTAssertEqual(main(store)?.focusedPaneID, floatID)
    }

    func test_shell_exit_of_last_float_removes_float_only_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)
        _ = store.closePane(id: PaneID("a"))

        let result = store.closePaneFromShellExit(id: floatID)

        XCTAssertEqual(result, .closed)
        XCTAssertNil(main(store))
        XCTAssertEqual(store.activeWorklaneID, otherID)
    }

    func test_last_live_pane_in_only_worklane_requests_window_close() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)
        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)

        XCTAssertEqual(store.closePane(id: floatID), .closeWindow)
        XCTAssertEqual(store.closePaneFromShellExit(id: floatID), .closeWindow)
    }

    func test_closing_last_float_of_float_only_worklane_removes_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)
        _ = store.closePane(id: PaneID("a"))

        XCTAssertEqual(store.closePane(id: floatID), .closed)

        XCTAssertNil(main(store))
        XCTAssertEqual(store.activeWorklaneID, otherID)
    }

    // MARK: - Reopen

    func test_reopen_closed_float_restores_as_float() throws {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)
        let frame = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        store.moveFloat(floatID, frame: frame)
        _ = store.closePane(id: floatID)

        let result = try XCTUnwrap(store.restoreClosedPane())

        let restored = try XCTUnwrap(main(store)?.floatingPane(id: result.restoredPaneID))
        XCTAssertEqual(restored.mode, .floating)
        XCTAssertEqual(restored.floatFrame, frame)
        XCTAssertEqual(stripIDs(store), ["a"])
        XCTAssertEqual(main(store)?.focusedPaneID, result.restoredPaneID)
    }

    func test_closing_temporary_float_is_not_reopenable() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(
            store,
            lifetime: .temporary(owner: nil, placement: .worklane, waitAfterCommand: false)
        )

        _ = store.closePane(id: floatID)

        XCTAssertNil(store.restoreClosedPane())
    }

    // MARK: - Transfer

    func test_drag_last_tile_out_keeps_float_only_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)

        store.transferPaneToWorklane(paneID: PaneID("a"), targetWorklaneID: otherID, singleColumnWidth: 800)

        XCTAssertEqual(store.worklanes.count, 2)
        XCTAssertEqual(stripIDs(store), [])
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
        XCTAssertEqual(store.worklanes.first { $0.id == otherID }?.paneStripState.panes.map(\.id.rawValue), ["x", "a"])
    }

    func test_transferring_a_float_to_another_worklane_is_a_no_op() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)

        store.transferPaneToWorklane(paneID: floatID, targetWorklaneID: otherID, singleColumnWidth: 800)
        store.transferPaneToNewWorklane(paneID: floatID, singleColumnWidth: 800)

        XCTAssertEqual(store.worklanes.count, 2)
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
    }

    func test_extract_last_tile_with_floats_keeps_window_open() throws {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        let payload = try XCTUnwrap(
            store.extractPaneForCrossWindowTransfer(paneID: PaneID("a"), singleColumnWidth: 800)
        )

        XCTAssertFalse(payload.sourceWorklaneRemoved)
        XCTAssertFalse(payload.sourceWindowShouldClose)
        XCTAssertEqual(main(store)?.focusedPaneID, floatID)
    }

    func test_split_out_lone_tile_with_floats_leaves_floats_behind() throws {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        XCTAssertTrue(store.canSplitOutPaneToNewWindow(paneID: PaneID("a")))
        XCTAssertFalse(store.canSplitOutPaneToNewWindow(paneID: floatID))
        let result = try XCTUnwrap(
            store.splitOutPaneToNewWindow(paneID: PaneID("a"), destinationWindowID: WindowID("win_dest"))
        )

        XCTAssertFalse(result.sourceWindowShouldClose)
        XCTAssertEqual(result.destinationWorkspaceState.worklanes.first?.floatingPanes, [])
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
    }

    // MARK: - Pane data writes

    func test_launchDeferredPane_works_for_float() throws {
        let store = makeStore(tiles: ["a"])
        var request = TerminalSessionRequest(workingDirectory: "/tmp")
        request.isLaunchDeferred = true
        let floatID = try XCTUnwrap(store.newFloat(request: request, canvas: canvas))

        XCTAssertTrue(store.launchDeferredPane(id: floatID, nativeCommand: "  htop  "))

        let pane = try XCTUnwrap(main(store)?.pane(id: floatID))
        XCTAssertEqual(pane.sessionRequest.nativeCommand, "htop")
        XCTAssertFalse(pane.sessionRequest.isLaunchDeferred)
        XCTAssertTrue(pane.sessionRequest.waitAfterNativeCommand)
    }

    func test_rename_float_pane_title() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)
        let recorder = recordChanges(store)

        XCTAssertTrue(store.setPaneTitle(id: floatID, title: " logs "))

        XCTAssertEqual(main(store)?.pane(id: floatID)?.title, "logs")
        XCTAssertTrue(recorder.changes().contains(.floats(mainID)))
        withExtendedLifetime(recorder.subscription) {}
    }

    // MARK: - Strip commands with a focused float

    func test_duplicate_with_focused_float_opens_offset_float() throws {
        let store = makeStore(tiles: ["a"])
        let source = addFloat(store)

        store.send(.duplicateFocusedPane)

        let worklane = try XCTUnwrap(main(store))
        XCTAssertEqual(stripIDs(store), ["a"])
        XCTAssertEqual(worklane.floatingPanes.count, 2)
        let duplicateID = try XCTUnwrap(worklane.focusedFloatID)
        XCTAssertNotEqual(duplicateID, source)
        let sourceFrame = try XCTUnwrap(worklane.floatingPane(id: source)?.floatFrame)
        let duplicateFrame = try XCTUnwrap(worklane.floatingPane(id: duplicateID)?.floatFrame)
        XCTAssertGreaterThan(duplicateFrame.x, sourceFrame.x)
        XCTAssertLessThan(duplicateFrame.y, sourceFrame.y)
    }

    func test_focus_move_from_float_returns_to_strip_focus() {
        let store = makeStore(tiles: ["a", "b"])
        _ = addFloat(store)

        store.send(.focusLeft)

        XCTAssertNil(main(store)?.focusedFloatID)
        XCTAssertEqual(main(store)?.focusedPaneID, PaneID("b"))
    }

    func test_move_command_with_focused_float_leaves_strip_untouched() {
        let store = makeStore(tiles: ["a", "b"])
        let floatID = addFloat(store)

        store.send(.moveLeft)

        XCTAssertEqual(stripIDs(store), ["a", "b"])
        XCTAssertEqual(main(store)?.focusedPaneID, floatID)
    }

    func test_split_command_with_focused_float_focuses_new_tile() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        store.send(.splitVertically)

        XCTAssertEqual(stripIDs(store).count, 2)
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
        XCTAssertNil(main(store)?.focusedFloatID)
        XCTAssertEqual(main(store)?.focusedPaneID, main(store)?.paneStripState.focusedPaneID)
    }

    func test_splitWithLayout_targeting_float_splits_at_strip_focus() throws {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        let newID = store.splitWithLayout(
            placement: .afterFocused,
            isHorizontal: true,
            layout: .none,
            availableWidth: 1200,
            leadingVisibleInset: 0,
            availableSize: canvas.size,
            minimumSizeByPaneID: [:],
            targetPaneID: floatID,
            preserveFocusPaneID: floatID
        )

        let newPaneID = try XCTUnwrap(newID)
        XCTAssertEqual(stripIDs(store), ["a", newPaneID.rawValue])
        XCTAssertTrue(main(store)?.isFloating(floatID) == true)
        XCTAssertEqual(main(store)?.focusedPaneID, floatID)
    }

    func test_applyGrid_with_floated_source_docks_it_into_the_grid() throws {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)
        _ = store.closePane(id: PaneID("a"))

        let result = try store.applyGrid(
            sourcePaneID: floatID,
            rows: 1,
            columns: 2,
            command: nil,
            includeSource: true,
            focus: .source
        )

        let worklane = try XCTUnwrap(store.worklanes.first { $0.id == result.worklaneID })
        XCTAssertEqual(worklane.floatingPanes, [])
        XCTAssertEqual(worklane.paneStripState.panes.first?.id, floatID)
        XCTAssertEqual(worklane.paneStripState.panes.count, 2)
    }

    func test_sidebar_order_cycles_through_floating_floats_only() {
        let store = makeStore(tiles: ["a"])
        let floating = addFloat(store)
        let pip = addFloat(store)
        store.pipPane(pip)
        store.focusPane(id: PaneID("a"))

        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(main(store)?.focusedPaneID, floating)

        store.send(.focusNextPaneBySidebarOrder)
        XCTAssertEqual(main(store)?.focusedPaneID, PaneID("a"))
    }

    func test_selectWorklaneAndFocusPane_focuses_float_in_other_worklane() {
        let store = makeStore(tiles: ["a"], otherTiles: ["x"])
        let floatID = addFloat(store)
        store.minimizePane(floatID)
        store.selectWorklane(id: otherID)

        store.selectWorklaneAndFocusPane(worklaneID: mainID, paneID: floatID)

        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(main(store)?.floatingPane(id: floatID)?.mode, .floating)
        XCTAssertEqual(main(store)?.focusedPaneID, floatID)
    }

    // MARK: - Contexts

    func test_focusedPaneContext_and_border_labels_see_floats() {
        let store = makeStore(tiles: ["a"])
        let floatID = addFloat(store)

        XCTAssertEqual(main(store)?.focusedPaneContext?.paneID, floatID)
        XCTAssertEqual(main(store)?.paneContextsPrioritizingFocus.first?.paneID, floatID)
        XCTAssertEqual(main(store)?.paneContext(for: floatID)?.paneID, floatID)
    }
}
