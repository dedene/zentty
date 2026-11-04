import CoreGraphics

/// Pure placement helpers for the float layer.
enum FloatLayerCentering {
    /// Insets a raw layer-bounds rect on the leading (left) edge by the width the
    /// sidebar occludes, yielding the rect placement math should treat as the
    /// visible canvas. A negative or oversized inset is clamped so the rect never
    /// collapses below zero width.
    static func effectiveCanvasRect(bounds: CGRect, leadingInset: CGFloat) -> CGRect {
        let inset = max(0, min(leadingInset, bounds.width))
        return CGRect(
            x: bounds.minX + inset,
            y: bounds.minY,
            width: bounds.width - inset,
            height: bounds.height
        )
    }

    /// Centres a float of `size` in `canvas`, scaling it down (aspect preserved,
    /// floored to whole points) when it does not fit.
    static func centeredFrame(forFloatSize size: CGSize, in canvas: CGRect) -> CGRect {
        let fitted: CGSize
        if size.width > canvas.width || size.height > canvas.height {
            let scale = min(canvas.width / size.width, canvas.height / size.height)
            fitted = CGSize(
                width: floor(size.width * scale),
                height: floor(size.height * scale)
            )
        } else {
            fitted = size
        }
        return CGRect(
            x: canvas.origin.x + floor((canvas.width - fitted.width) / 2),
            y: canvas.origin.y + floor((canvas.height - fitted.height) / 2),
            width: fitted.width,
            height: fitted.height
        )
    }
}
