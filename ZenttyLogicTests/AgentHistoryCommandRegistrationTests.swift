import Carbon.HIToolbox
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryCommandRegistrationTests: XCTestCase {
    private let commandShiftH = KeyboardShortcut(key: .character("h"), modifiers: [.command, .shift])

    func test_show_agent_history_is_registered_with_command_shift_h_in_general_category() throws {
        let definition = AppCommandRegistry.definition(for: .showAgentHistory)

        XCTAssertEqual(AppCommandID.showAgentHistory.rawValue, "agent_history.show")
        XCTAssertEqual(definition.title, "Agent History…")
        XCTAssertEqual(definition.category, .general)
        XCTAssertEqual(definition.defaultShortcut, commandShiftH)
        XCTAssertEqual(definition.action, .showAgentHistory)
        XCTAssertEqual(definition.detailDescription, "Search past agent conversations and resume them.")

        let menuItem = try XCTUnwrap(definition.menuItem)
        XCTAssertEqual(menuItem.section, .view)
        XCTAssertEqual(menuItem.title, "Agent History…")
        XCTAssertEqual(menuItem.selector, #selector(MainWindowController.showAgentHistory(_:)))
        XCTAssertEqual(menuItem.systemImageName, "clock.arrow.circlepath")
        XCTAssertEqual(
            AppCommandRegistry.commandID(forMenuAction: #selector(MainWindowController.showAgentHistory(_:))),
            .showAgentHistory
        )
    }

    func test_view_menu_lists_agent_history_right_after_bookmarks() throws {
        let viewEntries = try XCTUnwrap(AppCommandRegistry.menuEntriesBySection[.view])
        let commandIDs: [AppCommandID?] = viewEntries.map { entry in
            if case .command(let id) = entry { return id }
            return nil
        }

        let bookmarksIndex = try XCTUnwrap(commandIDs.firstIndex(of: .openBookmarksPopover))
        XCTAssertEqual(commandIDs[bookmarksIndex + 1], .showAgentHistory)
        XCTAssertEqual(commandIDs[bookmarksIndex + 2], .toggleSidebar)
        XCTAssertEqual(commandIDs.filter { $0 == .showAgentHistory }.count, 1)
    }

    func test_command_shift_h_resolves_to_show_agent_history_without_conflicts() {
        XCTAssertEqual(KeyboardShortcutResolver.resolve(commandShiftH, shortcuts: .default), .showAgentHistory)

        let defaultsBoundToCommandShiftH = AppCommandRegistry.definitions
            .filter { $0.defaultShortcut == commandShiftH }
            .map(\.id)
        XCTAssertEqual(defaultsBoundToCommandShiftH, [.showAgentHistory])

        let manager = ShortcutManager(shortcuts: .default)
        XCTAssertNil(manager.conflict(for: commandShiftH, assigningTo: .showAgentHistory))
    }

    func test_search_text_includes_history_aliases() {
        let searchText = AppCommandRegistry.definition(for: .showAgentHistory).searchText

        for alias in ["agent history", "history", "sessions", "resume", "find session", "past conversations"] {
            XCTAssertTrue(searchText.contains(alias), "Missing search alias '\(alias)' in \(searchText)")
        }
    }

    func test_palette_item_uses_clock_icon() throws {
        let item = try XCTUnwrap(
            CommandPaletteItemBuilder.buildItems(
                availableCommandIDs: [.showAgentHistory],
                shortcutManager: ShortcutManager(shortcuts: .default)
            ).first
        )

        XCTAssertEqual(item.id, .command(.showAgentHistory))
        XCTAssertEqual(item.iconSystemName, "clock.arrow.circlepath")
        XCTAssertEqual(item.shortcutDisplay, "⌘⇧H")
    }

    func test_presets_bind_agent_history_to_command_shift_h() {
        let resolver = ShortcutPresetResolver(sourceProvider: USLetterKeyboardSourceProvider())

        for preset in ShortcutPreset.allCases {
            let manager = ShortcutManager(shortcuts: .init(bindings: resolver.resolve(preset)))
            XCTAssertEqual(
                manager.shortcut(for: .showAgentHistory),
                commandShiftH,
                "Preset \(preset) must keep Agent History on ⌘⇧H"
            )
            XCTAssertEqual(manager.commandID(for: commandShiftH), .showAgentHistory, "Preset \(preset)")
        }
    }

    func test_tooltip_formats_agent_history_shortcut() {
        XCTAssertEqual(
            CommandTooltipFormatter.title(
                "Agent History",
                commandID: .showAgentHistory,
                shortcutManager: ShortcutManager(shortcuts: .default)
            ),
            "Agent History (⌘⇧H)"
        )

        let unbound = ShortcutManager(
            shortcuts: .init(bindings: [ShortcutBindingOverride(commandID: .showAgentHistory, shortcut: nil)])
        )
        XCTAssertEqual(
            CommandTooltipFormatter.title("Agent History", commandID: .showAgentHistory, shortcutManager: unbound),
            "Agent History"
        )
    }
}

/// Maps the ANSI letter key codes to their US QWERTY characters so the
/// physical-key presets resolve deterministically, independent of the host
/// keyboard layout.
private struct USLetterKeyboardSourceProvider: KeyboardPreviewSourceProviding {
    private static let letters: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z",
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
    ]

    func currentGeometry() -> KeyboardPreviewGeometry {
        .ansi
    }

    func output(for keyCode: UInt16, modifiers: Set<KeyboardModifier>) -> String? {
        guard modifiers.isEmpty else { return nil }
        return Self.letters[Int(keyCode)]
    }

    func displayLabel(for keyCode: UInt16) -> String? {
        output(for: keyCode, modifiers: [])
    }
}
