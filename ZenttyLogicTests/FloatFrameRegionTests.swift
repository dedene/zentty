import XCTest
@testable import Zentty

/// Hit classification for a float's border band (y-up local space). The top band is the
/// move handle; corners and the other three edges resize.
final class FloatFrameRegionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let band: CGFloat = 8
    private let cornerZone: CGFloat = 10

    private func region(_ x: CGFloat, _ y: CGFloat) -> FloatFrameRegion {
        FloatFrameRegion.region(
            at: CGPoint(x: x, y: y),
            bounds: bounds,
            band: band,
            cornerZone: cornerZone
        )
    }

    // MARK: - Corners

    func testBottomLeftCorner() {
        XCTAssertEqual(region(3, 3), .resize(.bottomLeft))
    }

    func testBottomRightCorner() {
        XCTAssertEqual(region(397, 3), .resize(.bottomRight))
    }

    func testTopLeftCornerResizes() {
        XCTAssertEqual(region(3, 297), .resize(.topLeft))
    }

    func testTopRightCornerResizes() {
        XCTAssertEqual(region(397, 297), .resize(.topRight))
    }

    // MARK: - Edges

    func testLeftEdgeMidHeight() {
        XCTAssertEqual(region(3, 150), .resize(.left))
    }

    func testRightEdgeMidHeight() {
        XCTAssertEqual(region(397, 150), .resize(.right))
    }

    func testBottomEdgeMidWidth() {
        XCTAssertEqual(region(200, 3), .resize(.bottom))
    }

    // MARK: - Top band (move)

    func testTopBandIsMove() {
        XCTAssertEqual(region(200, 297), .move)
    }

    func testTopBandNearCornerZoneEdgeIsMove() {
        // Just beyond the top-right corner zone → still the move band.
        XCTAssertEqual(region(389, 297), .move)
    }

    // MARK: - Pass-through

    func testInteriorPassesThrough() {
        XCTAssertEqual(region(200, 150), .passthrough)
    }

    func testOutsideBoundsPassesThrough() {
        XCTAssertEqual(region(500, 500), .passthrough)
    }

    // MARK: - Raw handle classifier

    func testResizeHandleReturnsNilForInterior() {
        XCTAssertNil(FloatFrameRegion.resizeHandle(
            at: CGPoint(x: 200, y: 150), bounds: bounds, band: band, cornerZone: cornerZone
        ))
    }

    func testResizeHandleReportsTopEdgeForTopBand() {
        XCTAssertEqual(FloatFrameRegion.resizeHandle(
            at: CGPoint(x: 200, y: 297), bounds: bounds, band: band, cornerZone: cornerZone
        ), .top)
    }

    func testCornerZonePromotesEdgePointNearCorner() {
        // In the left band (x=3), 10pt up from the bottom → within the corner
        // zone → bottomLeft, not the left edge.
        XCTAssertEqual(region(3, 10), .resize(.bottomLeft))
    }

    func testEdgeJustBeyondCornerZone() {
        // In the left band (x=3), 11pt up → beyond the corner zone → left edge.
        XCTAssertEqual(region(3, 11), .resize(.left))
    }

    func testDegenerateBoundsAreAllBand() {
        // Too small to have an interior: every point inside is a border hit.
        let tiny = CGRect(x: 0, y: 0, width: 12, height: 12)
        let result = FloatFrameRegion.region(
            at: CGPoint(x: 6, y: 6), bounds: tiny, band: band, cornerZone: cornerZone
        )
        XCTAssertNotEqual(result, .passthrough)
    }
}
