import CoreGraphics
import Foundation
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
    case globalSearchFocusEntered
    case globalSearchFocusExited
    case dismissTimerElapsed
}

struct SidebarVisibilityController: Equatable, Sendable {
    private(set) var mode: SidebarVisibilityMode
    private var isPointerInHoverRail = false
    private var isPointerInSidebar = false
    private var isGlobalSearchFocused = false

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
        mode == .hoverPeek && !isPointerInHoverRail && !isPointerInSidebar && !isGlobalSearchFocused
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
        case .globalSearchFocusEntered:
            isGlobalSearchFocused = true
            if mode == .hidden {
                mode = .hoverPeek
            }
        case .globalSearchFocusExited:
            isGlobalSearchFocused = false
        case .dismissTimerElapsed:
            guard mode == .hoverPeek, !isPointerInHoverRail, !isPointerInSidebar, !isGlobalSearchFocused else {
                return
            }
            mode = .hidden
            resetPointerTracking()
        }
    }

    func effectiveLeadingInset(sidebarWidth: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        guard mode == .pinnedOpen else {
            return 0
        }
        return SidebarWidthPreference.clamped(
            sidebarWidth,
            availableWidth: availableWidth
        ) + ShellMetrics.shellGap
    }

    private mutating func resetPointerTracking() {
        isPointerInHoverRail = false
        isPointerInSidebar = false
        isGlobalSearchFocused = false
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

    static func userDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }
        return defaults
    }

    static func reset() {
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
