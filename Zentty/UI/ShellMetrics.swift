import CoreGraphics

enum ChromeGeometry {
    static let outerWindowRadius: CGFloat = 26
    static let shellInset: CGFloat = 8
    static let paneInset: CGFloat = 4
    static let rowInset: CGFloat = 4
    static let pillInset: CGFloat = 2

    static let headerHeight: CGFloat = 44
    static let headerHorizontalInset: CGFloat = 16

    static let trafficLightOpticalLeadingOffset: CGFloat = 12
    static let trafficLightOpticalTopOffset: CGFloat = 12
    static let trafficLightLeadingInset: CGFloat = shellInset + trafficLightOpticalLeadingOffset
    static let trafficLightTopInset: CGFloat = shellInset + trafficLightOpticalTopOffset
    static let trafficLightSpacing: CGFloat = 6

    static func innerRadius(outerRadius: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outerRadius - inset)
    }

    static func clipSafeInnerBorderInset(
        parentRadius: CGFloat,
        childRadius: CGFloat,
        borderWidth: CGFloat = 1
    ) -> CGFloat {
        guard parentRadius > 0, childRadius > 0 else {
            return 0
        }

        let clampedChildRadius = min(childRadius, parentRadius)
        let verticalOffset = parentRadius - clampedChildRadius
        let allowedHalfWidth = sqrt(max(0, (parentRadius * parentRadius) - (verticalOffset * verticalOffset)))
        let curveInset = max(0, parentRadius - allowedHalfWidth)
        return max(borderWidth / 2, curveInset + (borderWidth / 2))
    }

    static func snappedOutwardInset(_ inset: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        let scale = max(1, backingScaleFactor)
        return (inset * scale).rounded(.up) / scale
    }

    static func backingPixelInset(backingScaleFactor: CGFloat) -> CGFloat {
        1 / max(1, backingScaleFactor)
    }

    static let contentShellRadius: CGFloat = innerRadius(
        outerRadius: outerWindowRadius,
        inset: shellInset
    )
    static let sidebarRadius: CGFloat = contentShellRadius
    static let paneRadius: CGFloat = innerRadius(
        outerRadius: contentShellRadius,
        inset: paneInset
    )
    static let rowRadius: CGFloat = innerRadius(
        outerRadius: sidebarRadius,
        inset: rowInset
    )
    static let pillRadius: CGFloat = innerRadius(
        outerRadius: rowRadius,
        inset: pillInset
    )

    static func paneBorderInset(backingScaleFactor: CGFloat) -> CGFloat {
        let clipSafeInset = clipSafeInnerBorderInset(
            parentRadius: contentShellRadius,
            childRadius: paneRadius,
            borderWidth: 1
        )
        let antialiasGuardInset = backingPixelInset(backingScaleFactor: backingScaleFactor)
        return snappedOutwardInset(
            clipSafeInset + antialiasGuardInset,
            backingScaleFactor: backingScaleFactor
        )
    }
}

enum ShellMetrics {
    static let outerInset: CGFloat = ChromeGeometry.shellInset
    static let shellGap: CGFloat = ChromeGeometry.shellInset

    static let outerWindowRadius: CGFloat = ChromeGeometry.outerWindowRadius
    static let contentShellRadius: CGFloat = ChromeGeometry.contentShellRadius
    static let sidebarRadius: CGFloat = ChromeGeometry.sidebarRadius
    static let paneRadius: CGFloat = ChromeGeometry.paneRadius
    static let rowRadius: CGFloat = ChromeGeometry.rowRadius
    static let pillRadius: CGFloat = ChromeGeometry.pillRadius

    static let headerHeight: CGFloat = ChromeGeometry.headerHeight
    static let headerHorizontalInset: CGFloat = ChromeGeometry.headerHorizontalInset
    static let contentPadding: CGFloat = 8

    static let sidebarContentInset: CGFloat = 8
    static let sidebarTopInset: CGFloat = 58
    static let sidebarBottomInset: CGFloat = 18
    static let sidebarRowHorizontalInset: CGFloat = 12
    static let sidebarLeadingAccessorySize: CGFloat = 14
    static let sidebarLeadingAccessorySpacing: CGFloat = 8
    static let sidebarLeadingAccessoryGutterWidth: CGFloat = sidebarLeadingAccessorySize + sidebarLeadingAccessorySpacing
    // These budgets intentionally preserve the current fixed row rhythm.
    // They model semantic row bands rather than NSTextField fitting sizes.
    static let sidebarRowVerticalPadding: CGFloat = 14
    static let sidebarRowInterlineSpacing: CGFloat = 2
    static let sidebarTitleLineHeightBudget: CGFloat = 6
    static let sidebarPrimaryLineHeightBudget: CGFloat = 20
    static let sidebarStatusLineHeightBudget: CGFloat = 6
    static let sidebarContextLineHeightBudget: CGFloat = 6
    static let sidebarCompactRowHeight: CGFloat = sidebarRowVerticalPadding + sidebarPrimaryLineHeightBudget
    static let sidebarExpandedRowHeight: CGFloat = sidebarRowVerticalPadding
        + sidebarTitleLineHeightBudget
        + sidebarPrimaryLineHeightBudget
        + sidebarStatusLineHeightBudget
        + sidebarContextLineHeightBudget
        + (3 * sidebarRowInterlineSpacing)
    static let sidebarRowCornerRadius: CGFloat = ChromeGeometry.rowRadius
    static let sidebarFooterIconSpacing: CGFloat = 12
    static let footerHeight: CGFloat = 24

    static let trafficLightLeadingInset: CGFloat = ChromeGeometry.trafficLightLeadingInset
    static let trafficLightTopInset: CGFloat = ChromeGeometry.trafficLightTopInset
    static let trafficLightSpacing: CGFloat = ChromeGeometry.trafficLightSpacing

    static func sidebarRowHeight(
        includesTopLabel: Bool,
        includesStatus: Bool,
        detailLineCount: Int,
        includesOverflow: Bool,
        includesArtifact: Bool
    ) -> CGFloat {
        let clampedDetailLineCount = max(0, detailLineCount)
        let visibleLineHeights: [CGFloat] = [
            includesTopLabel ? sidebarTitleLineHeightBudget : nil,
            sidebarPrimaryLineHeightBudget,
            includesStatus ? sidebarStatusLineHeightBudget : nil,
        ]
            .compactMap { $0 }
            + Array(repeating: sidebarContextLineHeightBudget, count: clampedDetailLineCount)
            + (includesOverflow ? [sidebarContextLineHeightBudget] : [])

        let textHeight = visibleLineHeights.reduce(0, +)
        let spacingHeight = CGFloat(max(0, visibleLineHeights.count - 1)) * sidebarRowInterlineSpacing
        let extraDetailBreathingRoom = CGFloat(max(0, clampedDetailLineCount - 1)) * sidebarRowInterlineSpacing
        let computedHeight = sidebarRowVerticalPadding + textHeight + spacingHeight + extraDetailBreathingRoom

        guard includesArtifact else {
            return computedHeight
        }

        return max(computedHeight, sidebarExpandedRowHeight)
    }
}
