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
    var onBorderChromeSnapshotsDidChange: (([PaneBorderChromeSnapshot]) -> Void)?

    private let motionController = PaneStripMotionController()
    private let viewportView = NSView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let backingScaleFactorProvider: () -> CGFloat

    private var currentState: PaneStripState?
    private var currentPaneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    private var currentPresentation: StripPresentation?
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var lastFocusedPaneID: PaneID?
    private var lastInsertionTransition: PaneInsertionTransition?
    private var lastRemovalTransition: PaneRemovalTransition?
    private var lastRenderWasAnimated = false
    private var suppressAnimatedRenderForResize = false
    private var resizeSuppressionGeneration = 0
    private var visualStateSettleGeneration = 0
    private var activeScrollSwitchAxis: ScrollSwitchAxis?
    private var accumulatedScrollSwitchDelta: CGFloat = 0
    private var hasTriggeredScrollSwitchInGesture = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var resolvedLeadingVisibleInset: CGFloat = 0
    private var renderInvocationCount = 0

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

    func render(
        _ state: PaneStripState,
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    ) {
        currentPaneBorderContextByPaneID = paneBorderContextByPaneID
        currentState = state
        guard bounds.size != .zero else {
            return
        }
        if hasViewportSizeChangeSinceLastRender {
            markResizeAnimationSuppressionPending()
        }
        renderCurrentState(state, animated: !paneViews.isEmpty)
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
        suppressAnimatedRenderForResize = false
        resizeSuppressionGeneration += 1
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

    var lastInsertionTransitionForTesting: PaneInsertionTransition? {
        lastInsertionTransition
    }

    var lastRemovalTransitionForTesting: PaneRemovalTransition? {
        lastRemovalTransition
    }

    var lastRenderWasAnimatedForTesting: Bool {
        lastRenderWasAnimated
    }

    var renderInvocationCountForTesting: Int {
        renderInvocationCount
    }

    var leadingVisibleInsetForTesting: CGFloat {
        resolvedLeadingVisibleInset
    }

    private func renderCurrentState(
        _ state: PaneStripState,
        animated: Bool,
        animationDuration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        animationTimingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        visualStateSettleGeneration += 1
        let settleGeneration = visualStateSettleGeneration
        renderInvocationCount += 1
        let previousPresentation = currentPresentation
        let previousOffset = currentOffset
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
        lastInsertionTransition = insertionTransition
        currentPresentation = presentation
        let targetOffset = motionController.snappedOffset(
            presentation.targetOffset,
            backingScaleFactor: currentBackingScaleFactor
        )
        let isResizeSuppressedRender = animated
            && sharesAnyPane(with: state, previousPresentation: previousPresentation)
            && (suppressAnimatedRenderForResize || hasViewportSizeChangeSinceLastRender)
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
        reconcilePaneViews(
            with: state,
            presentation: presentation,
            initialOffset: previousOffset,
            insertionTransition: insertionTransition,
            suspendedPaneIDs: suspendedPaneIDs
        )
        applyTerminalAnimationFreeze(to: frozenPaneIDs)
        applyViewportSyncSuspension(to: suspendedPaneIDs)

        let updates = {
            self.applyPresentation(
                presentation,
                state: state,
                offset: targetOffset,
                animated: shouldAnimate,
                insertionTransition: insertionTransition,
                allowInactiveDimming: !shouldAnimate
            )
        }

        if shouldAnimate {
            motionController.animate(
                in: self,
                duration: animationDuration,
                timingFunction: animationTimingFunction,
                updates: updates
            ) { [weak self] in
                guard let self, self.visualStateSettleGeneration == settleGeneration else {
                    return
                }

                self.applyPresentation(
                    presentation,
                    state: state,
                    offset: targetOffset,
                    animated: false,
                    insertionTransition: insertionTransition,
                    allowInactiveDimming: true
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.visualStateSettleGeneration == settleGeneration else {
                        return
                    }
                    self.applyTerminalAnimationFreeze(to: [])
                    self.viewportView.layoutSubtreeIfNeeded()
                    self.applyViewportSyncSuspension(to: [])
                }
            }
        } else {
            updates()
            applyTerminalAnimationFreeze(to: [])
            viewportView.layoutSubtreeIfNeeded()
            applyViewportSyncSuspension(to: [])
        }

        currentOffset = targetOffset
        lastRenderedSize = bounds.size
        if isResizeSuppressedRender {
            suppressAnimatedRenderForResize = false
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

    private func applyPresentation(
        _ presentation: StripPresentation,
        state: PaneStripState,
        offset: CGFloat,
        animated: Bool,
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
                isFocused: panePresentation.isFocused
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
                    paneView.animator().frame = targetFrame
                    paneView.animateFrozenTerminalFrame(for: targetFrame.size)
                } else {
                    paneView.frame = targetFrame
                }

                if shouldAnimateAlpha(
                    for: panePresentation,
                    insertionTransition: insertionTransition
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
        }

        lastFocusedPaneID = lastFocusedPaneID.flatMap { paneViews[$0] == nil ? nil : $0 }
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

    private func applyTerminalAnimationFreeze(to frozenPaneIDs: Set<PaneID>) {
        paneViews.forEach { paneID, paneView in
            paneView.setTerminalAnimationFrozen(frozenPaneIDs.contains(paneID))
        }
    }

    private func applyViewportSyncSuspension(to suspendedPaneIDs: Set<PaneID>) {
        paneViews.forEach { paneID, paneView in
            paneView.setTerminalViewportSyncSuspended(suspendedPaneIDs.contains(paneID))
        }
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
            let insertedPane = nextPresentation.panes.first(where: { $0.paneID == insertedPaneID }),
            let insertedColumnIndex = nextPresentation.columns.firstIndex(where: {
                $0.panes.contains(where: { $0.paneID == insertedPaneID })
            })
        else {
            return nil
        }

        let nextColumn = nextPresentation.columns[insertedColumnIndex]
        let previousColumnsByID = Dictionary(uniqueKeysWithValues: previousPresentation.columns.map { ($0.columnID, $0) })

        if let previousColumn = previousColumnsByID[nextColumn.columnID] {
            let spacing = nextColumn.panes.count > 1
                ? nextColumn.panes[0].frame.minY - nextColumn.panes[1].frame.maxY
                : 16
            guard let insertedIndex = nextColumn.panes.firstIndex(where: { $0.paneID == insertedPaneID }) else {
                return nil
            }

            if insertedIndex > 0 {
                let anchorPane = nextColumn.panes[insertedIndex - 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                let initialHeight = min(insertedPane.frame.height, 96)
                let initialFrame = CGRect(
                    x: insertedPane.frame.minX,
                    y: (previousAnchorPane?.frame.minY ?? anchorPane.frame.minY) - initialHeight,
                    width: insertedPane.frame.width,
                    height: initialHeight
                )
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .bottom,
                    initialFrame: initialFrame.offsetBy(dx: -previousOffset, dy: 0),
                    columnID: nextColumn.columnID,
                    sourcePaneID: anchorPane.paneID
                )
            }

            if insertedIndex < nextColumn.panes.count - 1 {
                let anchorPane = nextColumn.panes[insertedIndex + 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .top,
                    initialFrame: CGRect(
                        x: insertedPane.frame.minX,
                        y: (previousAnchorPane?.frame.maxY ?? anchorPane.frame.maxY) + spacing,
                        width: insertedPane.frame.width,
                        height: insertedPane.frame.height
                    ).offsetBy(dx: -previousOffset, dy: 0),
                    columnID: nextColumn.columnID,
                    sourcePaneID: anchorPane.paneID
                )
            }

            return nil
        }

        let spacing = nextPresentation.columns.count > 1
            ? nextPresentation.columns[1].frame.minX - nextPresentation.columns[0].frame.maxX
            : 16

        if insertedColumnIndex > 0 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex - 1]
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .right,
                initialFrame: CGRect(
                    x: anchorColumn.frame.maxX + spacing,
                    y: insertedPane.frame.minY,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                ).offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        if insertedColumnIndex < nextPresentation.columns.count - 1 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex + 1]
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .left,
                initialFrame: CGRect(
                    x: anchorColumn.frame.minX - spacing - insertedPane.frame.width,
                    y: insertedPane.frame.minY,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                ).offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        return nil
    }

    private func removalTransition(
        from previousPresentation: StripPresentation?,
        to nextPresentation: StripPresentation
    ) -> PaneRemovalTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)

        guard !removedPaneIDs.isEmpty, insertedPaneIDs.isEmpty else {
            return nil
        }

        for previousColumn in previousPresentation.columns {
            guard previousColumn.panes.count > 1 else {
                continue
            }
            guard let nextColumn = nextPresentation.columns.first(where: {
                $0.columnID == previousColumn.columnID
            }) else {
                continue
            }
            let columnRemovedIDs = removedPaneIDs.intersection(
                Set(previousColumn.panes.map(\.paneID))
            )
            guard columnRemovedIDs.count == 1 else {
                continue
            }

            let survivingPaneIDs = Set(nextColumn.panes.map(\.paneID))
            guard !survivingPaneIDs.isEmpty else {
                continue
            }

            return PaneRemovalTransition(
                columnID: previousColumn.columnID,
                survivingPaneIDs: survivingPaneIDs
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
            let focusedIndex = currentState.columns.firstIndex(where: {
                $0.panes.contains(where: { $0.id == focusedPaneID })
            })
        else {
            return
        }

        let step = accumulatedDelta > 0 ? -1 : 1
        let targetIndex = focusedIndex + step
        guard currentState.columns.indices.contains(targetIndex) else {
            return
        }

        let targetColumn = currentState.columns[targetIndex]
        onFocusSettled?(targetColumn.focusedPaneID ?? targetColumn.panes.first?.id ?? focusedPaneID)
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
        insertionTransition: PaneInsertionTransition?
    ) -> Bool {
        insertionTransition?.paneID == panePresentation.paneID
    }
}
