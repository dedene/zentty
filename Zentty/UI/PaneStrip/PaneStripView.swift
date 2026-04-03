import AppKit
import QuartzCore

struct PaneInsertionTransition: Equatable {
    enum Side: Equatable {
        case left
        case right
        case top
        case bottom
    }

    let paneID: PaneID
    let side: Side
    let initialFrame: CGRect
    let columnID: PaneColumnID?
    let sourcePaneID: PaneID?
    let initialAlpha: CGFloat

    init(
        paneID: PaneID,
        side: Side,
        initialFrame: CGRect,
        columnID: PaneColumnID? = nil,
        sourcePaneID: PaneID? = nil,
        initialAlpha: CGFloat = 0
    ) {
        self.paneID = paneID
        self.side = side
        self.initialFrame = initialFrame
        self.columnID = columnID
        self.sourcePaneID = sourcePaneID
        self.initialAlpha = initialAlpha
    }
}

struct PaneRemovalTransition: Equatable {
    let columnID: PaneColumnID
    let survivingPaneIDs: Set<PaneID>
}

@MainActor
final class PaneStripView: NSView {
    var onFocusSettled: ((PaneID) -> Void)?
    var onPaneSelected: ((PaneID) -> Void)?
    var onPaneCloseRequested: ((PaneID) -> Void)?
    var onBorderChromeSnapshotsDidChange: (([PaneBorderChromeSnapshot]) -> Void)?
    var onDividerInteraction: ((PaneDivider) -> Void)?
    var onDividerResizeRequested: ((PaneResizeTarget, CGFloat) -> Void)?
    var onDividerEqualizeRequested: ((PaneDivider) -> Void)?
    var onPaneStripStateRestoreRequested: ((PaneStripState) -> Void)?
    var onPaneReorderRequested: ((PaneID, Int) -> Void)?
    var onPaneSplitDropRequested: ((PaneID, PaneID, PaneSplitPreview.Axis, Bool) -> Void)?
    var onPaneCrossWorklaneDropRequested: ((PaneID, WorklaneID, Bool) -> Void)?
    var sidebarWorklaneFrameProvider: (() -> [(WorklaneID, CGRect)])?
    var onDragApproachingSidebarEdge: ((Bool) -> Void)?
    var onHoveredSidebarWorklaneChanged: ((WorklaneID?) -> Void)?
    var onNewWorklanePlaceholderVisibilityChanged: ((Bool) -> Void)?
    var onSidebarScrollRequested: ((CGFloat) -> Void)?
    var onDragActiveChanged: ((Bool) -> Void)?
    var onLeadingInsetChangedDuringDrag: ((CGFloat) -> Void)?
    var activeWorklaneIDProvider: (() -> WorklaneID?)?
    var sidebarBoundsProvider: (() -> CGRect)?
    var worklaneCountProvider: (() -> Int)?
    var sidebarWidthProvider: (() -> CGFloat)?
    weak var dragOverlayView: NSView? {
        didSet { dragCoordinator.dragHostView = dragOverlayView }
    }
    private(set) var isDragActive = false
    private(set) var isZoomedOut = false
    static let zoomScale: CGFloat = 0.4
    var dragZoomScale: CGFloat { Self.zoomScale }

    private let motionController = PaneStripMotionController()
    private let scrollSwitchHandler = ScrollSwitchGestureHandler()
    private let viewportView = NSView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let backingScaleFactorProvider: () -> CGFloat
    private let dragCoordinator = PaneDragCoordinator()

