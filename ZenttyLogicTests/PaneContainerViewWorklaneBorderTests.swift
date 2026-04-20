import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewWorklaneBorderTests: AppKitTestCase {
    private let theme = ZenttyTheme.fallback(for: nil)

    func test_focused_without_worklane_color_uses_theme_border_and_no_glow() {
        let paneView = makePaneView(isFocused: true)

        paneView.render(
            pane: PaneState(id: PaneID("p"), title: "p"),
            emphasis: 1,
            isFocused: true,
            worklaneColor: nil
        )

        XCTAssertEqual(paneView.insetBorderColorToken, token(for: theme.paneBorderFocused))
        XCTAssertNil(paneView.focusGlowColorTokenForTesting)
    }

    func test_focused_with_worklane_color_tints_border_and_activates_glow() {
        let paneView = makePaneView(isFocused: true)

        paneView.render(
            pane: PaneState(id: PaneID("p"), title: "p"),
            emphasis: 1,
            isFocused: true,
            worklaneColor: .blue
        )

        let expectedBorder = WorklaneColor.blue.tint(alpha: WorklaneColor.Alpha.focusedBorder)
        let expectedGlow = WorklaneColor.blue.tint(alpha: WorklaneColor.Alpha.focusedGlow)
        XCTAssertEqual(paneView.insetBorderColorToken, token(for: expectedBorder))
        XCTAssertEqual(paneView.focusGlowColorTokenForTesting, token(for: expectedGlow))
        XCTAssertEqual(paneView.focusGlowFrameForTesting, paneView.bounds)
    }

    func test_unfocused_with_worklane_color_leaves_unfocused_border_and_no_glow() {
        let paneView = makePaneView(isFocused: true)

        paneView.render(
            pane: PaneState(id: PaneID("p"), title: "p"),
            emphasis: 1,
            isFocused: false,
            worklaneColor: .purple
        )

        XCTAssertEqual(paneView.insetBorderColorToken, token(for: theme.paneBorderUnfocused))
        XCTAssertNil(paneView.focusGlowColorTokenForTesting)
    }

    func test_clearing_worklane_color_reverts_border_and_disables_glow() {
        let paneView = makePaneView(isFocused: true)
        let paneState = PaneState(id: PaneID("p"), title: "p")

        paneView.render(pane: paneState, emphasis: 1, isFocused: true, worklaneColor: .green)
        XCTAssertNotNil(paneView.focusGlowColorTokenForTesting)

        paneView.render(pane: paneState, emphasis: 1, isFocused: true, worklaneColor: nil)
        XCTAssertEqual(paneView.insetBorderColorToken, token(for: theme.paneBorderFocused))
        XCTAssertNil(paneView.focusGlowColorTokenForTesting)
    }

    // MARK: - Helpers

    private func makePaneView(isFocused: Bool) -> PaneContainerView {
        let pane = PaneState(id: PaneID("p"), title: "p")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: InertTerminalAdapter(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        return PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: isFocused,
            runtime: runtime,
            theme: theme,
            backingScaleFactorProvider: { 2 }
        )
    }

    private func token(for color: NSColor) -> String? {
        NSColor(cgColor: color.cgColor)?.themeToken
    }
}

@MainActor
private final class InertTerminalAdapter: TerminalAdapter, TerminalSearchControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private let terminalView = NSView()

    func makeTerminalView() -> NSView { terminalView }
    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func showSearch() { searchDidChange?(.started(needle: nil)) }
    func useSelectionForFind() { searchDidChange?(.started(needle: nil)) }
    func updateSearch(needle: String) {}
    func findNext() {}
    func findPrevious() {}
    func endSearch() { searchDidChange?(.ended) }
}
