import AppKit

/// The pointer a float's resize zone shows.
enum FloatResizeCursorKind: Equatable, Sendable {
    /// Left and right edges.
    case horizontal
    /// Top and bottom edges (the top one is the move band and shows none).
    case vertical
    /// Top-left and bottom-right corners (↖↘).
    case diagonalNorthWestSouthEast
    /// Top-right and bottom-left corners (↗↙).
    case diagonalNorthEastSouthWest
}

extension FloatResizeHandle {
    var cursorKind: FloatResizeCursorKind {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .topLeft, .bottomRight: return .diagonalNorthWestSouthEast
        case .topRight, .bottomLeft: return .diagonalNorthEastSouthWest
        }
    }
}

extension FloatFrameRegion {
    /// The cursor a point in this region shows: only resize zones have one.
    /// The move band and the terminal keep their own pointer.
    var resizeCursorKind: FloatResizeCursorKind? {
        guard case .resize(let handle) = self else { return nil }
        return handle.cursorKind
    }
}

/// One rect of a float's border that shows `handle`'s resize cursor.
struct FloatResizeCursorZone: Equatable, Sendable {
    let handle: FloatResizeHandle
    let rect: CGRect
}

/// Axis-aligned rects covering the resize zones of `FloatFrameRegion`, for
/// cursor rects (which can't follow a point classifier). The bounds are cut
/// on every corner-zone and band line; each cell takes the region of its
/// centre, so the rects agree with `region(at:)` everywhere except the
/// band-minus-corner squares where two edges tie (`|band - cornerZone|`
/// points across).
enum FloatResizeCursorZones {
    static func zones(
        bounds: CGRect,
        band: CGFloat,
        cornerZone: CGFloat,
        excluding excluded: [CGRect] = []
    ) -> [FloatResizeCursorZone] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let xs = cuts(from: bounds.minX, to: bounds.maxX, insets: [cornerZone, band])
        let ys = cuts(from: bounds.minY, to: bounds.maxY, insets: [cornerZone, band])
        var zones: [FloatResizeCursorZone] = []
        for (minX, maxX) in zip(xs, xs.dropFirst()) {
            for (minY, maxY) in zip(ys, ys.dropFirst()) {
                let cell = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let region = FloatFrameRegion.region(
                    at: CGPoint(x: cell.midX, y: cell.midY),
                    bounds: bounds,
                    band: band,
                    cornerZone: cornerZone
                )
                guard case .resize(let handle) = region else { continue }
                for piece in subtract(excluded, from: cell) {
                    zones.append(FloatResizeCursorZone(handle: handle, rect: piece))
                }
            }
        }
        return zones
    }

    /// The handle whose zone holds `point`, if any.
    static func handle(at point: CGPoint, in zones: [FloatResizeCursorZone]) -> FloatResizeHandle? {
        zones.first { $0.rect.contains(point) }?.handle
    }

    private static func cuts(from minValue: CGFloat, to maxValue: CGFloat, insets: [CGFloat]) -> [CGFloat] {
        let inner = insets.flatMap { [minValue + $0, maxValue - $0] }
            .filter { $0 > minValue && $0 < maxValue }
        return Array(Set([minValue, maxValue] + inner)).sorted()
    }

    static func subtract(_ excluded: [CGRect], from rect: CGRect) -> [CGRect] {
        excluded.reduce([rect]) { pieces, cut in
            pieces.flatMap { subtract(cut, from: $0) }
        }
    }

    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        var pieces: [CGRect] = []
        if overlap.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY))
        }
        if overlap.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
        }
        if overlap.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height))
        }
        if overlap.maxX < rect.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces
    }
}

/// The `NSCursor` for a resize handle.
@MainActor
enum FloatResizeCursor {
    /// macOS 15+: the system frame-resize cursors (the ones window edges
    /// use). macOS 13–14 have no public diagonal resize cursor, so corners
    /// fall back to the crosshair; edges use the classic two-way arrows.
    static func cursor(for handle: FloatResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: frameResizePosition(for: handle), directions: .all)
        }
        switch handle.cursorKind {
        case .horizontal: return .resizeLeftRight
        case .vertical: return .resizeUpDown
        case .diagonalNorthWestSouthEast, .diagonalNorthEastSouthWest: return .crosshair
        }
    }

    @available(macOS 15.0, *)
    private static func frameResizePosition(for handle: FloatResizeHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
}
