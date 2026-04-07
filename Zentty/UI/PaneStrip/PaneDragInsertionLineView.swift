import AppKit
import QuartzCore

/// A pulsing blue vertical line that indicates the drop insertion position.
/// Added as a subview of viewportView so it scales automatically with zoom.
@MainActor
final class PaneDragInsertionLineView: NSView {
    enum Orientation {
        case vertical
        case horizontal
    }

    private var isPulsing = false
    private(set) var orientation: Orientation = .vertical

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOrientation(_ orientation: Orientation) {
        guard self.orientation != orientation else { return }
        self.orientation = orientation
        layer?.cornerRadius = 3
    }

    func startPulsing() {
        guard !isPulsing else { return }
        isPulsing = true

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.6
        animation.toValue = 1.0
        animation.duration = 0.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "pulse")
    }

    func stopPulsing() {
        isPulsing = false
        layer?.removeAnimation(forKey: "pulse")
    }

    /// Adjusts opacity based on how close the cursor is to the insertion line.
    /// Closer = brighter.
    func updateProximityOpacity(distance: CGFloat) {
        let maxDistance: CGFloat = 100
        let proximity = max(0, min(1, 1 - distance / maxDistance))
        let baseOpacity: Float = 0.4 + 0.6 * Float(proximity)

        // Update the pulse animation range based on proximity
        layer?.removeAnimation(forKey: "pulse")
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = baseOpacity * 0.7
        animation.toValue = baseOpacity
        animation.duration = 0.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "pulse")
    }
}
