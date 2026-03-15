import AppKit
import QuartzCore

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
    let canvasBackground: NSColor
    let canvasBorder: NSColor
    let canvasShadow: NSColor
    let contextStripBackground: NSColor
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
    let sidebarButtonInactiveBackground: NSColor
    let sidebarButtonActiveBorder: NSColor
    let sidebarButtonActiveText: NSColor
    let sidebarButtonInactiveText: NSColor

    static let animationDuration: CFTimeInterval = 0.20

    static func == (lhs: ZenttyTheme, rhs: ZenttyTheme) -> Bool {
        [
            lhs.windowBackground, lhs.sidebarBackground, lhs.canvasBackground, lhs.canvasBorder,
            lhs.canvasShadow, lhs.contextStripBackground, lhs.workspaceChipBackground, lhs.workspaceChipText,
            lhs.primaryText, lhs.secondaryText, lhs.tertiaryText, lhs.paneBorderFocused,
            lhs.paneBorderUnfocused, lhs.paneFillFocused, lhs.paneFillUnfocused, lhs.paneShadow,
            lhs.startupSurface, lhs.failureOverlayBackground, lhs.failurePrimaryText,
            lhs.failureSecondaryText, lhs.sidebarButtonActiveBackground, lhs.sidebarButtonInactiveBackground,
            lhs.sidebarButtonActiveBorder, lhs.sidebarButtonActiveText, lhs.sidebarButtonInactiveText,
        ].map(\.themeToken) == [
            rhs.windowBackground, rhs.sidebarBackground, rhs.canvasBackground, rhs.canvasBorder,
            rhs.canvasShadow, rhs.contextStripBackground, rhs.workspaceChipBackground, rhs.workspaceChipText,
            rhs.primaryText, rhs.secondaryText, rhs.tertiaryText, rhs.paneBorderFocused,
            rhs.paneBorderUnfocused, rhs.paneFillFocused, rhs.paneFillUnfocused, rhs.paneShadow,
            rhs.startupSurface, rhs.failureOverlayBackground, rhs.failurePrimaryText,
            rhs.failureSecondaryText, rhs.sidebarButtonActiveBackground, rhs.sidebarButtonInactiveBackground,
            rhs.sidebarButtonActiveBorder, rhs.sidebarButtonActiveText, rhs.sidebarButtonInactiveText,
        ].map(\.themeToken)
    }

    init(resolvedTheme: GhosttyResolvedTheme) {
        let background = resolvedTheme.background.srgbClamped
        let foreground = resolvedTheme.foreground.srgbClamped
        let accent = (resolvedTheme.cursorColor).srgbClamped

        let opacityHint = min(max(resolvedTheme.backgroundOpacity ?? 0.92, 0.78), 0.97)
        let softnessHint = min(max((resolvedTheme.backgroundBlurRadius ?? 0) / 120, 0), 0.10)
        let baseWindow = background.mixed(towards: foreground, amount: 0.10 + softnessHint)
        let baseSidebar = background.mixed(towards: foreground, amount: 0.14 + softnessHint)
        let baseCanvas = background.mixed(towards: foreground, amount: 0.06 + (softnessHint * 0.6))

        windowBackground = baseWindow.withAlphaComponent(1)
        sidebarBackground = baseSidebar.withAlphaComponent(opacityHint)
        canvasBackground = baseCanvas.withAlphaComponent(opacityHint)
        canvasBorder = foreground.withAlphaComponent(background.isDarkThemeColor ? 0.18 : 0.16)
        canvasShadow = NSColor.black.withAlphaComponent(background.isDarkThemeColor ? 0.16 + softnessHint : 0.07 + (softnessHint * 0.5))
        contextStripBackground = NSColor.clear
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
        startupSurface = background.withAlphaComponent(1)
        failureOverlayBackground = background.mixed(towards: foreground, amount: 0.08).withAlphaComponent(0.92)
        failurePrimaryText = foreground.withAlphaComponent(0.96)
        failureSecondaryText = foreground.withAlphaComponent(0.72)
        sidebarButtonActiveBackground = accent
            .mixed(towards: background, amount: background.isDarkThemeColor ? 0.78 : 0.86)
            .withAlphaComponent(0.94)
        sidebarButtonInactiveBackground = foreground
            .mixed(towards: background, amount: background.isDarkThemeColor ? 0.92 : 0.96)
            .withAlphaComponent(0.22)
        sidebarButtonActiveBorder = accent.withAlphaComponent(background.isDarkThemeColor ? 0.48 : 0.34)
        sidebarButtonActiveText = foreground.withAlphaComponent(0.98)
        sidebarButtonInactiveText = foreground.withAlphaComponent(0.62)
    }

    static func fallback(for appearance: NSAppearance?) -> ZenttyTheme {
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
        return ZenttyTheme(resolvedTheme: resolvedTheme)
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
