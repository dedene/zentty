import AppKit

/// Overlay rendered above `AppCanvasView` while peek is open. Renders
/// the dim layer over non-selected panes, the accent border around the
/// highlighted pane, the HUD (proctitle / folder / branch), and — for multi-
/// worklane windows — peeking neighbor lanes above and below the active band.
@MainActor
final class WorklanePeekView: NSView {

    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let hud = WorklanePeekHUDView()
    private let cameraSpring = SpringAnimator()
    private weak var anchorPaneStripView: PaneStripView?

    /// Lane carriers, keyed by **absolute** worklane index (matching
    /// `WorklaneStore.worklanes`). The original active worklane is *not*
    /// in this dict — its rendering belongs to `anchorPaneStripView`.
    private var laneCarriers: [Int: WorklanePeekLaneView] = [:]

    /// Per-session state captured at peek-open. Used by lazy carrier creation
    /// during camera pan so we don't have to thread these through every call.
    private struct SessionContext {
        let worklanes: [WorklaneState]
        let originalActiveIndex: Int
        let canvasSize: CGSize
        let zoomScale: CGFloat
        let theme: ZenttyTheme
        let runtimeRegistry: PaneRuntimeRegistry
    }
    private var session: SessionContext?

    /// Index of the worklane currently anchored at the *visible* center —
    /// the one the user is peeking at. Equal to `session.originalActiveIndex`
    /// at the start; changes as the user crosses worklane boundaries with
    /// Tab and the camera pans.
    private(set) var centeredIndex: Int = 0

    /// Vertical offset (in points) applied to every visible lane so the
    /// `centeredIndex` lane sits at the canvas center. Positive Y shifts
    /// content up (toward higher worklane indices in the stack).
    private var cameraOffset: CGFloat = 0

    private struct HUDPlacement {
        let targetZoomScale: CGFloat
        let visibleLeadingInset: CGFloat
    }
    private var hudPlacement: HUDPlacement?

    /// Padding around the highlighted pane's bounds for the accent border.
    private let highlightInset: CGFloat = -2

    /// Vertical gap between the column's top edge and the HUD pill above it.
    private let hudGap: CGFloat = 12

    /// Vertical gap between adjacent lane bands. Generous spacing on
    /// purpose — partial clipping of the ±1 lanes off the top/bottom of
    /// the canvas is fine because the camera pans the chosen lane fully
    /// into view as the user Ctrl-Tabs further.
    private static let bandGap: CGFloat = 48

    /// Prebuild one extra off-screen lane beyond the visible neighbor on
    /// each side. That keeps single-pane worklanes feeling like a continuous
    /// stack instead of letting the next carrier fade in during a tab pan.
    private static let carrierPreloadRadius = 2

    /// Camera pan animation duration. Matches `SpringAnimator`'s zoom timing
    /// so vertical worklane pans and pane-strip zooms feel related.
    private static let panAnimationDuration: TimeInterval = SpringAnimator.defaultDuration

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
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

    /// Worklane IDs currently rendered as live previews in this peek session
    /// — every neighbor lane that has a carrier mounted. The
    /// `WorklaneRenderCoordinator` queries this set so Ghostty's occlusion
    /// flag stays *off* for those worklanes (otherwise their surfaces would
    /// pause and the user would see a frozen still instead of live output).
    /// Includes any lane built so far during the session, even ones currently
    /// off-screen due to the camera position — keeping them un-occluded means
    /// they're already streaming when the user pans onto them.
    var peekVisibleWorklaneIDs: Set<WorklaneID> {
        guard let session else { return [] }
        var ids = Set(laneCarriers.compactMap { _, carrier in carrier.worklaneID })
        // The original active worklane is rendered by the anchor strip and
        // is already un-occluded by the active-worklane rule; include it
        // here too so the set fully describes what's "peek-visible" for any
        // diagnostics or future consumers.
        if session.worklanes.indices.contains(session.originalActiveIndex) {
            ids.insert(session.worklanes[session.originalActiveIndex].id)
        }
        return ids
    }

