import AppKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttySelectionAutoscrollControllerTests: XCTestCase {
    func test_top_edge_tick_requests_decremented_row_and_top_clamped_pointer() throws {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 160))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let result = controller.tick(elapsed: 0.25)

        XCTAssertLessThan(try XCTUnwrap(result?.targetRow), 100)
        XCTAssertEqual(result?.syntheticMouseLocation, CGPoint(x: 80, y: 159))
    }

    func test_bottom_edge_tick_requests_incremented_row_and_bottom_clamped_pointer() throws {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 0))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let result = controller.tick(elapsed: 0.25)

        XCTAssertGreaterThan(try XCTUnwrap(result?.targetRow), 100)
        XCTAssertEqual(result?.syntheticMouseLocation, CGPoint(x: 80, y: 1))
    }

    func test_tick_returns_nil_when_pointer_is_outside_edge_zone() {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 80))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        XCTAssertNil(controller.tick(elapsed: 0.25))
    }

    func test_deeper_edge_proximity_requests_more_rows_than_shallow_edge_proximity() throws {
        let shallow = makeController()
        shallow.setViewportHeight(160)
        shallow.setSelectionDragActive(true)
        shallow.setMouseLocation(CGPoint(x: 80, y: 25))
        shallow.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let deep = makeController()
        deep.setViewportHeight(160)
        deep.setSelectionDragActive(true)
        deep.setMouseLocation(CGPoint(x: 80, y: 1))
        deep.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let shallowResult = shallow.tick(elapsed: 0.25)
        let deepResult = deep.tick(elapsed: 0.25)

        XCTAssertGreaterThan(try XCTUnwrap(deepResult?.targetRow), try XCTUnwrap(shallowResult?.targetRow))
    }

    func test_deeper_edge_requests_rows_sooner_than_shallow_edge_at_timer_cadence() throws {
        let shallow = makeController()
        shallow.setViewportHeight(160)
        shallow.setSelectionDragActive(true)
        shallow.setMouseLocation(CGPoint(x: 80, y: 25))
        shallow.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let deep = makeController()
        deep.setViewportHeight(160)
        deep.setSelectionDragActive(true)
        deep.setMouseLocation(CGPoint(x: 80, y: 1))
        deep.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        XCTAssertNil(shallow.tick(elapsed: 1.0 / 30.0))
        XCTAssertNotNil(deep.tick(elapsed: 1.0 / 30.0)?.targetRow)
        XCTAssertNil(shallow.tick(elapsed: 1.0 / 30.0))
        XCTAssertNotNil(shallow.tick(elapsed: 1.0 / 30.0)?.targetRow)
    }

    func test_tick_clears_pending_when_scrollbar_moves_in_requested_direction() throws {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 1))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let first = controller.tick(elapsed: 0.25)
        let second = controller.tick(elapsed: 0.25)

        XCTAssertGreaterThan(try XCTUnwrap(first?.targetRow), 100)
        XCTAssertNil(second)

        controller.setScrollbarUpdate(.init(total: 200, offset: 101, len: 10))
        let third = controller.tick(elapsed: 0.25)
        XCTAssertGreaterThan(try XCTUnwrap(third?.targetRow), 101)
    }

    func test_tick_clamps_to_scroll_limits() {
        let top = makeController()
        top.setViewportHeight(160)
        top.setSelectionDragActive(true)
        top.setMouseLocation(CGPoint(x: 80, y: 160))
        top.setScrollbarUpdate(.init(total: 200, offset: 0, len: 10))
        XCTAssertNil(top.tick(elapsed: 0.25))

        let bottom = makeController()
        bottom.setViewportHeight(160)
        bottom.setSelectionDragActive(true)
        bottom.setMouseLocation(CGPoint(x: 80, y: 0))
        bottom.setScrollbarUpdate(.init(total: 200, offset: 190, len: 10))
        XCTAssertNil(bottom.tick(elapsed: 0.25))
    }

    func test_short_viewport_prefers_nearest_edge_zone_instead_of_overlapping_to_top() throws {
        let controller = makeController()
        controller.setViewportHeight(30)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 1))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let result = controller.tick(elapsed: 0.25)

        XCTAssertGreaterThan(try XCTUnwrap(result?.targetRow), 100)
        XCTAssertEqual(result?.syntheticMouseLocation, CGPoint(x: 80, y: 1))
    }

    func test_matching_top_and_bottom_edge_depths_trigger_autoscroll_symmetrically() throws {
        let top = makeController()
        top.setViewportHeight(160)
        top.setSelectionDragActive(true)
        top.setMouseLocation(CGPoint(x: 80, y: 130))
        top.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let bottom = makeController()
        bottom.setViewportHeight(160)
        bottom.setSelectionDragActive(true)
        bottom.setMouseLocation(CGPoint(x: 80, y: 30))
        bottom.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let topResult = try XCTUnwrap(top.tick(elapsed: 0.25))
        let bottomResult = try XCTUnwrap(bottom.tick(elapsed: 0.25))

        XCTAssertEqual(100 - topResult.targetRow, bottomResult.targetRow - 100)
    }

    func test_bottom_edge_hysteresis_keeps_autoscroll_active_until_release_zone_is_left() throws {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 10))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        XCTAssertGreaterThan(try XCTUnwrap(controller.tick(elapsed: 0.25)?.targetRow), 100)

        controller.setScrollbarUpdate(.init(total: 200, offset: 101, len: 10))
        controller.setMouseLocation(CGPoint(x: 80, y: 40))
        XCTAssertGreaterThan(try XCTUnwrap(controller.tick(elapsed: 0.25)?.targetRow), 101)

        controller.setScrollbarUpdate(.init(total: 200, offset: 102, len: 10))
        controller.setMouseLocation(CGPoint(x: 80, y: 60))
        XCTAssertNil(controller.tick(elapsed: 0.25))
    }

    func test_matching_top_and_bottom_edge_depths_request_same_row_delta() throws {
        let top = makeController()
        top.setViewportHeight(160)
        top.setSelectionDragActive(true)
        top.setMouseLocation(CGPoint(x: 80, y: 156))
        top.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let bottom = makeController()
        bottom.setViewportHeight(160)
        bottom.setSelectionDragActive(true)
        bottom.setMouseLocation(CGPoint(x: 80, y: 4))
        bottom.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let topResult = try XCTUnwrap(top.tick(elapsed: 0.13))
        let bottomResult = try XCTUnwrap(bottom.tick(elapsed: 0.13))

        XCTAssertEqual(100 - topResult.targetRow, bottomResult.targetRow - 100)
    }

    func test_deep_bottom_edge_ramps_beyond_previous_scroll_delta() throws {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(true)
        controller.setMouseLocation(CGPoint(x: 80, y: 1))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        let result = try XCTUnwrap(controller.tick(elapsed: 0.25))

        XCTAssertGreaterThanOrEqual(result.targetRow, 109)
    }

    func test_tick_returns_nil_when_drag_is_inactive() {
        let controller = makeController()
        controller.setViewportHeight(160)
        controller.setSelectionDragActive(false)
        controller.setMouseLocation(CGPoint(x: 80, y: 1))
        controller.setScrollbarUpdate(.init(total: 200, offset: 100, len: 10))

        XCTAssertNil(controller.tick(elapsed: 0.25))
    }
}

@MainActor
private func makeController() -> LibghosttySelectionAutoscrollController {
    LibghosttySelectionAutoscrollController(
        configuration: .init()
    )
}
