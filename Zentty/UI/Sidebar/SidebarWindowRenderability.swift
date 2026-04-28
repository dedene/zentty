import AppKit

enum SidebarWindowRenderability {
    static func appKitRenderableWindow(_ window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }

        let occlusionState = window.occlusionState
        let isOccluded = !occlusionState.isEmpty && !occlusionState.contains(.visible)
        return window.isVisible && !window.isMiniaturized && !isOccluded
    }

    static func alwaysRenderableWindow(_ window: NSWindow?) -> Bool {
        window != nil
    }
}
