import Darwin
import Foundation
import XCTest
@testable import Zentty

final class ZenttyCLIDiscoveryTests: XCTestCase {
    func test_capture_server_rejects_overlong_socket_path() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-capture-server-" + String(repeating: "x", count: 96), isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertThrowsError(
            try RequestCaptureServer(
                response: AgentIPCResponse(id: "overlong", ok: true, result: nil),
                tempDirectoryURL: rootURL
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENAMETOOLONG)
        }
    }

    func test_real_cli_pane_list_uses_discovery_and_defaults_to_current_worklane() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "discover-1",
                ok: true,
                result: AgentIPCResponseResult(discoveredPanes: [])
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["pane", "list", "--json"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .discover)
        XCTAssertEqual(request.subcommand, "panes")
        XCTAssertEqual(
            request.arguments,
            ["--window-id", "window-main", "--worklane-id", "worklane-main"]
        )
        XCTAssertEqual(stderrPipe.fileHandleForReading.availableData, Data())
        let output = try JSONSerialization.jsonObject(
            with: stdoutPipe.fileHandleForReading.availableData
        )
        XCTAssertEqual((output as? [Any])?.count, 0)
    }

    func test_real_cli_list_subcommands_honor_json_before_or_after_subcommand() throws {
        let cases: [(subcommand: String, arguments: [String], result: AgentIPCResponseResult)] = [
            ("windows", ["list", "--json", "windows"], AgentIPCResponseResult(discoveredWindows: [])),
            ("windows", ["list", "windows", "--json"], AgentIPCResponseResult(discoveredWindows: [])),
            ("worklanes", ["list", "--json", "worklanes"], AgentIPCResponseResult(discoveredWorklanes: [])),
            ("worklanes", ["list", "worklanes", "--json"], AgentIPCResponseResult(discoveredWorklanes: [])),
            ("panes", ["list", "--json", "panes"], AgentIPCResponseResult(discoveredPanes: [])),
            ("panes", ["list", "panes", "--json"], AgentIPCResponseResult(discoveredPanes: [])),
        ]

        for testCase in cases {
            try assertRealCLIListOutputsJSON(
                arguments: testCase.arguments,
                subcommand: testCase.subcommand,
                result: testCase.result
            )
        }
    }

    func test_real_cli_list_aliases_output_json() throws {
        let cases: [(subcommand: String, arguments: [String], result: AgentIPCResponseResult)] = [
            ("windows", ["window", "list", "--json"], AgentIPCResponseResult(discoveredWindows: [])),
            ("worklanes", ["worklane", "list", "--json"], AgentIPCResponseResult(discoveredWorklanes: [])),
        ]

        for testCase in cases {
            try assertRealCLIListOutputsJSON(
                arguments: testCase.arguments,
                subcommand: testCase.subcommand,
                result: testCase.result
            )
        }
    }

    func test_real_cli_split_forwards_explicit_targeting_arguments() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "pane-1",
                ok: true,
                result: AgentIPCResponseResult()
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "split",
            "right",
            "--window-id", "window-main",
            "--worklane-id", "worklane-main",
            "--pane-id", "pane-main",
            "--pane-token", "token-main",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "split")
        XCTAssertEqual(
            request.arguments,
            [
                "right",
                "--window-id", "window-main",
                "--worklane-id", "worklane-main",
                "--pane-id", "pane-main",
                "--pane-token", "token-main",
            ]
        )
    }

    func test_real_cli_notify_forwards_pane_local_notification_request() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "notify-1",
                ok: true,
                result: AgentIPCResponseResult()
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "notify",
            "--title", "Build done",
            "--subtitle", "Tests passed",
            "--no-inbox",
            "--silent",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_PANE_TOKEN"] = "token-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdoutPipe.fileHandleForReading.availableData, Data())
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "notify")
        XCTAssertEqual(
            request.arguments,
            [
                "--title", "Build done",
                "--subtitle", "Tests passed",
                "--no-inbox",
                "--silent",
            ]
        )
        XCTAssertEqual(request.environment["ZENTTY_WINDOW_ID"], "window-main")
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "token-main")
    }

    func test_real_cli_notify_fails_without_pane_token() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["notify", "--title", "Build done"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = "/tmp/zentty.sock"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment.removeValue(forKey: "ZENTTY_PANE_TOKEN")
        process.environment = environment
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.availableData,
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            stderr.contains("Not running inside a Zentty pane"),
            "Expected pane-local validation error, got: \(stderr)"
        )
    }

    func test_real_cli_theme_toggle_forwards_theme_request() throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(
                id: "theme-1",
                ok: true,
                result: AgentIPCResponseResult(stdout: "light\n")
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["theme", "toggle"]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_PANE_TOKEN"] = "token-main"
        process.environment = environment
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.availableData, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdout, "light\n")
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "theme")
        XCTAssertEqual(request.arguments, ["toggle"])
        XCTAssertTrue(request.expectsResponse)
    }

    func test_real_cli_theme_explicit_modes_forward_matching_theme_request() throws {
        for command in ["dark", "light", "auto"] {
            let server = try RequestCaptureServer(
                response: AgentIPCResponse(
                    id: "theme-\(command)",
                    ok: true,
                    result: AgentIPCResponseResult(stdout: "\(command)\n")
                )
            )
            defer { server.invalidate() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: try builtCLIPath())
            process.arguments = ["theme", command]

            var environment = ProcessInfo.processInfo.environment
            environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
            environment["ZENTTY_WINDOW_ID"] = "window-main"
            environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
            environment["ZENTTY_PANE_ID"] = "pane-main"
            environment["ZENTTY_PANE_TOKEN"] = "token-main"
            process.environment = environment
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            try process.run()
            let request = try server.receiveOneRequest()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(request.kind, .pane)
            XCTAssertEqual(request.subcommand, "theme")
            XCTAssertEqual(request.arguments, [command])
            XCTAssertTrue(request.expectsResponse)
        }
    }

    func test_real_cli_theme_fails_outside_zentty_instance() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["theme", "toggle"]

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ZENTTY_INSTANCE_SOCKET")
        process.environment = environment
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.availableData,
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            stderr.contains("Not running inside a Zentty instance"),
            "Expected theme command to require a Zentty instance, got: \(stderr)"
        )
    }

    func test_real_cli_agent_hooks_forward_status_without_title_context_unless_explicitly_enabled() throws {
        let disabledValues: [String?] = [nil, "", "0", "false", "true", "invalid", "01", "1 "]
        for adapter in ["claude", "codex"] {
            for event in ["SessionStart", "UserPromptSubmit"] {
                for value in disabledValues {
                    let stdout = try runAgentHook(
                        arguments: ["--adapter=\(adapter)"],
                        payload: #"{"hook_event_name":"\#(event)"}"#,
                        autoPaneTitles: value
                    )
                    XCTAssertEqual(stdout, "", "\(adapter) \(event) must stay silent for \(value ?? "<unset>")")
                }
            }
        }
    }

    func test_real_cli_agent_hooks_opt_in_to_pane_title_context_for_every_prompt_and_session_source() throws {
        for adapter in ["claude", "codex"] {
            let payloads: [[String: Any]] = ["startup", "resume", "clear", "compact"].map {
                ["hook_event_name": "SessionStart", "source": $0]
            } + [
                ["hook_event_name": "UserPromptSubmit", "prompt": "Fix invoice totals"],
                ["hook_event_name": "UserPromptSubmit", "prompt": "Now inspect the login form"],
            ]
            for payload in payloads {
                let payloadData = try JSONSerialization.data(withJSONObject: payload)
                let stdout = try runAgentHook(
                    arguments: ["--adapter=\(adapter)"],
                    payload: String(decoding: payloadData, as: UTF8.self),
                    autoPaneTitles: "1"
                )
                let output = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
                )
                XCTAssertEqual(Set(output.keys), ["hookSpecificOutput"])
                let specific = try XCTUnwrap(output["hookSpecificOutput"] as? [String: String])
                XCTAssertEqual(Set(specific.keys), ["hookEventName", "additionalContext"])
                XCTAssertEqual(specific["hookEventName"], payload["hook_event_name"] as? String)
                let context = try XCTUnwrap(specific["additionalContext"])
                XCTAssertTrue(context.contains("Project — current task"))
                XCTAssertTrue(context.contains("project name as the prefix"))
                XCTAssertTrue(context.contains("working-folder name"))
                XCTAssertTrue(context.contains("at the start of this run"))
                XCTAssertTrue(context.contains("meaningfully changes during the run"))
                XCTAssertTrue(context.contains("including a manually renamed title"))
                XCTAssertTrue(context.contains(#""$ZENTTY_CLI_BIN" pane rename -- '"#))
                XCTAssertTrue(context.contains("safely shell-quoted literal title"))
                XCTAssertTrue(context.contains("delegated subagents must not rename"))
                XCTAssertTrue(context.contains("|| true"))
            }
        }
    }

    func test_real_cli_agent_hooks_do_not_emit_title_context_for_tools_stop_or_subagents() throws {
        let silentEvents = [
            "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
            "PreCompact", "PostCompact", "Stop", "SessionEnd", "Notification",
            "SubagentStart", "SubagentStop",
        ]
        for adapter in ["claude", "codex"] {
            for event in silentEvents {
                let stdout = try runAgentHook(
                    arguments: ["--adapter=\(adapter)", "session-start"],
                    payload: #"{"hook_event_name":"\#(event)"}"#
                )
                XCTAssertEqual(stdout, "", "\(adapter) \(event) must remain silent")
            }
            for event in ["SessionStart", "UserPromptSubmit"] {
                for agentKey in ["agent_id", "agentId"] {
                    let stdout = try runAgentHook(
                        arguments: ["--adapter=\(adapter)"],
                        payload: #"{"hook_event_name":"\#(event)","\#(agentKey)":"child-1"}"#
                    )
                    XCTAssertEqual(stdout, "", "A subagent must not receive its parent's title reminder")
                }
            }
        }
    }

    func test_real_cli_agent_hook_title_context_does_not_copy_untrusted_payload_text() throws {
        let marker = "untrusted-'\"-$(echo injected)-`echo injected`\n"
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "prompt": marker,
            "cwd": "/projects/" + marker,
        ])
        let stdout = try runAgentHook(
            arguments: ["--adapter=codex", "prompt-submit"],
            payload: String(decoding: payload, as: UTF8.self)
        )
        XCTAssertFalse(stdout.contains("untrusted"))
        XCTAssertFalse(stdout.contains("echo injected"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(stdout.utf8)))

        for malformed in ["{", "[]", #"{"source":"startup"}"#] {
            XCTAssertEqual(try runAgentHook(arguments: ["--adapter=claude"], payload: malformed), "")
        }
        XCTAssertEqual(
            try runAgentHook(arguments: ["--adapter=unknown"], payload: #"{"hook_event_name":"SessionStart"}"#),
            ""
        )
    }

    func test_real_cli_agent_hook_title_context_survives_unavailable_app_socket() throws {
        let stdout = try runAgentHook(
            arguments: ["--adapter=claude"],
            payload: #"{"hook_event_name":"SessionStart","source":"resume"}"#,
            socketAvailable: false
        )
        let output = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(output?["hookSpecificOutput"])
    }

    func test_real_cli_pane_rename_accepts_literal_title_and_defaults_to_own_pane() throws {
        let server = try RequestCaptureServer(response: AgentIPCResponse(id: "rename", ok: true, result: nil))
        defer { server.invalidate() }
        let title = "demo — Fix 'quotes', \"totals\" & $values"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["pane", "rename", "--", title]
        process.environment = [
            "ZENTTY_INSTANCE_SOCKET": server.socketPath,
            "ZENTTY_WORKLANE_ID": "worklane-main",
            "ZENTTY_PANE_ID": "pane-main",
            "ZENTTY_PANE_TOKEN": "token-main",
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "pane-rename")
        XCTAssertEqual(request.arguments, ["--title", title])
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "token-main")
        XCTAssertEqual(stderrPipe.fileHandleForReading.readDataToEndOfFile(), Data())
    }

    private func runAgentHook(
        arguments: [String],
        payload: String,
        socketAvailable: Bool = true,
        autoPaneTitles: String? = "1"
    ) throws -> String {
        let server = socketAvailable
            ? try RequestCaptureServer(response: AgentIPCResponse(id: "hook", ok: true, result: nil))
            : nil
        defer { server?.invalidate() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["ipc", "agent-event"] + arguments
        process.environment = [
            "ZENTTY_INSTANCE_SOCKET": server?.socketPath ?? "/tmp/zentty-absent-\(UUID().uuidString).sock",
            "ZENTTY_WORKLANE_ID": "worklane-main",
            "ZENTTY_PANE_ID": "pane-main",
            "ZENTTY_PANE_TOKEN": "token-main",
        ]
        process.environment?["ZENTTY_AUTO_PANE_TITLES"] = autoPaneTitles
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try stdinPipe.fileHandleForWriting.close()

        if let server {
            let request = try server.receiveOneRequest()
            XCTAssertEqual(request.kind, .ipc)
            XCTAssertEqual(request.subcommand, "agent-event")
            XCTAssertEqual(request.arguments, arguments)
            XCTAssertEqual(request.standardInput, payload)
            XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
            XCTAssertFalse(request.expectsResponse)
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stderrPipe.fileHandleForReading.readDataToEndOfFile(), Data())
        return String(decoding: stdout, as: UTF8.self)
    }

    private func builtCLIPath() throws -> String {
        if let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: builtProductsDir, isDirectory: true)
                .appendingPathComponent("zentty", isDirectory: false)
                .path
        }
        let testBundleProductsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let testBundleCLIURL = testBundleProductsURL.appendingPathComponent("zentty", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: testBundleCLIURL.path) {
            return testBundleCLIURL.path
        }
        throw XCTSkip("BUILT_PRODUCTS_DIR is unavailable.")
    }

    private func assertRealCLIListOutputsJSON(
        arguments: [String],
        subcommand: String,
        result: AgentIPCResponseResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let server = try RequestCaptureServer(
            response: AgentIPCResponse(id: "list-\(subcommand)", ok: true, result: result)
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let request = try server.receiveOneRequest()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.availableData
        let stderrData = stderrPipe.fileHandleForReading.availableData
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail(
                "CLI exited with status \(process.terminationStatus): \(stderr)",
                file: file,
                line: line
            )
            return
        }
        XCTAssertEqual(request.kind, .discover, file: file, line: line)
        XCTAssertEqual(request.subcommand, subcommand, file: file, line: line)
        XCTAssertEqual(stderrData, Data(), "Unexpected stderr: \(stderr)", file: file, line: line)
        let output = try JSONSerialization.jsonObject(with: stdoutData)
        XCTAssertEqual((output as? [Any])?.count, 0, file: file, line: line)
    }
}

