import CoreGraphics
import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreFloatTests: XCTestCase {
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

    private func stripIDs(_ store: WorklaneStore) -> [String] {
        worklane(store).paneStripState.panes.map(\.id.rawValue)
    }

    private func mode(_ store: WorklaneStore, _ id: PaneID) -> FloatingPaneMode? {
        worklane(store).floatingPane(id: id)?.mode
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

    private func assertRect(
        _ actual: CGRect?,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("missing rect", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func recordChanges(_ store: WorklaneStore) -> (subscription: WorklaneChangeSubscription, changes: () -> [WorklaneChange]) {
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }
        return (subscription, { changes })
    }

    // MARK: - Float

    func test_float_removes_from_strip_and_keeps_aux_state() {
        let store = makeStore(tiles: ["a", "b"])
        let id = PaneID("b")
        let marker = PaneLifetime.temporary(owner: nil, placement: .worklane, waitAfterCommand: true)
        var aux = PaneAuxiliaryState(raw: PaneRawState(), presentation: PanePresentationState())
        aux.lifetime = marker
        store.worklanes[0].auxiliaryStateByPaneID[id] = aux

        store.floatPane(id, canvas: canvas, tileFrame: CGRect(x: 600, y: 0, width: 600, height: 800))

        XCTAssertEqual(stripIDs(store), ["a"])
        let float = worklane(store).floatingPane(id: id)
        XCTAssertEqual(float?.mode, .floating)
        XCTAssertEqual(float?.origin, FloatOrigin(columnIndex: 1))
        assertRect(float?.floatFrame.resolved(in: canvas), CGRect(x: 622, y: 22, width: 556, height: 756))
        XCTAssertEqual(worklane(store).auxiliaryStateByPaneID[id]?.lifetime, marker)
        XCTAssertEqual(worklane(store).focusedFloatID, id)
        XCTAssertEqual(worklane(store).focusedPaneID, id)
    }

    func test_float_last_tile_keeps_worklane() {
        let store = makeStore(tiles: ["only"])
        let id = PaneID("only")

        store.floatPane(id, canvas: canvas, tileFrame: nil)

        XCTAssertEqual(store.worklanes.count, 1)
        XCTAssertFalse(worklane(store).hasTiledPanes)
        XCTAssertTrue(worklane(store).hasLivePanes)
        XCTAssertNil(worklane(store).paneStripState.focusedPaneID)
        XCTAssertEqual(worklane(store).focusedPaneID, id)
        assertRect(
            worklane(store).floatingPane(id: id)?.floatFrame.resolved(in: canvas),
            CGRect(x: 240, y: 160, width: 720, height: 480)
        )
    }

    func test_float_notifies_floats_and_paneStructure() {
        let store = makeStore(tiles: ["a", "b"])
        let recorder = recordChanges(store)
        defer { store.unsubscribe(recorder.subscription) }

        store.floatPane(PaneID("a"), canvas: canvas, tileFrame: nil)

        XCTAssertTrue(recorder.changes().contains(.paneStructure(worklaneID)))
        XCTAssertTrue(recorder.changes().contains(.floats(worklaneID)))
    }

    func test_float_unhides_floats() {
        let store = makeStore(tiles: ["a", "b"])
        store.setFloatsHidden(true)

        store.floatPane(PaneID("a"), canvas: canvas, tileFrame: nil)

        XCTAssertFalse(worklane(store).floatsHidden)
    }

    // MARK: - Dock

    func test_dock_origin_returns_to_original_column_index() {
        let store = makeStore(tiles: ["a", "b", "c"], focused: "b")
        let id = PaneID("b")
        store.floatPane(id, canvas: canvas, tileFrame: nil)
        XCTAssertEqual(stripIDs(store), ["a", "c"])

        store.dockPane(id, target: .origin)

        XCTAssertEqual(stripIDs(store), ["a", "b", "c"])
        XCTAssertTrue(worklane(store).floatingPanes.isEmpty)
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).paneStripState.focusedPaneID, id)
    }

    func test_dock_origin_beyond_strip_inserts_after_focused_column() {
        let store = makeStore(tiles: ["a", "b", "c"], focused: "c")
        let id = PaneID("c")
        store.floatPane(id, canvas: canvas, tileFrame: nil)
        store.floatPane(PaneID("b"), canvas: canvas, tileFrame: nil)
        store.focusPane(id: PaneID("a"))

        store.dockPane(id, target: .origin)

        XCTAssertEqual(stripIDs(store), ["a", "c"])
    }

    func test_dock_promotes_temporary_lifetime() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store, lifetime: .temporary(owner: PaneID("a"), placement: .pane, waitAfterCommand: false))

        store.dockPane(id, target: .columnGap(index: 0))

        XCTAssertEqual(stripIDs(store), [id.rawValue, "a"])
        XCTAssertEqual(worklane(store).auxiliaryStateByPaneID[id]?.lifetime, .persistent)
    }

    func test_dock_stackGap_inserts_into_column() {
        let store = makeStore(tiles: ["a", "b"])
        let id = addFloat(store)

        store.dockPane(id, target: .stackGap(columnID: PaneColumnID("col_a"), paneIndex: 1))

        let columnA = worklane(store).paneStripState.columns.first { $0.id == PaneColumnID("col_a") }
        XCTAssertEqual(columnA?.panes.map(\.id), [PaneID("a"), id])
        XCTAssertFalse(worklane(store).isFloating(id))
    }

    func test_dock_split_horizontal_leading_places_left_of_target() {
        let store = makeStore(tiles: ["a", "b"])
        let id = addFloat(store)

        store.dockPane(id, target: .split(target: PaneID("b"), axis: .horizontal, leading: true))

        XCTAssertEqual(stripIDs(store), ["a", id.rawValue, "b"])
    }

    func test_dock_to_missing_column_keeps_float() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)

        store.dockPane(id, target: .stackGap(columnID: PaneColumnID("col_gone"), paneIndex: 0))

        XCTAssertTrue(worklane(store).isFloating(id))
        XCTAssertEqual(stripIDs(store), ["a"])
    }

    // MARK: - PiP

    func test_pip_defaults_to_bottom_right_and_drops_focus() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)

        store.pipPane(id, corner: nil)

        XCTAssertEqual(mode(store, id), .pip(corner: .bottomRight, order: 0))
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_pip_third_in_corner_minimizes_oldest() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        let third = addFloat(store)

        store.pipPane(first, corner: .topLeft)
        store.pipPane(second, corner: .topLeft)
        store.pipPane(third, corner: .topLeft)

        XCTAssertEqual(mode(store, first), .minimized(order: 0))
        XCTAssertEqual(mode(store, second), .pip(corner: .topLeft, order: 0))
        XCTAssertEqual(mode(store, third), .pip(corner: .topLeft, order: 1))
    }

    func test_movePip_compacts_source_corner_and_appends_to_target() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        let third = addFloat(store)
        store.pipPane(first, corner: .bottomRight)
        store.pipPane(second, corner: .bottomRight)
        store.pipPane(third, corner: .topRight)

        store.movePip(first, to: .topRight)

        XCTAssertEqual(mode(store, second), .pip(corner: .bottomRight, order: 0))
        XCTAssertEqual(mode(store, third), .pip(corner: .topRight, order: 0))
        XCTAssertEqual(mode(store, first), .pip(corner: .topRight, order: 1))
    }

    func test_pip_unhides_floats() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)
        store.setFloatsHidden(true)

        store.pipPane(id, corner: .bottomLeft)

        XCTAssertFalse(worklane(store).floatsHidden)
    }

    // MARK: - Minimize / restore

    func test_minimize_focused_float_moves_focus_to_previous_eligible() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        XCTAssertEqual(worklane(store).focusedFloatID, second)

        store.minimizePane(second)

        XCTAssertEqual(mode(store, second), .minimized(order: 0))
        XCTAssertEqual(worklane(store).focusedFloatID, first)
        XCTAssertEqual(worklane(store).focusedPaneID, first)
    }

    func test_minimize_skips_ineligible_history_and_falls_back_to_strip() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        store.pipPane(first, corner: .bottomRight)
        store.focusFloat(second)

        store.minimizePane(second)

        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_minimize_last_float_of_float_only_worklane_leaves_no_focus() {
        let store = makeStore(tiles: ["only"])
        store.floatPane(PaneID("only"), canvas: canvas, tileFrame: nil)

        store.minimizePane(PaneID("only"))

        XCTAssertNil(worklane(store).focusedPaneID)
        XCTAssertTrue(worklane(store).hasLivePanes)
    }

    func test_minimized_orders_stay_dense_newest_last() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        let third = addFloat(store)
        store.minimizePane(first)
        store.minimizePane(second)
        store.minimizePane(third)

        store.restoreFloat(second)

        XCTAssertEqual(mode(store, first), .minimized(order: 0))
        XCTAssertEqual(mode(store, third), .minimized(order: 1))
    }

    func test_restore_from_minimized_raises_and_focuses() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        let second = addFloat(store)
        store.minimizePane(first)

        store.restoreFloat(first)

        let state = worklane(store)
        XCTAssertEqual(mode(store, first), .floating)
        XCTAssertGreaterThan(
            state.floatingPane(id: first)?.stackOrder ?? -1,
            state.floatingPane(id: second)?.stackOrder ?? Int.max
        )
        XCTAssertEqual(state.focusedFloatID, first)
        XCTAssertEqual(state.focusedPaneID, first)
    }

    // MARK: - Hide, move, raise, focus

    func test_setFloatsHidden_clears_float_focus() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)

        store.setFloatsHidden(true)

        XCTAssertTrue(worklane(store).floatsHidden)
        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
        XCTAssertTrue(worklane(store).isFloating(id))
    }

    func test_moveFloat_updates_frame_and_notifies_only_floats() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)
        let recorder = recordChanges(store)
        defer { store.unsubscribe(recorder.subscription) }
        let frame = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

        store.moveFloat(id, frame: frame)

        XCTAssertEqual(worklane(store).floatingPane(id: id)?.floatFrame, frame)
        XCTAssertEqual(recorder.changes(), [.floats(worklaneID)])
    }

    func test_raiseFloat_brings_float_to_front() {
        let store = makeStore(tiles: ["a"])
        let back = addFloat(store)
        let front = addFloat(store)

        store.raiseFloat(back)

        let state = worklane(store)
        XCTAssertGreaterThan(
            state.floatingPane(id: back)?.stackOrder ?? -1,
            state.floatingPane(id: front)?.stackOrder ?? Int.max
        )
        XCTAssertEqual(state.floatsByStackOrder.last?.pane.id, back)
        XCTAssertEqual(state.allPanes.last?.id, front, "raising never renumbers floats")
    }

    func test_new_floats_get_increasing_sequences() {
        let store = makeStore(tiles: ["a", "b"])
        let first = addFloat(store)
        store.floatPane(PaneID("b"), canvas: canvas, tileFrame: nil)
        let third = addFloat(store)

        let sequences = [first, PaneID("b"), third].map { worklane(store).floatingPane(id: $0)?.sequence ?? -1 }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, 3)
        XCTAssertEqual(worklane(store).allPanes.map(\.id), [PaneID("a"), first, PaneID("b"), third])
    }

    func test_focusPane_on_tile_clears_float_focus() {
        let store = makeStore(tiles: ["a"])
        _ = addFloat(store)

        store.focusPane(id: PaneID("a"))

        XCTAssertNil(worklane(store).focusedFloatID)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"))
    }

    func test_focusPane_on_float_focuses_it() {
        let store = makeStore(tiles: ["a"])
        let first = addFloat(store)
        _ = addFloat(store)

        store.focusPane(id: first)

        XCTAssertEqual(worklane(store).focusedFloatID, first)
    }

    func test_focusFloat_on_pip_restores_it() {
        let store = makeStore(tiles: ["a"])
        let id = addFloat(store)
        store.pipPane(id, corner: .topRight)

        store.focusFloat(id)

        XCTAssertEqual(mode(store, id), .floating)
        XCTAssertEqual(worklane(store).focusedFloatID, id)
    }

    // MARK: - New float

    func test_newFloat_temporary_not_in_strip() {
        let store = makeStore(tiles: ["a"])
        let lifetime = PaneLifetime.temporary(owner: nil, placement: .worklane, waitAfterCommand: false)
        let id = addFloat(store, lifetime: lifetime)

        let state = worklane(store)
        XCTAssertEqual(stripIDs(store), ["a"])
        XCTAssertTrue(state.isFloating(id))
        XCTAssertEqual(state.floatingPane(id: id)?.mode, .floating)
        XCTAssertNil(state.floatingPane(id: id)?.origin)
        XCTAssertEqual(state.auxiliaryStateByPaneID[id]?.lifetime, lifetime)
        XCTAssertEqual(state.pane(id: id)?.sessionRequest.workingDirectory, "/tmp")
        XCTAssertEqual(state.focusedFloatID, id)
        XCTAssertEqual(state.nextPaneNumber, 3)
    }

    func test_newFloat_initialFrame_is_clamped_to_minimum_and_canvas() {
        let store = makeStore(tiles: ["a"])
        let id = store.newFloat(
            request: TerminalSessionRequest(workingDirectory: "/tmp"),
            canvas: canvas,
            initialFrame: CGRect(x: 1100, y: 700, width: 100, height: 50)
        )

        let frame = id.flatMap { worklane(store).floatingPane(id: $0)?.floatFrame.resolved(in: canvas) }
        assertRect(frame, CGRect(x: 900, y: 630, width: 300, height: 170))
    }

    // MARK: - Float commands (Task 14)

    func test_cycle_float_focus_uses_stable_sequence_not_stack_order() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)
        let f1 = addFloat(store)
        let f2 = addFloat(store)
        XCTAssertEqual(worklane(store).focusedPaneID, f2)

        var visited: [PaneID?] = []
        for _ in 0..<4 {
            store.cycleFloatFocus()
            visited.append(worklane(store).focusedPaneID)
        }

        XCTAssertEqual(visited, [f0, f1, f2, f0], "each focus raises, but the cycle follows creation order")
        XCTAssertEqual(worklane(store).floatsByStackOrder.last?.pane.id, f0)
    }

    func test_cycle_from_strip_focuses_front_most_float() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)
        _ = addFloat(store)
        store.focusFloat(f0)
        store.focusPane(id: PaneID("a"))
        XCTAssertFalse(worklane(store).floatOwnsFocus)

        store.cycleFloatFocus()

        XCTAssertEqual(worklane(store).focusedPaneID, f0, "the raised float is front-most")
    }

    func test_cycle_skips_pip_and_minimized() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)
        let f1 = addFloat(store)
        let f2 = addFloat(store)
        let f3 = addFloat(store)
        store.pipPane(f1)
        store.minimizePane(f2)
        store.focusFloat(f0)

        store.cycleFloatFocus()
        XCTAssertEqual(worklane(store).focusedPaneID, f3)
        store.cycleFloatFocus()
        XCTAssertEqual(worklane(store).focusedPaneID, f0)
        XCTAssertEqual(mode(store, f1), .pip(corner: .bottomRight, order: 0))
        XCTAssertEqual(mode(store, f2), .minimized(order: 0))
    }

    func test_cycle_with_no_floating_float_is_a_no_op() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)
        store.pipPane(f0)
        let before = worklane(store)

        store.cycleFloatFocus()

        XCTAssertEqual(worklane(store), before)
    }

    func test_cycle_unhides_hidden_floats() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)
        store.setFloatsHidden(true)
        XCTAssertFalse(worklane(store).floatOwnsFocus)

        store.cycleFloatFocus()

        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, f0)
    }

    func test_toggle_floats_hidden_round_trips() {
        let store = makeStore(tiles: ["a"])
        let f0 = addFloat(store)

        store.toggleFloatsHidden()
        XCTAssertTrue(worklane(store).floatsHidden)
        XCTAssertEqual(worklane(store).focusedPaneID, PaneID("a"), "hiding drops float focus")

        store.toggleFloatsHidden()
        XCTAssertFalse(worklane(store).floatsHidden)
        XCTAssertEqual(mode(store, f0), .floating)
    }

    func test_newFloatFromFocus_inherits_focused_float_cwd() throws {
        let store = makeStore(tiles: ["a", "b"])
        setCwd(store, PaneID("a"), "/tmp/a")
        setCwd(store, PaneID("b"), "/tmp/b")
        store.floatPane(PaneID("b"), canvas: canvas, tileFrame: nil)
        store.focusPane(id: PaneID("b"))
        XCTAssertTrue(worklane(store).floatOwnsFocus)

        let id = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))

        let float = try XCTUnwrap(worklane(store).floatingPane(id: id))
        XCTAssertEqual(float.pane.sessionRequest.workingDirectory, "/tmp/b")
        XCTAssertNil(float.pane.sessionRequest.command, "a new shell, not a duplicate")
        XCTAssertEqual(worklane(store).focusedPaneID, id)
        XCTAssertEqual(worklane(store).auxiliaryStateByPaneID[id]?.lifetime, .persistent)
        XCTAssertEqual(stripIDs(store), ["a"], "the strip is untouched")
    }

    func test_newFloatFromFocus_centred_60_percent() throws {
        let store = makeStore(tiles: ["a"])
        setCwd(store, PaneID("a"), "/tmp/a")

        let id = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))

        let frame = worklane(store).floatingPane(id: id)?.floatFrame.resolved(in: canvas)
        assertRect(frame, CGRect(x: 240, y: 160, width: 720, height: 480))
        XCTAssertEqual(worklane(store).floatingPane(id: id)?.pane.sessionRequest.workingDirectory, "/tmp/a")
    }

    func test_newFloatFromFocus_opens_in_empty_worklane() throws {
        let store = makeStore(tiles: [])

        let id = try XCTUnwrap(store.newFloatFromFocus(canvas: canvas))

        XCTAssertEqual(worklane(store).focusedPaneID, id)
        XCTAssertTrue(worklane(store).floatOwnsFocus)
    }

    private func setCwd(_ store: WorklaneStore, _ id: PaneID, _ path: String) {
        var worklanes = store.worklanes
        worklanes[0].auxiliaryStateByPaneID[id] = PaneAuxiliaryState(
            shellContext: PaneShellContext(scope: .local, path: path, home: nil, user: nil, host: nil)
        )
        store.replaceWorklanes(worklanes, activeWorklaneID: worklaneID)
    }
}
