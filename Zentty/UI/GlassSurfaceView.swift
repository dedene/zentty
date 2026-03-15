import AppKit

enum GlassSurfaceStyle {
    case sidebar
}

final class GlassSurfaceView: NSVisualEffectView {
    private let style: GlassSurfaceStyle

    init(style: GlassSurfaceStyle) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let shadowColor: NSColor
        let cornerRadius: CGFloat

        switch style {
        case .sidebar:
            material = theme.reducedTransparency ? .menu : .hudWindow
            backgroundColor = theme.sidebarBackground
            borderColor = theme.sidebarBorder
            shadowColor = theme.sidebarShadow
            cornerRadius = ShellMetrics.sidebarRadius
        }

        performThemeAnimation(animated: animated) {
            self.layer?.cornerRadius = cornerRadius
            self.layer?.cornerCurve = .continuous
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.layer?.borderWidth = 1
            self.layer?.shadowColor = shadowColor.cgColor
        }

        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 10)
    }
}