private final class RequestCaptureServer {
    let socketPath: String

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.tests.discovery-server")
    private let semaphore = DispatchSemaphore(value: 0)
    private let tempDirectoryURL: URL
    private var capturedRequest: AgentIPCRequest?
    private var response: AgentIPCResponse

    init(response: AgentIPCResponse, tempDirectoryURL providedTempDirectoryURL: URL? = nil) throws {
        self.response = response
        tempDirectoryURL = providedTempDirectoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        socketPath = tempDirectoryURL.appendingPathComponent("zentty.sock", isDirectory: false).path

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8Path = socketPath.utf8CString
        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(listenFD)
            try? FileManager.default.removeItem(at: tempDirectoryURL)
            throw POSIXError(.ENAMETOOLONG)
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { buffer in
                memcpy(pointer, buffer.baseAddress, buffer.count)
            }
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(listenFD, SOMAXCONN) == 0 else {
            close(listenFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        queue.async { [self] in
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            do {
                let requestData = try Self.readLine(from: clientFD)
                capturedRequest = try JSONDecoder().decode(AgentIPCRequest.self, from: requestData)
                if capturedRequest?.expectsResponse == true {
                    try Self.write(response: response, to: clientFD)
                }
            } catch {
            }

            semaphore.signal()
        }
    }

    func invalidate() {
        close(listenFD)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    func receiveOneRequest(timeout: TimeInterval = 5) throws -> AgentIPCRequest {
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        XCTAssertEqual(waitResult, .success)
        return try XCTUnwrap(capturedRequest)
    }

    private static func readLine(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
                return Data(data.prefix(upTo: newlineIndex))
            }
        }
    }

    private static func write(response: AgentIPCResponse, to fileDescriptor: Int32) throws {
        var payload = try JSONEncoder().encode(response)
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            _ = send(fileDescriptor, baseAddress, rawBuffer.count, 0)
        }
    }
}
