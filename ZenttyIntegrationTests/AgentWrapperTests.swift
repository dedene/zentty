import Darwin
import Foundation
import XCTest
@testable import Zentty

@MainActor
final class AgentWrapperTests: XCTestCase {
    func test_real_cli_help_hides_internal_commands_and_shows_public_version_command() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["--help"]
        process.standardInput = Pipe()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertTrue(stdoutString.contains("version"), stdoutString)
        XCTAssertFalse(stdoutString.contains("codex-notify"), stdoutString)
        XCTAssertFalse(stdoutString.contains("\nipc"), stdoutString)
        XCTAssertFalse(stdoutString.contains("\n  ipc"), stdoutString)
        XCTAssertFalse(stdoutString.contains("launch"), stdoutString)
    }

    func test_real_cli_version_reports_marketing_version_and_git_commit() throws {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundleURL = productsURL.appendingPathComponent("Zentty.app", isDirectory: true)
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        let metadata = AboutMetadata.load(from: appBundle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["version"]
        process.standardInput = Pipe()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertEqual(
            stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            "zentty \(metadata.version) (\(metadata.commit))"
        )
    }

    func test_bare_command_zentty_version_reports_marketing_version_and_git_commit() throws {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundleURL = productsURL.appendingPathComponent("Zentty.app", isDirectory: true)
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))
        let metadata = AboutMetadata.load(from: appBundle)
        let bundledCLI = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
            .path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "zentty version"]
        process.standardInput = Pipe()

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([bundledCLI, environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment.removeValue(forKey: "ZENTTY_CLI_BIN")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, stderrString)
        XCTAssertEqual(
            stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            "zentty \(metadata.version) (\(metadata.commit))"
        )
    }

    func test_real_cli_launch_accepts_dash_prefixed_tool_arguments() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )

        let result = try harness.run(
            tool: "codex",
            arguments: ["--yolo"],
            extraEnvironment: [
                "ZENTTY_CLI_BIN": try builtCLIPath(),
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["--yolo"])
    }

    func test_real_cli_ipc_accepts_dash_prefixed_passthrough_arguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event", "--adapter=codex"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = ""
        environment["ZENTTY_PANE_TOKEN"] = ""
        environment["ZENTTY_WORKLANE_ID"] = ""
        environment["ZENTTY_PANE_ID"] = ""
        process.environment = environment

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.standardInput = Pipe()

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(data: stderrData, encoding: .utf8) ?? "")
    }

    func test_real_cli_codex_notify_forwards_payload_to_codex_notify_adapter() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"type":"agent-turn-complete","session_id":"session-1"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["codex-notify", payload]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .ipc)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=codex-notify"])
        XCTAssertEqual(request.standardInput, payload)
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "pane-token-under-test")
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
    }

    func test_real_cli_ipc_forwards_droid_pid_to_adapter() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"hook_event_name":"SessionStart","session_id":"session-droid"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event", "--adapter=droid"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_DROID_PID"] = "4242"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=droid"])
        XCTAssertEqual(request.standardInput, payload)
        XCTAssertEqual(request.environment["ZENTTY_DROID_PID"], "4242")
    }

    /// End-to-end coverage for the Grok fan-out: piping a TodoWrite PreToolUse
    /// payload to `zentty ipc agent-event --adapter=grok` must produce two
    /// captured IPC requests — the raw forward and the canonical task.progress
    /// re-emit. This is the load-bearing wiring that replaced the bash `jq`
    /// pipeline.
    func test_real_cli_grok_todowrite_payload_emits_raw_forward_plus_canonical_task_progress() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"hook_event_name":"PreToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"status":"completed"},{"status":"in_progress"},{"status":"pending"}]}}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event", "--adapter=grok"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let requests = try server.receiveRequests(count: 2)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(requests.count, 2)

        // First: raw forward via the grok adapter.
        XCTAssertEqual(requests[0].subcommand, "agent-event")
        XCTAssertEqual(requests[0].arguments, ["--adapter=grok"])
        XCTAssertEqual(requests[0].standardInput, payload)

        // Second: canonical task.progress envelope minted by GrokCanonicalReEmitter.
        XCTAssertEqual(requests[1].subcommand, "agent-event")
        XCTAssertEqual(requests[1].arguments, [])
        let canonical = try XCTUnwrap(requests[1].standardInput)
        XCTAssertTrue(canonical.contains("\"event\":\"task.progress\""), "expected task.progress event in canonical re-emit, got: \(canonical)")
        XCTAssertTrue(canonical.contains("\"done\":1"))
        XCTAssertTrue(canonical.contains("\"total\":3"))
    }

    /// End-to-end coverage for the nested-key session id resolution: a
    /// SessionStart payload that nests the id under `context.session_id` should
    /// still surface as a canonical `session.start` envelope carrying the id.
    func test_real_cli_grok_session_start_with_nested_id_emits_canonical_session_start() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"hook_event_name":"SessionStart","context":{"session_id":"ses_nested_id"}}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event", "--adapter=grok"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let requests = try server.receiveRequests(count: 2)
        process.waitUntilExit()

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].arguments, ["--adapter=grok"])
        let canonical = try XCTUnwrap(requests[1].standardInput)
        XCTAssertTrue(canonical.contains("\"event\":\"session.start\""))
        XCTAssertTrue(canonical.contains("\"id\":\"ses_nested_id\""))
    }

    func test_real_cli_codex_notify_reads_payload_from_standard_input_when_argument_is_omitted() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"type":"agent-turn-complete","session_id":"session-stdin"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["codex-notify"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .ipc)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=codex-notify"])
        XCTAssertEqual(request.standardInput, payload)
    }

    func test_real_cli_notify_forwards_body_to_pane_ipc() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let body = """
        mise ERROR No version is set for shim: codex
        Set a global default version with mise use -g node@22.22.1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "notify",
            "--title", "Codex failed to start",
            "--subtitle", "mise ERROR No version is set for shim: codex",
            "--body", body,
            "--silent",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        process.standardInput = Pipe()

        try process.run()
        let request = try server.receiveOneRequest { request in
            AgentIPCResponse(id: request.id, ok: true, result: AgentIPCResponseResult(), error: nil)
        }
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "notify")
        XCTAssertEqual(
            request.arguments,
            [
                "--title", "Codex failed to start",
                "--subtitle", "mise ERROR No version is set for shim: codex",
                "--body", body,
                "--silent",
            ]
        )
    }

    func test_real_cli_gemini_hook_forwards_payload_to_gemini_adapter_and_returns_empty_json() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"hook_event_name":"SessionStart","session_id":"session-gemini"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["gemini-hook", payload]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertEqual(request.kind, .ipc)
        XCTAssertEqual(request.subcommand, "agent-event")
        XCTAssertEqual(request.arguments, ["--adapter=gemini"])
        XCTAssertEqual(request.standardInput, payload)
    }

    func test_real_cli_gemini_hook_reads_payload_from_standard_input_when_argument_is_omitted() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let payload = #"{"hook_event_name":"SessionStart","session_id":"session-gemini-stdin"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["gemini-hook"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        process.standardError = Pipe()
        let stdout = Pipe()
        process.standardOutput = stdout
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        XCTAssertEqual(request.arguments, ["--adapter=gemini"])
        XCTAssertEqual(request.standardInput, payload)
    }

    func test_real_cli_gemini_hook_returns_empty_json_when_routing_environment_is_missing() throws {
        let payload = #"{"hook_event_name":"SessionStart","session_id":"session-gemini"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["gemini-hook", payload]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = ""
        environment["ZENTTY_PANE_TOKEN"] = ""
        environment["ZENTTY_WORKLANE_ID"] = ""
        environment["ZENTTY_PANE_ID"] = ""
        process.environment = environment
        process.standardError = Pipe()
        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        process.waitUntilExit()

        let stdoutString = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
    }

    func test_claude_wrapper_falls_back_to_real_binary_when_cli_is_missing() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["claude", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "claude",
            script: """
            #!/bin/bash
            set -euo pipefail
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
            done
            """
        )

        let result = try harness.run(tool: "claude", arguments: ["hello"])

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["hello"])
        XCTAssertTrue(try harness.readArgumentCalls(named: "cli-args.log").isEmpty)
    }

    func test_tool_wrappers_delegate_to_launch_command_when_cli_is_available() throws {
        for tool in ["amp", "claude", "codex", "copilot", "cursor-agent", "droid", "gemini", "grok", "kimi", "kimi-cli", "opencode", "pi"] {
            let harness = try WrapperHarness(copyingScriptsNamed: [tool, "zentty-agent-wrapper"])
            try harness.installRealBinary(
                named: tool,
                script: """
                #!/bin/bash
                set -euo pipefail
                printf 'unexpected\n' >> "$REAL_ARGS_LOG"
                """
            )
            try harness.installCliStub()

            let result = try harness.run(
                tool: tool,
                arguments: ["hello"],
                extraEnvironment: [
                    "ZENTTY_CLI_BIN": harness.cliPath,
                    "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                    "ZENTTY_PANE_TOKEN": harness.paneToken,
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "pane-main",
                ]
            )

            // cursor wrappers identify as the `cursor` tool regardless of which
            // alias (`cursor-agent` or `agent`) the user invoked.
            // kimi-cli wrapper identifies as `kimi`.
            let expectedLaunchTool: String
            switch tool {
            case "cursor-agent":
                expectedLaunchTool = "cursor"
            case "kimi-cli":
                expectedLaunchTool = "kimi"
            default:
                expectedLaunchTool = tool
            }
            XCTAssertEqual(result.exitCode, 0, "\(tool): \(result.stderr)\n\(result.stdout)")
            XCTAssertEqual(try harness.readArgumentCalls(named: "cli-args.log"), [["launch", expectedLaunchTool, "hello"]], tool)
            XCTAssertTrue(try harness.readLines(named: "real-args.log").isEmpty, tool)
        }
    }

    func test_tool_wrapper_exports_cli_path_when_resolved_from_path() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["codex", "zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "codex",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf 'unexpected\n' >> "$REAL_ARGS_LOG"
            """
        )
        try harness.installCliStub()

        let result = try harness.run(
            tool: "codex",
            arguments: ["hello"],
            extraEnvironment: [
                "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                "ZENTTY_PANE_TOKEN": harness.paneToken,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readArgumentCalls(named: "cli-args.log"), [["launch", "codex", "hello"]])
        XCTAssertEqual(try harness.readLines(named: "cli-env.log"), [harness.cliPath])
        XCTAssertTrue(try harness.readLines(named: "real-args.log").isEmpty)
    }

    func test_launch_command_reports_inactive_mise_shim_before_bootstrap() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let fakeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shimDirectory = fakeRoot
            .appendingPathComponent("mise", isDirectory: true)
            .appendingPathComponent("shims", isDirectory: true)
        let miseDirectory = fakeRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: miseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeRoot) }

        let codexShim = shimDirectory.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 99\n".write(to: codexShim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexShim.path)

        let mise = miseDirectory.appendingPathComponent("mise", isDirectory: false)
        try """
        #!/bin/sh
        echo 'mise ERROR No version is set for shim: codex' >&2
        echo 'Set a global default version with mise use -g node@22.22.1' >&2
        exit 1
        """.write(to: mise, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mise.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["launch", "codex"]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [shimDirectory.path, miseDirectory.path, "/usr/bin", "/bin"].joined(separator: ":")
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment.removeValue(forKey: "ZENTTY_CLI_BIN")
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stderrString = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(stderrString.contains("mise ERROR No version is set for shim: codex"), stderrString)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "notify")
        XCTAssertTrue(request.arguments.contains("Codex failed to start"), request.arguments.joined(separator: " "))
        XCTAssertTrue(request.arguments.contains("mise ERROR No version is set for shim: codex"), request.arguments.joined(separator: " "))
    }

    func test_launch_command_resolves_active_mise_shim_before_bootstrap() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let fakeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shimDirectory = fakeRoot
            .appendingPathComponent("mise", isDirectory: true)
            .appendingPathComponent("shims", isDirectory: true)
        let miseDirectory = fakeRoot.appendingPathComponent("bin", isDirectory: true)
        let realBinDirectory = fakeRoot.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: miseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBinDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeRoot) }

        let codexShim = shimDirectory.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 99\n".write(to: codexShim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexShim.path)

        let realCodex = realBinDirectory.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 42\n".write(to: realCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realCodex.path)

        let mise = miseDirectory.appendingPathComponent("mise", isDirectory: false)
        try """
        #!/bin/sh
        if [ "$1" = "which" ] && [ "$2" = "codex" ]; then
          printf '%s\\n' '\(realCodex.path)'
          exit 0
        fi
        exit 1
        """.write(to: mise, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mise.path)

        let process = Process()
        let cliPath = try builtCLIPath()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["launch", "codex", "hello"]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [shimDirectory.path, miseDirectory.path, "/usr/bin", "/bin"].joined(separator: ":")
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment.removeValue(forKey: "ZENTTY_CLI_BIN")
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest { request in
            AgentIPCResponse(
                id: request.id,
                ok: true,
                result: AgentIPCResponseResult(
                    launchPlan: AgentLaunchPlan(
                        executablePath: "/usr/bin/true",
                        arguments: [],
                        setEnvironment: [:],
                        unsetEnvironment: [],
                        preLaunchActions: []
                    )
                ),
                error: nil
            )
        }
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .bootstrap)
        XCTAssertEqual(request.tool, .codex)
        XCTAssertEqual(request.environment["ZENTTY_REAL_BINARY"], realCodex.path)
        XCTAssertEqual(
            request.environment["ZENTTY_CLI_BIN"],
            URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func test_launch_command_forwards_invoking_cli_path_when_environment_omits_cli_bin() throws {
        let server = try IPCRequestCaptureServer()
        defer { server.invalidate() }

        let realBinURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        let realCodexURL = realBinURL.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\nexit 42\n".write(to: realCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realCodexURL.path)
        defer { try? FileManager.default.removeItem(at: realBinURL) }

        let process = Process()
        let cliPath = try builtCLIPath()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["launch", "codex", "hello"]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [realBinURL.path, "/usr/bin", "/bin"].joined(separator: ":")
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_PANE_TOKEN"] = "pane-token-under-test"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment.removeValue(forKey: "ZENTTY_CLI_BIN")
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest { request in
            AgentIPCResponse(
                id: request.id,
                ok: true,
                result: AgentIPCResponseResult(
                    launchPlan: AgentLaunchPlan(
                        executablePath: "/usr/bin/true",
                        arguments: [],
                        setEnvironment: [:],
                        unsetEnvironment: [],
                        preLaunchActions: []
                    )
                ),
                error: nil
            )
        }
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .bootstrap)
        XCTAssertEqual(request.tool, .codex)
        XCTAssertEqual(request.environment["ZENTTY_REAL_BINARY"], realCodexURL.path)
        XCTAssertEqual(
            request.environment["ZENTTY_CLI_BIN"],
            URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func test_kimi_wrapper_passthroughs_login_to_real_binary_even_when_cli_is_available() throws {
        for tool in ["kimi", "kimi-cli"] {
            let harness = try WrapperHarness(copyingScriptsNamed: [tool, "zentty-agent-wrapper"])
            try harness.installRealBinary(
                named: "kimi",
                script: """
                #!/bin/bash
                set -euo pipefail
                for arg in "$@"; do
                  printf '%s\n' "$arg" >> "$REAL_ARGS_LOG"
                done
                """
            )
            try harness.installCliStub()

            let result = try harness.run(
                tool: tool,
                arguments: ["login"],
                extraEnvironment: [
                    "ZENTTY_CLI_BIN": harness.cliPath,
                    "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                    "ZENTTY_PANE_TOKEN": harness.paneToken,
                    "ZENTTY_WORKLANE_ID": "worklane-main",
                    "ZENTTY_PANE_ID": "pane-main",
                ]
            )

            XCTAssertEqual(result.exitCode, 0, "\(tool): \(result.stderr)\n\(result.stdout)")
            XCTAssertEqual(try harness.readLines(named: "real-args.log"), ["login"], tool)
            XCTAssertTrue(try harness.readArgumentCalls(named: "cli-args.log").isEmpty, tool)
        }
    }

    func test_generic_wrapper_delegates_selected_tool_to_launch_command() throws {
        let harness = try WrapperHarness(copyingScriptsNamed: ["zentty-agent-wrapper"])
        try harness.installRealBinary(
            named: "opencode",
            script: """
            #!/bin/bash
            set -euo pipefail
            printf 'unexpected\n' >> "$REAL_ARGS_LOG"
            """
        )
        try harness.installCliStub()

        let result = try harness.run(
            tool: "zentty-agent-wrapper",
            arguments: ["run", "hello"],
            extraEnvironment: [
                "ZENTTY_AGENT_TOOL": "opencode",
                "ZENTTY_CLI_BIN": harness.cliPath,
                "ZENTTY_INSTANCE_SOCKET": harness.socketPath,
                "ZENTTY_PANE_TOKEN": harness.paneToken,
                "ZENTTY_WORKLANE_ID": "worklane-main",
                "ZENTTY_PANE_ID": "pane-main",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "\(result.stderr)\n\(result.stdout)")
        XCTAssertEqual(try harness.readArgumentCalls(named: "cli-args.log"), [["launch", "opencode", "run", "hello"]])
        XCTAssertTrue(try harness.readLines(named: "real-args.log").isEmpty)
    }

    private func builtCLIPath() throws -> String {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cliURL = productsURL.appendingPathComponent("zentty", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw XCTSkip("Built zentty CLI not found at \(cliURL.path)")
        }
        return cliURL.path
    }
}

private final class IPCRequestCaptureServer {
    let socketPath: String
    private let rootURL: URL
    private var fileDescriptor: Int32

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        socketPath = rootURL.appendingPathComponent("zentty.sock", isDirectory: false).path

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = socketPath.utf8CString
        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fileDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in
                memcpy(pointer, buffer.baseAddress, buffer.count)
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fileDescriptor)
            throw error
        }

        guard listen(fileDescriptor, 8) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fileDescriptor)
            throw error
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(socketPath)
        try? FileManager.default.removeItem(at: rootURL)
    }

    func receiveOneRequest(
        timeout: TimeInterval = 5,
        respond: ((AgentIPCRequest) -> AgentIPCResponse)? = nil
    ) throws -> AgentIPCRequest {
        let expectation = XCTestExpectation(description: "receive IPC request")
        let lock = NSLock()
        var capturedRequest: AgentIPCRequest?
        var capturedError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            defer { expectation.fulfill() }
            let client = accept(self.fileDescriptor, nil, nil)
            guard client >= 0 else {
                lock.lock()
                capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                lock.unlock()
                return
            }
            defer { close(client) }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(client, &buffer, buffer.count, 0)
                if count > 0 {
                    data.append(buffer, count: count)
                    if data.contains(UInt8(ascii: "\n")) {
                        break
                    }
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                lock.lock()
                capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                lock.unlock()
                return
            }

            let requestData: Data
            if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                requestData = data.prefix(upTo: newlineIndex)
            } else {
                requestData = data
            }

            do {
                let request = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
                if let response = respond?(request) {
                    var responseData = try JSONEncoder().encode(response)
                    responseData.append(UInt8(ascii: "\n"))
                    _ = responseData.withUnsafeBytes { rawBuffer in
                        guard let baseAddress = rawBuffer.baseAddress else {
                            return
                        }
                        _ = Darwin.send(client, baseAddress, rawBuffer.count, 0)
                    }
                }
                lock.lock()
                capturedRequest = request
                lock.unlock()
            } catch {
                lock.lock()
                capturedError = error
                lock.unlock()
            }
        }

        let waiterResult = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if waiterResult != .completed {
            throw NSError(
                domain: "AgentWrapperTests.IPCRequestCaptureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for IPC request"]
            )
        }

        lock.lock()
        defer { lock.unlock() }
        if let capturedError {
            throw capturedError
        }
        return try XCTUnwrap(capturedRequest)
    }

    /// Accepts `count` sequential connections, reading one framed JSON request
    /// per connection, and returns the captured requests in arrival order.
    /// Used to verify the CLI's canonical-event fan-out, which sends a primary
    /// `--adapter=<name>` IPC request followed by zero or more canonical
    /// re-emits over fresh connections.
    func receiveRequests(
        count: Int,
        timeout: TimeInterval = 5
    ) throws -> [AgentIPCRequest] {
        precondition(count > 0)
        let expectation = XCTestExpectation(description: "receive \(count) IPC requests")
        let lock = NSLock()
        var captured: [AgentIPCRequest] = []
        var capturedError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            defer { expectation.fulfill() }
            for _ in 0..<count {
                let client = accept(self.fileDescriptor, nil, nil)
                guard client >= 0 else {
                    lock.lock()
                    capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    lock.unlock()
                    return
                }

                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var readOK = true
                while true {
                    let n = recv(client, &buffer, buffer.count, 0)
                    if n > 0 {
                        data.append(buffer, count: n)
                        if data.contains(UInt8(ascii: "\n")) { break }
                        continue
                    }
                    if n == 0 { break }
                    if errno == EINTR { continue }
                    lock.lock()
                    capturedError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    lock.unlock()
                    readOK = false
                    break
                }
                close(client)
                guard readOK else { return }

                let requestData: Data
                if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                    requestData = data.prefix(upTo: newlineIndex)
                } else {
                    requestData = data
                }

                do {
                    let request = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
                    lock.lock()
                    captured.append(request)
                    lock.unlock()
                } catch {
                    lock.lock()
                    capturedError = error
                    lock.unlock()
                    return
                }
            }
        }

        let waiterResult = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if waiterResult != .completed {
            throw NSError(
                domain: "AgentWrapperTests.IPCRequestCaptureServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(count) IPC requests"]
            )
        }
        lock.lock()
        defer { lock.unlock() }
        if let capturedError {
            throw capturedError
        }
        return captured
    }
}

