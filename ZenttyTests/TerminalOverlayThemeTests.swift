import AppKit
import XCTest
@testable import Zentty

/// Ghostty draws no background in Zentty, so an overlay that does not paint
/// the theme's terminal background shows the system window color instead.
@MainActor
final class TerminalOverlayThemeTests: XCTestCase {
    func test_overlay_paints_the_window_theme_and_follows_theme_changes() throws {
        let controller = MainWindowController(
            runtimeRegistry: PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }),
            overlayAdapterFactory: { _ in OverlayTestAdapter() }
        ).prepareForHostedTesting()
        addTeardownBlock { controller.closeWindowBypassingConfirmation() }
        controller.showWindow(nil)
        let pane = try XCTUnwrap(controller.worklaneStore.activeWorklane?.paneStripState.focusedPaneID)
        _ = try controller.openOverlay(on: pane, options: PaneOverlayIPCOptions(
            command: "", workingDirectory: "/tmp", wait: false,
            follow: false, notify: false, sizePercent: 100, placement: .pane
        ))
        let layer = try XCTUnwrap(controller.overlaySessionForTesting(on: pane)?.view.layer)

        assertPainted(layer, with: controller.currentWindowTheme)

        let translucent = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.8,
                backgroundBlurRadius: nil
            ),
            reduceTransparency: false
        )
        controller.rootViewControllerForTesting.onThemeDidChange?(translucent)

        assertPainted(layer, with: translucent)
        XCTAssertEqual(layer.backgroundColor?.alpha, 1, "the covered pane must not show through")
    }

    private func assertPainted(_ layer: CALayer, with theme: ZenttyTheme, line: UInt = #line) {
        XCTAssertEqual(layer.backgroundColor, theme.windowBackground.withAlphaComponent(1).cgColor, line: line)
        XCTAssertEqual(layer.borderColor, theme.paneBorderFocused.cgColor, line: line)
    }
}
