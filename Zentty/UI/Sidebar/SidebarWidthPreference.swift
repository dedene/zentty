import AppKit

enum SidebarWidthPreference {
    static let defaultWidth: CGFloat = 280
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 420
    static let maximumWidthScreenFraction: CGFloat = 0.33
    static let minimumContentAreaWidth: CGFloat = 200
    static let persistenceKey = "RootViewController.sidebarWidth"

    private static let testDefaultsSuiteName = "ZenttyTests.SidebarWidthPreference"

    static func maximumWidth(for availableWidth: CGFloat?) -> CGFloat {
        guard let availableWidth, availableWidth > 0 else {
            return maximumWidth
        }

        let fractionBased = floor(availableWidth * maximumWidthScreenFraction)
        let contentGuard = availableWidth - minimumContentAreaWidth
        return max(minimumWidth, min(fractionBased, contentGuard))
    }

    static func clamped(_ width: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth(for: availableWidth))
    }

    static func restoredWidth(from defaults: UserDefaults, availableWidth: CGFloat? = nil) -> CGFloat {
        guard defaults.object(forKey: persistenceKey) != nil else {
            return defaultWidth
        }

        return clamped(CGFloat(defaults.double(forKey: persistenceKey)), availableWidth: availableWidth)
    }

    static func persist(_ width: CGFloat, in defaults: UserDefaults, availableWidth: CGFloat? = nil) {
        defaults.set(Double(clamped(width, availableWidth: availableWidth)), forKey: persistenceKey)
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
}
