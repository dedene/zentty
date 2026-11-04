import AppKit
import XCTest
@testable import Zentty

/// Floats in the sidebar (UX spec §13): normal pane rows with a mode glyph,
/// no separate overlay rows, and `show_overlays` hiding only temporary floats.
@MainActor
final class SidebarFloatRowTests: AppKitTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let worklaneID = WorklaneID("wl_main")

    private func makeStore(tiles: [String]) -> WorklaneStore {
        let panes = tiles.map { id in
            PaneState(
                id: PaneID(id),
                title: id,
                sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp"),
                width: 400
            )
        }
        return WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(panes: panes, focusedPaneID: PaneID(tiles[0])),
                    nextPaneNumber: tiles.count + 1,
                    auxiliaryStateByPaneID: [:]
                ),
            ],
            activeWorklaneID: worklaneID
        )
    }

    private func summary(_ store: WorklaneStore, showsTemporaryFloats: Bool = true) throws -> WorklaneSidebarSummary {
        try XCTUnwrap(WorklaneSidebarSummaryBuilder.summaries(
            for: store.worklanes,
            activeWorklaneID: worklaneID,
            showsTemporaryFloats: showsTemporaryFloats
        ).first)
    }

    private func openOverlay(_ store: WorklaneStore, on owner: String) throws -> PaneID {
        try store.openOverlayFloat(
            on: PaneID(owner),
            request: OverlayFloatRequest(
                command: "/bin/echo hi", workingDirectory: "/tmp", waitAfterCommand: true,
                placement: .pane, sizePercent: 100, follow: false, notify: false
            ),
            canvas: canvas,
            ownerFrame: nil
        ).id
    }

    // MARK: - Rows

    func test_float_rows_carry_their_mode_and_every_pane_is_listed_once() throws {
        let store = makeStore(tiles: ["tile", "float", "pip", "pill"])
        for id in ["float", "pip", "pill"] {
            store.floatPane(PaneID(id), canvas: canvas, tileFrame: nil)
        }
        store.pipPane(PaneID("pip"))
        store.minimizePane(PaneID("pill"))

        let rows = try summary(store).displayPaneRows

        XCTAssertEqual(rows.map(\.paneID.rawValue), ["tile", "float", "pip", "pill"])
        XCTAssertEqual(rows.map(\.floatMode), [nil, .floating, .pip, .minimized])
    }

    func test_overlay_floats_are_plain_pane_rows_with_a_float_glyph() throws {
        let store = makeStore(tiles: ["a", "b"])
        let overlayID = try openOverlay(store, on: "a")

        let rows = try summary(store).displayPaneRows

        XCTAssertEqual(rows.map(\.paneID), [PaneID("a"), PaneID("b"), overlayID])
        XCTAssertEqual(rows.last?.floatMode, .floating)
        XCTAssertEqual(rows.map(\.isTemporaryFloat), [false, false, true])
    }

    func test_hiding_overlays_drops_temporary_floats_only() throws {
        let store = makeStore(tiles: ["a", "b", "float"])
        store.floatPane(PaneID("float"), canvas: canvas, tileFrame: nil)
        let overlayID = try openOverlay(store, on: "a")

        let shown = try summary(store).displayPaneRows.map(\.paneID)
        let hidden = try summary(store, showsTemporaryFloats: false).displayPaneRows.map(\.paneID)

        XCTAssertTrue(shown.contains(overlayID))
        XCTAssertEqual(hidden, [PaneID("a"), PaneID("b"), PaneID("float")])
    }

    func test_a_tile_with_only_a_hidden_overlay_beside_it_reads_as_a_single_pane() throws {
        let single = makeStore(tiles: ["a"])
        let withOverlay = makeStore(tiles: ["a"])
        _ = try openOverlay(withOverlay, on: "a")

        func text(_ rows: [WorklaneSidebarPaneRow]) -> [[String?]] {
            rows.map { [$0.primaryText, $0.trailingText, $0.detailText] }
        }
        XCTAssertEqual(
            text(try summary(withOverlay, showsTemporaryFloats: false).displayPaneRows),
            text(try summary(single).displayPaneRows)
        )
    }

    func test_an_overlay_floats_shell_signals_land_on_its_own_pane() throws {
        let store = makeStore(tiles: ["a"])
        let overlayID = try openOverlay(store, on: "a")

        store.applyAgentStatusPayload(AgentStatusPayload(
            worklaneID: worklaneID, paneID: overlayID, signalKind: .paneContext, state: nil,
            paneContext: PaneShellContext(scope: .local, path: "/private/var", home: NSHomeDirectory(), user: nil, host: nil),
            origin: .shell, toolName: nil, text: nil, artifactKind: nil, artifactLabel: nil, artifactURL: nil
        ))

        let worklane = try XCTUnwrap(store.activeWorklane)
        let overlayState = try XCTUnwrap(worklane.auxiliaryStateByPaneID[overlayID])
        XCTAssertEqual(overlayState.shellContext?.path, "/private/var")
        XCTAssertEqual(PaneCopyTargetResolver.target(for: overlayState), .path("/private/var"),
                       "Copy Path on a focused overlay copies where its shell is")
        XCTAssertNil(worklane.auxiliaryStateByPaneID[PaneID("a")]?.shellContext, "the owner is untouched")
    }

    // MARK: - Glyph

    func test_float_glyphs_are_real_symbols_with_spoken_names() {
        let expected: [(WorklaneSidebarFloatMode, String, String)] = [
            (.floating, "rectangle.on.rectangle", "Floating pane"),
            (.pip, "pip", "Picture in picture"),
            (.minimized, "dock.rectangle", "Minimized pane"),
        ]
        for (mode, symbol, label) in expected {
            XCTAssertEqual(mode.symbolName, symbol)
            XCTAssertEqual(mode.accessibilityLabel, label)
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil), symbol)
        }
        XCTAssertEqual(WorklaneSidebarFloatMode(.floating), .floating)
        XCTAssertEqual(WorklaneSidebarFloatMode(.pip(corner: .topLeft, order: 1)), .pip)
        XCTAssertEqual(WorklaneSidebarFloatMode(.minimized(order: 0)), .minimized)
    }

    func test_primary_row_shows_the_float_glyph_beside_the_remote_indicator() {
        let view = SidebarPanePrimaryRowView()
        view.configureRemoteIndicator(isRemote: true, label: nil)

        view.configureFloatIndicator(.pip)

        XCTAssertEqual(view.floatIconSymbolNameForTesting, "pip")
        XCTAssertEqual(view.floatIconAccessibilityLabelForTesting, "Picture in picture")
        XCTAssertTrue(view.remoteIconIsVisibleForTesting, "a floated ssh pane is still remote")

        view.configureFloatIndicator(nil)

        XCTAssertNil(view.floatIconSymbolNameForTesting)
    }
}
