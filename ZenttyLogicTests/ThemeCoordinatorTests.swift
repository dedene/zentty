import AppKit
import XCTest
@testable import Zentty

@MainActor
final class ThemeCoordinatorTests: AppKitTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.ThemeCoordinator.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        directoryURL = nil
        try super.tearDownWithError()
    }

    func test_refreshTheme_does_not_notify_theme_change_when_resolved_theme_is_unchanged() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let coordinator = makeCoordinator(initialTheme: ZenttyTheme.fallback(for: appearance))
        var themeChangeCount = 0
        var terminalReloadCount = 0
        coordinator.onThemeDidChange = { _, _ in themeChangeCount += 1 }
        coordinator.onTerminalConfigReload = { terminalReloadCount += 1 }

        coordinator.refreshTheme(for: appearance, animated: true, forceTerminalReload: true)

        XCTAssertEqual(themeChangeCount, 0)
        XCTAssertEqual(terminalReloadCount, 1)
    }

    func test_refreshTheme_notifies_once_when_resolved_theme_changes() throws {
        let initialAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let nextAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let coordinator = makeCoordinator(initialTheme: ZenttyTheme.fallback(for: initialAppearance))
        var themeChanges: [(ZenttyTheme, Bool)] = []
        var terminalReloadCount = 0
        coordinator.onThemeDidChange = { theme, animated in themeChanges.append((theme, animated)) }
        coordinator.onTerminalConfigReload = { terminalReloadCount += 1 }

        coordinator.refreshTheme(for: nextAppearance, animated: true)

        XCTAssertEqual(themeChanges.count, 1)
        XCTAssertTrue(themeChanges[0].1)
        XCTAssertEqual(terminalReloadCount, 1)
    }

    func test_refreshTheme_threads_sidebar_selection_emphasis_from_provider() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let configURL = directoryURL.appendingPathComponent("ghostty-config")
        var emphasis: AppConfig.Appearance.SidebarSelectionEmphasis = .subtle
        let coordinator = ThemeCoordinator(
            themeResolver: GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: []),
            initialTheme: ZenttyTheme.fallback(for: appearance),
            sidebarSelectionEmphasisProvider: { emphasis }
        )

        coordinator.refreshTheme(for: appearance, animated: false)
        XCTAssertEqual(coordinator.currentTheme.sidebarSelectionEmphasis, .subtle)

        emphasis = .vivid
        coordinator.refreshTheme(for: appearance, animated: false)
        XCTAssertEqual(coordinator.currentTheme.sidebarSelectionEmphasis, .vivid)
    }

    private func makeCoordinator(initialTheme: ZenttyTheme) -> ThemeCoordinator {
        let configURL = directoryURL.appendingPathComponent("ghostty-config")
        return ThemeCoordinator(
            themeResolver: GhosttyThemeResolver(configURL: configURL, additionalThemeDirectories: []),
            initialTheme: initialTheme
        )
    }
}
