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
    let worklaneChipBackground: NSColor
    let worklaneChipText: NSColor
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
    let sidebarWorkingTextHighlight: NSColor
    let sidebarGradientStart: NSColor
    let sidebarGradientEnd: NSColor
    let statusRunning: NSColor
    let statusNeedsInput: NSColor
    let statusStopped: NSColor
    let statusReady: NSColor
    let statusIdle: NSColor
    let openWithChromeBackground: NSColor
    let openWithChromeBorder: NSColor
    let openWithChromeDivider: NSColor
    let openWithChromePrimaryTint: NSColor
    let openWithChromeChevronTint: NSColor
    let openWithChromeHoverBackground: NSColor
    let openWithChromePressedBackground: NSColor
    let openWithPopoverBackground: NSColor
    let openWithPopoverBorder: NSColor
    let openWithPopoverShadow: NSColor
    let openWithPopoverText: NSColor
    let openWithPopoverSecondaryText: NSColor
    let openWithPopoverRowHoverBackground: NSColor
    let openWithPopoverRowSelectedBackground: NSColor
    let openWithPopoverRowSelectedBorder: NSColor
    let openWithPopoverFooterSeparator: NSColor
    let notificationPanelBackground: NSColor
    let notificationPanelBorder: NSColor
    let notificationPanelShadow: NSColor
    let notificationPanelSeparator: NSColor
    let notificationPanelRowHoverBackground: NSColor
    let notificationPanelRowSelectedBackground: NSColor
    let commandPaletteBackground: NSColor
    let commandPaletteBorder: NSColor
    let commandPaletteShadow: NSColor
    let commandPaletteText: NSColor
    let commandPaletteSecondaryText: NSColor
    let commandPaletteRowHoverBackground: NSColor
    let commandPaletteRowSelectedBackground: NSColor
    let commandPaletteSeparator: NSColor
    let underlapShadow: NSColor
    let sidebarGlassAppearance: ThemeChromeAppearance
    let reducedTransparency: Bool

    static let animationDuration: CFTimeInterval = 0.20

    static func == (lhs: ZenttyTheme, rhs: ZenttyTheme) -> Bool {
        [
            lhs.windowBackground, lhs.sidebarBackground, lhs.sidebarBorder, lhs.sidebarShadow,
            lhs.topChromeBackground, lhs.topChromeBorder, lhs.canvasBackground, lhs.canvasBorder,
            lhs.canvasShadow, lhs.contextStripBackground, lhs.contextStripBorder, lhs.worklaneChipBackground, lhs.worklaneChipText,
            lhs.primaryText, lhs.secondaryText, lhs.tertiaryText, lhs.paneBorderFocused,
            lhs.paneBorderUnfocused, lhs.paneFillFocused, lhs.paneFillUnfocused, lhs.paneShadow,
            lhs.startupSurface, lhs.failureOverlayBackground, lhs.failurePrimaryText,
            lhs.failureSecondaryText, lhs.sidebarButtonActiveBackground, lhs.sidebarButtonHoverBackground,
            lhs.sidebarButtonInactiveBackground, lhs.sidebarButtonActiveBorder, lhs.sidebarButtonInactiveBorder,
            lhs.sidebarButtonActiveText, lhs.sidebarButtonInactiveText, lhs.sidebarWorkingTextHighlight, lhs.sidebarGradientStart,
            lhs.sidebarGradientEnd, lhs.openWithChromeBackground, lhs.openWithChromeBorder,
            lhs.openWithChromeDivider, lhs.openWithChromePrimaryTint, lhs.openWithChromeChevronTint,
            lhs.openWithChromeHoverBackground, lhs.openWithChromePressedBackground, lhs.openWithPopoverBackground,
            lhs.openWithPopoverBorder, lhs.openWithPopoverShadow, lhs.openWithPopoverText,
            lhs.openWithPopoverSecondaryText, lhs.openWithPopoverRowHoverBackground,
            lhs.openWithPopoverRowSelectedBackground, lhs.openWithPopoverRowSelectedBorder,
            lhs.openWithPopoverFooterSeparator,
            lhs.notificationPanelBackground, lhs.notificationPanelBorder, lhs.notificationPanelShadow,
            lhs.notificationPanelSeparator, lhs.notificationPanelRowHoverBackground,
            lhs.notificationPanelRowSelectedBackground,
            lhs.commandPaletteBackground, lhs.commandPaletteBorder, lhs.commandPaletteShadow,
            lhs.commandPaletteText, lhs.commandPaletteSecondaryText,
            lhs.commandPaletteRowHoverBackground, lhs.commandPaletteRowSelectedBackground,
            lhs.commandPaletteSeparator,
            lhs.underlapShadow,
            lhs.statusRunning, lhs.statusNeedsInput, lhs.statusStopped, lhs.statusReady, lhs.statusIdle,
        ].map(\.themeToken) == [
            rhs.windowBackground, rhs.sidebarBackground, rhs.sidebarBorder, rhs.sidebarShadow,
            rhs.topChromeBackground, rhs.topChromeBorder, rhs.canvasBackground, rhs.canvasBorder,
            rhs.canvasShadow, rhs.contextStripBackground, rhs.contextStripBorder, rhs.worklaneChipBackground, rhs.worklaneChipText,
            rhs.primaryText, rhs.secondaryText, rhs.tertiaryText, rhs.paneBorderFocused,
            rhs.paneBorderUnfocused, rhs.paneFillFocused, rhs.paneFillUnfocused, rhs.paneShadow,
            rhs.startupSurface, rhs.failureOverlayBackground, rhs.failurePrimaryText,
            rhs.failureSecondaryText, rhs.sidebarButtonActiveBackground, rhs.sidebarButtonHoverBackground,
            rhs.sidebarButtonInactiveBackground, rhs.sidebarButtonActiveBorder, rhs.sidebarButtonInactiveBorder,
            rhs.sidebarButtonActiveText, rhs.sidebarButtonInactiveText, rhs.sidebarWorkingTextHighlight, rhs.sidebarGradientStart,
            rhs.sidebarGradientEnd, rhs.openWithChromeBackground, rhs.openWithChromeBorder,
            rhs.openWithChromeDivider, rhs.openWithChromePrimaryTint, rhs.openWithChromeChevronTint,
            rhs.openWithChromeHoverBackground, rhs.openWithChromePressedBackground, rhs.openWithPopoverBackground,
            rhs.openWithPopoverBorder, rhs.openWithPopoverShadow, rhs.openWithPopoverText,
            rhs.openWithPopoverSecondaryText, rhs.openWithPopoverRowHoverBackground,
            rhs.openWithPopoverRowSelectedBackground, rhs.openWithPopoverRowSelectedBorder,
            rhs.openWithPopoverFooterSeparator,
            rhs.notificationPanelBackground, rhs.notificationPanelBorder, rhs.notificationPanelShadow,
            rhs.notificationPanelSeparator, rhs.notificationPanelRowHoverBackground,
            rhs.notificationPanelRowSelectedBackground,
            rhs.commandPaletteBackground, rhs.commandPaletteBorder, rhs.commandPaletteShadow,
            rhs.commandPaletteText, rhs.commandPaletteSecondaryText,
            rhs.commandPaletteRowHoverBackground, rhs.commandPaletteRowSelectedBackground,
            rhs.commandPaletteSeparator,
            rhs.underlapShadow,
            rhs.statusRunning, rhs.statusNeedsInput, rhs.statusStopped, rhs.statusReady, rhs.statusIdle,
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
        let readableForeground = foreground.ensuringTextContrast(on: background)
        let readableSidebarText = foreground.ensuringTextContrast(on: baseSidebar)
        let readableSidebarActiveText = foreground.ensuringTextContrast(on: sidebarRowSelectedBase)
        let startupSurfaceBase = background.withAlphaComponent(1)
        let openWithChromeBase = accent
            .mixed(towards: startupSurfaceBase, amount: background.isDarkThemeColor ? 0.92 : 0.95)
        let openWithPopoverBase = baseSidebar
            .mixed(towards: startupSurfaceBase, amount: background.isDarkThemeColor ? 0.14 : 0.32)
        let notificationPanelBase = background.isDarkThemeColor
            ? openWithPopoverBase
                .mixed(towards: NSColor.black, amount: 0.18)
                .mixed(towards: startupSurfaceBase, amount: 0.04)
            : openWithPopoverBase
                .mixed(towards: foreground, amount: 0.06)
                .mixed(towards: startupSurfaceBase, amount: 0.10)

        self.reducedTransparency = reduceTransparency
        sidebarGlassAppearance = background.isDarkThemeColor ? .dark : .light
        startupSurface = startupSurfaceBase
        windowBackground = startupSurfaceBase
        sidebarBackground = baseSidebar.withAlphaComponent(reduceTransparency ? 0.92 : (background.isDarkThemeColor ? 0.42 : 0.74))
        sidebarBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.10)
        sidebarShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.05)
        canvasBackground = startupSurfaceBase
        topChromeBackground = startupSurfaceBase
        topChromeBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.06 : 0.08)
        canvasBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.14)
        canvasShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.12 + softnessHint : 0.06 + (softnessHint * 0.35))
        contextStripBackground = accent
            .mixed(towards: startupSurfaceBase, amount: background.isDarkThemeColor ? 0.88 : 0.92)
            .withAlphaComponent(reduceTransparency ? 0.94 : 0.74)
        contextStripBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.10 : 0.12)
        worklaneChipBackground = accent
            .mixed(towards: background, amount: background.isDarkThemeColor ? 0.82 : 0.88)
            .withAlphaComponent(0.92)
        worklaneChipText = readableForeground.withAlphaComponent(0.96)
        primaryText = readableForeground.withAlphaComponent(0.96)
        secondaryText = readableForeground.withAlphaComponent(0.72)
        tertiaryText = readableForeground.withAlphaComponent(0.54)
        paneBorderFocused = accent.withAlphaComponent(background.isDarkThemeColor ? 0.42 : 0.34)
        paneBorderUnfocused = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.13 : 0.10)
        paneFillFocused = background.mixed(towards: accent, amount: 0.08).withAlphaComponent(0.98)
        paneFillUnfocused = background.withAlphaComponent(0.96)
        paneShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.12 : 0.06)
        failureOverlayBackground = background.mixed(towards: foreground, amount: 0.08).withAlphaComponent(0.92)
        failurePrimaryText = readableForeground.withAlphaComponent(0.96)
        failureSecondaryText = readableForeground.withAlphaComponent(0.72)
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
        sidebarButtonActiveText = readableSidebarActiveText.withAlphaComponent(background.isDarkThemeColor ? 0.98 : 0.96)
        sidebarButtonInactiveText = readableSidebarText.withAlphaComponent(background.isDarkThemeColor ? 0.74 : 0.72)
        sidebarWorkingTextHighlight = background.isDarkThemeColor
            ? readableSidebarText.mixed(towards: NSColor.white, amount: 0.14)
            : readableSidebarText.mixed(towards: NSColor.white, amount: 0.82)
        sidebarGradientStart = baseSidebar
            .mixed(towards: NSColor.black, amount: background.isDarkThemeColor ? 0.12 : 0.04)
            .withAlphaComponent(reduceTransparency ? 0.05 : (background.isDarkThemeColor ? 0.18 : 0.12))
        sidebarGradientEnd = baseSidebar
            .mixed(towards: foreground, amount: background.isDarkThemeColor ? 0.05 : 0.12)
            .withAlphaComponent(reduceTransparency ? 0.04 : (background.isDarkThemeColor ? 0.10 : 0.08))

        let isDark = background.isDarkThemeColor
        let palette = resolvedTheme.palette
        let paletteBlue = ((isDark ? palette[12] : palette[4]) ?? palette[4])?.srgbClamped
            ?? accent
        let paletteYellow = ((isDark ? palette[11] : palette[3]) ?? palette[3])?.srgbClamped
            ?? foreground.mixed(towards: NSColor(srgbRed: 1.0, green: 0.70, blue: 0.20, alpha: 1), amount: 0.82)
        let paletteRed = ((isDark ? palette[9] : palette[1]) ?? palette[1])?.srgbClamped
            ?? foreground.mixed(towards: NSColor(srgbRed: 1.0, green: 0.30, blue: 0.30, alpha: 1), amount: 0.82)
        let paletteGreen = ((isDark ? palette[10] : palette[2]) ?? palette[2])?.srgbClamped
            ?? foreground.mixed(towards: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.40, alpha: 1), amount: 0.82)
        statusRunning = paletteBlue
        statusNeedsInput = paletteYellow
        statusStopped = paletteRed
        statusReady = paletteGreen
        statusIdle = accent.withAlphaComponent(isDark ? 0.54 : 0.48)

        openWithChromeBackground = openWithChromeBase.withAlphaComponent(
            reduceTransparency ? 0.96 : (background.isDarkThemeColor ? 0.60 : 0.82)
        )
        openWithChromeBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.10)
        openWithChromeDivider = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.035 : 0.055)
        openWithChromePrimaryTint = readableForeground.withAlphaComponent(0.96)
        openWithChromeChevronTint = readableForeground.withAlphaComponent(background.isDarkThemeColor ? 0.68 : 0.62)
        openWithChromeHoverBackground = openWithChromeBase
            .mixed(towards: foreground, amount: background.isDarkThemeColor ? 0.08 : 0.12)
            .withAlphaComponent(reduceTransparency ? 0.18 : (background.isDarkThemeColor ? 0.18 : 0.24))
        openWithChromePressedBackground = openWithChromeBase
            .mixed(towards: foreground, amount: background.isDarkThemeColor ? 0.14 : 0.18)
            .withAlphaComponent(reduceTransparency ? 0.24 : (background.isDarkThemeColor ? 0.26 : 0.32))
        openWithPopoverBackground = openWithPopoverBase.withAlphaComponent(
            reduceTransparency ? 0.96 : (background.isDarkThemeColor ? 0.72 : 0.84)
        )
        openWithPopoverBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.10)
        openWithPopoverShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.22 : 0.10)
        openWithPopoverText = readableForeground.withAlphaComponent(0.96)
        openWithPopoverSecondaryText = readableForeground.withAlphaComponent(0.70)
        openWithPopoverRowHoverBackground = sidebarRowHoverBase.withAlphaComponent(
            reduceTransparency ? 0.26 : (background.isDarkThemeColor ? 0.26 : 0.34)
        )
        openWithPopoverRowSelectedBackground = accent
            .mixed(towards: openWithPopoverBase, amount: background.isDarkThemeColor ? 0.78 : 0.84)
            .withAlphaComponent(reduceTransparency ? 0.92 : (background.isDarkThemeColor ? 0.56 : 0.72))
        openWithPopoverRowSelectedBorder = accent.withAlphaComponent(background.isDarkThemeColor ? 0.22 : 0.18)
        openWithPopoverFooterSeparator = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.06 : 0.08)
        notificationPanelBackground = notificationPanelBase.withAlphaComponent(
            reduceTransparency ? 0.98 : (background.isDarkThemeColor ? 0.84 : 0.92)
        )
        notificationPanelBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.11 : 0.13)
        notificationPanelShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.30 : 0.15)
        notificationPanelSeparator = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.09 : 0.10)
        notificationPanelRowHoverBackground = notificationPanelBase
            .mixed(towards: readableForeground, amount: background.isDarkThemeColor ? 0.10 : 0.16)
            .withAlphaComponent(reduceTransparency ? 0.20 : (background.isDarkThemeColor ? 0.20 : 0.26))
        notificationPanelRowSelectedBackground = accent
            .mixed(towards: notificationPanelBase, amount: background.isDarkThemeColor ? 0.66 : 0.76)
            .withAlphaComponent(reduceTransparency ? 0.94 : (background.isDarkThemeColor ? 0.68 : 0.78))
        let commandPaletteBase = baseSidebar
            .mixed(towards: startupSurfaceBase, amount: background.isDarkThemeColor ? 0.18 : 0.36)
        commandPaletteBackground = commandPaletteBase.withAlphaComponent(
            reduceTransparency ? 0.98 : (background.isDarkThemeColor ? 0.78 : 0.88)
        )
        commandPaletteBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.10 : 0.12)
        commandPaletteShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.28 : 0.14)
        commandPaletteText = readableForeground.withAlphaComponent(0.96)
        commandPaletteSecondaryText = readableForeground.withAlphaComponent(0.62)
        commandPaletteRowHoverBackground = commandPaletteBase
            .mixed(towards: readableForeground, amount: background.isDarkThemeColor ? 0.10 : 0.14)
            .withAlphaComponent(reduceTransparency ? 0.22 : (background.isDarkThemeColor ? 0.22 : 0.28))
        commandPaletteRowSelectedBackground = accent
            .mixed(towards: commandPaletteBase, amount: background.isDarkThemeColor ? 0.62 : 0.72)
            .withAlphaComponent(reduceTransparency ? 0.94 : (background.isDarkThemeColor ? 0.64 : 0.76))
        commandPaletteSeparator = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.08 : 0.10)
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

    var brightenedForLabel: NSColor {
        mixed(towards: .white, amount: 0.35)
    }

    func contrastRatio(against other: NSColor) -> CGFloat {
        let lighter = max(perceivedLuminance, other.perceivedLuminance)
        let darker = min(perceivedLuminance, other.perceivedLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func ensuringTextContrast(on background: NSColor, minimum: CGFloat = 4.5) -> NSColor {
        let preferred = srgbClamped.withAlphaComponent(1)
        guard preferred.contrastRatio(against: background) < minimum else {
            return preferred
        }

        let lightFallback = NSColor(calibratedWhite: 0.98, alpha: 1)
        let darkFallback = NSColor(calibratedWhite: 0.08, alpha: 1)
        let lightContrast = lightFallback.contrastRatio(against: background)
        let darkContrast = darkFallback.contrastRatio(against: background)
        return lightContrast >= darkContrast ? lightFallback : darkFallback
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

    func adjustedHSB(
        saturationBy saturationDelta: CGFloat = 0,
        brightnessBy brightnessDelta: CGFloat = 0,
        alphaBy alphaDelta: CGFloat = 0
    ) -> NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else {
            return self
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            deviceHue: hue,
            saturation: min(max(saturation + saturationDelta, 0), 1),
            brightness: min(max(brightness + brightnessDelta, 0), 1),
            alpha: min(max(alpha + alphaDelta, 0), 1)
        )
    }

    func composited(over background: NSColor) -> NSColor {
        let source = srgbClamped
        let destination = background.srgbClamped
        let outputAlpha = source.alphaComponent + (destination.alphaComponent * (1 - source.alphaComponent))

        guard outputAlpha > 0 else {
            return .clear
        }

        let red = (
            (source.redComponent * source.alphaComponent)
                + (destination.redComponent * destination.alphaComponent * (1 - source.alphaComponent))
        ) / outputAlpha
        let green = (
            (source.greenComponent * source.alphaComponent)
                + (destination.greenComponent * destination.alphaComponent * (1 - source.alphaComponent))
        ) / outputAlpha
        let blue = (
            (source.blueComponent * source.alphaComponent)
                + (destination.blueComponent * destination.alphaComponent * (1 - source.alphaComponent))
        ) / outputAlpha

        return NSColor(srgbRed: red, green: green, blue: blue, alpha: outputAlpha)
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
