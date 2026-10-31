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

    // MARK: - Peek view

    func test_peek_polls_only_while_shown_and_shows_the_tail() throws {
        setUpBar()
        let peek = PillPeekView()
        root.addSubview(peek)
        var reads = 0
        peek.textProvider = { paneID in
            reads += 1
            XCTAssertEqual(paneID, PaneID("a"))
            return (1...15).map { "row \($0)" }.joined(separator: "\n") + "\n\n\n"
        }

        peek.show(item("a"), above: CGRect(x: 600, y: 5, width: 80, height: 28))

        XCTAssertTrue(peek.isPolling)
        XCTAssertEqual(reads, 1, "reads once right away")
        XCTAssertEqual(peek.bodyTextForTesting.split(separator: "\n").first, "row 6")
        XCTAssertEqual(peek.bodyTextForTesting.split(separator: "\n").last, "row 15")
        XCTAssertEqual(peek.nameForTesting, "a")
        XCTAssertEqual(peek.frame.size, PillPeekView.size)
        XCTAssertEqual(peek.frame.maxX, 680, "right edges aligned")
        XCTAssertEqual(peek.frame.minY, 5 + 28 + PillPeekView.anchorGap)

        let polled = expectation(description: "polled again")
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPeekView.pollInterval * 2.5) { polled.fulfill() }
        wait(for: [polled], timeout: 3)
        XCTAssertGreaterThanOrEqual(reads, 2)

        peek.hide()
        XCTAssertFalse(peek.isPolling)
        let readsAtHide = reads
        let idle = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPeekView.pollInterval * 2.5) { idle.fulfill() }
        wait(for: [idle], timeout: 3)
        XCTAssertEqual(reads, readsAtHide, "no reads while hidden")
        XCTAssertTrue(peek.isHidden)
    }

    func test_peek_stays_inside_the_container() {
        let container = CGRect(x: 0, y: 0, width: 700, height: 500)

        let nearLeft = PillPeekView.frame(above: CGRect(x: 10, y: 5, width: 60, height: 28), in: container)
        XCTAssertEqual(nearLeft.minX, PillPeekView.edgeInset)
    }
}
