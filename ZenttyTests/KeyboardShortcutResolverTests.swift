import XCTest
@testable import Zentty

final class KeyboardShortcutResolverTests: XCTestCase {
    func test_resolves_split_after_shortcut() {
        let command = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command])
        )

        XCTAssertEqual(command, .splitAfterFocusedPane)
    }

    func test_resolves_split_before_shortcut() {
        let command = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command, .shift])
        )

        XCTAssertEqual(command, .splitBeforeFocusedPane)
    }

    func test_resolves_close_shortcut() {
        let command = KeyboardShortcutResolver.resolve(
            .init(key: .character("w"), modifiers: [.command])
        )

        XCTAssertEqual(command, .closeFocusedPane)
    }

    func test_resolves_focus_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option])
            ),
            .focusLeft
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .option])
            ),
            .focusRight
        )
    }

    func test_resolves_jump_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option, .shift])
            ),
            .focusFirst
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .option, .shift])
            ),
            .focusLast
        )
    }

    func test_returns_nil_for_unhandled_shortcuts() {
        let command = KeyboardShortcutResolver.resolve(
            .init(key: .character("k"), modifiers: [.command])
        )

        XCTAssertNil(command)
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
