import XCTest
@testable import Zentty

final class KeyboardShortcutResolverTests: XCTestCase {
    func test_resolves_new_workspace_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("t"), modifiers: [.command])
        )

        XCTAssertEqual(action, .newWorkspace)
    }

    func test_resolves_horizontal_split_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command])
        )

        XCTAssertEqual(action, .pane(.splitHorizontally))
    }

    func test_resolves_vertical_split_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("d"), modifiers: [.command, .shift])
        )

        XCTAssertEqual(action, .pane(.splitVertically))
    }

    func test_resolves_close_shortcut() {
        let action = KeyboardShortcutResolver.resolve(
            .init(key: .character("w"), modifiers: [.command])
        )

        XCTAssertEqual(action, .pane(.closeFocusedPane))
    }

    func test_resolves_horizontal_focus_shortcuts() {
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

    func test_resolves_vertical_focus_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .upArrow, modifiers: [.command, .option])
            ),
            .pane(.focusUp)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .downArrow, modifiers: [.command, .option])
            ),
            .pane(.focusDown)
        )
    }

    func test_resolves_jump_to_edge_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .option, .shift])
            ),
            .pane(.focusFirstColumn)
        )

        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .option, .shift])
            ),
            .pane(.focusLastColumn)
        )
    }

    func test_resolves_resize_shortcuts() {
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .leftArrow, modifiers: [.command, .control, .option])
            ),
            .pane(.resizeLeft)
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .rightArrow, modifiers: [.command, .control, .option])
            ),
            .pane(.resizeRight)
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .upArrow, modifiers: [.command, .control, .option])
            ),
            .pane(.resizeUp)
        )
        XCTAssertEqual(
            KeyboardShortcutResolver.resolve(
                .init(key: .downArrow, modifiers: [.command, .control, .option])
            ),
            .pane(.resizeDown)
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
