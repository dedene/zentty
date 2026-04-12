import AppKit

enum GlassSurfaceStyle {
    case sidebar
    case openWithPopover
    case notificationPanel
    case commandPalette
    case toast

    var cornerRadius: CGFloat {
        switch self {
        case .sidebar:
            ChromeGeometry.sidebarRadius
        case .openWithPopover, .notificationPanel, .commandPalette:
            16
        case .toast:
            17
        }
    }
}

@MainActor
final class GlassSurfaceView: NSVisualEffectView {
    private let style: GlassSurfaceStyle
    private let gradientLayer = CAGradientLayer()

    init(style: GlassSurfaceStyle) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = false
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.locations = [0, 1]
        layer?.insertSublayer(gradientLayer, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = layer?.cornerRadius ?? style.cornerRadius
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let shadowColor: NSColor
        let cornerRadius: CGFloat
        let gradientColors: [CGColor]
        let shadowRadius: CGFloat
        let shadowOffset: CGSize

        switch style {
        case .sidebar:
            material = theme.reducedTransparency ? .menu : .hudWindow
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.sidebarBackground
            borderColor = theme.sidebarBorder
            shadowColor = theme.sidebarShadow
            cornerRadius = style.cornerRadius
            gradientColors = [
                theme.sidebarGradientStart.cgColor,
                theme.sidebarGradientEnd.cgColor,
            ]
            shadowRadius = 12
            shadowOffset = CGSize(width: 0, height: 10)
        case .openWithPopover:
            material = .menu
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.openWithPopoverBackground
            borderColor = theme.openWithPopoverBorder
            shadowColor = theme.openWithPopoverShadow
            cornerRadius = style.cornerRadius
            gradientColors = [
                theme.openWithPopoverBackground
                    .mixed(towards: .white, amount: theme.sidebarGlassAppearance == .dark ? 0.03 : 0.10)
                    .withAlphaComponent(theme.reducedTransparency ? 0.14 : 0.10)
                    .cgColor,
                theme.openWithPopoverBackground
                    .mixed(towards: .black, amount: theme.sidebarGlassAppearance == .dark ? 0.06 : 0.02)
                    .withAlphaComponent(theme.reducedTransparency ? 0.08 : 0.06)
                    .cgColor,
            ]
            shadowRadius = 18
            shadowOffset = CGSize(width: 0, height: 14)
        case .notificationPanel:
            material = theme.reducedTransparency ? .menu : .hudWindow
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.notificationPanelBackground
            borderColor = theme.notificationPanelBorder
            shadowColor = theme.notificationPanelShadow
            cornerRadius = style.cornerRadius
            gradientColors = [
                theme.notificationPanelBackground
                    .mixed(towards: .white, amount: theme.sidebarGlassAppearance == .dark ? 0.06 : 0.10)
                    .withAlphaComponent(theme.reducedTransparency ? 0.18 : 0.14)
                    .cgColor,
                theme.notificationPanelBackground
                    .mixed(towards: .black, amount: theme.sidebarGlassAppearance == .dark ? 0.10 : 0.04)
                    .withAlphaComponent(theme.reducedTransparency ? 0.10 : 0.08)
                    .cgColor,
            ]
            shadowRadius = 22
            shadowOffset = CGSize(width: 0, height: 18)
        case .commandPalette:
            material = theme.reducedTransparency ? .menu : .hudWindow
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.commandPaletteBackground
            borderColor = theme.commandPaletteBorder
            shadowColor = theme.commandPaletteShadow
            cornerRadius = style.cornerRadius
            gradientColors = [
                theme.commandPaletteBackground
                    .mixed(towards: .white, amount: theme.sidebarGlassAppearance == .dark ? 0.05 : 0.08)
                    .withAlphaComponent(theme.reducedTransparency ? 0.16 : 0.12)
                    .cgColor,
                theme.commandPaletteBackground
                    .mixed(towards: .black, amount: theme.sidebarGlassAppearance == .dark ? 0.08 : 0.03)
                    .withAlphaComponent(theme.reducedTransparency ? 0.10 : 0.07)
                    .cgColor,
            ]
            shadowRadius = 24
            shadowOffset = CGSize(width: 0, height: 16)
        case .toast:
            material = theme.reducedTransparency ? .menu : .hudWindow
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.openWithPopoverBackground
            borderColor = theme.openWithPopoverBorder
            shadowColor = theme.openWithPopoverShadow
            cornerRadius = style.cornerRadius
            gradientColors = [
                theme.openWithPopoverBackground
                    .mixed(towards: .white, amount: theme.sidebarGlassAppearance == .dark ? 0.015 : 0.04)
                    .withAlphaComponent(theme.reducedTransparency ? 0.08 : 0.06)
                    .cgColor,
                theme.openWithPopoverBackground
                    .mixed(towards: .black, amount: theme.sidebarGlassAppearance == .dark ? 0.03 : 0.015)
                    .withAlphaComponent(theme.reducedTransparency ? 0.05 : 0.04)
                    .cgColor,
            ]
            shadowRadius = theme.sidebarGlassAppearance == .dark ? 16 : 14
            shadowOffset = CGSize(width: 0, height: 8)
        }

        performThemeAnimation(animated: animated) {
            self.layer?.cornerRadius = cornerRadius
            self.layer?.cornerCurve = .continuous
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.layer?.borderWidth = 1
            self.layer?.shadowColor = shadowColor.cgColor
            self.gradientLayer.colors = gradientColors
            if case .sidebar = self.style {
                self.alphaValue = theme.sidebarGlassOpacity
            }
        }

        layer?.shadowOpacity = 1
        layer?.shadowRadius = shadowRadius
        layer?.shadowOffset = shadowOffset
    }
}
