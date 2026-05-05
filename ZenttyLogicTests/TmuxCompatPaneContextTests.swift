import XCTest
@testable import Zentty

final class TmuxCompatPaneContextTests: XCTestCase {
    private let entry = PaneListEntry(
        index: 1,
        id: "pn_alpha",
        column: 1,
        title: "alpha",
        workingDirectory: "/tmp",
        isFocused: true,
        agentTool: nil,
        agentStatus: nil
    )

    func test_window_id_and_index_use_caller_supplied_worklane_coordinates() {
        // Reproduces the bug behind "Could not determine current tmux pane/window":
        // `list-windows` reports each worklane at its enumeration index, so
        // `display-message`/`list-panes` must report the *same* identity for
        // the worklane the pane belongs to — not the pane's column-within-worklane.
        let context = TmuxCompatIPCHandler.paneContext(
            for: entry,
            windowID: "wl_de8b645f",
            windowIndex: 4
        )

        XCTAssertEqual(context["window_id"], "@wl_de8b645f")
        XCTAssertEqual(context["window_index"], "4")
    }

    func test_pane_fields_render_independently_of_window_coordinates() {
        let context = TmuxCompatIPCHandler.paneContext(
            for: entry,
            windowID: "wl_de8b645f",
            windowIndex: 4
        )

        XCTAssertEqual(context["pane_id"], "%pn_alpha")
        XCTAssertEqual(context["pane_uuid"], "pn_alpha")
        XCTAssertEqual(context["pane_index"], "1")
        XCTAssertEqual(context["pane_title"], "alpha")
        XCTAssertEqual(context["pane_current_path"], "/tmp")
        XCTAssertEqual(context["session_name"], "zentty")
    }

    func test_pane_active_falls_back_to_entry_focus_when_no_active_id_passed() {
        let context = TmuxCompatIPCHandler.paneContext(
            for: entry,
            windowID: "wl_x",
            windowIndex: 0
        )
        XCTAssertEqual(context["pane_active"], "1")
    }

    func test_pane_active_uses_explicit_active_pane_id_when_provided() {
        let unfocused = PaneListEntry(
            index: 2,
            id: "pn_beta",
            column: 2,
            title: "beta",
            workingDirectory: nil,
            isFocused: false,
            agentTool: nil,
            agentStatus: nil
        )
        let activeContext = TmuxCompatIPCHandler.paneContext(
            for: unfocused,
            windowID: "wl_x",
            windowIndex: 0,
            activePaneID: "pn_beta"
        )
        XCTAssertEqual(activeContext["pane_active"], "1")

        let inactiveContext = TmuxCompatIPCHandler.paneContext(
            for: unfocused,
            windowID: "wl_x",
            windowIndex: 0,
            activePaneID: "pn_other"
        )
        XCTAssertEqual(inactiveContext["pane_active"], "")
    }
}
