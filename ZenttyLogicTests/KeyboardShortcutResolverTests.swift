import XCTest
@testable import Zentty

final class KeyboardShortcutResolverTests: XCTestCase {
    func test_registry_includes_toggle_sidebar_command_with_general_category_and_command_s_default() {
        let definition = AppCommandRegistry.definition(for: .toggleSidebar)

        XCTAssertEqual(definition.title, "Toggle Sidebar")
        XCTAssertEqual(definition.category, .general)
        XCTAssertEqual(
            definition.defaultShortcut,
            .init(key: .character("s"), modifiers: [.command])
        )
    }

    func test_resolves_default_shortcuts_from_registry() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("t"), modifiers: [.command]),
                shortcuts: .default
            ),
            .newWorklane
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: .default
            ),
            .toggleSidebar
        )
    }

    func test_resolves_remapped_shortcuts_from_overrides() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("b"), modifiers: [.command])
                )
            ]
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("b"), modifiers: [.command]),
                shortcuts: shortcuts
            ),
            .toggleSidebar
        )
        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: shortcuts
            )
        )
    }

    func test_unbound_commands_do_not_resolve() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(commandID: .toggleSidebar, shortcut: nil)
            ]
        )

        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("s"), modifiers: [.command]),
                shortcuts: shortcuts
            )
        )
    }

    func test_conflicting_shortcut_override_is_rejected_in_effective_bindings() {
        let manager = ShortcutManager(
            shortcuts: AppConfig.Shortcuts(
                bindings: [
                    ShortcutBindingOverride(
                        commandID: .toggleSidebar,
                        shortcut: .init(key: .character("t"), modifiers: [.command])
                    )
                ]
            )
        )

        XCTAssertEqual(manager.shortcut(for: .toggleSidebar), .init(key: .character("s"), modifiers: [.command]))
        XCTAssertEqual(manager.commandID(for: .init(key: .character("t"), modifiers: [.command])), .newWorklane)
    }

    func test_bindings_without_command_control_or_option_are_rejected() {
        let shortcuts = AppConfig.Shortcuts(
            bindings: [
                ShortcutBindingOverride(
                    commandID: .toggleSidebar,
                    shortcut: .init(key: .character("a"), modifiers: [])
                )
            ]
        )

        let manager = ShortcutManager(shortcuts: shortcuts)

        XCTAssertEqual(manager.shortcut(for: .toggleSidebar), .init(key: .character("s"), modifiers: [.command]))
        XCTAssertNil(manager.commandID(for: .init(key: .character("a"), modifiers: [])))
    }

    func test_returns_nil_for_unhandled_shortcuts() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("k"), modifiers: [.command]),
            shortcuts: .default
        )

        XCTAssertNil(action)
    }
}
