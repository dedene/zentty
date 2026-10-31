import AppKit
import XCTest
@testable import Zentty

@MainActor
final class HistoryToolbarButtonTests: AppKitTestCase {
    private func makeButton() -> HistoryToolbarButton {
        HistoryToolbarButton(
            frame: NSRect(
                x: 0,
                y: 0,
                width: HistoryToolbarButton.buttonSize,
                height: HistoryToolbarButton.buttonSize
            )
        )
    }

    func test_tooltip_uses_registry_shortcut() {
        let button = makeButton()

        button.updateShortcutTooltip(ShortcutManager(shortcuts: .default))
        XCTAssertEqual(button.toolTip, "Agent History (⌘⇧H)")

        button.updateShortcutTooltip(
            ShortcutManager(
                shortcuts: AppConfig.Shortcuts(
                    bindings: [ShortcutBindingOverride(commandID: .showAgentHistory, shortcut: nil)]
                )
            )
        )
        XCTAssertEqual(button.toolTip, "Agent History")
    }

    func test_accessibility_label_is_agent_history() {
        let button = makeButton()

        XCTAssertEqual(button.accessibilityLabel(), "Agent History")
        XCTAssertEqual(button.title, "")
        XCTAssertNotNil(button.image)
    }

    func test_presented_state_is_emphasized_and_reported() throws {
        let button = makeButton()
        let theme = ZenttyTheme.fallback(for: nil)
        button.configure(theme: theme, animated: false)

        XCTAssertFalse(button.isPalettePresentedForTesting)
        let idleBackground = try XCTUnwrap(button.layer?.backgroundColor)
        XCTAssertEqual(idleBackground.alpha, 0, accuracy: 0.001)

        button.setPalettePresented(true, animated: false)

        XCTAssertTrue(button.isPalettePresentedForTesting)
        let emphasizedBackground = try XCTUnwrap(button.layer?.backgroundColor)
        let expected = ChromeGeometry.iconButtonHoverBackground(theme: theme, isHovered: true).cgColor
        XCTAssertEqual(emphasizedBackground.alpha, expected.alpha, accuracy: 0.001)
        XCTAssertGreaterThan(emphasizedBackground.alpha, 0)
        XCTAssertEqual(button.contentTintColor, theme.primaryText.withAlphaComponent(1.0))

        button.setPalettePresented(false, animated: false)

        XCTAssertFalse(button.isPalettePresentedForTesting)
        XCTAssertEqual(try XCTUnwrap(button.layer?.backgroundColor).alpha, 0, accuracy: 0.001)
    }

    func test_click_invokes_on_click() {
        let button = makeButton()
        var clickCount = 0
        button.onClick = { clickCount += 1 }

        button.performClick(nil)

        XCTAssertEqual(clickCount, 1)
    }
}
