import AppKit
import QuartzCore

/// Motion constants for floats and the one Reduce Motion switch they read.
/// Reduce Motion: no lift, no overshoot; settles, lift-in-place and the
/// strip reflow use `reducedDuration` with a plain ease.
@MainActor
enum FloatMotion {
    /// Strip reflow and lift-in-place when a tile floats or a float docks.
    static let reflowDuration: CFTimeInterval = 0.36
    static let reflowTiming = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)
    /// Every float motion under Reduce Motion.
    static let reducedDuration: CFTimeInterval = 0.15
    static let reducedTiming = CAMediaTimingFunction(name: .easeInEaseOut)
    /// Lift-on-move start: the float grows to its lifted size.
    static let liftDuration: CFTimeInterval = 0.15
    static let liftTiming = CAMediaTimingFunction(name: .easeOut)
    /// A moved float grows this many points wide while lifted.
    static let liftPoints: CGFloat = 12

    /// `frame` scaled by `1 + liftPoints / width` about its centre.
    static func liftedFrame(_ frame: CGRect) -> CGRect {
        scaled(frame, by: liftScale(forWidth: frame.width))
    }

    static func liftScale(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return 1 + liftPoints / width
    }

    /// `frame` scaled by `scale` about its centre.
    static func scaled(_ frame: CGRect, by scale: CGFloat) -> CGRect {
        let width = frame.width * scale
        let height = frame.height * scale
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// Duration and curve of a strip reflow (float in place, dock).
    static var reflowMotion: (duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        reduceMotion ? (reducedDuration, reducedTiming) : (reflowDuration, reflowTiming)
    }

    /// Tests set this to pin Reduce Motion; nil reads the system setting.
    static var reduceMotionOverride: Bool?

    static var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
