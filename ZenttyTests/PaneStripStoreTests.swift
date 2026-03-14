import XCTest
@testable import Zentty

final class PaneStripStoreTests: XCTestCase {
    func test_store_starts_with_single_focused_pane() {
        let store = PaneStripStore()

        XCTAssertEqual(store.state.panes.map(\.title), ["shell"])
        XCTAssertEqual(store.state.focusedPane?.title, "shell")
    }

    func test_split_inserts_adjacent_pane_and_focuses_it() {
        let store = PaneStripStore()
        store.updateMetadata(
            id: PaneID("shell"),
            metadata: TerminalMetadata(currentWorkingDirectory: "/tmp/project")
        )

        store.send(.split)

        XCTAssertEqual(store.state.panes.map(\.title), ["shell", "pane 1"])
        XCTAssertEqual(store.state.focusedPane?.title, "pane 1")
        XCTAssertEqual(store.state.focusedPane?.sessionRequest.workingDirectory, "/tmp/project")
    }

    func test_close_removes_focused_pane_and_moves_focus_to_nearest_neighbor() {
        let store = PaneStripStore(state: .pocDefault)

        store.send(.closeFocusedPane)

        XCTAssertEqual(store.state.panes.map(\.title), ["shell"])
        XCTAssertEqual(store.state.focusedPane?.title, "shell")
    }

    func test_close_keeps_at_least_one_pane_in_the_strip() {
        let store = PaneStripStore(
            state: PaneStripState(
                panes: [PaneState(id: PaneID("solo"), title: "solo")]
            )
        )

        store.send(.closeFocusedPane)

        XCTAssertEqual(store.state.panes.map(\.title), ["solo"])
        XCTAssertEqual(store.state.focusedPane?.title, "solo")
    }

    func test_focus_commands_update_the_focused_pane() {
        let store = PaneStripStore(
            state: PaneStripState(
                panes: [
                    PaneState(id: PaneID("logs"), title: "logs"),
                    PaneState(id: PaneID("editor"), title: "editor"),
                    PaneState(id: PaneID("tests"), title: "tests"),
                    PaneState(id: PaneID("shell"), title: "shell"),
                ],
                focusedPaneID: PaneID("editor")
            )
        )

        store.send(.focusRight)
        XCTAssertEqual(store.state.focusedPane?.title, "tests")

        store.send(.focusLeft)
        XCTAssertEqual(store.state.focusedPane?.title, "editor")

        store.send(.focusLast)
        XCTAssertEqual(store.state.focusedPane?.title, "shell")

        store.send(.focusFirst)
        XCTAssertEqual(store.state.focusedPane?.title, "logs")
    }
}