    /// Called whenever the set of peek-visible worklanes changes (open,
    /// lazy carrier creation during pan, close) so the render coordinator
    /// can re-push surface-activity flags. Set by the owner.
    var onPeekVisibleWorklanesChanged: (() -> Void)?

    /// Called when a mounted neighbor carrier changes its internal
    /// horizontal zoom/scroll transform. The overlay owns the highlight
    /// CAShapeLayer, so the owner needs to ask for a fresh highlight rect.
    var onGeometryChanged: (() -> Void)?

    func detach() {
        TerminalViewportDiagnostics.shared.record(.peekViewDetach)
        cameraSpring.stop()
        // Reset the anchor strip's camera transform before letting go so the
        // strip lands without a residual translate during the zoom-in.
        anchorPaneStripView?.layer?.transform = CATransform3DIdentity
        anchorPaneStripView = nil
        dimLayer.path = nil
        highlightLayer.path = nil
        hud.content = .init()
        hudPlacement = nil
        teardownNeighborLanes()
        session = nil
        cameraOffset = 0
        centeredIndex = 0
        // Tell observers (the render coordinator) the peek-visible set is
        // empty now so neighbor surfaces can be re-occluded.
        onPeekVisibleWorklanesChanged?()
    }

    /// Set up the neighbor carriers for one peek session.
    /// `worklanes` is in the same order as `WorklaneStore.worklanes`. The
    /// active worklane is identified by `activeIndex` and is *not* rendered
    /// here (the existing pane strip handles it). Carriers for worklanes
    /// further from the active are built lazily on camera pan.
    func configureNeighborLanes(
        worklanes: [WorklaneState],
        activeIndex: Int,
        canvasSize: CGSize,
        zoomScale: CGFloat,
        runtimeRegistry: PaneRuntimeRegistry,
        theme: ZenttyTheme
    ) {
        teardownNeighborLanes()
        session = SessionContext(
            worklanes: worklanes,
            originalActiveIndex: activeIndex,
            canvasSize: canvasSize,
            zoomScale: zoomScale,
            theme: theme,
            runtimeRegistry: runtimeRegistry
        )
        centeredIndex = activeIndex
        cameraOffset = 0

        // Build visible neighbors plus one off-screen lookahead on both
        // sides so the lane stack is already populated when the camera pans.
        for index in (activeIndex - Self.carrierPreloadRadius)...(activeIndex + Self.carrierPreloadRadius) {
            ensureCarrier(at: index, fadeInDelay: 0.10)
        }

        // Position everything (no carriers if single-worklane session).
        layoutNeighborCarriers()
        applyCameraOffset(animated: false)
        onPeekVisibleWorklanesChanged?()
    }

    /// Pan the camera so the worklane containing `worklaneID` is centered.
    /// Lazily builds a carrier for that worklane (and its ±1 neighbors) if
    /// it doesn't exist yet, so a long Tab traversal across many worklanes
    /// keeps a populated centered band.
    func centerOn(worklaneID: WorklaneID, animated: Bool) {
        guard let session,
              let targetIndex = session.worklanes.firstIndex(where: { $0.id == worklaneID }),
              targetIndex != centeredIndex
        else { return }

        centeredIndex = targetIndex
        // Make sure the centered lane *and* its immediate neighbors have
        // carriers — otherwise the user pans into an empty void after the
        // first cross.
        let countBefore = laneCarriers.count
        for index in (targetIndex - Self.carrierPreloadRadius)...(targetIndex + Self.carrierPreloadRadius) {
            ensureCarrier(at: index, fadeInDelay: nil)
        }
        if laneCarriers.count != countBefore {
            onPeekVisibleWorklanesChanged?()
        }
        resetNonSelectedHorizontalCentering()
        applyCameraOffset(animated: animated)
    }

    /// Center the carrier (or anchor strip) holding `paneID` on its own
    /// horizontal axis. Mirrors the active strip's `centerPeekOnPane` for
    /// neighbor lanes so the highlighted pane stays visually centered as
    /// the user navigates within a worklane that isn't the original active.
    func centerHorizontally(paneID: PaneID, animated: Bool) {
        guard let session else { return }
        for carrier in laneCarriers.values where carrier.containsPane(paneID) {
            carrier.centerOnPane(paneID, animated: animated)
        }
        // The anchor strip is centered by the controller via
        // `PaneStripView.centerPeekOnPane` already, so skip it here.
        _ = session
    }

