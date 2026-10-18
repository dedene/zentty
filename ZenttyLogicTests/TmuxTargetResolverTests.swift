import XCTest
@testable import Zentty

final class TmuxTargetResolverTests: XCTestCase {
    private let resolver = TmuxTargetResolver(topology: TmuxTopologyFixture.make(), callerPaneID: "pn_lead")

    private func paneID(_ target: String?) -> String? {
        resolver.pane(target)?.pane.id
    }

    func test_no_target_is_the_callers_pane() {
        XCTAssertEqual(paneID(nil), "pn_lead")
        XCTAssertEqual(paneID(""), "pn_lead")
    }

    func test_numeric_pane_id() {
        XCTAssertEqual(paneID("%4"), "pn_mate")
        XCTAssertEqual(paneID("%9"), "pn_other")
    }

    func test_raw_zentty_pane_id_still_resolves() {
        XCTAssertEqual(paneID("%pn_mate"), "pn_mate")
        XCTAssertEqual(paneID("pn_mate"), "pn_mate")
    }

    func test_missing_pane_does_not_fall_back_to_the_caller() {
        XCTAssertNil(paneID("%99"))
        XCTAssertNil(paneID("%pn_gone"))
    }

    func test_window_id_resolves_to_its_active_pane() {
        XCTAssertEqual(paneID("@8"), "pn_other")
        XCTAssertEqual(resolver.window("@5")?.id, "wl_lead")
        XCTAssertNil(resolver.window("@42"))
    }

    func test_session_window_pane_grammar() {
        XCTAssertEqual(paneID("zentty:0.1"), "pn_mate")
        XCTAssertEqual(paneID("zentty:1"), "pn_other")
        XCTAssertEqual(paneID("=zentty:"), "pn_lead")
        XCTAssertEqual(paneID(":0.1"), "pn_mate")
        XCTAssertEqual(paneID("zentty:@8.%9"), "pn_other")
        XCTAssertEqual(paneID("$1:notes"), "pn_other")
        XCTAssertEqual(paneID(".1"), "pn_mate")
    }

    func test_unknown_session_or_window_fails() {
        XCTAssertNil(paneID("claude-swarm:0"))
        XCTAssertNil(paneID("zentty:7"))
        XCTAssertNil(paneID("zentty:0.5"))
        XCTAssertNil(paneID("zentty:1.%4"), "pane %4 is not in window 1")
    }

    func test_bare_word_tries_pane_index_then_window_then_session() {
        XCTAssertEqual(paneID("1"), "pn_mate")
        XCTAssertEqual(paneID("notes"), "pn_other")
        XCTAssertEqual(paneID("zentty"), "pn_lead")
    }

    func test_window_targets_never_read_a_number_as_a_pane_index() {
        // `kill-window -t 1` from the lead's worklane means window 1, even
        // though the lead's window has a pane at index 1.
        XCTAssertEqual(resolver.window("1")?.id, "wl_second")
        XCTAssertEqual(paneID("1"), "pn_mate", "a pane target still reads it as a pane index")
    }

    func test_session_name_wins_over_a_worklane_with_the_same_name() {
        var topology = TmuxTopologyFixture.make()
        topology.session.windows[1].name = "zentty"
        let resolver = TmuxTargetResolver(topology: topology, callerPaneID: "pn_lead")

        XCTAssertEqual(resolver.window("zentty")?.id, "wl_lead")
        XCTAssertEqual(resolver.window("zentty:")?.id, "wl_lead")
        XCTAssertEqual(resolver.window("=zentty")?.id, "wl_lead")

        topology.session.windows[1].name = "zentty-app"
        XCTAssertEqual(
            TmuxTargetResolver(topology: topology, callerPaneID: "pn_lead").window("zentty")?.id,
            "wl_lead",
            "nor does a worklane whose name starts with it"
        )
    }

    func test_unknown_caller_has_no_default_target() {
        // The caller's pane closed (or was replaced): no default target, so
        // split-window / kill-pane cannot land on whatever pane is active.
        let resolver = TmuxTargetResolver(topology: TmuxTopologyFixture.make(), callerPaneID: "pn_gone")

        XCTAssertNil(resolver.pane(nil))
        XCTAssertNil(resolver.window(nil))
        XCTAssertNil(resolver.pane("{last}"))
        XCTAssertEqual(resolver.pane("%4")?.pane.id, "pn_mate", "explicit targets still work")
        XCTAssertEqual(resolver.window("zentty")?.id, "wl_lead", "a session target means its active window")
    }

    func test_pane_group_targets() {
        let resolver = TmuxTargetResolver(topology: TmuxTopologyFixture.makeWithPaneGroup(), callerPaneID: "pn_worker")

        XCTAssertEqual(resolver.pane("@20")?.pane.id, "pn_worker")
        XCTAssertEqual(resolver.window(nil)?.number, 20, "a pane-group pane's own window is its group")
        XCTAssertEqual(resolver.pane("zentty:2.0")?.pane.id, "pn_worker")
        XCTAssertEqual(resolver.pane("zentty:@20.%11")?.pane.id, "pn_worker")
        XCTAssertNil(resolver.pane("zentty:@5.%11"), "pane %11 is not in the worklane's own window")
        XCTAssertEqual(resolver.window("@5")?.panes.map(\.id), ["pn_lead", "pn_mate"])
    }

    func test_brace_tokens_fall_back_to_the_caller() {
        XCTAssertEqual(paneID("{last}"), "pn_lead")
    }

    func test_matches_session() {
        XCTAssertTrue(resolver.matchesSession(nil))
        XCTAssertTrue(resolver.matchesSession("zentty"))
        XCTAssertTrue(resolver.matchesSession("=zentty"))
        XCTAssertTrue(resolver.matchesSession("$1"))
        XCTAssertTrue(resolver.matchesSession("zentty:0"))
        XCTAssertTrue(resolver.matchesSession("%3"))
        XCTAssertFalse(resolver.matchesSession("claude-swarm"))
        XCTAssertFalse(resolver.matchesSession("$2"))
        XCTAssertFalse(resolver.matchesSession("%99"))
    }
}
