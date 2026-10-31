import CoreGraphics
import XCTest
@testable import Zentty

/// UI and other consumers see floated panes (audit sweep C): command
/// availability, sidebar rows, palette/menu bar sources and the peek.
@MainActor
final class FloatConsumerSurfaceTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")
    private let leftID = PaneID("pn_left")
    private let rightID = PaneID("pn_right")
    private let floatID = PaneID("pn_float")

    /// Three tiles; `pn_float` is floated (and focused) by `makeStoreWithFloat`.
    private func makeStore() -> WorklaneStore {
        let panes = [leftID, rightID, floatID].map { id in
            PaneState(
                id: id,
                title: id.rawValue,
                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/\(id.rawValue)"),
                width: 400
            )
        }
        return WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(panes: panes, focusedPaneID: leftID),
                    nextPaneNumber: 4,
                    auxiliaryStateByPaneID: [:]
                ),
            ],
            activeWorklaneID: worklaneID
        )
    }

    private func makeStoreWithFloat() -> WorklaneStore {
        let store = makeStore()
        store.floatPane(floatID, canvas: canvas, tileFrame: nil)
        XCTAssertEqual(store.activeWorklane?.focusedPaneID, floatID, "precondition: float focused")
        return store
    }

    // MARK: - Accessors

    func test_focusedPane_is_the_focused_float() {
        let store = makeStoreWithFloat()

        XCTAssertEqual(store.activeWorklane?.focusedPane?.id, floatID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.focusedPane?.id, leftID)
    }

    // MARK: - Command availability

    func test_availability_counts_include_floats_and_flag_float_focus() {
        let store = makeStoreWithFloat()

        let counts = PaneAvailabilityCounts(worklaneStore: store)

        XCTAssertEqual(counts.activePaneCount, 3)
        XCTAssertEqual(counts.activeTiledPaneCount, 2)
        XCTAssertEqual(counts.totalPaneCount, 3)
        XCTAssertEqual(counts.activeColumnCount, 2)
        XCTAssertTrue(counts.focusedPaneIsFloat)
    }

    func test_focused_float_disables_strip_move_resize_and_move_to_window() {
        let store = makeStoreWithFloat()
        let context = availabilityContext(store)

        for command: AppCommandID in [
            .movePaneLeft, .movePaneRight, .resizePaneLeft, .resizePaneDown,
            .movePaneToNewWindow, .arrangeWidthGoldenFocusWide,
        ] {
            XCTAssertFalse(
                CommandAvailabilityResolver.isCommandAvailable(command, for: context),
                "\(command) must be off while a float owns focus"
            )
        }
        for command: AppCommandID in [
            .closeFocusedPane, .renameCurrentPane, .duplicateFocusedPane, .focusLeftPane, .arrangeWidthHalves,
        ] {
            XCTAssertTrue(
                CommandAvailabilityResolver.isCommandAvailable(command, for: context),
                "\(command) stays on with a focused float"
            )
        }
    }

    func test_tile_focus_with_float_keeps_strip_commands_on() {
        let store = makeStoreWithFloat()
        store.focusPane(id: rightID)
        let context = availabilityContext(store)

        XCTAssertFalse(context.focusedPaneIsFloat)
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(.movePaneLeft, for: context))
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(.movePaneToNewWindow, for: context))
    }

    func test_float_with_single_tile_still_offers_return_to_strip() {
        let store = makeStore()
        store.floatPane(rightID, canvas: canvas, tileFrame: nil)
        store.floatPane(floatID, canvas: canvas, tileFrame: nil)
        let context = availabilityContext(store)

        XCTAssertEqual(context.activeTiledPaneCount, 1)
        XCTAssertTrue(CommandAvailabilityResolver.isCommandAvailable(.focusLeftPane, for: context))
        XCTAssertFalse(CommandAvailabilityResolver.isCommandAvailable(.arrangeWidthFull, for: context))
    }

    // MARK: - Sidebar

    func test_sidebar_lists_float_row_and_highlights_it_without_renaming_worklane() throws {
        let tiledSummary = try XCTUnwrap(summary(makeStore()))
        let store = makeStoreWithFloat()

        let floatSummary = try XCTUnwrap(summary(store))

        XCTAssertEqual(floatSummary.paneRows.map(\.paneID), [leftID, rightID, floatID])
        XCTAssertEqual(floatSummary.paneRows.filter(\.isFocused).map(\.paneID), [floatID])
        store.focusPane(id: leftID)
        let refocusedSummary = try XCTUnwrap(summary(store))
        XCTAssertEqual(floatSummary.primaryText, refocusedSummary.primaryText,
                       "worklane identity follows the strip, not the focused float")
        XCTAssertEqual(tiledSummary.paneRows.count, 3)
    }

    // MARK: - Palette and menu bar

    func test_palette_pane_items_include_floats() {
        let store = makeStoreWithFloat()

        let items = CommandPaletteItemBuilder.buildPaneItems(
            worklanes: store.worklanes,
            currentPaneReference: nil
        )

        XCTAssertEqual(items.count, 3)
    }

    // MARK: - Peek

    func test_peek_selection_commits_original_when_highlight_untouched() {
        let strip = WorklaneStore.PaneReference(worklaneID: worklaneID, paneID: leftID)
        let float = WorklaneStore.PaneReference(worklaneID: worklaneID, paneID: floatID)
        let traversal = WorklanePeekTraversal(references: [
            strip,
            WorklaneStore.PaneReference(worklaneID: worklaneID, paneID: rightID),
        ])

        let selection = WorklanePeekSelectionState.opening(at: strip, restoring: float)

        XCTAssertEqual(selection.committed, float)
        XCTAssertEqual(selection.advancing(by: .forward, traversal: traversal).committed.paneID, rightID)
    }

    func test_peek_traversal_entry_leaves_float_only_worklane() {
        let lanes = [WorklaneID("wl_a"), WorklaneID("wl_b"), WorklaneID("wl_c")]
        let traversal = WorklanePeekTraversal(references: [
            .init(worklaneID: lanes[1], paneID: PaneID("b1")),
            .init(worklaneID: lanes[1], paneID: PaneID("b2")),
            .init(worklaneID: lanes[2], paneID: PaneID("c1")),
            .init(worklaneID: lanes[2], paneID: PaneID("c2")),
        ])

        XCTAssertEqual(
            traversal.entry(leaving: lanes[0], worklaneOrder: lanes, direction: .forward)?.paneID,
            PaneID("b1")
        )
        XCTAssertEqual(
            traversal.entry(leaving: lanes[0], worklaneOrder: lanes, direction: .backward)?.paneID,
            PaneID("c2")
        )
        XCTAssertNil(
            WorklanePeekTraversal(references: []).entry(leaving: lanes[0], worklaneOrder: lanes, direction: .forward)
        )
    }

    // MARK: - Float command availability

    private func isAvailable(_ commandID: AppCommandID, _ store: WorklaneStore) -> Bool {
        CommandAvailabilityResolver.isCommandAvailable(commandID, for: availabilityContext(store))
    }

    func test_minimize_and_pip_need_focused_float() {
        let store = makeStoreWithFloat()
        XCTAssertTrue(isAvailable(.minimizeFloat, store))
        XCTAssertTrue(isAvailable(.pipFloat, store))

        store.focusPane(id: leftID)

        XCTAssertFalse(isAvailable(.minimizeFloat, store), "a tile has focus")
        XCTAssertFalse(isAvailable(.pipFloat, store))
        XCTAssertFalse(isAvailable(.minimizeFloat, makeStore()), "no floats at all")
    }

    func test_hide_all_needs_shown_float_or_hidden_state() {
        XCTAssertFalse(isAvailable(.toggleFloatsHidden, makeStore()))

        let store = makeStoreWithFloat()
        XCTAssertTrue(isAvailable(.toggleFloatsHidden, store))

        store.setFloatsHidden(true)
        XCTAssertTrue(isAvailable(.toggleFloatsHidden, store), "Show Floating Panes stays on while hidden")

        store.setFloatsHidden(false)
        store.pipPane(floatID)
        XCTAssertTrue(isAvailable(.toggleFloatsHidden, store), "a PiP alone can be hidden")

        store.minimizePane(floatID)
        XCTAssertFalse(isAvailable(.toggleFloatsHidden, store), "a pill alone isn't hidden by it")
    }

    func test_cycle_needs_floating_float() {
        XCTAssertFalse(isAvailable(.cycleFloatFocus, makeStore()))

        let store = makeStoreWithFloat()
        XCTAssertTrue(isAvailable(.cycleFloatFocus, store))

        store.setFloatsHidden(true)
        XCTAssertTrue(isAvailable(.cycleFloatFocus, store), "cycling un-hides")

        store.pipPane(floatID)
        XCTAssertFalse(isAvailable(.cycleFloatFocus, store), "PiPs are not cycled")
    }

    func test_focus_next_ignores_pip_and_minimized() throws {
        let store = makeStore()
        store.floatPane(floatID, canvas: canvas, tileFrame: nil)
        store.pipPane(floatID)
        store.floatPane(rightID, canvas: canvas, tileFrame: nil)
        store.minimizePane(rightID)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.map(\.id), [leftID], "precondition: 1 tile")

        XCTAssertEqual(PaneAvailabilityCounts(worklaneStore: store).navigablePaneCount, 1)
        XCTAssertFalse(isAvailable(.focusNextPane, store), "PiP and pill are no navigation targets")
        XCTAssertFalse(isAvailable(.focusPreviousPane, store))

        store.restoreFloat(rightID)
        XCTAssertTrue(isAvailable(.focusNextPane, store), "a visible float is a target")
        store.setFloatsHidden(true)
        XCTAssertFalse(isAvailable(.focusNextPane, store), "hidden floats are not")
    }

    func test_new_float_available_with_empty_worklane() {
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(panes: [], focusedPaneID: nil),
                    nextPaneNumber: 1,
                    auxiliaryStateByPaneID: [:]
                ),
            ],
            activeWorklaneID: worklaneID
        )
        XCTAssertTrue(isAvailable(.newFloat, store))
        XCTAssertFalse(isAvailable(.minimizeFloat, store))
    }

    // MARK: - Helpers

    private func availabilityContext(_ store: WorklaneStore) -> CommandAvailabilityContext {
        CommandAvailabilityContext(
            counts: PaneAvailabilityCounts(worklaneStore: store),
            focusedPaneHasRememberedSearch: false,
            globalSearchHasRememberedSearch: false,
            activeWorklaneHasBranchURL: false
        )
    }

    private func summary(_ store: WorklaneStore) -> WorklaneSidebarSummary? {
        WorklaneSidebarSummaryBuilder.summaries(
            for: store.worklanes,
            activeWorklaneID: worklaneID
        ).first
    }
}