    private var currentState: PaneStripState?
    private var currentPaneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    private var currentPresentation: StripPresentation?
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var dragZoneViews: [PaneID: PaneDragZoneView] = [:]
    private var dividerViews: [PaneDivider: PaneDividerHandleView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var lastFocusedPaneID: PaneID?
    private(set) var lastInsertionTransition: PaneInsertionTransition?
    private(set) var lastRemovalTransition: PaneRemovalTransition?
    private(set) var lastRenderWasAnimated = false
    private var renderGuard = RenderGuard()
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var resolvedLeadingVisibleInset: CGFloat = 0
    private var hoveredDivider: PaneDivider?
    private var activeDivider: PaneDivider?
    private var dividerDragSession: DividerDragSession?
    private var dividerDragEscapeMonitor: Any?
    private var dividerDragSuspendedPaneIDs: Set<PaneID> = []
    private var pendingTargetOffsetOverride: PendingTargetOffsetOverride?

    private struct DividerDragSession {
        let target: PaneResizeTarget
        let initialState: PaneStripState
        var lastTranslation: CGFloat
    }

    private enum PendingTargetOffsetOverride {
        case usePresentationTargetOffset
    }

    var leadingVisibleInset: CGFloat {
        get { resolvedLeadingVisibleInset }
        set { setLeadingVisibleInset(newValue, animated: false) }
    }

    override var fittingSize: NSSize {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return NSSize(width: width, height: height)
    }

    override init(frame frameRect: NSRect) {
        self.runtimeRegistry = PaneRuntimeRegistry()
        self.backingScaleFactorProvider = { NSScreen.main?.backingScaleFactor ?? 1 }
        super.init(frame: frameRect)
        setup()
    }

    init(
        frame frameRect: NSRect = .zero,
        runtimeRegistry: PaneRuntimeRegistry = PaneRuntimeRegistry(),
        backingScaleFactorProvider: @escaping () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 1 }
    ) {
        self.runtimeRegistry = runtimeRegistry
        self.backingScaleFactorProvider = backingScaleFactorProvider
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private struct RenderGuard {
        private(set) var generation: Int = 0
        private(set) var isResizeSuppressed: Bool = false
        private(set) var renderCount: Int = 0

        mutating func markResizePending() -> Int {
            isResizeSuppressed = true
            generation += 1
            return generation
        }

        mutating func clearResizeSuppression(forGeneration g: Int) {
            guard g == generation else { return }
            isResizeSuppressed = false
        }

        mutating func advanceGeneration() -> Int {
            generation += 1
            renderCount += 1
            return generation
        }

        mutating func resetResizeSuppression() {
            isResizeSuppressed = false
            generation += 1
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        viewportView.wantsLayer = true
        viewportView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportView.layer?.masksToBounds = true
        viewportView.frame = bounds
        viewportView.autoresizingMask = [.width, .height]
        addSubview(viewportView)

        setupDragCoordinator()
    }

    var onPaneNewWorklaneDropRequested: ((PaneID, Bool) -> Void)?

    private func setupDragCoordinator() {
        dragCoordinator.onReorder = { [weak self] paneID, columnIndex in
            self?.onPaneReorderRequested?(paneID, columnIndex)
        }
        dragCoordinator.onSplitDrop = { [weak self] paneID, targetPaneID, axis, leading in
            self?.onPaneSplitDropRequested?(paneID, targetPaneID, axis, leading)
        }
        dragCoordinator.onDragActiveChanged = { [weak self] active in
            guard let self else { return }
            self.isDragActive = active
            if !active {
                if let state = self.currentState {
                    self.renderCurrentState(state, animated: false)
                }
            }
            self.onDragActiveChanged?(active)
        }
        dragCoordinator.onSidebarDrop = { [weak self] paneID, worklaneID, isDuplicate in
            self?.onPaneCrossWorklaneDropRequested?(paneID, worklaneID, isDuplicate)
        }
        dragCoordinator.onSidebarNewWorklaneDrop = { [weak self] paneID, isDuplicate in
            self?.onPaneNewWorklaneDropRequested?(paneID, isDuplicate)
        }
        dragCoordinator.onHoveredSidebarWorklaneChanged = { [weak self] worklaneID in
            self?.onHoveredSidebarWorklaneChanged?(worklaneID)
        }
        dragCoordinator.onDragApproachingSidebarEdge = { [weak self] approaching in
            self?.onDragApproachingSidebarEdge?(approaching)
        }
        dragCoordinator.sidebarWorklaneFrameProvider = { [weak self] in
            self?.sidebarWorklaneFrameProvider?() ?? []
        }
        dragCoordinator.activeWorklaneIDProvider = { [weak self] in
            self?.activeWorklaneIDProvider?()
        }
        dragCoordinator.sidebarBoundsProvider = { [weak self] in
            self?.sidebarBoundsProvider?() ?? .zero
        }
        dragCoordinator.worklaneCountProvider = { [weak self] in
            self?.worklaneCountProvider?() ?? 1
        }
        dragCoordinator.sidebarWidthProvider = { [weak self] in
            self?.sidebarWidthProvider?() ?? 0
        }
        dragCoordinator.onNewWorklanePlaceholderVisibilityChanged = { [weak self] visible in
            self?.onNewWorklanePlaceholderVisibilityChanged?(visible)
        }
        dragCoordinator.onSidebarScrollRequested = { [weak self] delta in
            self?.onSidebarScrollRequested?(delta)
        }
    }

    override func layout() {
        super.layout()
        viewportView.frame = bounds
        if isZoomedOut && !isZoomAnimating {
            if isDragActive {
                // During drag, restore zoom + scroll without recomputing anchor
                applyZoomScale(Self.zoomScale)
            } else {
                // Normal: recompute zoom bounds after frame change (e.g. window resize)
                applyZoom(animated: false)
            }
        }

        guard let currentState, bounds.size != .zero, bounds.size != lastRenderedSize else {
            return
        }

        renderCurrentState(currentState, animated: false)
    }

    func render(
        _ state: PaneStripState,
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        leadingVisibleInset: CGFloat? = nil,
        animated: Bool = true,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        currentPaneBorderContextByPaneID = paneBorderContextByPaneID
        currentState = state
        if let leadingVisibleInset {
            resolvedLeadingVisibleInset = leadingVisibleInset
        }
        guard bounds.size != .zero else {
            return
        }
        if hasViewportSizeChangeSinceLastRender {
            markResizeAnimationSuppressionPending()
        }
        renderCurrentState(
            state,
            animated: animated && !paneViews.isEmpty,
            animationDuration: duration,
            animationTimingFunction: timingFunction
        )
    }

    func transition(
        to state: PaneStripState,
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        leadingVisibleInset: CGFloat,
        animated: Bool,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        currentPaneBorderContextByPaneID = paneBorderContextByPaneID
        currentState = state
        resolvedLeadingVisibleInset = leadingVisibleInset
        renderGuard.resetResizeSuppression()
        guard bounds.size != .zero else {
            return
        }
        if hasViewportSizeChangeSinceLastRender {
            markResizeAnimationSuppressionPending()
        }
        renderCurrentState(
            state,
            animated: animated,
            animationDuration: duration,
            animationTimingFunction: timingFunction
        )
    }

    func focusCurrentPaneIfNeeded() {
        syncFocusedTerminal(with: currentState?.focusedPaneID, force: true)
    }

    func settlePresentationNow() {
        viewportView.layer?.removeAllAnimations()
        paneViews.values.forEach {
            $0.layer?.removeAllAnimations()
            $0.syncInsetBorderNow()
        }
        dividerViews.values.forEach { $0.layer?.removeAllAnimations() }

        guard let currentState, bounds.size != .zero else {
            return
        }

        renderCurrentState(currentState, animated: false)
    }

    func setLeadingVisibleInset(
        _ leadingVisibleInset: CGFloat,
        animated: Bool,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard abs(resolvedLeadingVisibleInset - leadingVisibleInset) > 0.001 else {
            return
        }

        resolvedLeadingVisibleInset = leadingVisibleInset
        lastRenderedSize = .zero
        guard let currentState, bounds.size != .zero else {
            return
        }

        renderCurrentState(
            currentState,
            animated: animated,
            animationDuration: duration,
            animationTimingFunction: timingFunction
        )
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        paneViews.values.forEach { paneView in
            paneView.apply(theme: theme, animated: animated)
        }
    }

    var leadingVisibleInsetForTesting: CGFloat {
        resolvedLeadingVisibleInset
    }

    var renderInvocationCount: Int {
        renderGuard.renderCount
    }

    func centerFocusedInteriorPaneOnNextRender() {
        pendingTargetOffsetOverride = .usePresentationTargetOffset
    }

    func clearPendingTargetOffsetOverride() {
        pendingTargetOffsetOverride = nil
    }

    private func renderCurrentState(
        _ state: PaneStripState,
        animated: Bool,
        animationDuration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        animationTimingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard !isDragActive else { return }
        let settleGeneration = renderGuard.advanceGeneration()
        let previousPresentation = currentPresentation
        let previousOffset = currentOffset
        let targetOffsetOverride = pendingTargetOffsetOverride
        pendingTargetOffsetOverride = nil
        let presentation = motionController.presentation(
            for: state,
            in: bounds.size,
            leadingVisibleInset: resolvedLeadingVisibleInset,
            backingScaleFactor: currentBackingScaleFactor
        )
        let insertionTransition = insertionTransition(
            from: previousPresentation,
            previousOffset: previousOffset,
            to: presentation
        )
        let needsTerminalRedrawAfterRender = terminalDisplaySizeChanged(
            from: previousPresentation,
            to: presentation
        )
        lastInsertionTransition = insertionTransition
        currentPresentation = presentation
        let targetOffset = preferredTargetOffset(
            for: presentation,
            previousOffset: previousOffset,
            targetOffsetOverride: targetOffsetOverride
        )
        let isResizeSuppressedRender = animated
            && sharesAnyPane(with: state, previousPresentation: previousPresentation)
            && (renderGuard.isResizeSuppressed || hasViewportSizeChangeSinceLastRender)
        let shouldAnimate = animated
            && sharesAnyPane(with: state, previousPresentation: previousPresentation)
            && window?.inLiveResize != true
            && !inLiveResize
            && !isResizeSuppressedRender
        lastRenderWasAnimated = shouldAnimate
        let removalTransition = shouldAnimate
            ? removalTransition(from: previousPresentation, to: presentation)
            : nil
        lastRemovalTransition = removalTransition
        var suspendedPaneIDs = suspendedPaneIDs(
            in: presentation,
            insertionTransition: insertionTransition,
            animated: shouldAnimate
        )
        var frozenPaneIDs = frozenPaneIDs(
            for: insertionTransition,
            animated: shouldAnimate
        )
        if let removalTransition {
            frozenPaneIDs.formUnion(removalTransition.survivingPaneIDs)
            suspendedPaneIDs.formUnion(removalTransition.survivingPaneIDs)
        }
        if shouldAnimate, needsTerminalRedrawAfterRender {
            suspendedPaneIDs.formUnion(presentation.panes.map(\.paneID))
        }
        reconcilePaneViews(
            with: state,
            presentation: presentation,
            initialOffset: previousOffset,
            insertionTransition: insertionTransition,
            suspendedPaneIDs: suspendedPaneIDs
        )
        if !isZoomedOut {
            applyTerminalAnimationFreeze(to: frozenPaneIDs, insertionTransition: insertionTransition)
            applyViewportSyncSuspension(to: suspendedPaneIDs)
        }

        let updates = {
            let useNeutralPaneBackground = shouldAnimate && !frozenPaneIDs.isEmpty
            self.applyPresentation(
                presentation,
                state: state,
                offset: targetOffset,
                animated: shouldAnimate,
                useNeutralBackground: useNeutralPaneBackground,
                insertionTransition: insertionTransition,
                allowInactiveDimming: true
            )
            self.reconcileDividerViews(with: presentation, offset: targetOffset)
        }

        if shouldAnimate {
            motionController.animate(
                in: self,
                duration: animationDuration,
                timingFunction: animationTimingFunction,
                updates: updates
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if self.renderGuard.generation == settleGeneration {
                        self.applyPresentation(
                            presentation,
                            state: state,
                            offset: targetOffset,
                            animated: false,
                            useNeutralBackground: false,
                            insertionTransition: insertionTransition,
                            allowInactiveDimming: true
                        )
                        self.reconcileDividerViews(with: presentation, offset: targetOffset)
                        self.paneViews.values.forEach { $0.syncInsetBorderNow() }
                    }

                    if !self.isZoomedOut {
                        self.applyTerminalAnimationFreeze(to: [])
                        self.applyViewportSyncSuspension(to: [])
                    }
                    self.viewportView.layoutSubtreeIfNeeded()
                    if needsTerminalRedrawAfterRender {
                        self.refreshTerminalDisplays()
                        for paneView in self.paneViews.values {
                            paneView.forceTerminalViewportSync()
                        }
                    }
                }
            }
        } else {
            updates()
            if !isZoomedOut {
                applyTerminalAnimationFreeze(to: [])
                applyViewportSyncSuspension(to: [])
            }
            viewportView.layoutSubtreeIfNeeded()
            if needsTerminalRedrawAfterRender {
                refreshTerminalDisplays()
            }
        }

        currentOffset = targetOffset
        lastRenderedSize = bounds.size
        if isResizeSuppressedRender {
            renderGuard.clearResizeSuppression(forGeneration: settleGeneration)
        }
        onBorderChromeSnapshotsDidChange?(borderChromeSnapshots(for: presentation, offset: targetOffset))
        syncFocusedTerminal(with: state.focusedPaneID)
    }

    private func sharesAnyPane(
        with state: PaneStripState,
        previousPresentation: StripPresentation?
    ) -> Bool {
        let nextPaneIDs = Set(state.panes.map(\.id))
        let previousPaneIDs = Set(previousPresentation?.panes.map(\.paneID) ?? [])
        return !nextPaneIDs.isDisjoint(with: previousPaneIDs)
    }

    private func terminalDisplaySizeChanged(
        from previousPresentation: StripPresentation?,
        to presentation: StripPresentation
    ) -> Bool {
        guard let previousPresentation else {
            return false
        }

        let previousSizesByPaneID = Dictionary(
            uniqueKeysWithValues: previousPresentation.panes.map { ($0.paneID, $0.frame.size) }
        )

        for pane in presentation.panes {
            guard let previousSize = previousSizesByPaneID[pane.paneID] else {
                continue
            }

            if abs(previousSize.width - pane.frame.width) > 0.5
                || abs(previousSize.height - pane.frame.height) > 0.5 {
                return true
            }
        }

        return false
    }

    private func refreshTerminalDisplays() {
        for paneView in paneViews.values {
            paneView.needsLayout = true
            paneView.layoutSubtreeIfNeeded()
            refreshDisplayRecursively(in: paneView)
        }

        refreshDisplayRecursively(in: viewportView)
    }

    private func refreshDisplayRecursively(in view: NSView) {
        view.needsDisplay = true
        view.displayIfNeeded()
        view.subviews.forEach { refreshDisplayRecursively(in: $0) }
    }

    private func applyPresentation(
        _ presentation: StripPresentation,
        state: PaneStripState,
        offset: CGFloat,
        animated: Bool,
        useNeutralBackground: Bool,
        insertionTransition: PaneInsertionTransition?,
        allowInactiveDimming: Bool
    ) {
        presentation.panes.enumerated().forEach { index, panePresentation in
            guard let paneView = paneViews[panePresentation.paneID] else {
                return
            }

            let pane = state.panes[index]
            paneView.render(
                pane: pane,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused,
                animated: animated,
                useNeutralBackground: useNeutralBackground
            )
            let targetFrame = panePresentation.frame.offsetBy(
                dx: -resolvedOffset(offset),
                dy: 0
            )
            let targetAlpha = PaneContainerView.presentationAlpha(
                forEmphasis: panePresentation.emphasis,
                allowInactiveDimming: allowInactiveDimming
            )
            if animated {
                if shouldAnimateFrame(
                    for: panePresentation,
                    insertionTransition: insertionTransition
                ) {
                    paneView.animateInsetBorder(to: targetFrame.size)
                    paneView.animator().frame = targetFrame
                } else {
                    paneView.frame = targetFrame
                }

                if shouldAnimateAlpha(
                    for: panePresentation,
                    insertionTransition: insertionTransition,
                    currentAlpha: paneView.alphaValue,
                    targetAlpha: targetAlpha
                ) {
                    paneView.animator().alphaValue = targetAlpha
                } else {
                    paneView.alphaValue = targetAlpha
                }
            } else {
                paneView.frame = targetFrame
                paneView.alphaValue = targetAlpha
            }
        }
    }

    private func reconcilePaneViews(
        with state: PaneStripState,
        presentation: StripPresentation,
        initialOffset: CGFloat,
        insertionTransition: PaneInsertionTransition?,
        suspendedPaneIDs: Set<PaneID>
    ) {
        ZenttyPerformanceSignposts.interval("PaneStripReconcileViews") {
            let nextPaneIDs = Set(presentation.panes.map(\.paneID))
            let obsoletePaneIDs = Set(paneViews.keys).subtracting(nextPaneIDs)

            for paneID in obsoletePaneIDs {
                dragZoneViews[paneID]?.removeFromSuperview()
                dragZoneViews.removeValue(forKey: paneID)
                paneViews[paneID]?.prepareForRemoval()
                paneViews[paneID]?.removeFromSuperview()
                paneViews.removeValue(forKey: paneID)
            }

            presentation.panes.enumerated().forEach { index, panePresentation in
                guard paneViews[panePresentation.paneID] == nil else {
                    return
                }

                let pane = state.panes[index]
                let runtime = runtimeRegistry.runtime(for: pane)
                let paneView = PaneContainerView(
                    pane: pane,
                    width: panePresentation.frame.width,
                    height: panePresentation.frame.height,
                    emphasis: panePresentation.emphasis,
                    isFocused: panePresentation.isFocused,
                    runtime: runtime,
                    theme: currentTheme
                )
                paneView.onSelected = { [weak self] in
                    self?.onPaneSelected?(pane.id)
                }
                paneView.onCloseRequested = { [weak self] in
                    self?.onPaneCloseRequested?(pane.id)
                }
                paneView.onScrollWheel = { [weak self] event in
                    self?.handlePaneSwitchScroll(event) ?? false
                }
                paneView.setTerminalViewportSyncSuspended(suspendedPaneIDs.contains(pane.id))
                if let insertionTransition, insertionTransition.paneID == pane.id {
                    paneView.frame = insertionTransition.initialFrame
                    paneView.alphaValue = insertionTransition.initialAlpha
                } else {
                    paneView.frame = panePresentation.frame.offsetBy(
                        dx: -resolvedOffset(initialOffset),
                        dy: 0
                    )
                    paneView.alphaValue = PaneContainerView.presentationAlpha(forEmphasis: panePresentation.emphasis)
                }
                paneViews[panePresentation.paneID] = paneView
                viewportView.addSubview(paneView)
                paneView.activateSessionIfNeeded()

            let dragZone = PaneDragZoneView(paneID: pane.id)
            let dragZoneHeight = PaneContainerView.dragZoneHeight
            dragZone.frame = CGRect(
                x: 0,
                y: paneView.bounds.height - dragZoneHeight,
                width: paneView.bounds.width,
                height: dragZoneHeight
            )
            dragZone.autoresizingMask = [.width, .minYMargin]
            // Coordinates arrive in WINDOW space (location(in: nil)).
            // Convert from window to PaneStripView — stable regardless of
            // whether the pane was reparented to an overlay during drag.
            dragZone.onDragActivated = { [weak self] paneID, windowPoint in
                guard let self else { return }
                let inStrip = self.convert(windowPoint, from: nil)
                self.handleDragActivated(paneID: paneID, origin: inStrip)
            }
            dragZone.onDragMoved = { [weak self] windowPoint in
                guard let self else { return }
                let inStrip = self.convert(windowPoint, from: nil)
                self.dragCoordinator.updateCursor(inStrip)
            }
            dragZone.onDragEnded = { [weak self] windowPoint in
                guard let self else { return }
                let inStrip = self.convert(windowPoint, from: nil)
                self.dragCoordinator.endDrag(at: inStrip)
            }
            dragZone.onDragCancelled = { [weak self] in
                self?.dragCoordinator.cancelDrag()
            }
            paneView.addSubview(dragZone)
            dragZoneViews[pane.id] = dragZone
            }

            lastFocusedPaneID = lastFocusedPaneID.flatMap { paneViews[$0] == nil ? nil : $0 }
        }
    }

    private func suspendedPaneIDs(
        in presentation: StripPresentation,
        insertionTransition: PaneInsertionTransition?,
        animated: Bool
    ) -> Set<PaneID> {
        guard
            animated,
            let insertionTransition,
            insertionTransition.side == .top || insertionTransition.side == .bottom,
            let columnID = insertionTransition.columnID,
            let column = presentation.columns.first(where: { $0.columnID == columnID })
        else {
            return []
        }

        return Set(column.panes.map(\.paneID))
    }

    private func frozenPaneIDs(
        for insertionTransition: PaneInsertionTransition?,
        animated: Bool
    ) -> Set<PaneID> {
        guard
            animated,
            let insertionTransition,
            insertionTransition.side == .top || insertionTransition.side == .bottom,
            let sourcePaneID = insertionTransition.sourcePaneID
        else {
            return []
        }

        return [sourcePaneID]
    }

    private func applyTerminalAnimationFreeze(
        to frozenPaneIDs: Set<PaneID>,
        insertionTransition: PaneInsertionTransition? = nil
    ) {
        paneViews.forEach { paneID, paneView in
            if frozenPaneIDs.contains(paneID) {
                let gravity: TerminalAnchorView.Gravity
                if let side = insertionTransition?.side {
                    gravity = (side == .bottom) ? .top : .bottom
                } else {
                    gravity = .top
                }
                paneView.beginVerticalFreeze(gravity: gravity)
            } else {
                paneView.endVerticalFreeze()
            }
        }
    }

    private func applyViewportSyncSuspension(to suspendedPaneIDs: Set<PaneID>) {
        paneViews.forEach { paneID, paneView in
            paneView.setTerminalViewportSyncSuspended(
                suspendedPaneIDs.contains(paneID) || dividerDragSuspendedPaneIDs.contains(paneID)
            )
        }
    }

    private func syncFocusedTerminal(with paneID: PaneID?, force: Bool = false) {
        guard let paneID else {
            lastFocusedPaneID = nil
            return
        }

        guard force || paneID != lastFocusedPaneID else {
            return
        }

        lastFocusedPaneID = paneID
        Task { @MainActor [weak self] in
            self?.paneViews[paneID]?.focusTerminal()
        }
    }

    var leadingMaskMinX: CGFloat {
        0
    }

    private func borderChromeSnapshots(
        for presentation: StripPresentation,
        offset: CGFloat
    ) -> [PaneBorderChromeSnapshot] {
        presentation.panes.map { panePresentation in
            PaneBorderChromeSnapshot(
                paneID: panePresentation.paneID,
                frame: panePresentation.frame.offsetBy(dx: -resolvedOffset(offset), dy: 0),
                isFocused: panePresentation.isFocused,
                emphasis: panePresentation.emphasis,
                borderContext: currentPaneBorderContextByPaneID[panePresentation.paneID]
            )
        }
    }

    private func reconcileDividerViews(
        with presentation: StripPresentation,
        offset: CGFloat
    ) {
        let nextDividerIDs = Set(presentation.dividers.map(\.divider))
        let obsoleteDividerIDs = Set(dividerViews.keys).subtracting(nextDividerIDs)

        for divider in obsoleteDividerIDs {
            dividerViews[divider]?.removeFromSuperview()
            dividerViews.removeValue(forKey: divider)
        }
        if let hoveredDivider, !nextDividerIDs.contains(hoveredDivider) {
            self.hoveredDivider = nil
        }
        if let activeDivider, !nextDividerIDs.contains(activeDivider) {
            self.activeDivider = nil
        }

        for dividerPresentation in presentation.dividers {
            let dividerView: PaneDividerHandleView
            if let existingDividerView = dividerViews[dividerPresentation.divider] {
                dividerView = existingDividerView
            } else {
                let createdDividerView = PaneDividerHandleView()
                createdDividerView.onPan = { [weak self, weak createdDividerView] recognizer in
                    guard let self, let createdDividerView else {
                        return
                    }
                    let divider = createdDividerView.divider
                    let location = recognizer.location(in: createdDividerView)
                    self.handleDividerPan(
                        divider,
                        locationInDividerView: location,
                        recognizer: recognizer
                    )
                }
                createdDividerView.onDoubleClick = { [weak self, weak createdDividerView] in
                    guard let self, let divider = createdDividerView?.divider else {
                        return
                    }
                    self.handleDividerDoubleClick(divider)
                }
                createdDividerView.onHoverChanged = { [weak self, weak createdDividerView] isHovered in
                    guard let self, let divider = createdDividerView?.divider else {
                        return
                    }
                    self.handleDividerHover(divider, isHovered: isHovered)
                }
                dividerViews[dividerPresentation.divider] = createdDividerView
                viewportView.addSubview(createdDividerView)
                dividerView = createdDividerView
            }

            let translatedHitFrame = dividerPresentation.hitFrame.offsetBy(
                dx: -resolvedOffset(offset),
                dy: 0
            )
            let translatedDividerFrame = dividerPresentation.frame.offsetBy(
                dx: -resolvedOffset(offset),
                dy: 0
            )
            dividerView.frame = translatedHitFrame
            dividerView.divider = dividerPresentation.divider
            dividerView.render(
                axis: dividerPresentation.axis,
                dividerFrameInSelf: translatedDividerFrame.offsetBy(
                    dx: -translatedHitFrame.minX,
                    dy: -translatedHitFrame.minY
                ),
                highlighted: hoveredDivider == dividerPresentation.divider,
                active: activeDivider == dividerPresentation.divider,
                accessibilityLabel: accessibilityLabel(for: dividerPresentation.divider)
            )
        }

        refreshHoveredDividerFromPointer()
    }

    private func handleDividerHover(_ divider: PaneDivider, isHovered: Bool) {
        if isHovered {
            hoveredDivider = divider
            onDividerInteraction?(divider)
        } else if hoveredDivider == divider {
            hoveredDivider = nil
        }
        updateDividerHighlightStates()
    }

    private func handleDividerPan(
        _ divider: PaneDivider,
        locationInDividerView: CGPoint,
        recognizer: NSPanGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            guard let currentState,
                  beginDividerDragSession(
                    for: divider,
                    locationInDividerView: locationInDividerView,
                    state: currentState,
                    notifyInteraction: true
                  ) != nil else {
                return
            }
        case .changed, .ended:
            guard var dividerDragSession else {
                return
            }
            let translation = recognizer.translation(in: self)
            let resolvedTranslation = resolvedDividerTranslation(
                translation,
                axis: dividerDragSession.target.axis
            )
            let delta = resolvedTranslation - dividerDragSession.lastTranslation
            if abs(delta) > 0.001 {
                onDividerResizeRequested?(dividerDragSession.target, delta)
                dividerDragSession.lastTranslation = resolvedTranslation
                self.dividerDragSession = dividerDragSession
            }
            if recognizer.state == .ended {
                endDividerDrag()
            }
        case .cancelled, .failed:
            cancelDividerDrag()
        default:
            break
        }
    }

