import AppKit
import XCTest
@testable import Zentty

/// The PiP host on its own: bounds scaling, click ownership, the hover
/// legend, the status strip and the needs-input ring.
@MainActor
final class PipContainerViewTests: AppKitTestCase {
    private let paneID = PaneID("pip")
    private let pipFrame = CGRect(x: 600, y: 60, width: 232, height: 145)
    private let contentSize = CGSize(width: 800, height: 500)

    // MARK: - Pure chrome

    func test_legend_sits_on_the_top_edge_right_aligned() {
        let bounds = CGRect(x: 0, y: 0, width: 232, height: 145)
        let legend = PipChrome.legendFrame(in: bounds)
        let size = PaneBorderActionsLayout.size(for: [.restore, .minimize, .close])

        XCTAssertEqual(legend.size, size)
        XCTAssertEqual(legend.maxX, bounds.maxX - PipChrome.legendTrailingInset)
        XCTAssertEqual(legend.midY, bounds.maxY, "centred on the top edge")
        XCTAssertEqual(PipChrome.hoverRect(in: bounds), bounds.union(legend), "hover covers the half that sticks out")
    }

    func test_pip_legend_is_restore_minimize_close() {
        XCTAssertEqual(PipChrome.actions, [.restore, .minimize, .close])
    }

    func test_status_strip_is_the_bottom_18pt() {
        let strip = PipChrome.statusStripFrame(in: CGRect(x: 0, y: 0, width: 232, height: 145))
        XCTAssertEqual(strip, CGRect(x: 0, y: 0, width: 232, height: 18))
    }

    func test_ring_only_for_needs_input() {
        XCTAssertTrue(PipChrome.showsRing(for: item(.needsInput)))
        XCTAssertFalse(PipChrome.showsRing(for: item(.running)))
        XCTAssertFalse(PipChrome.showsRing(for: item(nil)))
        XCTAssertFalse(PipChrome.showsRing(for: nil))
    }

    func test_accessibility_label_names_status_and_mode() {
        XCTAssertEqual(PipChrome.accessibilityLabel(for: item(.needsInput)), "claude, Needs input, picture in picture")
        XCTAssertEqual(PipChrome.accessibilityLabel(for: item(nil)), "claude, picture in picture")
    }

    func test_rect_mapping_carries_the_outset_along() {
        let pane = CGRect(x: 100, y: 100, width: 800, height: 500)
        let outset = pane.insetBy(dx: -10, dy: -10)
        let target = CGRect(x: 600, y: 60, width: 200, height: 125)

        let mapped = FloatLayerView.rect(outset, mapping: pane, onto: target)

        XCTAssertEqual(mapped.minX, 597.5, accuracy: 0.001)
        XCTAssertEqual(mapped.minY, 57.5, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 205, accuracy: 0.001)
        XCTAssertEqual(mapped.height, 130, accuracy: 0.001)
        XCTAssertEqual(FloatLayerView.rect(pane, mapping: pane, onto: target), target)
    }

    // MARK: - View

    func test_scale_lives_on_the_scale_view_and_survives_frame_changes() {
        let pip = makePip()
        let scaleView = pip.scaleViewForTesting

        XCTAssertEqual(pip.bounds.size, pipFrame.size, "chrome stays unscaled")
        XCTAssertEqual(scaleView.frame.size, pipFrame.size)
        XCTAssertEqual(scaleView.bounds.width, contentSize.width, accuracy: 0.001, "the picture keeps the float size")
        XCTAssertEqual(scaleView.bounds.height, contentSize.height, accuracy: 0.001)

        pip.frame = CGRect(x: 0, y: 0, width: 300, height: 188)

        XCTAssertEqual(scaleView.frame.size, CGSize(width: 300, height: 188))
        XCTAssertEqual(scaleView.bounds.width, contentSize.width, accuracy: 0.001, "re-set after the frame change")
        XCTAssertEqual(scaleView.bounds.height, contentSize.height, accuracy: 0.001)
    }

    func test_owns_every_click_inside() {
        let pip = makePip()
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        parent.addSubview(pip)
        let inner = NSView(frame: CGRect(origin: .zero, size: contentSize))
        pip.scaleViewForTesting.addSubview(inner)

        XCTAssertTrue(pip.hitTest(CGPoint(x: pipFrame.midX, y: pipFrame.midY)) === pip)
        XCTAssertTrue(pip.hitTest(CGPoint(x: pipFrame.minX + 2, y: pipFrame.maxY - 2)) === pip)
        XCTAssertNil(pip.hitTest(CGPoint(x: pipFrame.minX - 2, y: pipFrame.midY)))
    }

    func test_click_restores() throws {
        let pip = makePip()
        var clicked: [PaneID] = []
        pip.onClicked = { clicked.append($0) }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        pip.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(clicked, [], "a press may still become a drag")
        pip.mouseUp(with: try event(.leftMouseUp))

        XCTAssertEqual(clicked, [paneID])
        XCTAssertTrue(pip.accessibilityPerformPress())
        XCTAssertEqual(clicked, [paneID, paneID])
    }

