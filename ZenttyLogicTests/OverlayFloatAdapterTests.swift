import CoreGraphics
import XCTest
@testable import Zentty

/// `zentty overlay …` on floats: one test (or a few) per row of the
/// compatibility table in the floating-panes technical design §8.
@MainActor
final class OverlayFloatAdapterTests: XCTestCase {
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

    private func worklaneState(_ id: WorklaneID, tiles: [String], focused: String? = nil) -> WorklaneState {
        let focusedColumn = (focused ?? tiles.last).map { PaneColumnID("col_\($0)") }
        return WorklaneState(
            id: id,
            title: nil,
            paneStripState: PaneStripState(columns: tiles.map(column), focusedColumnID: focusedColumn),
            nextPaneNumber: tiles.count + 1
        )
    }

    private func makeStore(
        tiles: [String] = ["a", "b"],
        focused: String? = nil,
        otherTiles: [String]? = nil,
        activeOther: Bool = false
    ) -> WorklaneStore {
        var worklanes = [worklaneState(mainID, tiles: tiles, focused: focused)]
        if let otherTiles {
            worklanes.append(worklaneState(otherID, tiles: otherTiles))
        }
        return WorklaneStore(worklanes: worklanes, activeWorklaneID: activeOther ? otherID : mainID)
    }

    private func request(
        _ placement: OverlayPlacement = .worklane,
        wait: Bool = false,
        follow: Bool = false,
        notify: Bool = false,
        sizePercent: Int = 100,
        cwd: String? = "/tmp"
    ) -> OverlayFloatRequest {
        OverlayFloatRequest(
            command: "/bin/echo hi",
            workingDirectory: cwd,
            waitAfterCommand: wait,
            placement: placement,
            sizePercent: sizePercent,
            follow: follow,
            notify: notify
        )
    }

    @discardableResult
    private func open(
        _ store: WorklaneStore,
        on owner: String,
        _ request: OverlayFloatRequest,
        ownerFrame: CGRect? = nil
    ) throws -> OverlayFloatOpenResult {
        try store.openOverlayFloat(on: PaneID(owner), request: request, canvas: canvas, ownerFrame: ownerFrame)
    }

    private func worklane(_ store: WorklaneStore, _ id: WorklaneID) -> WorklaneState? {
        store.worklanes.first { $0.id == id }
    }

    private func lifetime(_ store: WorklaneStore, _ id: PaneID) -> PaneLifetime? {
        guard let index = store.worklaneIndex(containingPane: id) else { return nil }
        return store.worklanes[index].auxiliaryStateByPaneID[id]?.lifetime
    }

    private func frame(_ store: WorklaneStore, _ id: PaneID) -> CGRect? {
        guard let index = store.worklaneIndex(containingPane: id) else { return nil }
        return store.worklanes[index].floatingPane(id: id)?.floatFrame.resolved(in: canvas)
    }

    private func assertRect(_ actual: CGRect?, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            return XCTFail("missing rect", file: file, line: line)
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func listEntries(_ store: WorklaneStore, on paneID: String? = nil) throws -> [[String: Any]] {
        let json = try OverlayFloatEntry.json(store.overlayFloatEntries(targeting: paneID.map(PaneID.init)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    // MARK: - `open` returns the id immediately; the id is the pane id

    func test_open_returns_the_new_floats_pane_id() throws {
        let store = makeStore()
        let result = try open(store, on: "a", request())

        XCTAssertTrue(result.isNew)
        let main = try XCTUnwrap(worklane(store, mainID))
        XCTAssertEqual(main.floatingPane(id: result.id)?.mode, .floating)
        XCTAssertEqual(main.focusedFloatID, result.id, "an overlay on the active worklane takes focus")
        XCTAssertEqual(main.paneStripState.panes.map(\.id.rawValue), ["a", "b"], "the strip is untouched")
    }

    // MARK: - Every overlay is ephemeral → `.temporary`, never restored

    func test_overlay_floats_are_temporary_and_never_persisted() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request()).id

        XCTAssertEqual(lifetime(store, id), .temporary(owner: PaneID("a"), placement: .worklane, waitAfterCommand: false))
        let main = try XCTUnwrap(worklane(store, mainID))
        XCTAssertFalse(main.isPersistent(id))
        XCTAssertFalse(main.persistentPanes.contains { $0.id == id })
    }

    // MARK: - `--wait` keeps the terminal after the command exits

    func test_wait_keeps_the_terminal_after_the_command_exits() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request(wait: true, cwd: "/tmp")).id
        let pane = try XCTUnwrap(worklane(store, mainID)?.pane(id: id))

        XCTAssertEqual(pane.sessionRequest.nativeCommand, "/bin/echo hi")
        XCTAssertTrue(pane.sessionRequest.waitAfterNativeCommand)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp")
        XCTAssertEqual(lifetime(store, id), .temporary(owner: PaneID("a"), placement: .worklane, waitAfterCommand: true))
    }

