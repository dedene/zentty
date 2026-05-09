import AppKit

/// Carrier that hosts a live `PaneStripView` for one neighbor worklane during
/// visual mode. Each instance renders an inactive worklane's panes at a smaller
/// frame so their column band peeks above or below the active lane.
///
/// Lifecycle: a carrier is built when visual mode opens and destroyed on exit.
/// While alive, it shares the app's `PaneRuntimeRegistry`, which means it
/// claims (mounts) the host views of an inactive worklane's panes — host views
/// that were unmounted up to that moment, so there's no conflict with the
/// active strip in `AppCanvasView`. On exit we detach so those host views can
/// be re-claimed if the user navigates into that worklane.
@MainActor
final class VisualSwitcherLaneView: NSView {

    private let strip: PaneStripView
    private(set) var worklaneID: WorklaneID?

    /// Which "ring" of neighbors this carrier sits in. ±1 lanes are at full
    /// neighbor scale; ±2 lanes peek smaller and dimmer as a spatial hint.
    enum Ring {
        case primary    // ±1
        case peeking    // ±2

        /// Resting opacity once the carrier has fully appeared. Neighbors
        /// stay dimmer than the active lane so the focus stays in the band.
        var alpha: CGFloat {
            switch self {
            case .primary: return 0.55
            case .peeking: return 0.32
            }
        }
    }

    let ring: Ring

    init(runtimeRegistry: PaneRuntimeRegistry, ring: Ring) {
        self.ring = ring
        self.strip = PaneStripView(runtimeRegistry: runtimeRegistry)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 6
        alphaValue = 0

        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Drag would have no meaning in a neighbor preview; keep the strip
        // visually live but ignore mouse input directly on it. Clicks land
        // on the overlay instead so the controller can commit-on-click.
        strip.setLeadingVisibleInset(0, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Render the carrier's strip with `worklane`. Safe to call multiple times
    /// during a single visual-mode session — `PaneStripView.render` diffs.
    func bind(worklane: WorklaneState, theme: ZenttyTheme) {
        worklaneID = worklane.id
        strip.apply(theme: theme, animated: false)
        strip.render(worklane.paneStripState, animated: false)
    }

    /// Returns the pane's frame inside this carrier (i.e., in the carrier's
    /// own coordinate space). Used by the overlay to draw the selection
    /// highlight when the highlighted pane lives in a neighbor lane.
    func paneFrameInCarrier(_ paneID: PaneID) -> CGRect? {
        strip.convertPaneFrame(paneID, to: self)
    }

    /// Animate the carrier from invisible to its ring's resting alpha. The
    /// delay staggers ±1 (immediate) before ±2 (later) so the eye registers
    /// the primary neighbors first.
    func appear(after delay: TimeInterval) {
        let target = ring.alpha
        // Drop straight to 0 and use a CABasicAnimation-equivalent via NSView
        // animator — simple, fits the existing animation idioms here.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = target
            }
        }
    }

    /// Detach the strip so the runtime registry can re-mount these panes
    /// elsewhere. Called on visual-mode exit so a follow-up active-worklane
    /// switch (e.g., committing into the just-previewed neighbor) doesn't
    /// race with the neighbor strip still owning the host views.
    func detach() {
        strip.removeFromSuperview()
        worklaneID = nil
    }
}
