import CoreGraphics
import XCTest
@testable import Zentty

/// The store side of `zentty pane float|dock|pip|minimize|restore` and
/// `zentty float new|list|hide|show`: target-state semantics, worklanes that
/// are not on screen, and the list payload.
@MainActor
final class WorklaneStoreFloatCommandsTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let mainID = WorklaneID("wl_main")
    private let otherID = WorklaneID("wl_other")
    private let a = PaneID("pn_a")
    private let b = PaneID("pn_b")
    private let c = PaneID("pn_c")
    private let x = PaneID("pn_x")

    // MARK: - Fixtures

    /// `wl_main` (active): tiles a, b, c (c focused), cwd /tmp/<id>.
    /// `wl_other`: tile x.
    private func makeStore() -> WorklaneStore {
        WorklaneStore(
            worklanes: [
                worklane(mainID, tiles: [a, b, c]),
                worklane(otherID, tiles: [x]),
            ],
            activeWorklaneID: mainID
        )
    }

    private func worklane(_ id: WorklaneID, tiles: [PaneID]) -> WorklaneState {
        WorklaneState(
            id: id,
            title: nil,
            paneStripState: PaneStripState(
                columns: tiles.map { tile in
                    PaneColumnState(
                        id: PaneColumnID("col_\(tile.rawValue)"),
                        panes: [PaneState(id: tile, title: tile.rawValue)],
                        width: 400,
                        focusedPaneID: tile,
                        lastFocusedPaneID: tile
                    )
                },
                focusedColumnID: tiles.last.map { PaneColumnID("col_\($0.rawValue)") }
            ),
            nextPaneNumber: tiles.count + 1,
            auxiliaryStateByPaneID: Dictionary(uniqueKeysWithValues: tiles.map { tile in
                (tile, PaneAuxiliaryState(shellContext: PaneShellContext(
                    scope: .local, path: "/tmp/\(tile.rawValue)", home: nil, user: nil, host: nil
                )))
            })
        )
    }

    private func state(_ store: WorklaneStore, _ id: WorklaneID? = nil) -> WorklaneState {
        store.worklanes.first { $0.id == (id ?? mainID) }!
    }

    private func mode(_ store: WorklaneStore, _ pane: PaneID, in id: WorklaneID? = nil) -> FloatingPaneMode? {
        state(store, id).floatingPane(id: pane)?.mode
    }

    private func stripIDs(_ store: WorklaneStore, _ id: WorklaneID? = nil) -> [PaneID] {
        state(store, id).paneStripState.panes.map(\.id)
    }

    private func apply(
        _ store: WorklaneStore,
        _ action: PaneFloatAction,
        _ pane: PaneID,
        corner: FloatCorner? = nil,
        tileFrame: CGRect? = nil
    ) throws {
        try store.applyFloatAction(action, to: pane, corner: corner, canvas: canvas, tileFrame: tileFrame)
    }

    // MARK: - pane float

    func test_float_lifts_a_tile_and_is_idempotent() throws {
        let store = makeStore()
        let tileFrame = CGRect(x: 400, y: 0, width: 400, height: 800)

        try apply(store, .float, b, tileFrame: tileFrame)
        let frame = state(store).floatingPane(id: b)?.floatFrame
        try apply(store, .float, b)

        XCTAssertEqual(stripIDs(store), [a, c])
        XCTAssertEqual(mode(store, b), .floating)
        XCTAssertEqual(state(store).floatingPane(id: b)?.floatFrame, frame, "a second float leaves it alone")
        XCTAssertEqual(state(store).floatingPane(id: b)?.origin, FloatOrigin(columnIndex: 1))
        XCTAssertEqual(state(store).focusedPaneID, b)
    }

    func test_float_brings_a_pip_or_pill_back_as_a_float() throws {
        let store = makeStore()
        try apply(store, .pip, a)
        try apply(store, .minimize, b)

        try apply(store, .float, a)
        try apply(store, .float, b)

        XCTAssertEqual(mode(store, a), .floating)
        XCTAssertEqual(mode(store, b), .floating)
        XCTAssertEqual(state(store).focusedPaneID, b)
    }

    // MARK: - pane dock

    func test_dock_returns_a_float_to_its_column_and_ignores_tiles() throws {
        let store = makeStore()
        try apply(store, .minimize, a)

        try apply(store, .dock, a)
        try apply(store, .dock, b)

        XCTAssertEqual(stripIDs(store), [a, b, c])
        XCTAssertTrue(state(store).floatingPanes.isEmpty)
    }

    // MARK: - pane pip

    func test_pip_floats_a_tile_first_and_takes_the_corner() throws {
        let store = makeStore()
        let tileFrame = CGRect(x: 0, y: 0, width: 400, height: 800)

        try apply(store, .pip, a, corner: .topLeft, tileFrame: tileFrame)

        XCTAssertEqual(mode(store, a), .pip(corner: .topLeft, order: 0))
        XCTAssertEqual(stripIDs(store), [b, c])
        XCTAssertEqual(state(store).floatingPane(id: a)?.origin, FloatOrigin(columnIndex: 0))
        XCTAssertNotEqual(state(store).focusedPaneID, a, "a PiP never holds focus")
        XCTAssertEqual(
            state(store).floatingPane(id: a)?.floatFrame,
            NormalizedRect(rect: FloatLayout.liftedFrame(tileFrame: tileFrame, canvas: canvas), in: canvas),
            "restoring the PiP brings it back where the tile was"
        )
    }

    func test_pip_without_corner_keeps_the_current_corner_and_moves_with_one() throws {
        let store = makeStore()
        try apply(store, .pip, a, corner: .topRight)

        try apply(store, .pip, a)
        XCTAssertEqual(mode(store, a), .pip(corner: .topRight, order: 0))

        try apply(store, .pip, a, corner: .bottomLeft)
        XCTAssertEqual(mode(store, a), .pip(corner: .bottomLeft, order: 0))

        try apply(store, .pip, b)
        XCTAssertEqual(mode(store, b), .pip(corner: .bottomRight, order: 0))
    }

    // MARK: - pane minimize / restore

    func test_minimize_from_a_tile_and_from_a_pip() throws {
        let store = makeStore()
        try apply(store, .minimize, a)
        try apply(store, .pip, b)
        try apply(store, .minimize, b)
        try apply(store, .minimize, b)

        XCTAssertEqual(mode(store, a), .minimized(order: 0))
        XCTAssertEqual(mode(store, b), .minimized(order: 1))
        XCTAssertEqual(stripIDs(store), [c])
        XCTAssertEqual(state(store).focusedPaneID, c)
    }

    func test_restore_focuses_a_pill_and_refuses_a_tile() throws {
        let store = makeStore()
        try apply(store, .minimize, a)

        try apply(store, .restore, a)
        XCTAssertEqual(mode(store, a), .floating)
        XCTAssertEqual(state(store).focusedPaneID, a)

        let before = store.worklanes
        XCTAssertThrowsError(try apply(store, .restore, b)) {
            XCTAssertEqual($0 as? FloatControlIPCError, .notFloating(b.rawValue))
        }
        XCTAssertEqual(store.worklanes, before)
    }

    func test_unknown_pane_throws() {
        let store = makeStore()
        for action in PaneFloatAction.allCases {
            XCTAssertThrowsError(try apply(store, action, PaneID("pn_gone")), action.rawValue) {
                guard case PaneRoutingError.paneNotFound = $0 else {
                    return XCTFail("unexpected error \($0)")
                }
            }
        }
    }

    // MARK: - Worklanes that are not on screen

    func test_actions_work_in_another_worklane_without_switching() throws {
        let store = makeStore()
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }
        defer { _ = subscription }

        // x is wl_other's only tile: `pane float` refuses it (SoleTileFloatTests).
        store.floatSoleTileForTesting(x, canvas: canvas)
        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertTrue(stripIDs(store, otherID).isEmpty)
        XCTAssertEqual(mode(store, x, in: otherID), .floating)
        XCTAssertTrue(changes.contains(.paneStructure(otherID)), "the strip of that worklane changed")
        XCTAssertTrue(changes.contains(.floats(otherID)))
        XCTAssertFalse(changes.contains(.floats(mainID)))

        try apply(store, .minimize, x)
        XCTAssertEqual(mode(store, x, in: otherID), .minimized(order: 0))
        try apply(store, .pip, x, corner: .topLeft)
        XCTAssertEqual(mode(store, x, in: otherID), .pip(corner: .topLeft, order: 0))
        try apply(store, .restore, x)
        XCTAssertEqual(mode(store, x, in: otherID), .floating)
        XCTAssertEqual(state(store, otherID).focusedFloatID, x)
        try apply(store, .dock, x)
        XCTAssertEqual(stripIDs(store, otherID), [x])
        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(stripIDs(store), [a, b, c], "the active worklane is untouched")
    }

    func test_float_hide_and_show_in_another_worklane() throws {
        let store = makeStore()
        store.floatSoleTileForTesting(x, canvas: canvas)

        store.setFloatsHidden(true, in: otherID)
        XCTAssertTrue(state(store, otherID).floatsHidden)
        XCTAssertNil(state(store, otherID).focusedFloatID)
        XCTAssertFalse(state(store).floatsHidden)

        store.setFloatsHidden(false, in: otherID)
        XCTAssertFalse(state(store, otherID).floatsHidden)
        XCTAssertEqual(state(store, otherID).focusedFloatID, x, "an empty strip hands focus back to the float")
        XCTAssertEqual(store.activeWorklaneID, mainID)
    }

    // MARK: - float new

    func test_new_float_starts_in_the_source_pane_directory_and_takes_focus() throws {
        let store = makeStore()

        let id = try store.newFloat(from: a, workingDirectory: nil, command: "npm test", temporary: false, canvas: canvas)

        let float = try XCTUnwrap(state(store).floatingPane(id: id))
        XCTAssertEqual(float.mode, .floating)
        XCTAssertEqual(float.pane.sessionRequest.workingDirectory, "/tmp/pn_a")
        XCTAssertEqual(float.pane.sessionRequest.command, "npm test")
        XCTAssertNil(float.origin)
        XCTAssertEqual(state(store).focusedPaneID, id)
        XCTAssertEqual(state(store).auxiliaryStateByPaneID[id]?.lifetime, .persistent)
        XCTAssertEqual(stripIDs(store), [a, b, c])
        XCTAssertEqual(
            float.floatFrame.resolved(in: canvas),
            FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
        )
    }

    func test_new_float_falls_back_to_the_source_launch_directory() throws {
        var worklane = worklane(mainID, tiles: [a])
        worklane.auxiliaryStateByPaneID = [:]
        _ = worklane.updatePane(id: a) { $0.sessionRequest.workingDirectory = "/srv/project" }
        let store = WorklaneStore(worklanes: [worklane], activeWorklaneID: mainID)

        let id = try store.newFloat(from: a, workingDirectory: nil, command: nil, temporary: false, canvas: canvas)

        XCTAssertEqual(state(store).pane(id: id)?.sessionRequest.workingDirectory, "/srv/project")
    }

    func test_new_float_checks_an_explicit_directory() throws {
        let store = makeStore()
        let before = store.worklanes

        XCTAssertThrowsError(try store.newFloat(
            from: a, workingDirectory: "/nope", command: nil, temporary: false, canvas: canvas,
            directoryExists: { _ in false }
        )) {
            XCTAssertEqual($0 as? FloatControlIPCError, .invalidWorkingDirectory("/nope"))
        }
        XCTAssertEqual(store.worklanes, before)

        let id = try store.newFloat(
            from: a, workingDirectory: "/srv", command: nil, temporary: false, canvas: canvas,
            directoryExists: { $0 == "/srv" }
        )
        XCTAssertEqual(state(store).pane(id: id)?.sessionRequest.workingDirectory, "/srv")
    }

    func test_temporary_new_float_is_not_an_overlay() throws {
        let store = makeStore()

        let id = try store.newFloat(from: c, workingDirectory: nil, command: nil, temporary: true, canvas: canvas)

        XCTAssertEqual(
            state(store).auxiliaryStateByPaneID[id]?.lifetime,
            .temporary(owner: nil, placement: .worklane, waitAfterCommand: false)
        )
        XCTAssertFalse(state(store).isPersistent(id))
        XCTAssertNil(state(store).overlayAnchor(of: id))
        XCTAssertTrue(store.overlayFloatEntries(targeting: nil).isEmpty, "overlay list ignores it")
        XCTAssertNil(store.overlayFloatID(targeting: c))
        let overlay = try store.openOverlayFloat(
            on: c,
            request: OverlayFloatRequest(
                command: "/bin/echo hi", workingDirectory: "/tmp", waitAfterCommand: false,
                placement: .worklane, sizePercent: 100, follow: false, notify: false
            ),
            canvas: canvas,
            directoryExists: { _ in true }
        )
        XCTAssertTrue(overlay.isNew, "a worklane overlay is not satisfied by the temporary float")
        XCTAssertNotEqual(overlay.id, id)
        XCTAssertTrue(state(store).containsPane(id: id), "reconciliation leaves the owner-less float alone")
    }

    func test_new_float_from_another_worklane_stays_there() throws {
        let store = makeStore()

        let id = try store.newFloat(from: x, workingDirectory: nil, command: nil, temporary: false, canvas: canvas)

        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(mode(store, id, in: otherID), .floating)
        XCTAssertEqual(state(store, otherID).focusedFloatID, id)
        XCTAssertEqual(state(store, otherID).pane(id: id)?.sessionRequest.workingDirectory, "/tmp/pn_x")
        XCTAssertTrue(state(store).floatingPanes.isEmpty)
    }

    // MARK: - float list

    func test_list_reports_index_mode_and_placement_in_pane_list_order() throws {
        let store = makeStore()
        try apply(store, .float, b)
        store.moveFloat(b, frame: NormalizedRect(x: 0.1, y: 0.5, width: 0.4, height: 0.3))
        try apply(store, .pip, a, corner: .topLeft)
        store.floatSoleTileForTesting(c, canvas: canvas)
        try apply(store, .minimize, c)

        let entries = store.floatListEntries(in: mainID, windowID: WindowID("win_1"))

        XCTAssertEqual(entries.map(\.id), [b.rawValue, a.rawValue, c.rawValue], "creation order")
        XCTAssertEqual(entries.map(\.index), [1, 2, 3], "same numbering as pane list (no tiles left)")
        XCTAssertEqual(entries.map(\.mode), ["floating", "pip", "minimized"])
        XCTAssertEqual(entries[0].frame, FloatListEntry.Frame(x: 0.1, y: 0.2, width: 0.4, height: 0.3), "origin top-left")
        XCTAssertNil(entries[0].corner)
        XCTAssertEqual(entries[1].corner, "top-left")
        XCTAssertNil(entries[1].frame)
        XCTAssertNil(entries[2].frame)
        XCTAssertNil(entries[2].corner)
        XCTAssertEqual(entries.map(\.worklaneID), Array(repeating: mainID.rawValue, count: 3))
        XCTAssertEqual(entries.map(\.windowID), Array(repeating: "win_1", count: 3))
        XCTAssertEqual(entries.map(\.workingDirectory), ["/tmp/pn_b", "/tmp/pn_a", "/tmp/pn_c"])
        XCTAssertEqual(entries.map(\.title), ["pn_b", "pn_a", "pn_c"])
        XCTAssertEqual(entries.map(\.isFocused), [true, false, false])
        XCTAssertTrue(store.floatListEntries(in: otherID, windowID: nil).isEmpty)
        XCTAssertTrue(store.floatListEntries(in: WorklaneID("wl_gone"), windowID: nil).isEmpty)
    }

    func test_list_numbering_counts_tiles_first() throws {
        let store = makeStore()
        try apply(store, .minimize, a)

        let entry = try XCTUnwrap(store.floatListEntries(in: mainID, windowID: nil).first)

        XCTAssertEqual(entry.index, 3)
        XCTAssertEqual(state(store).allPanes.last?.id.rawValue, entry.id)
    }

    func test_list_flags_hidden_temporary_and_running_status() throws {
        let store = makeStore()
        try apply(store, .float, a)
        try apply(store, .pip, b)
        store.floatSoleTileForTesting(c, canvas: canvas)
        try apply(store, .minimize, c)
        let temporary = try store.newFloat(from: a, workingDirectory: nil, command: nil, temporary: true, canvas: canvas)
        var worklanes = store.worklanes
        worklanes[0].auxiliaryStateByPaneID[a]?.shellActivityState = .commandRunning
        store.replaceWorklanes(worklanes, activeWorklaneID: mainID)
        store.setFloatsHidden(true)

        let entries = Dictionary(uniqueKeysWithValues: store.floatListEntries(in: mainID, windowID: nil).map { ($0.id, $0) })

        XCTAssertEqual(entries[a.rawValue]?.isHidden, true)
        XCTAssertEqual(entries[b.rawValue]?.isHidden, true)
        XCTAssertEqual(entries[c.rawValue]?.isHidden, false, "pills never hide")
        XCTAssertEqual(entries[temporary.rawValue]?.isTemporary, true)
        XCTAssertEqual(entries[a.rawValue]?.isTemporary, false)
        XCTAssertEqual(entries[a.rawValue]?.status, "running")
        XCTAssertEqual(entries[b.rawValue]?.status, "idle")
    }

    func test_list_status_reads_agent_attention() {
        XCTAssertEqual(WorklaneStore.floatListStatus(nil), "idle")
        let store = makeStore()
        var worklanes = store.worklanes
        worklanes[0].auxiliaryStateByPaneID[a]?.agentStatus = PaneAgentStatus(
            tool: .claudeCode, state: .running, text: nil, artifactLink: nil,
            updatedAt: Date(), workingDirectory: "/tmp/pn_a", sessionID: "s1"
        )
        store.replaceWorklanes(worklanes, activeWorklaneID: mainID)
        store.applyAgentStatusPayload(AgentStatusPayload(
            windowID: nil, worklaneID: mainID, paneID: a, signalKind: .lifecycle, state: .needsInput,
            origin: .explicitAPI, toolName: "Claude Code", text: "Approval requested",
            interactionKind: .approval, sessionID: "s1", artifactKind: nil, artifactLabel: nil, artifactURL: nil
        ))

        XCTAssertEqual(WorklaneStore.floatListStatus(state(store).auxiliaryStateByPaneID[a]), "needs-input")
    }
}
