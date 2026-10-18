import XCTest
@testable import Zentty

/// Restored column widths are absolute points captured in the window's own
/// geometry. The store rescales them by `real readableWidth / seed
/// readableWidth` once the window lays out, so the restore seed has to
/// describe that same geometry, including the per-window sidebar.
@MainActor
final class RestoreLayoutSeedTests: XCTestCase {
    private let windowFrame = NSRect(x: 0, y: 0, width: 1728, height: 1084)

    func test_restore_seed_uses_recipe_window_sidebar_over_config_sidebar() {
        let config = makeConfig(sidebarWidth: 314.68)
        let recipeSidebar = WorkspaceRecipe.Sidebar(mode: .pinnedOpen, width: 243)

        let seed = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: windowFrame,
            config: config,
            recipeSidebar: recipeSidebar
        )

        XCTAssertEqual(
            seed.readableWidth,
            liveLayoutContext(config: config, seed: seed, sidebarWidth: 243).readableWidth,
            accuracy: 0.001
        )
    }

    func test_restore_seed_falls_back_to_config_sidebar_without_recipe_sidebar() {
        let config = makeConfig(sidebarWidth: 314.68)

        let seed = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: windowFrame,
            config: config,
            recipeSidebar: nil
        )

        XCTAssertEqual(
            seed.readableWidth,
            liveLayoutContext(config: config, seed: seed, sidebarWidth: 314.68).readableWidth,
            accuracy: 0.001
        )
    }

    func test_restored_multi_column_widths_survive_first_live_layout_when_sidebars_differ() {
        let config = makeConfig(sidebarWidth: 314.68)
        let recipeSidebar = WorkspaceRecipe.Sidebar(mode: .pinnedOpen, width: 243)
        let seed = MainWindowController.initialPaneLayoutContextForRestore(
            initialFrame: windowFrame,
            config: config,
            recipeSidebar: recipeSidebar
        )
        let live = liveLayoutContext(config: config, seed: seed, sidebarWidth: 243)
        let savedColumnWidth = Double(live.readableWidth)
        let imported = WorkspaceRecipeImporter.makeWorklanes(
            from: makeTwoColumnWindow(columnWidth: savedColumnWidth, sidebar: recipeSidebar),
            windowID: WindowID("window-main"),
            layoutContext: seed,
            processEnvironment: [:]
        )
        let store = WorklaneStore(
            worklanes: imported.worklanes,
            layoutContext: seed,
            activeWorklaneID: imported.activeWorklaneID
        )

        store.updateLayoutContext(live)

        let widths = store.activeWorklane?.paneStripState.columns.map(\.width) ?? []
        XCTAssertEqual(widths.count, 2)
        for width in widths {
            XCTAssertEqual(width, CGFloat(savedColumnWidth), accuracy: 0.001)
        }
    }

    private func makeConfig(sidebarWidth: CGFloat) -> AppConfig {
        var config = AppConfig.default
        config.sidebar = AppConfig.Sidebar(width: sidebarWidth, visibility: .pinnedOpen)
        return config
    }

    /// Mirrors `RootViewController.resolveCurrentPaneLayoutContext` once the
    /// window has laid out with the given sidebar.
    private func liveLayoutContext(
        config: AppConfig,
        seed: PaneLayoutContext,
        sidebarWidth: CGFloat
    ) -> PaneLayoutContext {
        config.paneLayout.makeLayoutContext(
            displayClass: seed.displayClass,
            viewportWidth: windowFrame.width - (ShellMetrics.outerInset * 2),
            leadingVisibleInset: SidebarVisibilityController(mode: .pinnedOpen)
                .effectiveLeadingInset(sidebarWidth: sidebarWidth, availableWidth: windowFrame.width),
            sizing: seed.sizing
        )
    }

    private func makeTwoColumnWindow(
        columnWidth: Double,
        sidebar: WorkspaceRecipe.Sidebar
    ) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(
            id: "window-main",
            frame: WorkspaceRecipe.WindowFrame(rect: windowFrame),
            worklanes: [
                WorkspaceRecipe.Worklane(
                    id: "main",
                    title: nil,
                    nextPaneNumber: 3,
                    focusedColumnID: "column-1",
                    columns: ["1", "2"].map { suffix in
                        WorkspaceRecipe.Column(
                            id: "column-\(suffix)",
                            width: columnWidth,
                            focusedPaneID: "pane-\(suffix)",
                            lastFocusedPaneID: "pane-\(suffix)",
                            paneHeights: [1],
                            panes: [WorkspaceRecipe.Pane(id: "pane-\(suffix)", titleSeed: "Shell \(suffix)")]
                        )
                    }
                )
            ],
            activeWorklaneID: "main",
            sidebar: sidebar
        )
    }
}
