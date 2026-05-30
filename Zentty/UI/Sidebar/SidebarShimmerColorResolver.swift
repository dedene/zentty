import AppKit

enum SidebarShimmerColorResolver {
    enum Treatment {
        case highlight
        case shadow
    }

    enum ColoredEmphasis {
        case full
        case focusedPane
        case unfocusedPane
    }

    static func shimmerColor(
        baseTextColor: NSColor,
        worklaneColor: WorklaneColor?,
        coloredEmphasis: ColoredEmphasis,
        treatment: Treatment,
        isActive: Bool,
        theme: ZenttyTheme
    ) -> NSColor {
        guard let worklaneColor else {
            return legacyShimmerColor(
                baseTextColor: baseTextColor,
                treatment: treatment,
                isActive: isActive,
                theme: theme
            )
        }

        let baseColor = worklaneColor.tint(alpha: 1)
        let resolved: NSColor
        let alpha: CGFloat
        switch treatment {
        case .highlight:
            resolved = hsbAdjusted(
                baseColor,
                saturationMultiplier: 1.08,
                brightnessMultiplier: theme.sidebarGlassAppearance == .dark ? 1.12 : 0.86
            )
            alpha = highlightAlpha(isActive: isActive, theme: theme)

        case .shadow:
            resolved = hsbAdjusted(
                baseColor,
                saturationMultiplier: 1.12,
                brightnessMultiplier: theme.sidebarGlassAppearance == .dark ? 0.56 : 0.62
            )
            alpha = shadowAlpha(isActive: isActive, theme: theme)
        }

        let toned = tonedColoredShimmer(
            resolved,
            emphasis: coloredEmphasis,
            theme: theme
        )
        return toned.withAlphaComponent(alpha * alphaMultiplier(for: coloredEmphasis))
    }

    private static func legacyShimmerColor(
        baseTextColor: NSColor,
        treatment: Treatment,
        isActive: Bool,
        theme: ZenttyTheme
    ) -> NSColor {
        switch treatment {
        case .highlight:
            return baseTextColor.withAlphaComponent(highlightAlpha(isActive: isActive, theme: theme))
        case .shadow:
            let shadowTarget = theme.sidebarGlassAppearance == .dark
                ? NSColor.black
                : theme.sidebarBackground
            return baseTextColor
                .mixed(towards: shadowTarget, amount: theme.sidebarGlassAppearance == .dark ? 0.82 : 0.74)
                .withAlphaComponent(shadowAlpha(isActive: isActive, theme: theme))
        }
    }

    private static func highlightAlpha(isActive: Bool, theme: ZenttyTheme) -> CGFloat {
        if theme.reducedTransparency {
            return isActive ? 1.0 : 0.72
        }

        return isActive ? 1.0 : 0.86
    }

    private static func shadowAlpha(isActive: Bool, theme: ZenttyTheme) -> CGFloat {
        if theme.reducedTransparency {
            return isActive ? 0.64 : 0.54
        }

        return isActive ? 0.72 : 0.60
    }

    private static func hsbAdjusted(
        _ color: NSColor,
        saturationMultiplier: CGFloat,
        brightnessMultiplier: CGFloat
    ) -> NSColor {
        let source = color.srgbClamped
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            deviceHue: hue,
            saturation: clamp(saturation * saturationMultiplier),
            brightness: clamp(brightness * brightnessMultiplier),
            alpha: alpha
        )
    }

    private static func tonedColoredShimmer(
        _ color: NSColor,
        emphasis: ColoredEmphasis,
        theme: ZenttyTheme
    ) -> NSColor {
        switch emphasis {
        case .full:
            return color
        case .focusedPane:
            return desaturated(color, saturationMultiplier: 0.68)
                .mixed(towards: neutralTarget(for: theme), amount: theme.sidebarGlassAppearance == .dark ? 0.16 : 0.10)
        case .unfocusedPane:
            // An unfocused pane's primary text is rendered in neutral dim grey
            // (`theme.secondaryText`), so a chromatic band reads as a stray
            // colour streak sweeping across otherwise-grey glyphs. Keep only a
            // whisper of the worklane hue and let the sweep read mostly as a
            // faint brightness sheen — the neutral-mix target is already
            // theme-correct (black in dark, a light grey in light).
            return desaturated(color, saturationMultiplier: 0.13)
                .mixed(towards: neutralTarget(for: theme), amount: theme.sidebarGlassAppearance == .dark ? 0.52 : 0.40)
        }
    }

    private static func desaturated(
        _ color: NSColor,
        saturationMultiplier: CGFloat
    ) -> NSColor {
        let source = color.srgbClamped
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            deviceHue: hue,
            saturation: clamp(saturation * saturationMultiplier),
            brightness: brightness,
            alpha: alpha
        )
    }

    private static func neutralTarget(for theme: ZenttyTheme) -> NSColor {
        theme.sidebarGlassAppearance == .dark
            ? NSColor.black
            : theme.sidebarBackground.mixed(towards: NSColor.black, amount: 0.18)
    }

    private static func alphaMultiplier(for emphasis: ColoredEmphasis) -> CGFloat {
        switch emphasis {
        case .full:
            return 1
        case .focusedPane:
            return 0.88
        case .unfocusedPane:
            return 0.58
        }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
