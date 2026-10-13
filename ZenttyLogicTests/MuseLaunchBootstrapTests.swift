import Foundation
import XCTest
@testable import Zentty

/// Muse Code launch plan: a per-pane managed hooks file (the user's managed
/// hooks plus ours) named by `TBH_MANAGED_HOOKS_PATH`, and a per-run
/// `-c managed_hooks_env_vars=[…]` so Muse lets the Zentty routing env reach
/// the hook process.
final class MuseLaunchBootstrapTests: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makePlan(
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        home: URL? = nil
    ) throws -> AgentLaunchPlan {
        let runtimeDirectory = try makeTemporaryDirectory(named: "agent-launch-muse-runtime")
        let homeDirectory = try home ?? makeTemporaryDirectory(named: "agent-launch-muse-home")
        var environment = [
            "HOME": homeDirectory.path,
            "ZENTTY_REAL_BINARY": "/Users/test/.local/bin/muse",
            "ZENTTY_CLI_BIN": "/tmp/zentty",
        ]
        environment.merge(extraEnvironment) { _, new in new }
        let request = AgentIPCRequest(
            kind: .bootstrap,
            arguments: arguments,
            standardInput: nil,
            environment: environment,
            expectsResponse: true,
            tool: .muse
        )
        return try AgentLaunchBootstrap.makePlan(
            request: request,
            target: AgentIPCTarget(
                windowID: WindowID("window-main"),
                worklaneID: WorklaneID("worklane-main"),
                paneID: PaneID("pane-main")
            ),
            runtimeDirectoryURL: runtimeDirectory
        )
    }

    private func hooks(of plan: AgentLaunchPlan) throws -> [String: Any] {
        let path = try XCTUnwrap(plan.setEnvironment["TBH_MANAGED_HOOKS_PATH"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        )
        return try XCTUnwrap(object["hooks"] as? [String: Any])
    }

    private func commands(in hooks: [String: Any], event: String) -> [[String: Any]] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    private func allowlist(in arguments: [String]) throws -> [String] {
        let assignment = try XCTUnwrap(arguments.first { $0.hasPrefix("managed_hooks_env_vars=") })
        let data = Data(assignment.dropFirst("managed_hooks_env_vars=".count).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
    }

    func test_muse_plan_writes_managed_hooks_and_prepends_env_allowlist_for_tui() throws {
        let plan = try makePlan(arguments: ["--model", "muse-spark-1.2", "fix the bug"])

        XCTAssertEqual(plan.executablePath, "/Users/test/.local/bin/muse")
        XCTAssertEqual(plan.setEnvironment["ZENTTY_AGENT_TOOL"], "muse")
        XCTAssertEqual(Array(plan.arguments.prefix(1)), ["-c"])
        XCTAssertEqual(Array(plan.arguments.suffix(3)), ["--model", "muse-spark-1.2", "fix the bug"])
        XCTAssertEqual(try allowlist(in: plan.arguments), AgentLaunchBootstrap.museHookEnvironmentKeys)

        let hooks = try hooks(of: plan)
        for event in [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "ToolUseStart",
            "PostToolUse", "PostToolUseFailure", "PostToolBatch", "PermissionRequest",
            "Notification", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
            "Stop", "StopFailure", "Interrupt",
        ] {
            let handlers = commands(in: hooks, event: event)
            XCTAssertEqual(handlers.count, 1, event)
            XCTAssertEqual(handlers.first?["command"] as? String, "\"/tmp/zentty\" ipc agent-event --adapter=muse", event)
        }
        // Muse only admits these two as async handlers.
        XCTAssertEqual(commands(in: hooks, event: "ToolUseStart").first?["async"] as? Bool, true)
        XCTAssertEqual(commands(in: hooks, event: "Interrupt").first?["async"] as? Bool, true)
        XCTAssertNil(commands(in: hooks, event: "Stop").first?["async"])
    }

    func test_muse_plan_inserts_allowlist_after_exec_subcommand() throws {
        let plan = try makePlan(arguments: ["exec", "--model", "muse-spark-1.2", "hi"])

        XCTAssertEqual(plan.arguments.first, "exec")
        XCTAssertEqual(plan.arguments[1], "-c")
        XCTAssertTrue(plan.arguments[2].hasPrefix("managed_hooks_env_vars="))
        XCTAssertEqual(Array(plan.arguments.suffix(3)), ["--model", "muse-spark-1.2", "hi"])
    }

    func test_muse_plan_prepends_allowlist_for_resume() throws {
        let plan = try makePlan(arguments: ["resume", "01a1312b-07c1-7eb0-8d56-c65f7b11496b"])

        XCTAssertEqual(plan.arguments.first, "-c")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["resume", "01a1312b-07c1-7eb0-8d56-c65f7b11496b"])
    }

    /// `TBH_MANAGED_HOOKS_PATH` replaces `settings.json`'s managed path, so the
    /// overlay keeps the user's managed hooks and env allowlist.
    func test_muse_plan_merges_managed_hooks_and_allowlist_from_user_settings() throws {
        let home = try makeTemporaryDirectory(named: "agent-launch-muse-settings-home")
        let configDirectory = home.appendingPathComponent(".config/muse", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let managedHooks = home.appendingPathComponent("enterprise-hooks.json", isDirectory: false)
        try #"{"hooks":{"PreToolUse":[{"matcher":"bash","hooks":[{"type":"command","command":"audit"}]}]}}"#
            .write(to: managedHooks, atomically: true, encoding: .utf8)
        try """
        {"schema_version":1,"managed_hooks_path":"\(managedHooks.path)","managed_hooks_env_vars":["AUDIT_TOKEN"]}
        """.write(to: configDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let plan = try makePlan(arguments: [], home: home)

        let preToolUse = commands(in: try hooks(of: plan), event: "PreToolUse").compactMap { $0["command"] as? String }
        XCTAssertEqual(preToolUse, ["audit", "\"/tmp/zentty\" ipc agent-event --adapter=muse"])
        XCTAssertEqual(try allowlist(in: plan.arguments), ["AUDIT_TOKEN"] + AgentLaunchBootstrap.museHookEnvironmentKeys)
    }

    func test_muse_plan_prefers_env_managed_hooks_path_over_settings() throws {
        let directory = try makeTemporaryDirectory(named: "agent-launch-muse-env-hooks")
        let envHooks = directory.appendingPathComponent("env-hooks.json", isDirectory: false)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"from-env"}]}]}}"#
            .write(to: envHooks, atomically: true, encoding: .utf8)

        let plan = try makePlan(arguments: [], environment: ["TBH_MANAGED_HOOKS_PATH": envHooks.path])

        XCTAssertNotEqual(plan.setEnvironment["TBH_MANAGED_HOOKS_PATH"], envHooks.path)
        let stop = commands(in: try hooks(of: plan), event: "Stop").compactMap { $0["command"] as? String }
        XCTAssertEqual(stop.first, "from-env")
        XCTAssertEqual(stop.count, 2)
    }

    func test_muse_plan_expands_home_in_settings_managed_hooks_path() throws {
        let home = try makeTemporaryDirectory(named: "agent-launch-muse-tilde-home")
        let configDirectory = home.appendingPathComponent(".config/muse", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"from-tilde"}]}]}}"#
            .write(to: home.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        try #"{"managed_hooks_path":"~/hooks.json"}"#
            .write(to: configDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let plan = try makePlan(arguments: [], home: home)

        XCTAssertEqual(commands(in: try hooks(of: plan), event: "Stop").first?["command"] as? String, "from-tilde")
    }

    /// A nested launch inherits the parent's overlay path, which is never a
    /// source; the settings file still is.
    func test_muse_plan_nested_launch_falls_back_to_settings_managed_hooks() throws {
        let home = try makeTemporaryDirectory(named: "agent-launch-muse-nested-home")
        let configDirectory = home.appendingPathComponent(".config/muse", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let managed = home.appendingPathComponent("enterprise.json")
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"audit"}]}]}}"#
            .write(to: managed, atomically: true, encoding: .utf8)
        try #"{"managed_hooks_path":"\#(managed.path)"}"#
            .write(to: configDirectory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let plan = try makePlan(
            arguments: [],
            environment: ["TBH_MANAGED_HOOKS_PATH": "/Users/test/.config/zentty/run/launch/w/p/muse/managed-hooks.json"],
            home: home
        )

        XCTAssertEqual(commands(in: try hooks(of: plan), event: "Stop").first?["command"] as? String, "audit")
    }

    /// A user `-c managed_hooks_env_vars=…` would clash with ours (Muse
    /// refuses a key set twice), so it is folded into one list.
    func test_muse_plan_folds_user_allowlist_argument_into_one() throws {
        let plan = try makePlan(arguments: ["-c", #"managed_hooks_env_vars=["MY_VAR"]"#, "--model", "m", "--", "-c", "keep"])

        XCTAssertEqual(plan.arguments.filter { $0.hasPrefix("managed_hooks_env_vars=") }.count, 1)
        XCTAssertEqual(try allowlist(in: plan.arguments), ["MY_VAR"] + AgentLaunchBootstrap.museHookEnvironmentKeys)
        XCTAssertEqual(Array(plan.arguments.suffix(5)), ["--model", "m", "--", "-c", "keep"])
    }

    func test_muse_plan_hooks_disabled_returns_direct_plan_and_sheds_inherited_overlay() throws {
        let inherited = "/Users/test/.config/zentty/run/launch/w/p/muse/managed-hooks.json"
        let plan = try makePlan(
            arguments: ["hi"],
            environment: ["ZENTTY_MUSE_HOOKS_DISABLED": "1", "TBH_MANAGED_HOOKS_PATH": inherited]
        )

        XCTAssertEqual(plan.arguments, ["hi"])
        XCTAssertNil(plan.setEnvironment["TBH_MANAGED_HOOKS_PATH"])
        XCTAssertEqual(plan.unsetEnvironment, ["TBH_MANAGED_HOOKS_PATH"])
    }

    func test_muse_plan_hooks_disabled_keeps_user_managed_hooks_path() throws {
        let plan = try makePlan(
            arguments: ["hi"],
            environment: ["ZENTTY_MUSE_HOOKS_DISABLED": "1", "TBH_MANAGED_HOOKS_PATH": "/etc/muse/hooks.json"]
        )

        XCTAssertEqual(plan.arguments, ["hi"])
        XCTAssertTrue(plan.unsetEnvironment.isEmpty)
    }
}