    private func resetNonSelectedHorizontalCentering() {
        guard let session else { return }
        if centeredIndex != session.originalActiveIndex {
            anchorPaneStripView?.resetPeekHorizontalCentering()
        }
        for (index, carrier) in laneCarriers where index != centeredIndex {
            carrier.showFullCanvas()
        }
    }

    private func ensureCarrier(at index: Int, fadeInDelay: TimeInterval?) {
        guard let session,
              session.worklanes.indices.contains(index),
              index != session.originalActiveIndex,
              laneCarriers[index] == nil
        else { return }

        let carrier = WorklanePeekLaneView(runtimeRegistry: session.runtimeRegistry)
        // Carrier is positioned via direct frame assignment — translation
        // stays on so the explicit frame sticks instead of being clobbered.
        carrier.translatesAutoresizingMaskIntoConstraints = true
        carrier.onGeometryChanged = { [weak self] in
            self?.onGeometryChanged?()
        }
        insertNeighborSubview(carrier)
        laneCarriers[index] = carrier

        // Layout *before* binding so the carrier's bounds are known when
        // the strip's layer-scale math runs inside `bind`.
        positionCarrier(carrier, atAbsoluteIndex: index)
        carrier.bind(
            worklane: session.worklanes[index],
            theme: session.theme,
            canvasSize: session.canvasSize,
            zoomScale: session.zoomScale
        )
        if let fadeInDelay {
            carrier.appear(after: fadeInDelay)
        } else {
            carrier.showImmediately()
        }
        // The new carrier inherits the current camera offset.
        applyCameraOffset(toCarrier: carrier, animated: false)
    }

    private func insertNeighborSubview(_ carrier: WorklanePeekLaneView) {
        if hud.superview === self {
            addSubview(carrier, positioned: .below, relativeTo: hud)
        } else {
            addSubview(carrier)
        }
    }

    private func teardownNeighborLanes() {
        for (_, carrier) in laneCarriers {
            carrier.detach()
            carrier.removeFromSuperview()
        }
        laneCarriers.removeAll()
    }

