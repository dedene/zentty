import AppKit

/// Themed scrim over the worklane canvas while the command palette is open.
@MainActor
final class CommandPaletteBackdropView: NSView {
    private static let fadeInDuration: TimeInterval = 0.15
    private static let fadeOutDuration: TimeInterval = 0.10

    private var visibilityGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return self
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.commandPaletteBackdrop.cgColor
        }
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration

        if visible {
            isHidden = false
        }

        let targetAlpha: CGFloat = visible ? 1 : 0
        guard animated else {
            alphaValue = targetAlpha
            isHidden = !visible
            return
        }

        // Cancel an in-flight fade so rapid open/close cannot leave stale state.
        if visible {
            alphaValue = 0
        }

        let duration = visible ? Self.fadeInDuration : Self.fadeOutDuration
        let timingFunction: CAMediaTimingFunctionName = visible ? .easeOut : .easeIn

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timingFunction)
            self.animator().alphaValue = targetAlpha
        }, completionHandler: {
            MainActorShim.assumeIsolated {
                guard generation == self.visibilityGeneration else { return }
                if visible {
                    self.alphaValue = 1
                } else {
                    self.alphaValue = 0
                    self.isHidden = true
                }
            }
        })
    }
}
