import CoreGraphics
import XCTest
@testable import Zentty

/// A worklane's only tile stays a tile: no border buttons, Float or Dock Pane
/// unavailable, the CLI refuses with a clear error. Floats keep everything.
@MainActor
final class SoleTileFloatTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_sole")
    private let a = PaneID("a")
    private let b = PaneID("b")

    // MARK: - Border actions

    func test_sole_tile_has_no_border_actions() {
        XCTAssertEqual(PaneBorderActionsLayout.actions(for: .tile, isSoleTile: true), [])
        XCTAssertEqual(PaneBorderActionsLayout.actions(for: .tile, isSoleTile: false), [.float, .close])
    }

    func test_floats_and_pips_keep_their_actions_whatever_the_flag() {
        XCTAssertEqual(
            PaneBorderActionsLayout.actions(for: .float, isSoleTile: true),
            PaneBorderActionsLayout.actions(for: .float)
        )
        XCTAssertEqual(
            PaneBorderActionsLayout.actions(for: .pip, isSoleTile: true),
            PaneBorderActionsLayout.actions(for: .pip)
        )
    }

    // MARK: - WorklaneState.isSoleTile

    func test_isSoleTile_only_for_a_lone_strip_pane() {
        XCTAssertTrue(worklane(tiles: [[a]]).isSoleTile(a))
        XCTAssertFalse(worklane(tiles: [[a], [b]]).isSoleTile(a), "two columns")
        XCTAssertFalse(worklane(tiles: [[a, b]]).isSoleTile(a), "two panes stacked in one column")
        XCTAssertFalse(worklane(tiles: [[a]]).isSoleTile(b), "not in the strip")
    }

    func test_floats_do_not_count_as_tiles() {
        let store = makeStore(tiles: [[a], [b]])
        store.floatPane(b, canvas: canvas, tileFrame: nil)

        XCTAssertTrue(store.worklanes[0].isSoleTile(a))
    }

    // MARK: - Store

    func test_floatPane_leaves_the_sole_tile_in_the_strip() {
        let store = makeStore(tiles: [[a]])

        store.floatPane(a, canvas: canvas, tileFrame: nil)

        XCTAssertEqual(store.worklanes[0].paneStripState.panes.map(\.id), [a])
        XCTAssertTrue(store.worklanes[0].floatingPanes.isEmpty)
    }

    func test_toggleFloat_on_the_sole_tile_is_a_no_op_and_never_asks_for_its_frame() {
        let store = makeStore(tiles: [[a]])
        var askedForFrame = false

        store.toggleFloat(a, canvas: canvas) { _ in
            askedForFrame = true
            return nil
        }

        XCTAssertTrue(store.worklanes[0].floatingPanes.isEmpty)
        XCTAssertFalse(askedForFrame, "no lift is prepared for a float that never comes")
    }

    func test_last_float_still_docks_next_to_the_sole_tile() {
        let store = makeStore(tiles: [[a], [b]])
        store.floatPane(b, canvas: canvas, tileFrame: nil)

        store.toggleFloat(b, canvas: canvas) { _ in nil }

        XCTAssertEqual(store.worklanes[0].paneStripState.panes.map(\.id), [a, b])
    }

    // MARK: - CLI

    func test_cli_refuses_to_float_pip_or_minimize_the_sole_tile() {
        let store = makeStore(tiles: [[a]])
        for action in [PaneFloatAction.float, .pip, .minimize] {
            XCTAssertThrowsError(try store.applyFloatAction(action, to: a, canvas: canvas), "\(action)") { error in
                XCTAssertEqual(error as? FloatControlIPCError, .soleTile("a"))
            }
        }
        XCTAssertTrue(store.worklanes[0].floatingPanes.isEmpty)
    }

    func test_cli_sole_tile_error_explains_itself() {
        let message = FloatControlIPCError.soleTile("a").errorDescription ?? ""
        XCTAssertTrue(message.contains("only tile"), message)
    }

    func test_cli_dock_of_the_sole_tile_stays_a_no_op() throws {
        let store = makeStore(tiles: [[a]])
        XCTAssertNoThrow(try store.applyFloatAction(.dock, to: a, canvas: canvas))
    }

    func test_cli_floats_a_tile_that_has_company() throws {
        let store = makeStore(tiles: [[a], [b]])
        try store.applyFloatAction(.float, to: b, canvas: canvas)
        XCTAssertEqual(store.worklanes[0].floatingPane(id: b)?.mode, .floating)
    }

    // MARK: - Menu / palette availability

    func test_float_or_dock_pane_is_unavailable_on_the_sole_tile() {
        let store = makeStore(tiles: [[a]])
        let counts = PaneAvailabilityCounts(worklaneStore: store)
        XCTAssertTrue(counts.focusedPaneIsSoleTile)
        XCTAssertFalse(CommandAvailabilityResolver.isCommandAvailable(.toggleFloat, for: context(counts)))
        XCTAssertTrue(
            CommandAvailabilityResolver.isCommandAvailable(.closeFocusedPane, for: context(counts)),
            "Close Pane keeps working from the keyboard"
        )
    }

    func test_float_or_dock_pane_is_available_with_a_second_tile_or_on_a_float() {
        let store = makeStore(tiles: [[a], [b]])
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(
            .toggleFloat,
            for: context(PaneAvailabilityCounts(worklaneStore: store))
        ))

        store.floatPane(b, canvas: canvas, tileFrame: nil)
        let counts = PaneAvailabilityCounts(worklaneStore: store)
        XCTAssertFalse(counts.focusedPaneIsSoleTile, "the focused float can dock")
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(.toggleFloat, for: context(counts)))
    }

    // MARK: - Fixtures

    private func context(_ counts: PaneAvailabilityCounts) -> CommandAvailabilityContext {
        CommandAvailabilityContext(
            counts: counts,
            focusedPaneHasRememberedSearch: false,
            globalSearchHasRememberedSearch: false,
            activeWorklaneHasBranchURL: false
        )
    }

    private func worklane(tiles columns: [[PaneID]]) -> WorklaneState {
        WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(
                columns: columns.map { panes in
                    PaneColumnState(
                        id: PaneColumnID("col_\(panes[0].rawValue)"),
                        panes: panes.map { PaneState(id: $0, title: $0.rawValue) },
                        width: 400,
                        focusedPaneID: panes.last,
                        lastFocusedPaneID: panes.last
                    )
                },
                focusedColumnID: columns.last.map { PaneColumnID("col_\($0[0].rawValue)") }
            ),
            nextPaneNumber: 3
        )
    }

    private func makeStore(tiles: [[PaneID]]) -> WorklaneStore {
        WorklaneStore(worklanes: [worklane(tiles: tiles)], activeWorklaneID: worklaneID)
    }
}
