import AppKit
import QuartzCore

@MainActor
final class PaneDragCoordinator {

    // MARK: - Callbacks

    var onReorder: ((PaneID, Int) -> Void)?
    var onSplitDrop: ((PaneID, PaneID, PaneSplitPreview.Axis, Bool) -> Void)?
    var onDragActiveChanged: ((Bool) -> Void)?
    var onSidebarDrop: ((PaneID, WorklaneID, Bool) -> Void)?
    var onSidebarNewWorklaneDrop: ((PaneID, Bool) -> Void)?
    var onHoveredSidebarWorklaneChanged: ((WorklaneID?) -> Void)?
    var onDragApproachingSidebarEdge: ((Bool) -> Void)?
    var onNewWorklanePlaceholderVisibilityChanged: ((Bool) -> Void)?
    var onSidebarScrollRequested: ((CGFloat) -> Void)?

    // MARK: - Sidebar Providers

    var sidebarWorklaneFrameProvider: (() -> [(WorklaneID, CGRect)])?
    var activeWorklaneIDProvider: (() -> WorklaneID?)?
    var sidebarBoundsProvider: (() -> CGRect)?
    var worklaneCountProvider: (() -> Int)?
    var sidebarWidthProvider: (() -> CGFloat)?

    /// View above the sidebar in z-order. The dragged pane is reparented here
    /// so it renders on top of the sidebar during drag.
    weak var dragHostView: NSView?

    // MARK: - Public State

    private(set) var phase: PaneDragPhase = .idle

    // MARK: - Drag State

    private var draggedPaneView: PaneContainerView?
    private var originalPaneFrame: CGRect = .zero
    private var grabOffsetInContent: CGSize = .zero
    /// Grab offset in window coordinates — the canonical space that never lies.
    private var grabOffsetInWindow: CGSize = .zero
    /// Layer-hosting container for the drag preview. We animate THIS layer
    /// (not paneView.layer) to avoid AppKit fighting our transform/position changes.
    private var dragContainer: PaneDragFloatingContainer?

    /// The layer to animate for position/transform/shadow during drag.
    /// Uses the container's layer (which we own) when available.
    private var dragLayer: CALayer? {
        dragContainer?.layer ?? draggedPaneView?.layer
    }

    /// Current reduced-space insertion index (gap position in the layout without dragged pane).
    private var currentReducedIndex: Int?
    /// Current original-space insertion index (for reorderPane).
    private var currentInsertionIndex: Int?

    private var edgeScrollTimer: Timer?
    /// Current scroll velocity in content-space pt/s. Smoothly tracks the target.
    private var edgeScrollVelocity: CGFloat = 0
    private var escapeMonitor: Any?
    private var flagsChangedMonitor: Any?
    private var ghostView: PaneDragGhostView?
    private var duplicateBadgeLayer: CALayer?

    // MARK: - References

    private weak var paneStripView: PaneStripView?
    private weak var viewportView: NSView?
    private var motionController: PaneStripMotionController?
    private var originalState: PaneStripState?
    private var originalPresentation: StripPresentation?
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var backingScaleFactor: CGFloat = 1
    private var leadingVisibleInset: CGFloat = 0

    /// Layout with the dragged pane removed — computed once at activation.
    private var reducedPresentation: StripPresentation?

    // MARK: - Visual Indicators

    private var insertionLine: PaneDragInsertionLineView?
    private var splitOverlay: PaneDragSplitOverlayView?

    // MARK: - Split Detection State

    private var splitDwellTimer: Timer?
    private var splitDwellPaneID: PaneID?
    /// Once dwell is satisfied on any pane during a drag, switching panes is instant.
    private var splitDwellSatisfied: Bool = false
    private var currentSplitHit: SplitZoneHit?

    // MARK: - Sidebar Drag State

    private var currentSidebarTarget: WorklaneID?
    private var isCursorInSidebarZone: Bool = false
    private var isApproachingSidebar: Bool = false
    private var isShowingNewWorklanePlaceholder: Bool = false
    private(set) var isOptionHeld: Bool = false
    private var sidebarEdgeScrollTimer: Timer?
    private var sidebarEdgeScrollVelocity: CGFloat = 0

    // MARK: - Constants

    private static let popScale: CGFloat = 0.45
    private static let sidebarPopScale: CGFloat = 0.2
    private static let gapScreenPt: CGFloat = 20
    private static let splitDwellDuration: TimeInterval = 0.25
    private static let sidebarDeadZoneScreenPt: CGFloat = 20

    // MARK: - Shared Visual Layout

    private struct DragVisualLayout {
        let columnFrames: [CGRect]
        let paneFramesByID: [PaneID: CGRect]
        let gapCenters: [CGFloat]
    }

    private func makeDragVisualLayout(
        presentation: StripPresentation,
        activeReducedGapIndex: Int?,
        zoomScale: CGFloat
    ) -> DragVisualLayout {
        let offset = paneStripView?.resolvedDragOffset(presentation.targetOffset) ?? 0
        let extraGap = Self.gapScreenPt / max(zoomScale, 0.01)

        var shiftByColumnID: [PaneColumnID: CGFloat] = [:]
        for (index, column) in presentation.columns.enumerated() {
            var shift: CGFloat = 0
            if let gap = activeReducedGapIndex {
                if index < gap {
                    shift = -extraGap / 2
                } else {
                    shift = extraGap / 2
                }
            }
            shiftByColumnID[column.columnID] = shift
        }

        let columnFrames = presentation.columns.map { column in
            column.frame.offsetBy(dx: -offset + (shiftByColumnID[column.columnID] ?? 0), dy: 0)
        }

        var paneFramesByID: [PaneID: CGRect] = [:]
        for pane in presentation.panes {
            paneFramesByID[pane.paneID] = pane.frame.offsetBy(
                dx: -offset + (shiftByColumnID[pane.columnID] ?? 0), dy: 0
            )
        }

        var gapCenters: [CGFloat] = []
        if !columnFrames.isEmpty {
            gapCenters.append(columnFrames[0].minX)
            for i in 1..<columnFrames.count {
                gapCenters.append((columnFrames[i - 1].maxX + columnFrames[i].minX) / 2)
            }
            gapCenters.append(columnFrames[columnFrames.count - 1].maxX)
        }

        return DragVisualLayout(
            columnFrames: columnFrames,
            paneFramesByID: paneFramesByID,
            gapCenters: gapCenters
        )
    }

    // MARK: - Activation

