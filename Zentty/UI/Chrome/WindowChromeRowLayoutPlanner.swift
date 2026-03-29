import CoreGraphics

enum WindowChromeRowLayoutPlanner {
    enum Kind {
        case attention
        case proxyIcon
        case focusedLabel
        case branch
        case pullRequest
        case reviewChip
    }

    struct Item {
        let kind: Kind
        let preferredWidth: CGFloat
        let minimumWidth: CGFloat
    }

    struct PlannedItem {
        let kind: Kind
        let preferredWidth: CGFloat
        let minimumWidth: CGFloat
        var assignedWidth: CGFloat
    }

    struct Plan {
        let items: [PlannedItem]
        let preferredTotalWidth: CGFloat
        let finalTotalWidth: CGFloat
        let overflowBeforeCompression: CGFloat
        let overflowAfterChipEviction: CGFloat
        let didDropReviewChips: Bool
        let didCompressItems: Bool
    }

    private static let zeroCompressionOrder: [Kind] = [
        .reviewChip,
        .attention,
        .focusedLabel,
        .proxyIcon,
        .branch,
        .pullRequest,
    ]

    static func plan(availableWidth: CGFloat, items: [Item]) -> Plan {
        var plannedItems = items.map {
            PlannedItem(
                kind: $0.kind,
                preferredWidth: $0.preferredWidth,
                minimumWidth: $0.minimumWidth,
                assignedWidth: $0.preferredWidth
            )
        }

        let preferredTotalWidth = totalWidth(for: plannedItems)
        let overflowBeforeCompression = max(0, preferredTotalWidth - availableWidth)

        guard overflowBeforeCompression > 0 else {
            return Plan(
                items: plannedItems,
                preferredTotalWidth: preferredTotalWidth,
                finalTotalWidth: preferredTotalWidth,
                overflowBeforeCompression: 0,
                overflowAfterChipEviction: 0,
                didDropReviewChips: false,
                didCompressItems: false
            )
        }

        let overflowAfterChipEviction = reduce(
            &plannedItems,
            availableWidth: availableWidth,
            floorResolver: { _ in 0 },
            indices: reviewChipEvictionIndices(in: plannedItems)
        )

        var remainingShortage = overflowAfterChipEviction
        if remainingShortage > 0 {
            remainingShortage = reduce(
                &plannedItems,
                availableWidth: availableWidth,
                floorResolver: { $0.minimumWidth },
                compressionOrder: [.attention, .focusedLabel, .proxyIcon, .pullRequest, .branch]
            )
        }

        if remainingShortage > 0 {
            _ = reduce(
                &plannedItems,
                availableWidth: availableWidth,
                floorResolver: { _ in 0 },
                compressionOrder: zeroCompressionOrder
            )
        }

        return Plan(
            items: plannedItems,
            preferredTotalWidth: preferredTotalWidth,
            finalTotalWidth: totalWidth(for: plannedItems),
            overflowBeforeCompression: overflowBeforeCompression,
            overflowAfterChipEviction: overflowAfterChipEviction,
            didDropReviewChips: plannedItems.contains {
                $0.kind == .reviewChip && $0.assignedWidth <= 0.5 && $0.preferredWidth > 0.5
            },
            didCompressItems: plannedItems.contains {
                $0.assignedWidth < ($0.preferredWidth - 0.5)
            }
        )
    }

    private static func reduce(
        _ items: inout [PlannedItem],
        availableWidth: CGFloat,
        floorResolver: (PlannedItem) -> CGFloat,
        compressionOrder: [Kind]
    ) -> CGFloat {
        var remainingShortage = overflowWidth(for: items, availableWidth: availableWidth)

        for kind in compressionOrder where remainingShortage > 0 {
            for index in items.indices where items[index].kind == kind && remainingShortage > 0 {
                let floor = floorResolver(items[index])
                let reducibleWidth = max(0, items[index].assignedWidth - floor)
                let reduction = min(reducibleWidth, remainingShortage)
                items[index].assignedWidth -= reduction
                remainingShortage = overflowWidth(for: items, availableWidth: availableWidth)
            }
        }

        return remainingShortage
    }

    private static func reduce(
        _ items: inout [PlannedItem],
        availableWidth: CGFloat,
        floorResolver: (PlannedItem) -> CGFloat,
        indices: [Int]
    ) -> CGFloat {
        var remainingShortage = overflowWidth(for: items, availableWidth: availableWidth)

        for index in indices where remainingShortage > 0 {
            let floor = floorResolver(items[index])
            let reducibleWidth = max(0, items[index].assignedWidth - floor)
            let reduction = min(reducibleWidth, remainingShortage)
            items[index].assignedWidth -= reduction
            remainingShortage = overflowWidth(for: items, availableWidth: availableWidth)
        }

        return remainingShortage
    }

    private static func reviewChipEvictionIndices(in items: [PlannedItem]) -> [Int] {
        let chipIndices = items.indices.filter { items[$0].kind == .reviewChip }
        guard chipIndices.count > 1 else {
            return []
        }

        return Array(chipIndices.dropLast())
    }

    private static func overflowWidth(for items: [PlannedItem], availableWidth: CGFloat) -> CGFloat {
        max(0, totalWidth(for: items) - availableWidth)
    }

    private static func totalWidth(for items: [PlannedItem]) -> CGFloat {
        let visibleItems = items.filter { $0.assignedWidth > 0.5 }
        guard !visibleItems.isEmpty else {
            return 0
        }

        let widths = visibleItems.reduce(CGFloat.zero) { $0 + $1.assignedWidth }
        let spacings = zip(visibleItems, visibleItems.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + spacing(between: pair.0.kind, and: pair.1.kind)
        }
        return widths + spacings
    }

    private static func spacing(between previousKind: Kind, and nextKind: Kind) -> CGFloat {
        switch (previousKind, nextKind) {
        case (.proxyIcon, .focusedLabel), (.focusedLabel, .proxyIcon):
            return 4
        case (.reviewChip, .reviewChip):
            return 8
        case (.reviewChip, _), (_, .reviewChip):
            return 12
        default:
            return 10
        }
    }
}
