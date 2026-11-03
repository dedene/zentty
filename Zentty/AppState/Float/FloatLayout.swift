import CoreGraphics

/// Pure placement math for floats and PiPs. Coordinates are the float layer's
/// y-up (non-flipped) space: `minY` is the bottom edge, `maxY` the top.
enum FloatLayout {
    /// A floated tile lifts in place, inset from its old slot by this much.
    static let liftInset: CGFloat = 22
    static let minimumFloatSize = FloatResizeMath.minimumFloatSize
    /// Default float size (fraction of the canvas) when nothing is remembered.
    static let defaultCanvasFraction: CGFloat = 0.6
    /// A split on a float opens a new float offset down-right by this much.
    static let splitOffset: CGFloat = 28

    static let pipSmallWidth: CGFloat = 232
    static let pipMediumWidth: CGFloat = 300
    static let pipMargin: CGFloat = 14
    static let pipGap: CGFloat = 10
    static let maxPipsPerCorner = 2
    /// PiP height as a fraction of its width.
    static let pipAspectRange: ClosedRange<CGFloat> = 0.45...0.9

    // MARK: - PiP

    /// PiP width for the `floats.pip_size` setting.
    static func pipWidth(for size: AppConfig.Floats.PipSize) -> CGFloat {
        switch size {
        case .small: pipSmallWidth
        case .medium: pipMediumWidth
        }
    }

    /// PiP size at `width`, following the float's aspect ratio (clamped).
    static func pipSize(floatSize: CGSize, width: CGFloat) -> CGSize {
        let ratio = floatSize.width > 0
            ? floatSize.height / floatSize.width
            : pipAspectRange.lowerBound
        let clampedRatio = min(max(ratio, pipAspectRange.lowerBound), pipAspectRange.upperBound)
        return CGSize(width: width, height: width * clampedRatio)
    }

    /// Frame of the PiP at `indexInCorner` (0 = closest to the corner). PiPs in
    /// a corner stack vertically away from it. `bottomInset` (pill bar) only
    /// lifts the bottom corners.
    static func pipFrame(
        corner: FloatCorner,
        indexInCorner: Int,
        size: CGSize,
        canvas: CGRect,
        bottomInset: CGFloat
    ) -> CGRect {
        let stackOffset = CGFloat(max(0, indexInCorner)) * (size.height + pipGap)
        let x: CGFloat
        switch corner {
        case .topLeft, .bottomLeft:
            x = canvas.minX + pipMargin
        case .topRight, .bottomRight:
            x = canvas.maxX - pipMargin - size.width
        }

        let y: CGFloat
        switch corner {
        case .bottomLeft, .bottomRight:
            y = canvas.minY + pipMargin + max(0, bottomInset) + stackOffset
        case .topLeft, .topRight:
            y = canvas.maxY - pipMargin - size.height - stackOffset
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The PiP to send to the pill bar when `incoming` joins `corner`: the
    /// oldest (lowest order) one, once the corner already holds the maximum.
    static func evictionCandidate(
        in floats: [FloatingPaneState],
        corner: FloatCorner,
        incoming: PaneID
    ) -> PaneID? {
        let occupants = pips(in: floats, corner: corner, excluding: incoming)
        guard occupants.count >= maxPipsPerCorner else {
            return nil
        }
        return occupants.first?.pane.id
    }

    /// PiPs in `corner`, ordered by their in-corner order (closest first).
    static func pips(
        in floats: [FloatingPaneState],
        corner: FloatCorner,
        excluding excludedID: PaneID? = nil
    ) -> [FloatingPaneState] {
        floats
            .compactMap { float -> (order: Int, float: FloatingPaneState)? in
                guard float.pane.id != excludedID,
                      case .pip(let pipCorner, let order) = float.mode,
                      pipCorner == corner else {
                    return nil
                }
                return (order, float)
            }
            .sorted { $0.order < $1.order }
            .map(\.float)
    }

    // MARK: - Float frames

    /// Float frame for a lifted tile: its slot inset by `liftInset`, grown to
    /// the minimum size around its centre, then kept inside the canvas.
    static func liftedFrame(tileFrame: CGRect, canvas: CGRect) -> CGRect {
        let inset = tileFrame.insetBy(dx: liftInset, dy: liftInset)
        let width = max(inset.width, minimumFloatSize.width)
        let height = max(inset.height, minimumFloatSize.height)
        let grown = CGRect(
            x: tileFrame.midX - width / 2,
            y: tileFrame.midY - height / 2,
            width: width,
            height: height
        )
        return clamped(grown, in: canvas)
    }

    /// The frame for a float opened by a split on another float: offset
    /// down-right (y-up, so y decreases), kept inside the canvas.
    static func splitOffsetFrame(from frame: CGRect, canvas: CGRect) -> CGRect {
        clamped(frame.offsetBy(dx: splitOffset, dy: -splitOffset), in: canvas)
    }

    /// Where a new float opens so it never hides exactly behind another:
    /// while its origin lands on an occupied origin (within half a point),
    /// it steps `splitOffset` down-right. A step that would leave the canvas
    /// wraps to the canvas's top-left corner and the cascade goes on from
    /// there. Gives up (keeps the last candidate) once every slot it tried
    /// was taken.
    static func cascadedFrame(_ frame: CGRect, avoiding occupied: [CGRect], canvas: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else {
            return frame
        }
        func isTaken(_ candidate: CGRect) -> Bool {
            occupied.contains {
                abs($0.minX - candidate.minX) < 0.5 && abs($0.minY - candidate.minY) < 0.5
            }
        }
        var candidate = frame
        // One step per occupied frame, plus the wrap, always finds a free
        // origin or proves there is none worth looking for.
        for _ in 0...(occupied.count + 1) {
            guard isTaken(candidate) else {
                return candidate
            }
            let next = candidate.offsetBy(dx: splitOffset, dy: -splitOffset)
            if next.maxX > canvas.maxX || next.minY < canvas.minY {
                candidate = CGRect(
                    x: canvas.minX,
                    y: canvas.maxY - candidate.height,
                    width: candidate.width,
                    height: candidate.height
                )
            } else {
                candidate = next
            }
        }
        return candidate
    }

    /// `size` (at least the minimum) centred in the canvas.
    static func centeredFrame(size: CGSize, canvas: CGRect) -> CGRect {
        let width = max(size.width, minimumFloatSize.width)
        let height = max(size.height, minimumFloatSize.height)
        return clamped(
            CGRect(x: canvas.midX - width / 2, y: canvas.midY - height / 2, width: width, height: height),
            in: canvas
        )
    }

    /// Default float size for a canvas: 60% of it.
    static func defaultFloatSize(canvas: CGRect) -> CGSize {
        CGSize(width: canvas.width * defaultCanvasFraction, height: canvas.height * defaultCanvasFraction)
    }

    /// Shrinks `frame` to fit the canvas and moves it fully inside. A canvas
    /// smaller than the frame wins over the minimum size.
    static func clamped(_ frame: CGRect, in canvas: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else {
            return frame
        }
        let width = min(frame.width, canvas.width)
        let height = min(frame.height, canvas.height)
        let x = min(max(frame.minX, canvas.minX), canvas.maxX - width)
        let y = min(max(frame.minY, canvas.minY), canvas.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
