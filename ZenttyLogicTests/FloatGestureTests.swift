import AppKit
import XCTest
@testable import Zentty

final class FloatGestureTests: XCTestCase {
    /// The pane is (10, 10, 400, 300); the container's bounds are it grown
    /// by the 10pt chrome outset.
    private let outsetBounds = CGRect(x: 0, y: 0, width: 420, height: 320)
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)

    // MARK: - Ownership

    func test_top_band_owns_move() {
        XCTAssertEqual(own(CGPoint(x: 210, y: 310)), .move)
    }

    func test_band_outer_half_outside_pane_owns_move() {
        // 5pt above the pane's top border, inside the outset.
        XCTAssertEqual(own(CGPoint(x: 210, y: 315)), .move)
    }

    func test_bottom_right_corner_owns_resize() {
        XCTAssertEqual(own(CGPoint(x: 415, y: 5)), .resize(.bottomRight))
    }

    func test_side_edges_own_resize() {
        XCTAssertEqual(own(CGPoint(x: 5, y: 160)), .resize(.left))
        XCTAssertEqual(own(CGPoint(x: 210, y: 4)), .resize(.bottom))
    }

    func test_interior_plain_click_passes_through() {
        XCTAssertNil(own(CGPoint(x: 210, y: 160)))
    }

    func test_control_command_anywhere_owns_move() {
        XCTAssertEqual(own(CGPoint(x: 210, y: 160), modifiers: [.control, .command]), .move)
        XCTAssertEqual(own(CGPoint(x: 415, y: 5), modifiers: [.control, .command, .shift]), .move)
    }

    func test_command_only_passes_through() {
        XCTAssertNil(own(CGPoint(x: 210, y: 160), modifiers: [.command]))
        XCTAssertNil(own(CGPoint(x: 210, y: 160), modifiers: [.control]))
    }

    func test_border_chrome_never_owned() {
        XCTAssertNil(own(CGPoint(x: 380, y: 310), isOverBorderChrome: true))
        XCTAssertNil(own(CGPoint(x: 380, y: 310), modifiers: [.control, .command], isOverBorderChrome: true))
    }

    func test_only_left_mouse_down_is_owned() {
        XCTAssertNil(own(CGPoint(x: 210, y: 310), eventType: .rightMouseDown))
        XCTAssertNil(own(CGPoint(x: 210, y: 310), eventType: .scrollWheel))
        XCTAssertNil(own(CGPoint(x: 210, y: 310), eventType: .mouseMoved))
    }

    func test_point_outside_bounds_not_owned() {
        XCTAssertNil(own(CGPoint(x: 500, y: 160), modifiers: [.control, .command]))
    }

    // MARK: - Dock mode

    func test_option_at_mouse_down_starts_dock_mode() {
        let kind = own(CGPoint(x: 210, y: 310), modifiers: [.option])
        XCTAssertEqual(kind, .move, "⌥ on the band still owns the move")
        XCTAssertTrue(FloatGesture.startsDockMode(kind: .move, modifiers: [.option]))
        XCTAssertTrue(FloatGesture.startsDockMode(kind: .move, modifiers: [.control, .command, .option]))
        XCTAssertFalse(FloatGesture.startsDockMode(kind: .move, modifiers: []))
        XCTAssertFalse(FloatGesture.startsDockMode(kind: .resize(.bottomRight), modifiers: [.option]), "resizes never dock")
        XCTAssertNil(own(CGPoint(x: 210, y: 160), modifiers: [.option]), "⌥ alone on content stays the terminal's")
    }

    func test_dock_mode_release_never_throws() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 500, y: 350),
            startFrame: CGRect(x: 350, y: 250, width: 300, height: 200),
            timestamp: 10
        )
        session.move(to: CGPoint(x: 515, y: 335), timestamp: 10.01)
        XCTAssertEqual(
            FloatGesture.outcome(session: session, kind: .move, canvas: canvas, dockMode: true),
            .move(frame: CGRect(x: 365, y: 235, width: 300, height: 200))
        )
    }

    // MARK: - Outcome

    func test_small_movement_is_click() {
        var session = FloatDragSession(startMouse: .zero, startFrame: CGRect(x: 100, y: 100, width: 400, height: 300), timestamp: 0)
        session.move(to: CGPoint(x: 2, y: 1), timestamp: 0.2)
        XCTAssertEqual(FloatGesture.outcome(session: session, kind: .move, canvas: canvas), .click)
        XCTAssertEqual(FloatGesture.outcome(session: session, kind: .resize(.bottomRight), canvas: canvas), .click)
    }

    func test_move_outcome_clamped_inside_canvas() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 700, y: 600),
            startFrame: CGRect(x: 600, y: 400, width: 300, height: 200),
            timestamp: 0
        )
        session.move(to: CGPoint(x: 850, y: 750), timestamp: 1)
        session.move(to: CGPoint(x: 1000, y: 900), timestamp: 2)
        XCTAssertEqual(
            FloatGesture.outcome(session: session, kind: .move, canvas: canvas),
            .move(frame: CGRect(x: 700, y: 500, width: 300, height: 200))
        )
    }

    func test_fast_release_throws_to_corner() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 500, y: 350),
            startFrame: CGRect(x: 350, y: 250, width: 300, height: 200),
            timestamp: 10
        )
        session.move(to: CGPoint(x: 515, y: 335), timestamp: 10.01)
        XCTAssertEqual(session.velocity.dx, 1500, accuracy: 0.5)
        XCTAssertEqual(
            FloatGesture.outcome(session: session, kind: .move, canvas: canvas),
            .throwToPip(corner: .bottomRight)
        )
    }

    func test_1099_pt_per_s_stays_move() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 0, y: 0),
            startFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
            timestamp: 0
        )
        session.move(to: CGPoint(x: 1.099, y: 0), timestamp: 0.001)
        session.move(to: CGPoint(x: 10.99, y: 0), timestamp: 0.01)
        XCTAssertLessThan(hypot(session.velocity.dx, session.velocity.dy), FloatThrowProjection.pipThreshold)
        XCTAssertEqual(
            FloatGesture.outcome(session: session, kind: .move, canvas: canvas),
            .move(frame: CGRect(x: 111, y: 100, width: 300, height: 200))
        )
    }

    func test_resize_never_throws() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 500, y: 100),
            startFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            timestamp: 0
        )
        session.move(to: CGPoint(x: 540, y: 60), timestamp: 0.01)
        guard case .resize = FloatGesture.outcome(session: session, kind: .resize(.bottomRight), canvas: canvas) else {
            return XCTFail("a fast resize stays a resize")
        }
    }

    func test_resize_outcome_keeps_opposite_edge_and_min_size() {
        var session = FloatDragSession(
            startMouse: CGPoint(x: 500, y: 100),
            startFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            timestamp: 0
        )
        session.move(to: CGPoint(x: 200, y: 350), timestamp: 1)
        // Shrinks past the minimum: 300×170, top-left corner (100, 400) fixed.
        XCTAssertEqual(
            FloatGesture.outcome(session: session, kind: .resize(.bottomRight), canvas: canvas),
            .resize(frame: CGRect(x: 100, y: 230, width: 300, height: 170))
        )
    }

    // MARK: - Helpers

    private func own(
        _ point: CGPoint,
        eventType: NSEvent.EventType = .leftMouseDown,
        modifiers: NSEvent.ModifierFlags = [],
        isOverBorderChrome: Bool = false
    ) -> FloatGestureKind? {
        FloatGesture.ownership(
            at: point,
            outsetBounds: outsetBounds,
            eventType: eventType,
            modifiers: modifiers,
            isOverBorderChrome: isOverBorderChrome
        )
    }
}
