import AppKit

/// When the strip under the float layer is dimmed.
enum FloatScrimPolicy {
    /// Dim while a visible `.floating` float owns focus. A tile with focus,
    /// hidden floats, PiPs and minimized floats never dim the strip.
    static func isVisible(_ content: FloatLayerContent) -> Bool {
        guard !content.floatsHidden, let focusedID = content.focusedFloatID else {
            return false
        }
        return content.floats.contains { $0.pane.id == focusedID && $0.mode.isFloating }
    }
}

/// Black scrim behind the floats that dims the strip while a float has
/// focus. Hit-transparent: a click on a dimmed tile reaches the tile, which
/// then takes focus and lifts the dim.
@MainActor
final class FloatScrimView: NSView {
    static let opacity: CGFloat = 0.45
    static let fadeDuration: CFTimeInterval = 0.25

    /// The last requested state (the fade may still be running).
    private(set) var isScrimVisible = false
    private var visibilityGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.opacity).cgColor
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isScrimVisible else { return }
        isScrimVisible = visible
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let targetAlpha: CGFloat = visible ? 1 : 0

        if visible {
            isHidden = false
        }
        guard animated else {
            alphaValue = targetAlpha
            isHidden = !visible
            return
        }

        let reduceMotion = FloatMotion.reduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? FloatMotion.reducedDuration : Self.fadeDuration
            context.timingFunction = reduceMotion
                ? FloatMotion.reducedTiming
                : CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            self.animator().alphaValue = targetAlpha
        }, completionHandler: {
            MainActorShim.assumeIsolated {
                // A later toggle owns the end state.
                guard generation == self.visibilityGeneration else { return }
                self.alphaValue = targetAlpha
                self.isHidden = !visible
            }
        })
    }
}