    func test_legend_shows_on_hover_and_its_buttons_win_the_hit_test() throws {
        let pip = makePip()
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        parent.addSubview(pip)
        let legendPoint = CGPoint(x: pipFrame.maxX - PipChrome.legendTrailingInset - 10, y: pipFrame.maxY - 3)
        XCTAssertTrue(pip.actionsViewForTesting.isHidden)
        XCTAssertTrue(pip.hitTest(legendPoint) === pip, "no legend yet: the PiP owns the click")

        pip.setHovered(true)

        XCTAssertFalse(pip.actionsViewForTesting.isHidden)
        for action in PipChrome.actions {
            XCTAssertNotNil(pip.actionsViewForTesting.buttonForTesting(action))
        }
        let close = try XCTUnwrap(pip.actionsViewForTesting.buttonForTesting(.close))
        let closeCentre = parent.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
        XCTAssertTrue(pip.hitTest(closeCentre) === close)
        let aboveTheEdge = CGPoint(x: closeCentre.x, y: pipFrame.maxY + 3)
        XCTAssertTrue(pip.hitTest(aboveTheEdge) === close, "the half above the PiP edge is clickable")

        pip.setHovered(false)
        XCTAssertTrue(pip.actionsViewForTesting.isHidden)
    }

    func test_legend_actions_are_forwarded_with_the_pane() throws {
        let pip = makePip()
        var received: [(PaneID, PaneBorderAction)] = []
        pip.onActionRequested = { received.append(($0, $1)) }
        pip.setHovered(true)

        let minimize = try XCTUnwrap(pip.actionsViewForTesting.buttonForTesting(.minimize))
        minimize.performClick(nil)

        XCTAssertEqual(received.map(\.0), [paneID])
        XCTAssertEqual(received.map(\.1), [.minimize])
    }

    func test_status_strip_shows_name_and_status_word() {
        let pip = makePip()

        pip.configure(status: item(.running), theme: ZenttyTheme.fallback(for: nil))

        XCTAssertEqual(pip.statusStripForTesting.nameForTesting, "claude")
        XCTAssertEqual(pip.statusStripForTesting.statusWordForTesting, "Working")
        XCTAssertEqual(pip.accessibilityLabel(), "claude, Working, picture in picture")

        pip.configure(status: item(nil), theme: ZenttyTheme.fallback(for: nil))
        XCTAssertNil(pip.statusStripForTesting.statusWordForTesting, "idle shows no word")
    }

    func test_needs_input_turns_on_the_amber_ring_and_glow() {
        let pip = makePip()
        let theme = ZenttyTheme.fallback(for: nil)

        pip.configure(status: item(.running), theme: theme)
        XCTAssertTrue(pip.glowLayerForTesting.isHidden)
        XCTAssertEqual(pip.ringColorForTesting, theme.paneBorderUnfocused.cgColor)

        pip.configure(status: item(.needsInput), theme: theme)
        XCTAssertFalse(pip.glowLayerForTesting.isHidden)
        XCTAssertEqual(pip.ringColorForTesting, theme.statusNeedsInput.cgColor)
        XCTAssertEqual(pip.glowLayerForTesting.shadowColor, theme.statusNeedsInput.cgColor)
        XCTAssertEqual(pip.statusStripForTesting.statusWordForTesting, "Needs input")

        pip.configure(status: item(.ready), theme: theme)
        XCTAssertTrue(pip.glowLayerForTesting.isHidden)
        XCTAssertEqual(pip.statusStripForTesting.statusWordForTesting, "Done")
    }

    func test_working_dot_pulses_unless_reduce_motion() {
        defer { FloatMotion.reduceMotionOverride = nil }
        FloatMotion.reduceMotionOverride = false
        let pip = makePip()
        pip.configure(status: item(.running), theme: ZenttyTheme.fallback(for: nil))
        XCTAssertNotNil(pip.statusStripForTesting.dotLayerForTesting.animation(forKey: PillView.pulseKey))

        FloatMotion.reduceMotionOverride = true
        pip.configure(status: item(.needsInput), theme: ZenttyTheme.fallback(for: nil))
        XCTAssertNil(pip.statusStripForTesting.dotLayerForTesting.animation(forKey: PillView.pulseKey))
    }

    // MARK: - Fixtures

    private func makePip() -> PipContainerView {
        let pip = PipContainerView(paneID: paneID)
        pip.apply(frame: pipFrame, contentSize: contentSize)
        return pip
    }

    private func item(_ attention: WorklaneAttentionState?) -> PillBarItem {
        PillBarItem(paneID: paneID, name: "claude", subtitle: nil, attention: attention)
    }
}
