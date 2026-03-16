import AppKit

struct PaneInsertionTransition: Equatable {
    enum Side: Equatable {
        case left
        case right
    }

    let paneID: PaneID
    let side: Side
    let initialFrame: CGRect
}

final class PaneStripView: NSView {
    private enum ScrollSwitchAxis {
        case horizontal
        case shiftedVertical
    }

    private enum ScrollSwitchThreshold {
        static let precise: CGFloat = 40
        static let wheel: CGFloat = 1
    }

    var onFocusSettled: ((PaneID) -> Void)?
    var onPaneSelected: ((PaneID) -> Void)?
    var onPaneCloseRequested: ((PaneID) -> Void)?

    private let motionController = PaneStripMotionController()
    private let viewportView = NSView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let backingScaleFactorProvider: () -> CGFloat

    private var currentState: PaneStripState?
    private var currentPresentation: StripPresentation?
    private var orderedPaneIDs: [PaneID] = []
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var lastFocusedPaneID: PaneID?
    private var lastInsertionTransition: PaneInsertionTransition?
    private var lastRenderWasAnimated = false
    private var suppressAnimatedRenderForResize = false
    private var resizeSuppressionGeneration = 0
    private var activeScrollSwitchAxis: ScrollSwitchAxis?
    private var accumulatedScrollSwitchDelta: CGFloat = 0
    private var hasTriggeredScrollSwitchInGesture = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    var leadingVisibleInset: CGFloat = 0 {
        didSet {
            guard abs(oldValue - leadingVisibleInset) > 0.001 else {
                return
            }

            lastRenderedSize = .zero
            if let currentState, bounds.size != .zero {
                renderCurrentState(currentState, animated: false)
            }
        }
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
    }

    override func layout() {
        super.layout()
        viewportView.frame = bounds

        guard let currentState, bounds.size != .zero, bounds.size != lastRenderedSize else {
            return
        }

        markResizeAnimationSuppressionPending()
        renderCurrentState(currentState, animated: false)
    }

    func render(_ state: PaneStripState) {
        currentState = state
        guard bounds.size != .zero else {
            return
        }
        if hasViewportSizeChangeSinceLastRender {
            markResizeAnimationSuppressionPending()
        }
        renderCurrentState(state, animated: !orderedPaneIDs.isEmpty)
    }

