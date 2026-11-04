import XCTest
@testable import Zentty

/// Wire contract of `zentty pane float|dock|pip|minimize|restore` and
/// `zentty float new|list|hide|show` (shared by the app and the CLI).
final class FloatControlProtocolTests: XCTestCase {

    // MARK: - Subcommand names

    func test_pane_actions_map_to_ipc_subcommands_both_ways() {
        let expected: [(PaneFloatAction, PaneIPCSubcommand)] = [
            (.float, .paneFloat), (.dock, .paneDock), (.pip, .panePip),
            (.minimize, .paneMinimize), (.restore, .paneRestore),
        ]
        XCTAssertEqual(expected.count, PaneFloatAction.allCases.count)
        for (action, subcommand) in expected {
            XCTAssertEqual(action.subcommand, subcommand.rawValue)
            XCTAssertEqual(PaneFloatAction(subcommand: subcommand.rawValue), action)
            XCTAssertEqual(subcommand.floatAction, action)
        }
        XCTAssertNil(PaneFloatAction(subcommand: "float"))
        XCTAssertNil(PaneFloatAction(subcommand: "pane-zoom"))
        XCTAssertNil(PaneIPCSubcommand.floatNew.floatAction)
    }

    func test_float_group_subcommands_are_known_to_the_handler() {
        XCTAssertEqual(PaneIPCSubcommand(rawValue: FloatControlIPC.newSubcommand), .floatNew)
        XCTAssertEqual(PaneIPCSubcommand(rawValue: FloatControlIPC.listSubcommand), .floatList)
        XCTAssertEqual(PaneIPCSubcommand(rawValue: FloatControlIPC.hideSubcommand), .floatHide)
        XCTAssertEqual(PaneIPCSubcommand(rawValue: FloatControlIPC.showSubcommand), .floatShow)
    }

    func test_float_commands_never_focus_the_caller_and_require_a_target() {
        let commands: [PaneIPCSubcommand] = [
            .paneFloat, .paneDock, .panePip, .paneMinimize, .paneRestore,
            .floatNew, .floatList, .floatHide, .floatShow,
        ]
        for command in commands {
            XCTAssertFalse(command.focusesTarget, command.rawValue)
            XCTAssertTrue(command.requiresResolvedTarget, command.rawValue)
        }
    }

    // MARK: - pane <action>

    func test_pane_float_options_round_trip() throws {
        let options = PaneFloatIPCOptions(target: "pn_abc", corner: "top-left")
        XCTAssertEqual(options.arguments(), ["--target", "pn_abc", "--corner", "top-left"])
        XCTAssertEqual(try PaneFloatIPCOptions.parse(arguments: options.arguments(), action: .pip), options)
        XCTAssertEqual(try PaneFloatIPCOptions.parse(arguments: [], action: .float), PaneFloatIPCOptions())
        XCTAssertEqual(try PaneFloatIPCOptions.parse(arguments: ["--target", "2"], action: .dock).target, "2")
    }

    func test_pane_float_options_accept_every_corner_for_pip_only() throws {
        for corner in FloatControlIPC.cornerNames {
            XCTAssertEqual(try PaneFloatIPCOptions.parse(arguments: ["--corner", corner], action: .pip).corner, corner)
            XCTAssertNotNil(FloatCorner(wireName: corner), corner)
        }
        XCTAssertThrowsError(try PaneFloatIPCOptions.parse(arguments: ["--corner", "top-left"], action: .minimize)) {
            XCTAssertEqual($0 as? FloatControlIPCError, .cornerOnlyForPip)
        }
        XCTAssertThrowsError(try PaneFloatIPCOptions.parse(arguments: ["--corner", "middle"], action: .pip)) {
            XCTAssertEqual($0 as? FloatControlIPCError, .invalidValue("--corner", "middle"))
        }
    }

