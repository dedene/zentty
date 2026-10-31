import CoreGraphics
import XCTest
@testable import Zentty

/// tmux-compat agent teams whose leader (or a teammate) is a float: the
/// user's strip is never rearranged around a pane that is not in it, and a
/// respawned float comes back as a float in the same place.
@MainActor
final class WorklaneStoreFloatTmuxTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let mainID = WorklaneID("wl_main")

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

    private func makeStore(tiles: [String], focused: String) -> WorklaneStore {
        let worklane = WorklaneState(
            id: mainID,
            title: nil,
            paneStripState: PaneStripState(
                columns: tiles.map(column),
                focusedColumnID: PaneColumnID("col_\(focused)")
            ),
            nextPaneNumber: tiles.count + 1,
            auxiliaryStateByPaneID: Dictionary(uniqueKeysWithValues: tiles.map {
                (PaneID($0), PaneAuxiliaryState(raw: PaneRawState(), presentation: PanePresentationState()))
            })
        )
        return WorklaneStore(worklanes: [worklane], activeWorklaneID: mainID)
    }

    private func main(_ store: WorklaneStore) -> WorklaneState {
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

    private func teamSplit(_ store: WorklaneStore, leader: PaneID) -> PaneID? {
        store.splitWithLayout(
            in: mainID,
            placement: .afterFocused,
            isHorizontal: true,
            layout: .golden,
            availableWidth: canvas.width,
            leadingVisibleInset: 0,
            availableSize: canvas.size,
            minimumSizeByPaneID: [:],
            targetPaneID: leader,
            preserveFocusPaneID: leader,
            sessionRequest: TerminalSessionRequest(isLaunchDeferred: true)
        )
    }

    // MARK: - Golden split with a floated leader

    func test_golden_split_targeting_a_floated_leader_leaves_the_strip_widths_alone() throws {
        let store = makeStore(tiles: ["a", "b", "c"], focused: "c")
        store.floatPane(PaneID("a"), canvas: canvas, tileFrame: nil)
        let widthsBefore = main(store).paneStripState.columns.map(\.width)
        XCTAssertEqual(main(store).paneStripState.panes.map(\.id.rawValue), ["b", "c"])

        let teammate = try XCTUnwrap(teamSplit(store, leader: PaneID("a")))

        let strip = main(store).paneStripState
        XCTAssertEqual(strip.panes.map(\.id), [PaneID("b"), PaneID("c"), teammate])
        XCTAssertEqual(
            Array(strip.columns.prefix(2).map(\.width)),
            widthsBefore,
            "the user's columns keep their widths when the leader is not in the strip"
        )
        XCTAssertTrue(main(store).isFloating(PaneID("a")))
    }

    func test_golden_split_targeting_a_tiled_leader_still_arranges_golden() throws {
        let store = makeStore(tiles: ["a", "b"], focused: "b")
        let widthsBefore = main(store).paneStripState.columns.map(\.width)

        _ = try XCTUnwrap(teamSplit(store, leader: PaneID("a")))

        XCTAssertNotEqual(
            Array(main(store).paneStripState.columns.prefix(2).map(\.width)),
            widthsBefore,
            "a docked leader keeps the golden arrangement"
        )
    }

    // MARK: - Respawn of a floated pane

    func test_replacement_float_takes_the_old_floats_place_and_focus() throws {
        let store = makeStore(tiles: ["a"], focused: "a")
        let old = addFloat(store)
        let other = addFloat(store)
        store.focusFloat(old)
        let oldFloat = try XCTUnwrap(main(store).floatingPane(id: old))

        let replacement = try XCTUnwrap(store.openReplacementFloat(
            for: old,
            in: mainID,
            sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp", isLaunchDeferred: true)
        ))
        _ = store.closePane(id: old)

        XCTAssertEqual(main(store).paneStripState.panes.map(\.id), [PaneID("a")], "the strip is untouched")
        XCTAssertEqual(main(store).floatingPanes.map(\.pane.id), [replacement, other])
        let float = try XCTUnwrap(main(store).floatingPane(id: replacement))
        XCTAssertEqual(float.mode, .floating)
        XCTAssertEqual(float.floatFrame, oldFloat.floatFrame)
        XCTAssertEqual(float.stackOrder, oldFloat.stackOrder)
        XCTAssertEqual(float.sequence, oldFloat.sequence)
        XCTAssertEqual(main(store).focusedFloatID, replacement)
        XCTAssertEqual(main(store).pane(id: replacement)?.sessionRequest.isLaunchDeferred, true)
    }

    func test_replacement_of_a_pip_stays_a_pip_in_the_same_slot() throws {
        let store = makeStore(tiles: ["a"], focused: "a")
        let old = addFloat(store)
        let other = addFloat(store)
        store.pipPane(old, corner: .bottomRight)
        store.pipPane(other, corner: .bottomRight)
        store.focusPane(id: PaneID("a"))

        let replacement = try XCTUnwrap(store.openReplacementFloat(
            for: old,
            in: mainID,
            sessionRequest: TerminalSessionRequest(isLaunchDeferred: true)
        ))
        _ = store.closePane(id: old)

        XCTAssertEqual(main(store).floatingPane(id: replacement)?.mode, .pip(corner: .bottomRight, order: 0))
        XCTAssertEqual(main(store).floatingPane(id: other)?.mode, .pip(corner: .bottomRight, order: 1))
        XCTAssertEqual(main(store).focusedPaneID, PaneID("a"), "a PiP never takes focus")
    }

    func test_replacement_float_is_nil_for_a_tile() {
        let store = makeStore(tiles: ["a"], focused: "a")

        XCTAssertNil(store.openReplacementFloat(
            for: PaneID("a"),
            in: mainID,
            sessionRequest: TerminalSessionRequest(isLaunchDeferred: true)
        ))
    }
}
