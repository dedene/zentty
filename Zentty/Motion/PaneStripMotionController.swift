import AppKit
import CoreGraphics
import QuartzCore

struct PanePresentation: Equatable, Sendable {
    let paneID: PaneID
    let columnID: PaneColumnID
    let frame: CGRect
    let emphasis: CGFloat
    let isFocused: Bool
}

struct ColumnPresentation: Equatable, Sendable {
    let columnID: PaneColumnID
    let frame: CGRect
    let panes: [PanePresentation]

    var focusedPane: PanePresentation? {
        panes.first(where: \.isFocused)
    }
}

struct StripPresentation: Equatable, Sendable {
    let columns: [ColumnPresentation]
    let contentWidth: CGFloat
    let targetOffset: CGFloat

    var panes: [PanePresentation] {
        columns.flatMap(\.panes)
    }

    var focusedPane: PanePresentation? {
        panes.first(where: \.isFocused)
    }
}

@MainActor
final class PaneStripMotionController {
    private enum Layout {
        static let focusedEmphasis: CGFloat = 1
        static let secondaryEmphasis: CGFloat = 0.92
        static let fallbackSpacing: CGFloat = 16
    }

    func presentation(
        for state: PaneStripState,
        in viewportSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        backingScaleFactor: CGFloat = 1
    ) -> StripPresentation {
        let scale = resolvedBackingScaleFactor(backingScaleFactor)
        let sizing = state.layoutSizing
        let availableHeight = max(0, viewportSize.height - sizing.topInset - sizing.bottomInset)

        var cursorX = sizing.horizontalInset
        var columnPresentations: [ColumnPresentation] = []

        for column in state.columns {
            let columnWidth = max(1, column.width)
            let columnMinX = cursorX
            let columnMaxX = cursorX + columnWidth
            let columnFrame = snappedFrame(
                minX: columnMinX,
                maxX: columnMaxX,
                minY: sizing.bottomInset,
                maxY: sizing.bottomInset + availableHeight,
                backingScaleFactor: scale
            )
            let paneHeight = stackedPaneHeight(
                availableHeight: availableHeight,
                paneCount: column.panes.count,
                spacing: sizing.interPaneSpacing
            )
            var paneTopY = sizing.bottomInset + availableHeight
            let panePresentations = column.panes.map { pane in
                let maxY = paneTopY
                let minY = maxY - paneHeight
                paneTopY = minY - sizing.interPaneSpacing
                return PanePresentation(
                    paneID: pane.id,
                    columnID: column.id,
                    frame: snappedFrame(
                        minX: columnMinX,
                        maxX: columnMaxX,
                        minY: minY,
                        maxY: maxY,
                        backingScaleFactor: scale
                    ),
                    emphasis: pane.id == state.focusedPaneID
                        ? Layout.focusedEmphasis
                        : Layout.secondaryEmphasis,
                    isFocused: pane.id == state.focusedPaneID
                )
            }

            columnPresentations.append(
                ColumnPresentation(
                    columnID: column.id,
                    frame: columnFrame,
                    panes: panePresentations
                )
            )

            cursorX = columnMaxX + sizing.interPaneSpacing
        }

        let trailingSpacing = columnPresentations.isEmpty ? 0 : sizing.interPaneSpacing
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
            forFocusedPaneIn: columnPresentations.flatMap(\.panes).first(where: \.isFocused),
            isFirstColumn: columnPresentations.flatMap(\.panes).first(where: \.isFocused)?.columnID
                == columnPresentations.first?.columnID,
            viewportWidth: viewportSize.width,
            contentWidth: contentWidth,
            leadingVisibleInset: leadingVisibleInset,
            backingScaleFactor: scale
        )