    func focusCurrentPaneIfNeeded() {
        syncFocusedTerminal(with: currentState?.focusedPaneID, force: true)
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

    var lastInsertionTransitionForTesting: PaneInsertionTransition? {
        lastInsertionTransition
    }

    var lastRenderWasAnimatedForTesting: Bool {
        lastRenderWasAnimated
    }

    private func renderCurrentState(_ state: PaneStripState, animated: Bool) {
        let previousPresentation = currentPresentation
        let previousOffset = currentOffset
        let presentation = motionController.presentation(
            for: state,
            in: bounds.size,
            leadingVisibleInset: leadingVisibleInset,
            backingScaleFactor: currentBackingScaleFactor
        )
        let insertionTransition = insertionTransition(
            from: previousPresentation,
            previousOffset: previousOffset,
            to: presentation
        )
        lastInsertionTransition = insertionTransition
        currentPresentation = presentation
        let targetOffset = motionController.snappedOffset(
            presentation.targetOffset,
            backingScaleFactor: currentBackingScaleFactor
        )
        let isResizeSuppressedRender = animated
            && sharesAnyPane(with: state)
            && (suppressAnimatedRenderForResize || hasViewportSizeChangeSinceLastRender)
        let shouldAnimate = animated
            && sharesAnyPane(with: state)
            && window?.inLiveResize != true
            && !inLiveResize
            && !isResizeSuppressedRender
        lastRenderWasAnimated = shouldAnimate
        reconcilePaneViews(
            with: state,
            presentation: presentation,
            initialOffset: previousOffset,
            insertionTransition: insertionTransition
        )
        orderedPaneIDs = presentation.panes.map(\.paneID)

        let updates = {
            self.applyPresentation(
                presentation,
                state: state,
                offset: targetOffset,
                animated: shouldAnimate
            )
        }

        if shouldAnimate {
            motionController.animate(in: self, updates: updates)
        } else {
            updates()
            viewportView.layoutSubtreeIfNeeded()
        }

        currentOffset = targetOffset
        lastRenderedSize = bounds.size
        if isResizeSuppressedRender {
            suppressAnimatedRenderForResize = false
        }
        syncFocusedTerminal(with: state.focusedPaneID)
    }

    private func sharesAnyPane(with state: PaneStripState) -> Bool {
        let nextPaneIDs = Set(state.panes.map(\.id))
        return !nextPaneIDs.isDisjoint(with: orderedPaneIDs)
    }

    private func applyPresentation(
        _ presentation: StripPresentation,
        state: PaneStripState,
        offset: CGFloat,
        animated: Bool
    ) {
        presentation.panes.enumerated().forEach { index, panePresentation in
            guard let paneView = paneViews[panePresentation.paneID] else {
                return
            }

            let pane = state.panes[index]
            paneView.render(
                pane: pane,
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused
            )
            let targetFrame = panePresentation.frame.offsetBy(
                dx: -resolvedOffset(offset),
                dy: 0
            )
            if animated {
                paneView.animator().frame = targetFrame
            } else {
                paneView.frame = targetFrame
            }
        }
    }

    private func reconcilePaneViews(
        with state: PaneStripState,
        presentation: StripPresentation,
        initialOffset: CGFloat,
        insertionTransition: PaneInsertionTransition?
    ) {
        let nextPaneIDs = Set(presentation.panes.map(\.paneID))
        let obsoletePaneIDs = Set(paneViews.keys).subtracting(nextPaneIDs)

        for paneID in obsoletePaneIDs {
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
            if let insertionTransition, insertionTransition.paneID == pane.id {
                paneView.frame = insertionTransition.initialFrame
                paneView.alphaValue = 0
            } else {
                paneView.frame = panePresentation.frame.offsetBy(
                    dx: -resolvedOffset(initialOffset),
                    dy: 0
                )
            }
            paneViews[panePresentation.paneID] = paneView
            viewportView.addSubview(paneView)
            paneView.activateSessionIfNeeded()
        }

        lastFocusedPaneID = lastFocusedPaneID.flatMap { paneViews[$0] == nil ? nil : $0 }
    }

    private func insertionTransition(
        from previousPresentation: StripPresentation?,
        previousOffset: CGFloat,
        to nextPresentation: StripPresentation
    ) -> PaneInsertionTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)

        guard insertedPaneIDs.count == 1, removedPaneIDs.isEmpty else {
            return nil
        }

        guard
            let insertedPaneID = insertedPaneIDs.first,
            let insertedIndex = nextPresentation.panes.firstIndex(where: { $0.paneID == insertedPaneID }),
            let insertedPane = nextPresentation.panes.first(where: { $0.paneID == insertedPaneID })
        else {
            return nil
        }

        let spacing = nextPresentation.panes.count > 1
            ? nextPresentation.panes[1].frame.minX - nextPresentation.panes[0].frame.maxX
            : 16

        let previousFramesByPaneID = Dictionary(uniqueKeysWithValues: previousPresentation.panes.map { ($0.paneID, $0.frame) })

