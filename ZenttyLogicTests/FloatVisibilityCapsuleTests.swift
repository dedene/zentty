import AppKit
import XCTest
@testable import Zentty

/// The title-bar hide-all capsule: eye/eye-slash, divider, count of floats +
/// PiPs, hidden at zero, toggles `floatsHidden`.
@MainActor
final class FloatVisibilityCapsuleTests: XCTestCase {
    private let worklaneID = WorklaneID("wl_main")

    private func makeWorklane(modes: [FloatingPaneMode], hidden: Bool = false) -> WorklaneState {
        var worklane = WorklaneState(
            id: worklaneID,
            title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: PaneID("pn_tile"), title: "tile")], focusedPaneID: PaneID("pn_tile")),
            nextPaneNumber: 2
        )
        worklane.floatingPanes = modes.enumerated().map { index, mode in
            FloatingPaneState(
                pane: PaneState(id: PaneID("pn_float_\(index)"), title: "float \(index)"),
                mode: mode,
                floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
                stackOrder: index,
                origin: nil,
                sequence: index
            )
        }
        worklane.floatsHidden = hidden
        return worklane
    }

    // MARK: - State

    func test_no_floats_or_only_pills_hides_the_capsule() {
        XCTAssertNil(FloatVisibilityCapsuleState(worklane: nil))
        XCTAssertNil(FloatVisibilityCapsuleState(worklane: makeWorklane(modes: [])))
        XCTAssertNil(FloatVisibilityCapsuleState(worklane: makeWorklane(modes: [.minimized(order: 0), .minimized(order: 1)])))
    }

    func test_count_is_floats_plus_pips_and_ignores_pills() throws {
        let state = try XCTUnwrap(FloatVisibilityCapsuleState(worklane: makeWorklane(modes: [
            .floating,
            .pip(corner: .bottomRight, order: 0),
            .minimized(order: 0),
        ])))

        XCTAssertEqual(state.count, 2)
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.symbolName, "eye")
        XCTAssertEqual(state.actionTitle, "Hide floating panes")
    }

    func test_hidden_floats_still_count_and_show_the_eye_slash() throws {
        let state = try XCTUnwrap(FloatVisibilityCapsuleState(worklane: makeWorklane(modes: [.floating], hidden: true)))

        XCTAssertEqual(state.count, 1)
        XCTAssertTrue(state.isHidden)
        XCTAssertEqual(state.symbolName, "eye.slash")
        XCTAssertEqual(state.actionTitle, "Show floating panes")
    }

    func test_large_counts_cap_at_99_plus() {
        XCTAssertEqual(FloatVisibilityCapsuleState(count: 7, isHidden: false).countText, "7")
        XCTAssertEqual(FloatVisibilityCapsuleState(count: 120, isHidden: false).countText, "99+")
    }

    // MARK: - View

    /// The shortcut comes from the registry (rebindable) and is spelled like
    /// every other chrome tooltip.
    func test_tooltip_names_the_action_and_its_shortcut() throws {
        let manager = ShortcutManager(shortcuts: .default)
        let shortcut = try XCTUnwrap(manager.shortcut(for: .toggleFloatsHidden))
        XCTAssertEqual(shortcut.key, .character("."))
        XCTAssertEqual(shortcut.modifiers, [.command, .option])
        let capsule = FloatVisibilityCapsuleView(frame: .zero)
        capsule.updateShortcutTooltip(manager)

        capsule.render(FloatVisibilityCapsuleState(count: 2, isHidden: false))
        XCTAssertEqual(capsule.toolTip, "Hide floating panes (\(shortcut.displayString))")
        XCTAssertEqual(capsule.accessibilityLabel(), "Hide floating panes")

        capsule.render(FloatVisibilityCapsuleState(count: 2, isHidden: true))
        XCTAssertEqual(capsule.toolTip, "Show floating panes (\(shortcut.displayString))")
        XCTAssertEqual(capsule.accessibilityLabel(), "Show floating panes")
    }

    func test_hidden_state_tints_the_icon_with_the_accent() {
        let theme = ZenttyTheme.fallback(for: nil)
        let capsule = FloatVisibilityCapsuleView(frame: .zero)
        capsule.apply(theme: theme, animated: false)

        capsule.render(FloatVisibilityCapsuleState(count: 1, isHidden: false))
        XCTAssertEqual(capsule.iconTint, theme.openWithChromePrimaryTint)

        capsule.render(FloatVisibilityCapsuleState(count: 1, isHidden: true))
        XCTAssertEqual(capsule.iconTint, theme.statusRunning)
    }

    func test_click_anywhere_on_the_capsule_toggles() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let capsule = FloatVisibilityCapsuleView(frame: NSRect(x: 20, y: 5, width: FloatVisibilityCapsuleView.width, height: 30))
        host.addSubview(capsule)
        capsule.render(FloatVisibilityCapsuleState(count: 3, isHidden: false))
        capsule.layoutSubtreeIfNeeded()
        var toggles = 0
        capsule.onToggle = { toggles += 1 }

        XCTAssertTrue(host.hitTest(NSPoint(x: 20 + 10, y: 20)) === capsule, "icon segment")
        XCTAssertTrue(host.hitTest(NSPoint(x: 20 + FloatVisibilityCapsuleView.width - 8, y: 20)) === capsule, "count segment")
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 20)).flatMap { $0 === capsule ? $0 : nil })
        capsule.performClick(nil)

        XCTAssertEqual(toggles, 1)
    }

    // MARK: - Window chrome

    func test_window_chrome_hides_capsule_without_floats() {
        let view = WindowChromeView(frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight))

        view.render(floatVisibility: nil)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.floatVisibilityControlFrame, .zero)
        XCTAssertTrue(view.floatVisibilityCapsuleForTesting.isHidden)
    }

    func test_window_chrome_places_capsule_before_the_server_capsule_and_reserves_lane() {
        let view = WindowChromeView(frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight))
        view.render(server: WindowChromeServerState(title: "localhost:5173", icon: nil, isPrimaryEnabled: true, isMenuEnabled: true))
        view.render(openWith: WindowChromeOpenWithState(title: "Cursor", icon: nil, isPrimaryEnabled: true, isMenuEnabled: true))

        view.render(floatVisibility: FloatVisibilityCapsuleState(count: 2, isHidden: false))
        view.layoutSubtreeIfNeeded()

        let capsule = view.floatVisibilityControlFrame
        XCTAssertEqual(capsule.width, FloatVisibilityCapsuleView.width)
        XCTAssertEqual(capsule.height, view.serverControlFrame.height, "same height as the other capsules")
        XCTAssertEqual(capsule.midY, view.serverControlFrame.midY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(capsule.maxX, view.serverControlFrame.minX - 8)
        XCTAssertLessThanOrEqual(view.visibleLaneFrame.maxX, capsule.minX - 8)
    }

    func test_window_chrome_capsule_without_server_sits_before_open_with() {
        let view = WindowChromeView(frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight))
        view.render(openWith: WindowChromeOpenWithState(title: "Cursor", icon: nil, isPrimaryEnabled: true, isMenuEnabled: true))

        view.render(floatVisibility: FloatVisibilityCapsuleState(count: 1, isHidden: true))
        view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(view.floatVisibilityControlFrame.maxX, view.openWithControlFrame.minX - 8)
        XCTAssertGreaterThan(view.floatVisibilityControlFrame.width, 0)
    }

    func test_window_chrome_forwards_capsule_click() {
        let view = WindowChromeView(frame: NSRect(x: 0, y: 0, width: 760, height: WindowChromeView.preferredHeight))
        var toggles = 0
        view.onFloatVisibilityToggle = { toggles += 1 }
        view.render(floatVisibility: FloatVisibilityCapsuleState(count: 1, isHidden: false))

        view.floatVisibilityCapsuleForTesting.performClick(nil)

        XCTAssertEqual(toggles, 1)
    }
}
