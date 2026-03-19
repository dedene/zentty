import AppKit
import CoreGraphics
import QuartzCore

enum SidebarVisibilityMode: String, Equatable, Sendable {
    case pinnedOpen
    case hidden
    case hoverPeek
}

enum SidebarVisibilityEvent: Sendable {
    case togglePressed
    case hoverRailEntered
    case hoverRailExited
    case sidebarEntered
    case sidebarExited
    case dismissTimerElapsed
}

struct SidebarVisibilityController: Equatable, Sendable {
    private(set) var mode: SidebarVisibilityMode
    private var isPointerInHoverRail = false
    private var isPointerInSidebar = false

    init(mode: SidebarVisibilityMode = .pinnedOpen) {
        self.mode = mode
    }

    var persistedMode: SidebarVisibilityMode {
        mode == .pinnedOpen ? .pinnedOpen : .hidden
    }

    var isVisible: Bool {
        mode != .hidden
    }

    var isFloating: Bool {
        mode == .hoverPeek
    }

    var showsResizeHandle: Bool {
        mode == .pinnedOpen
    }

    var shouldScheduleDismissal: Bool {
        mode == .hoverPeek && !isPointerInHoverRail && !isPointerInSidebar
    }

    mutating func handle(_ event: SidebarVisibilityEvent) {
        switch event {
        case .togglePressed:
            mode = mode == .pinnedOpen ? .hidden : .pinnedOpen
            resetPointerTracking()
        case .hoverRailEntered:
            isPointerInHoverRail = true
            if mode == .hidden {
                mode = .hoverPeek
            }
        case .hoverRailExited:
            isPointerInHoverRail = false
        case .sidebarEntered:
            isPointerInSidebar = true
        case .sidebarExited:
            isPointerInSidebar = false
        case .dismissTimerElapsed:
            guard mode == .hoverPeek, !isPointerInHoverRail, !isPointerInSidebar else {
                return
            }
            mode = .hidden
            resetPointerTracking()
        }
    }

    func effectiveLeadingInset(sidebarWidth: CGFloat) -> CGFloat {
        guard mode == .pinnedOpen else {
            return 0
        }
        return SidebarWidthPreference.clamped(sidebarWidth) + ShellMetrics.shellGap
    }

    private mutating func resetPointerTracking() {
        isPointerInHoverRail = false
        isPointerInSidebar = false
    }
}

enum SidebarVisibilityPreference {
    static let persistenceKey = "RootViewController.sidebarVisibility"
    private static let testDefaultsSuiteName = "ZenttyTests.SidebarVisibilityPreference"

    static func restoredVisibility(from defaults: UserDefaults) -> SidebarVisibilityMode {
        guard let rawValue = defaults.string(forKey: persistenceKey),
              let visibility = SidebarVisibilityMode(rawValue: rawValue),
              visibility != .hoverPeek else {
            return .pinnedOpen
        }
        return visibility
    }

    static func persist(_ visibility: SidebarVisibilityMode, in defaults: UserDefaults) {
        defaults.set(normalized(visibility).rawValue, forKey: persistenceKey)
    }

    static func userDefaultsForTesting() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }
        return defaults
    }

    static func resetForTesting() {
        UserDefaults(suiteName: testDefaultsSuiteName)?
            .removePersistentDomain(forName: testDefaultsSuiteName)
    }

    private static func normalized(_ visibility: SidebarVisibilityMode) -> SidebarVisibilityMode {
        visibility == .pinnedOpen ? .pinnedOpen : .hidden
    }
}

struct SidebarMotionState: Equatable {
    let revealFraction: CGFloat
    let reservedFraction: CGFloat

    static let hidden = SidebarMotionState(revealFraction: 0, reservedFraction: 0)
    static let hoverPeek = SidebarMotionState(revealFraction: 1, reservedFraction: 0)
    static let pinnedOpen = SidebarMotionState(revealFraction: 1, reservedFraction: 1)

