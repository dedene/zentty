import AppKit
import XCTest
@testable import Zentty

/// Pill bar and peek views, detached: click restores, a drag up promotes,
/// hover drives the peek, "+N" menus the oldest pills.
@MainActor
final class PillBarViewTests: AppKitTestCase {
    private var root: NSView!
    private var barView: PillBarView!
    private var clicked: [PaneID] = []
    private var promoted: [(PaneID, CGPoint)] = []
    private var peeks: [PaneID?] = []

    private func setUpBar() {
        FloatMotion.reduceMotionOverride = true
        root = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        barView = PillBarView(frame: CGRect(x: 0, y: 0, width: 700, height: PillBarLayout.barHeight))
        root.addSubview(barView)
        clicked = []
        promoted = []
        peeks = []
        barView.onPillClicked = { [unowned self] in clicked.append($0) }
        barView.onPillPromoted = { [unowned self] in promoted.append(($0, $1)) }
        barView.onPeekChanged = { [unowned self] item, _ in peeks.append(item?.paneID) }
        addTeardownBlock {
            MainActor.assumeIsolated {
                FloatMotion.reduceMotionOverride = nil
            }
        }
    }

    private func item(_ id: String, attention: WorklaneAttentionState? = nil) -> PillBarItem {
        PillBarItem(paneID: PaneID(id), name: id, subtitle: "~", attention: attention)
    }

    private func render(_ ids: [String]) {
        barView.render(PillBarContent(items: ids.map { item($0) }), theme: ZenttyTheme.fallback(for: nil))
        barView.layoutSubtreeIfNeeded()
    }

    private func pillFrame(_ id: String) throws -> CGRect {
        try XCTUnwrap(barView.pillViewForTesting(PaneID(id))).frame
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    // MARK: - Closing

    func test_a_closing_pill_fades_in_place_and_keeps_the_bar_up_until_it_is_gone() throws {
        setUpBar()
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        addTeardownBlock { MainActor.assumeIsolated { window.close() } }
        render(["a", "b"])
        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("a")))
        let point = CGPoint(x: pill.frame.midX, y: pill.frame.midY)

        barView.render(PillBarContent(items: []), theme: ZenttyTheme.fallback(for: nil), closing: [PaneID("a")])

        XCTAssertNil(barView.pillViewForTesting(PaneID("a")), "no longer a pill")
        XCTAssertEqual(barView.closingPaneIDsForTesting, [PaneID("a")])
        XCTAssertIdentical(pill.superview, barView, "still drawing")
        XCTAssertFalse(barView.isHidden, "the bar stays up for the fade")
        XCTAssertNil(barView.hitTest(barView.convert(point, to: root)), "a fading pill takes no clicks")
        let fade = try XCTUnwrap(pill.layer?.animation(forKey: PillBarView.closingAnimationKey) as? CAAnimationGroup)
        XCTAssertEqual(fade.animations?.count, 1, "Reduce Motion: the fade only")
        XCTAssertEqual(fade.duration, FloatMotion.reducedDuration, accuracy: 0.0001)
        XCTAssertNil(barView.pillViewForTesting(PaneID("b")), "b left without a close: gone at once")

