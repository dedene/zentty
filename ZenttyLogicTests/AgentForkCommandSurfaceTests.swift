import XCTest
@testable import Zentty

/// Fork-agent-conversation surfaces: CLI/IPC arguments, the
/// `agents.fork_destination` setting, the command registry entry, and the
/// palette's enablement rules.
final class AgentForkCommandSurfaceTests: XCTestCase {
    private let plan = AgentForkPlan(
        tool: .claudeCode,
        command: "claude --resume 5b1f9e52-5c1d-4e8a-9d53-7f3e0b1c2a44 --fork-session",
        workingDirectory: "/tmp/project"
    )

    // MARK: - CLI flags and IPC arguments

    func test_cli_flags_map_to_destinations() throws {
        XCTAssertNil(try AgentForkIPCArguments(target: nil, down: false, worklane: false).destination)
        XCTAssertEqual(try AgentForkIPCArguments(target: nil, down: true, worklane: false).destination, .splitDown)
        XCTAssertEqual(try AgentForkIPCArguments(target: nil, down: false, worklane: true).destination, .newWorklane)
    }

    func test_cli_rejects_both_destination_flags() {
        XCTAssertThrowsError(try AgentForkIPCArguments(target: nil, down: true, worklane: true)) { error in
            XCTAssertEqual(error as? AgentForkIPCArguments.ParseError, .conflictingDestinations)
        }
    }

    func test_ipc_arguments_round_trip() throws {
        let cases = [
            AgentForkIPCArguments(),
            AgentForkIPCArguments(target: "2"),
            AgentForkIPCArguments(target: "pn_abc", destination: .newWorklane),
            AgentForkIPCArguments(destination: .splitDown),
        ]
        for arguments in cases {
            XCTAssertEqual(try AgentForkIPCArguments.parse(arguments.ipcArguments), arguments)
        }
        XCTAssertEqual(
            AgentForkIPCArguments(target: "2", destination: .splitDown).ipcArguments,
            ["2", "--destination", "split_down"]
        )
    }

    func test_ipc_parse_rejects_bad_input() {
        XCTAssertThrowsError(try AgentForkIPCArguments.parse(["--destination"])) { error in
            XCTAssertEqual(error as? AgentForkIPCArguments.ParseError, .missingValue("--destination"))
        }
        XCTAssertThrowsError(try AgentForkIPCArguments.parse(["--destination", "sideways"])) { error in
            XCTAssertEqual(error as? AgentForkIPCArguments.ParseError, .invalidDestination("sideways"))
        }
        XCTAssertThrowsError(try AgentForkIPCArguments.parse(["1", "2"])) { error in
            XCTAssertEqual(error as? AgentForkIPCArguments.ParseError, .unexpectedArgument("2"))
        }
        XCTAssertThrowsError(try AgentForkIPCArguments.parse(["--down"])) { error in
            XCTAssertEqual(error as? AgentForkIPCArguments.ParseError, .unexpectedArgument("--down"))
        }
    }

    // MARK: - Config

    func test_fork_destination_defaults_to_split_right() {
        XCTAssertEqual(AppConfig.default.agents.forkDestination, .splitRight)
        XCTAssertEqual(AppConfigTOML.decode("[agents]\n")?.agents.forkDestination, .splitRight)
    }

    func test_fork_destination_round_trips_through_toml() {
        for destination in AgentForkDestination.allCases {
            var config = AppConfig.default
            config.agents.forkDestination = destination

            let encoded = AppConfigTOML.encode(config)

            XCTAssertTrue(encoded.contains("[agents]\nfork_destination = \"\(destination.rawValue)\""))
            XCTAssertEqual(AppConfigTOML.decode(encoded)?.agents.forkDestination, destination)
        }
    }

    func test_fork_destination_decodes_each_token() {
        XCTAssertEqual(
            AppConfigTOML.decode("[agents]\nfork_destination = \"split_down\"")?.agents.forkDestination,
            .splitDown
        )
        XCTAssertEqual(
            AppConfigTOML.decode("[agents]\nfork_destination = \"new_worklane\"")?.agents.forkDestination,
            .newWorklane
        )
    }

    func test_invalid_fork_destination_is_rejected() {
        XCTAssertNil(AppConfigTOML.decode("[agents]\nfork_destination = \"sideways\""))
    }

    func test_unknown_agents_key_is_tolerated() {
        XCTAssertEqual(
            AppConfigTOML.decode("[agents]\nfork_destination = \"split_down\"\nfuture_flag = true")?
                .agents.forkDestination,
            .splitDown
        )
    }

    // MARK: - Command registry and availability

    func test_registry_includes_fork_command_without_default_shortcut() {
        let definition = AppCommandRegistry.definition(for: .forkAgentConversation)

        XCTAssertEqual(definition.title, "Fork Agent Conversation")
        XCTAssertEqual(definition.category, .panes)
        XCTAssertNil(definition.defaultShortcut)
        XCTAssertEqual(definition.action, .pane(.forkAgentConversation))
        XCTAssertEqual(AppCommandID.forkAgentConversation.rawValue, "pane.fork_agent_conversation")
    }

    func test_fork_command_is_hidden_without_agent_and_shown_for_any_agent() {
        XCTAssertFalse(isForkAvailable(nil))
        XCTAssertTrue(isForkAvailable(.available(plan)))
        XCTAssertTrue(isForkAvailable(.unavailable(reason: "Copilot can't fork a conversation.")))
    }

    func test_palette_item_is_enabled_with_tool_subtitle_when_forkable() throws {
        let item = try XCTUnwrap(paletteItem(for: .available(plan)))

        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.subtitle, "Continue this Claude Code conversation in a new pane.")
    }

    func test_palette_item_is_disabled_with_reason_when_not_forkable() throws {
        let item = try XCTUnwrap(paletteItem(for: .unavailable(reason: "Claude Code hasn't reported a session ID yet.")))

        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.subtitle, "Claude Code hasn't reported a session ID yet.")
    }

    func test_disabled_fork_row_is_not_executable_from_palette() {
        let disabledItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.forkAgentConversation, .duplicateFocusedPane],
            shortcutManager: ShortcutManager(shortcuts: .default),
            focusedPaneAgentFork: .unavailable(reason: "Copilot can't fork a conversation.")
        )
        let enabledItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.forkAgentConversation, .duplicateFocusedPane],
            shortcutManager: ShortcutManager(shortcuts: .default),
            focusedPaneAgentFork: .available(plan)
        )

        XCTAssertEqual(
            CommandPaletteItemBuilder.disabledCommandItemIDs(in: disabledItems),
            [.command(.forkAgentConversation)]
        )
        XCTAssertEqual(CommandPaletteItemBuilder.disabledCommandItemIDs(in: enabledItems), [])
    }

    // MARK: - Helpers

    private func isForkAvailable(_ fork: AgentForkAvailability?) -> Bool {
        CommandAvailabilityResolver.isCommandAvailable(
            .forkAgentConversation,
            for: CommandAvailabilityContext(
                worklaneCount: 1,
                activePaneCount: 1,
                totalPaneCount: 1,
                activeColumnCount: 1,
                focusedColumnPaneCount: 1,
                focusedPaneHasRememberedSearch: false,
                globalSearchHasRememberedSearch: false,
                activeWorklaneHasBranchURL: false,
                focusedPaneAgentFork: fork
            )
        )
    }

    private func paletteItem(for fork: AgentForkAvailability) -> CommandPaletteItem? {
        CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: [.forkAgentConversation],
            shortcutManager: ShortcutManager(shortcuts: .default),
            focusedPaneAgentFork: fork
        ).first
    }
}