    // MARK: - Without `--wait`, closes when the command exits

    func test_without_wait_the_float_closes_when_its_command_exits() throws {
        let store = makeStore(tiles: ["a"])
        let id = try open(store, on: "a", request(wait: false)).id
        let pane = try XCTUnwrap(worklane(store, mainID)?.pane(id: id))
        XCTAssertFalse(pane.sessionRequest.waitAfterNativeCommand)

        XCTAssertEqual(store.closePaneFromShellExit(id: id), .closed)

        let main = try XCTUnwrap(worklane(store, mainID))
        XCTAssertFalse(main.containsPane(id: id))
        XCTAssertTrue(main.containsPane(id: PaneID("a")), "the owner and its worklane stay")
    }

    // MARK: - One overlay per owner + placement; re-open returns the existing one

    func test_reopening_for_the_same_owner_and_placement_returns_the_existing_float() throws {
        let store = makeStore()
        let shared = try open(store, on: "a", request(.worklane))
        let sharedAgain = try open(store, on: "b", request(.worklane))
        XCTAssertEqual(sharedAgain, OverlayFloatOpenResult(id: shared.id, isNew: false), "one worklane overlay per worklane")

        let paneA = try open(store, on: "a", request(.pane))
        let paneB = try open(store, on: "b", request(.pane))
        let paneAAgain = try open(store, on: "a", request(.pane))
        XCTAssertTrue(paneA.isNew)
        XCTAssertTrue(paneB.isNew)
        XCTAssertEqual(paneAAgain, OverlayFloatOpenResult(id: paneA.id, isNew: false))
        XCTAssertEqual(Set([shared.id, paneA.id, paneB.id]).count, 3)
        XCTAssertEqual(worklane(store, mainID)?.floatingPanes.count, 3)
    }

    // MARK: - `--placement pane` follows its owner and closes with it

    func test_pane_placement_starts_over_the_owner_frame_inset_16pt() throws {
        let store = makeStore()
        let ownerFrame = CGRect(x: 100, y: 50, width: 500, height: 600)
        let id = try open(store, on: "a", request(.pane), ownerFrame: ownerFrame).id

        assertRect(frame(store, id), ownerFrame.insetBy(dx: 16, dy: 16))
    }

    func test_pane_placement_on_a_float_starts_over_that_floats_frame() throws {
        let store = makeStore()
        let worklaneOverlay = try open(store, on: "a", request(.worklane)).id
        let ownerFrame = try XCTUnwrap(frame(store, worklaneOverlay))
        let id = try open(store, on: worklaneOverlay.rawValue, request(.pane)).id

        assertRect(frame(store, id), ownerFrame.insetBy(dx: 16, dy: 16))
    }