        barView.finishClosing(PaneID("a"))
        XCTAssertNil(pill.superview)
        XCTAssertTrue(barView.isHidden)
    }

    func test_a_closing_pill_shrinks_with_the_float_close_motion() throws {
        setUpBar()
        FloatMotion.reduceMotionOverride = false
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        addTeardownBlock { MainActor.assumeIsolated { window.close() } }
        render(["a"])
        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("a")))

        barView.render(PillBarContent(items: []), theme: ZenttyTheme.fallback(for: nil), closing: [PaneID("a")])

        let fade = try XCTUnwrap(pill.layer?.animation(forKey: PillBarView.closingAnimationKey) as? CAAnimationGroup)
        XCTAssertEqual(fade.duration, FloatLayerView.TransitionMotion.closeDuration, accuracy: 0.0001)
        let transform = try XCTUnwrap(fade.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "transform" })
        let end = try XCTUnwrap((transform.toValue as? NSValue)?.caTransform3DValue)
        XCTAssertEqual(end.m11, FloatLayerView.TransitionMotion.closeScale, accuracy: 0.0001, "96%")
    }

    func test_a_pill_that_returns_drops_its_fading_copy() throws {
        setUpBar()
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        addTeardownBlock { MainActor.assumeIsolated { window.close() } }
        render(["a"])
        let fading = try XCTUnwrap(barView.pillViewForTesting(PaneID("a")))
        barView.render(PillBarContent(items: []), theme: ZenttyTheme.fallback(for: nil), closing: [PaneID("a")])

        render(["a"])

        XCTAssertNil(fading.superview)
        XCTAssertTrue(barView.closingPaneIDsForTesting.isEmpty)
        XCTAssertNotNil(barView.pillViewForTesting(PaneID("a")))
    }

    // MARK: - Visibility and layout

    func test_bar_is_hidden_without_pills_and_shows_one_pill_per_item() throws {
        setUpBar()
        render([])
        XCTAssertTrue(barView.isHidden)
        XCTAssertNil(barView.hitTest(CGPoint(x: 650, y: 20)))

        render(["a", "b"])
        XCTAssertFalse(barView.isHidden)
        XCTAssertLessThan(try pillFrame("a").maxX, try pillFrame("b").minX, "newest rightmost")
        XCTAssertEqual(try pillFrame("b").maxX, barView.bounds.maxX - PillBarLayout.horizontalInset)
    }

    func test_empty_bar_area_is_hit_transparent() throws {
        setUpBar()
        render(["a"])
        let pill = try pillFrame("a")

        XCTAssertNil(barView.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertTrue(barView.hitTest(CGPoint(x: pill.midX, y: pill.midY)) === barView)
    }

    func test_too_many_pills_overflow_into_a_menu_of_the_oldest() throws {
        setUpBar()
        render((0..<20).map { "pane-with-a-long-name-\($0)" })

        let overflow = barView.overflowViewForTesting
        XCTAssertFalse(overflow.isHidden)
        XCTAssertGreaterThan(overflow.count, 0)
        XCTAssertTrue(try XCTUnwrap(barView.pillViewForTesting(PaneID("pane-with-a-long-name-0"))).isHidden)
        XCTAssertFalse(try XCTUnwrap(barView.pillViewForTesting(PaneID("pane-with-a-long-name-19"))).isHidden)

        let menu = barView.makeOverflowMenu()
        XCTAssertEqual(menu.items.count, overflow.count)
        XCTAssertEqual(menu.items.first?.title, "pane-with-a-long-name-0 · ~")
        let first = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(first.action), to: first.target, from: first))
        XCTAssertEqual(clicked, [PaneID("pane-with-a-long-name-0")])
    }

    func test_overflow_button_opens_the_menu() throws {
        setUpBar()
        render((0..<20).map { "pane-with-a-long-name-\($0)" })
        var presented: NSMenu?
        barView.overflowMenuPresenter = { menu, _ in presented = menu }

        barView.overflowViewForTesting.mouseDown(with: try mouse(.leftMouseDown, at: .zero))

        XCTAssertEqual(presented?.items.count, barView.overflowViewForTesting.count)
    }

    // MARK: - Click and drag

    func test_click_restores_the_pill() throws {
        setUpBar()
        render(["a", "b"])
        let pill = try pillFrame("a")
        let point = CGPoint(x: pill.midX, y: pill.midY)

        barView.mouseDown(with: try mouse(.leftMouseDown, at: point))
        barView.mouseUp(with: try mouse(.leftMouseUp, at: point))

        XCTAssertEqual(clicked, [PaneID("a")])
        XCTAssertTrue(promoted.isEmpty)
    }

    func test_drag_up_out_of_the_bar_promotes_at_the_release_point() throws {
        setUpBar()
        render(["a"])
        let pill = try pillFrame("a")
        let start = CGPoint(x: pill.midX, y: pill.midY)
        let release = CGPoint(x: 100, y: 300)

        barView.mouseDown(with: try mouse(.leftMouseDown, at: start))
        barView.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x, y: 120)))
        XCTAssertEqual(try pillFrame("a").midY, 120, accuracy: 0.5, "the pill follows the pointer")
        XCTAssertTrue(barView.hitTest(CGPoint(x: 5, y: 5)) === barView, "the drag owns the mouse")
        barView.mouseUp(with: try mouse(.leftMouseUp, at: release))

        XCTAssertTrue(clicked.isEmpty)
        XCTAssertEqual(promoted.map(\.0), [PaneID("a")])
        XCTAssertEqual(promoted.first?.1, release)
    }

    func test_short_drag_springs_back_without_promoting() throws {
        setUpBar()
        render(["a"])
        let slot = try pillFrame("a")
        let start = CGPoint(x: slot.midX, y: slot.midY)

        barView.mouseDown(with: try mouse(.leftMouseDown, at: start))
        barView.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x - 30, y: start.y + 20)))
        barView.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: start.x - 30, y: start.y + 20)))

        XCTAssertTrue(clicked.isEmpty, "a drag is not a click")
        XCTAssertTrue(promoted.isEmpty)
        XCTAssertEqual(try pillFrame("a"), slot)
        XCTAssertEqual(barView.pillViewForTesting(PaneID("a"))?.alphaValue, 1)
    }

    func test_movement_under_the_threshold_is_still_a_click() throws {
        setUpBar()
        render(["a"])
        let slot = try pillFrame("a")
        let start = CGPoint(x: slot.midX, y: slot.midY)

        barView.mouseDown(with: try mouse(.leftMouseDown, at: start))
        barView.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x + 2, y: start.y + 2)))
        barView.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: start.x + 2, y: start.y + 2)))

        XCTAssertEqual(clicked, [PaneID("a")])
        XCTAssertEqual(try pillFrame("a"), slot)
    }

    // MARK: - Hover

    func test_hover_reports_the_pill_and_a_drag_or_removal_ends_the_peek() throws {
        setUpBar()
        render(["a", "b"])
        let pillA = try XCTUnwrap(barView.pillViewForTesting(PaneID("a")))

        pillA.setHovered(true)
        XCTAssertEqual(peeks, [PaneID("a")])

        render(["b"])
        XCTAssertEqual(peeks, [PaneID("a"), nil], "a vanished pill ends its peek")

        let pillB = try XCTUnwrap(barView.pillViewForTesting(PaneID("b")))
        pillB.setHovered(true)
        let start = CGPoint(x: pillB.frame.midX, y: pillB.frame.midY)
        barView.mouseDown(with: try mouse(.leftMouseDown, at: start))
        barView.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y + 30)))
        XCTAssertEqual(peeks.last, .some(nil), "dragging hides the peek")
    }

    // MARK: - Appearance and accessibility

    func test_needs_input_pill_has_an_amber_border_and_a_voiceover_label() throws {
        setUpBar()
        let theme = ZenttyTheme.fallback(for: nil)
        barView.render(PillBarContent(items: [item("agent", attention: .needsInput)]), theme: theme)
        barView.layoutSubtreeIfNeeded()
        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("agent")))

        XCTAssertEqual(
            pill.layer?.borderColor.map { NSColor(cgColor: $0)?.themeToken },
            theme.statusNeedsInput.withAlphaComponent(0.65).themeToken
        )
        XCTAssertEqual(pill.accessibilityRole(), .button)
        XCTAssertEqual(pill.accessibilityLabel(), "agent, Needs input, minimized")
        XCTAssertTrue(pill.accessibilityPerformPress())
        XCTAssertEqual(clicked, [PaneID("agent")])
    }

    func test_pill_offers_picture_in_picture_and_close_to_voiceover() throws {
        setUpBar()
        var actions: [(PaneID, PaneBorderAction)] = []
        barView.onPillActionRequested = { actions.append(($0, $1)) }
        render(["agent"])
        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("agent")))

        let custom = pill.accessibilityCustomActions() ?? []
        XCTAssertEqual(custom.map(\.name), ["Picture in picture", "Close pane"])
        for action in custom {
            XCTAssertTrue(action.handler?() ?? false)
        }

        XCTAssertEqual(actions.map(\.0), [PaneID("agent"), PaneID("agent")])
        XCTAssertEqual(actions.map(\.1), [.pip, .close])
        XCTAssertEqual(clicked, [], "custom actions never restore")
    }

    func test_working_pill_pulses_its_dot_unless_motion_is_reduced() throws {
        setUpBar()
        FloatMotion.reduceMotionOverride = false
        let theme = ZenttyTheme.fallback(for: nil)
        barView.render(PillBarContent(items: [item("busy", attention: .running)]), theme: theme)
        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("busy")))
        XCTAssertNotNil(pill.dotLayerForTesting.animation(forKey: PillView.pulseKey))

        barView.render(PillBarContent(items: [item("busy", attention: .ready)]), theme: theme)
        XCTAssertNil(pill.dotLayerForTesting.animation(forKey: PillView.pulseKey))
    }

    func test_compressed_pills_hide_their_subtitle() throws {
        setUpBar()
        render((0..<6).map { "a-rather-long-pane-name-\($0)" })

        let pill = try XCTUnwrap(barView.pillViewForTesting(PaneID("a-rather-long-pane-name-5")))
        XCTAssertEqual(pill.style, .compact)
        XCTAssertFalse(pill.isSubtitleShownForTesting)
    }

    func test_overflow_label_counts_in_the_singular_and_plural() {
        XCTAssertEqual(PillOverflowView.accessibilityLabel(count: 1), "1 more minimized pane")
        XCTAssertEqual(PillOverflowView.accessibilityLabel(count: 3), "3 more minimized panes")
    }

    // MARK: - Peek placement

    func test_peek_sits_above_the_pill_with_right_edges_aligned() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 232, height: 140)

        let frame = PillPeekView.frame(size: size, above: CGRect(x: 600, y: 5, width: 80, height: 28), in: container)

        XCTAssertEqual(frame, CGRect(x: 680 - 232, y: 5 + 28 + PillPeekView.anchorGap, width: 232, height: 140))
    }

    func test_peek_stays_inside_the_container() {
        let container = CGRect(x: 40, y: 0, width: 700, height: 500)
        let size = CGSize(width: 232, height: 140)

        let nearLeft = PillPeekView.frame(size: size, above: CGRect(x: 50, y: 5, width: 60, height: 28), in: container)
        XCTAssertEqual(nearLeft.minX, 40 + PillPeekView.edgeInset)

        let nearRight = PillPeekView.frame(size: size, above: CGRect(x: 700, y: 5, width: 60, height: 28), in: container)
        XCTAssertEqual(nearRight.maxX, container.maxX - PillPeekView.edgeInset)

        let short = CGRect(x: 0, y: 0, width: 700, height: 160)
        let clamped = PillPeekView.frame(size: size, above: CGRect(x: 300, y: 5, width: 60, height: 28), in: short)
        XCTAssertEqual(clamped.maxY, short.maxY - PillPeekView.edgeInset, "no room above: kept on screen")
    }
}
