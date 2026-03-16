import AppKit
import CoreGraphics
import QuartzCore

struct PanePresentation: Equatable, Sendable {
    let paneID: PaneID
    let frame: CGRect
    let emphasis: CGFloat
    let isFocused: Bool
}

struct StripPresentation: Equatable, Sendable {
    let panes: [PanePresentation]
    let contentWidth: CGFloat
    let targetOffset: CGFloat
}

@MainActor
final class PaneStripMotionController {
    private enum Layout {
        static let focusedEmphasis: CGFloat = 1
        static let secondaryEmphasis: CGFloat = 0.92
    }

    func presentation(
        for state: PaneStripState,
        in viewportSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        backingScaleFactor: CGFloat = 1
    ) -> StripPresentation {
        let scale = resolvedBackingScaleFactor(backingScaleFactor)
        let layoutItems = state.layoutItems(
            in: viewportSize,
            leadingVisibleInset: leadingVisibleInset
        )
        let sizing = state.layoutSizing
        let paneHeight = sizing.paneHeight(for: viewportSize.height)

        var cursorX = sizing.horizontalInset
        let presentations = layoutItems.map { item in
            let minX = cursorX
            let maxX = cursorX + item.width
            let frame = snappedFrame(
                minX: minX,
                maxX: maxX,
                minY: sizing.verticalInset,
                maxY: sizing.verticalInset + paneHeight,
                backingScaleFactor: scale
            )
            cursorX = maxX + sizing.interPaneSpacing
            return PanePresentation(
                paneID: item.pane.id,
                frame: frame,
                emphasis: item.isFocused ? Layout.focusedEmphasis : Layout.secondaryEmphasis,
                isFocused: item.isFocused
            )
        }

        let trailingSpacing = layoutItems.isEmpty ? 0 : sizing.interPaneSpacing
        let rawContentWidth = max(
            viewportSize.width,
            cursorX - trailingSpacing + sizing.horizontalInset
        )
        let contentWidth = snapped(
            rawContentWidth,
            backingScaleFactor: scale,
            roundingRule: .up
        )
        let targetOffset = targetOffset(
            forFocusedPaneIn: presentations,
            viewportWidth: viewportSize.width,
            contentWidth: contentWidth,
            leadingVisibleInset: leadingVisibleInset,
            backingScaleFactor: scale
        )

        return StripPresentation(
            panes: presentations,
            contentWidth: contentWidth,
            targetOffset: targetOffset
        )
    }

    func targetOffset(
        forFocusedPaneIn presentations: [PanePresentation],
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0,
        backingScaleFactor: CGFloat = 1
    ) -> CGFloat {
        guard let focusedPane = presentations.first(where: \.isFocused) else {
            return 0
        }

        let viewportMidX = viewportWidth / 2
        let centeredOffset = focusedPane.frame.midX - viewportMidX
        let unclampedOffset: CGFloat
        if presentations.first?.paneID == focusedPane.paneID, leadingVisibleInset > 0 {
            let readableLeadingOffset = focusedPane.frame.minX - leadingVisibleInset
            unclampedOffset = min(centeredOffset, readableLeadingOffset)
        } else {
            unclampedOffset = centeredOffset
        }
        let clamped = clampedOffset(
            unclampedOffset,
            contentWidth: contentWidth,
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        let snappedValue = snappedOffset(clamped, backingScaleFactor: backingScaleFactor)
        let scale = resolvedBackingScaleFactor(backingScaleFactor)
        let minOffset = snapped(
            -max(0, leadingVisibleInset),
            backingScaleFactor: scale,
            roundingRule: .down
        )
        let maxOffset = snapped(
            max(0, contentWidth - viewportWidth),
            backingScaleFactor: scale,
            roundingRule: .down
        )

        return min(max(minOffset, snappedValue), maxOffset)
    }

    func clampedOffset(
        _ proposedOffset: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) -> CGFloat {
        let minOffset = -max(0, leadingVisibleInset)
        let maxOffset = max(0, contentWidth - viewportWidth)
        return min(max(minOffset, proposedOffset), maxOffset)
    }

    func nearestSettlePaneID(
        in presentation: StripPresentation,
        proposedOffset: CGFloat,
        viewportWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) -> PaneID? {
        guard !presentation.panes.isEmpty else {
            return nil
        }

        let settledOffset = clampedOffset(
            proposedOffset,
            contentWidth: presentation.contentWidth,
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        let viewportMidX = settledOffset + (viewportWidth / 2)

        return presentation.panes.min { lhs, rhs in
            abs(lhs.frame.midX - viewportMidX) < abs(rhs.frame.midX - viewportMidX)
        }?.paneID
    }

    func snappedOffset(_ offset: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        snapped(offset, backingScaleFactor: backingScaleFactor)
    }

    func animate(in hostView: NSView, updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            updates()
            hostView.layoutSubtreeIfNeeded()
        }
    }

    private func snappedFrame(
        minX: CGFloat,
        maxX: CGFloat,
        minY: CGFloat,
        maxY: CGFloat,
        backingScaleFactor: CGFloat
    ) -> CGRect {
        let scale = resolvedBackingScaleFactor(backingScaleFactor)
        let snappedMinX = snapped(minX, backingScaleFactor: scale)
        let snappedMaxX = snapped(maxX, backingScaleFactor: scale)
        let snappedMinY = snapped(minY, backingScaleFactor: scale)
        let snappedMaxY = snapped(maxY, backingScaleFactor: scale)
        let onePixel = 1 / scale

        return CGRect(
            x: snappedMinX,
            y: snappedMinY,
            width: max(onePixel, snappedMaxX - snappedMinX),
            height: max(onePixel, snappedMaxY - snappedMinY)
        )
    }

    private func snapped(
        _ value: CGFloat,
        backingScaleFactor: CGFloat,
        roundingRule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> CGFloat {
        let scale = resolvedBackingScaleFactor(backingScaleFactor)
        return (value * scale).rounded(roundingRule) / scale
    }

    private func resolvedBackingScaleFactor(_ backingScaleFactor: CGFloat) -> CGFloat {
        max(1, backingScaleFactor)
    }
}
