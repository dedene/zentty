import Foundation
import XCTest
@testable import Zentty

/// dedene/zentty#121: Claude Code runs background sessions (`claude --bg`,
/// `claude agents`) under one shared per-user daemon. The daemon is started by
/// whichever pane first needs it and keeps that pane's `ZENTTY_*` environment,
/// so every background session's hooks run with the daemon starter's routing
/// variables and its `ZENTTY_CLAUDE_PID`, whichever pane launched the session.
/// `claude --bg` also discards an injected `--session-id`, so the session id
/// cannot tie the hooks back to the launch. The per-launch `--settings` does
/// reach the daemon session, so the hook command itself carries the routing.
final class ClaudeDaemonPaneRoutingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-daemon-pane-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test_hook_command_overrides_a_daemon_inherited_environment_with_the_launch_pane() throws {
        // A stand-in for the zentty CLI that reports the routing it was run with.
        let cliURL = directory.appendingPathComponent("zentty cli", isDirectory: false)
        try """
        #!/bin/sh
        echo "$ZENTTY_INSTANCE_SOCKET|${ZENTTY_WINDOW_ID-unset}|$ZENTTY_WORKLANE_ID|$ZENTTY_PANE_ID|$ZENTTY_PANE_TOKEN|$*"
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let commands = try claudeHookCommands(launchEnvironment: [
            "ZENTTY_CLI_BIN": cliURL.path,
            "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty run/b.sock",
            "ZENTTY_WORKLANE_ID": "worklane-b",
            "ZENTTY_PANE_ID": "pane-b",
            "ZENTTY_PANE_TOKEN": "token-b",
        ])
        XCTAssertEqual(Set(commands).count, 1, "every Claude hook carries the same routing")

        // The hook runs under the daemon, whose environment names pane A.
        let output = try runShell(XCTUnwrap(commands.first), environment: [
            "ZENTTY_INSTANCE_SOCKET": "/tmp/a.sock",
            "ZENTTY_WINDOW_ID": "window-a",
            "ZENTTY_WORKLANE_ID": "worklane-a",
            "ZENTTY_PANE_ID": "pane-a",
            "ZENTTY_PANE_TOKEN": "token-a",
        ])

        // The launch had no window id; pane A's must not leak in, since the
        // pane token is derived from the window id too.
        XCTAssertEqual(
            output,
            "/tmp/zentty run/b.sock|unset|worklane-b|pane-b|token-b|ipc agent-event --adapter=claude"
        )
    }

    func test_hook_command_stays_plain_without_launch_routing() throws {
        let commands = try claudeHookCommands(launchEnvironment: [
            "ZENTTY_CLI_BIN": "/usr/local/bin/zentty",
            "ZENTTY_WORKLANE_ID": "worklane-b",
            "ZENTTY_PANE_ID": "pane-b",
        ])

        XCTAssertEqual(Set(commands), [#""/usr/local/bin/zentty" ipc agent-event --adapter=claude"#])
    }

    func test_inherited_agent_pid_is_dropped_unless_it_is_an_ancestor_of_the_hook() {
        let environment = ["ZENTTY_CLAUDE_PID": "4242", "ZENTTY_PANE_ID": "pane-b"]

        XCTAssertEqual(
            AgentHookProcessLineage.droppingInheritedPID(key: "ZENTTY_CLAUDE_PID", from: environment, isAncestor: { $0 == 4242 }),
            environment
        )
        XCTAssertEqual(
            AgentHookProcessLineage.droppingInheritedPID(key: "ZENTTY_CLAUDE_PID", from: environment, isAncestor: { _ in false }),
            ["ZENTTY_PANE_ID": "pane-b"]
        )
    }

    func test_ancestor_lookup_walks_the_parent_chain() {
        // hook (30) <- sh (20) <- claude (10) <- shell (5) <- launchd (1)
        let parents: [Int32: Int32] = [30: 20, 20: 10, 10: 5, 5: 1]
        let parent: (Int32) -> Int32? = { parents[$0] }

        XCTAssertTrue(AgentHookProcessLineage.isAncestor(10, of: 30, parent: parent))
        XCTAssertFalse(AgentHookProcessLineage.isAncestor(4242, of: 30, parent: parent), "the daemon starter's Claude is not an ancestor")
        XCTAssertFalse(AgentHookProcessLineage.isAncestor(30, of: 30, parent: parent))
        XCTAssertTrue(AgentHookProcessLineage.isAncestor(getppid()), "real lookup resolves this process's parent")
    }

    private func claudeHookCommands(launchEnvironment: [String: String]) throws -> [String] {
        var environment = launchEnvironment
        environment["ZENTTY_REAL_BINARY"] = "/usr/bin/true"
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: [],
            standardInput: nil,
            environment: environment,
            expectsResponse: true,
            tool: .claude
        )
        let plan = try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: nil,
                worklaneID: WorklaneID(environment["ZENTTY_WORKLANE_ID"] ?? ""),
                paneID: PaneID(environment["ZENTTY_PANE_ID"] ?? "")
            ),
            runtimeDirectoryURL: directory.appendingPathComponent("runtime", isDirectory: true)
        )
        let settingsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--settings"))
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(plan.arguments[settingsIndex + 1].utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
        return hooks.values.flatMap { $0 }.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private func runShell(_ command: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
