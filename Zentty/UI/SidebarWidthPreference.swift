import AppKit

enum SidebarWidthPreference {
    static let defaultWidth: CGFloat = 280
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 360
    static let persistenceKey = "RootViewController.sidebarWidth"

    private static let testDefaultsSuiteName = "ZenttyTests.SidebarWidthPreference"

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func restoredWidth(from defaults: UserDefaults) -> CGFloat {
        guard defaults.object(forKey: persistenceKey) != nil else {
            return defaultWidth
        }

        return clamped(CGFloat(defaults.double(forKey: persistenceKey)))
    }

    static func persist(_ width: CGFloat, in defaults: UserDefaults) {
        defaults.set(Double(clamped(width)), forKey: persistenceKey)
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
