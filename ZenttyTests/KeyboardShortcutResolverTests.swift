import XCTest
@testable import Zentty

final class KeyboardShortcutResolverTests: XCTestCase {
    func test_resolves_new_workspace_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("t"), modifiers: [.command])
        )

        XCTAssertEqual(action, .newWorkspace)
    }

    func test_resolves_split_after_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command])
        )

        XCTAssertEqual(action, .pane(.splitAfterFocusedPane))
    }

    func test_resolves_split_before_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command, .shift])
        )

        XCTAssertEqual(action, .pane(.splitBeforeFocusedPane))
    }

    func test_resolves_close_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("w"), modifiers: [.command])
        )

        XCTAssertEqual(action, .pane(.closeFocusedPane))
    }

    func test_resolves_focus_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option])
            ),
            .pane(.focusLeft)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .option])
            ),
            .pane(.focusRight)
        )
    }

    func test_resolves_jump_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option, .shift])
            ),
            .pane(.focusFirst)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .option, .shift])
            ),
            .pane(.focusLast)
        )
    }

    func test_returns_nil_for_unhandled_shortcuts() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("k"), modifiers: [.command])
        )

        XCTAssertNil(action)
    }

    func test_returns_nil_for_terminal_owned_shortcuts() {
        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.option])
            )
        )

        XCTAssertNil(
            KeyboardShortcutResolver.resolve(
                .init(key: .character("c"), modifiers: [])
            )
        )
    }
}
