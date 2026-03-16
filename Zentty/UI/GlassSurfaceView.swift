import AppKit

enum GlassSurfaceStyle {
    case sidebar
}

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
        gradientLayer.cornerRadius = ChromeGeometry.sidebarRadius
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let shadowColor: NSColor
        let cornerRadius: CGFloat
        let gradientColors: [CGColor]

        switch style {
        case .sidebar:
            material = theme.reducedTransparency ? .menu : .hudWindow
            appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
            backgroundColor = theme.sidebarBackground
            borderColor = theme.sidebarBorder
            shadowColor = theme.sidebarShadow
            cornerRadius = ChromeGeometry.sidebarRadius
            gradientColors = [
                theme.sidebarGradientStart.cgColor,
                theme.sidebarGradientEnd.cgColor,
            ]
        }

        performThemeAnimation(animated: animated) {
            self.layer?.cornerRadius = cornerRadius
            self.layer?.cornerCurve = .continuous
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.layer?.borderWidth = 1
            self.layer?.shadowColor = shadowColor.cgColor
            self.gradientLayer.colors = gradientColors
        }

        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 10)
    }
}
