import AppKit
import XCTest
@testable import Zentty

@MainActor
final class AppMenuBuilderTests: XCTestCase {
    func test_copy_markdown_menu_item_follows_clipboard_setting() {
        var config = AppConfig.default
        config.clipboard.showCopyMarkdownCommand = true

        let menuWithMarkdown = AppMenuBuilder.makeMainMenu(appName: "Zentty", config: config)
        XCTAssertNotNil(menuItem(for: #selector(MainWindowController.copyMarkdown(_:)), in: menuWithMarkdown))

        config.clipboard.showCopyMarkdownCommand = false
        let menuWithoutMarkdown = AppMenuBuilder.makeMainMenu(appName: "Zentty", config: config)
        XCTAssertNil(menuItem(for: #selector(MainWindowController.copyMarkdown(_:)), in: menuWithoutMarkdown))
    }

    func test_required_menu_items_detects_copy_markdown_setting_mismatch() {
        var config = AppConfig.default
        config.clipboard.showCopyMarkdownCommand = true
        let menuWithMarkdown = AppMenuBuilder.makeMainMenu(appName: "Zentty", config: config)

        XCTAssertTrue(AppMenuBuilder.hasRequiredMenuItems(in: menuWithMarkdown, appName: "Zentty", config: config))

        config.clipboard.showCopyMarkdownCommand = false
        XCTAssertFalse(AppMenuBuilder.hasRequiredMenuItems(in: menuWithMarkdown, appName: "Zentty", config: config))

        let menuWithoutMarkdown = AppMenuBuilder.makeMainMenu(appName: "Zentty", config: config)
        XCTAssertTrue(AppMenuBuilder.hasRequiredMenuItems(in: menuWithoutMarkdown, appName: "Zentty", config: config))

        config.clipboard.showCopyMarkdownCommand = true
        XCTAssertFalse(AppMenuBuilder.hasRequiredMenuItems(in: menuWithoutMarkdown, appName: "Zentty", config: config))
    }

    private func menuItem(for action: Selector, in mainMenu: NSMenu) -> NSMenuItem? {
        for rootItem in mainMenu.items {
            if let found = menuItem(for: action, in: rootItem.submenu) {
                return found
            }
        }

        return nil
    }

    private func menuItem(for action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action {
                return item
            }
            if let found = menuItem(for: action, in: item.submenu) {
                return found
            }
        }

        return nil
    }
}