    func test_pane_float_options_reject_bad_input() {
        XCTAssertThrowsError(try PaneFloatIPCOptions.parse(arguments: ["--target"], action: .float)) {
            XCTAssertEqual($0 as? FloatControlIPCError, .missingValue("--target"))
        }
        XCTAssertThrowsError(try PaneFloatIPCOptions.parse(arguments: ["2"], action: .float)) {
            XCTAssertEqual($0 as? FloatControlIPCError, .unexpectedArgument("2"))
        }
    }

    func test_corner_wire_names_round_trip() {
        XCTAssertEqual(FloatCorner.allCases.map(\.wireName), FloatControlIPC.cornerNames)
        for corner in FloatCorner.allCases {
            XCTAssertEqual(FloatCorner(wireName: corner.wireName), corner)
        }
        XCTAssertNil(FloatCorner(wireName: "topLeft"))
    }

    // MARK: - float new

    func test_float_new_options_round_trip_with_command_tokens() throws {
        let options = FloatNewIPCOptions(
            workingDirectory: "/tmp/two words",
            temporary: true,
            command: ["git", "log", "--oneline", "it's"]
        )
        let arguments = try options.arguments()
        XCTAssertEqual(Array(arguments.prefix(4)), ["--cwd", "/tmp/two words", "--temporary", "--command-json"])
        XCTAssertEqual(try FloatNewIPCOptions.parse(arguments: arguments), options)
        XCTAssertEqual(try FloatNewIPCOptions().arguments(), [])
        XCTAssertEqual(try FloatNewIPCOptions.parse(arguments: []), FloatNewIPCOptions())
    }

    func test_float_new_options_reject_bad_input() {
        let cases: [([String], FloatControlIPCError)] = [
            (["--cwd"], .missingValue("--cwd")),
            (["--cwd", ""], .invalidValue("--cwd", "")),
            (["--command-json", "not json"], .invalidCommandJSON),
            (["--wait"], .unexpectedArgument("--wait")),
        ]
        for (arguments, expected) in cases {
            XCTAssertThrowsError(try FloatNewIPCOptions.parse(arguments: arguments), "\(arguments)") {
                XCTAssertEqual($0 as? FloatControlIPCError, expected)
            }
        }
    }

    func test_worklane_commands_take_no_arguments() {
        XCTAssertNoThrow(try FloatWorklaneIPCOptions.validate(arguments: []))
        XCTAssertThrowsError(try FloatWorklaneIPCOptions.validate(arguments: ["--all"])) {
            XCTAssertEqual($0 as? FloatControlIPCError, .unexpectedArgument("--all"))
        }
    }

    // MARK: - float list payload

    func test_float_list_entry_json_keys_follow_cli_conventions() throws {
        let entry = FloatListEntry(
            id: "pn_1", index: 3, worklaneID: "wl_1", windowID: "win_1", title: "logs",
            workingDirectory: "/tmp", mode: "floating",
            frame: .init(x: 0.2, y: 0.1, width: 0.6, height: 0.5), corner: nil,
            status: "idle", agentTool: nil, isFocused: true, isHidden: false, isTemporary: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["id", "index", "worklaneID", "windowID", "title", "workingDirectory", "mode", "frame",
             "status", "isFocused", "isHidden", "isTemporary"],
            "nil optionals are omitted"
        )
        XCTAssertEqual((object["frame"] as? [String: Double])?["width"], 0.6)
        let result = AgentIPCResponseResult(floatList: [entry])
        XCTAssertEqual(try JSONDecoder().decode(AgentIPCResponseResult.self, from: JSONEncoder().encode(result)), result)
    }

    func test_response_without_float_list_still_decodes() throws {
        let decoded = try JSONDecoder().decode(AgentIPCResponseResult.self, from: Data(#"{"stdout":"x"}"#.utf8))
        XCTAssertNil(decoded.floatList)
        XCTAssertEqual(decoded.stdout, "x")
    }
}
