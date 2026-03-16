import AppKit
import QuartzCore

enum ThemeChromeAppearance: Equatable {
    case light
    case dark

    var nsAppearanceName: NSAppearance.Name {
        switch self {
        case .light:
            .aqua
        case .dark:
            .darkAqua
        }
    }
}

struct GhosttyResolvedTheme: Equatable {
    var background: NSColor
    var foreground: NSColor
    var cursorColor: NSColor
    var selectionBackground: NSColor?
    var selectionForeground: NSColor?
    var palette: [Int: NSColor]
    var backgroundOpacity: CGFloat?
    var backgroundBlurRadius: CGFloat?

    static func == (lhs: GhosttyResolvedTheme, rhs: GhosttyResolvedTheme) -> Bool {
        lhs.background.themeToken == rhs.background.themeToken
            && lhs.foreground.themeToken == rhs.foreground.themeToken
            && lhs.cursorColor.themeToken == rhs.cursorColor.themeToken
            && lhs.selectionBackground?.themeToken == rhs.selectionBackground?.themeToken
            && lhs.selectionForeground?.themeToken == rhs.selectionForeground?.themeToken
            && lhs.palette.mapValues(\.themeToken) == rhs.palette.mapValues(\.themeToken)
            && lhs.backgroundOpacity == rhs.backgroundOpacity
            && lhs.backgroundBlurRadius == rhs.backgroundBlurRadius
    }
}

struct ZenttyTheme: Equatable {
    let windowBackground: NSColor
    let sidebarBackground: NSColor
    let sidebarBorder: NSColor
    let sidebarShadow: NSColor
    let topChromeBackground: NSColor
    let topChromeBorder: NSColor
    let canvasBackground: NSColor
    let canvasBorder: NSColor
    let canvasShadow: NSColor
    let contextStripBackground: NSColor
    let contextStripBorder: NSColor
    let workspaceChipBackground: NSColor
    let workspaceChipText: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let paneBorderFocused: NSColor
    let paneBorderUnfocused: NSColor
    let paneFillFocused: NSColor
    let paneFillUnfocused: NSColor
    let paneShadow: NSColor
    let startupSurface: NSColor
    let failureOverlayBackground: NSColor
    let failurePrimaryText: NSColor
    let failureSecondaryText: NSColor
    let sidebarButtonActiveBackground: NSColor
    let sidebarButtonHoverBackground: NSColor
    let sidebarButtonInactiveBackground: NSColor
    let sidebarButtonActiveBorder: NSColor
    let sidebarButtonInactiveBorder: NSColor
    let sidebarButtonActiveText: NSColor
    let sidebarButtonInactiveText: NSColor
    let sidebarGradientStart: NSColor
    let sidebarGradientEnd: NSColor
    let underlapShadow: NSColor
    let sidebarGlassAppearance: ThemeChromeAppearance
    let reducedTransparency: Bool

    static let animationDuration: CFTimeInterval = 0.20

    static func == (lhs: ZenttyTheme, rhs: ZenttyTheme) -> Bool {
        [
            lhs.windowBackground, lhs.sidebarBackground, lhs.sidebarBorder, lhs.sidebarShadow,
            lhs.topChromeBackground, lhs.topChromeBorder, lhs.canvasBackground, lhs.canvasBorder,
            lhs.canvasShadow, lhs.contextStripBackground, lhs.contextStripBorder, lhs.workspaceChipBackground, lhs.workspaceChipText,
            lhs.primaryText, lhs.secondaryText, lhs.tertiaryText, lhs.paneBorderFocused,
            lhs.paneBorderUnfocused, lhs.paneFillFocused, lhs.paneFillUnfocused, lhs.paneShadow,
            lhs.startupSurface, lhs.failureOverlayBackground, lhs.failurePrimaryText,
            lhs.failureSecondaryText, lhs.sidebarButtonActiveBackground, lhs.sidebarButtonHoverBackground,
            lhs.sidebarButtonInactiveBackground, lhs.sidebarButtonActiveBorder, lhs.sidebarButtonInactiveBorder,
            lhs.sidebarButtonActiveText, lhs.sidebarButtonInactiveText, lhs.sidebarGradientStart,
            lhs.sidebarGradientEnd,
            lhs.underlapShadow,
        ].map(\.themeToken) == [
            rhs.windowBackground, rhs.sidebarBackground, rhs.sidebarBorder, rhs.sidebarShadow,
            rhs.topChromeBackground, rhs.topChromeBorder, rhs.canvasBackground, rhs.canvasBorder,
            rhs.canvasShadow, rhs.contextStripBackground, rhs.contextStripBorder, rhs.workspaceChipBackground, rhs.workspaceChipText,
            rhs.primaryText, rhs.secondaryText, rhs.tertiaryText, rhs.paneBorderFocused,
            rhs.paneBorderUnfocused, rhs.paneFillFocused, rhs.paneFillUnfocused, rhs.paneShadow,
            rhs.startupSurface, rhs.failureOverlayBackground, rhs.failurePrimaryText,
            rhs.failureSecondaryText, rhs.sidebarButtonActiveBackground, rhs.sidebarButtonHoverBackground,
            rhs.sidebarButtonInactiveBackground, rhs.sidebarButtonActiveBorder, rhs.sidebarButtonInactiveBorder,
            rhs.sidebarButtonActiveText, rhs.sidebarButtonInactiveText, rhs.sidebarGradientStart,
            rhs.sidebarGradientEnd,
            rhs.underlapShadow,
        ].map(\.themeToken)
            && lhs.sidebarGlassAppearance == rhs.sidebarGlassAppearance
            && lhs.reducedTransparency == rhs.reducedTransparency
    }

