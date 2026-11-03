import AppKit
import XCTest
@testable import Zentty

/// Which cursor a float's resize zone shows, and the cursor rects that carry
/// it: corners diagonal, left/right horizontal, bottom vertical, the top
/// (move) band none. The rects must agree with the press classifier
/// (`FloatFrameRegion`), so the cursor never promises a resize a press
/// wouldn't start.
final class FloatResizeCursorTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 420, height: 300)
    private let band = FloatGesture.band
    private let cornerZone = FloatGesture.cornerZone

    // MARK: - Handle → cursor kind

    func test_corners_are_diagonal() {
        XCTAssertEqual(FloatResizeHandle.topLeft.cursorKind, .diagonalNorthWestSouthEast)
        XCTAssertEqual(FloatResizeHandle.bottomRight.cursorKind, .diagonalNorthWestSouthEast)
        XCTAssertEqual(FloatResizeHandle.topRight.cursorKind, .diagonalNorthEastSouthWest)
        XCTAssertEqual(FloatResizeHandle.bottomLeft.cursorKind, .diagonalNorthEastSouthWest)
    }

    func test_side_edges_are_horizontal_and_bottom_is_vertical() {
        XCTAssertEqual(FloatResizeHandle.left.cursorKind, .horizontal)
        XCTAssertEqual(FloatResizeHandle.right.cursorKind, .horizontal)
        XCTAssertEqual(FloatResizeHandle.bottom.cursorKind, .vertical)
    }

    func test_only_resize_regions_have_a_cursor() {
        XCTAssertNil(FloatFrameRegion.move.resizeCursorKind, "the move band keeps the arrow")
        XCTAssertNil(FloatFrameRegion.passthrough.resizeCursorKind, "the terminal keeps its own")
        XCTAssertEqual(FloatFrameRegion.resize(.bottomLeft).resizeCursorKind, .diagonalNorthEastSouthWest)
        XCTAssertEqual(FloatFrameRegion.resize(.right).resizeCursorKind, .horizontal)
    }

    @MainActor
    func test_every_handle_resolves_a_cursor() {
        for handle in FloatResizeHandle.allCases {
            _ = FloatResizeCursor.cursor(for: handle)
        }
        if #unavailable(macOS 15.0) {
            XCTAssertTrue(FloatResizeCursor.cursor(for: .bottomRight) === NSCursor.crosshair, "no public diagonal before 15")
            XCTAssertTrue(FloatResizeCursor.cursor(for: .left) === NSCursor.resizeLeftRight)
            XCTAssertTrue(FloatResizeCursor.cursor(for: .bottom) === NSCursor.resizeUpDown)
        }
    }

    // MARK: - Zone rects

    func test_zones_agree_with_the_press_classifier() {
        let zones = FloatResizeCursorZones.zones(bounds: bounds, band: band, cornerZone: cornerZone)
        var y = bounds.minY + 0.5
        while y < bounds.maxY {
            var x = bounds.minX + 0.5
            while x < bounds.maxX {
                let point = CGPoint(x: x, y: y)
                defer { x += 1 }
                guard !isInEdgeTieSquare(point) else { continue }
                let region = FloatFrameRegion.region(at: point, bounds: bounds, band: band, cornerZone: cornerZone)
                let expected: FloatResizeHandle? = if case .resize(let handle) = region { handle } else { nil }
                XCTAssertEqual(
                    FloatResizeCursorZones.handle(at: point, in: zones), expected,
                    "at \(point): region \(region)"
                )
            }
            y += 1
        }
    }

    func test_zones_never_overlap() {
        let zones = FloatResizeCursorZones.zones(bounds: bounds, band: band, cornerZone: cornerZone)
        for (index, zone) in zones.enumerated() {
            for other in zones[(index + 1)...] {
                let overlap = zone.rect.intersection(other.rect)
                XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(zone) overlaps \(other)")
            }
        }
    }

    func test_the_top_band_between_the_corners_has_no_zone() {
        let zones = FloatResizeCursorZones.zones(bounds: bounds, band: band, cornerZone: cornerZone)
        XCTAssertNil(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.midX, y: bounds.maxY - 2), in: zones))
        XCTAssertNil(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.midX, y: bounds.maxY - band + 1), in: zones))
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: 2, y: bounds.maxY - 2), in: zones), .topLeft)
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2), in: zones), .topRight)
    }

    func test_offset_bounds_keep_their_zones() {
        let offset = bounds.offsetBy(dx: 37, dy: -12)
        let zones = FloatResizeCursorZones.zones(bounds: offset, band: band, cornerZone: cornerZone)
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: offset.minX + 3, y: offset.midY), in: zones), .left)
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: offset.maxX - 3, y: offset.minY + 3), in: zones), .bottomRight)
        XCTAssertNil(FloatResizeCursorZones.handle(at: CGPoint(x: 3, y: 3), in: zones), "outside the bounds")
    }

    func test_excluded_rects_cut_the_zones() {
        // A float drawn above covers the right half, bottom-right corner included.
        let cover = CGRect(x: bounds.midX, y: -50, width: 400, height: 200)
        let zones = FloatResizeCursorZones.zones(bounds: bounds, band: band, cornerZone: cornerZone, excluding: [cover])
        XCTAssertNil(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.maxX - 3, y: 3), in: zones))
        XCTAssertNil(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.maxX - 3, y: 100), in: zones))
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: bounds.maxX - 3, y: 200), in: zones), .right)
        XCTAssertEqual(FloatResizeCursorZones.handle(at: CGPoint(x: 3, y: 3), in: zones), .bottomLeft)
        for zone in zones {
            let overlap = zone.rect.intersection(cover)
            XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(zone) reaches under the cover")
        }
    }

    func test_empty_bounds_have_no_zones() {
        XCTAssertTrue(FloatResizeCursorZones.zones(bounds: .zero, band: band, cornerZone: cornerZone).isEmpty)
    }

    /// Where the band is wider than the corner zone, the two edges meeting
    /// at a corner tie along a diagonal the axis-aligned rects can't follow
    /// (`|band - cornerZone|` points across). Either edge is fine there.
    private func isInEdgeTieSquare(_ point: CGPoint) -> Bool {
        let lower = min(band, cornerZone)
        let upper = max(band, cornerZone)
        let tiesX = [point.x - bounds.minX, bounds.maxX - point.x].contains { $0 > lower && $0 <= upper }
        let tiesY = [point.y - bounds.minY, bounds.maxY - point.y].contains { $0 > lower && $0 <= upper }
        return tiesX && tiesY
    }
}