    func test_pane_placement_closes_with_its_owner() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request(.pane)).id

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)

        XCTAssertNil(store.worklaneIndex(containingPane: id))
        XCTAssertTrue(worklane(store, mainID)?.containsPane(id: PaneID("b")) == true)
    }

    func test_an_overlay_owned_by_an_overlay_closes_with_it() throws {
        let store = makeStore()
        let parent = try open(store, on: "a", request(.pane)).id
        let child = try open(store, on: parent.rawValue, request(.pane)).id

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)

        XCTAssertNil(store.worklaneIndex(containingPane: parent))
        XCTAssertNil(store.worklaneIndex(containingPane: child))
    }

    func test_pane_placement_follows_its_owner_to_another_worklane() throws {
        let store = makeStore(tiles: ["a", "b"], otherTiles: ["c"])
        let id = try open(store, on: "a", request(.pane)).id

        store.transferPaneToWorklane(paneID: PaneID("a"), targetWorklaneID: otherID, singleColumnWidth: 800)

        XCTAssertEqual(worklane(store, otherID)?.floatingPane(id: id)?.pane.id, id)
        XCTAssertFalse(worklane(store, mainID)?.containsPane(id: id) == true)
        XCTAssertEqual(lifetime(store, id), .temporary(owner: PaneID("a"), placement: .pane, waitAfterCommand: false))
    }

    func test_pane_placement_follows_a_worklanes_only_pane_and_the_empty_worklane_goes() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"])
        let id = try open(store, on: "a", request(.pane)).id

        store.transferPaneToWorklane(paneID: PaneID("a"), targetWorklaneID: otherID, singleColumnWidth: 800)

        XCTAssertNil(worklane(store, mainID), "a worklane left with nothing but its overlays closes")
        XCTAssertEqual(worklane(store, otherID)?.floatingPane(id: id)?.pane.id, id)
    }

    // MARK: - `--placement worklane` re-anchors to the focused pane

    func test_worklane_placement_reanchors_to_the_focused_pane_when_its_owner_closes() throws {
        let store = makeStore(tiles: ["a", "b", "c"], focused: "c")
        let id = try open(store, on: "a", request(.worklane)).id

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)

        let main = try XCTUnwrap(worklane(store, mainID))
        XCTAssertTrue(main.containsPane(id: id))
        guard case .temporary(let owner, .worklane, _) = lifetime(store, id) else {
            return XCTFail("still a worklane overlay")
        }
        XCTAssertEqual(owner, main.paneStripState.focusedPaneID)
        XCTAssertNotEqual(owner, PaneID("a"))
    }

    func test_worklane_placement_closes_with_its_worklanes_last_pane() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"])
        _ = try open(store, on: "a", request(.worklane))

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed, "overlays do not keep a worklane alive")

        XCTAssertNil(worklane(store, mainID))
        XCTAssertEqual(store.worklanes.map(\.id), [otherID])
    }

    func test_closing_the_windows_last_pane_still_closes_the_window_with_an_overlay_open() throws {
        let store = makeStore(tiles: ["a"])
        _ = try open(store, on: "a", request(.worklane))

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closeWindow)
        XCTAssertEqual(store.closePaneFromShellExit(id: PaneID("a")), .closeWindow)
    }

    func test_a_temporary_float_without_an_owner_is_left_alone() throws {
        let store = makeStore(tiles: ["a", "b"])
        let lifetime = PaneLifetime.temporary(owner: nil, placement: .worklane, waitAfterCommand: false)
        let id = try XCTUnwrap(store.newFloat(request: TerminalSessionRequest(workingDirectory: "/tmp"), canvas: canvas, lifetime: lifetime))

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)

        XCTAssertEqual(self.lifetime(store, id), lifetime, "no owner to re-anchor or close with")
    }

    // MARK: - `--follow` selects the worklane and focuses the overlay

    func test_follow_selects_the_owners_worklane_and_focuses_the_float() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"], activeOther: true)
        let id = try open(store, on: "a", request(follow: true)).id

        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(store.activeWorklane?.floatingPane(id: id)?.mode, .floating)
        XCTAssertEqual(store.activeWorklane?.focusedPaneID, id)
    }

    func test_without_follow_a_background_overlay_keeps_the_selection_and_stays_out_of_sight() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"], activeOther: true)
        let id = try open(store, on: "a", request(follow: false)).id

        XCTAssertEqual(store.activeWorklaneID, otherID)
        let main = try XCTUnwrap(worklane(store, mainID))
        XCTAssertEqual(main.floatingPane(id: id)?.mode, .minimized(order: 0))
        XCTAssertNotEqual(main.focusedPaneID, id)
    }

    // MARK: - `--notify`: opening the notification shows the overlay

    func test_following_a_notify_overlays_notification_reveals_it_once() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"], activeOther: true)
        let id = try open(store, on: "a", request(notify: true)).id
        XCTAssertEqual(worklane(store, mainID)?.floatingPane(id: id)?.mode, .minimized(order: 0))

        store.selectWorklane(id: mainID)
        store.revealOverlayFloatAwaitingNavigation(on: PaneID("a"))
        XCTAssertEqual(store.activeWorklane?.floatingPane(id: id)?.mode, .floating)
        XCTAssertEqual(store.activeWorklane?.focusedPaneID, id)

        store.minimizePane(id)
        store.revealOverlayFloatAwaitingNavigation(on: PaneID("a"))
        XCTAssertEqual(store.activeWorklane?.floatingPane(id: id)?.mode, .minimized(order: 0), "only the first navigation reveals it")
    }

    func test_background_overlay_without_notify_is_not_revealed_by_navigation() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"], activeOther: true)
        let id = try open(store, on: "a", request(notify: false)).id

        store.selectWorklane(id: mainID)
        store.revealOverlayFloatAwaitingNavigation(on: PaneID("a"))
        XCTAssertEqual(store.activeWorklane?.floatingPane(id: id)?.mode, .minimized(order: 0))
    }

    // MARK: - list / show / close target the owner's overlay; list adds `mode`

    func test_list_reports_id_owner_worklane_placement_exit_status_and_mode() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request(.pane, wait: true)).id
        store.handleTerminalEvent(paneID: id, event: .commandFinished(exitCode: 17, durationNanoseconds: 1))

        let entry = try XCTUnwrap(try listEntries(store).first)
        XCTAssertEqual(entry["id"] as? String, id.rawValue)
        XCTAssertEqual(entry["paneID"] as? String, "a")
        XCTAssertEqual(entry["worklaneID"] as? String, mainID.rawValue)
        XCTAssertEqual(entry["placement"] as? String, "pane")
        XCTAssertEqual(entry["exitCode"] as? Int, 17)
        XCTAssertEqual(entry["mode"] as? String, "floating")
        XCTAssertEqual(Set(entry.keys), ["id", "paneID", "worklaneID", "placement", "exitCode", "mode"])

        store.handleTerminalEvent(paneID: id, event: .userSubmittedInput)
        XCTAssertNil(try listEntries(store).first?["exitCode"], "a new command clears the last exit status")
    }

    func test_list_show_and_close_target_the_owners_pane_overlay_before_the_worklane_one() throws {
        let store = makeStore(tiles: ["a", "b"], otherTiles: ["c"])
        let shared = try open(store, on: "a", request(.worklane)).id
        let paneA = try open(store, on: "a", request(.pane)).id
        let paneB = try open(store, on: "b", request(.pane)).id

        XCTAssertEqual(Set(try listEntries(store, on: "a").compactMap { $0["id"] as? String }), [shared.rawValue, paneA.rawValue])
        XCTAssertEqual(Set(try listEntries(store, on: "b").compactMap { $0["id"] as? String }), [shared.rawValue, paneB.rawValue])
        XCTAssertTrue(try listEntries(store, on: "c").isEmpty)
        XCTAssertEqual(try listEntries(store).count, 3)

        try store.closeOverlayFloat(targeting: PaneID("b"))
        XCTAssertNil(store.worklaneIndex(containingPane: paneB))
        try store.closeOverlayFloat(targeting: PaneID("b"))
        XCTAssertNil(store.worklaneIndex(containingPane: shared), "then the worklane overlay")
        XCTAssertNotNil(store.worklaneIndex(containingPane: paneA))

        XCTAssertThrowsError(try store.closeOverlayFloat(targeting: PaneID("b"))) {
            XCTAssertEqual($0 as? TerminalOverlayError, .notOpen)
        }
        XCTAssertThrowsError(try store.showOverlayFloat(targeting: PaneID("c"))) {
            XCTAssertEqual($0 as? TerminalOverlayError, .notOpen)
        }
    }

    func test_show_selects_the_overlays_worklane_restores_and_focuses_it() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"], activeOther: true)
        let id = try open(store, on: "a", request()).id

        try store.showOverlayFloat(targeting: PaneID("a"))

        XCTAssertEqual(store.activeWorklaneID, mainID)
        XCTAssertEqual(store.activeWorklane?.floatingPane(id: id)?.mode, .floating)
        XCTAssertEqual(store.activeWorklane?.focusedPaneID, id)
    }

    func test_an_overlay_targets_itself() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request(.pane)).id

        XCTAssertEqual(store.overlayFloatID(targeting: id), id)
        try store.closeOverlayFloat(targeting: id)
        XCTAssertNil(store.worklaneIndex(containingPane: id))
    }

    func test_open_reports_unknown_panes_and_missing_directories() throws {
        let store = makeStore()
        XCTAssertThrowsError(try open(store, on: "missing", request())) {
            XCTAssertEqual($0 as? TerminalOverlayError, .paneNotFound)
        }
        let missing = "/nonexistent-\(UUID().uuidString)"
        XCTAssertThrowsError(try open(store, on: "a", request(cwd: missing))) {
            XCTAssertEqual($0 as? TerminalOverlayError, .invalidWorkingDirectory(missing))
        }
        XCTAssertTrue(worklane(store, mainID)?.floatingPanes.isEmpty == true)
    }

    // MARK: - `--size-percent 30-100` is the initial float size

    func test_size_percent_scales_the_inset_anchor_around_its_centre() throws {
        let store = makeStore()
        let worklaneFloat = try open(store, on: "a", request(.worklane, sizePercent: 50)).id
        let inset = canvas.insetBy(dx: 16, dy: 16)
        assertRect(frame(store, worklaneFloat), CGRect(
            x: inset.midX - inset.width / 4, y: inset.midY - inset.height / 4,
            width: inset.width / 2, height: inset.height / 2
        ))

        let ownerFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let paneFloat = try open(store, on: "a", request(.pane, sizePercent: 30), ownerFrame: ownerFrame).id
        let paneFrame = try XCTUnwrap(frame(store, paneFloat))
        XCTAssertEqual(paneFrame.width, FloatLayout.minimumFloatSize.width, accuracy: 0.001, "never below the minimum float size")
        XCTAssertEqual(paneFrame.height, FloatLayout.minimumFloatSize.height, accuracy: 0.001)
        XCTAssertEqual(paneFrame.midX, ownerFrame.midX, accuracy: 0.001)
        XCTAssertEqual(paneFrame.midY, ownerFrame.midY, accuracy: 0.001)
    }

    // MARK: - Docking promotes a temporary float and detaches it from its owner

    func test_docking_an_overlay_float_makes_it_a_normal_pane() throws {
        let store = makeStore()
        let id = try open(store, on: "a", request(.pane)).id

        XCTAssertTrue(store.dockPane(id, target: .origin))
        XCTAssertEqual(lifetime(store, id), .persistent)

        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)
        XCTAssertNotNil(store.worklaneIndex(containingPane: id), "a docked overlay no longer closes with its owner")
        XCTAssertTrue(try listEntries(store).isEmpty)
    }

    // MARK: - Close confirmations see the overlays that close with a pane

    func test_overlays_closing_with_a_pane_or_worklane() throws {
        let store = makeStore(tiles: ["a", "b"])
        let shared = try open(store, on: "a", request(.worklane)).id
        let paneA = try open(store, on: "a", request(.pane)).id
        let paneB = try open(store, on: "b", request(.pane)).id

        XCTAssertEqual(store.temporaryFloatIDs(closingWithPane: PaneID("a")), [paneA])
        XCTAssertEqual(Set(store.temporaryFloatIDs(closingWithWorklane: mainID)), [shared, paneA, paneB])
        XCTAssertEqual(store.temporaryFloatIDs(closingWithPane: paneA), [paneA], "closing an overlay takes itself")

        XCTAssertEqual(store.closePane(id: PaneID("b")), .closed)
        XCTAssertEqual(
            Set(store.temporaryFloatIDs(closingWithPane: PaneID("a"))), [shared, paneA],
            "the worklane's last pane takes the worklane overlay too"
        )
    }

    /// Review finding: the prompt must see the overlay being closed and every
    /// overlay reconciliation closes after it, at any depth.
    func test_overlays_closing_with_a_pane_include_the_target_and_nested_overlays() throws {
        let store = makeStore(tiles: ["a", "b"])
        let child = try open(store, on: "a", request(.pane)).id
        let grandchild = try open(store, on: child.rawValue, request(.pane)).id
        let shared = try open(store, on: child.rawValue, request(.worklane)).id

        XCTAssertEqual(Set(store.temporaryFloatIDs(closingWithPane: PaneID("a"))), [child, grandchild])
        XCTAssertEqual(Set(store.temporaryFloatIDs(closingWithPane: child)), [child, grandchild])
        XCTAssertEqual(store.temporaryFloatIDs(closingWithPane: grandchild), [grandchild])

        // What reconciliation really closes: the worklane overlay re-anchors.
        XCTAssertEqual(store.closePane(id: PaneID("a")), .closed)
        XCTAssertNil(store.worklaneIndex(containingPane: child))
        XCTAssertNil(store.worklaneIndex(containingPane: grandchild))
        XCTAssertNotNil(store.worklaneIndex(containingPane: shared))
    }

    // MARK: - Overlays never keep a window alive

    /// Review finding: a lone tile plus its overlay used to count as two
    /// panes, so it split out and left an empty source window behind.
    func test_a_lone_tile_with_an_overlay_cannot_split_out_of_the_only_worklane() throws {
        let store = makeStore(tiles: ["a"])
        try open(store, on: "a", request(.pane))

        XCTAssertFalse(store.canSplitOutPaneToNewWindow(paneID: PaneID("a")))
        XCTAssertNil(store.splitOutPaneToNewWindow(paneID: PaneID("a"), destinationWindowID: WindowID("win_dest")))
        XCTAssertNotNil(store.worklaneIndex(containingPane: PaneID("a")))
    }

    func test_splitting_out_a_worklanes_last_persistent_pane_removes_the_worklane() throws {
        let store = makeStore(tiles: ["a"], otherTiles: ["c"])
        let overlay = try open(store, on: "a", request(.pane)).id
        let shared = try open(store, on: "a", request(.worklane)).id
        XCTAssertTrue(store.canSplitOutPaneToNewWindow(paneID: PaneID("a")))

        let result = try XCTUnwrap(
            store.splitOutPaneToNewWindow(paneID: PaneID("a"), destinationWindowID: WindowID("win_dest"))
        )

        XCTAssertFalse(result.sourceWindowShouldClose, "the other worklane keeps the window")
        XCTAssertNil(worklane(store, mainID), "only overlays were left: the worklane goes with them")
        XCTAssertNil(store.worklaneIndex(containingPane: overlay))
        XCTAssertNil(store.worklaneIndex(containingPane: shared))
        XCTAssertEqual(store.activeWorklaneID, otherID)
        XCTAssertEqual(result.destinationWorkspaceState.worklanes.first?.floatingPanes, [])
    }

    func test_an_overlay_alone_in_its_worklane_never_splits_out() throws {
        let store = makeStore(tiles: ["a", "b"])
        let overlay = try open(store, on: "a", request(.pane)).id
        XCTAssertFalse(store.canSplitOutPaneToNewWindow(paneID: overlay), "floats don't split out in v1")
    }

    // MARK: - IPC options share the store's placement type

    func test_ipc_options_map_onto_the_float_request() throws {
        let options = try PaneOverlayIPCOptions.parse(arguments: [
            "--wait", "--follow", "--notify", "--cwd", "/tmp", "--placement", "pane",
            "--size-percent", "40", "--command-json", "[\"htop\"]",
        ])
        let placement: OverlayPlacement = options.placement
        XCTAssertEqual(placement, .pane)
        XCTAssertEqual(options.floatRequest, OverlayFloatRequest(
            command: options.command, workingDirectory: "/tmp", waitAfterCommand: true,
            placement: .pane, sizePercent: 40, follow: true, notify: true
        ))
    }
}
