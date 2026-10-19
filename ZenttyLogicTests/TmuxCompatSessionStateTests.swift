import XCTest
@testable import Zentty

final class TmuxCompatSessionStateTests: XCTestCase {
    private func makeState() -> TmuxCompatSessionState {
        TmuxCompatSessionState(now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    func test_numbers_are_stable_and_sequential_per_kind() {
        let state = makeState()

        XCTAssertEqual(state.paneNumber(for: "pn_a"), 0)
        XCTAssertEqual(state.paneNumber(for: "pn_b"), 1)
        XCTAssertEqual(state.paneNumber(for: "pn_a"), 0)
        XCTAssertEqual(state.windowNumber(for: "wl_a"), 0)
        XCTAssertEqual(state.sessionNumber(for: "wd_a"), 0)
        XCTAssertEqual(state.paneID(forNumber: 1), "pn_b")
        XCTAssertEqual(state.worklaneID(forNumber: 0), "wl_a")
        XCTAssertEqual(state.windowID(forSessionNumber: 0), "wd_a")
        XCTAssertNil(state.paneID(forNumber: 7))
    }

    func test_session_created_is_recorded_once() {
        let state = makeState()
        XCTAssertEqual(state.sessionCreatedTimestamp(for: "wd_a"), 1_700_000_000)
    }

    func test_rebind_moves_pane_number_and_options_to_the_replacement() {
        let state = makeState()
        let number = state.paneNumber(for: "pn_old")
        state.setOption("@owner", value: "omx", scope: .pane("pn_old"))
        state.recordShimPane("pn_old", startCommand: "sleep 1")

        state.rebindPane(from: "pn_old", to: "pn_new")

        XCTAssertEqual(state.paneNumber(for: "pn_new"), number)
        XCTAssertEqual(state.paneID(forNumber: number), "pn_new")
        XCTAssertEqual(state.option("@owner", scope: .pane("pn_new")), "omx")
        XCTAssertNil(state.option("@owner", scope: .pane("pn_old")))
        XCTAssertTrue(state.isShimCreatedPane("pn_new"))
        XCTAssertNotEqual(state.paneNumber(for: "pn_old"), number, "the old id gets a fresh number if seen again")
    }

    func test_options_inherit_pane_window_session_global() {
        let state = makeState()
        state.setOption("remain-on-exit", value: "on", scope: .global)
        state.setOption("remain-on-exit", value: "failed", scope: .window("wl_a"))
        state.setOption("@team", value: "alpha", scope: .session("wd_a"))

        XCTAssertEqual(
            state.inheritedOption("remain-on-exit", paneID: "pn_a", worklaneID: "wl_a", windowID: "wd_a"),
            "failed"
        )
        XCTAssertEqual(
            state.inheritedOption("remain-on-exit", paneID: "pn_a", worklaneID: "wl_b", windowID: "wd_a"),
            "on"
        )
        XCTAssertEqual(state.inheritedOption("@team", paneID: nil, worklaneID: nil, windowID: "wd_a"), "alpha")
        XCTAssertNil(state.inheritedOption("@team", paneID: nil, worklaneID: nil, windowID: "wd_b"))
    }

    func test_append_and_unset_options() {
        let state = makeState()
        state.setOption("terminal-features", value: "xterm*:RGB", scope: .session("wd_a"))
        state.appendOption("terminal-features", value: ",*:clipboard", scope: .session("wd_a"))
        XCTAssertEqual(state.option("terminal-features", scope: .session("wd_a")), "xterm*:RGB,*:clipboard")

        state.unsetOption("terminal-features", scope: .session("wd_a"))
        XCTAssertNil(state.option("terminal-features", scope: .session("wd_a")))
    }

    func test_pane_pid_is_pinned_to_the_first_observation() {
        let state = makeState()
        XCTAssertNil(state.pinnedPanePID(for: "pn_a", observed: nil))
        XCTAssertEqual(state.pinnedPanePID(for: "pn_a", observed: 100), 100)
        XCTAssertEqual(state.pinnedPanePID(for: "pn_a", observed: 200), 100)
        XCTAssertEqual(state.pinnedPanePID(for: "pn_a", observed: nil), 100)
    }

    func test_forget_pane_drops_its_facts() {
        let state = makeState()
        state.recordShimPane("pn_a", startCommand: "claude")
        _ = state.pinnedPanePID(for: "pn_a", observed: 100)
        state.forgetPane("pn_a")

        XCTAssertFalse(state.isShimCreatedPane("pn_a"))
        XCTAssertNil(state.startCommand(for: "pn_a"))
        XCTAssertNil(state.pinnedPanePID(for: "pn_a", observed: nil))
    }

    func test_pane_group_follows_a_respawned_pane_and_is_forgotten_with_it() {
        let state = makeState()
        let group = TmuxCompatSessionState.paneGroupKey(creatorPaneID: "pn_old")
        state.assignPaneGroup("pn_old", group: group)

        state.rebindPane(from: "pn_old", to: "pn_new")
        XCTAssertEqual(state.paneGroup(for: "pn_new"), group)
        XCTAssertNil(state.paneGroup(for: "pn_old"))

        state.forgetPane("pn_new")
        XCTAssertNil(state.paneGroup(for: "pn_new"))
    }

    func test_start_command_without_marking_the_pane_shim_created() {
        let state = makeState()
        state.recordStartCommand("pn_user", startCommand: "codex")

        XCTAssertEqual(state.startCommand(for: "pn_user"), "codex")
        XCTAssertFalse(state.isShimCreatedPane("pn_user"))
    }

    func test_recent_shim_pane_window_expires() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let state = TmuxCompatSessionState(now: { clock.now })
        state.recordShimPane("pn_new", startCommand: nil)

        XCTAssertTrue(state.isRecentShimPane("pn_new", within: 5))
        XCTAssertFalse(state.isRecentShimPane("pn_user", within: 5))
        clock.now = Date(timeIntervalSince1970: 1_006)
        XCTAssertFalse(state.isRecentShimPane("pn_new", within: 5))
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}