    init(revealFraction: CGFloat, reservedFraction: CGFloat) {
        self.revealFraction = min(max(revealFraction, 0), 1)
        self.reservedFraction = min(max(reservedFraction, 0), 1)
    }

    init(mode: SidebarVisibilityMode) {
        switch mode {
        case .hidden:
            self = .hidden
        case .hoverPeek:
            self = .hoverPeek
        case .pinnedOpen:
            self = .pinnedOpen
        }
    }
}

enum SidebarTransitionProfile {
    static let standardDuration: TimeInterval = 0.24
    static let reducedMotionDuration: TimeInterval = 0.14
    static let controlPoint1 = CGPoint(x: 0.22, y: 1)
    static let controlPoint2 = CGPoint(x: 0.36, y: 1)

    static func resolvedDuration(reducedMotion: Bool) -> TimeInterval {
        reducedMotion ? reducedMotionDuration : standardDuration
    }

    static func resolvedTimingFunction(reducedMotion: Bool) -> CAMediaTimingFunction {
        if reducedMotion {
            return CAMediaTimingFunction(name: .easeOut)
        }

        return CAMediaTimingFunction(
            controlPoints: Float(controlPoint1.x),
            Float(controlPoint1.y),
            Float(controlPoint2.x),
            Float(controlPoint2.y)
        )
    }
}

enum SidebarToggleVisuals {
    static func contentTintColor(theme: ZenttyTheme, isActive: Bool) -> NSColor {
        theme.primaryText.withAlphaComponent(isActive ? 0.96 : 0.82)
    }

    static func backgroundColor(theme: ZenttyTheme, isActive: Bool) -> NSColor {
        .clear
    }

    static func borderColor(theme: ZenttyTheme, isActive: Bool) -> NSColor {
        .clear
    }
}

enum SidebarToggleIconFactory {
    static let imageSize = NSSize(width: 15, height: 15)
    private static let symbolName = "sidebar.left"

    static func makeImage(
        symbolProvider: (String, String?) -> NSImage? = { name, description in
            NSImage(systemSymbolName: name, accessibilityDescription: description)
        }
    ) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: imageSize.width, weight: .semibold)
        if let symbolImage = symbolProvider(symbolName, "Toggle sidebar")?.withSymbolConfiguration(configuration) {
            symbolImage.isTemplate = true
            return symbolImage
        }

        let fallbackImage = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.withAlphaComponent(0.16).setFill()

            let outlineRect = rect.insetBy(dx: 1.25, dy: 1.5)
            let outlinePath = NSBezierPath(roundedRect: outlineRect, xRadius: 2.5, yRadius: 2.5)
            outlinePath.lineWidth = 1.35
            outlinePath.stroke()

            let sidebarRect = NSRect(
                x: outlineRect.minX + 0.75,
                y: outlineRect.minY + 0.75,
                width: 3.0,
                height: outlineRect.height - 1.5
            )
            NSBezierPath(roundedRect: sidebarRect, xRadius: 1.2, yRadius: 1.2).fill()

            let dividerPath = NSBezierPath()
            dividerPath.lineWidth = 1.25
            dividerPath.move(to: NSPoint(x: sidebarRect.maxX + 1.6, y: outlineRect.minY + 0.75))
            dividerPath.line(to: NSPoint(x: sidebarRect.maxX + 1.6, y: outlineRect.maxY - 0.75))
            dividerPath.stroke()
            return true
        }
        fallbackImage.isTemplate = true
        return fallbackImage
    }
}

@MainActor
final class SidebarToggleOverlayView: NSView {
    private enum Layout {
        static let buttonSize: CGFloat = 28
        static let toggleSpacingFromTrafficLights: CGFloat = 12
    }

    var onToggleSidebar: (() -> Void)?

