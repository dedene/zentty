import XCTest
@testable import Zentty

final class ServerIPCCommandTests: XCTestCase {
    func test_set_command_parses_bare_port() throws {
        let command = try ServerIPCCommand.parse(arguments: ["set", "3000"])

        XCTAssertEqual(command, .set(rawURL: "3000", pid: nil, json: false))
        XCTAssertEqual(command.ipcSubcommand, "server-set")
        XCTAssertEqual(command.ipcArguments, ["3000"])
    }

    func test_set_command_parses_pid_and_json() throws {
        let command = try ServerIPCCommand.parse(arguments: ["set", "localhost:5173", "--pid", "1234", "--json"])

        XCTAssertEqual(command, .set(rawURL: "localhost:5173", pid: 1234, json: true))
        XCTAssertEqual(command.ipcArguments, ["localhost:5173", "--pid", "1234", "--json"])
        XCTAssertTrue(command.expectsResponse)
    }

    func test_clear_command_parses_json() throws {
        let command = try ServerIPCCommand.parse(arguments: ["clear", "--json"])

        XCTAssertEqual(command, .clear(json: true))
        XCTAssertEqual(command.ipcSubcommand, "server-clear")
        XCTAssertEqual(command.ipcArguments, ["--json"])
    }

    func test_list_command_parses_json() throws {
        let command = try ServerIPCCommand.parse(arguments: ["list", "--json"])

        XCTAssertEqual(command, .list(json: true))
        XCTAssertEqual(command.ipcSubcommand, "server-list")
        XCTAssertEqual(command.ipcArguments, ["--json"])
    }

    func test_open_command_parses_default_primary_open() throws {
        let command = try ServerIPCCommand.parse(arguments: ["open"])

        XCTAssertEqual(command, .open(rawURL: nil, browserID: nil, json: false))
        XCTAssertEqual(command.ipcSubcommand, "server-open")
        XCTAssertEqual(command.ipcArguments, [])
    }

    func test_open_command_parses_url_and_browser() throws {
        let command = try ServerIPCCommand.parse(arguments: ["open", "localhost:5173", "--browser", "bundle:com.google.Chrome"])

        XCTAssertEqual(command, .open(rawURL: "localhost:5173", browserID: "bundle:com.google.Chrome", json: false))
        XCTAssertEqual(command.ipcArguments, ["localhost:5173", "--browser", "bundle:com.google.Chrome"])
    }

    func test_watch_command_parses_passthrough_command() throws {
        let command = try ServerIPCCommand.parse(arguments: ["watch", "--", "npm", "run", "dev"])

        XCTAssertEqual(command, .watch(command: ["npm", "run", "dev"]))
        XCTAssertNil(command.ipcSubcommand)
        XCTAssertEqual(command.ipcArguments, ["npm", "run", "dev"])
    }

    func test_watch_set_command_parses_internal_registration() throws {
        let command = try ServerIPCCommand.parse(arguments: ["watch-set", "localhost:5173", "--json"])

        XCTAssertEqual(command, .watchSet(rawURL: "localhost:5173", pid: nil, json: true))
        XCTAssertEqual(command.ipcSubcommand, "server-watch-set")
        XCTAssertEqual(command.ipcArguments, ["localhost:5173", "--json"])
        XCTAssertTrue(command.expectsResponse)
    }

    func test_watch_clear_command_is_internal_cleanup_command() throws {
        let command = try ServerIPCCommand.parse(arguments: ["watch-clear"])

        XCTAssertEqual(command, .watchClear(json: false))
        XCTAssertEqual(command.ipcSubcommand, "server-watch-clear")
        XCTAssertEqual(command.ipcArguments, [])
        XCTAssertFalse(command.expectsResponse)
    }