        if insertedIndex > 0 {
            let leftNeighborID = nextPresentation.panes[insertedIndex - 1].paneID
            let anchorFrame = previousFramesByPaneID[leftNeighborID] ?? insertedPane.frame
            let initialContentFrame = CGRect(
                x: anchorFrame.maxX + spacing,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .right,
                initialFrame: initialContentFrame.offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        if insertedIndex < nextPresentation.panes.count - 1 {
            let rightNeighborID = nextPresentation.panes[insertedIndex + 1].paneID
            let anchorFrame = previousFramesByPaneID[rightNeighborID] ?? insertedPane.frame
            let initialContentFrame = CGRect(
                x: anchorFrame.minX - spacing - insertedPane.frame.width,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .left,
                initialFrame: initialContentFrame.offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        return nil
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
        DispatchQueue.main.async { [weak self] in
            self?.paneViews[paneID]?.focusTerminal()
        }
    }

    var leadingMaskMinXForTesting: CGFloat {
        0
    }

    override func scrollWheel(with event: NSEvent) {
        if handlePaneSwitchScroll(event) {
            return
        }

        super.scrollWheel(with: event)
    }

    private func handlePaneSwitchScroll(_ event: NSEvent) -> Bool {
        if shouldResetScrollSwitchGesture(for: event) {
            resetScrollSwitchGesture()
        }

        guard let axis = scrollSwitchAxis(for: event) else {
            if shouldResetScrollSwitchGesture(for: event) {
                resetScrollSwitchGesture()
            }
            return false
        }

        if activeScrollSwitchAxis == nil || !eventHasGesturePhases(event) {
            activeScrollSwitchAxis = axis
            accumulatedScrollSwitchDelta = 0
            hasTriggeredScrollSwitchInGesture = false
        }

        guard activeScrollSwitchAxis == axis else {
            return true
        }

        if hasTriggeredScrollSwitchInGesture {
            if shouldEndScrollSwitchGesture(for: event) {
                resetScrollSwitchGesture()
            }
            return true
        }

        accumulatedScrollSwitchDelta += scrollSwitchDelta(for: event, axis: axis)
        let threshold = event.hasPreciseScrollingDeltas
            ? ScrollSwitchThreshold.precise
            : ScrollSwitchThreshold.wheel

        if abs(accumulatedScrollSwitchDelta) >= threshold {
            hasTriggeredScrollSwitchInGesture = true
            settleAdjacentPane(for: accumulatedScrollSwitchDelta)
        }

        if shouldEndScrollSwitchGesture(for: event) || !eventHasGesturePhases(event) {
            resetScrollSwitchGesture()
        }

        return true
    }

    private func settleAdjacentPane(for accumulatedDelta: CGFloat) {
        guard
            let currentState,
            let focusedPaneID = currentState.focusedPaneID,
            let focusedIndex = orderedPaneIDs.firstIndex(of: focusedPaneID)
        else {
            return
        }

        let step = accumulatedDelta > 0 ? -1 : 1
        let targetIndex = focusedIndex + step
        guard orderedPaneIDs.indices.contains(targetIndex) else {
            return
        }

        onFocusSettled?(orderedPaneIDs[targetIndex])
    }

    private func scrollSwitchAxis(for event: NSEvent) -> ScrollSwitchAxis? {
        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)

        if horizontalDelta > verticalDelta, horizontalDelta > 0 {
            return .horizontal
        }

        let deviceIndependentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !event.hasPreciseScrollingDeltas,
           deviceIndependentFlags.contains(.shift),
           verticalDelta > 0,
           verticalDelta >= horizontalDelta {
            return .shiftedVertical
        }

        return nil
    }

    private func scrollSwitchDelta(for event: NSEvent, axis: ScrollSwitchAxis) -> CGFloat {
        let inversionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        switch axis {
        case .horizontal:
            return event.scrollingDeltaX * inversionMultiplier
        case .shiftedVertical:
            return event.scrollingDeltaY * inversionMultiplier
        }
    }

    private func eventHasGesturePhases(_ event: NSEvent) -> Bool {
        event.phase != [] || event.momentumPhase != []
    }

    private func shouldResetScrollSwitchGesture(for event: NSEvent) -> Bool {
        event.phase.contains(.began) || event.phase.contains(.mayBegin)
    }

    private func shouldEndScrollSwitchGesture(for event: NSEvent) -> Bool {
        event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
    }

    private func resetScrollSwitchGesture() {
        activeScrollSwitchAxis = nil
        accumulatedScrollSwitchDelta = 0
        hasTriggeredScrollSwitchInGesture = false
    }

    private var currentBackingScaleFactor: CGFloat {
        max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? backingScaleFactorProvider())
    }

    private var hasViewportSizeChangeSinceLastRender: Bool {
        lastRenderedSize != .zero && bounds.size != lastRenderedSize
    }

    private func markResizeAnimationSuppressionPending() {
        suppressAnimatedRenderForResize = true
        resizeSuppressionGeneration += 1
        let generation = resizeSuppressionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.resizeSuppressionGeneration == generation else {
                return
            }
            self.suppressAnimatedRenderForResize = false
        }
    }

    private func resolvedOffset(_ offset: CGFloat) -> CGFloat {
        motionController.snappedOffset(
            offset,
            backingScaleFactor: currentBackingScaleFactor
        )
    }
}
