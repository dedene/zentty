import AppKit

/// Carrier that hosts a live `PaneStripView` for one neighbor worklane during
/// peek.
///
/// **Layout strategy.** To preserve the *exact* aspect ratios and pane layout
/// the user would see if this worklane were active, the inner `PaneStripView`
/// is sized to the **full canvas dimensions** and put into the same
/// zoomed-out state as the active strip (internal scale `PaneStripView.zoomScale`
/// via `beginPeekZoomOut`). The visible footprint is then shrunk by a
/// uniform layer-level scale on the strip — the carrier itself only acts as
/// a masking window so the strip's empty area outside the band is clipped.
///
/// This avoids the bug where rendering the strip into a small frame caused
/// columns/panes (and their Ghostty terminal cells) to be re-sized to the
/// neighbor's small dimensions, giving a different cell density / visual
/// than the active strip.
@MainActor
final class WorklanePeekLaneView: NSView {

    private let strip: PaneStripView
    private(set) var worklaneID: WorklaneID?
    private var canvasSize: CGSize = .zero
    /// The internal zoom scale used by both the active strip and this
    /// neighbor preview — must match so all visible lanes share the same
    /// visual size.
    private var laneZoomScale: CGFloat = PaneStripView.zoomScale
    private var hasInitialZoomOut = false

    /// Resting opacity once the carrier has fully appeared. Neighbor lanes
    /// stay dimmer than the active so focus stays in the centered band.
    static let appearedAlpha: CGFloat = 0.7

    init(runtimeRegistry: PaneRuntimeRegistry) {
        self.strip = PaneStripView(runtimeRegistry: runtimeRegistry)
        super.init(frame: .zero)
        wantsLayer = true
        // Crop the strip's empty area outside its zoomed band so only the
        // band paints inside our bounds.
        layer?.masksToBounds = true
        layer?.cornerRadius = 6
        alphaValue = 0

        // Strip is positioned by direct frame assignment in relayoutStrip().
        // Translation stays on (default) so the explicit frame sticks.
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.wantsLayer = true
        strip.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addSubview(strip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Render the carrier's strip with `worklane`. On the first bind we
    /// also drive the strip into its zoomed-out state so the band proportions
    /// match the active strip's. `canvasSize` is the **active** canvas size
    /// — neighbor strips render at the same dimensions so Ghostty allocates
    /// the same terminal cells the active strip would. `zoomScale` matches
    /// the active strip's scale so all visible lanes share the same visual
    /// band size.
    func bind(
        worklane: WorklaneState,
        theme: ZenttyTheme,
        canvasSize: CGSize,
        zoomScale: CGFloat
    ) {
        worklaneID = worklane.id
        self.canvasSize = canvasSize
        self.laneZoomScale = zoomScale
        relayoutStrip()

        strip.apply(theme: theme, animated: false)
        strip.render(worklane.paneStripState, animated: false)

        // Force layout so the strip lays panes out at full canvas dimensions
        // before we ask it to zoom out — otherwise the zoom centering math
        // runs against zero bounds.
        strip.layoutSubtreeIfNeeded()

        if !hasInitialZoomOut {
            // Use the streaming-friendly variant so terminals keep updating
            // live while this carrier is on screen. The carrier's masked
            // layer-scale handles the visual shrink without disturbing
            // Ghostty's natural canvas-sized bounds.
            strip.enterPeekNeighborZoomOut(
                scale: zoomScale,
                centerOnPaneID: worklane.paneStripState.focusedPaneID
            )
            hasInitialZoomOut = true
        }
    }

    /// Recomputes the strip's frame + layer scale so the strip's zoomed band
    /// is what fills our bounds. Called on bind() and on layout().
    func relayoutStrip() {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        // The visible band, in strip-local coords, equals canvasSize ×
        // laneZoomScale (mirrors `applyZoomScale` math). We size ourselves
        // to *show* exactly that band.
        let bandWidth = canvasSize.width * laneZoomScale
        let bandHeight = canvasSize.height * laneZoomScale
        guard bandWidth > 0, bandHeight > 0 else { return }

        // Uniform scale chosen to fit the band into our bounds. Letterbox
        // (preserve aspect) rather than stretch when the carrier and band
        // aspect ratios disagree.
        let scaleX = bounds.width / bandWidth
        let scaleY = bounds.height / bandHeight
        let scale = min(scaleX, scaleY)

        // Place the strip so its band-center aligns with our bounds-center.
        // Since the strip's band is centered inside its own bounds, this
        // means strip.frame.center == self.bounds.center.
        strip.frame = CGRect(
            x: bounds.midX - canvasSize.width / 2,
            y: bounds.midY - canvasSize.height / 2,
            width: canvasSize.width,
            height: canvasSize.height
        )
        // Apply uniform scale via the layer transform. This shrinks the
        // strip's *rendering* without shrinking its layout — panes inside
        // keep their natural canvas-relative proportions.
        strip.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    override func layout() {
        super.layout()
        relayoutStrip()
    }

    /// Returns the highlighted pane's frame in the carrier's coordinate
    /// space, accounting for the layer scale applied to the strip.
    func paneFrameInCarrier(_ paneID: PaneID) -> CGRect? {
        guard canvasSize.width > 0 else { return nil }
        let bandWidth = canvasSize.width * laneZoomScale
        let bandHeight = canvasSize.height * laneZoomScale
        guard bandWidth > 0, bandHeight > 0 else { return nil }

        // Pane frame in strip-local coords (full-canvas-size strip).
        guard let frameInStrip = strip.convertPaneFrame(paneID, to: strip) else { return nil }

        let scale = min(bounds.width / bandWidth, bounds.height / bandHeight)
        let stripCenter = CGPoint(x: strip.bounds.midX, y: strip.bounds.midY)

        // Layer scale around the strip's center maps a strip-local point P
        // to:   carrier-center + (P − strip-center) × scale
        let dx = (frameInStrip.minX - stripCenter.x) * scale
        let dy = (frameInStrip.minY - stripCenter.y) * scale
        return CGRect(
            x: bounds.midX + dx,
            y: bounds.midY + dy,
            width: frameInStrip.width * scale,
            height: frameInStrip.height * scale
        )
    }

    /// Animate the carrier from invisible to its resting alpha.
    func appear(after delay: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            self.alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = Self.appearedAlpha
            }
        }
    }

    /// Detach the strip so the runtime registry can re-mount these panes
    /// elsewhere. Called on peek exit so a follow-up active-worklane
    /// switch (e.g., committing into the just-previewed neighbor) doesn't
    /// race with the neighbor strip still owning the host views.
    func detach() {
        strip.removeFromSuperview()
        worklaneID = nil
    }
}