    private let toggleButton = SidebarToggleButton()
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var sidebarVisibility: SidebarVisibilityMode = .pinnedOpen
    private var toggleLeadingConstraint: NSLayoutConstraint?
    private var toggleCenteredConstraint: NSLayoutConstraint?
    private var toggleBottomAlignedConstraint: NSLayoutConstraint?
    private var trafficLightClusterTrailingX: CGFloat = 0
    private var trafficLightClusterMidYInSuperview: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.target = self
        toggleButton.action = #selector(handleToggleSidebar)

        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            {
                let constraint = toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor)
                toggleLeadingConstraint = constraint
                return constraint
            }(),
            toggleButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize),
            toggleButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize),
        ])

        let toggleCenteredConstraint = toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        let toggleBottomAlignedConstraint = toggleButton.centerYAnchor.constraint(equalTo: bottomAnchor)
        toggleBottomAlignedConstraint.isActive = false
        toggleCenteredConstraint.isActive = true
        self.toggleCenteredConstraint = toggleCenteredConstraint
        self.toggleBottomAlignedConstraint = toggleBottomAlignedConstraint

        toggleButton.configure(theme: currentTheme, isActive: true, animated: false)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateToggleAnchorConstraints()
    }

    override func layout() {
        super.layout()
        updateToggleAnchorConstraints()
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        toggleButton.configure(
            theme: theme,
            isActive: sidebarVisibility == .pinnedOpen,
            animated: animated
        )
    }

    func setSidebarVisibility(_ sidebarVisibility: SidebarVisibilityMode, animated: Bool) {
        self.sidebarVisibility = sidebarVisibility
        toggleButton.configure(
            theme: currentTheme,
            isActive: sidebarVisibility == .pinnedOpen,
            animated: animated
        )
    }

    func setTrafficLightAnchor(trailingX: CGFloat, midYInSuperview: CGFloat? = nil) {
        trafficLightClusterTrailingX = trailingX
        trafficLightClusterMidYInSuperview = midYInSuperview
        updateToggleAnchorConstraints()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc
    private func handleToggleSidebar() {
        onToggleSidebar?()
    }

    var toggleMinXForTesting: CGFloat {
        toggleButton.frame.minX
    }

    var toggleFrameInSuperviewForTesting: NSRect {
        guard let superview else {
            return toggleButton.frame
        }

        return convert(toggleButton.frame, to: superview)
    }

    var isToggleActiveForTesting: Bool {
        toggleButton.isActive
    }

    private func updateToggleAnchorConstraints() {
        toggleLeadingConstraint?.constant = trafficLightClusterTrailingX + Layout.toggleSpacingFromTrafficLights

        if let trafficLightClusterMidYInSuperview, let superview {
            let localMidY = convert(NSPoint(x: 0, y: trafficLightClusterMidYInSuperview), from: superview).y
            toggleCenteredConstraint?.isActive = false
            toggleBottomAlignedConstraint?.constant = -localMidY
            toggleBottomAlignedConstraint?.isActive = true
            return
        }

        toggleBottomAlignedConstraint?.isActive = false
        toggleCenteredConstraint?.isActive = true
    }
}

private final class SidebarToggleButton: NSButton {
    private(set) var isActive = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        image = SidebarToggleIconFactory.makeImage()
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel("Toggle sidebar")
    }

    func configure(theme: ZenttyTheme, isActive: Bool, animated: Bool) {
        self.isActive = isActive
        contentTintColor = SidebarToggleVisuals.contentTintColor(theme: theme, isActive: isActive)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = (
                SidebarToggleVisuals.backgroundColor(theme: theme, isActive: isActive)
            ).cgColor
            self.layer?.borderColor = (
                SidebarToggleVisuals.borderColor(theme: theme, isActive: isActive)
            ).cgColor
            self.layer?.borderWidth = isActive ? 1.0 : 1.0
            self.layer?.shadowColor = theme.underlapShadow.cgColor
            self.layer?.shadowOpacity = isActive ? 0.18 : 0.10
            self.layer?.shadowRadius = isActive ? 9 : 5
            self.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
    }
}

@MainActor
final class SidebarHoverRailView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }
}
