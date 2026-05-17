import Darwin
import Foundation
import XCTest
@testable import Zentty

final class TmuxCompatCLITests: XCTestCase {
    func test_capture_server_rejects_overlong_socket_path() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmux-capture-server-" + String(repeating: "x", count: 96), isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertThrowsError(
            try TmuxCaptureServer(
                response: AgentIPCResponse(id: "overlong", ok: true, result: nil),
                tempDirectoryURL: rootURL
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENAMETOOLONG)
        }
    }

    func test_real_cli_grid_help_prints_grid_usage_and_flags() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["grid", "--help"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.contains("USAGE: zentty grid"))
        XCTAssertTrue(stdout.contains("--new-only"))
        XCTAssertTrue(stdout.contains("--include-source"))
        XCTAssertTrue(stdout.contains("--focus"))
        XCTAssertTrue(stdout.contains("--window-id <window-id|new>"))
        XCTAssertTrue(stdout.contains("--worklane-id <worklane-id|new>"))
        XCTAssertTrue(stdout.contains("ROWSxCOLUMNS"))
        XCTAssertEqual(stderr, "")
    }

    func test_real_cli_grid_forwards_dimensions_focus_and_passthrough_command_to_all_panes_by_default() throws {
        let server = try TmuxCaptureServer(
            response: AgentIPCResponse(id: "grid-1", ok: true, result: nil)
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "grid", "3x2",
            "--focus", "last",
            "--",
            "codex", "--model", "gpt-5.2",
        ]

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
        XCTAssertEqual(request.subcommand, "grid")
        XCTAssertTrue(request.expectsResponse)
        XCTAssertEqual(
            request.arguments,
            [
                "--rows", "3",
                "--columns", "2",
                "--focus", "last",
                "--command-json", "[\"codex\",\"--model\",\"gpt-5.2\"]",
            ]
        )
    }

    func test_real_cli_grid_forwards_new_destinations_and_new_only() throws {
        let server = try TmuxCaptureServer(
            response: AgentIPCResponse(id: "grid-2", ok: true, result: nil)
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "grid", "2x2",
            "--window-id", "new",
            "--worklane-id", "new",
            "--new-only",
            "--",
            "claude", "--dangerously-skip-permissions",
        ]

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
        XCTAssertEqual(request.subcommand, "grid")
        XCTAssertEqual(
            request.arguments,
            [
                "--rows", "2",
                "--columns", "2",
                "--new-only",
                "--focus", "source",
                "--new-window",
                "--new-worklane",
                "--command-json", "[\"claude\",\"--dangerously-skip-permissions\"]",
            ]
        )
    }

    func test_real_cli_tmux_compat_forwards_subcommand_and_args() throws {
        let server = try TmuxCaptureServer(
            response: AgentIPCResponse(
                id: "tmux-1",
                ok: true,
                result: AgentIPCResponseResult(stdout: "%new-pane-id\n")
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["__tmux-compat", "split-window", "-h", "-t", "%leader"]

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
        XCTAssertEqual(request.kind, .tmuxCompat)
        XCTAssertEqual(request.subcommand, "split-window")
        XCTAssertEqual(request.arguments, ["-h", "-t", "%leader"])
        XCTAssertTrue(request.expectsResponse)

        let stdout = stdoutPipe.fileHandleForReading.availableData
        XCTAssertEqual(String(data: stdout, encoding: .utf8), "%new-pane-id\n")
    }

    func test_real_cli_tmux_compat_strips_leading_socket_global() throws {
        // Claude Code 2.1.128 prefixes `-S <socket-from-$TMUX>` to every
        // tmux invocation. The CLI must skip it and still route the real
        // subcommand and its args through IPC.
        let server = try TmuxCaptureServer(
            response: AgentIPCResponse(
                id: "tmux-2",
                ok: true,
                result: AgentIPCResponseResult(stdout: "@window-1\n")
            )
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "__tmux-compat",
            "-S", "/tmp/zentty-claude-teams/wl_test",
            "display-message", "-t", "%pn_leader", "-p", "#{window_id}",
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
        XCTAssertEqual(request.subcommand, "display-message")
        XCTAssertEqual(request.arguments, ["-t", "%pn_leader", "-p", "#{window_id}"])
    }

    func test_real_cli_tmux_compat_preserves_subcommand_internal_dash_S() throws {
        // wait-for's own `-S` flag (signal mode) must survive the global
        // stripping pass.
        let server = try TmuxCaptureServer(
            response: AgentIPCResponse(id: "tmux-3", ok: true, result: nil)
        )
        defer { server.invalidate() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = [
            "__tmux-compat",
            "-S", "/tmp/zentty-claude-teams/wl_test",
            "wait-for", "-S", "agent-ready",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server.socketPath
        environment["ZENTTY_WINDOW_ID"] = "window-main"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-main"
        environment["ZENTTY_PANE_ID"] = "pane-main"
        environment["ZENTTY_PANE_TOKEN"] = "token-main"
        environment["ZENTTY_INSTANCE_ID"] = "test-instance"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        // wait-for runs locally and signals via a file; verify it exits 0.
        XCTAssertEqual(process.terminationStatus, 0)

        // Clean up the signal file the CLI just wrote.
        let signalURL = URL(fileURLWithPath: "/tmp/zentty-tmux-wait-for-test-instance-agent-ready.sig")
        try? FileManager.default.removeItem(at: signalURL)
    }

    func test_real_cli_tmux_compat_fails_when_socket_env_missing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtCLIPath())
        process.arguments = ["__tmux-compat", "list-panes"]

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
            stderr.contains("ZENTTY_INSTANCE_SOCKET unset"),
            "Expected helpful error message, got: \(stderr)"
        )
    }

    private func builtCLIPath() throws -> String {
        if let builtProductsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: builtProductsDir, isDirectory: true)
                .appendingPathComponent("zentty", isDirectory: false)
                .path
        }
        let fallback = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("zentty", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: fallback.path) else {
            throw XCTSkip("Built zentty CLI is unavailable.")
        }
        return fallback.path
    }
}

private final class TmuxCaptureServer {
    let socketPath: String

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.tests.tmux-compat-server")
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
                try Self.write(response: response, to: clientFD)
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