    func test_watch_clear_command_builds_authenticated_server_request() throws {
        let request = try ServerIPCCommand.makeRequest(
            command: .watchClear(json: false),
            environment: paneEnvironment,
            id: "request-watch-clear"
        )

        XCTAssertEqual(request.kind, .server)
        XCTAssertEqual(request.id, "request-watch-clear")
        XCTAssertEqual(request.subcommand, "server-watch-clear")
        XCTAssertEqual(request.arguments, [])
        XCTAssertFalse(request.expectsResponse)
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
    }

    func test_make_request_uses_server_kind_and_forwards_pane_environment() throws {
        let command = try ServerIPCCommand.parse(arguments: ["set", "3000", "--json"])
        let request = try ServerIPCCommand.makeRequest(
            command: command,
            environment: paneEnvironment,
            id: "request-1"
        )

        XCTAssertEqual(request.kind, .server)
        XCTAssertEqual(request.id, "request-1")
        XCTAssertEqual(request.subcommand, "server-set")
        XCTAssertEqual(request.arguments, ["3000", "--json"])
        XCTAssertTrue(request.expectsResponse)
        XCTAssertEqual(request.environment["ZENTTY_WORKLANE_ID"], "worklane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_ID"], "pane-main")
        XCTAssertEqual(request.environment["ZENTTY_PANE_TOKEN"], "pane-token")
        XCTAssertNil(request.environment["UNRELATED"])
    }

    func test_make_request_rejects_outside_pane_environment() throws {
        XCTAssertThrowsError(
            try ServerIPCCommand.makeRequest(
                command: .clear(json: true),
                environment: [:],
                id: "request-1"
            )
        ) { error in
            XCTAssertEqual(error as? ServerIPCCommandError, .outsidePane)
            XCTAssertEqual(error.localizedDescription, ServerIPCCommand.outsidePaneMessage)
        }
    }

    func test_server_request_round_trips() throws {
        let request = AgentIPCRequest(
            id: "request-1",
            kind: .server,
            arguments: ["localhost:5173", "--browser", "bundle:com.google.Chrome"],
            standardInput: nil,
            environment: paneEnvironment,
            expectsResponse: true,
            subcommand: "server-open"
        )

        let decoded = try JSONDecoder().decode(
            AgentIPCRequest.self,
            from: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func test_handler_parses_prefixed_server_subcommands_to_canonical_commands() throws {
        let set = try ServerIPCHandler.parseCommand(
            subcommand: "server-set",
            arguments: ["localhost:5173", "--json"]
        )
        let list = try ServerIPCHandler.parseCommand(subcommand: "server-list", arguments: ["--json"])
        let open = try ServerIPCHandler.parseCommand(
            subcommand: "server-open",
            arguments: ["localhost:5173", "--browser", "bundle:com.google.Chrome"]
        )
        let clear = try ServerIPCHandler.parseCommand(subcommand: "server-clear", arguments: [])
        let watchSet = try ServerIPCHandler.parseCommand(
            subcommand: "server-watch-set",
            arguments: ["localhost:5173", "--json"]
        )
        let watchClear = try ServerIPCHandler.parseCommand(
            subcommand: "server-watch-clear",
            arguments: []
        )

        XCTAssertEqual(set, .set(rawURL: "localhost:5173", pid: nil, json: true))
        XCTAssertEqual(list, .list(json: true))
        XCTAssertEqual(open, .open(rawURL: "localhost:5173", browserID: "bundle:com.google.Chrome", json: false))
        XCTAssertEqual(clear, .clear(json: false))
        XCTAssertEqual(watchSet, .watchSet(rawURL: "localhost:5173", pid: nil, json: true))
        XCTAssertEqual(watchClear, .watchClear(json: false))
    }

    private var paneEnvironment: [String: String] {
        [
            "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty.sock",
            "ZENTTY_WINDOW_ID": "window-main",
            "ZENTTY_WORKLANE_ID": "worklane-main",
            "ZENTTY_PANE_ID": "pane-main",
            "ZENTTY_PANE_TOKEN": "pane-token",
            "ZENTTY_INSTANCE_ID": "instance-main",
            "UNRELATED": "ignored",
        ]
    }
}