    /// Update the highlight to point at `paneID` (in any visible lane),
    /// refresh HUD content, and recompute the HUD frame so the box stays
    /// centered on its x-axis midpoint as content widths change. The HUD's
    /// *center* is the stable beacon — content can grow or shrink and the
    /// box widens/narrows symmetrically around the visible-canvas center.
    func update(highlightedPaneID: PaneID, hudContent: WorklanePeekHUDView.Content) {
        guard let highlightRect = highlightRectFor(paneID: highlightedPaneID) else { return }
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

    /// Resolve the on-screen rect for a pane that may live in the active
    /// strip or in any of the visible neighbor carriers. Returns the rect
    /// in this overlay's coordinate space, padded by `highlightInset`.
    /// Accounts for the current camera offset so the highlight tracks the
    /// pane's *visible* position after a pan.
    private func highlightRectFor(paneID: PaneID) -> CGRect? {
        if let anchor = anchorPaneStripView,
           let rect = anchor.convertPaneFrame(paneID, to: self) {
            // The anchor strip carries a layer translate matching cameraOffset
            // but the AppKit coordinate conversion above doesn't pick up
            // layer transforms. Add it manually.
            return rect.offsetBy(dx: 0, dy: cameraOffset).insetBy(dx: highlightInset, dy: highlightInset)
        }
        for carrier in laneCarriers.values {
            if let rectInCarrier = carrier.paneFrameInCarrier(paneID) {
                let rect = convert(rectInCarrier, from: carrier)
                // Same layer-transform compensation as the anchor strip.
                return rect.offsetBy(dx: 0, dy: cameraOffset).insetBy(dx: highlightInset, dy: highlightInset)
            }
        }
        return nil
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

    /// Place each carrier at its **absolute** position in the lane stack,
    /// based on its index relative to the original active. The visible
    /// position after camera pan is then computed by `applyCameraOffset`
    /// applying a layer translate on top.
    private func layoutNeighborCarriers() {
        guard hudPlacement != nil else { return }
        for (index, carrier) in laneCarriers {
            positionCarrier(carrier, atAbsoluteIndex: index)
        }
    }

    private func positionCarrier(_ carrier: WorklanePeekLaneView, atAbsoluteIndex index: Int) {
        guard let placement = hudPlacement, let session else { return }
        let bandHeight = bounds.height * placement.targetZoomScale
        let visibleCenterX = (placement.visibleLeadingInset + bounds.width) / 2

        // Stack offset, in lane-units, from the original active worklane.
        // Higher index sits visually below (lower Y in non-flipped coords).
        let stackOffset = index - session.originalActiveIndex
        let bandCenterY = bounds.midY - CGFloat(stackOffset) * (bandHeight + Self.bandGap)
        carrier.frame = CGRect(
            x: 0,
            y: bandCenterY - bandHeight / 2,
            width: bounds.width,
            height: bandHeight
        )
        carrier.setVisibleBandCenterX(visibleCenterX)
    }

    /// Compute the desired Y translate from the current centered index, then
    /// apply it (animated or instant) to the anchor strip and every carrier
    /// so the centered lane sits at the canvas's vertical mid-line.
    private func applyCameraOffset(animated: Bool) {
        guard let session, let placement = hudPlacement else { return }
        let bandHeight = bounds.height * placement.targetZoomScale
        let stackOffset = centeredIndex - session.originalActiveIndex
        // Visual "up" is +Y; moving the camera toward a higher-index lane
        // means shifting all content *up* by that many lanes.
        let targetOffset = CGFloat(stackOffset) * (bandHeight + Self.bandGap)

        if animated {
            let fromOffset = cameraOffset
            cameraSpring.start(duration: Self.panAnimationDuration) { [weak self] eased in
                guard let self else { return }
                let offset = fromOffset + (targetOffset - fromOffset) * eased
                self.setCameraOffset(offset)
                self.onGeometryChanged?()
            } complete: { [weak self] in
                guard let self else { return }
                self.setCameraOffset(targetOffset)
                self.onGeometryChanged?()
            }
        } else {
            cameraSpring.stop()
            setCameraOffset(targetOffset)
            onGeometryChanged?()
        }
    }

    private func setCameraOffset(_ offset: CGFloat) {
        cameraOffset = offset
        let transform = CATransform3DMakeTranslation(0, offset, 0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        anchorPaneStripView?.layer?.transform = transform
        for carrier in laneCarriers.values {
            carrier.layer?.transform = transform
        }
        CATransaction.commit()
        layoutDimAndHighlight()
    }

    /// Apply the *current* cameraOffset to one carrier (used right after
    /// lazily building it). No animation — the carrier joins the ongoing
    /// spring on the next camera tick.
    private func applyCameraOffset(toCarrier carrier: WorklanePeekLaneView, animated: Bool) {
        let transform = CATransform3DMakeTranslation(0, cameraOffset, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        carrier.layer?.transform = transform
        CATransaction.commit()
    }

    private func layoutDimAndHighlight() {
        // The dim/highlight CAShapeLayers paint relative to the overlay's
        // own bounds — they don't pick up the per-lane layer transform.
        // The highlight is recomputed by `update(highlightedPaneID:)` on
        // every selection change, which already factors in cameraOffset.
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutNeighborCarriers()
        if let anchor = anchorPaneStripView,
           let path = highlightLayer.path,
           !path.isEmpty {
            let outer = CGMutablePath()
            outer.addRect(bounds)
            outer.addPath(path)
            dimLayer.path = outer
            _ = anchor // silence weak-ref warning
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Defense-in-depth: if no anchor PaneStripView is attached, peek
        // mode is not active — let clicks fall through so drag-zones,
        // dividers, and pane focus continue working normally even if
        // `isHidden` somehow drifts out of sync.
        guard anchorPaneStripView != nil else { return nil }

        if hud.frame.contains(point), !hud.isHidden {
            return hud.hitTest(point)
        }
        return self
    }
}
