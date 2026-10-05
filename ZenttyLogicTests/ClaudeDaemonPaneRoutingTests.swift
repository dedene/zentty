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

    // MARK: - claude attach

    private static let sessionID = "6e811ae4-adf7-4055-a72c-c4a76db690a2"
    private static let paneA = ["ZENTTY_WORKLANE_ID": "worklane-a", "ZENTTY_PANE_ID": "pane-a"]
    private static let paneB = ["ZENTTY_WORKLANE_ID": "worklane-b", "ZENTTY_PANE_ID": "pane-b", "ZENTTY_CLAUDE_PID": "4242"]

    func test_attach_launches_the_client_as_given_and_announces_the_session() throws {
        let plan = try claudePlan(arguments: ["attach", "6E811AE4"], launchEnvironment: [
            "ZENTTY_CLI_BIN": "/tmp/zentty",
            "ZENTTY_WORKLANE_ID": "worklane-b",
            "ZENTTY_PANE_ID": "pane-b",
            "ZENTTY_PANE_TOKEN": "token-b",
        ])

        XCTAssertEqual(plan.arguments, ["attach", "6E811AE4"], "the attach client takes no --session-id or --settings")
        XCTAssertEqual(plan.preLaunchActions.count, 1)
        let action = try XCTUnwrap(plan.preLaunchActions.first)
        XCTAssertEqual(action.subcommand, "agent-event")
        XCTAssertEqual(action.arguments, ["--adapter=claude"])
        let input = try AgentEventBridge.claudeParseInput(Data(XCTUnwrap(action.standardInput).utf8))
        XCTAssertEqual(input.hookEventName, ClaudeLaunchPolicy.attachEventName)
        XCTAssertEqual(input.sessionID, "6e811ae4")
    }

    func test_attach_without_a_usable_id_announces_nothing() throws {
        for arguments in [["attach"], ["attach", "--help"], ["attach", "6e81"]] {
            let plan = try claudePlan(arguments: arguments, launchEnvironment: ["ZENTTY_CLI_BIN": "/tmp/zentty"])
            XCTAssertEqual(plan.arguments, arguments)
            XCTAssertTrue(plan.preLaunchActions.isEmpty, "\(arguments)")
        }
    }

    func test_attached_session_reports_to_the_attaching_pane_until_the_client_exits() throws {
        var clientIsAlive = true
        let sessionStore = makeSessionStore { _ in clientIsAlive }
        let subagentStore = makeSubagentStore()
        func send(_ event: String, sessionID: String = Self.sessionID, source: String? = nil, from environment: [String: String]) throws -> [AgentStatusPayload] {
            var payload = ["hook_event_name": event, "session_id": sessionID]
            payload["source"] = source
            return try AgentEventBridge.claudeAdapter(
                data: JSONSerialization.data(withJSONObject: payload),
                environment: environment,
                sessionStore: sessionStore,
                subagentStore: subagentStore
            )
        }

        // Launched with `claude --bg` from pane A; its hooks always name pane A.
        _ = try send("SessionStart", source: "startup", from: Self.paneA)
        XCTAssertEqual(try send("Stop", from: Self.paneA).map(\.paneID), [PaneID("pane-a")])

        // `claude attach 6e811ae4` in pane B.
        let attached = try send(ClaudeLaunchPolicy.attachEventName, sessionID: "6e811ae4", from: Self.paneB)
        XCTAssertEqual(attached.map(\.paneID), [PaneID("pane-a"), PaneID("pane-a"), PaneID("pane-b")])
        XCTAssertTrue(attached[0].clearsStatus, "pane A drops the status it can no longer update")
        XCTAssertEqual(attached[1].pidEvent, .clear)
        XCTAssertEqual(attached[2].pidEvent, .attach)
        XCTAssertEqual(attached[2].pid, 4242, "pane B tracks the attach client")
        XCTAssertEqual(attached[2].sessionID, Self.sessionID)

        XCTAssertEqual(try send("Stop", from: Self.paneA).map(\.paneID), [PaneID("pane-b")])
        // A resume, clear or compaction while attached must not bounce it back.
        let restarted = try send("SessionStart", source: "compact", from: Self.paneA)
        XCTAssertEqual(restarted.map(\.paneID), [PaneID("pane-b")])
        XCTAssertEqual(restarted.first?.pid, 4242)
        XCTAssertEqual(try send("UserPromptSubmit", from: Self.paneA).map(\.paneID), [PaneID("pane-b")])

        // Detach: the client exits without any hook.
        clientIsAlive = false
        XCTAssertEqual(try send("Stop", from: Self.paneA).map(\.paneID), [PaneID("pane-a")])
        let record = try XCTUnwrap(sessionStore.lookup(sessionID: Self.sessionID))
        XCTAssertNil(record.attachment)
        XCTAssertNil(record.pid, "the attach client's pid does not outlive the attachment")
    }

    func test_attach_from_the_launch_pane_tracks_the_client_without_clearing_it() throws {
        let sessionStore = makeSessionStore { _ in true }
        let subagentStore = makeSubagentStore()
        var paneA = Self.paneA
        _ = try AgentEventBridge.claudeAdapter(
            data: JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "session_id": Self.sessionID]),
            environment: paneA,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )

        paneA["ZENTTY_CLAUDE_PID"] = "4242"
        let attached = try AgentEventBridge.claudeAdapter(
            data: JSONSerialization.data(withJSONObject: ["hook_event_name": ClaudeLaunchPolicy.attachEventName, "session_id": "6e811ae4"]),
            environment: paneA,
            sessionStore: sessionStore,
            subagentStore: subagentStore
        )
        XCTAssertEqual(attached.map(\.pidEvent), [.attach])
        XCTAssertEqual(attached.first?.paneID, PaneID("pane-a"))
    }

    func test_attach_to_a_session_zentty_never_saw_changes_nothing() throws {
        let sessionStore = makeSessionStore { _ in true }
        let payloads = try AgentEventBridge.claudeAdapter(
            data: JSONSerialization.data(withJSONObject: ["hook_event_name": ClaudeLaunchPolicy.attachEventName, "session_id": "0badc0de"]),
            environment: Self.paneB,
            sessionStore: sessionStore,
            subagentStore: makeSubagentStore()
        )
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(try sessionStore.lookup(sessionID: "0badc0de"))
    }

    func test_attach_announcement_is_handled_the_way_the_wrapper_sends_it() throws {
        // Same entry point and arguments as the wrapper's pre-launch action,
        // against the adapter's default (per-test-process) stores.
        let sessionID = UUID().uuidString.lowercased()
        func run(_ payload: [String: String], environment: [String: String]) throws -> [AgentStatusPayload] {
            var posted: [AgentStatusPayload] = []
            let exitCode = AgentEventBridge.run(
                arguments: ["zentty", "agent-event", "--adapter=claude"],
                environment: environment,
                inputData: try JSONSerialization.data(withJSONObject: payload),
                post: { posted.append($0) },
                writeError: { XCTFail("\($0)") }
            )
            XCTAssertEqual(exitCode, EXIT_SUCCESS)
            return posted
        }

        _ = try run(["hook_event_name": "SessionStart", "session_id": sessionID], environment: Self.paneA)
        var paneB = Self.paneB
        paneB["ZENTTY_CLAUDE_PID"] = "\(getpid())"
        let attached = try run(
            ["hook_event_name": ClaudeLaunchPolicy.attachEventName, "session_id": String(sessionID.prefix(8))],
            environment: paneB
        )
        XCTAssertEqual(attached.last?.paneID, PaneID("pane-b"))
        XCTAssertEqual(attached.last?.pid, getpid())
        XCTAssertEqual(try run(["hook_event_name": "Stop", "session_id": sessionID], environment: Self.paneA).map(\.paneID), [PaneID("pane-b")])
        _ = try run(["hook_event_name": "SessionEnd", "session_id": sessionID], environment: Self.paneA)
    }

    func test_session_records_written_before_attach_existed_still_decode() throws {
        let stateURL = directory.appendingPathComponent("legacy-sessions.json", isDirectory: false)
        try #"{"version":1,"sessions":{"s1":{"sessionID":"s1","worklaneIDRawValue":"worklane-a","paneIDRawValue":"pane-a","preToolUseSlotsByAgentID":{},"tasks":[],"updatedAt":1}}}"#
            .write(to: stateURL, atomically: true, encoding: .utf8)
        let record = try XCTUnwrap(ClaudeHookSessionStore(stateURL: stateURL).lookup(sessionID: "s1"))
        XCTAssertEqual(record.paneID, PaneID("pane-a"))
        XCTAssertNil(record.attachment)
    }

    private func makeSessionStore(isProcessAlive: @escaping (Int32) -> Bool) -> ClaudeHookSessionStore {
        ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("sessions-\(UUID().uuidString).json", isDirectory: false),
            isProcessAlive: isProcessAlive
        )
    }

    private func makeSubagentStore() -> AgentSubagentRegistryStore {
        AgentSubagentRegistryStore(
            stateURL: directory.appendingPathComponent("subagents-\(UUID().uuidString).json", isDirectory: false)
        )
    }

    private func claudePlan(arguments: [String], launchEnvironment: [String: String]) throws -> AgentLaunchPlan {
        var environment = launchEnvironment
        environment["ZENTTY_REAL_BINARY"] = "/usr/bin/true"
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: arguments,
            standardInput: nil,
            environment: environment,
            expectsResponse: true,
            tool: .claude
        )
        return try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: nil,
                worklaneID: WorklaneID(environment["ZENTTY_WORKLANE_ID"] ?? ""),
                paneID: PaneID(environment["ZENTTY_PANE_ID"] ?? "")
            ),
            runtimeDirectoryURL: directory.appendingPathComponent("runtime", isDirectory: true)
        )
    }

    private func claudeHookCommands(launchEnvironment: [String: String]) throws -> [String] {
        let plan = try claudePlan(arguments: [], launchEnvironment: launchEnvironment)
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
