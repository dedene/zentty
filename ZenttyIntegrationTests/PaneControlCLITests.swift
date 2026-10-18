import Foundation
import XCTest
@testable import Zentty

/// What `zentty pane send|send-key|read` and `zentty events` put on the
/// wire, and what they refuse before connecting.
final class PaneControlCLITests: XCTestCase {
    // MARK: - pane send

    func test_send_without_a_named_destination_fails_before_connecting() throws {
        let result = try runCLI(["pane", "send", "--", "npm", "test"])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("Name the destination pane"), result.stderr)
    }

    func test_send_joins_text_and_forwards_target_flags_and_selectors() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "send", ok: true))
        defer { server.invalidate() }

        let result = try runCLI(
            ["pane", "send", "2", "--no-enter", "--paste", "--force", "--worklane-id", "wl_x", "--", "a", "b"],
            server: server
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.kind, .pane)
        XCTAssertEqual(request.subcommand, "send")
        XCTAssertEqual(request.standardInput, "a b")
        XCTAssertEqual(
            request.arguments,
            ["--target", "2", "--no-enter", "--paste", "--force", "--worklane-id", "wl_x"]
        )
    }

    func test_send_reads_piped_stdin_and_drops_one_trailing_newline() throws {
        for (input, expected) in [("npm test\n", "npm test"), ("one\ntwo\r\n", "one\ntwo"), ("keep\n\n", "keep\n")] {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "send", ok: true))
            defer { server.invalidate() }
            let result = try runCLI(["pane", "send", "3"], server: server, standardInput: Data(input.utf8))
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.request?.standardInput, expected, input.debugDescription)
            XCTAssertEqual(result.request?.arguments, ["--target", "3"])
        }
    }

    func test_empty_text_is_an_error_not_a_bare_enter() throws {
        // An empty variable after '--', or nothing at all with stdin on
        // /dev/null: neither may turn into a lone Enter.
        for arguments in [["pane", "send", "2", "--"], ["pane", "send", "2"]] {
            let result = try runCLI(arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("Nothing to send"), result.stderr)
        }
        let emptyPipe = try runCLI(["pane", "send", "2"], standardInput: Data())
        XCTAssertEqual(emptyPipe.status, 64)
        XCTAssertTrue(emptyPipe.stderr.contains("Nothing to send"), emptyPipe.stderr)
    }

    func test_text_too_large_once_encoded_fails_before_connecting() throws {
        let escapeHeavy = String(repeating: "\u{1b}", count: 60 * 1024)
        let result = try runCLI(["pane", "send", "2"], standardInput: Data(escapeHeavy.utf8))
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("too large"), result.stderr)
    }

    // MARK: - pane send-key

    func test_send_key_splits_leading_pane_reference_from_keys() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "send-key", ok: true))
        defer { server.invalidate() }
        let result = try runCLI(["pane", "send-key", "2", "C-c", "Up", "--force"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.subcommand, "send-key")
        XCTAssertEqual(request.arguments, ["--target", "2", "--key", "C-c", "--key", "Up", "--force"])
    }

    func test_send_key_with_pane_id_treats_every_positional_as_a_key() throws {
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "send-key", ok: true))
        defer { server.invalidate() }
        let result = try runCLI(["pane", "send-key", "--pane-id", "pn_x", "2", "Enter"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.arguments, ["--key", "2", "--key", "Enter", "--pane-id", "pn_x"])
    }

    func test_send_key_rejects_unknown_keys_and_missing_destination() throws {
        let unknown = try runCLI(["pane", "send-key", "2", "Entr"])
        XCTAssertEqual(unknown.status, 64)
        XCTAssertTrue(unknown.stderr.contains("Unknown key name 'Entr'"), unknown.stderr)

        let unnamed = try runCLI(["pane", "send-key", "Enter"])
        XCTAssertEqual(unnamed.status, 64)
        XCTAssertTrue(unnamed.stderr.contains("Name the destination pane"), unnamed.stderr)
    }

    // MARK: - pane read

    func test_read_prints_text_or_json() throws {
        let read = PaneReadResult(
            paneID: "pn_a", worklaneID: "wl_a", windowID: "wd_a", columns: 80, rows: 24,
            includesScrollback: true, lineLimit: 5, text: "$ ls"
        )
        for json in [false, true] {
            let server = try TmuxCaptureServer(response: AgentIPCResponse(
                id: "read", ok: true, result: AgentIPCResponseResult(paneRead: read)
            ))
            defer { server.invalidate() }
            let result = try runCLI(
                ["pane", "read", "2", "--lines", "5", "--scrollback"] + (json ? ["--json"] : []),
                server: server
            )
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.request?.subcommand, "read")
            XCTAssertEqual(result.request?.arguments, ["--target", "2", "--lines", "5", "--scrollback"])
            if json {
                XCTAssertEqual(try JSONDecoder().decode(PaneReadResult.self, from: Data(result.stdout.utf8)), read)
            } else {
                XCTAssertEqual(result.stdout, "$ ls\n")
            }
        }
    }

    // MARK: - events

    func test_events_prints_streamed_lines_after_the_acknowledgement() throws {
        let ready = #"{"ts":"2026-01-01T00:00:00.000Z","type":"stream.ready","v":1}"#
        let phase = #"{"agent":"Codex","pane":"pn_a","phase":"idle","ts":"2026-01-01T00:00:01.000Z","type":"agent.phase","v":1}"#
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "events", ok: true), streamLines: [ready, phase])
        defer { server.invalidate() }

        let result = try runCLI(["events", "--json", "--type", "agent.phase"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.request?.subcommand, "events")
        XCTAssertEqual(result.request?.arguments, ["--type", "agent.phase"])
        XCTAssertEqual(result.stdout, ready + "\n" + phase + "\n")
    }

    func test_events_human_output_renders_fields() throws {
        let phase = #"{"agent":"Codex","pane":"pn_a","phase":"idle","ts":"T","type":"agent.phase","v":1}"#
        let server = try TmuxCaptureServer(response: AgentIPCResponse(id: "events", ok: true), streamLines: [phase])
        defer { server.invalidate() }
        let result = try runCLI(["events"], server: server)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "T  agent.phase  pane=pn_a  agent=Codex  phase=idle\n")
    }

    func test_events_rejects_unknown_types_before_connecting() throws {
        let result = try runCLI(["events", "--type", "agents.phase"])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("Unknown event type 'agents.phase'"), result.stderr)
    }

    // MARK: - Helpers

    private struct Result {
        let request: AgentIPCRequest?
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs the built CLI. `standardInput` nil means /dev/null; otherwise it
    /// arrives through a pipe that closes after the data.
    private func runCLI(
        _ arguments: [String],
        server: TmuxCaptureServer? = nil,
        standardInput: Data? = nil
    ) throws -> Result {
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
        let stdinPipe = standardInput.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let completed = XCTestExpectation(description: "pane CLI exited")
        process.terminationHandler = { _ in completed.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        if let stdinPipe, let standardInput {
            // Written from another thread: a large payload would otherwise
            // block here until the CLI reads it.
            DispatchQueue.global().async {
                stdinPipe.fileHandleForWriting.write(standardInput)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
        let request = try server?.receiveOneRequest()
        guard XCTWaiter().wait(for: [completed], timeout: 5) == .completed else {
            XCTFail("pane CLI timed out: \(arguments)")
            throw POSIXError(.ETIMEDOUT)
        }
        return Result(
            request: request,
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
