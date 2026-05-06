import AppKit

enum SidebarWorklaneRowStyleResolver {
    static func tintColor(
        worklaneColor: WorklaneColor?,
        isActive: Bool,
        isHovered: Bool,
        isPaneRowHovered: Bool
    ) -> CGColor {
        guard let worklaneColor else {
            return NSColor.clear.cgColor
        }

        let alpha: CGFloat
        if isActive {
            alpha = WorklaneColor.Alpha.active
        } else if isHovered && !isPaneRowHovered {
            alpha = WorklaneColor.Alpha.hover
        } else {
            alpha = WorklaneColor.Alpha.inactive
        }

        return worklaneColor.tint(alpha: alpha).cgColor
    }

    static func backgroundColor(
        isActive: Bool,
        isWorking: Bool,
        isHovered: Bool,
        isPaneRowHovered: Bool,
        activeBackground: NSColor,
        hoverBackground: NSColor,
        inactiveBackground: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        if isActive {
            guard isWorking else {
                return activeBackground
            }

            return activeBackground
                .mixed(towards: theme.sidebarGradientStart.brightenedForLabel, amount: 0.12)
        }

        if isHovered && !isPaneRowHovered {
            return hoverBackground
        }

        return inactiveBackground
    }

    static func resolvedBackgroundColor(
        isActive: Bool,
        isWorking: Bool,
        isHovered: Bool,
        isPaneRowHovered: Bool,
        isReorderDragActive: Bool,
        activeBackground: NSColor,
        hoverBackground: NSColor,
        inactiveBackground: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        let background = backgroundColor(
            isActive: isActive,
            isWorking: isWorking,
            isHovered: isHovered,
            isPaneRowHovered: isPaneRowHovered,
            activeBackground: activeBackground,
            hoverBackground: hoverBackground,
            inactiveBackground: inactiveBackground,
            theme: theme
        )
        guard isReorderDragActive else {
            return background
        }

        let sidebarSurface = theme.sidebarBackground.composited(
            over: theme.windowBackground
        )
        return background
            .composited(over: sidebarSurface)
            .srgbClamped
            .withAlphaComponent(1)
    }

    static func paneRowInteractionColors(
        worklaneColor: WorklaneColor?,
        theme: ZenttyTheme
    ) -> (hover: NSColor, pressed: NSColor) {
        if let worklaneColor {
            return (
                worklaneColor.tint(alpha: WorklaneColor.Alpha.paneRowHover),
                worklaneColor.tint(alpha: WorklaneColor.Alpha.paneRowPressed)
            )
        }

        return (
            theme.sidebarButtonHoverBackground.withAlphaComponent(0.5),
            theme.sidebarButtonHoverBackground.withAlphaComponent(0.7)
        )
    }

    static func primaryTextColor(
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor
    ) -> NSColor {
        isActive ? activeTextColor : inactiveTextColor
    }

    static func topLabelTextColor(
        isActive: Bool,
        activeTextColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        isActive ? activeTextColor.withAlphaComponent(0.66) : theme.tertiaryText
    }

    static func overflowTextColor(
        isActive: Bool,
        activeTextColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        isActive ? activeTextColor.withAlphaComponent(0.54) : theme.tertiaryText
    }

    static func detailTextColor(
        emphasis: WorklaneSidebarDetailEmphasis,
        isActive: Bool,
        theme: ZenttyTheme
    ) -> NSColor {
        switch emphasis {
        case .primary:
            return isActive
                ? theme.sidebarButtonActiveText.withAlphaComponent(0.78)
                : theme.secondaryText
        case .secondary:
            return isActive
                ? theme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : theme.tertiaryText
        }
    }

    static func panePrimaryTextColor(
        isFocused: Bool,
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        let focusedBaseColor = isActive ? activeTextColor : inactiveTextColor
        return isFocused ? focusedBaseColor : theme.secondaryText
    }

    static func paneTrailingTextColor(
        isFocused: Bool,
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        let focusedBaseColor = isActive ? activeTextColor : inactiveTextColor
        return isFocused ? focusedBaseColor.withAlphaComponent(0.62) : theme.tertiaryText
    }

    static func paneDetailTextColor(
        isFocused: Bool,
        isWorking: Bool,
        isActive: Bool,
        activeTextColor: NSColor,
        inactiveTextColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        let focusedBaseColor = isActive ? activeTextColor : inactiveTextColor
        if isWorking {
            let emphasis = workingTextHighlightColor(
                isActive: isActive,
                inactiveTextColor: inactiveTextColor
            )
            return isFocused ? emphasis.withAlphaComponent(0.68) : emphasis.withAlphaComponent(0.60)
        }

        return isFocused ? focusedBaseColor.withAlphaComponent(0.62) : theme.tertiaryText
    }

    static func statusTextColor(
        attentionState: WorklaneAttentionState?,
        theme: ZenttyTheme
    ) -> NSColor {
        switch attentionState {
        case .running:
            return theme.statusRunning
        case .needsInput:
            return theme.statusNeedsInput
        case .unresolvedStop:
            return theme.statusStopped
        case .ready:
            return theme.statusReady
        case nil:
            return theme.secondaryText
        }
    }

    static func statusShimmerBaseColor(
        statusColor: NSColor,
        theme: ZenttyTheme
    ) -> NSColor {
        if theme.sidebarGlassAppearance == .dark {
            return statusColor.adjustedHSB(
                saturationBy: 0.18,
                brightnessBy: 0.10
            )
        }

        return statusColor.adjustedHSB(
            saturationBy: 0.14,
            brightnessBy: -0.04
        )
    }

    static func shimmerColor(
        baseTextColor: NSColor,
        worklaneColor: WorklaneColor?,
        coloredEmphasis: SidebarShimmerColorResolver.ColoredEmphasis,
        treatment: SidebarShimmerColorResolver.Treatment,
        isActive: Bool,
        theme: ZenttyTheme
    ) -> NSColor {
        SidebarShimmerColorResolver.shimmerColor(
            baseTextColor: baseTextColor,
            worklaneColor: worklaneColor,
            coloredEmphasis: coloredEmphasis,
            treatment: treatment,
            isActive: isActive,
            theme: theme
        )
    }

    static func renderedBaseTextColor(
        _ textColor: NSColor,
        isShimmering: Bool,
        treatment: SidebarShimmerColorResolver.Treatment
    ) -> NSColor {
        guard isShimmering else {
            return textColor
        }

        switch treatment {
        case .highlight:
            return textColor.withAlphaComponent(textColor.alphaComponent * 0.78)
        case .shadow:
            return textColor
        }
    }

    private static func workingTextHighlightColor(
        isActive: Bool,
        inactiveTextColor: NSColor
    ) -> NSColor {
        if isActive {
            return .white
        }

        return inactiveTextColor.mixed(towards: .white, amount: 0.72)
    }
}