private final class WrapperHarness {
    let rootURL: URL
    let wrapperBinURL: URL
    let realBinURL: URL
    let cliURL: URL
    let logDirectoryURL: URL

    init(copyingScriptsNamed scriptNames: [String]) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        wrapperBinURL = rootURL.appendingPathComponent("wrapper-bin", isDirectory: true)
        realBinURL = rootURL.appendingPathComponent("real-bin", isDirectory: true)
        logDirectoryURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        cliURL = rootURL
            .appendingPathComponent("cli-bin", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: false)

        try FileManager.default.createDirectory(at: wrapperBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBinURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cliURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for scriptName in scriptNames {
            let sourceURL = Self.repoRootURL
                .appendingPathComponent("ZenttyResources/bin", isDirectory: true)
                .appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
            let destinationURL = wrapperBinURL
                .appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    var cliPath: String {
        cliURL.path
    }

    var socketPath: String {
        rootURL.appendingPathComponent("zentty.sock", isDirectory: false).path
    }

    var paneToken: String {
        "pane-token-under-test"
    }

    func installRealBinary(named name: String, script: String) throws {
        let fileURL = realBinURL.appendingPathComponent(name, isDirectory: false)
        try script.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    }

    func installCliStub() throws {
        try """
        #!/bin/bash
        set -euo pipefail
        if [[ -n "${CLI_STDIN_LOG:-}" && "${1:-}" == "ipc" && "${2:-}" == "agent-event" ]]; then
          cat > "$CLI_STDIN_LOG"
        fi
        if [[ -n "${CLI_ARGS_LOG:-}" ]]; then
          {
            printf '%s\n' '--call--'
            for arg in "$@"; do
              printf '%s\n' "$arg"
            done
          } >> "$CLI_ARGS_LOG"
        fi
        if [[ -n "${CLI_ENV_LOG:-}" ]]; then
          printf '%s\n' "${ZENTTY_CLI_BIN:-}" >> "$CLI_ENV_LOG"
        fi
        """.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
    }

    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        stdin: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executableURL(for: tool).path] + arguments

        var environment = ProcessInfo.processInfo.environment
        let wrapperPaths = publicWrapperDirectories.map(\.path)
        environment["PATH"] = ([cliURL.deletingLastPathComponent().path] + wrapperPaths + [realBinURL.path, "/usr/bin", "/bin"]).joined(separator: ":")
        if let firstWrapperPath = wrapperPaths.first {
            environment["ZENTTY_WRAPPER_BIN_DIR"] = firstWrapperPath
        }
        if !wrapperPaths.isEmpty {
            environment["ZENTTY_WRAPPER_BIN_DIRS"] = wrapperPaths.joined(separator: ":")
        }
        environment["REAL_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("real-args.log", isDirectory: false).path
        environment["CLI_ARGS_LOG"] = logDirectoryURL.appendingPathComponent("cli-args.log", isDirectory: false).path
        environment["CLI_ENV_LOG"] = logDirectoryURL.appendingPathComponent("cli-env.log", isDirectory: false).path
        environment["CLI_STDIN_LOG"] = logDirectoryURL.appendingPathComponent("cli-stdin.log", isDirectory: false).path
        extraEnvironment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func readLines(named logName: String) throws -> [String] {
        let logURL = logDirectoryURL.appendingPathComponent(logName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }

        return try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func readArgumentCalls(named logName: String) throws -> [[String]] {
        var calls: [[String]] = []
        var current: [String] = []

        for line in try readLines(named: logName) {
            if line == "--call--" {
                if !current.isEmpty {
                    calls.append(current)
                    current = []
                }
                continue
            }
            current.append(line)
        }

        if !current.isEmpty {
            calls.append(current)
        }

        return calls
    }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var publicWrapperDirectories: [URL] {
        ["amp", "claude", "codex", "copilot", "cursor", "droid", "gemini", "grok", "kimi", "opencode", "pi"]
            .map { wrapperBinURL.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func executableURL(for scriptName: String) -> URL {
        wrapperBinURL.appendingPathComponent(Self.scriptRelativePath(for: scriptName), isDirectory: false)
    }

    private static func scriptRelativePath(for scriptName: String) -> String {
        switch scriptName {
        case "claude":
            return "claude/claude"
        case "codex":
            return "codex/codex"
        case "copilot":
            return "copilot/copilot"
        case "cursor-agent":
            return "cursor/cursor-agent"
        case "droid":
            return "droid/droid"
        case "gemini":
            return "gemini/gemini"
        case "kimi":
            return "kimi/kimi"
        case "kimi-cli":
            return "kimi/kimi-cli"
        case "opencode":
            return "opencode/opencode"
        case "pi":
            return "pi/pi"
        case "zentty-agent-wrapper":
            return "shared/zentty-agent-wrapper"
        default:
            return scriptName
        }
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
