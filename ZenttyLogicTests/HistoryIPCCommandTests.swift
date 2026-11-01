import XCTest
@testable import Zentty

final class HistoryIPCCommandTests: XCTestCase {
    private let paneEnvironment = [
        "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty.sock",
        "ZENTTY_WINDOW_ID": "window-1",
        "ZENTTY_WORKLANE_ID": "worklane-1",
        "ZENTTY_PANE_ID": "pane-1",
        "ZENTTY_PANE_TOKEN": "token-1",
        "ZENTTY_INSTANCE_ID": "instance-1",
    ]

    func test_search_command_round_trips_through_ipc_arguments() throws {
        let command = HistoryIPCCommand.search(
            HistorySearchIPCOptions(query: "flaky display", allProjects: true, agent: "codex", limit: 25)
        )

        XCTAssertEqual(command.ipcSubcommand, "history-search")
        XCTAssertEqual(
            command.ipcArguments,
            ["--query", "flaky display", "--all", "--agent", "codex", "--limit", "25"]
        )
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: command.ipcSubcommand, arguments: command.ipcArguments),
            command
        )
        XCTAssertTrue(command.allProjects)
        XCTAssertEqual(command.maxResponseBytes, HistoryIPC.maxSearchResponseBytes)
    }

    func test_show_command_round_trips_through_ipc_arguments() throws {
        let command = HistoryIPCCommand.show(
            HistoryShowIPCOptions(sessionID: "3f2a9c1e-6d1b-4c7e-9a2f-0b1c2d3e4f50", agent: "claude", turns: 5)
        )

        XCTAssertEqual(command.ipcSubcommand, "history-show")
        XCTAssertEqual(
            command.ipcArguments,
            ["--session-id", "3f2a9c1e-6d1b-4c7e-9a2f-0b1c2d3e4f50", "--agent", "claude", "--turns", "5"]
        )
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: command.ipcSubcommand, arguments: command.ipcArguments),
            command
        )
        XCTAssertFalse(command.allProjects)
        XCTAssertEqual(command.maxResponseBytes, HistoryIPC.maxShowResponseBytes)
    }

    func test_query_value_that_looks_like_a_flag_is_kept_as_text() throws {
        let command = try HistoryIPCCommand.parse(
            subcommand: "history-search",
            arguments: ["--query", "--all", "--limit", "3"]
        )

        XCTAssertEqual(command, .search(HistorySearchIPCOptions(query: "--all", allProjects: false, limit: 3)))
    }

    func test_parse_rejects_unknown_flag_missing_value_and_unknown_subcommand() {
        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--pane-id", "p"])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .unexpectedArgument("--pane-id")) }

        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--limit"])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .missingValue("--limit")) }

        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--all", "--all"])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .unexpectedArgument("--all")) }

        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--turns", "3"])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .missingValue("--session-id")) }

        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-delete", arguments: [])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .unknownSubcommand("history-delete")) }

        XCTAssertThrowsError(try HistoryIPCCommand.parse(subcommand: nil, arguments: [])) {
            XCTAssertEqual($0 as? HistoryIPCError, .unknownSubcommand(""))
        }
    }

    func test_limit_and_turns_bounds_and_defaults() throws {
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x"]),
            .search(HistorySearchIPCOptions(query: "x", limit: 10))
        )
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--session-id", "s"]),
            .show(HistoryShowIPCOptions(sessionID: "s", turns: 20))
        )
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--limit", "50"]),
            .search(HistorySearchIPCOptions(query: "x", limit: 50))
        )
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--session-id", "s", "--turns", "200"]),
            .show(HistoryShowIPCOptions(sessionID: "s", turns: 200))
        )

        for limit in ["0", "51", "-1", "ten", ""] {
            XCTAssertThrowsError(
                try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--limit", limit])
            ) { XCTAssertEqual($0 as? HistoryIPCError, .invalidValue("--limit", limit)) }
        }
        for turns in ["0", "201", "1.5"] {
            XCTAssertThrowsError(
                try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--session-id", "s", "--turns", turns])
            ) { XCTAssertEqual($0 as? HistoryIPCError, .invalidValue("--turns", turns)) }
        }
    }

    func test_agent_must_be_supported() throws {
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--agent", "OpenCode"]),
            .search(HistorySearchIPCOptions(query: "x", agent: "opencode"))
        )
        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", "--agent", "gemini"])
        ) { error in
            XCTAssertEqual(error as? HistoryIPCError, .invalidValue("--agent", "gemini"))
            XCTAssertEqual(
                error.localizedDescription,
                "Unknown agent 'gemini'. Use one of: claude, codex, grok, opencode."
            )
        }
    }

    func test_supported_agents_match_enum() {
        XCTAssertEqual(HistoryIPC.supportedAgents, AgentHistoryAgent.allCases.map(\.rawValue))
    }

    func test_empty_or_overlong_query_is_rejected() throws {
        for arguments in [[], ["--query", ""], ["--query", "  \n"]] {
            XCTAssertThrowsError(try HistoryIPCCommand.parse(subcommand: "history-search", arguments: arguments)) {
                XCTAssertEqual($0 as? HistoryIPCError, .missingQuery)
            }
        }

        let longest = String(repeating: "é", count: HistoryIPC.maxQueryCharacters)
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", longest]),
            .search(HistorySearchIPCOptions(query: longest))
        )
        let overlong = longest + "x"
        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", overlong])
        ) { XCTAssertEqual($0 as? HistoryIPCError, .invalidValue("--query", overlong)) }
    }

    func test_session_id_with_control_characters_is_rejected() throws {
        for sessionID in ["abc\u{1B}[31m", "abc\ndef", "abc def", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(
                try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--session-id", sessionID])
            ) { error in
                XCTAssertEqual(error as? HistoryIPCError, .invalidValue("--session-id", sessionID))
                XCTAssertFalse(error.localizedDescription.contains("\u{1B}"), "Echoed ids never carry escapes")
            }
        }
        XCTAssertEqual(
            try HistoryIPCCommand.parse(subcommand: "history-show", arguments: ["--session-id", "ses_01JABC"]),
            .show(HistoryShowIPCOptions(sessionID: "ses_01JABC"))
        )
    }

    func test_echoed_values_are_capped_and_escaped() throws {
        let flood = String(repeating: "a", count: 10_000)
        let floodErrors: [HistoryIPCError] = [
            .unexpectedArgument(flood),
            .unknownSubcommand(flood),
            .invalidValue("--agent", flood),
            .invalidValue("--limit", flood),
            .invalidValue("--turns", flood),
            .invalidValue("--session-id", flood),
            .notFound(flood),
        ]
        for error in floodErrors {
            let message = error.localizedDescription
            XCTAssertLessThan(message.count, 160, "\(error) echoes the full argument")
            XCTAssertTrue(message.contains(String(repeating: "a", count: 80) + "…"), "\(error)")
            XCTAssertFalse(message.contains(String(repeating: "a", count: 81)), "\(error)")
        }
        XCTAssertLessThan(HistoryIPCError.unexpectedArgument(flood).localizedDescription.count, 120)
        XCTAssertTrue(HistoryIPCError.unexpectedArgument(flood).localizedDescription.hasSuffix("…'."))

        // Real parse paths: an unknown flag and an unknown subcommand.
        let hostile = "--x\u{1B}]0;pwned\u{07}\u{1B}[31m" + flood
        XCTAssertThrowsError(
            try HistoryIPCCommand.parse(subcommand: "history-search", arguments: ["--query", "x", hostile])
        ) { error in
            XCTAssertEqual(error as? HistoryIPCError, .unexpectedArgument(hostile))
            XCTAssertFalse(error.localizedDescription.contains("\u{1B}"))
            XCTAssertFalse(error.localizedDescription.contains("\u{07}"))
            XCTAssertLessThan(error.localizedDescription.count, 160)
        }
        XCTAssertThrowsError(try HistoryIPCCommand.parse(subcommand: hostile, arguments: [])) { error in
            XCTAssertEqual(error as? HistoryIPCError, .unknownSubcommand(hostile))
            XCTAssertFalse(error.localizedDescription.contains("\u{1B}"))
            XCTAssertFalse(error.localizedDescription.contains("\u{07}"))
            XCTAssertLessThan(error.localizedDescription.count, 160)
        }
    }

    func test_make_request_requires_socket_and_routing_environment() throws {
        let command = HistoryIPCCommand.search(HistorySearchIPCOptions(query: "x"))
        for missingKey in ["ZENTTY_INSTANCE_SOCKET", "ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"] {
            var environment = paneEnvironment
            environment[missingKey] = ""
            XCTAssertThrowsError(try HistoryIPCCommand.makeRequest(command: command, environment: environment)) {
                XCTAssertEqual($0 as? HistoryIPCError, .outsidePane, missingKey)
                XCTAssertEqual($0.localizedDescription, "zentty history must run inside a Zentty pane.")
            }
        }

        let request = try HistoryIPCCommand.makeRequest(command: command, environment: paneEnvironment, id: "req-1")
        XCTAssertEqual(request.id, "req-1")
        XCTAssertEqual(request.kind, .history)
        XCTAssertEqual(request.subcommand, "history-search")
        XCTAssertEqual(request.arguments, command.ipcArguments)
        XCTAssertNil(request.standardInput)
        XCTAssertTrue(request.expectsResponse)
    }

    func test_make_request_forwards_only_routing_environment() throws {
        var environment = paneEnvironment
        environment["HOME"] = "/Users/someone"
        environment["OPENAI_API_KEY"] = "sk-secret"
        environment["ZENTTY_WINDOW_ID"] = ""

        let request = try HistoryIPCCommand.makeRequest(
            command: .show(HistoryShowIPCOptions(sessionID: "s")),
            environment: environment
        )

        XCTAssertEqual(request.environment, [
            "ZENTTY_WORKLANE_ID": "worklane-1",
            "ZENTTY_PANE_ID": "pane-1",
            "ZENTTY_PANE_TOKEN": "token-1",
            "ZENTTY_INSTANCE_ID": "instance-1",
        ])
    }

    func test_history_kind_encodes_as_history() throws {
        let request = try HistoryIPCCommand.makeRequest(
            command: .search(HistorySearchIPCOptions(query: "x")),
            environment: paneEnvironment
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["kind"] as? String, "history")
        XCTAssertEqual(try JSONDecoder().decode(AgentIPCRequest.self, from: JSONEncoder().encode(request)), request)
    }

    func test_error_codes() {
        let expected: [(HistoryIPCError, String)] = [
            (.outsidePane, "missing_target_context"),
            (.missingValue("--limit"), "missing_value"),
            (.missingQuery, "missing_value"),
            (.invalidValue("--limit", "0"), "unexpected_argument"),
            (.unexpectedArgument("--pane-id"), "unexpected_argument"),
            (.unknownSubcommand("history-x"), "unexpected_argument"),
            (.disabled, "history_disabled"),
            (.unavailable("The index is being rebuilt."), "history_unavailable"),
            (.scopeDenied, "history_scope_denied"),
            (.scopeUnknown("This pane runs on another machine, so its project is unknown."), "history_scope_unknown"),
            (.notFound("abc"), "not_found"),
            (.responseTooLarge, "request_too_large"),
        ]
        for (error, code) in expected {
            XCTAssertEqual(error.ipcCode, code, "\(error)")
        }

        XCTAssertEqual(HistoryIPCError.disabled.localizedDescription, HistoryIPC.disabledMessage)
        XCTAssertEqual(HistoryIPCError.scopeDenied.localizedDescription, HistoryIPC.scopeDeniedMessage)
        XCTAssertEqual(
            HistoryIPCError.notFound("abc").localizedDescription,
            "No session abc in this project's Agent History."
        )
        XCTAssertEqual(
            HistoryIPCError.unavailable("The index is being rebuilt.").localizedDescription,
            "The index is being rebuilt."
        )
    }
}
