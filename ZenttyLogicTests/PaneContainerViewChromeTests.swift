import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewChromeTests: AppKitTestCase {
    private func makeContainer(
        terminalView: NSView = NSView(),
        width: CGFloat = 600,
        isFocused: Bool = false,
        theme: ZenttyTheme = ZenttyTheme.fallback(for: nil)
    ) -> (PaneContainerView, PaneState) {
        let pane = PaneState(id: PaneID("chrome"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: ChromeTerminalAdapterSpy(terminalView: terminalView),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let container = PaneContainerView(
            pane: pane,
            width: width,
            height: 400,
            emphasis: 1,
            isFocused: isFocused,
            runtime: runtime,
            theme: theme,
            backingScaleFactorProvider: { 1 }
        )
        return (container, pane)
    }

    private func translucentTheme() -> ZenttyTheme {
        ZenttyTheme(
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
    }

    func test_float_chrome_cuts_trailing_border_gap_for_actions() throws {
        let (container, _) = makeContainer()
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()

        let actionsFrame = try XCTUnwrap(container.borderActionsFrameForTesting)
        XCTAssertEqual(actionsFrame.size, CGSize(width: 86, height: 16))
        XCTAssertEqual(
            container.trailingBorderGapWidthForTesting,
            actionsFrame.width + (PaneBorderActionsLayout.gapPadding * 2),
            accuracy: 0.001
        )
        XCTAssertEqual(actionsFrame.maxX, container.bounds.maxX - PaneBorderActionsLayout.trailingInset, accuracy: 0.001)
    }

    func test_tile_actions_hidden_until_hover_or_focus() {
        let (container, pane) = makeContainer()
        container.layoutSubtreeIfNeeded()
        XCTAssertNil(container.borderActionsFrameForTesting)
        XCTAssertEqual(container.trailingBorderGapWidthForTesting, 0)

        container.setHovered(true)
        XCTAssertNotNil(container.borderActionsFrameForTesting)
        XCTAssertNotNil(container.borderActionsViewForTesting.buttonForTesting(.float))
        XCTAssertNotNil(container.borderActionsViewForTesting.buttonForTesting(.close))
        XCTAssertNil(container.borderActionsViewForTesting.buttonForTesting(.pip))

        container.setHovered(false)
        XCTAssertNil(container.borderActionsFrameForTesting)

        container.render(pane: pane, emphasis: 1, isFocused: true)
        XCTAssertNotNil(container.borderActionsFrameForTesting)
    }

    func test_sole_tile_shows_no_actions_even_hovered_and_focused() {
        let (container, pane) = makeContainer(isFocused: true)
        container.isSoleTile = true
        container.setHovered(true)
        container.render(pane: pane, emphasis: 1, isFocused: true)
        container.layoutSubtreeIfNeeded()

        XCTAssertNil(container.borderActionsFrameForTesting)
        XCTAssertEqual(container.trailingBorderGapWidthForTesting, 0)

        container.isSoleTile = false
        XCTAssertNotNil(container.borderActionsFrameForTesting, "a second tile brings them back")
    }

    func test_sole_tile_flag_does_not_strip_float_actions() {
        let (container, _) = makeContainer()
        container.chromeKind = .float
        container.isSoleTile = true
        container.layoutSubtreeIfNeeded()

        XCTAssertNotNil(container.borderActionsViewForTesting.buttonForTesting(.dock))
    }

    func test_narrow_tile_keeps_legend_and_drops_actions() {
        let (container, _) = makeContainer(width: 140, isFocused: true)
        container.layoutSubtreeIfNeeded()

        XCTAssertNil(container.borderActionsFrameForTesting)
    }

    func test_legend_truncates_before_actions() throws {
        let (container, pane) = makeContainer(width: 320)
        container.chromeKind = .float
        container.render(
            pane: pane,
            emphasis: 1,
            isFocused: true,
            borderContext: PaneBorderContextDisplayModel(
                text: "~/Development/Personal/zentty/a/very/long/path/that/never/fits/here"
            )
        )
        container.layoutSubtreeIfNeeded()

        let legend = try XCTUnwrap(container.paneBorderContextFrameForTesting)
        let actions = try XCTUnwrap(container.borderActionsFrameForTesting)
        XCTAssertLessThanOrEqual(legend.maxX, actions.minX - PaneBorderActionsLayout.legendSpacing + 0.001)
    }

    func test_action_button_reports_action() throws {
        let (container, _) = makeContainer()
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()
        var received: [PaneBorderAction] = []
        container.onBorderActionRequested = { received.append($0) }

        let button = try XCTUnwrap(container.borderActionsViewForTesting.buttonForTesting(.pip))
        button.performClick(nil)

        XCTAssertEqual(received, [.pip])
    }

    func test_border_chrome_hit_test_finds_button_above_the_pane_edge() throws {
        let (container, _) = makeContainer()
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(container.borderActionsFrameForTesting)
        let button = try XCTUnwrap(container.borderActionsViewForTesting.buttonForTesting(.close))
        let closeFrame = container.convert(button.frame, from: container.borderActionsViewForTesting)
        // Upper half of the button sits outside the pane's bounds.
        let point = CGPoint(x: closeFrame.midX, y: actions.maxY - 2)
        XCTAssertGreaterThan(point.y, container.bounds.maxY)

        XCTAssertTrue(container.hitTestBorderChrome(point, from: container) === button)
    }

    func test_float_chrome_uses_opaque_backdrop_in_translucent_theme() throws {
        let (container, _) = makeContainer(theme: translucentTheme())
        let tileColors = container.backgroundColorsForTesting
        XCTAssertEqual(try XCTUnwrap(tileColors.contentClip).alpha, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tileColors.terminalHost).alpha, 0, accuracy: 0.001)

        container.chromeKind = .float

        let floatColors = container.backgroundColorsForTesting
        XCTAssertEqual(try XCTUnwrap(floatColors.contentClip).alpha, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(floatColors.terminalHost).alpha, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(floatColors.pane).alpha, 1, accuracy: 0.001)
    }

    func test_pip_chrome_uses_opaque_backdrop_in_translucent_theme() throws {
        let (container, _) = makeContainer(theme: translucentTheme())

        container.chromeKind = .pip

        let colors = container.backgroundColorsForTesting
        XCTAssertEqual(try XCTUnwrap(colors.contentClip).alpha, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(colors.terminalHost).alpha, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(colors.pane).alpha, 1, accuracy: 0.001)

        container.chromeKind = .tile
        XCTAssertEqual(try XCTUnwrap(container.backgroundColorsForTesting.terminalHost).alpha, 0, accuracy: 0.001,
                       "docked again, the tile is see-through like its neighbours")
    }

    func test_float_chrome_has_no_container_shadow() {
        let (container, _) = makeContainer()
        XCTAssertGreaterThan(container.layer?.shadowOpacity ?? 0, 0)

        container.chromeKind = .float

        XCTAssertEqual(container.layer?.shadowOpacity ?? -1, 0)
    }

    func test_actions_rect_is_mouse_suppressed_for_terminal() throws {
        let terminalView = SuppressionSpyTerminalView()
        let (container, _) = makeContainer(terminalView: terminalView)
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()

        let actions = try XCTUnwrap(container.borderActionsFrameForTesting)
        let visibleActions = actions.intersection(container.bounds)
        let host = try XCTUnwrap(terminalView.superview)
        let expected = host.convert(visibleActions, from: container)
        XCTAssertTrue(
            terminalView.lastRects.contains { $0.contains(expected) },
            "suppression rects \(terminalView.lastRects) should contain \(expected)"
        )
    }

    func test_float_legend_renders_bold_name_dot_cwd() throws {
        let (container, pane) = makeContainer()
        container.chromeKind = .float
        var model = PaneBorderContextDisplayModel(text: "~/x")
        model.displayName = "pnpm dev"
        container.render(pane: pane, emphasis: 1, isFocused: false, borderContext: model)
        container.layoutSubtreeIfNeeded()

        let text = try XCTUnwrap(container.paneBorderContextAttributedTextForTesting)
        XCTAssertEqual(text.string, "pnpm dev · ~/x")
        let nameFont = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let cwdFont = try XCTUnwrap(text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(nameFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNotEqual(nameFont, cwdFont)
        let natural = try XCTUnwrap(container.paneBorderContextNaturalTextWidthForTesting)
        let measured = ceil(text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width)
        XCTAssertEqual(natural, measured, accuracy: 0.5, "the legend is sized from the same attributed string")
    }

    func test_buttons_have_accessibility_labels() throws {
        let (container, _) = makeContainer()
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()

        for action in PaneBorderActionsLayout.actions(for: .float) {
            let button = try XCTUnwrap(container.borderActionsViewForTesting.buttonForTesting(action))
            XCTAssertEqual(button.accessibilityLabel(), action.accessibilityLabel)
        }
        XCTAssertEqual(
            container.borderActionsViewForTesting.buttonForTesting(.dock)?.accessibilityLabel(),
            "Dock into layout"
        )
    }

    /// Scaled down in a PiP the container's own legend would be unreadable:
    /// the PiP host draws the legend (on hover) and the name unscaled.
    func test_pip_container_draws_no_legend_of_its_own() {
        let (container, _) = makeContainer()
        container.chromeKind = .pip
        container.layoutSubtreeIfNeeded()
        XCTAssertNil(container.borderActionsFrameForTesting)

        container.setHovered(true)

        XCTAssertNil(container.borderActionsFrameForTesting)
        XCTAssertTrue(container.borderActionsViewForTesting.isHidden)
    }
}

@MainActor
private final class SuppressionSpyTerminalView: NSView, TerminalMouseInteractionSuppressionControlling {
    private(set) var lastRects: [CGRect] = []

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        lastRects = rects
    }
}

@MainActor
private final class ChromeTerminalAdapterSpy: TerminalAdapter {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private let terminalView: NSView

    init(terminalView: NSView) {
        self.terminalView = terminalView
    }

    func makeTerminalView() -> NSView { terminalView }
    func startSession(using request: TerminalSessionRequest) throws {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func sendText(_ text: String) {}
    func close() {}
}
