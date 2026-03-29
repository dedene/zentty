import AppKit
import QuartzCore

@MainActor
final class PaneDragCoordinator {

    // MARK: - Callbacks

    var onReorder: ((PaneID, Int) -> Void)?
    var onDragActiveChanged: ((Bool) -> Void)?

    // MARK: - Public State

    private(set) var phase: PaneDragPhase = .idle

    // MARK: - Drag State

    private var draggedPaneView: PaneContainerView?
    private var originalPaneFrame: CGRect = .zero
    private var grabOffsetInContent: CGSize = .zero

    /// Current reduced-space insertion index (gap position in the layout without dragged pane).
    private var currentReducedIndex: Int?
    /// Current original-space insertion index (for reorderPane).
    private var currentInsertionIndex: Int?

    private var edgeScrollTimer: Timer?
    /// Current scroll velocity in content-space pt/s. Smoothly tracks the target.
    private var edgeScrollVelocity: CGFloat = 0
    private var escapeMonitor: Any?

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

    // MARK: - Constants

    private static let popScale: CGFloat = 0.5
    private static let gapScreenPt: CGFloat = 20

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

        // Bring to front
        viewportView.addSubview(paneView, positioned: .above, relativeTo: nil)

        // Pop transform
        let currentZoom = paneStripView.currentZoomScale()
        let popMultiplier = Self.popScale / max(0.01, currentZoom)
        paneView.wantsLayer = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paneView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        paneView.layer?.position = CGPoint(x: paneView.frame.midX, y: paneView.frame.midY)
        paneView.layer?.transform = CATransform3DMakeScale(popMultiplier, popMultiplier, 1)
        CATransaction.commit()

        // Shadow
        paneView.shadow = NSShadow()
        paneView.layer?.shadowColor = NSColor.black.cgColor
        paneView.layer?.shadowOpacity = 0.6
        paneView.layer?.shadowRadius = 24
        paneView.layer?.shadowOffset = CGSize(width: 0, height: -10)

        viewportView.autoresizingMask = []

        // Signal drag active BEFORE layout
        installEscapeMonitor()
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

        // Apply reduced layout (no gap yet)
        applyVisualLayout(activeReducedGapIndex: nil, animated: true, excludingPaneID: paneID)

        // Insertion line
        let line = PaneDragInsertionLineView()
        line.isHidden = true
        viewportView.addSubview(line, positioned: .below, relativeTo: paneView)
        insertionLine = line

        positionDraggedPane(cursorInStrip: cursorInStrip, zoomScale: currentZoom)
    }

    // MARK: - Cursor Update

    func updateCursor(_ cursorInStrip: CGPoint) {
        guard case .active(var activeState) = phase,
              let paneStripView, let viewportView,
              let reducedPresentation else { return }

        activeState.cursorPosition = cursorInStrip

        let currentZoom = paneStripView.currentZoomScale()
        positionDraggedPane(cursorInStrip: cursorInStrip, zoomScale: currentZoom)

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

        if let idx = currentInsertionIndex {
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

        let targetCenter = CGPoint(x: originalPaneFrame.midX, y: originalPaneFrame.midY)

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

        let currentTransform = draggedPaneView?.layer?.transform ?? CATransform3DIdentity
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
                self.draggedPaneView?.layer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                stripView.endDragWithZoomIn()
            }
        }
        draggedPaneView?.layer?.add(posSpring, forKey: "cancelPosition")
        draggedPaneView?.layer?.add(transformSpring, forKey: "cancelTransform")
        draggedPaneView?.layer?.add(shadowAnim, forKey: "cancelShadow")
        CATransaction.commit()
    }

    // MARK: - Private — Pane Positioning

    private func positionDraggedPane(cursorInStrip: CGPoint, zoomScale: CGFloat) {
        guard let paneView = draggedPaneView,
              let paneStripView, let viewportView else { return }

        let cursorInContent = paneStripView.convert(cursorInStrip, to: viewportView)
        let paneCenterInContent = CGPoint(
            x: cursorInContent.x + grabOffsetInContent.width,
            y: cursorInContent.y + grabOffsetInContent.height
        )

        paneView.layer?.position = paneCenterInContent

        let popMultiplier = Self.popScale / max(0.01, zoomScale)
        paneView.layer?.transform = CATransform3DMakeScale(popMultiplier, popMultiplier, 1)
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
        } else if let paneLayer = draggedPaneView?.layer {
            targetCenter = paneLayer.position
        } else {
            let paneID = phase.activeState?.draggedPaneID
            restoreDraggedPane()
            if let paneID { onReorder?(paneID, columnIndex) }
            paneStripView.endDragWithZoomIn()
            teardown()
            return
        }

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
        let currentTransform = draggedPaneView?.layer?.transform ?? CATransform3DIdentity
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
                self.draggedPaneView?.layer?.removeAllAnimations()
                self.restoreDraggedPane()
                self.teardown()
                if let paneID {
                    self.onReorder?(paneID, columnIndex)
                }
                stripView.endDragWithZoomIn()
            }
        }
        draggedPaneView?.layer?.add(posSpring, forKey: "settlePosition")
        draggedPaneView?.layer?.add(transformSpring, forKey: "settleTransform")
        draggedPaneView?.layer?.add(shadowAnim, forKey: "settleShadow")
        CATransaction.commit()
    }

    // MARK: - Private — Restore

    private func restoreDraggedPane() {
        guard let paneView = draggedPaneView else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paneView.layer?.transform = CATransform3DIdentity
        paneView.layer?.anchorPoint = CGPoint(x: 0, y: 0)
        paneView.layer?.position = originalPaneFrame.origin
        paneView.layer?.shadowOpacity = 0
        paneView.layer?.shadowRadius = 0
        CATransaction.commit()

        paneView.frame = originalPaneFrame
        paneView.shadow = nil
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

    // MARK: - Private — Teardown

    private func teardown() {
        removeEscapeMonitor()
        stopEdgeScroll()

        insertionLine?.removeFromSuperview()
        insertionLine = nil

        // Do NOT unfreeze terminals here — keep ALL panes frozen until
        // endDragWithZoomIn completes the zoom-in animation. Unfreezing
        // early causes terminals to re-render at the wrong backing size.

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
        edgeScrollVelocity = 0

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
