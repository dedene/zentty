import XCTest
@testable import Zentty

/// A live fork types its command into a fresh shell, which inherits nothing from the source pane.
/// The fork must name the session's Claude config root like an ended resume does, or `claude`
/// looks in whatever root that shell exports and can't find the conversation.
extension AgentHistoryLauncherTests {
    func test_live_fork_from_alternate_claude_root_sets_config_dir() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        var live = source(liveSessionID, rowID: 4)
        live.sourceRoot = "/Users/tester/.claude-work/"

        let outcome = launcher.perform(.secondary, source: live)

        guard case .forked(let result) = outcome else {
            return XCTFail("expected a fork, got \(outcome)")
        }
        let forkPane = try XCTUnwrap(
            host.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID }
        )
        XCTAssertEqual(
            forkPane.sessionRequest.command,
            "env CLAUDE_CONFIG_DIR=/Users/tester/.claude-work claude --resume \(liveSessionID) --fork-session"
        )
    }

    /// A default-root session must not follow a `CLAUDE_CONFIG_DIR` the new shell exports for
    /// another account.
    func test_live_fork_from_default_claude_root_unsets_config_dir() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let launcher = makeLauncher(hosts: [host], presenting: host, homeDirectory: "/Users/tester")
        var live = source(liveSessionID, rowID: 4)
        live.sourceRoot = "/Users/tester/.claude"

        let outcome = launcher.perform(.secondary, source: live)

        guard case .forked(let result) = outcome else {
            return XCTFail("expected a fork, got \(outcome)")
        }
        XCTAssertEqual(host.forkRequests.map(\.sessionOverride?.claudeConfigRoot), [.defaultRoot])
        let forkPane = try XCTUnwrap(
            host.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID }
        )
        XCTAssertEqual(
            forkPane.sessionRequest.command,
            "env -u CLAUDE_CONFIG_DIR claude --resume \(liveSessionID) --fork-session"
        )
    }

    func test_live_fork_without_a_known_root_leaves_the_environment_alone() throws {
        let host = LauncherFakeHost(windowID: windowA, store: makeStore(windowA, liveSession: true))
        let launcher = makeLauncher(hosts: [host], presenting: host)
        var live = source(liveSessionID, rowID: 4)
        live.sourceRoot = "relative/.claude"

        guard case .forked(let result) = launcher.perform(.secondary, source: live) else {
            return XCTFail("expected a fork")
        }
        XCTAssertEqual(host.forkRequests.map(\.sessionOverride?.claudeConfigRoot), [nil])
        let forkPane = try XCTUnwrap(
            host.worklaneStore.activeWorklane?.paneStripState.panes.first { $0.id == result.paneID }
        )
        XCTAssertEqual(forkPane.sessionRequest.command, "claude --resume \(liveSessionID) --fork-session")
    }
}