    private func handleDividerDoubleClick(_ divider: PaneDivider) {
        onDividerInteraction?(divider)
        activeDivider = divider
        updateDividerHighlightStates()
        onDividerEqualizeRequested?(divider)
        activeDivider = nil
        refreshHoveredDividerFromPointer()
    }

    @discardableResult
    private func beginDividerDragSession(
        for divider: PaneDivider,
        locationInDividerView: CGPoint,
        state: PaneStripState,
        notifyInteraction: Bool
    ) -> PaneResizeTarget? {
        guard let target = resizeTarget(
            for: divider,
            locationInDividerView: locationInDividerView,
            state: state
        ) else {
            return nil
        }

        dividerDragSession = DividerDragSession(
            target: target,
            initialState: state,
            lastTranslation: 0
        )
        activeDivider = resolvedActiveDivider(for: target)
        hoveredDivider = resolvedActiveDivider(for: target)
        if notifyInteraction, let activeDivider {
            onDividerInteraction?(activeDivider)
        }
        beginDividerDrag()
        return target
    }

    private func resizeTarget(
        for divider: PaneDivider,
        locationInDividerView: CGPoint,
        state: PaneStripState
    ) -> PaneResizeTarget? {
        switch divider {
        case .pane:
            return .divider(divider)
        case .column:
            guard let target = state.horizontalResizeTarget(for: divider) else {
                return nil
            }
            return .horizontalEdge(target)
        }
    }