        return StripPresentation(
            columns: columnPresentations,
            contentWidth: contentWidth,
            targetOffset: targetOffset
        )
    }

    func targetOffset(
        forFocusedPaneIn focusedPane: PanePresentation?,
        isFirstColumn: Bool = false,
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0,
        backingScaleFactor: CGFloat = 1
    ) -> CGFloat {
        guard let focusedPane else {
            return 0
        }

        let viewportMidX = viewportWidth / 2
        let centeredOffset = focusedPane.frame.midX - viewportMidX
        let unclampedOffset: CGFloat
        if isFirstColumn, leadingVisibleInset > 0, focusedPane.frame.minX <= max(0, leadingVisibleInset) {
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
        guard !presentation.columns.isEmpty else {
            return nil
        }

        let settledOffset = clampedOffset(
            proposedOffset,
            contentWidth: presentation.contentWidth,
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        let viewportMidX = settledOffset + (viewportWidth / 2)

        guard let closestColumn = presentation.columns.min(by: {
            abs($0.frame.midX - viewportMidX) < abs($1.frame.midX - viewportMidX)
        }) else {
            return nil
        }

        return closestColumn.focusedPane?.paneID ?? closestColumn.panes.first?.paneID
    }

    func snappedOffset(_ offset: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        snapped(offset, backingScaleFactor: backingScaleFactor)
    }

    func animate(
        in hostView: NSView,
        updates: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            updates()
            hostView.layoutSubtreeIfNeeded()
        } completionHandler: {
            completion?()
        }
    }

    private func stackedPaneHeight(
        availableHeight: CGFloat,
        paneCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        guard paneCount > 0 else {
            return 0
        }

        let totalSpacing = spacing * CGFloat(max(0, paneCount - 1))
        return max(0, availableHeight - totalSpacing) / CGFloat(paneCount)
    }

    private func insertionTransition(
        from previousPresentation: StripPresentation?,
        previousOffset: CGFloat,
        to nextPresentation: StripPresentation
    ) -> PaneInsertionTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)

        guard insertedPaneIDs.count == 1, removedPaneIDs.isEmpty else {
            return nil
        }

        guard
            let insertedPaneID = insertedPaneIDs.first,
            let insertedPane = nextPresentation.panes.first(where: { $0.paneID == insertedPaneID }),
            let insertedColumnIndex = nextPresentation.columns.firstIndex(where: {
                $0.panes.contains(where: { $0.paneID == insertedPaneID })
            })
        else {
            return nil
        }

        let previousColumnsByID = Dictionary(uniqueKeysWithValues: previousPresentation.columns.map { ($0.columnID, $0) })
        let nextColumn = nextPresentation.columns[insertedColumnIndex]

        if let previousColumn = previousColumnsByID[nextColumn.columnID] {
            let spacing = paneSpacing(in: nextColumn)
            guard let insertedIndex = nextColumn.panes.firstIndex(where: { $0.paneID == insertedPaneID }) else {
                return nil
            }

            if insertedIndex > 0 {
                let anchorPane = nextColumn.panes[insertedIndex - 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                let initialFrame = CGRect(
                    x: insertedPane.frame.minX,
                    y: (previousAnchorPane?.frame.minY ?? anchorPane.frame.minY)
                        - spacing
                        - insertedPane.frame.height,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                )
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .bottom,
                    initialFrame: initialFrame
                )
            }

            if insertedIndex < nextColumn.panes.count - 1 {
                let anchorPane = nextColumn.panes[insertedIndex + 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                let initialFrame = CGRect(
                    x: insertedPane.frame.minX,
                    y: (previousAnchorPane?.frame.maxY ?? anchorPane.frame.maxY) + spacing,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                )
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .top,
                    initialFrame: initialFrame
                )
            }

            return nil
        }

        let spacing = columnSpacing(in: nextPresentation)

        if insertedColumnIndex > 0 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex - 1]
            let initialFrame = CGRect(
                x: anchorColumn.frame.maxX + spacing,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .right,
                initialFrame: initialFrame
            )
        }

        if insertedColumnIndex < nextPresentation.columns.count - 1 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex + 1]
            let initialFrame = CGRect(
                x: anchorColumn.frame.minX - spacing - insertedPane.frame.width,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .left,
                initialFrame: initialFrame
            )
        }

        return nil
    }

    private func columnSpacing(in presentation: StripPresentation) -> CGFloat {
        guard presentation.columns.count > 1 else {
            return Layout.fallbackSpacing
        }

        return max(
            Layout.fallbackSpacing,
            presentation.columns[1].frame.minX - presentation.columns[0].frame.maxX
        )
    }

    private func paneSpacing(in column: ColumnPresentation) -> CGFloat {
        guard column.panes.count > 1 else {
            return Layout.fallbackSpacing
        }

        return max(
            Layout.fallbackSpacing,
            column.panes[0].frame.minY - column.panes[1].frame.maxY
        )
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
