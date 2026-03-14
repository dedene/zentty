import AppKit
import QuartzCore

final class PaneStripMotionController {
    func animate(in hostView: NSView, updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            updates()
            hostView.layoutSubtreeIfNeeded()
        }
    }
}