    init(
        resolvedTheme: GhosttyResolvedTheme,
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    ) {
        let background = resolvedTheme.background.srgbClamped
        let foreground = resolvedTheme.foreground.srgbClamped
        let accent = (resolvedTheme.cursorColor).srgbClamped

        let softnessHint = min(max((resolvedTheme.backgroundBlurRadius ?? 0) / 120, 0), 0.10)
        let baseSidebar = background.isDarkThemeColor
            ? background
                .mixed(towards: NSColor.black, amount: 0.24)
                .mixed(towards: accent, amount: 0.04)
            : background
                .mixed(towards: foreground, amount: 0.08 + softnessHint)
        let sidebarRowSelectedBase = background.isDarkThemeColor
            ? background
                .mixed(towards: NSColor.black, amount: 0.18)
                .mixed(towards: foreground, amount: 0.04)
            : foreground
                .mixed(towards: background, amount: 0.12)
        let sidebarRowHoverBase = background.isDarkThemeColor
            ? baseSidebar.mixed(towards: foreground, amount: 0.12)
            : foreground.mixed(towards: background, amount: 0.24)
        let sidebarRowIdleBase = background.isDarkThemeColor
            ? baseSidebar.mixed(towards: foreground, amount: 0.22)
            : baseSidebar.mixed(towards: foreground, amount: 0.18)

        self.reducedTransparency = reduceTransparency
        sidebarGlassAppearance = background.isDarkThemeColor ? .dark : .light
        startupSurface = background.withAlphaComponent(1)
        windowBackground = startupSurface
        sidebarBackground = baseSidebar.withAlphaComponent(reduceTransparency ? 0.92 : (background.isDarkThemeColor ? 0.42 : 0.74))
        sidebarBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.10)
        sidebarShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.05)
        canvasBackground = startupSurface
        topChromeBackground = canvasBackground
        topChromeBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.06 : 0.08)
        canvasBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.14)
        canvasShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.12 + softnessHint : 0.06 + (softnessHint * 0.35))
        contextStripBackground = accent
            .mixed(towards: startupSurface, amount: background.isDarkThemeColor ? 0.88 : 0.92)
            .withAlphaComponent(reduceTransparency ? 0.94 : 0.74)
        contextStripBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.10 : 0.12)
        workspaceChipBackground = accent
            .mixed(towards: background, amount: background.isDarkThemeColor ? 0.82 : 0.88)
            .withAlphaComponent(0.92)
        workspaceChipText = foreground.withAlphaComponent(0.96)
        primaryText = foreground.withAlphaComponent(0.96)
        secondaryText = foreground.withAlphaComponent(0.72)
        tertiaryText = foreground.withAlphaComponent(0.54)
        paneBorderFocused = accent.withAlphaComponent(background.isDarkThemeColor ? 0.42 : 0.34)
        paneBorderUnfocused = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.13 : 0.10)
        paneFillFocused = background.mixed(towards: accent, amount: 0.08).withAlphaComponent(0.98)
        paneFillUnfocused = background.withAlphaComponent(0.96)
        paneShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.06)
        failureOverlayBackground = background.mixed(towards: foreground, amount: 0.08).withAlphaComponent(0.92)
        failurePrimaryText = foreground.withAlphaComponent(0.96)
        failureSecondaryText = foreground.withAlphaComponent(0.72)
        sidebarButtonActiveBackground = sidebarRowSelectedBase.withAlphaComponent(
            reduceTransparency ? 0.94 : (background.isDarkThemeColor ? 0.62 : 0.88)
        )
        sidebarButtonHoverBackground = sidebarRowHoverBase.withAlphaComponent(
            reduceTransparency ? 0.28 : (background.isDarkThemeColor ? 0.28 : 0.42)
        )
        sidebarButtonInactiveBackground = sidebarRowIdleBase.withAlphaComponent(
            reduceTransparency ? 0.10 : (background.isDarkThemeColor ? 0.12 : 0.08)
        )
        sidebarButtonActiveBorder = accent.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.10)
        sidebarButtonInactiveBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.10 : 0.12)
        sidebarButtonActiveText = background.isDarkThemeColor
            ? foreground.withAlphaComponent(0.98)
            : NSColor.white.withAlphaComponent(0.96)
        sidebarButtonInactiveText = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.74 : 0.72)
        sidebarGradientStart = baseSidebar
            .mixed(towards: NSColor.black, amount: background.isDarkThemeColor ? 0.12 : 0.04)
            .withAlphaComponent(reduceTransparency ? 0.05 : (background.isDarkThemeColor ? 0.18 : 0.12))
        sidebarGradientEnd = baseSidebar
            .mixed(towards: foreground, amount: background.isDarkThemeColor ? 0.05 : 0.12)
            .withAlphaComponent(reduceTransparency ? 0.04 : (background.isDarkThemeColor ? 0.10 : 0.08))
        underlapShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.06)
    }

    static func fallback(
        for appearance: NSAppearance?,
        reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    ) -> ZenttyTheme {
        let isDarkMode = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let resolvedTheme = GhosttyResolvedTheme(
            background: isDarkMode
                ? NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
                : NSColor(calibratedRed: 0.77, green: 0.85, blue: 0.91, alpha: 1),
            foreground: isDarkMode
                ? NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1)
                : NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.17, alpha: 1),
            cursorColor: isDarkMode
                ? NSColor(calibratedRed: 0.44, green: 0.72, blue: 1.0, alpha: 1)
                : NSColor(calibratedRed: 0.19, green: 0.46, blue: 0.88, alpha: 1),
            selectionBackground: nil,
            selectionForeground: nil,
            palette: [:],
            backgroundOpacity: isDarkMode ? 0.92 : 0.94,
            backgroundBlurRadius: 18
        )
        return ZenttyTheme(resolvedTheme: resolvedTheme, reduceTransparency: reduceTransparency)
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let normalized = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&value) else {
            return nil
        }

        switch normalized.count {
        case 6:
            self.init(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        case 8:
            self.init(
                srgbRed: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        default:
            return nil
        }
    }

    var srgbClamped: NSColor {
        let converted = usingColorSpace(.sRGB) ?? self
        return NSColor(
            srgbRed: min(max(converted.redComponent, 0), 1),
            green: min(max(converted.greenComponent, 0), 1),
            blue: min(max(converted.blueComponent, 0), 1),
            alpha: min(max(converted.alphaComponent, 0), 1)
        )
    }

    var themeHexString: String {
        let color = srgbClamped
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    var themeAlphaComponentRounded: Int {
        Int(round(srgbClamped.alphaComponent * 1000))
    }

    var themeToken: String {
        "\(themeHexString)-\(themeAlphaComponentRounded)"
    }

    var isDarkThemeColor: Bool {
        perceivedLuminance < 0.48
    }

    var perceivedLuminance: CGFloat {
        let color = srgbClamped
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return (0.2126 * channel(color.redComponent))
            + (0.7152 * channel(color.greenComponent))
            + (0.0722 * channel(color.blueComponent))
    }

    func mixed(towards other: NSColor, amount: CGFloat) -> NSColor {
        let source = srgbClamped
        let target = other.srgbClamped
        let clamped = min(max(amount, 0), 1)
        return NSColor(
            srgbRed: source.redComponent + ((target.redComponent - source.redComponent) * clamped),
            green: source.greenComponent + ((target.greenComponent - source.greenComponent) * clamped),
            blue: source.blueComponent + ((target.blueComponent - source.blueComponent) * clamped),
            alpha: source.alphaComponent + ((target.alphaComponent - source.alphaComponent) * clamped)
        )
    }
}

func performThemeAnimation(animated: Bool, updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    if animated {
        CATransaction.setAnimationDuration(ZenttyTheme.animationDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    }
    updates()
    CATransaction.commit()
}
