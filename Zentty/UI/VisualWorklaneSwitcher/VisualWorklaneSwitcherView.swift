import AppKit

/// Overlay rendered above `AppCanvasView` while visual mode is open. Renders
/// the dim layer over non-selected panes, the accent border around the
/// highlighted pane, and the HUD (proctitle / folder / branch) below.
///
/// In Phase 4 this only handles the active worklane (re-using the existing
/// `PaneStripView.beginVisualModeZoomOut`). Phases 5/6 will add neighbor
/// lanes as additional sub-views layered above and below.
@MainActor
final class VisualWorklaneSwitcherView: NSView {

    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let hud = VisualSwitcherHUDView()
    private weak var anchorPaneStripView: PaneStripView?

    private struct HUDPlacement {
        let targetZoomScale: CGFloat
        let visibleLeadingInset: CGFloat
    }
    private var hudPlacement: HUDPlacement?

    /// Padding around the highlighted pane's bounds for the accent border.
    private let highlightInset: CGFloat = -2

    /// Vertical gap between the column's top edge and the HUD pill above it.
    private let hudGap: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        // Click events pass through the visible "holes" so the user can click
        // a pane to commit. The view itself isn't opaque to hit-testing —
        // the dim/highlight layers are decorative.
        wantsLayer = true

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dimLayer.fillRule = .evenOdd
        layer?.addSublayer(dimLayer)

        highlightLayer.fillColor = NSColor.clear.cgColor
        highlightLayer.strokeColor = NSColor.controlAccentColor.cgColor
        highlightLayer.lineWidth = 2.5
        highlightLayer.shadowColor = NSColor.controlAccentColor.cgColor
        highlightLayer.shadowOpacity = 0.6
        highlightLayer.shadowRadius = 6
        highlightLayer.shadowOffset = .zero
        layer?.addSublayer(highlightLayer)

        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
    }

    // MARK: - Public API

    func attach(paneStripView: PaneStripView) {
        anchorPaneStripView = paneStripView
    }

    func detach() {
        anchorPaneStripView = nil
        dimLayer.path = nil
        highlightLayer.path = nil
        hud.content = .init()
        hudPlacement = nil
    }

    /// Update the highlight to point at `paneID`, refresh HUD content, and
    /// recompute the HUD frame so the box stays centered on its `x`-axis
    /// midpoint as content widths change. The HUD's *center* is the stable
    /// beacon — content can grow or shrink and the box widens/narrows
    /// symmetrically around the visible-canvas center.
    func update(highlightedPaneID: PaneID, hudContent: VisualSwitcherHUDView.Content) {
        guard let anchor = anchorPaneStripView else { return }
        guard let paneRect = anchor.convertPaneFrame(highlightedPaneID, to: self) else { return }

        let highlightRect = paneRect.insetBy(dx: highlightInset, dy: highlightInset)
        let cornerRadius: CGFloat = 8

        let outer = CGMutablePath()
        outer.addRect(bounds)
        outer.addPath(CGPath(roundedRect: highlightRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        dimLayer.path = outer

        highlightLayer.path = CGPath(
            roundedRect: highlightRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        hud.content = hudContent
        applyHUDPlacement()
    }

    /// Cache the placement parameters; the actual frame is computed lazily
    /// inside `applyHUDPlacement()` once the HUD has real content (so its
    /// fitting size is correct).
    func placeHUDStably(targetZoomScale: CGFloat, visibleLeadingInset: CGFloat = 0) {
        hudPlacement = HUDPlacement(
            targetZoomScale: targetZoomScale,
            visibleLeadingInset: visibleLeadingInset
        )
        applyHUDPlacement()
    }

    private func applyHUDPlacement() {
        guard let placement = hudPlacement else { return }
        hud.layoutSubtreeIfNeeded()
        let size = hud.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let visibleCenterX = (placement.visibleLeadingInset + bounds.width) / 2
        let originX = visibleCenterX - size.width / 2

        // After the zoom + centering animation settles, columns occupy a
        // vertical band centered on the canvas, with height ≈ bounds.height
        // × targetZoomScale (assuming full-height columns — the typical
        // Zentty layout). The column's top edge in non-flipped coords sits
        // at ~ midY + (band height / 2). Anchor HUD just above that edge.
        let bandHeight = bounds.height * placement.targetZoomScale
        let columnTopY = bounds.midY + bandHeight / 2
        let originY = min(columnTopY + hudGap, bounds.height - size.height - 8)
        let clampedX = max(8, min(originX, bounds.width - size.width - 8))
        hud.frame = CGRect(x: clampedX, y: originY, width: size.width, height: size.height)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // The dim path is bounds-sized; refresh it on resize.
        if let anchor = anchorPaneStripView,
           let path = highlightLayer.path,
           !path.isEmpty {
            // Re-compose dim path with current bounds.
            let outer = CGMutablePath()
            outer.addRect(bounds)
            outer.addPath(path)
            dimLayer.path = outer
            _ = anchor // silence weak-ref warning
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Defense-in-depth: if no anchor PaneStripView is attached, visual
        // mode is not active — let clicks fall through so drag-zones,
        // dividers, and pane focus continue working normally even if
        // `isHidden` somehow drifts out of sync.
        guard anchorPaneStripView != nil else { return nil }

        // Block clicks from reaching the underlying PaneStripView while
        // visual mode is open — Phase 4 doesn't yet implement click-to-commit
        // (added in Phase 5). The HUD remains interactive for hover affordances.
        if hud.frame.contains(point), !hud.isHidden {
            return hud.hitTest(point)
        }
        return self
    }
}
