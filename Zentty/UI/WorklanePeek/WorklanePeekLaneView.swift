import AppKit

/// Carrier that hosts a live `PaneStripView` for one neighbor worklane during
/// peek.
///
/// **Layout strategy.** To preserve the *exact* aspect ratios and pane layout
/// the user would see if this worklane were active, the inner `PaneStripView`
/// is sized to the **full canvas dimensions** and put into the same
/// zoomed-out state as the active strip (internal scale `PaneStripView.zoomScale`
/// via `beginPeekZoomOut`). The carrier spans the overlay width but keeps the
/// zoomed band height, so split panes can remain visible to the left/right
/// while vertical overflow between stacked lanes is still clipped.
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
    private var visibleBandCenterX: CGFloat?
    private var singlePanePreviewPaneID: PaneID?
    /// The internal zoom scale used by both the active strip and this
    /// neighbor preview — must match so all visible lanes share the same
    /// visual size.
    private var laneZoomScale: CGFloat = PaneStripView.zoomScale
    private var hasInitialZoomOut = false

    /// Resting opacity once the carrier has fully appeared. Neighbor lanes
    /// stay dimmer than the active so focus stays in the centered band.
    static let appearedAlpha: CGFloat = 0.7

    /// Fired when the inner strip's zoom/scroll transform changes. The
    /// overlay uses this to recompute the highlight path because AppKit
    /// coordinate conversion sees the updated `viewportView.bounds`, but the
    /// existing CAShapeLayer path does not move on its own.
    var onGeometryChanged: (() -> Void)?

    init(runtimeRegistry: PaneRuntimeRegistry) {
        self.strip = PaneStripView(runtimeRegistry: runtimeRegistry)
        super.init(frame: .zero)
        wantsLayer = true
        // Crop the strip vertically to this lane's band. The carrier itself
        // spans the overlay width so horizontally adjacent split panes are
        // not clipped at the narrow band edge.
        layer?.masksToBounds = true
        layer?.cornerRadius = 6
        alphaValue = 0

        // Strip is positioned by direct frame assignment in relayoutStrip().
        // Translation stays on (default) so the explicit frame sticks.
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.wantsLayer = true
        addSubview(strip)
        strip.onZoomTransformChanged = { [weak self] in
            self?.onGeometryChanged?()
        }
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
        strip.configureViewportDiagnostics(worklaneID: worklane.id, laneRole: .peekNeighbor)
        singlePanePreviewPaneID = worklane.paneStripState.panes.count == 1
            ? worklane.paneStripState.focusedPaneID
            : nil
        self.canvasSize = canvasSize
        self.laneZoomScale = zoomScale
        relayoutStrip()
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborBind,
            context: TerminalViewportDiagnostics.Context(
                paneID: worklane.paneStripState.focusedPaneID,
                worklaneID: worklane.id,
                laneRole: .peekNeighbor,
                viewportSize: canvasSize,
                note: bindDiagnosticsNote(focusedPaneID: worklane.paneStripState.focusedPaneID, zoomScale: zoomScale)
            )
        )

        if !hasInitialZoomOut {
            strip.preparePeekNeighborZoomOut(scale: zoomScale)
        }
        strip.apply(theme: theme, animated: false)
        strip.render(worklane.paneStripState, animated: false)

        // Force layout so the strip lays panes out at full canvas dimensions
        // before we ask it to zoom out — otherwise the zoom centering math
        // runs against zero bounds.
        strip.layoutSubtreeIfNeeded()

        if !hasInitialZoomOut {
            // Complete the prepared zoom once pane frames exist, without
            // letting the preview carrier resize Ghostty's physical viewport.
            strip.enterPeekNeighborZoomOut(scale: zoomScale, centerOnPaneID: singlePanePreviewPaneID)
            if singlePanePreviewPaneID == nil {
                strip.resetPeekHorizontalCentering()
            }
            hasInitialZoomOut = true
        }
    }

    func setVisibleBandCenterX(_ centerX: CGFloat) {
        visibleBandCenterX = centerX
        relayoutStrip()
    }

    /// Re-positions the strip so its zoomed band aligns with the visible
    /// canvas center inside this carrier.
    ///
    /// The carrier is full overlay width and only band-height. Positioning
    /// the full-size strip around `visibleBandCenterX` keeps the same visual
    /// center as the active lane while leaving horizontal sibling panes
    /// visible inside the wider carrier.
    ///
    /// Crucially, no layer transform is applied to the strip. AppKit's
    /// `convert(_:from:)` does not pick up layer transforms, so keeping the
    /// strip in pure frame-based coordinates lets the highlight overlay
    /// resolve pane rects via `convert` instead of needing manual scale math.
    func relayoutStrip() {
        guard canvasSize.width > 0, canvasSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let centerX = visibleBandCenterX ?? bounds.midX
        strip.frame = CGRect(
            x: centerX - canvasSize.width / 2,
            y: bounds.midY - canvasSize.height / 2,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    override func layout() {
        super.layout()
        relayoutStrip()
    }

    /// Returns the highlighted pane's frame in the carrier's coordinate
    /// space. With no layer transforms in play, AppKit's coordinate
    /// conversion is sufficient: it takes care of the strip's `frame.origin`
    /// inside the carrier and the strip's internal viewportView-bounds
    /// zoom (which `convertPaneFrame` already factors into its result).
    func paneFrameInCarrier(_ paneID: PaneID) -> CGRect? {
        strip.convertPaneFrame(paneID, to: self)
    }

    /// Whether the bound worklane currently contains a pane with this ID.
    /// Quick check used by the overlay to decide which carrier owns the
    /// highlighted pane after a camera pan.
    func containsPane(_ paneID: PaneID) -> Bool {
        strip.convertPaneFrame(paneID, to: strip) != nil
    }

    /// Horizontally re-center the carrier's strip on `paneID`. Mirrors the
    /// active strip's `centerPeekOnPane` so a pane in a neighbor lane
    /// stays at the visible center as the user navigates within it.
    func centerOnPane(_ paneID: PaneID, animated: Bool) {
        strip.centerPeekOnPane(paneID, animated: animated)
    }

    /// Show the full lane canvas inside this carrier. Used for adjacent
    /// previews that are visible but no longer hold the active peek
    /// selection.
    func showFullCanvas() {
        if let singlePanePreviewPaneID {
            strip.centerPeekOnPane(singlePanePreviewPaneID, animated: false)
        } else {
            strip.resetPeekHorizontalCentering()
        }
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

    func showImmediately() {
        layer?.removeAnimation(forKey: "opacity")
        alphaValue = Self.appearedAlpha
    }

    /// Detach the strip so the runtime registry can re-mount these panes
    /// elsewhere. Called on peek exit so a follow-up active-worklane
    /// switch (e.g., committing into the just-previewed neighbor) doesn't
    /// race with the neighbor strip still owning the host views.
    func detach() {
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborDetach,
            context: TerminalViewportDiagnostics.Context(
                worklaneID: worklaneID,
                laneRole: .peekNeighbor
            )
        )
        strip.abandonPeekNeighborZoomOutForTeardown()
        strip.removeFromSuperview()
        worklaneID = nil
        singlePanePreviewPaneID = nil
        onGeometryChanged = nil
    }

    private func bindDiagnosticsNote(focusedPaneID: PaneID?, zoomScale: CGFloat) -> String {
        [
            "zoomScale=\(zoomScale)",
            "canvas=\(format(canvasSize))",
            "carrier=\(format(bounds))",
            "strip=\(format(strip.frame))",
            "visibleCenterX=\(visibleBandCenterX.map(String.init(describing:)) ?? "nil")",
            "focusedPaneID=\(focusedPaneID?.rawValue ?? "nil")",
            "singlePanePreviewPaneID=\(singlePanePreviewPaneID?.rawValue ?? "nil")",
        ].joined(separator: " ")
    }

    private func format(_ size: CGSize) -> String {
        "\(size.width)x\(size.height)"
    }

    private func format(_ rect: CGRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.width)x\(rect.height)"
    }
}
