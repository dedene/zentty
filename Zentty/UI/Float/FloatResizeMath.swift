import CoreGraphics

/// The eight boundary-drag handles a float exposes: four corners plus four
/// edges. Shared by hit classification (``FloatFrameRegion``), cursor selection
/// and the resize math so there is one vocabulary for "which part of the border
/// is being dragged".
///
/// Signs are expressed in the float layer's coordinate space (non-flipped,
/// y-up): `minY` is the bottom edge, `maxY` the top. `widthSign`/`heightSign`
/// give the direction of pointer travel that *grows* the float; `0` means that
/// axis is not driven by this handle (an edge only resizes along one axis).
enum FloatResizeHandle: Sendable, Equatable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case left, right, top, bottom

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        case .left, .right, .top, .bottom: return false
        }
    }

    /// Sign applied to `delta.dx` so that pushing the handle outward grows the
    /// width. `0` for the top/bottom edges, which never move horizontally.
    var widthSign: CGFloat {
        switch self {
        case .right, .topRight, .bottomRight: return 1
        case .left, .topLeft, .bottomLeft: return -1
        case .top, .bottom: return 0
        }
    }

    /// Sign applied to `delta.dy` so that pushing the handle outward grows the
    /// height. `0` for the left/right edges, which never move vertically.
    var heightSign: CGFloat {
        switch self {
        case .top, .topLeft, .topRight: return 1
        case .bottom, .bottomLeft, .bottomRight: return -1
        case .left, .right: return 0
        }
    }
}

enum FloatResizeMath {
    /// Smallest size a float can be resized to.
    static let minimumFloatSize = CGSize(width: 300, height: 170)

    /// Edge-anchored 1× resize. The dragged edge (or the two edges meeting at a
    /// dragged corner) follows the pointer; the opposite edge stays fixed.
    ///
    /// The result is clamped to `minSize` and to `canvas`: a moving edge never
    /// crosses the canvas boundary. A frame that already sits partly past the
    /// canvas (floats only need to stay reachable) is never snapped inward; it
    /// just cannot grow further on that side. `minSize` wins over `canvas`.
    static func resizeAnchored(
        handle: FloatResizeHandle,
        delta: CGVector,
        frame: CGRect,
        minSize: CGSize,
        canvas: CGRect
    ) -> CGRect {
        var result = frame

        if handle.widthSign != 0 {
            let proposed = frame.width + handle.widthSign * delta.dx
            let available = handle.widthSign > 0
                ? canvas.maxX - frame.minX
                : frame.maxX - canvas.minX
            let width = clampedLength(
                proposed,
                current: frame.width,
                available: available,
                minimum: minSize.width
            )
            result.size.width = width
            if handle.widthSign < 0 {
                result.origin.x = frame.maxX - width
            }
        }

        if handle.heightSign != 0 {
            let proposed = frame.height + handle.heightSign * delta.dy
            let available = handle.heightSign > 0
                ? canvas.maxY - frame.minY
                : frame.maxY - canvas.minY
            let height = clampedLength(
                proposed,
                current: frame.height,
                available: available,
                minimum: minSize.height
            )
            result.size.height = height
            if handle.heightSign < 0 {
                result.origin.y = frame.maxY - height
            }
        }

        return result
    }

    private static func clampedLength(
        _ proposed: CGFloat,
        current: CGFloat,
        available: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        let maximum = max(available, current)
        return max(minimum, min(proposed, maximum))
    }
}
