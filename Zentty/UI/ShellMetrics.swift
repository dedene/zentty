import AppKit

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
    enum SidebarRowTypography {
        static func topLabelFont() -> NSFont {
            NSFont.systemFont(ofSize: 11, weight: .semibold)
        }

        static func primaryFont() -> NSFont {
            NSFont.systemFont(ofSize: 13, weight: .semibold)
        }

        static func statusFont() -> NSFont {
            NSFont.systemFont(ofSize: 11, weight: .semibold)
        }

        static func detailFont() -> NSFont {
            NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }

        static func overflowFont() -> NSFont {
            NSFont.systemFont(ofSize: 11, weight: .regular)
        }

        static let topLabelLineHeight = lineHeight(for: topLabelFont())
        static let primaryLineHeight = lineHeight(for: primaryFont())
        static let statusLineHeight = lineHeight(for: statusFont())
        static let detailLineHeight = lineHeight(for: detailFont())
        static let overflowLineHeight = lineHeight(for: overflowFont())

        private static func lineHeight(for font: NSFont) -> CGFloat {
            let label = NSTextField(labelWithString: "Ag")
            label.font = font
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            return ceil(label.fittingSize.height)
        }
    }

    static let outerInset: CGFloat = ChromeGeometry.shellInset
    static let shellGap: CGFloat = ChromeGeometry.shellInset
    static let canvasOuterInset: CGFloat = outerInset
    static let canvasSidebarGap: CGFloat = shellGap

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
    static let sidebarHeaderHeight: CGFloat = 58
    static let sidebarTopInset: CGFloat = sidebarHeaderHeight
    static let sidebarBottomInset: CGFloat = 18
    static let sidebarRowHorizontalInset: CGFloat = 12
    static let sidebarWorklaneTextHorizontalInset: CGFloat = 6
    static let sidebarRowTopInset: CGFloat = 8
    static let sidebarRowBottomInset: CGFloat = 8
    static let sidebarRowVerticalPadding: CGFloat = sidebarRowTopInset + sidebarRowBottomInset
    static let sidebarRowInterlineSpacing: CGFloat = 3
    static let sidebarTitleLineHeight: CGFloat = SidebarRowTypography.topLabelLineHeight
    static let sidebarPrimaryLineHeight: CGFloat = SidebarRowTypography.primaryLineHeight
    static let sidebarStatusLineHeight: CGFloat = SidebarRowTypography.statusLineHeight
    static let sidebarDetailLineHeight: CGFloat = SidebarRowTypography.detailLineHeight
    static let sidebarOverflowLineHeight: CGFloat = SidebarRowTypography.overflowLineHeight
    static let sidebarCompactRowHeight: CGFloat = sidebarRowTopInset
        + sidebarRowBottomInset
        + sidebarPrimaryLineHeight
    static let sidebarExpandedRowHeight: CGFloat = sidebarRowHeight(
        includesTopLabel: true,
        includesStatus: true,
        detailLineCount: 1,
        includesOverflow: false
    )
    static let sidebarRowCornerRadius: CGFloat = ChromeGeometry.rowRadius
    static let sidebarFooterIconSpacing: CGFloat = 12
    static let sidebarCreateWorklaneHorizontalInset: CGFloat = 8
    static let sidebarCreateWorklaneIconSpacing: CGFloat = 10
    static let sidebarCreateWorklaneButtonHeight: CGFloat = 24
    static let sidebarCreateWorklanePinnedVerticalOffset: CGFloat = -10
    static let sidebarCreateWorklanePinnedLeadingPad: CGFloat = 4
    static let footerHeight: CGFloat = sidebarCreateWorklaneButtonHeight
    static let sidebarPaneRowHorizontalInset: CGFloat = 6
    static let sidebarPaneRowVerticalInset: CGFloat = 6
    static let sidebarPaneButtonHorizontalInset: CGFloat = 6
    static let sidebarPaneButtonVerticalInset: CGFloat = 3.5
    static let sidebarPaneButtonCornerRadius: CGFloat = ChromeGeometry.innerRadius(
        outerRadius: sidebarRowCornerRadius,
        inset: sidebarPaneRowHorizontalInset
    )
    static let paneSubRowHeight: CGFloat = 24
    static let paneSubRowIndent: CGFloat = 16

    static let trafficLightLeadingInset: CGFloat = ChromeGeometry.trafficLightLeadingInset
    static let trafficLightTopInset: CGFloat = ChromeGeometry.trafficLightTopInset
    static let trafficLightSpacing: CGFloat = ChromeGeometry.trafficLightSpacing

    static func sidebarRowHeight(
        includesTopLabel: Bool,
        includesStatus: Bool,
        detailLineCount: Int,
        includesOverflow: Bool
    ) -> CGFloat {
        let clampedDetailLineCount = max(0, detailLineCount)
        let visibleLineHeights: [CGFloat] = [
            includesTopLabel ? sidebarTitleLineHeight : nil,
            sidebarPrimaryLineHeight,
            includesStatus ? sidebarStatusLineHeight : nil,
        ]
            .compactMap { $0 }
            + Array(repeating: sidebarDetailLineHeight, count: clampedDetailLineCount)
            + (includesOverflow ? [sidebarOverflowLineHeight] : [])

        let textHeight = visibleLineHeights.reduce(0, +)
        let spacingHeight = CGFloat(max(0, visibleLineHeights.count - 1)) * sidebarRowInterlineSpacing
        return sidebarRowTopInset
            + sidebarRowBottomInset
            + textHeight
            + spacingHeight
    }

    static func sidebarTitleFont() -> NSFont {
        SidebarRowTypography.topLabelFont()
    }

    static func sidebarPrimaryFont() -> NSFont {
        SidebarRowTypography.primaryFont()
    }

    static func sidebarStatusFont() -> NSFont {
        SidebarRowTypography.statusFont()
    }

    static func sidebarDetailFont() -> NSFont {
        SidebarRowTypography.detailFont()
    }

    static func sidebarOverflowFont() -> NSFont {
        SidebarRowTypography.overflowFont()
    }
}
