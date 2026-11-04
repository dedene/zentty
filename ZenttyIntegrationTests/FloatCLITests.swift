import Foundation
import XCTest
@testable import Zentty

/// `zentty pane float|dock|pip|minimize|restore` and `zentty float
/// new|list|hide|show`, run as the real CLI binary against a capture server.
final class FloatCLITests: XCTestCase {

    // MARK: - pane <action>

    func test_pane_actions_send_their_subcommand_with_target_and_selectors() throws {
        for action in PaneFloatAction.allCases {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(id: action.rawValue, ok: true))
            defer { server.invalidate() }

            let result = try runCLI(["pane", action.rawValue, "2", "--worklane-id", "wl_target"], server: server)

            XCTAssertEqual(result.status, 0, result.stderr)
            let request = try XCTUnwrap(result.request)
            XCTAssertEqual(request.kind, .pane)
            XCTAssertEqual(request.subcommand, "pane-\(action.rawValue)")
            XCTAssertEqual(request.arguments, ["--target", "2", "--worklane-id", "wl_target"])
            XCTAssertEqual(result.stdout, "")
        }
    }

    func test_pane_action_defaults_to_the_calling_pane() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "minimize", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(["pane", "minimize"], server: server)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.arguments, [])
        XCTAssertEqual(result.request?.environment["ZENTTY_PANE_ID"], "pane-caller")
    }

    func test_pane_pip_forwards_a_valid_corner_and_rejects_others_locally() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "pip", ok: true))
        defer { server.invalidate() }
        let result = try runCLI(["pane", "pip", "pn_abc", "--corner", "top-left"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.arguments, ["--target", "pn_abc", "--corner", "top-left"])

        let rejected = try runCLI(["pane", "pip", "--corner", "middle"])
        XCTAssertEqual(rejected.status, 64)
        XCTAssertTrue(rejected.stderr.contains("Invalid corner 'middle'"), rejected.stderr)
    }

    func test_positional_target_conflicts_with_pane_selectors() throws {
        let result = try runCLI(["pane", "float", "2", "--pane-id", "pn_abc"])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("Do not combine a positional pane target"), result.stderr)
    }

    func test_server_errors_exit_nonzero_with_the_message() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(
            id: "restore", ok: false,
            error: AgentIPCResponseError(code: "float", message: "Pane pn_a is a tile, not a floating pane.")
        ))
        defer { server.invalidate() }

        let result = try runCLI(["pane", "restore", "1"], server: server)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("is a tile, not a floating pane"), result.stderr)
    }

    // MARK: - float new

    func test_float_new_sends_cwd_temporary_and_command_tokens_and_prints_the_id() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(
            id: "new", ok: true, result: AgentIPCResponseResult(stdout: "pn_new\n")
        ))
        defer { server.invalidate() }
        let command = ["git", "log", "two words", "--", "--oneline"]

        let result = try runCLI(
            ["float", "new", "--cwd", "/tmp/two words", "--temporary", "--pane-index", "2", "--"] + command,
            server: server
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "pn_new\n")
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.subcommand, FloatControlIPC.newSubcommand)
        let options = try FloatNewIPCOptions.parse(arguments: Array(request.arguments.dropLast(2)))
        XCTAssertEqual(options, FloatNewIPCOptions(workingDirectory: "/tmp/two words", temporary: true, command: command))
        XCTAssertEqual(Array(request.arguments.suffix(2)), ["--pane-index", "2"])
    }

    func test_float_new_without_options_sends_nothing_extra() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "new", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(["float", "new"], server: server)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.arguments, [])
    }

    func test_float_new_resolves_a_relative_cwd_against_the_caller_directory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalRoot = try XCTUnwrap(realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "new", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(["float", "new", "--cwd", "sub"], server: server, currentDirectory: root)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.arguments, ["--cwd", physicalRoot + "/sub"])
    }

    // MARK: - float list

    func test_float_list_prints_a_table_or_json() throws {
        let entries = [
            FloatListEntry(
                id: "pn_1", index: 2, worklaneID: "wl", windowID: "win", title: "logs", workingDirectory: "/tmp",
                mode: "floating", frame: .init(x: 0.2, y: 0.1, width: 0.6, height: 0.5), corner: nil,
                status: "running", agentTool: nil, isFocused: true, isHidden: false, isTemporary: false
            ),
            FloatListEntry(
                id: "pn_2", index: 3, worklaneID: "wl", windowID: "win", title: "claude", workingDirectory: nil,
                mode: "pip", frame: nil, corner: "bottom-right",
                status: "needs-input", agentTool: "Claude Code", isFocused: false, isHidden: true, isTemporary: false
            ),
            FloatListEntry(
                id: "pn_3", index: 4, worklaneID: "wl", windowID: "win", title: "build", workingDirectory: nil,
                mode: "minimized", frame: nil, corner: nil,
                status: "done", agentTool: nil, isFocused: false, isHidden: false, isTemporary: true
            ),
        ]
        for json in [false, true] {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(
                id: "list", ok: true, result: AgentIPCResponseResult(floatList: entries)
            ))
            defer { server.invalidate() }

            let result = try runCLI(["float", "list"] + (json ? ["--json"] : []), server: server)

            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.request?.subcommand, FloatControlIPC.listSubcommand)
            XCTAssertEqual(result.request?.arguments, [])
            if json {
                XCTAssertEqual(try JSONDecoder().decode([FloatListEntry].self, from: Data(result.stdout.utf8)), entries)
                XCTAssertTrue(result.stdout.contains("\"corner\" : \"bottom-right\""), "pretty, sorted keys")
            } else {
                let lines = result.stdout.split(separator: "\n").map(String.init)
                XCTAssertEqual(lines.count, 4)
                XCTAssertTrue(lines[0].hasPrefix("IDX  MODE"), lines[0])
                XCTAssertTrue(lines[1].contains("60%x50% at 20%,10%"), lines[1])
                XCTAssertTrue(lines[1].contains("*"), lines[1])
                XCTAssertTrue(lines[1].hasSuffix("Running"), lines[1])
                XCTAssertTrue(lines[2].contains("pip (hidden)"), lines[2])
                XCTAssertTrue(lines[2].contains("bottom-right"), lines[2])
                XCTAssertTrue(lines[2].hasSuffix("Needs input"), lines[2])
                XCTAssertTrue(lines[3].contains("minimized"), lines[3])
                XCTAssertTrue(lines[3].hasSuffix("Done"), lines[3])
            }
        }
    }

    func test_float_list_with_no_floats_says_so() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(
            id: "list", ok: true, result: AgentIPCResponseResult(floatList: [])
        ))
        defer { server.invalidate() }

        let result = try runCLI(["float", "list"], server: server)

        XCTAssertEqual(result.stdout, "No floating panes.\n")
    }

    func test_float_list_against_an_older_app_fails_clearly() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "list", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(["float", "list"], server: server)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("does not support 'float list'"), result.stderr)
    }

    // MARK: - float hide / show

    func test_float_hide_and_show_forward_selectors() throws {
        for (verb, subcommand) in [("hide", FloatControlIPC.hideSubcommand), ("show", FloatControlIPC.showSubcommand)] {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(id: verb, ok: true))
            defer { server.invalidate() }

            let result = try runCLI(["float", verb, "--worklane-id", "wl_target"], server: server)

            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.request?.subcommand, subcommand)
            XCTAssertEqual(result.request?.arguments, ["--worklane-id", "wl_target"])
        }
    }

    func test_help_lists_the_float_commands_without_an_instance() throws {
        let float = try runCLI(["float", "--help"])
        XCTAssertEqual(float.status, 0)
        for subcommand in ["new", "list", "hide", "show"] {
            XCTAssertTrue(float.stdout.contains(subcommand), subcommand)
        }
        let pane = try runCLI(["pane", "--help"])
        XCTAssertEqual(pane.status, 0)
        for subcommand in ["float", "dock", "pip", "minimize", "restore"] {
            XCTAssertTrue(pane.stdout.contains(subcommand), subcommand)
        }
    }

    // MARK: - Helpers

    private struct Result {
        let request: AgentIPCRequest?
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runCLI(
        _ arguments: [String],
        server: TmuxCaptureServer? = nil,
        currentDirectory: URL? = nil
    ) throws -> Result {
        let productsURL = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cliURL = productsURL.appendingPathComponent("zentty")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cliURL.path), "CLI missing at \(cliURL.path)")
        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
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
        let completed = XCTestExpectation(description: "float CLI exited")
        process.terminationHandler = { _ in completed.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request = try server?.receiveOneRequest()
        guard XCTWaiter().wait(for: [completed], timeout: 5) == .completed else {
            XCTFail("float CLI timed out: \(arguments)")
            throw POSIXError(.ETIMEDOUT)
        }
        return Result(
            request: request, status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