    private func resolvedActiveDivider(for target: PaneResizeTarget) -> PaneDivider {
        switch target {
        case .divider(let divider):
            divider
        case .horizontalEdge(let horizontalTarget):
            horizontalTarget.divider
        }
    }

    // MARK: - Zoom

    func toggleZoom(animated: Bool = true) {
        guard !isDragActive else { return }
        isZoomedOut.toggle()

        if isZoomedOut {
            // Freeze terminals so they don't re-render at the zoomed pixel size
            for (_, paneView) in paneViews {
                paneView.beginVerticalFreeze(gravity: .top)
                paneView.setTerminalViewportSyncSuspended(true)
            }
            applyZoom(animated: animated)
        } else {
            // Zoom back first, then unfreeze after the animation completes
            // so the terminal re-renders at the correct full-size backing
            applyZoom(animated: animated)
            let unfreezeDelay = animated ? 0.35 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + unfreezeDelay) { [weak self] in
                guard let self, !self.isZoomedOut else { return }
                for (_, paneView) in self.paneViews {
                    paneView.endVerticalFreeze()
                    paneView.setTerminalViewportSyncSuspended(false)
                }
                // Force terminals to re-layout at correct backing size
                for (_, paneView) in self.paneViews {
                    paneView.needsLayout = true
                    paneView.layoutSubtreeIfNeeded()
                }
            }
        }
    }

    /// Whether a zoom animation is currently in progress.
    var isZoomAnimating: Bool { zoomAnimationTimer != nil }
    private var zoomAnimationTimer: Timer?
    private var zoomAnimationStart: CFTimeInterval = 0
    private var zoomAnimationFrom: CGFloat = 1
    private var zoomAnimationTo: CGFloat = 1
    private var zoomAnchor: CGPoint = .zero
    private static let zoomAnimationDuration: CFTimeInterval = 0.35

    private func applyZoom(animated: Bool) {
        // Compute the anchor: focused pane center in content space
        let fw = viewportView.frame.width
        let fh = viewportView.frame.height
        if let focusedID = currentState?.focusedPaneID,
           let focusedView = paneViews[focusedID] {
            zoomAnchor = CGPoint(x: focusedView.frame.midX, y: fh / 2)
        } else {
            zoomAnchor = CGPoint(x: fw / 2, y: fh / 2)
        }

        let targetScale = isZoomedOut ? Self.zoomScale : 1.0

        if animated {
            zoomAnimationFrom = currentZoomScale()
            zoomAnimationTo = targetScale
            zoomAnimationFromScrollX = dragScrollOffsetX
            zoomAnimationToScrollX = dragScrollOffsetX
            zoomAnimationStart = CACurrentMediaTime()
            startZoomAnimation()
        } else {
            applyZoomScale(targetScale)
        }
    }

    func currentZoomScale() -> CGFloat {
        let fw = viewportView.frame.width
        guard fw > 0 else { return 1 }
        let bw = viewportView.bounds.width
        guard bw > 0 else { return 1 }
        return fw / bw
    }

    /// Extra horizontal scroll offset applied during drag (in content space).
    var dragScrollOffsetX: CGFloat = 0
    private var zoomAnimationFromScrollX: CGFloat = 0
    private var zoomAnimationToScrollX: CGFloat = 0

    private func composedBounds(scale: CGFloat, scrollX: CGFloat) -> CGRect {
        let fw = viewportView.frame.width
        let fh = viewportView.frame.height
        guard fw > 0, fh > 0 else { return .zero }

        let bw = fw / scale
        let bh = fh / scale
        let ox = zoomAnchor.x * (1 - 1 / scale) + scrollX
        let oy = zoomAnchor.y * (1 - 1 / scale)

        return CGRect(x: ox, y: oy, width: bw, height: bh)
    }

    private func applyZoomScale(_ scale: CGFloat) {
        viewportView.bounds = composedBounds(scale: scale, scrollX: dragScrollOffsetX)
    }

    /// Re-apply the current zoom scale (with dragScrollOffsetX). Used by edge scroll.
    func applyCurrentZoom() {
        applyZoomScale(currentZoomScale())
    }

    private func startZoomAnimation() {
        stopZoomAnimation()

        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.zoomAnimationTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomAnimationTimer = timer
    }

    private func stopZoomAnimation() {
        zoomAnimationTimer?.invalidate()
        zoomAnimationTimer = nil
    }

    private func zoomAnimationTick() {
        let elapsed = CACurrentMediaTime() - zoomAnimationStart
        let duration = Self.zoomAnimationDuration
        let progress = min(1, elapsed / duration)

        // Critically damped spring with initial kick: snappy, no overshoot
        let omega: CGFloat = 10
        let v0: CGFloat = 5
        let raw = 1 + ((v0 - omega) * progress - 1) * exp(-omega * progress)
        let norm = 1 + ((v0 - omega) - 1) * exp(-omega)
        let eased = raw / norm

        let currentScale = zoomAnimationFrom + (zoomAnimationTo - zoomAnimationFrom) * eased
        let currentScrollX = zoomAnimationFromScrollX
            + (zoomAnimationToScrollX - zoomAnimationFromScrollX) * eased
        dragScrollOffsetX = currentScrollX
        applyZoomScale(currentScale)

        if isDragActive {
            dragCoordinator.updateDraggedPanePosition(zoomScale: currentScale)
        }

        if progress >= 1 {
            dragScrollOffsetX = zoomAnimationToScrollX
            applyZoomScale(zoomAnimationTo)
            // Stop animation BEFORE recheckEdgeScroll so isZoomAnimating is false
            // when the edge scroll timer guard checks it.
            stopZoomAnimation()
            if isDragActive {
                dragCoordinator.updateDraggedPanePosition(zoomScale: zoomAnimationTo)
                dragCoordinator.recheckEdgeScroll()
            }
        }
    }

    // MARK: - Pane Drag

    private func handleDragActivated(paneID: PaneID, origin: CGPoint) {
        guard let state = currentState,
              let presentation = currentPresentation else { return }

        // Trigger zoom-out if not already zoomed
        if !isZoomedOut {
            isZoomedOut = true
            // Freeze all non-dragged panes for zoom (dragged pane frozen by coordinator)
            for (id, paneView) in paneViews where id != paneID {
                paneView.setTerminalViewportSyncSuspended(true)
            }
            applyZoom(animated: true)
        }

        dragCoordinator.activateDrag(
            paneID: paneID,
            cursorInStrip: origin,
            paneViews: paneViews,
            viewportView: viewportView,
            paneStripView: self,
            state: state,
            presentation: presentation,
            motionController: motionController,
            backingScaleFactor: currentBackingScaleFactor,
            leadingVisibleInset: resolvedLeadingVisibleInset
        )
    }

    /// Called by PaneDragCoordinator after drop/cancel to trigger zoom-in.
    func endDragWithZoomIn() {
        guard isZoomedOut else { return }
        isZoomedOut = false
        // Animate scroll back to 0 alongside the zoom-in
        let targetScale: CGFloat = 1.0
        zoomAnimationFrom = currentZoomScale()
        zoomAnimationTo = targetScale
        zoomAnimationFromScrollX = dragScrollOffsetX
        zoomAnimationToScrollX = 0
        zoomAnimationStart = CACurrentMediaTime()
        startZoomAnimation()

        let unfreezeDelay: TimeInterval = Self.zoomAnimationDuration + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + unfreezeDelay) { [weak self] in
            guard let self, !self.isZoomedOut else { return }

            // Restore viewport autoresizing (was disabled by the drag coordinator)
            self.viewportView.autoresizingMask = [.width, .height]

            // Unfreeze and unsuspend all terminals
            for (_, paneView) in self.paneViews {
                paneView.endVerticalFreeze()
                paneView.setTerminalViewportSyncSuspended(false)
            }

            // Re-render at correct layout
            if let state = self.currentState {
                self.renderCurrentState(state, animated: false)
            }

            // Force full display invalidation — layout alone doesn't
            // mark layer-backed content dirty after bounds-based zoom.
            for (_, paneView) in self.paneViews {
                paneView.needsLayout = true
                paneView.layoutSubtreeIfNeeded()
                paneView.needsDisplay = true
                paneView.displayIfNeeded()
                // Also invalidate sublayers (terminal host)
                paneView.subviews.forEach { sub in
                    sub.needsDisplay = true
                    sub.subviews.forEach { $0.needsDisplay = true }
                }
            }
            self.viewportView.needsDisplay = true
            self.viewportView.displayIfNeeded()
        }
    }

    /// Apply drag layout with optional gap at an insertion point.
    /// `gapAtReducedIndex` specifies where to open a visual gap (columns shift apart).
    func applyDragLayout(
        _ presentation: StripPresentation,
        excluding paneID: PaneID,
        gapAtReducedIndex: Int? = nil,
        animated: Bool
    ) {
        let offset = presentation.targetOffset
        let gapWidth: CGFloat = 40  // visual gap width in content space
        let updates = {
            for panePresentation in presentation.panes where panePresentation.paneID != paneID {
                guard let paneView = self.paneViews[panePresentation.paneID] else { continue }

                // Shift panes to create a gap at the insertion point
                var dx: CGFloat = -self.resolvedOffset(offset)
                if let gapIdx = gapAtReducedIndex {
                    // Find this pane's column index in the presentation
                    if let colIdx = presentation.columns.firstIndex(where: { $0.columnID == panePresentation.columnID }) {
                        if colIdx >= gapIdx {
                            dx += gapWidth / 2  // shift right
                        } else {
                            dx -= gapWidth / 2  // shift left
                        }
                    }
                }

                let targetFrame = panePresentation.frame.offsetBy(dx: dx, dy: 0)
                paneView.frame = targetFrame
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                updates()
                self.viewportView.layoutSubtreeIfNeeded()
            }
        } else {
            updates()
        }
    }

    // MARK: - Divider Drag

    private func beginDividerDrag() {
        dividerDragSuspendedPaneIDs = Set(currentState?.panes.map(\.id) ?? [])
        applyViewportSyncSuspension(to: [])
        installDividerDragEscapeMonitorIfNeeded()
        updateDividerHighlightStates()
    }

    private func endDividerDrag() {
        dividerDragSession = nil
        dividerDragSuspendedPaneIDs = []
        removeDividerDragEscapeMonitor()
        activeDivider = nil
        applyViewportSyncSuspension(to: [])
        refreshHoveredDividerFromPointer()
    }

    private func cancelDividerDrag() {
        if let dividerDragSession {
            onPaneStripStateRestoreRequested?(dividerDragSession.initialState)
        }
        endDividerDrag()
    }

    private func installDividerDragEscapeMonitorIfNeeded() {
        guard dividerDragEscapeMonitor == nil else {
            return
        }

        dividerDragEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.dividerDragSession != nil else {
                return event
            }

            guard event.keyCode == 53 else {
                return event
            }

            self.cancelDividerDrag()
            return nil
        }
    }

    private func removeDividerDragEscapeMonitor() {
        guard let dividerDragEscapeMonitor else {
            return
        }

        NSEvent.removeMonitor(dividerDragEscapeMonitor)
        self.dividerDragEscapeMonitor = nil
    }

    private func resolvedDividerTranslation(
        _ translation: CGPoint,
        axis: PaneResizeAxis
    ) -> CGFloat {
        switch axis {
        case .horizontal:
            translation.x
        case .vertical:
            -translation.y
        }
    }

    private func refreshHoveredDividerFromPointer() {
        guard let window else {
            hoveredDivider = nil
            updateDividerHighlightStates()
            return
        }

        let locationInViewport = viewportView.convert(
            window.mouseLocationOutsideOfEventStream,
            from: nil
        )

        let resolvedHoveredDivider: PaneDivider?
        if let hoveredDivider,
           let hoveredView = dividerViews[hoveredDivider],
           hoveredView.frame.contains(locationInViewport) {
            resolvedHoveredDivider = hoveredDivider
        } else {
            resolvedHoveredDivider = dividerViews.first { _, dividerView in
                dividerView.frame.contains(locationInViewport)
            }?.key
        }

        hoveredDivider = resolvedHoveredDivider
        updateDividerHighlightStates()
    }

    #if DEBUG
    func dividerTranslationForTesting(
        _ translation: CGPoint,
        axis: PaneResizeAxis
    ) -> CGFloat {
        resolvedDividerTranslation(translation, axis: axis)
    }

    func dividerCursorDescriptionForTesting(_ divider: PaneDivider) -> String? {
        dividerViews[divider]?.cursorDescriptionForTesting
    }

    func dividerHighlightStateForTesting(_ divider: PaneDivider) -> (highlighted: Bool, active: Bool)? {
        guard dividerViews[divider] != nil else {
            return nil
        }

        return (
            highlighted: hoveredDivider == divider,
            active: activeDivider == divider
        )
    }

    func simulateDividerDoubleClickForTesting(_ divider: PaneDivider) {
        handleDividerDoubleClick(divider)
    }

    func beginDividerDragForTesting(
        _ divider: PaneDivider,
        locationInDividerView: CGPoint
    ) -> PaneResizeTarget? {
        guard let currentState else {
            return nil
        }

        return beginDividerDragSession(
            for: divider,
            locationInDividerView: locationInDividerView,
            state: currentState,
            notifyInteraction: false
        )
    }

    func endDividerDragForTesting() {
        endDividerDrag()
    }
    #endif

    private func updateDividerHighlightStates() {
        for (divider, dividerView) in dividerViews {
            dividerView.updateHighlightState(
                highlighted: hoveredDivider == divider,
                active: activeDivider == divider
            )
        }
    }

    private func accessibilityLabel(for divider: PaneDivider) -> String {
        switch divider {
        case .column:
            "Resize pane width from this split"
        case .pane:
            "Resize adjacent stacked panes"
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if handlePaneSwitchScroll(event) {
            return
        }

        super.scrollWheel(with: event)
    }

    private func handlePaneSwitchScroll(_ event: NSEvent) -> Bool {
        let result = scrollSwitchHandler.handle(scrollEvent: event)
        switch result {
        case .switchLeft, .switchRight:
            settleAdjacentPane(switchRight: result == .switchRight)
            return true
        case .consumed:
            return true
        case .none:
            return false
        }
    }

    private func settleAdjacentPane(switchRight: Bool) {
        guard
            let currentState,
            let focusedPaneID = currentState.focusedPaneID,
            let focusedIndex = currentState.columns.firstIndex(where: {
                $0.panes.contains(where: { $0.id == focusedPaneID })
            })
        else {
            return
        }

        let step = switchRight ? 1 : -1
        let targetIndex = focusedIndex + step
        guard currentState.columns.indices.contains(targetIndex) else {
            return
        }

        let targetColumn = currentState.columns[targetIndex]
        onFocusSettled?(targetColumn.focusedPaneID ?? targetColumn.panes.first?.id ?? focusedPaneID)
    }

    private var currentBackingScaleFactor: CGFloat {
        max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? backingScaleFactorProvider())
    }

    private var hasViewportSizeChangeSinceLastRender: Bool {
        lastRenderedSize != .zero && bounds.size != lastRenderedSize
    }

    private func markResizeAnimationSuppressionPending() {
        let generation = renderGuard.markResizePending()
        DispatchQueue.main.async { [weak self] in
            self?.renderGuard.clearResizeSuppression(forGeneration: generation)
        }
    }

    /// Exposed for PaneDragCoordinator to align insertion line with drag layout.
    func resolvedDragOffset(_ offset: CGFloat) -> CGFloat {
        resolvedOffset(offset)
    }

    private func resolvedOffset(_ offset: CGFloat) -> CGFloat {
        motionController.snappedOffset(
            offset,
            backingScaleFactor: currentBackingScaleFactor
        )
    }

    private func preferredTargetOffset(
        for presentation: StripPresentation,
        previousOffset: CGFloat,
        targetOffsetOverride: PendingTargetOffsetOverride? = nil
    ) -> CGFloat {
        if targetOffsetOverride == .usePresentationTargetOffset {
            let clampedTargetOffset = motionController.clampedOffset(
                presentation.targetOffset,
                contentWidth: presentation.contentWidth,
                viewportWidth: bounds.width,
                leadingVisibleInset: resolvedLeadingVisibleInset
            )

            return motionController.snappedOffset(
                clampedTargetOffset,
                backingScaleFactor: currentBackingScaleFactor
            )
        }

        let visibleBorderInset = ChromeGeometry.paneBorderInset(
            backingScaleFactor: currentBackingScaleFactor
        )
        let visibleLaneMinX = resolvedLeadingVisibleInset + visibleBorderInset
        let visibleLaneMaxX = bounds.width - visibleBorderInset
        let clampedPreviousOffset = motionController.clampedOffset(
            previousOffset,
            contentWidth: presentation.contentWidth,
            viewportWidth: bounds.width,
            leadingVisibleInset: resolvedLeadingVisibleInset
        )
        let snappedPreviousOffset = motionController.snappedOffset(
            clampedPreviousOffset,
            backingScaleFactor: currentBackingScaleFactor
        )

        guard let focusedPane = presentation.focusedPane else {
            return motionController.snappedOffset(
                presentation.targetOffset,
                backingScaleFactor: currentBackingScaleFactor
            )
        }

        let visibleFocusedMinX = focusedPane.frame.minX + visibleBorderInset - snappedPreviousOffset
        let visibleFocusedMaxX = focusedPane.frame.maxX - visibleBorderInset - snappedPreviousOffset
        if visibleFocusedMinX >= visibleLaneMinX - 0.001,
           visibleFocusedMaxX <= visibleLaneMaxX + 0.001 {
            return snappedPreviousOffset
        }

        var proposedOffset = snappedPreviousOffset
        if visibleFocusedMinX < visibleLaneMinX {
            proposedOffset += visibleFocusedMinX - visibleLaneMinX
        } else if visibleFocusedMaxX > visibleLaneMaxX {
            proposedOffset += visibleFocusedMaxX - visibleLaneMaxX
        }

        let clampedProposedOffset = motionController.clampedOffset(
            proposedOffset,
            contentWidth: presentation.contentWidth,
            viewportWidth: bounds.width,
            leadingVisibleInset: resolvedLeadingVisibleInset
        )

        return motionController.snappedOffset(
            clampedProposedOffset,
            backingScaleFactor: currentBackingScaleFactor
        )
    }

    private func shouldAnimateFrame(
        for panePresentation: PanePresentation,
        insertionTransition: PaneInsertionTransition?
    ) -> Bool {
        guard
            let insertionTransition,
            let columnID = insertionTransition.columnID,
            panePresentation.columnID == columnID,
            let sourcePaneID = insertionTransition.sourcePaneID
        else {
            return true
        }

        return panePresentation.paneID == insertionTransition.paneID
            || panePresentation.paneID == sourcePaneID
    }

    private func shouldAnimateAlpha(
        for panePresentation: PanePresentation,
        insertionTransition: PaneInsertionTransition?,
        currentAlpha: CGFloat,
        targetAlpha: CGFloat
    ) -> Bool {
        insertionTransition?.paneID == panePresentation.paneID
            || abs(currentAlpha - targetAlpha) > 0.001
    }
}

