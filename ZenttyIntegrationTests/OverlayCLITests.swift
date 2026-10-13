import Foundation
import XCTest
@testable import Zentty

final class OverlayCLITests: XCTestCase {
    func test_web_open_explicitly_requests_a_pane() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "web", ok: true,
            result: AgentIPCResponseResult(stdout: "web-pane\n")))
        defer { server.invalidate() }
        let result = try runCLI(["web", "open", "https://example.com/report"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.subcommand, "web-open")
        XCTAssertEqual(request.arguments, ["--url", "https://example.com/report", "--size-percent", "100", "--placement", "pane"])
        XCTAssertEqual(result.stdout, "web-pane\n")
    }

    func test_web_explicit_overlay_preserves_target_selectors() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "web", ok: true))
        defer { server.invalidate() }
        let result = try runCLI(["web", "overlay", "--pane-id", "target", "http://localhost:3000"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        let args = try XCTUnwrap(result.request).arguments
        XCTAssertTrue(args.contains("overlay"))
        XCTAssertEqual(Array(args.suffix(2)), ["--pane-id", "target"])
    }

    func test_web_security_options_cannot_override_app_settings() throws {
        for flag in ["--js", "--persistent", "--browse"] {
            let result = try runCLI(["web", "open", flag, "https://example.com"])
            XCTAssertEqual(result.status, 64)
            XCTAssertTrue(result.stderr.contains(flag), result.stderr)
        }
    }

    func test_open_preserves_passthrough_tokens_and_prints_response_verbatim() throws {
        let command = ["tool", "two words", "single'quote", "double\"quote", "--", "--help", "--pane-id", "literal", ""]
        let server = try TmuxCaptureServer(response: AgentIPCResponse(
            id: "open", ok: true, result: AgentIPCResponseResult(stdout: "{\"id\":\"overlay-1\"}")
        ))
        defer { server.invalidate() }

        let result = try runCLI(["overlay", "open", "--"] + command, server: server)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "overlay-open")
        XCTAssertTrue(request.expectsResponse)
        XCTAssertEqual(request.arguments.count, 2)
        XCTAssertEqual(request.arguments.first, "--command-json")
        let json = try XCTUnwrap(request.arguments.last).data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: json), command)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "{\"id\":\"overlay-1\"}")
        XCTAssertEqual(result.stderr, "")
    }

    func test_open_forwards_flags_and_all_target_selectors() throws {
        let options = [
            "--wait", "--follow", "--notify", "--cwd", "/tmp/two words",
            "--placement", "pane", "--size-percent", "70",
            "--window-id", "window-target", "--worklane-id", "worklane-target",
            "--pane-id", "pane-target", "--pane-index", "2", "--pane-token", "token-target",
        ]
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "open", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(["overlay", "open"] + options + ["--", "git", "diff"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(Array(request.arguments.dropLast(2)), options)
        XCTAssertEqual(request.arguments.suffix(2).first, "--command-json")
        XCTAssertEqual(try JSONDecoder().decode(
            [String].self, from: Data(try XCTUnwrap(request.arguments.last).utf8)
        ), ["git", "diff"])
    }

    func test_list_show_and_close_forward_selectors_and_handle_response_output() throws {
        let selectors = [
            "--window-id", "window-target", "--worklane-id", "worklane-target",
            "--pane-id", "pane-target", "--pane-index", "2", "--pane-token", "token-target",
        ]
        for subcommand in ["list", "show", "close"] {
            let output = "[{\"id\":\"overlay-1\"}]\n"
            let server = try TmuxCaptureServer(response: AgentIPCResponse(
                id: subcommand, ok: true, result: AgentIPCResponseResult(stdout: output)
            ))
            defer { server.invalidate() }
            let result = try runCLI(["overlay", subcommand] + selectors, server: server)
            let request = try XCTUnwrap(result.request)
            XCTAssertEqual(request.kind, .pane)
            XCTAssertEqual(request.subcommand, "overlay-" + subcommand)
            XCTAssertEqual(request.arguments, selectors)
            XCTAssertTrue(request.expectsResponse)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stdout, subcommand == "list" ? output : "")
            XCTAssertEqual(result.stderr, "")
        }
    }

    func test_default_target_uses_calling_pane_environment() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "list", ok: true))
        defer { server.invalidate() }
        let result = try runCLI(["overlay", "list"], server: server)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.arguments, [])
        XCTAssertEqual(request.environment["ZENTTY_WINDOW_ID"], "window-caller")
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-caller")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-caller")
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "token-caller")
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func test_open_help_succeeds_without_an_instance() throws {
        let result = try runCLI(["overlay", "open", "--help"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("USAGE: zentty overlay open"))
        XCTAssertTrue(result.stdout.contains("--placement"))
        XCTAssertEqual(result.stderr, "")
    }

    func test_open_missing_separator_or_command_exits_with_validation_error() throws {
        for (arguments, message) in [
            (["overlay", "open", "git", "diff"], "Use '--' before the command"),
            (["overlay", "open", "--"], "Missing overlay command"),
        ] {
            let result = try runCLI(arguments)
            XCTAssertEqual(result.status, 64)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.contains(message), result.stderr)
        }
    }

    func test_server_errors_produce_nonzero_exit_and_stderr_for_all_subcommands() throws {
        for subcommand in ["open", "list", "show", "close"] {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(
                id: subcommand, ok: false,
                error: AgentIPCResponseError(code: "overlay-test-error", message: "Overlay request rejected")
            ))
            defer { server.invalidate() }
            let arguments = ["overlay", subcommand] + (subcommand == "open" ? ["--", "git", "diff"] : [])
            let result = try runCLI(arguments, server: server)
            XCTAssertEqual(result.request?.subcommand, "overlay-" + subcommand)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.contains("Overlay request rejected"), result.stderr)
        }
    }

    func test_commands_outside_an_instance_exit_with_an_actionable_error() throws {
        for subcommand in ["open", "list", "show", "close"] {
            let arguments = ["overlay", subcommand] + (subcommand == "open" ? ["--", "git", "diff"] : [])
            let result = try runCLI(arguments)
            XCTAssertEqual(result.status, 64)
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.contains("Not running inside a Zentty instance"), result.stderr)
        }
    }

    private struct Result {
        let request: AgentIPCRequest?
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runCLI(_ arguments: [String], server: TmuxCaptureServer? = nil) throws -> Result {
        let productsURL = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cliURL = productsURL.appendingPathComponent("zentty")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliURL.path), "CLI missing at \(cliURL.path)")
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ZENTTY_INSTANCE_SOCKET"] = server?.socketPath ?? ""
        environment["ZENTTY_WINDOW_ID"] = "window-caller"
        environment["ZENTTY_WORKLANE_ID"] = "worklane-caller"
        environment["ZENTTY_PANE_ID"] = "pane-caller"
        environment["ZENTTY_PANE_TOKEN"] = "token-caller"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = XCTestExpectation(description: "overlay CLI exited")
        process.terminationHandler = { _ in completed.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request = try server?.receiveOneRequest()
        guard XCTWaiter().wait(for: [completed], timeout: 5) == .completed else {
            XCTFail("overlay CLI timed out: \(arguments)")
            throw POSIXError(.ETIMEDOUT)
        }
        return Result(
            request: request, status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