    func activateDrag(
        paneID: PaneID,
        cursorInStrip: CGPoint,
        paneViews: [PaneID: PaneContainerView],
        viewportView: NSView,
        paneStripView: PaneStripView,
        state: PaneStripState,
        presentation: StripPresentation,
        motionController: PaneStripMotionController,
        backingScaleFactor: CGFloat,
        leadingVisibleInset: CGFloat
    ) {
        guard case .idle = phase else { return }

        guard let columnIndex = state.columns.firstIndex(where: { $0.panes.contains(where: { $0.id == paneID }) }),
              let paneIndex = state.columns[columnIndex].panes.firstIndex(where: { $0.id == paneID }),
              let paneView = paneViews[paneID] else {
            return
        }

        let column = state.columns[columnIndex]
        let pane = column.panes[paneIndex]

        self.viewportView = viewportView
        self.paneStripView = paneStripView
        self.motionController = motionController
        self.originalState = state
        self.originalPresentation = presentation
        self.paneViews = paneViews
        self.backingScaleFactor = backingScaleFactor
        self.leadingVisibleInset = leadingVisibleInset
        self.draggedPaneView = paneView
        self.originalPaneFrame = paneView.frame

        // Compute grab offset by converting cursor into the PANE'S OWN coordinate space.
        // Both cursor and center go through the same conversion path (viewportView → paneView),
        // so any viewport scroll offset cancels out.
        let cursorInPane = paneStripView.convert(cursorInStrip, to: paneView)
        let grabOffsetInPane = CGSize(
            width: paneView.bounds.midX - cursorInPane.x,
            height: paneView.bounds.midY - cursorInPane.y
        )

        // Convert this pane-local offset to window space for the overlay path.
        // At zoom 1.0, pane-local pixels ≈ window pixels (no scale transform on the pane).
        grabOffsetInWindow = grabOffsetInPane

        // Also keep the viewport-space version for the viewport path
        let cursorInContent = paneStripView.convert(cursorInStrip, to: viewportView)
        grabOffsetInContent = CGSize(
            width: paneView.frame.midX - cursorInContent.x,
            height: paneView.frame.midY - cursorInContent.y
        )

        let activeState = PaneDragActiveState(
            draggedPaneID: paneID,
            sourceColumnID: column.id,
            sourceColumnIndex: columnIndex,
            sourcePaneIndex: paneIndex,
            originalPaneState: pane,
            originalColumnWidth: column.width,
            grabOffset: grabOffsetInContent,
            cursorPosition: cursorInStrip,
            currentDropTarget: .reorderGap(columnIndex: columnIndex),
            splitPreview: nil
        )
        phase = .active(activeState)
        currentInsertionIndex = columnIndex

        // Freeze dragged pane
        paneView.beginVerticalFreeze(gravity: .top)
        paneView.setTerminalViewportSyncSuspended(true)

        // Snapshot the pane as a bitmap for the drag preview.
        // The terminal is frozen, so a static image is perfect.
        // This avoids reparenting the actual pane (which causes layer ownership issues).
        let paneSize = paneView.frame.size
        let paneCenterInViewport = CGPoint(x: paneView.frame.midX, y: paneView.frame.midY)

        let hostView = dragHostView ?? viewportView
        let centerInHost = viewportView.convert(paneCenterInViewport, to: hostView)

        // Create snapshot image
        let snapshot = NSImage(size: paneSize)
        if let bitmapRep = paneView.bitmapImageRepForCachingDisplay(in: paneView.bounds) {
            paneView.cacheDisplay(in: paneView.bounds, to: bitmapRep)
            snapshot.addRepresentation(bitmapRep)
        }

        // Create a layer-hosting container with the snapshot
        let container = PaneDragFloatingContainer(frame: CGRect(origin: .zero, size: paneSize))
        container.layer?.contents = snapshot
        container.layer?.contentsGravity = .resizeAspectFill
        hostView.addSubview(container)
        self.dragContainer = container

        // Make original pane invisible but keep it in the hierarchy
        // (isHidden = true would kill the gesture recognizer on the drag zone child)
        paneView.alphaValue = 0

        // Position the container using frame (avoids macOS anchorPoint issues)
        let isOverlay = dragHostView != nil
        let popScale = isOverlay ? Self.popScale : Self.popScale
        let scaledWidth = paneSize.width * popScale
        let scaledHeight = paneSize.height * popScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(
            x: centerInHost.x - scaledWidth / 2,
            y: centerInHost.y - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.6
        container.layer?.shadowRadius = 24
        container.layer?.shadowOffset = CGSize(width: 0, height: -10)
        container.layer?.cornerRadius = 6
        CATransaction.commit()

        container.alphaValue = 0.8

        viewportView.autoresizingMask = []

        // Signal drag active BEFORE layout
        installEscapeMonitor()
        installFlagsChangedMonitor()

        // Snapshot current Option state in case user was already holding it
        isOptionHeld = NSEvent.modifierFlags.contains(.option)
        if isOptionHeld { updateDuplicateVisuals() }

        onDragActiveChanged?(true)

        // Compute reduced layout
        var reducedState = state
        _ = reducedState.removePane(id: paneID)
        reducedPresentation = motionController.presentation(
            for: reducedState,
            in: viewportView.frame.size,
            leadingVisibleInset: leadingVisibleInset,
            backingScaleFactor: backingScaleFactor
        )

        // Compensate border width for the target zoom (0.4x) so borders stay visible.
        // Note: currentZoom is still 1.0 here — the zoom animation starts via onDragActiveChanged.
        let targetZoom = paneStripView.dragZoomScale
        for (_, view) in paneViews {
            view.applyZoomBorderCompensation(zoomScale: targetZoom)
        }

        // Apply reduced layout (no gap yet)
        applyVisualLayout(activeReducedGapIndex: nil, animated: true, excludingPaneID: paneID)

        // Insertion line
        let line = PaneDragInsertionLineView()
        line.isHidden = true
        viewportView.addSubview(line)
        insertionLine = line

        positionDraggedPane(cursorInStrip: cursorInStrip, zoomScale: paneStripView.currentZoomScale())
    }

    // MARK: - Cursor Update

    func updateCursor(_ cursorInStrip: CGPoint) {
        guard case .active(var activeState) = phase,
              let paneStripView, let viewportView,
              let reducedPresentation else { return }

        activeState.cursorPosition = cursorInStrip

        let currentZoom = paneStripView.currentZoomScale()
        positionDraggedPane(cursorInStrip: cursorInStrip, zoomScale: currentZoom)

        // --- Sidebar zone routing ---
        // Use the sidebar's actual width for boundary detection (works even when sidebar is
        // auto-hidden and leadingVisibleInset is 0). The sidebar width represents where the
        // sidebar WOULD be when fully revealed.
        let sidebarWidth = sidebarWidthProvider?() ?? 0
        let sidebarEdge = max(paneStripView.leadingVisibleInset, sidebarWidth)
        let deadZone = Self.sidebarDeadZoneScreenPt
        let cursorX = cursorInStrip.x

        let inSidebarZone = cursorX < sidebarEdge - deadZone && sidebarEdge > deadZone
        let inDeadZone = sidebarEdge > deadZone && cursorX >= sidebarEdge - deadZone && cursorX < sidebarEdge
        let approachingSidebar = cursorX < sidebarEdge

        // Fire approaching-sidebar edge callback for sidebar reveal
        if approachingSidebar != isApproachingSidebar {
            isApproachingSidebar = approachingSidebar
            onDragApproachingSidebarEdge?(approachingSidebar)
        }

        if inDeadZone {
            // Dead zone: clear all targets
            clearCanvasTargets(activeState: &activeState)
            clearSidebarTargets(activeState: &activeState)
            activeState.currentDropTarget = .none
            activeState.splitPreview = nil
            phase = .active(activeState)
            return
        }

        if inSidebarZone {
            // Entered sidebar zone — clear canvas targets and evaluate sidebar
            if !isCursorInSidebarZone {
                isCursorInSidebarZone = true
                clearCanvasTargets(activeState: &activeState)
            }

            evaluateSidebarTarget(cursorInStrip: cursorInStrip, activeState: &activeState)
            phase = .active(activeState)
            return
        }

        // Canvas zone — clear sidebar targets if we just left sidebar
        if isCursorInSidebarZone {
            isCursorInSidebarZone = false
            clearSidebarTargets(activeState: &activeState)
        }

        // --- Canvas hit detection (existing logic) ---
        // Build the current visual layout to get column frames for hit testing
        let layout = makeDragVisualLayout(
            presentation: reducedPresentation,
            activeReducedGapIndex: currentReducedIndex,
            zoomScale: currentZoom
        )

        // Convert cursor to content space
        let cursorInContent = paneStripView.convert(cursorInStrip, to: viewportView)

        // Gap-based hit test with hysteresis
        let gapHit = PaneDragHitTest.reorderGapHit(
            cursorX: cursorInContent.x,
            visibleColumnFrames: layout.columnFrames,
            zoomScale: currentZoom,
            previousReducedIndex: currentReducedIndex
        )

        if gapHit != nil {
            // Reorder gaps always win — clear any active split state
            if currentSplitHit != nil {
                clearSplitMode()
            }
            cancelSplitDwell()

            if gapHit?.reducedIndex != currentReducedIndex {
                currentReducedIndex = gapHit?.reducedIndex

                if let reducedIdx = currentReducedIndex {
                    let insertionIndex = reducedIdx >= activeState.sourceColumnIndex
                        ? reducedIdx + 1
                        : reducedIdx
                    currentInsertionIndex = insertionIndex
                    activeState.currentDropTarget = .reorderGap(columnIndex: insertionIndex)
                }

                // Re-apply layout with gap opening
                applyVisualLayout(
                    activeReducedGapIndex: currentReducedIndex,
                    animated: true,
                    excludingPaneID: activeState.draggedPaneID
                )

                // Update insertion line
                if let reducedIdx = currentReducedIndex {
                    let openedLayout = makeDragVisualLayout(
                        presentation: reducedPresentation,
                        activeReducedGapIndex: reducedIdx,
                        zoomScale: currentZoom
                    )
                    updateInsertionLine(layout: openedLayout, reducedIndex: reducedIdx, zoomScale: currentZoom)
                } else {
                    insertionLine?.isHidden = true
                }
            }

            // Update insertion line proximity-based opacity
            if let line = insertionLine, !line.isHidden {
                let lineXInStrip = viewportView.convert(
                    CGPoint(x: line.frame.midX, y: 0), to: paneStripView
                ).x
                let distance = abs(cursorInStrip.x - lineXInStrip)
                line.updateProximityOpacity(distance: distance)
            }
        } else {
            // No gap hit — clear gap state if we were in one
            if currentReducedIndex != nil {
                currentReducedIndex = nil
                currentInsertionIndex = nil
                applyVisualLayout(
                    activeReducedGapIndex: nil,
                    animated: true,
                    excludingPaneID: activeState.draggedPaneID
                )
                insertionLine?.isHidden = true
            }

            // Evaluate split target
            evaluateSplitTarget(cursorInStrip: cursorInStrip)
        }

        // Sync activeState drop target with current split/reorder state
        if let hit = currentSplitHit {
            switch hit.axis {
            case .vertical:
                activeState.currentDropTarget = .verticalSplit(targetPaneID: hit.targetPaneID, above: hit.leading)
            case .horizontal:
                activeState.currentDropTarget = .horizontalSplit(targetPaneID: hit.targetPaneID, leading: hit.leading)
            }
            activeState.splitPreview = PaneSplitPreview(
                targetPaneID: hit.targetPaneID,
                targetColumnID: hit.targetColumnID,
                axis: hit.axis,
                fraction: 0.5
            )
        } else if currentReducedIndex == nil {
            activeState.currentDropTarget = .none
            activeState.splitPreview = nil
        }

        // Edge scroll — start timer when cursor is in an edge zone.
        // The timer handles smooth acceleration/deceleration internally.
        let targetVel = targetEdgeVelocity(for: cursorInStrip.x)
        if abs(targetVel) > 0.001 || abs(edgeScrollVelocity) > 0.5 {
            startEdgeScrollIfNeeded()
        }

        phase = .active(activeState)
    }

    func updateDraggedPanePosition(zoomScale: CGFloat) {
        guard case .active(let activeState) = phase else { return }
        positionDraggedPane(cursorInStrip: activeState.cursorPosition, zoomScale: zoomScale)
    }

    func recheckEdgeScroll() {
        guard case .active(let activeState) = phase else { return }
        updateCursor(activeState.cursorPosition)
    }

    // MARK: - Drop

    func endDrag(at cursorInStrip: CGPoint) {
        guard case .active(let activeState) = phase else { return }

        // Sidebar drops take priority
        if case .sidebarWorklane(let worklaneID) = activeState.currentDropTarget {
            completeSidebarDrop(targetWorklaneID: worklaneID)
        } else if case .newWorklane = activeState.currentDropTarget {
            completeSidebarNewWorklaneDrop()
        } else if let splitHit = currentSplitHit {
            completeSplitDrop(splitHit: splitHit)
        } else if let idx = currentInsertionIndex {
            completeDrop(columnIndex: idx)
        } else {
            cancelDrag()
        }
    }

    // MARK: - Cancel

    func cancelDrag() {
        guard case .active = phase else { return }

        guard let paneStripView else {
            teardown()
            return
        }

        // Reparent back to viewportView so the animation target (content space) is correct
        reparentToViewportForAnimation()
        let targetCenter = CGPoint(x: originalPaneFrame.midX, y: originalPaneFrame.midY)

        // Clear split and sidebar state before animating back
        clearSplitMode()
        cancelSplitDwell()
        onHoveredSidebarWorklaneChanged?(nil)
        onNewWorklanePlaceholderVisibilityChanged?(false)
        onDragApproachingSidebarEdge?(false)

        // Restore original layout
        if let originalPresentation {
            paneStripView.applyDragLayout(
                originalPresentation,
                excluding: phase.activeState?.draggedPaneID ?? PaneID(""),
                animated: true
            )
        }

        // Spring back to origin
        let posSpring = CASpringAnimation(keyPath: "position")
        posSpring.toValue = NSValue(point: targetCenter)
        posSpring.mass = 0.8
        posSpring.stiffness = 350
        posSpring.damping = 26
        posSpring.initialVelocity = 0
        posSpring.duration = posSpring.settlingDuration
        posSpring.fillMode = .forwards
        posSpring.isRemovedOnCompletion = false

        let currentTransform = dragLayer?.transform ?? CATransform3DIdentity
        let transformSpring = CASpringAnimation(keyPath: "transform")
        transformSpring.fromValue = NSValue(caTransform3D: currentTransform)
        transformSpring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformSpring.mass = 0.8
        transformSpring.stiffness = 350
        transformSpring.damping = 26
        transformSpring.duration = transformSpring.settlingDuration
        transformSpring.fillMode = .forwards
        transformSpring.isRemovedOnCompletion = false

        let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnim.toValue = 0
        shadowAnim.duration = 0.15

        let stripView = paneStripView

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self.dragLayer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                stripView.endDragWithZoomIn()
            }
        }
        dragLayer?.add(posSpring, forKey: "cancelPosition")
        dragLayer?.add(transformSpring, forKey: "cancelTransform")
        dragLayer?.add(shadowAnim, forKey: "cancelShadow")
        CATransaction.commit()
    }

    // MARK: - Private — Pane Positioning

    /// Tracks whether the pane is currently at sidebar scale to avoid re-animating.
    private var isAtSidebarScale: Bool = false

    /// For canvas drop animations: move the snapshot container from the overlay
    /// to viewportView with correct content-space position and zoom-compensated scale.
    private func reparentToViewportForAnimation() {
        guard let container = dragContainer,
              let viewportView, let paneStripView else { return }

        let posInOverlay = container.layer?.position ?? .zero
        let hostView = container.superview ?? viewportView
        let posInContent = hostView.convert(posInOverlay, to: viewportView)

        viewportView.addSubview(container)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.position = posInContent
        let zoomScale = paneStripView.currentZoomScale()
        let scale = Self.popScale / max(0.01, zoomScale)
        container.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    private func positionDraggedPane(cursorInStrip: CGPoint, zoomScale: CGFloat) {
        guard let paneStripView, let viewportView else { return }

        // The snapshot container lives in the overlay (or viewportView if no overlay)
        let isInOverlay = dragContainer?.superview === dragHostView

        // In sidebar zone, center pane under cursor (zero out grab offset)
        let effectiveGrabOffset: CGSize
        let effectiveWindowOffset: CGSize
        if isCursorInSidebarZone {
            effectiveGrabOffset = .zero
            effectiveWindowOffset = .zero
        } else {
            effectiveGrabOffset = grabOffsetInContent
            effectiveWindowOffset = grabOffsetInWindow
        }

        let paneCenter: CGPoint
        let targetScale = isCursorInSidebarZone ? Self.sidebarPopScale : Self.popScale
        let scaleMultiplier: CGFloat

        if isInOverlay, let dragHostView, let container = dragContainer {
            // --- Overlay path ---
            // Use NSView.frame for positioning (no layer.position/anchorPoint issues).
            let cursorInOverlay = dragHostView.convert(cursorInStrip, from: paneStripView)
            let scaledWidth = originalPaneFrame.width * targetScale
            let scaledHeight = originalPaneFrame.height * targetScale
            let offsetX = effectiveWindowOffset.width * targetScale
            let offsetY = effectiveWindowOffset.height * targetScale
            let targetFrame = CGRect(
                x: cursorInOverlay.x + offsetX - scaledWidth / 2,
                y: cursorInOverlay.y + offsetY - scaledHeight / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = targetFrame
            CATransaction.commit()
            // Skip the dragLayer position/transform below
            return
        } else {
            // --- Viewport path (original) ---
            let cursorInContent = paneStripView.convert(cursorInStrip, to: viewportView)
            paneCenter = CGPoint(
                x: cursorInContent.x + effectiveGrabOffset.width,
                y: cursorInContent.y + effectiveGrabOffset.height
            )
            // Compensate for viewportView zoom
            scaleMultiplier = targetScale / max(0.01, zoomScale)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragLayer?.position = paneCenter
        CATransaction.commit()

        // Animate scale transition when crossing sidebar boundary
        let shouldBeAtSidebarScale = isCursorInSidebarZone
        if shouldBeAtSidebarScale != isAtSidebarScale {
            isAtSidebarScale = shouldBeAtSidebarScale

            let spring = CASpringAnimation(keyPath: "transform")
            spring.toValue = NSValue(caTransform3D: CATransform3DMakeScale(scaleMultiplier, scaleMultiplier, 1))
            spring.mass = 0.6
            spring.stiffness = 500
            spring.damping = 30
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            dragLayer?.add(spring, forKey: "sidebarScaleSnap")
        } else {
            // Normal per-frame update (no implicit animation)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dragLayer?.removeAnimation(forKey: "sidebarScaleSnap")
            dragLayer?.transform = CATransform3DMakeScale(scaleMultiplier, scaleMultiplier, 1)
            CATransaction.commit()
        }
    }

    // MARK: - Private — Visual Layout Application

    private func applyVisualLayout(activeReducedGapIndex: Int?, animated: Bool, excludingPaneID: PaneID) {
        guard let paneStripView, let reducedPresentation else { return }
        let zoomScale = paneStripView.currentZoomScale()
        let layout = makeDragVisualLayout(
            presentation: reducedPresentation,
            activeReducedGapIndex: activeReducedGapIndex,
            zoomScale: zoomScale
        )

        let updates = {
            for pane in reducedPresentation.panes where pane.paneID != excludingPaneID {
                guard let paneView = self.paneViews[pane.paneID],
                      let targetFrame = layout.paneFramesByID[pane.paneID] else { continue }
                paneView.frame = targetFrame
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }

    // MARK: - Private — Drop

    private func completeDrop(columnIndex: Int) {
        guard let paneStripView else {
            onReorder?(phase.activeState?.draggedPaneID ?? PaneID(""), columnIndex)
            teardown()
            return
        }

        // Find drop target position from visual layout
        let zoomScale = paneStripView.currentZoomScale()
        let targetCenter: CGPoint
        if let reducedPresentation, let reducedIdx = currentReducedIndex {
            let layout = makeDragVisualLayout(
                presentation: reducedPresentation,
                activeReducedGapIndex: reducedIdx,
                zoomScale: zoomScale
            )
            if layout.gapCenters.indices.contains(reducedIdx),
               let refFrame = layout.columnFrames.first {
                let gapX = layout.gapCenters[reducedIdx]
                targetCenter = CGPoint(x: gapX, y: refFrame.midY)
            } else if let paneLayer = draggedPaneView?.layer {
                targetCenter = paneLayer.position
            } else {
                targetCenter = originalPaneFrame.center
            }
        } else if let layerPos = dragLayer?.position {
            targetCenter = layerPos
        } else {
            let paneID = phase.activeState?.draggedPaneID
            restoreDraggedPane()
            if let paneID { onReorder?(paneID, columnIndex) }
            paneStripView.endDragWithZoomIn()
            teardown()
            return
        }

        // Reparent back to viewportView so existing content-space animation math works
        reparentToViewportForAnimation()

        // Spring animation for position — snappy with minimal overshoot
        let posSpring = CASpringAnimation(keyPath: "position")
        posSpring.toValue = NSValue(point: targetCenter)
        posSpring.mass = 0.8
        posSpring.stiffness = 400
        posSpring.damping = 28
        posSpring.initialVelocity = 0
        posSpring.duration = posSpring.settlingDuration
        posSpring.fillMode = .forwards
        posSpring.isRemovedOnCompletion = false

        // Spring animation for transform — scale back down to match zoomed panes
        let currentTransform = dragLayer?.transform ?? CATransform3DIdentity
        let targetTransform = CATransform3DIdentity  // will match zoomed scale via bounds
        let transformSpring = CASpringAnimation(keyPath: "transform")
        transformSpring.fromValue = NSValue(caTransform3D: currentTransform)
        transformSpring.toValue = NSValue(caTransform3D: targetTransform)
        transformSpring.mass = 0.8
        transformSpring.stiffness = 400
        transformSpring.damping = 28
        transformSpring.duration = transformSpring.settlingDuration
        transformSpring.fillMode = .forwards
        transformSpring.isRemovedOnCompletion = false

        // Shadow fades quickly
        let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnim.toValue = 0
        shadowAnim.duration = 0.15

        let paneID = phase.activeState?.draggedPaneID
        let stripView = paneStripView

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self.dragLayer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                if let paneID {
                    self.onReorder?(paneID, columnIndex)
                }
                stripView.endDragWithZoomIn()
            }
        }
        dragLayer?.add(posSpring, forKey: "settlePosition")
        dragLayer?.add(transformSpring, forKey: "settleTransform")
        dragLayer?.add(shadowAnim, forKey: "settleShadow")
        CATransaction.commit()
    }

    private func completeSplitDrop(splitHit: SplitZoneHit) {
        guard let paneStripView else {
            let paneID = phase.activeState?.draggedPaneID ?? PaneID("")
            onSplitDrop?(paneID, splitHit.targetPaneID, splitHit.axis, splitHit.leading)
            teardown()
            return
        }

        // Target: center of the overlay (where the pane will land)
        let targetCenter: CGPoint
        if let overlay = splitOverlay {
            targetCenter = CGPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        } else if let reducedPresentation {
            let zoomScale = paneStripView.currentZoomScale()
            let layout = makeDragVisualLayout(
                presentation: reducedPresentation,
                activeReducedGapIndex: nil,
                zoomScale: zoomScale
            )
            let paneFrame = layout.paneFramesByID[splitHit.targetPaneID] ?? .zero
            targetCenter = CGPoint(x: paneFrame.midX, y: paneFrame.midY)
        } else {
            targetCenter = originalPaneFrame.center
        }

        // Hide the split overlay immediately
        splitOverlay?.removeFromSuperview()
        splitOverlay = nil

        // Reparent back to viewportView so existing content-space animation math works
        reparentToViewportForAnimation()

        // Spring animation — same feel as reorder drop
        let posSpring = CASpringAnimation(keyPath: "position")
        posSpring.toValue = NSValue(point: targetCenter)
        posSpring.mass = 0.8
        posSpring.stiffness = 400
        posSpring.damping = 28
        posSpring.initialVelocity = 0
        posSpring.duration = posSpring.settlingDuration
        posSpring.fillMode = .forwards
        posSpring.isRemovedOnCompletion = false

        let currentTransform = dragLayer?.transform ?? CATransform3DIdentity
        let transformSpring = CASpringAnimation(keyPath: "transform")
        transformSpring.fromValue = NSValue(caTransform3D: currentTransform)
        transformSpring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformSpring.mass = 0.8
        transformSpring.stiffness = 400
        transformSpring.damping = 28
        transformSpring.duration = transformSpring.settlingDuration
        transformSpring.fillMode = .forwards
        transformSpring.isRemovedOnCompletion = false

        let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
        shadowAnim.toValue = 0
        shadowAnim.duration = 0.15

        let paneID = phase.activeState?.draggedPaneID
        let stripView = paneStripView

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                self.dragLayer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                if let paneID {
                    self.onSplitDrop?(paneID, splitHit.targetPaneID, splitHit.axis, splitHit.leading)
                }
                stripView.endDragWithZoomIn()
            }
        }
        dragLayer?.add(posSpring, forKey: "settlePosition")
        dragLayer?.add(transformSpring, forKey: "settleTransform")
        dragLayer?.add(shadowAnim, forKey: "settleShadow")
        CATransaction.commit()
    }

    // MARK: - Private — Sidebar Drop

    private func completeSidebarDrop(targetWorklaneID: WorklaneID) {
        guard let paneStripView else {
            let paneID = phase.activeState?.draggedPaneID ?? PaneID("")
            let isDuplicate = isOptionHeld
            onSidebarDrop?(paneID, targetWorklaneID, isDuplicate)
            teardown()
            return
        }

        // Find the target row center from the sidebar frame provider.
        // Frames are in PaneStripView coords → convert to dragged pane's superview.
        let worklaneFrames = sidebarWorklaneFrameProvider?() ?? []
        let targetCenter: CGPoint
        if let targetFrame = worklaneFrames.first(where: { $0.0 == targetWorklaneID })?.1 {
            let centerInStrip = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            let containerSuperview = dragContainer?.superview ?? viewportView ?? paneStripView
            targetCenter = paneStripView.convert(centerInStrip, to: containerSuperview)
        } else if let layerPos = dragLayer?.position {
            targetCenter = layerPos
        } else {
            cancelDrag()
            return
        }

        let paneID = phase.activeState?.draggedPaneID
        let isDuplicate = isOptionHeld
        let stripView = paneStripView

        animateSidebarDrop(to: targetCenter) {
            MainActor.assumeIsolated {
                self.dragLayer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                if let paneID {
                    self.onSidebarDrop?(paneID, targetWorklaneID, isDuplicate)
                }
                stripView.endDragWithZoomIn()
            }
        }
    }

    private func completeSidebarNewWorklaneDrop() {
        guard let paneStripView else {
            let paneID = phase.activeState?.draggedPaneID ?? PaneID("")
            let isDuplicate = isOptionHeld
            onSidebarNewWorklaneDrop?(paneID, isDuplicate)
            teardown()
            return
        }

        // Target: the new-worklane placeholder area (below last row)
        let worklaneFrames = sidebarWorklaneFrameProvider?() ?? []
        let targetCenter: CGPoint
        if let lastFrame = worklaneFrames.last?.1 {
            let placeholderCenterY = lastFrame.minY - 30
            let centerInStrip = CGPoint(x: lastFrame.midX, y: placeholderCenterY)
            let containerSuperview = dragContainer?.superview ?? viewportView ?? paneStripView
            targetCenter = paneStripView.convert(centerInStrip, to: containerSuperview)
        } else if let layerPos = dragLayer?.position {
            targetCenter = layerPos
        } else {
            cancelDrag()
            return
        }

        let paneID = phase.activeState?.draggedPaneID
        let isDuplicate = isOptionHeld
        let stripView = paneStripView

        animateSidebarDrop(to: targetCenter) {
            MainActor.assumeIsolated {
                self.dragLayer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                if let paneID {
                    self.onSidebarNewWorklaneDrop?(paneID, isDuplicate)
                }
                stripView.endDragWithZoomIn()
            }
        }
    }

    private func animateSidebarDrop(to targetCenter: CGPoint, completion: @escaping @Sendable () -> Void) {
        guard let container = dragContainer else {
            MainActor.assumeIsolated { completion() }
            return
        }

        // Animate frame to shrink into the target center
        let tinySize: CGFloat = 4
        let targetFrame = CGRect(
            x: targetCenter.x - tinySize / 2,
            y: targetCenter.y - tinySize / 2,
            width: tinySize,
            height: tinySize
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            container.animator().frame = targetFrame
            container.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })

        container.layer?.shadowOpacity = 0
    }

    // MARK: - Private — Restore

    private func restoreDraggedPane() {
        guard let paneView = draggedPaneView else { return }

        // Restore the original pane visibility
        paneView.alphaValue = 1.0
        paneView.frame = originalPaneFrame

        // Remove the snapshot container
        dragContainer?.removeFromSuperview()
        dragContainer = nil
    }

    // MARK: - Private — Insertion Line

    private func updateInsertionLine(
        layout: DragVisualLayout,
        reducedIndex: Int,
        zoomScale: CGFloat
    ) {
        guard let line = insertionLine,
              layout.gapCenters.indices.contains(reducedIndex),
              !layout.columnFrames.isEmpty else {
            insertionLine?.isHidden = true
            return
        }

        let refFrame = layout.columnFrames[min(max(reducedIndex, 0), layout.columnFrames.count - 1)]
        // Keep line thickness roughly constant on screen
        let lineWidth: CGFloat = 6 / max(zoomScale, 0.01)
        let lineX = layout.gapCenters[reducedIndex]

        line.isHidden = false
        line.frame = CGRect(
            x: lineX - lineWidth / 2,
            y: refFrame.minY,
            width: lineWidth,
            height: refFrame.height
        )
        line.startPulsing()
    }

    // MARK: - Private — Split Dwell Timer

    private func startSplitDwell(for paneID: PaneID) {
        guard splitDwellPaneID != paneID else { return }
        cancelSplitDwell()
        splitDwellPaneID = paneID
        let timer = Timer(timeInterval: Self.splitDwellDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.splitDwellSatisfied = true
                if case .active(let activeState) = self.phase {
                    self.evaluateSplitTarget(cursorInStrip: activeState.cursorPosition)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        splitDwellTimer = timer
    }

    private func cancelSplitDwell() {
        splitDwellTimer?.invalidate()
        splitDwellTimer = nil
        splitDwellPaneID = nil
        // Do NOT reset splitDwellSatisfied — once satisfied, instant switching allowed
    }

    private func resetSplitState() {
        cancelSplitDwell()
        splitDwellSatisfied = false
        currentSplitHit = nil
        hideSplitOverlay()
    }

    // MARK: - Private — Split Target Evaluation

    private func evaluateSplitTarget(cursorInStrip: CGPoint) {
        guard case .active(let activeState) = phase,
              let paneStripView, let viewportView,
              let reducedPresentation else { return }

        let currentZoom = paneStripView.currentZoomScale()
        let layout = makeDragVisualLayout(
            presentation: reducedPresentation,
            activeReducedGapIndex: nil,
            zoomScale: currentZoom
        )

        let cursorInContent = paneStripView.convert(cursorInStrip, to: viewportView)

        var columnForPane: [PaneID: PaneColumnID] = [:]
        for pane in reducedPresentation.panes {
            columnForPane[pane.paneID] = pane.columnID
        }

        let splitHit = PaneDragHitTest.splitZoneHit(
            cursorInContent: cursorInContent,
            paneFramesByID: layout.paneFramesByID,
            columnForPane: columnForPane,
            sourceColumnID: activeState.sourceColumnID,
            minimumPaneHeight: PaneStripState.minimumVerticalPaneHeight
        )

        guard let splitHit else {
            if currentSplitHit != nil {
                clearSplitMode()
            }
            cancelSplitDwell()
            return
        }

        startSplitDwell(for: splitHit.targetPaneID)

        if splitDwellSatisfied {
            if splitHit != currentSplitHit {
                currentSplitHit = splitHit
                showSplitOverlay(for: splitHit, layout: layout)
            }
        }
    }

    // MARK: - Private — Split Overlay

    private func showSplitOverlay(for hit: SplitZoneHit, layout: DragVisualLayout) {
        guard let viewportView, let draggedPaneView else { return }

        // Mutual exclusion: hide insertion line
        insertionLine?.isHidden = true

        let paneFrame = layout.paneFramesByID[hit.targetPaneID] ?? .zero
        let overlayFrame: CGRect

        switch hit.axis {
        case .vertical:
            let halfHeight = paneFrame.height / 2
            if hit.leading {
                // "above" = upper half (higher Y in bottom-left coords)
                overlayFrame = CGRect(x: paneFrame.minX, y: paneFrame.midY,
                                      width: paneFrame.width, height: halfHeight)
            } else {
                // "below" = lower half
                overlayFrame = CGRect(x: paneFrame.minX, y: paneFrame.minY,
                                      width: paneFrame.width, height: halfHeight)
            }
        case .horizontal:
            let halfWidth = paneFrame.width / 2
            if hit.leading {
                overlayFrame = CGRect(x: paneFrame.minX, y: paneFrame.minY,
                                      width: halfWidth, height: paneFrame.height)
            } else {
                overlayFrame = CGRect(x: paneFrame.midX, y: paneFrame.minY,
                                      width: halfWidth, height: paneFrame.height)
            }
        }

        if let existing = splitOverlay {
            // Animate to new position (switching halves or panes)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                existing.frame = overlayFrame
            }
        } else {
            let overlay = PaneDragSplitOverlayView(frame: overlayFrame)
            viewportView.addSubview(overlay, positioned: .below, relativeTo: draggedPaneView)
            splitOverlay = overlay
            overlay.animateIn()
        }
    }

    private func hideSplitOverlay() {
        guard let overlay = splitOverlay else { return }
        self.splitOverlay = nil
        overlay.animateOut {
            overlay.removeFromSuperview()
        }
    }

    private func clearSplitMode() {
        currentSplitHit = nil
        hideSplitOverlay()
        // Do NOT reset splitDwellSatisfied — allow instant re-entry
    }

    // MARK: - Private — Sidebar Zone Detection

    private func evaluateSidebarTarget(cursorInStrip: CGPoint, activeState: inout PaneDragActiveState) {
        let worklaneFrames = sidebarWorklaneFrameProvider?() ?? []
        let activeID = activeWorklaneIDProvider?()
        let sidebarBounds = sidebarBoundsProvider?() ?? .zero
        let worklaneCount = worklaneCountProvider?() ?? 1

        let hit = PaneDragHitTest.sidebarRowHit(
            cursorInStrip: cursorInStrip,
            worklaneFrames: worklaneFrames,
            activeWorklaneID: activeID,
            sidebarBottomY: sidebarBounds.minY,
            isOptionHeld: isOptionHeld,
            worklaneCount: worklaneCount
        )

        switch hit {
        case .worklane(let worklaneID):
            if currentSidebarTarget != worklaneID {
                currentSidebarTarget = worklaneID
                onHoveredSidebarWorklaneChanged?(worklaneID)
            }
            if isShowingNewWorklanePlaceholder {
                isShowingNewWorklanePlaceholder = false
                onNewWorklanePlaceholderVisibilityChanged?(false)
            }
            activeState.currentDropTarget = .sidebarWorklane(worklaneID)

        case .newWorklane:
            if currentSidebarTarget != nil {
                currentSidebarTarget = nil
                onHoveredSidebarWorklaneChanged?(nil)
            }
            if !isShowingNewWorklanePlaceholder {
                isShowingNewWorklanePlaceholder = true
                onNewWorklanePlaceholderVisibilityChanged?(true)
            }
            activeState.currentDropTarget = .newWorklane

        case .none:
            if currentSidebarTarget != nil {
                currentSidebarTarget = nil
                onHoveredSidebarWorklaneChanged?(nil)
            }
            if isShowingNewWorklanePlaceholder {
                isShowingNewWorklanePlaceholder = false
                onNewWorklanePlaceholderVisibilityChanged?(false)
            }
            activeState.currentDropTarget = .none
        }

        activeState.splitPreview = nil

        // Sidebar vertical edge scroll
        updateSidebarEdgeScroll(cursorInStrip: cursorInStrip)
    }

    private func clearCanvasTargets(activeState: inout PaneDragActiveState) {
        if currentReducedIndex != nil {
            currentReducedIndex = nil
            currentInsertionIndex = nil
            applyVisualLayout(
                activeReducedGapIndex: nil,
                animated: true,
                excludingPaneID: activeState.draggedPaneID
            )
            insertionLine?.isHidden = true
        }
        if currentSplitHit != nil {
            clearSplitMode()
        }
        cancelSplitDwell()
        stopEdgeScroll()
    }

    private func clearSidebarTargets(activeState: inout PaneDragActiveState) {
        if currentSidebarTarget != nil {
            currentSidebarTarget = nil
            onHoveredSidebarWorklaneChanged?(nil)
        }
        if isShowingNewWorklanePlaceholder {
            isShowingNewWorklanePlaceholder = false
            onNewWorklanePlaceholderVisibilityChanged?(false)
        }
        stopSidebarEdgeScroll()
    }

    // MARK: - Private — Edge Scroll

    /// Compute the TARGET scroll velocity (in screen pt/s) from cursor position.
    /// Uses a cubic ease-in curve with a dead zone for natural feel.
    private func targetEdgeVelocity(for cursorX: CGFloat) -> CGFloat {
        guard let paneStripView else { return 0 }

        let visibleMinX = paneStripView.leadingVisibleInset
        let visibleMaxX = paneStripView.bounds.width
        let edgeZone: CGFloat = 80
        let deadZone: CGFloat = 12  // ignore first 12pt to prevent accidental scroll
        let maxSpeed: CGFloat = 1200

        // Left edge
        let leftEdge = visibleMinX
        if cursorX < leftEdge + edgeZone {
            let distFromEdge = max(0, cursorX - leftEdge)
            let activeZone = edgeZone - deadZone
            guard activeZone > 0 else { return 0 }
            let proximity = max(0, 1 - (distFromEdge - deadZone) / activeZone)
            guard proximity > 0 else { return 0 }
            return -maxSpeed * proximity * proximity * proximity
        }

        // Right edge
        let rightEdgeStart = visibleMaxX - edgeZone
        if cursorX > rightEdgeStart {
            let distFromEdge = max(0, visibleMaxX - cursorX)
            let activeZone = edgeZone - deadZone
            guard activeZone > 0 else { return 0 }
            let proximity = max(0, 1 - (distFromEdge - deadZone) / activeZone)
            guard proximity > 0 else { return 0 }
            return maxSpeed * proximity * proximity * proximity
        }

        return 0
    }

    private func startEdgeScrollIfNeeded() {
        guard edgeScrollTimer == nil, let paneStripView,
              !paneStripView.isZoomAnimating else { return }

        // Timer fires at 120Hz in .common mode so it runs during gesture tracking.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard case .active(let activeState) = self.phase,
                  let paneStripView = self.paneStripView else {
                self.stopEdgeScroll()
                return
            }

            let dt: CGFloat = 1.0 / 120
            let zoomScale = paneStripView.currentZoomScale()

            // Target velocity from cursor position (screen-space pt/s)
            let target = self.targetEdgeVelocity(for: activeState.cursorPosition.x)

            // Smoothly interpolate current velocity toward target.
            // Faster ramp-up (0.15), gentler deceleration (0.06) for natural momentum.
            let smoothing: CGFloat = abs(target) > abs(self.edgeScrollVelocity) ? 0.15 : 0.06
            self.edgeScrollVelocity += (target - self.edgeScrollVelocity) * smoothing

            // Stop timer only when velocity has fully settled to near-zero
            if abs(self.edgeScrollVelocity) < 0.5 && abs(target) < 0.001 {
                self.edgeScrollVelocity = 0
                self.stopEdgeScroll()
                return
            }

            // Convert screen velocity to content-space delta
            let contentDelta = self.edgeScrollVelocity * dt / max(0.01, zoomScale)
            paneStripView.dragScrollOffsetX += contentDelta
            paneStripView.applyCurrentZoom()

            self.updateCursor(activeState.cursorPosition)
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeScrollTimer = timer
    }

    private func stopEdgeScroll() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer = nil
    }

    // MARK: - Private — Sidebar Edge Scroll

    private func updateSidebarEdgeScroll(cursorInStrip: CGPoint) {
        let sidebarBounds = sidebarBoundsProvider?() ?? .zero
        guard sidebarBounds.height > 0 else {
            stopSidebarEdgeScroll()
            return
        }

        let targetVel = PaneDragSidebarEdgeScrollDriver.velocity(
            cursorY: cursorInStrip.y,
            sidebarMinY: sidebarBounds.minY,
            sidebarMaxY: sidebarBounds.maxY
        )

        if abs(targetVel) > 0.001 || abs(sidebarEdgeScrollVelocity) > 0.5 {
            startSidebarEdgeScrollIfNeeded(targetVelocity: targetVel)
        }
    }

    private func startSidebarEdgeScrollIfNeeded(targetVelocity: CGFloat) {
        guard sidebarEdgeScrollTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard case .active(let activeState) = self.phase else {
                self.stopSidebarEdgeScroll()
                return
            }

            let sidebarBounds = self.sidebarBoundsProvider?() ?? .zero
            let target = PaneDragSidebarEdgeScrollDriver.velocity(
                cursorY: activeState.cursorPosition.y,
                sidebarMinY: sidebarBounds.minY,
                sidebarMaxY: sidebarBounds.maxY
            )

            let smoothing: CGFloat = abs(target) > abs(self.sidebarEdgeScrollVelocity) ? 0.15 : 0.06
            self.sidebarEdgeScrollVelocity += (target - self.sidebarEdgeScrollVelocity) * smoothing

            if abs(self.sidebarEdgeScrollVelocity) < 0.5 && abs(target) < 0.001 {
                self.sidebarEdgeScrollVelocity = 0
                self.stopSidebarEdgeScroll()
                return
            }

            let dt: CGFloat = 1.0 / 120
            let delta = self.sidebarEdgeScrollVelocity * dt
            self.onSidebarScrollRequested?(delta)
        }
        RunLoop.main.add(timer, forMode: .common)
        sidebarEdgeScrollTimer = timer
    }

    private func stopSidebarEdgeScroll() {
        sidebarEdgeScrollTimer?.invalidate()
        sidebarEdgeScrollTimer = nil
        sidebarEdgeScrollVelocity = 0
    }

    // MARK: - Private — Escape Monitor

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, case .active = self.phase else { return event }
            guard event.keyCode == 53 else { return event }
            self.cancelDrag()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    // MARK: - Private — Flags Changed Monitor (Option Key)

    private func installFlagsChangedMonitor() {
        guard flagsChangedMonitor == nil else { return }
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, case .active = self.phase else { return event }
            let optionHeld = event.modifierFlags.contains(.option)
            if optionHeld != self.isOptionHeld {
                self.isOptionHeld = optionHeld
                self.updateDuplicateVisuals()
                // Re-evaluate sidebar targeting (single-worklane guard depends on Option state)
                if self.isCursorInSidebarZone, case .active(let activeState) = self.phase {
                    var mutableState = activeState
                    self.evaluateSidebarTarget(cursorInStrip: activeState.cursorPosition, activeState: &mutableState)
                    self.phase = .active(mutableState)
                }
            }
            return event
        }
    }

    private func removeFlagsChangedMonitor() {
        guard let flagsChangedMonitor else { return }
        NSEvent.removeMonitor(flagsChangedMonitor)
        self.flagsChangedMonitor = nil
    }

    private func updateDuplicateVisuals() {
        if isOptionHeld {
            showGhostView()
            showDuplicateBadge()
        } else {
            hideGhostView()
            hideDuplicateBadge()
        }
    }

    // MARK: - Private — Ghost View (Duplicate Indicator)

    private func showGhostView() {
        guard ghostView == nil, let viewportView, let draggedPaneView else { return }

        let ghost = PaneDragGhostView(frame: originalPaneFrame)
        ghost.alphaValue = 0
        viewportView.addSubview(ghost, positioned: .below, relativeTo: draggedPaneView)
        ghostView = ghost

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            ghost.animator().alphaValue = 0.3
        }
    }

    private func hideGhostView() {
        guard let ghost = ghostView else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            ghost.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            ghost.removeFromSuperview()
            self?.ghostView = nil
        })
    }

    // MARK: - Private — Duplicate Badge

    private func showDuplicateBadge() {
        guard duplicateBadgeLayer == nil, let paneLayer = draggedPaneView?.layer else { return }

        let badgeSize: CGFloat = 28
        let badge = CALayer()
        badge.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
        badge.cornerRadius = badgeSize / 2
        badge.backgroundColor = NSColor.controlAccentColor.cgColor

        // Render '+' symbol
        let textLayer = CATextLayer()
        textLayer.string = "+"
        textLayer.fontSize = 20
        textLayer.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.bounds = badge.bounds
        textLayer.position = CGPoint(x: badgeSize / 2, y: badgeSize / 2)
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        badge.addSublayer(textLayer)

        // Position at top-right of the pane
        badge.position = CGPoint(
            x: paneLayer.bounds.maxX - badgeSize / 2 - 8,
            y: paneLayer.bounds.maxY - badgeSize / 2 - 8
        )

        // Spring scale in
        badge.transform = CATransform3DMakeScale(0.01, 0.01, 1)
        paneLayer.addSublayer(badge)
        duplicateBadgeLayer = badge

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.01, 0.01, 1))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 0.6
        spring.stiffness = 400
        spring.damping = 18
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        badge.add(spring, forKey: "badgeSpringIn")
    }

    private func hideDuplicateBadge() {
        guard let badge = duplicateBadgeLayer else { return }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.toValue = NSValue(caTransform3D: CATransform3DMakeScale(0.01, 0.01, 1))
        spring.mass = 0.6
        spring.stiffness = 400
        spring.damping = 18
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                badge.removeFromSuperlayer()
                self.duplicateBadgeLayer = nil
            }
        }
        badge.add(spring, forKey: "badgeSpringOut")
        CATransaction.commit()
    }

    // MARK: - Private — Teardown

    private func teardown() {
        removeEscapeMonitor()
        removeFlagsChangedMonitor()
        stopEdgeScroll()
        stopSidebarEdgeScroll()

        insertionLine?.removeFromSuperview()
        insertionLine = nil

        // Remove overlay without animation during teardown
        splitOverlay?.removeFromSuperview()
        splitOverlay = nil
        cancelSplitDwell()
        splitDwellSatisfied = false
        currentSplitHit = nil

        // Remove duplicate mode visuals
        ghostView?.removeFromSuperview()
        ghostView = nil
        duplicateBadgeLayer?.removeFromSuperlayer()
        duplicateBadgeLayer = nil

        // Do NOT unfreeze terminals here — keep ALL panes frozen until
        // endDragWithZoomIn completes the zoom-in animation. Unfreezing
        // early causes terminals to re-render at the wrong backing size.

        // Restore normal border width after zoom ends
        for (_, view) in paneViews {
            view.resetZoomBorderCompensation()
        }

        dragContainer?.removeFromSuperview()
        dragContainer = nil
        draggedPaneView = nil
        originalPaneFrame = .zero
        paneViews = [:]
        originalState = nil
        originalPresentation = nil
        reducedPresentation = nil
        motionController = nil
        phase = .idle
        currentReducedIndex = nil
        currentInsertionIndex = nil
        grabOffsetInContent = .zero
        grabOffsetInWindow = .zero
        edgeScrollVelocity = 0
        isAtSidebarScale = false
        currentSidebarTarget = nil
        isCursorInSidebarZone = false
        isApproachingSidebar = false
        isShowingNewWorklanePlaceholder = false
        isOptionHeld = false

        onHoveredSidebarWorklaneChanged?(nil)
        onNewWorklanePlaceholderVisibilityChanged?(false)
        onDragApproachingSidebarEdge?(false)

        onDragActiveChanged?(false)
    }
}

// MARK: - PaneDragPhase Helpers

extension PaneDragPhase {
    var activeState: PaneDragActiveState? {
        if case .active(let state) = self { return state }
        return nil
    }
}

// MARK: - CGRect Extension

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