private final class PaneDividerHandleView: NSView {
    override var frame: NSRect {
        didSet {
            guard oldValue != frame else {
                return
            }

            invalidatePointerAffordances()
        }
    }

    var divider: PaneDivider = .column(afterColumnID: PaneColumnID("divider")) {
        didSet {
            invalidatePointerAffordances()
        }
    }

    var onPan: ((NSPanGestureRecognizer) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let highlightLayer = CALayer()
    private var trackingAreaValue: NSTrackingArea?
    private var axis: PaneResizeAxis = .horizontal
    private var accessibilityLabelText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        highlightLayer.backgroundColor = NSColor.clear.cgColor
        highlightLayer.cornerRadius = 1
        layer?.addSublayer(highlightLayer)
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaValue {
            removeTrackingArea(trackingAreaValue)
        }
        let trackingAreaValue = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaValue)
        self.trackingAreaValue = trackingAreaValue
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidatePointerAffordances()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        resolvedCursor.set()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }

        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resolvedCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        resolvedCursor.set()
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityLabel() -> String? {
        accessibilityLabelText
    }

    func render(
        axis: PaneResizeAxis,
        dividerFrameInSelf: CGRect,
        highlighted: Bool,
        active: Bool,
        accessibilityLabel: String
    ) {
        let didChangeAxis = self.axis != axis
        self.axis = axis
        accessibilityLabelText = accessibilityLabel
        toolTip = accessibilityLabel
        highlightLayer.frame = dividerFrameInSelf
        if didChangeAxis {
            invalidatePointerAffordances()
        }
        updateHighlightState(highlighted: highlighted, active: active)
    }

    func updateHighlightState(highlighted: Bool, active: Bool) {
        let alpha: CGFloat
        if active {
            alpha = 0.5
        } else if highlighted {
            alpha = 0.28
        } else {
            alpha = 0
        }
        highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        onPan?(recognizer)
    }

    private var resolvedCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    private func invalidatePointerAffordances() {
        updateTrackingAreas()
        discardCursorRects()
        window?.invalidateCursorRects(for: self)

        guard let window else {
            return
        }

        let locationInSelf = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(locationInSelf) {
            resolvedCursor.set()
        }
    }

    #if DEBUG
    var cursorDescriptionForTesting: String {
        axis == .horizontal ? "resizeLeftRight" : "resizeUpDown"
    }
    #endif
}
