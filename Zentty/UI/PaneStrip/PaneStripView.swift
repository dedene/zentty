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
    var onPaneBorderContextClicked: ((PaneID) -> Void)?
    var onDividerInteraction: ((PaneDivider) -> Void)?
    var onDividerResizeRequested: ((PaneResizeTarget, CGFloat) -> CGFloat)?
    var onDividerEqualizeRequested: ((PaneDivider) -> Void)?
    var onPaneStripStateRestoreRequested: ((PaneStripState) -> Void)?
    var onPaneReorderRequested: ((PaneID, Int, Bool) -> Void)?
    var onPaneReorderInColumnRequested: ((PaneID, PaneColumnID, Int, Bool) -> Void)?
    var onPaneSplitDropRequested: ((PaneID, PaneID, PaneSplitPreview.Axis, Bool, Bool) -> Void)?
    var onPaneCrossWorklaneDropRequested: ((PaneID, WorklaneID, Int?, Bool) -> Void)?
    var sidebarWorklaneFrameProvider: (() -> [(WorklaneID, CGRect)])?
    var sidebarPaneBoundaryProvider: (() -> [(WorklaneID, [PaneInsertionBoundary])])?
    var sidebarNewWorklanePlaceholderFrameProvider: (() -> CGRect?)?
    var onDragApproachingSidebarEdge: ((Bool) -> Void)?
    var onHoveredSidebarWorklaneChanged: ((WorklaneID?) -> Void)?
    var onNewWorklanePlaceholderVisibilityChanged: ((Int?) -> Void)?
    var onSidebarScrollRequested: ((CGFloat) -> Void)?
    var onSidebarInsertionLineChanged: ((SidebarPaneInsertionLineTarget?) -> Void)?
    var onDragActiveChanged: ((Bool) -> Void)?
    var onLeadingInsetChangedDuringDrag: ((CGFloat) -> Void)?
    var activeWorklaneIDProvider: (() -> WorklaneID?)?
    var sidebarBoundsProvider: (() -> CGRect)?
    var worklaneCountProvider: (() -> Int)?
    var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
    var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
    var restoredRerunnableCommandProvider: ((PaneID) -> String?)?
    var sidebarWidthProvider: (() -> CGFloat)?
    var shouldSuppressProgrammaticTerminalFocus: (() -> Bool)?
    weak var dragOverlayView: NSView? {
        didSet { dragCoordinator.dragHostView = dragOverlayView }
    }
    private(set) var isDragActive = false
    private(set) var isDropSettling = false
    private var dropSettleCoveredPaneID: PaneID?
    private var afterNextRenderCallback: (() -> Void)?
    private(set) var isZoomedOut = false
    static let zoomScale: CGFloat = 0.4
    var dragZoomScale: CGFloat { Self.zoomScale }

    private enum PaneFocusSource {
        case hover
        case pointerClick
        case scrollSwitch
        case external
    }

    private struct PaneFocusArbitrator {
        private var isHoverSuppressed = false
        private var suppressionMouseLocation: NSPoint?

        var canAcceptHoverFocus: Bool {
            !isHoverSuppressed
        }

        mutating func recordFocus(from source: PaneFocusSource, mouseLocation: NSPoint?) {
            switch source {
            case .hover:
                break
            case .pointerClick:
                clearHoverSuppression()
            case .scrollSwitch, .external:
                isHoverSuppressed = true
                suppressionMouseLocation = mouseLocation
            }
        }

        mutating func clearHoverSuppressionIfPointerLocationChanged(to mouseLocation: NSPoint?) -> Bool {
            guard isHoverSuppressed, let mouseLocation else {
                return false
            }

            guard let suppressionMouseLocation else {
                clearHoverSuppression()
                return true
            }

            guard hypot(
                mouseLocation.x - suppressionMouseLocation.x,
                mouseLocation.y - suppressionMouseLocation.y
            ) > 0.5 else {
                return false
            }

            clearHoverSuppression()
            return true
        }

        mutating func reset() {
            clearHoverSuppression()
        }

        private mutating func clearHoverSuppression() {
            isHoverSuppressed = false
            suppressionMouseLocation = nil
        }
    }

    private let motionController = PaneStripMotionController()
    private let scrollSwitchHandler = ScrollSwitchGestureHandler()
    private let viewportView = NSView()
    private let runtimeRegistry: PaneRuntimeRegistry
    private let backingScaleFactorProvider: () -> CGFloat
    private let dragCoordinator = PaneDragCoordinator()
    private var currentState: PaneStripState?
    private var currentPaneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    private var currentShowsPaneLabels = AppConfig.Panes.default.showLabels
    private var currentInactivePaneOpacity = AppConfig.Panes.default.inactiveOpacity
    private var currentSmoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled
    private var currentShowPaneBorders = AppConfig.Appearance.default.showPaneBorders
    private var currentFocusFollowsMouseEnabled = AppConfig.Panes.default.focusFollowsMouse
    private var currentFocusFollowsMouseDelay = AppConfig.Panes.default.focusFollowsMouseDelay
    private var pendingHoverFocusWorkItem: DispatchWorkItem?
    private var pendingHoverFocusPaneID: PaneID?
    private var pendingHoverFocusMouseLocation: NSPoint?
    private var focusArbitrator = PaneFocusArbitrator()
    private var pendingFocusRequestPaneID: PaneID?
    #if DEBUG
        private var hoverFocusWindowIsKeyOverrideForTesting: Bool?
        private var hoverFocusPressedMouseButtonsOverrideForTesting: Int?
        private var hoverFocusMouseLocationOverrideForTesting: NSPoint?
    #endif
    private var currentWorklaneColor: WorklaneColor?
    private var currentPresentation: StripPresentation?
    private var shortcutManager = ShortcutManager(shortcuts: .default)
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var dragZoneViews: [PaneID: PaneDragZoneView] = [:]
    private var dividerViews: [PaneDivider: PaneDividerHandleView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var lastFocusedPaneID: PaneID?
    private var pendingProgrammaticFocusPaneID: PaneID?
    private var focusGeneration: UInt64 = 0
    private var deferredWorkGeneration: UInt64 = 0
    private(set) var lastInsertionTransition: PaneInsertionTransition?
    private(set) var lastRemovalTransition: PaneRemovalTransition?
    private(set) var lastRenderWasAnimated = false
    private var pendingAnimatedSettleAction: (() -> Void)?
    private var renderGuard = RenderGuard()
    private var suppressDiffBasedTransitionsOnNextRender = false
    private var isDetachingFromWindow = false
    private var isRenderingLayoutPass = false
    private var needsTerminalRedrawAfterLayout = false
    private var isTerminalRedrawScheduled = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var resolvedLeadingVisibleInset: CGFloat = 0
    private var viewportDiagnosticsWorklaneID: WorklaneID?
    private var viewportDiagnosticsLaneRole: TerminalViewportLaneRole = .activeCanvas
    private var hoveredDivider: PaneDivider?
    private var activeDivider: PaneDivider?
    private var dividerDragSession: DividerDragSession?
    private var dividerDragEscapeMonitor: Any?
    private var dividerDragSuspendedPaneIDs: Set<PaneID> = []
    private var pendingTargetOffsetOverride: PendingTargetOffsetOverride?
    private var hostDrivenResizeRenderRequestPending = false
    var prefersHostDrivenResizeRendering = false
    var onHostDrivenResizeRenderRequested: (() -> Void)?
    #if DEBUG
        private(set) var renderSnapshotsForTesting: [RenderSnapshot] = []
    #endif

    private struct DividerDragSession {
        let target: PaneResizeTarget
        let initialState: PaneStripState
        let initialScrollOffsetX: CGFloat
        let initialCurrentOffset: CGFloat
        var lastTranslation: CGFloat
    }

    private var dividerDragCumulativeAppliedWidthDelta: CGFloat = 0

    private enum PendingTargetOffsetOverride: Equatable {
        case usePresentationTargetOffset
        case shiftBy(CGFloat)
    }

    #if DEBUG
        struct RenderSnapshot: Equatable {
            let boundsSize: CGSize
            let leadingVisibleInset: CGFloat
            let focusedPaneFrame: CGRect?
        }
    #endif

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

    var onPaneNewWorklaneDropRequested: ((PaneID, Int, Bool) -> Void)?

    private func setupDragCoordinator() {
        dragCoordinator.onReorder = { [weak self] paneID, columnIndex, isDuplicate in
            self?.onPaneReorderRequested?(paneID, columnIndex, isDuplicate)
        }
        dragCoordinator.onReorderInColumn = { [weak self] paneID, columnID, paneIndex, isDuplicate in
            self?.onPaneReorderInColumnRequested?(paneID, columnID, paneIndex, isDuplicate)
        }
        dragCoordinator.onSplitDrop = { [weak self] paneID, targetPaneID, axis, leading, isDuplicate in
            self?.onPaneSplitDropRequested?(paneID, targetPaneID, axis, leading, isDuplicate)
        }
        dragCoordinator.onDragActiveChanged = { [weak self] active in
            guard let self else { return }
            self.isDragActive = active
            if active {
                self.cancelPendingHoverFocus()
            }
            if !active, !self.isDetachingFromWindow {
                if let state = self.currentState {
                    self.renderCurrentState(state, animated: false)
                }
            }
            self.onDragActiveChanged?(active)
        }
        dragCoordinator.onSidebarDrop = { [weak self] paneID, worklaneID, paneIndex, isDuplicate in
            self?.onPaneCrossWorklaneDropRequested?(paneID, worklaneID, paneIndex, isDuplicate)
        }
        dragCoordinator.onSidebarNewWorklaneDrop = { [weak self] paneID, insertionIndex, isDuplicate in
            self?.onPaneNewWorklaneDropRequested?(paneID, insertionIndex, isDuplicate)
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
        dragCoordinator.sidebarNewWorklanePlaceholderFrameProvider = { [weak self] in
            self?.sidebarNewWorklanePlaceholderFrameProvider?()
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
        dragCoordinator.onNewWorklanePlaceholderVisibilityChanged = { [weak self] insertionIndex in
            self?.onNewWorklanePlaceholderVisibilityChanged?(insertionIndex)
        }
        dragCoordinator.onSidebarScrollRequested = { [weak self] delta in
            self?.onSidebarScrollRequested?(delta)
        }
        dragCoordinator.onSidebarInsertionLineChanged = { [weak self] target in
            self?.onSidebarInsertionLineChanged?(target)
        }
        dragCoordinator.sidebarPaneBoundaryProvider = { [weak self] in
            self?.sidebarPaneBoundaryProvider?() ?? []
        }
    }

    override func layout() {
        isRenderingLayoutPass = true
        super.layout()
        defer {
            isRenderingLayoutPass = false
            if needsTerminalRedrawAfterLayout {
                needsTerminalRedrawAfterLayout = false
                scheduleTerminalRedraw()
            }
        }
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

        if prefersHostDrivenResizeRendering {
            guard !hostDrivenResizeRenderRequestPending else {
                return
            }
            hostDrivenResizeRenderRequestPending = true
            let deferredWorkGeneration = self.deferredWorkGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, deferredWorkGeneration == self.deferredWorkGeneration else { return }
                self.hostDrivenResizeRenderRequestPending = false
                self.onHostDrivenResizeRenderRequested?()
            }
            return
        }

        renderCurrentState(currentState, animated: false)
    }

    func render(
        _ state: PaneStripState,
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        showsPaneLabels: Bool = AppConfig.Panes.default.showLabels,
        inactivePaneOpacity: CGFloat = AppConfig.Panes.default.inactiveOpacity,
        smoothScrollingEnabled: Bool = AppConfig.Panes.default.smoothScrollingEnabled,
        showPaneBorders: Bool = AppConfig.Appearance.default.showPaneBorders,
        focusFollowsMouseEnabled: Bool = AppConfig.Panes.default.focusFollowsMouse,
        focusFollowsMouseDelay: AppConfig.Panes.FocusFollowsMouseDelay = AppConfig.Panes.default.focusFollowsMouseDelay,
        worklaneColor: WorklaneColor? = nil,
        leadingVisibleInset: CGFloat? = nil,
        animated: Bool = true,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        hostDrivenResizeRenderRequestPending = false
        currentPaneBorderContextByPaneID = paneBorderContextByPaneID
        currentShowsPaneLabels = showsPaneLabels
        currentInactivePaneOpacity = max(
            AppConfig.Panes.minimumInactiveOpacity,
            min(inactivePaneOpacity, AppConfig.Panes.maximumInactiveOpacity)
        )
        currentSmoothScrollingEnabled = smoothScrollingEnabled
        currentShowPaneBorders = showPaneBorders
        currentFocusFollowsMouseEnabled = focusFollowsMouseEnabled
        currentFocusFollowsMouseDelay = focusFollowsMouseDelay
        if !focusFollowsMouseEnabled {
            cancelPendingHoverFocus()
            focusArbitrator.reset()
            pendingFocusRequestPaneID = nil
        }
        currentWorklaneColor = worklaneColor
        let previousFocusedPaneID = currentState?.focusedPaneID
        currentState = state
        if focusFollowsMouseEnabled {
            recordRenderedFocusTransition(from: previousFocusedPaneID, to: state.focusedPaneID)
        }
        resetScrollSwitchGestureIfFocusChanged(from: previousFocusedPaneID, to: state.focusedPaneID)

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

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        paneViews.values.forEach { $0.updateShortcutTooltips(shortcutManager) }
    }

    func transition(
        to state: PaneStripState,
        paneBorderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        showsPaneLabels: Bool = AppConfig.Panes.default.showLabels,
        inactivePaneOpacity: CGFloat = AppConfig.Panes.default.inactiveOpacity,
        smoothScrollingEnabled: Bool = AppConfig.Panes.default.smoothScrollingEnabled,
        showPaneBorders: Bool = AppConfig.Appearance.default.showPaneBorders,
        focusFollowsMouseEnabled: Bool = AppConfig.Panes.default.focusFollowsMouse,
        focusFollowsMouseDelay: AppConfig.Panes.FocusFollowsMouseDelay = AppConfig.Panes.default.focusFollowsMouseDelay,
        worklaneColor: WorklaneColor? = nil,
        leadingVisibleInset: CGFloat,
        animated: Bool,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        hostDrivenResizeRenderRequestPending = false
        currentPaneBorderContextByPaneID = paneBorderContextByPaneID
        currentShowsPaneLabels = showsPaneLabels
        currentInactivePaneOpacity = max(
            AppConfig.Panes.minimumInactiveOpacity,
            min(inactivePaneOpacity, AppConfig.Panes.maximumInactiveOpacity)
        )
        currentSmoothScrollingEnabled = smoothScrollingEnabled
        currentShowPaneBorders = showPaneBorders
        currentFocusFollowsMouseEnabled = focusFollowsMouseEnabled
        currentFocusFollowsMouseDelay = focusFollowsMouseDelay
        if !focusFollowsMouseEnabled {
            cancelPendingHoverFocus()
            focusArbitrator.reset()
            pendingFocusRequestPaneID = nil
        }
        currentWorklaneColor = worklaneColor
        let previousFocusedPaneID = currentState?.focusedPaneID
        currentState = state
        if focusFollowsMouseEnabled {
            recordRenderedFocusTransition(from: previousFocusedPaneID, to: state.focusedPaneID)
        }
        resetScrollSwitchGestureIfFocusChanged(from: previousFocusedPaneID, to: state.focusedPaneID)
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

    func cancelScrollSwitchGesture() {
        scrollSwitchHandler.reset()
    }

    func settlePresentationNow() {
        viewportView.layer?.removeAllAnimations()
        paneViews.values.forEach {
            $0.layer?.removeAllAnimations()
            $0.syncInsetBorderNow()
        }
        dividerViews.values.forEach { $0.layer?.removeAllAnimations() }

        if let pendingAnimatedSettleAction {
            self.pendingAnimatedSettleAction = nil
            pendingAnimatedSettleAction()
            return
        }

        guard let currentState, bounds.size != .zero else {
            return
        }

        renderCurrentState(
            currentState,
            animated: false,
            forceViewportLayoutBeforeViewportSync: true
        )
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let borderContextHitView = hitTestBorderContext(at: point) {
            return borderContextHitView
        }

        return super.hitTest(point)
    }

    private func scheduleHoverFocus(for paneID: PaneID, mouseLocation: NSPoint?) {
        cancelPendingHoverFocus()
        guard shouldAllowHoverFocus(for: paneID, mouseLocation: mouseLocation) else {
            return
        }

        pendingHoverFocusPaneID = paneID
        pendingHoverFocusMouseLocation = mouseLocation
        let delay = currentFocusFollowsMouseDelay.interval
        guard delay > 0 else {
            performHoverFocusIfStillValid(for: paneID)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performHoverFocusIfStillValid(for: paneID)
            }
        }
        pendingHoverFocusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func handleHoverEntered(over paneID: PaneID, mouseLocation: NSPoint?) {
        _ = focusArbitrator.clearHoverSuppressionIfPointerLocationChanged(
            to: mouseLocation
        )
        scheduleHoverFocus(for: paneID, mouseLocation: mouseLocation)
    }

    private func handleHoverMoved(over paneID: PaneID, mouseLocation: NSPoint?) {
        guard focusArbitrator.clearHoverSuppressionIfPointerLocationChanged(to: mouseLocation) else {
            return
        }
        scheduleHoverFocus(for: paneID, mouseLocation: mouseLocation)
    }

    private func handleHoverExited(from paneID: PaneID) {
        cancelPendingHoverFocus(for: paneID)
    }

    private func cancelPendingHoverFocus(for paneID: PaneID? = nil) {
        guard paneID == nil || pendingHoverFocusPaneID == paneID else {
            return
        }
        pendingHoverFocusWorkItem?.cancel()
        pendingHoverFocusWorkItem = nil
        pendingHoverFocusPaneID = nil
        pendingHoverFocusMouseLocation = nil
    }

    private func performHoverFocusIfStillValid(for paneID: PaneID) {
        guard pendingHoverFocusPaneID == paneID else {
            return
        }
        let mouseLocation = pendingHoverFocusMouseLocation
        cancelPendingHoverFocus(for: paneID)
        guard shouldAllowHoverFocus(for: paneID, mouseLocation: mouseLocation),
              currentState?.focusedPaneID != paneID,
              let paneView = paneViews[paneID]
        else {
            return
        }

        requestFocus(for: paneID, source: .hover)
        paneView.focusTerminal()
    }

    private func shouldAllowHoverFocus(for paneID: PaneID, mouseLocation: NSPoint?) -> Bool {
        guard currentFocusFollowsMouseEnabled,
              isWindowKeyForHoverFocus,
              paneViews[paneID] != nil,
              currentState?.focusedPaneID != paneID else {
            return false
        }

        guard !isDragActive,
              dividerDragSession == nil,
              activeDivider == nil,
              !paneViews.values.contains(where: \.isSearchHUDVisible),
              pressedMouseButtonsForHoverFocus == 0 else {
            return false
        }

        guard focusArbitrator.canAcceptHoverFocus else {
            return false
        }

        guard !isHoverFocusMouseLocationCoveredBySidebar(mouseLocation) else {
            return false
        }

        return true
    }

    private func isHoverFocusMouseLocationCoveredBySidebar(_ mouseLocation: NSPoint?) -> Bool {
        guard let mouseLocation else {
            return false
        }

        let locationInSelf = locationInSelfForHoverFocus(mouseLocation)
        guard bounds.contains(locationInSelf) else {
            return false
        }

        if resolvedLeadingVisibleInset > 0, locationInSelf.x < resolvedLeadingVisibleInset {
            return true
        }

        guard let sidebarBounds = sidebarBoundsProvider?(),
              !sidebarBounds.isEmpty,
              sidebarBounds.contains(locationInSelf)
        else {
            return false
        }

        return true
    }

    private func locationInSelfForHoverFocus(_ mouseLocation: NSPoint) -> NSPoint {
        guard window != nil else {
            return mouseLocation
        }

        return convert(mouseLocation, from: nil)
    }

    private func requestFocus(
        for paneID: PaneID,
        source: PaneFocusSource,
        mouseLocation: NSPoint? = nil
    ) {
        pendingFocusRequestPaneID = paneID
        let focusMouseLocation = mouseLocation ?? currentMouseLocationForHoverFocusArbitration
        focusArbitrator.recordFocus(
            from: source,
            mouseLocation: focusMouseLocation
        )

        switch source {
        case .hover, .pointerClick:
            onPaneSelected?(paneID)
        case .scrollSwitch:
            onFocusSettled?(paneID)
        case .external:
            break
        }
    }

    private func recordRenderedFocusTransition(from previousPaneID: PaneID?, to nextPaneID: PaneID?) {
        guard let previousPaneID, previousPaneID != nextPaneID else {
            return
        }

        if pendingFocusRequestPaneID == nextPaneID {
            pendingFocusRequestPaneID = nil
            return
        }

        pendingFocusRequestPaneID = nil
        focusArbitrator.recordFocus(
            from: .external,
            mouseLocation: currentMouseLocationForHoverFocusArbitration
        )
    }

    private var isWindowKeyForHoverFocus: Bool {
        #if DEBUG
            if let hoverFocusWindowIsKeyOverrideForTesting {
                return hoverFocusWindowIsKeyOverrideForTesting
            }
        #endif
        return window?.isKeyWindow == true
    }

    private var pressedMouseButtonsForHoverFocus: Int {
        #if DEBUG
            if let hoverFocusPressedMouseButtonsOverrideForTesting {
                return hoverFocusPressedMouseButtonsOverrideForTesting
            }
        #endif
        return NSEvent.pressedMouseButtons
    }

    private var currentMouseLocationForHoverFocusArbitration: NSPoint? {
        #if DEBUG
            if let hoverFocusMouseLocationOverrideForTesting {
                return hoverFocusMouseLocationOverrideForTesting
            }
        #endif
        return window?.mouseLocationOutsideOfEventStream
    }

    private func mouseLocationForFocusArbitration(from event: NSEvent) -> NSPoint? {
        guard event.window != nil else {
            return currentMouseLocationForHoverFocusArbitration
        }
        return event.locationInWindow
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        for paneView in paneViews.values {
            guard let frameInPane = paneView.interactiveBorderContextFrameInSelf else {
                continue
            }

            let frameInSelf = convert(frameInPane, from: paneView)
            addCursorRect(frameInSelf, cursor: .pointingHand)
        }
    }

    var leadingVisibleInsetForTesting: CGFloat {
        resolvedLeadingVisibleInset
    }

    var renderInvocationCount: Int {
        renderGuard.renderCount
    }

    #if DEBUG
        var hoverFocusWindowIsKeyForTesting: Bool? {
            get { hoverFocusWindowIsKeyOverrideForTesting }
            set { hoverFocusWindowIsKeyOverrideForTesting = newValue }
        }

        var hoverFocusPressedMouseButtonsForTesting: Int? {
            get { hoverFocusPressedMouseButtonsOverrideForTesting }
            set { hoverFocusPressedMouseButtonsOverrideForTesting = newValue }
        }

        var hoverFocusMouseLocationForTesting: NSPoint? {
            get { hoverFocusMouseLocationOverrideForTesting }
            set { hoverFocusMouseLocationOverrideForTesting = newValue }
        }

        var pendingHoverFocusPaneIDForTesting: PaneID? {
            pendingHoverFocusPaneID
        }

        func simulatePaneHoverEnteredForTesting(_ paneID: PaneID) {
            handleHoverEntered(over: paneID, mouseLocation: currentMouseLocationForHoverFocusArbitration)
        }

        func simulatePaneHoverExitedForTesting(_ paneID: PaneID) {
            handleHoverExited(from: paneID)
        }

        func simulatePaneHoverMovedForTesting(_ paneID: PaneID) {
            handleHoverMoved(over: paneID, mouseLocation: currentMouseLocationForHoverFocusArbitration)
        }
    #endif

    func centerFocusedInteriorPaneOnNextRender() {
        pendingTargetOffsetOverride = .usePresentationTargetOffset
    }

    func shiftTargetOffsetOnNextRender(by delta: CGFloat) {
        guard abs(delta) > 0.001 else { return }
        pendingTargetOffsetOverride = .shiftBy(delta)
    }

    func clearPendingTargetOffsetOverride() {
        pendingTargetOffsetOverride = nil
    }

    private func renderCurrentState(
        _ state: PaneStripState,
        animated: Bool,
        forceViewportLayoutBeforeViewportSync: Bool = false,
        animationDuration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        animationTimingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        guard !isDragActive || isDropSettling else { return }
        let settleGeneration = renderGuard.advanceGeneration()
        let previousPresentation = currentPresentation
        let previousOffset = currentOffset
        let targetOffsetOverride = pendingTargetOffsetOverride
        let suppressDiffBasedTransitions = suppressDiffBasedTransitionsOnNextRender
        suppressDiffBasedTransitionsOnNextRender = false
        pendingTargetOffsetOverride = nil
        let presentation = motionController.presentation(
            for: state,
            in: bounds.size,
            leadingVisibleInset: resolvedLeadingVisibleInset,
            backingScaleFactor: currentBackingScaleFactor
        )
        let insertionTransition = suppressDiffBasedTransitions ? nil : insertionTransition(
            from: previousPresentation,
            previousOffset: previousOffset,
            to: presentation
        )
        let needsTerminalRedrawAfterRender = terminalDisplaySizeChanged(
            from: previousPresentation,
            to: presentation
        )
        let newlyAttachedPaneIDs = newlyAttachedPaneIDs(
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
            && window?.isVisible == true
            && window?.inLiveResize != true
            && !inLiveResize
            && !isResizeSuppressedRender
            && !isZoomedOut
        lastRenderWasAnimated = shouldAnimate
        let removalTransition = shouldAnimate && !suppressDiffBasedTransitions
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
        let shouldUseTerminalResizePreview = shouldAnimate
            && needsTerminalRedrawAfterRender
            && insertionTransition == nil
            && removalTransition == nil
        reconcilePaneViews(
            with: state,
            presentation: presentation,
            initialOffset: previousOffset,
            insertionTransition: insertionTransition,
            suspendedPaneIDs: suspendedPaneIDs
        )
        if !isZoomedOut {
            applyTerminalAnimationFreeze(to: frozenPaneIDs, insertionTransition: insertionTransition)
            if shouldUseTerminalResizePreview {
                beginTerminalResizePreviews(
                    from: previousPresentation,
                    previousOffset: previousOffset,
                    to: presentation,
                    targetOffset: targetOffset
                )
            } else {
                clearTerminalResizePreviews()
            }
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
            let settleAction: () -> Void = { [weak self] in
                guard let self else { return }
                self.finishAnimatedRender(
                    settleGeneration: settleGeneration,
                    presentation: presentation,
                    state: state,
                    targetOffset: targetOffset,
                    insertionTransition: insertionTransition,
                    needsTerminalRedrawAfterRender: needsTerminalRedrawAfterRender,
                    newlyAttachedPaneIDs: newlyAttachedPaneIDs
                )
            }
            pendingAnimatedSettleAction = settleAction
            motionController.animate(
                in: self,
                duration: animationDuration,
                timingFunction: animationTimingFunction,
                updates: updates
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingAnimatedSettleAction = nil
                    self.finishAnimatedRender(
                        settleGeneration: settleGeneration,
                        presentation: presentation,
                        state: state,
                        targetOffset: targetOffset,
                        insertionTransition: insertionTransition,
                        needsTerminalRedrawAfterRender: needsTerminalRedrawAfterRender,
                        newlyAttachedPaneIDs: newlyAttachedPaneIDs
                    )
                }
            }
        } else {
            pendingAnimatedSettleAction = nil
            updates()
            if !isZoomedOut {
                applyTerminalAnimationFreeze(to: [])
                clearTerminalResizePreviews()
            }
            flushViewportLayoutIfNeeded()
            if forceViewportLayoutBeforeViewportSync || !newlyAttachedPaneIDs.isEmpty {
                viewportView.layoutSubtreeIfNeeded()
            }
            if !isZoomedOut {
                applyViewportSyncSuspension(to: [])
            }
            if !isZoomedOut {
                forceTerminalViewportSync(for: newlyAttachedPaneIDs)
            }
            if needsTerminalRedrawAfterRender {
                refreshTerminalDisplaysIfNeeded()
            }
        }

        currentOffset = targetOffset
        lastRenderedSize = bounds.size
        if isResizeSuppressedRender {
            renderGuard.clearResizeSuppression(forGeneration: settleGeneration)
        }
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        syncFocusedTerminal(with: state.focusedPaneID)
        #if DEBUG
            renderSnapshotsForTesting.append(
                RenderSnapshot(
                    boundsSize: bounds.size,
                    leadingVisibleInset: resolvedLeadingVisibleInset,
                    focusedPaneFrame: state.focusedPaneID.flatMap { paneViews[$0]?.frame }
                )
            )
        #endif

        if let callback = afterNextRenderCallback {
            afterNextRenderCallback = nil
            callback()
        }
    }

    private func hitTestBorderContext(at pointInSelf: CGPoint) -> PaneBorderContextInsetView? {
        for paneView in paneViews.values.reversed() {
            if let hitView = paneView.hitTestBorderContext(pointInSelf, from: self) {
                return hitView
            }
        }

        return nil
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

    private func newlyAttachedPaneIDs(
        from previousPresentation: StripPresentation?,
        to presentation: StripPresentation
    ) -> Set<PaneID> {
        guard let previousPresentation else {
            return []
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let currentPaneIDs = Set(presentation.panes.map(\.paneID))
        return currentPaneIDs.subtracting(previousPaneIDs)
    }

    private func forceTerminalViewportSync(for paneIDs: Set<PaneID>) {
        for paneID in paneIDs {
            paneViews[paneID]?.forceTerminalViewportSync()
        }
    }

    private func refreshTerminalDisplays() {
        for paneView in paneViews.values {
            paneView.needsLayout = true
            refreshDisplayRecursively(in: paneView)
        }

        refreshDisplayRecursively(in: viewportView)
    }

    private func refreshTerminalDisplaysIfNeeded() {
        guard !isRenderingLayoutPass else {
            needsTerminalRedrawAfterLayout = true
            return
        }
        scheduleTerminalRedraw()
    }

    private func scheduleTerminalRedraw() {
        guard !isTerminalRedrawScheduled else {
            return
        }

        isTerminalRedrawScheduled = true
        let deferredWorkGeneration = self.deferredWorkGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, deferredWorkGeneration == self.deferredWorkGeneration else { return }
            self.isTerminalRedrawScheduled = false
            self.refreshTerminalDisplays()
        }
    }

    private func flushViewportLayoutIfNeeded() {
        viewportView.needsLayout = true
    }

    private func refreshDisplayRecursively(in view: NSView) {
        view.needsDisplay = true
        view.displayIfNeeded()
        view.subviews.forEach { refreshDisplayRecursively(in: $0) }
    }

    private func finishAnimatedRender(
        settleGeneration: Int,
        presentation: StripPresentation,
        state: PaneStripState,
        targetOffset: CGFloat,
        insertionTransition: PaneInsertionTransition?,
        needsTerminalRedrawAfterRender: Bool,
        newlyAttachedPaneIDs: Set<PaneID>
    ) {
        if renderGuard.generation == settleGeneration {
            applyPresentation(
                presentation,
                state: state,
                offset: targetOffset,
                animated: false,
                useNeutralBackground: false,
                insertionTransition: insertionTransition,
                allowInactiveDimming: true
            )
            reconcileDividerViews(with: presentation, offset: targetOffset)
            paneViews.values.forEach { $0.syncInsetBorderNow() }
            clearTerminalResizePreviews()
        }

        if !isZoomedOut {
            applyTerminalAnimationFreeze(to: [])
            clearTerminalResizePreviews()
        }
        flushViewportLayoutIfNeeded()
        viewportView.layoutSubtreeIfNeeded()
        if !isZoomedOut {
            applyViewportSyncSuspension(to: [])
        }
        if needsTerminalRedrawAfterRender {
            refreshTerminalDisplaysIfNeeded()
            if !isZoomedOut {
                forceTerminalViewportSync(for: Set(paneViews.keys))
            }
        } else if !isZoomedOut {
            forceTerminalViewportSync(for: newlyAttachedPaneIDs)
        }
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

            paneView.smoothScrollingEnabled = currentSmoothScrollingEnabled
            paneView.showPaneBorders = currentShowPaneBorders
            let pane = state.panes[index]
            paneView.render(
                pane: pane,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused,
                borderContext: currentShowsPaneLabels
                    ? currentPaneBorderContextByPaneID[panePresentation.paneID]
                    : nil,
                worklaneColor: currentWorklaneColor,
                animated: animated,
                useNeutralBackground: useNeutralBackground
            )
            let targetFrame = panePresentation.frame.offsetBy(
                dx: -resolvedOffset(offset),
                dy: 0
            )
            let targetAlpha: CGFloat
            if panePresentation.paneID == dropSettleCoveredPaneID {
                targetAlpha = 0
            } else {
                targetAlpha = PaneContainerView.presentationAlpha(
                    forEmphasis: panePresentation.emphasis,
                    inactiveOpacity: currentInactivePaneOpacity,
                    allowInactiveDimming: allowInactiveDimming
                )
            }
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
                let frameChanged = paneView.frame != targetFrame
                paneView.frame = targetFrame
                if frameChanged {
                    paneView.needsLayout = true
                }
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
                let startsWithViewportSyncSuspended = isZoomedOut || suspendedPaneIDs.contains(pane.id)
                let paneView = PaneContainerView(
                    pane: pane,
                    width: panePresentation.frame.width,
                    height: panePresentation.frame.height,
                    emphasis: panePresentation.emphasis,
                    isFocused: panePresentation.isFocused,
                    runtime: runtime,
                    theme: currentTheme,
                    initialViewportSyncSuspended: startsWithViewportSyncSuspended,
                    viewportDiagnosticsWorklaneID: viewportDiagnosticsWorklaneID,
                    viewportDiagnosticsLaneRole: viewportDiagnosticsLaneRole,
                    viewportDiagnosticsIsZoomedOut: isZoomedOut
                )
                paneView.smoothScrollingEnabled = currentSmoothScrollingEnabled
                paneView.showPaneBorders = currentShowPaneBorders
                paneView.updateShortcutTooltips(shortcutManager)
                paneView.setZoomedOutBackdropVisible(isZoomedOut, animated: false)
                paneView.onSelected = { [weak self] in
                    if let pendingPaneID = self?.pendingProgrammaticFocusPaneID,
                       pendingPaneID != pane.id {
                        return
                    }
                    self?.requestFocus(for: pane.id, source: .pointerClick)
                }
                paneView.onHoverEntered = { [weak self] event in
                    guard let self else { return }
                    handleHoverEntered(
                        over: pane.id,
                        mouseLocation: mouseLocationForFocusArbitration(from: event)
                    )
                }
                paneView.onHoverMoved = { [weak self] event in
                    guard let self else { return }
                    handleHoverMoved(
                        over: pane.id,
                        mouseLocation: mouseLocationForFocusArbitration(from: event)
                    )
                }
                paneView.onHoverExited = { [weak self] _ in
                    self?.handleHoverExited(from: pane.id)
                }
                paneView.onCloseRequested = { [weak self] in
                    self?.onPaneCloseRequested?(pane.id)
                }
                paneView.onBorderContextClicked = { [weak self] paneID in
                    self?.onPaneBorderContextClicked?(paneID)
                }
                paneView.onScrollWheel = { [weak self] event in
                    self?.handlePaneSwitchScroll(event) ?? false
                }
                paneView.rightPaneCommandPresentationProvider = { [weak self] in
                    self?.rightPaneCommandPresentationProvider?() ?? .addsToWorklane
                }
                paneView.moveToWorklaneCatalogProvider = { [weak self] paneID in
                    self?.moveToWorklaneCatalogProvider?(paneID)
                }
                paneView.restoredRerunnableCommandProvider = { [weak self] paneID in
                    self?.restoredRerunnableCommandProvider?(paneID)
                }
                if !startsWithViewportSyncSuspended {
                    paneView.setTerminalViewportSyncSuspended(false)
                }
                if let insertionTransition, insertionTransition.paneID == pane.id {
                    paneView.frame = insertionTransition.initialFrame
                    paneView.alphaValue = insertionTransition.initialAlpha
                } else {
                    paneView.frame = panePresentation.frame.offsetBy(
                        dx: -resolvedOffset(initialOffset),
                        dy: 0
                    )
                    paneView.alphaValue = PaneContainerView.presentationAlpha(
                        forEmphasis: panePresentation.emphasis,
                        inactiveOpacity: currentInactivePaneOpacity
                    )
                }
                paneViews[panePresentation.paneID] = paneView
                viewportView.addSubview(paneView)
                if startsWithViewportSyncSuspended {
                    paneView.primeTerminalViewportForPreviewMountIfNeeded()
                    paneView.prepareSuspendedTerminalLayoutForPreviewMount()
                }
                TerminalViewportDiagnostics.shared.record(
                    .paneMounted,
                    context: TerminalViewportDiagnostics.Context(
                        paneID: pane.id,
                        worklaneID: viewportDiagnosticsWorklaneID,
                        laneRole: viewportDiagnosticsLaneRole,
                        isZoomedOut: isZoomedOut,
                        containerBounds: paneView.bounds
                    )
                )
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
            dragZone.contextMenuProvider = { [weak paneView] in
                paneView?.makeDragZoneContextMenu()
            }
            dragZone.isHidden = paneView.isSearchHUDVisible
            paneView.onSearchHUDVisibilityDidChange = { [weak dragZone] isVisible in
                dragZone?.isHidden = isVisible
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

    private func beginTerminalResizePreviews(
        from previousPresentation: StripPresentation?,
        previousOffset: CGFloat,
        to presentation: StripPresentation,
        targetOffset: CGFloat
    ) {
        guard let previousPresentation else {
            return
        }

        let previousFramesByPaneID = Dictionary(
            uniqueKeysWithValues: previousPresentation.panes.map { panePresentation in
                (
                    panePresentation.paneID,
                    panePresentation.frame.offsetBy(dx: -resolvedOffset(previousOffset), dy: 0)
                )
            }
        )

        for panePresentation in presentation.panes {
            guard
                let previousFrame = previousFramesByPaneID[panePresentation.paneID],
                let paneView = paneViews[panePresentation.paneID],
                abs(previousFrame.width - panePresentation.frame.width) > 0.5
                    || abs(previousFrame.height - panePresentation.frame.height) > 0.5
            else {
                continue
            }

            let targetFrame = panePresentation.frame.offsetBy(
                dx: -resolvedOffset(targetOffset),
                dy: 0
            )
            paneView.beginTerminalResizePreview(from: previousFrame, to: targetFrame)
        }
    }

    private func clearTerminalResizePreviews() {
        paneViews.values.forEach { $0.endTerminalResizePreview() }
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
            pendingProgrammaticFocusPaneID = nil
            focusGeneration &+= 1
            return
        }

        if shouldSuppressProgrammaticTerminalFocus?() == true {
            pendingProgrammaticFocusPaneID = nil
            focusGeneration &+= 1
            return
        }

        guard force || paneID != lastFocusedPaneID else {
            return
        }

        pendingProgrammaticFocusPaneID = paneID
        focusGeneration &+= 1
        let generation = focusGeneration
        for dragZone in dragZoneViews.values {
            dragZone.revalidateHoverState()
        }
        attemptFocus(paneID: paneID, generation: generation, retryCount: 0)
    }

    private func attemptFocus(paneID: PaneID, generation: UInt64, retryCount: Int) {
        guard generation == focusGeneration else { return }
        if shouldSuppressProgrammaticTerminalFocus?() == true {
            if pendingProgrammaticFocusPaneID == paneID {
                pendingProgrammaticFocusPaneID = nil
            }
            focusGeneration &+= 1
            return
        }
        guard retryCount < 50 else {
            if pendingProgrammaticFocusPaneID == paneID {
                pendingProgrammaticFocusPaneID = nil
            }
            return
        }

        if let paneView = paneViews[paneID], paneView.focusTerminalIfReady() {
            lastFocusedPaneID = paneID
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.focusGeneration,
                      self.pendingProgrammaticFocusPaneID == paneID else {
                    return
                }
                if self.paneViews[paneID]?.isTerminalFocused == true {
                    self.pendingProgrammaticFocusPaneID = nil
                } else {
                    self.attemptFocus(paneID: paneID, generation: generation, retryCount: retryCount + 1)
                }
            }
            return
        }

        // Retry on the next run loop turn — the pane view may not be
        // window-attached or its terminal surface may still be initializing.
        DispatchQueue.main.async { [weak self] in
            self?.attemptFocus(paneID: paneID, generation: generation, retryCount: retryCount + 1)
        }
    }

    func prepareForTestingTearDown() {
        cleanupTransientStateForWindowDetachment()
        afterNextRenderCallback = nil
        viewportView.layer?.removeAllAnimations()
        dividerViews.values.forEach { $0.layer?.removeAllAnimations() }
        layer?.removeAllAnimations()
        settlePresentationNow()
    }

    func configureViewportDiagnostics(
        worklaneID: WorklaneID?,
        laneRole: TerminalViewportLaneRole
    ) {
        viewportDiagnosticsWorklaneID = worklaneID
        viewportDiagnosticsLaneRole = laneRole
        for paneView in paneViews.values {
            paneView.configureViewportDiagnostics(
                worklaneID: worklaneID,
                laneRole: laneRole,
                isZoomedOut: isZoomedOut
            )
        }
    }

    private func cleanupTransientStateForWindowDetachment() {
        cancelPendingHoverFocus()
        focusArbitrator.reset()
        pendingFocusRequestPaneID = nil
        focusGeneration &+= 1
        pendingProgrammaticFocusPaneID = nil
        lastFocusedPaneID = nil
        deferredWorkGeneration &+= 1
        hostDrivenResizeRenderRequestPending = false
        needsTerminalRedrawAfterLayout = false
        isTerminalRedrawScheduled = false
        zoomSpring.stop()
        isZoomedOut = false
        dragScrollOffsetX = 0
        viewportView.autoresizingMask = [.width, .height]
        applyZoomScale(1)
        for (_, paneView) in paneViews {
            paneView.endVerticalFreeze()
            paneView.setTerminalViewportSyncSuspended(false)
        }
        pendingAnimatedSettleAction = nil
        endDropSettle()
        dragCoordinator.prepareForTestingTearDown()
        cancelDividerDrag()
        removeDividerDragEscapeMonitor()
        activeDivider = nil
        hoveredDivider = nil
        updateDividerHighlightStates()
    }

    var leadingMaskMinX: CGFloat {
        0
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
                performDividerResize(target: dividerDragSession.target, delta: delta)
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
            initialScrollOffsetX: dragScrollOffsetX,
            initialCurrentOffset: currentOffset,
            lastTranslation: 0
        )
        dividerDragCumulativeAppliedWidthDelta = 0
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

    /// Whether a zoom animation is currently in progress.
    var isZoomAnimating: Bool { zoomSpring.isRunning }
    private let zoomSpring = SpringAnimator()
    private var zoomAnchor: CGPoint = .zero
    private static let zoomAnimationDuration: CFTimeInterval = 0.35

    /// Fires on every frame of the zoom animation (and once on completion),
    /// plus on synchronous `applyZoomScale` calls. Used by the visual
    /// worklane switcher overlay to keep the highlight border and HUD in
    /// sync with the zoom transform and any `dragScrollOffsetX` shifts.
    var onZoomTransformChanged: (() -> Void)?

    private func updateZoomAnchor() {
        let fw = viewportView.frame.width
        let fh = viewportView.frame.height
        if let focusedID = currentState?.focusedPaneID,
           let focusedView = paneViews[focusedID] {
            zoomAnchor = CGPoint(x: focusedView.frame.midX, y: fh / 2)
        } else {
            zoomAnchor = CGPoint(x: fw / 2, y: fh / 2)
        }
    }

    /// Override applied to the next zoom-out target scale. The Worklane Peek
    /// uses this to put active + neighbor lanes at the same uniform scale
    /// when multiple worklanes are visible. Reset to nil when zooming back in
    /// so the drag-zoom path keeps using the static `Self.zoomScale`.
    private var zoomOutScaleOverride: CGFloat?

    private func applyZoom(animated: Bool, centerOnPaneID: PaneID? = nil) {
        // Compute the anchor: focused pane center in content space
        updateZoomAnchor()

        let zoomedOutScale = zoomOutScaleOverride ?? Self.zoomScale
        let targetScale = isZoomedOut ? zoomedOutScale : 1.0
        let targetScrollX = isZoomedOut
            ? scrollOffsetCentering(paneID: centerOnPaneID, scale: targetScale)
            : 0

        if animated {
            let fromScale = currentZoomScale()
            let fromScrollX = dragScrollOffsetX
            // Decide how to interpolate scrollX:
            //
            // - When the scale is *changing* AND we want a pane held at the
            //   visible center (zoom-out / zoom-in transitions), recompute
            //   scrollX from the current scale each tick. The relationship
            //   between scrollX and the on-screen pane position is
            //   non-linear in `scale`, so a linear interpolation here would
            //   cause the pane to drift sideways during the zoom.
            //
            // - When the scale stays put (pure pan: tab-navigation between
            //   panes inside peek), the recomputed value is constant,
            //   which would snap instantly. Fall back to linear
            //   interpolation between fromScrollX and targetScrollX so the
            //   spring's eased curve produces a smooth slide.
            let scaleIsChanging = abs(targetScale - fromScale) > 0.001
            let useDynamicScrollX = isZoomedOut && centerOnPaneID != nil && scaleIsChanging
            zoomSpring.start(duration: Self.zoomAnimationDuration) { [weak self] eased in
                guard let self else { return }
                let scale = fromScale + (targetScale - fromScale) * eased
                let scrollX: CGFloat = useDynamicScrollX
                    ? self.scrollOffsetCentering(paneID: centerOnPaneID, scale: scale)
                    : (fromScrollX + (targetScrollX - fromScrollX) * eased)
                self.dragScrollOffsetX = scrollX
                self.applyZoomScale(scale)
                if self.isDragActive {
                    self.dragCoordinator.updateDraggedPanePosition(zoomScale: scale)
                }
                self.onZoomTransformChanged?()
            } complete: { [weak self] in
                guard let self else { return }
                self.dragScrollOffsetX = targetScrollX
                self.applyZoomScale(targetScale)
                if self.isDragActive {
                    self.dragCoordinator.updateDraggedPanePosition(zoomScale: targetScale)
                    self.dragCoordinator.recheckEdgeScroll()
                }
                self.onZoomTransformChanged?()
            }
        } else {
            dragScrollOffsetX = targetScrollX
            applyZoomScale(targetScale)
            onZoomTransformChanged?()
        }
    }

    /// `dragScrollOffsetX` value that places `paneID`'s center at the
    /// horizontal center of the *visible* viewport — i.e., between
    /// `resolvedLeadingVisibleInset` and `viewportView.frame.width`. This
    /// matters when the sidebar is open; the canvas spans the whole window
    /// but the leading portion is obscured by the sidebar overlay, so the
    /// perceived center sits to the right of the geometric viewport center.
    /// Returns 0 (the natural unscrolled state) when no centering target is
    /// requested or the pane isn't currently mounted.
    private func scrollOffsetCentering(paneID: PaneID?, scale: CGFloat) -> CGFloat {
        guard let paneID,
              let frame = livePaneFrame(paneID),
              scale > 0,
              viewportView.frame.width > 0
        else { return 0 }
        let fw = viewportView.frame.width
        let visibleCenter = (resolvedLeadingVisibleInset + fw) / 2
        return frame.midX - visibleCenter / scale - zoomAnchor.x * (1 - 1 / scale)
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

    // MARK: - Pane Drag

    private func handleDragActivated(paneID: PaneID, origin: CGPoint) {
        guard let state = currentState,
              let presentation = currentPresentation else { return }

        // Trigger zoom-out if not already zoomed
        if !isZoomedOut {
            isZoomedOut = true
            setZoomedOutPaneBackdropsVisible(true, animated: true)
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
            previewBackgroundColor: currentTheme.paneZoomFillFocused.srgbClamped,
            backingScaleFactor: currentBackingScaleFactor,
            leadingVisibleInset: resolvedLeadingVisibleInset
        )
    }

    // MARK: - Drop Settle

    /// Begin the "drop settling" phase: allows rendering while the snapshot covers the pane.
    func beginDropSettle(paneID: PaneID? = nil, afterRender callback: @escaping () -> Void) {
        isDropSettling = true
        dropSettleCoveredPaneID = paneID
        afterNextRenderCallback = callback
        suppressDiffBasedTransitionsOnNextRender = true
    }

    /// End the settling phase, reveal the covered pane.
    func endDropSettle() {
        isDropSettling = false
        dropSettleCoveredPaneID = nil
        afterNextRenderCallback = nil
        suppressDiffBasedTransitionsOnNextRender = false
    }

    /// Return the current frame of a live pane view in viewportView coordinates.
    func livePaneFrame(_ paneID: PaneID) -> CGRect? {
        paneViews[paneID]?.frame
    }

    /// Convert a pane's current frame into the coordinate system of `target`,
    /// which must share an ancestor with this view. Returns `nil` if the pane
    /// isn't currently mounted. Used by the Worklane Peek overlay to track
    /// a highlighted pane through the zoom transform.
    func convertPaneFrame(_ paneID: PaneID, to target: NSView) -> CGRect? {
        guard let frame = livePaneFrame(paneID) else { return nil }
        return viewportView.convert(frame, to: target)
    }

    /// Resolve the pane currently under `point`, where `point` is expressed
    /// in `coordinateSpaceView`'s coordinate system. Used by peek hit-testing
    /// so pointer selection can reuse the strip's private pane-view map.
    func paneID(at point: NSPoint, from coordinateSpaceView: NSView) -> PaneID? {
        for paneID in currentState?.panes.map(\.id) ?? [] {
            guard let frame = convertPaneFrame(paneID, to: coordinateSpaceView),
                  frame.contains(point)
            else { continue }
            return paneID
        }
        return nil
    }

    /// Convert the bounding rect of the column containing `paneID` into the
    /// coordinate system of `target`. The Worklane Peek uses this so the
    /// HUD can anchor to the column (stable across pane changes within a
    /// vertical split) rather than to an individual pane.
    func convertColumnFrame(containingPaneID paneID: PaneID, to target: NSView) -> CGRect? {
        guard let state = currentState,
              let column = state.columns.first(where: { col in
                  col.panes.contains(where: { $0.id == paneID })
              })
        else { return nil }

        let frames = column.panes.compactMap { livePaneFrame($0.id) }
        guard let first = frames.first else { return nil }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return viewportView.convert(union, to: target)
    }

    /// Enter peek zoom-out using the same approach drag-zoom uses
    /// for *non-dragged* panes: only `setTerminalViewportSyncSuspended(true)`,
    /// no `beginVerticalFreeze`. The vertical freeze is needed when a pane is
    /// being snapshot-replaced (the dragged pane), but for static panes it
    /// causes an extra layout pass that re-runs `syncViewport` and reflows
    /// the terminal grid.
    ///
    /// `centerOnPaneID`, if provided, animates `dragScrollOffsetX` together
    /// with the zoom so that pane's column lands at the horizontal center of
    /// the viewport when the animation settles.
    /// `scaleOverride` lets the Worklane Peek pick a smaller scale when
    /// neighbor lanes need to fit alongside the active band.
    func beginPeekZoomOut(
        animated: Bool = true,
        centerOnPaneID: PaneID? = nil,
        scaleOverride: CGFloat? = nil
    ) {
        guard !isDragActive, !isZoomedOut else { return }
        isZoomedOut = true
        zoomOutScaleOverride = scaleOverride
        setZoomedOutPaneBackdropsVisible(true, animated: animated)
        for (_, paneView) in paneViews {
            paneView.setTerminalViewportSyncSuspended(true)
        }
        applyZoom(animated: animated, centerOnPaneID: centerOnPaneID)
    }

    /// Prepares an empty neighbor preview strip before its first render so
    /// newly mounted runtime host views inherit viewport-sync suspension while
    /// they are being reparented into the preview carrier.
    func preparePeekNeighborZoomOut(scale: CGFloat) {
        guard !isDragActive, !isZoomedOut else { return }
        isZoomedOut = true
        zoomOutScaleOverride = scale
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborPrepareZoomOut,
            context: TerminalViewportDiagnostics.Context(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut,
                note: "scale=\(scale)"
            )
        )
    }

    /// Variant of `beginPeekZoomOut` for **neighbor preview lanes**:
    /// puts the strip into the same internal zoom-out state synchronously.
    /// Neighbor panes still suspend physical viewport sync so Ghostty keeps
    /// the active-worklane grid while the preview carrier repositions them.
    func enterPeekNeighborZoomOut(scale: CGFloat, centerOnPaneID: PaneID? = nil) {
        guard !isDragActive else { return }
        if !isZoomedOut {
            isZoomedOut = true
        }
        zoomOutScaleOverride = scale
        setZoomedOutPaneBackdropsVisible(true, animated: false)
        for (_, paneView) in paneViews {
            paneView.configureViewportDiagnostics(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
            paneView.setTerminalViewportSyncSuspended(true)
        }
        applyZoom(animated: false, centerOnPaneID: centerOnPaneID)
    }

    /// Synchronously leave neighbor peek state. Neighbor carriers are torn
    /// down immediately on close/commit, so they cannot use the delayed
    /// unsuspend path from the animated active-strip zoom-in.
    func endPeekNeighborZoomOut() {
        guard isZoomedOut else { return }
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborEndZoomOut,
            context: TerminalViewportDiagnostics.Context(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        )
        isZoomedOut = false
        zoomOutScaleOverride = nil
        dragScrollOffsetX = 0
        applyZoomScale(1)
        onZoomTransformChanged?()
        setZoomedOutPaneBackdropsVisible(false, animated: false)
        for (_, paneView) in paneViews {
            paneView.configureViewportDiagnostics(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
            paneView.setTerminalViewportSyncSuspended(false)
        }
    }

    /// Tear down a neighbor preview carrier without publishing its temporary
    /// geometry back to the terminal engine.
    func abandonPeekNeighborZoomOutForTeardown() {
        guard isZoomedOut else { return }
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborAbandonZoomOut,
            context: TerminalViewportDiagnostics.Context(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        )
        zoomSpring.stop()
        isZoomedOut = false
        zoomOutScaleOverride = nil
        dragScrollOffsetX = 0
        applyZoomScale(1)
        onZoomTransformChanged?()
        setZoomedOutPaneBackdropsVisible(false, animated: false)
        for (_, paneView) in paneViews {
            paneView.configureViewportDiagnostics(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        }
    }

    /// While zoomed out, animate `dragScrollOffsetX` so the given pane's
    /// column ends up at the horizontal center of the viewport. No-op when
    /// not currently zoomed.
    func centerPeekOnPane(_ paneID: PaneID, animated: Bool = true) {
        guard isZoomedOut else { return }
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborCenterOnPane,
            context: TerminalViewportDiagnostics.Context(
                paneID: paneID,
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        )
        applyZoom(animated: animated, centerOnPaneID: paneID)
    }

    /// While zoomed out, return the horizontal peek camera to a neutral
    /// full-canvas view. Neighbor preview lanes use this whenever they are
    /// visible but not selected, so a stale pane-centering offset cannot clip
    /// split panes against the carrier mask.
    func resetPeekHorizontalCentering() {
        guard isZoomedOut else { return }
        TerminalViewportDiagnostics.shared.record(
            .peekNeighborResetFullCanvas,
            context: TerminalViewportDiagnostics.Context(
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        )
        zoomSpring.stop()
        zoomAnchor = CGPoint(x: viewportView.frame.width / 2, y: viewportView.frame.height / 2)
        dragScrollOffsetX = 0
        applyZoomScale(currentZoomScale())
        onZoomTransformChanged?()
    }

    private func setZoomedOutPaneBackdropsVisible(_ visible: Bool, animated: Bool) {
        let duration = animated ? Self.zoomAnimationDuration : ZenttyTheme.animationDuration
        for (_, paneView) in paneViews {
            paneView.setZoomedOutBackdropVisible(
                visible,
                animated: animated,
                animationDuration: duration
            )
        }
    }

    /// Reverse `beginPeekZoomOut`. Pairs the zoom-in animation with a
    /// deferred un-suspend so the terminal re-syncs its viewport to the new
    /// (full) pixel size only after the animation settles.
    ///
    /// `centerOnPaneID`, if provided, is recorded for diagnostics. The
    /// zoom-in always lands on the natural unscrolled origin so temporary
    /// peek centering cannot leak into the normal pane-strip layout.
    func endPeekZoomIn(animated: Bool = true, centerOnPaneID: PaneID? = nil) {
        guard isZoomedOut else { return }
        TerminalViewportDiagnostics.shared.record(
            .activeZoomIn,
            context: TerminalViewportDiagnostics.Context(
                paneID: centerOnPaneID,
                worklaneID: viewportDiagnosticsWorklaneID,
                laneRole: viewportDiagnosticsLaneRole,
                isZoomedOut: isZoomedOut
            )
        )
        isZoomedOut = false
        applyZoom(animated: animated, centerOnPaneID: centerOnPaneID)
        // Reset so the next drag-zoom (or another peek session)
        // starts from the canonical static scale unless explicitly overridden.
        zoomOutScaleOverride = nil

        let unfreezeDelay: TimeInterval = animated ? Self.zoomAnimationDuration : 0
        let deferredWorkGeneration = self.deferredWorkGeneration
        if !animated {
            setZoomedOutPaneBackdropsVisible(false, animated: false)
            for (_, paneView) in paneViews {
                paneView.configureViewportDiagnostics(
                    worklaneID: viewportDiagnosticsWorklaneID,
                    laneRole: viewportDiagnosticsLaneRole,
                    isZoomedOut: isZoomedOut
                )
                TerminalViewportDiagnostics.shared.record(
                    .activeZoomInUnsuspend,
                    context: TerminalViewportDiagnostics.Context(
                        paneID: paneView.paneID,
                        worklaneID: viewportDiagnosticsWorklaneID,
                        laneRole: viewportDiagnosticsLaneRole,
                        isZoomedOut: isZoomedOut
                    )
                )
                paneView.setTerminalViewportSyncSuspended(false)
            }
            return
        }
        setZoomedOutPaneBackdropsVisible(false, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + unfreezeDelay) { [weak self] in
            guard let self,
                  deferredWorkGeneration == self.deferredWorkGeneration,
                  !self.isZoomedOut
            else { return }
            for (_, paneView) in self.paneViews {
                paneView.configureViewportDiagnostics(
                    worklaneID: self.viewportDiagnosticsWorklaneID,
                    laneRole: self.viewportDiagnosticsLaneRole,
                    isZoomedOut: self.isZoomedOut
                )
                TerminalViewportDiagnostics.shared.record(
                    .activeZoomInUnsuspend,
                    context: TerminalViewportDiagnostics.Context(
                        paneID: paneView.paneID,
                        worklaneID: self.viewportDiagnosticsWorklaneID,
                        laneRole: self.viewportDiagnosticsLaneRole,
                        isZoomedOut: self.isZoomedOut
                    )
                )
                paneView.setTerminalViewportSyncSuspended(false)
            }
        }
    }

    /// Called by PaneDragCoordinator after drop/cancel to trigger zoom-in.
    func endDragWithZoomIn() {
        guard isZoomedOut else { return }
        isZoomedOut = false
        setZoomedOutPaneBackdropsVisible(false, animated: true)
        updateZoomAnchor()
        // Animate scroll back to 0 alongside the zoom-in
        let targetScale: CGFloat = 1.0
        let fromScale = currentZoomScale()
        let fromScrollX = dragScrollOffsetX
        let toScrollX: CGFloat = 0

        zoomSpring.start(duration: Self.zoomAnimationDuration) { [weak self] eased in
            guard let self else { return }
            let scale = fromScale + (targetScale - fromScale) * eased
            self.dragScrollOffsetX = fromScrollX + (toScrollX - fromScrollX) * eased
            self.applyZoomScale(scale)
            if self.isDragActive {
                self.dragCoordinator.updateDraggedPanePosition(zoomScale: scale)
            }
        } complete: { [weak self] in
            guard let self else { return }
            self.dragScrollOffsetX = toScrollX
            self.applyZoomScale(targetScale)
            if self.isDragActive {
                self.dragCoordinator.updateDraggedPanePosition(zoomScale: targetScale)
                self.dragCoordinator.recheckEdgeScroll()
            }
        }

        let unfreezeDelay: TimeInterval = Self.zoomAnimationDuration + 0.05
        let deferredWorkGeneration = self.deferredWorkGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + unfreezeDelay) { [weak self] in
            guard let self,
                  deferredWorkGeneration == self.deferredWorkGeneration,
                  !self.isZoomedOut else { return }

            // Restore viewport autoresizing (was disabled by the drag coordinator)
            self.viewportView.autoresizingMask = [.width, .height]

            // Unfreeze and unsuspend all terminals
            for (_, paneView) in self.paneViews {
                paneView.endVerticalFreeze()
                paneView.setTerminalViewportSyncSuspended(false)
            }

            // Re-render at correct layout. syncFocusedTerminal (called
            // inside renderCurrentState) now uses retry-until-success, so
            // focus will land on the correct pane once it's ready.
            if let state = self.currentState {
                self.renderCurrentState(state, animated: false)
                self.focusCurrentPaneIfNeeded()
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
        cancelPendingHoverFocus()
        dividerDragSuspendedPaneIDs = Set(currentState?.panes.map(\.id) ?? [])
        applyViewportSyncSuspension(to: [])
        installDividerDragEscapeMonitorIfNeeded()
        updateDividerHighlightStates()
    }

    private func endDividerDrag() {
        // Absorb any phantom `dragScrollOffsetX` into `currentOffset` via a
        // next-render `.shiftBy` override so the visual state matches the
        // logical state after the drag ends. Without this, a non-zero
        // `dragScrollOffsetX` would survive drag-end (and worklane switches),
        // making the first pane drift off the viewport edge or leaving an
        // empty gap after a shrink.
        if abs(dragScrollOffsetX) > 0.001 {
            let phantom = dragScrollOffsetX
            dragScrollOffsetX = 0
            applyCurrentZoom()
            pendingTargetOffsetOverride = .shiftBy(phantom)
            if let state = currentState {
                renderCurrentState(state, animated: false)
            }
        }
        dividerDragSession = nil
        dividerDragCumulativeAppliedWidthDelta = 0
        dividerDragSuspendedPaneIDs = []
        removeDividerDragEscapeMonitor()
        activeDivider = nil
        applyViewportSyncSuspension(to: [])
        refreshHoveredDividerFromPointer()
    }

    private func cancelDividerDrag() {
        if let dividerDragSession {
            onPaneStripStateRestoreRequested?(dividerDragSession.initialState)
            if abs(dragScrollOffsetX - dividerDragSession.initialScrollOffsetX) > 0.001 {
                dragScrollOffsetX = dividerDragSession.initialScrollOffsetX
                applyCurrentZoom()
            }
        }
        endDividerDrag()
    }

    /// Runs one pointer-delta step of a divider drag. The "anchor opposite
    /// edge" scroll compensation (see `applyDividerDragScrollCompensation`)
    /// can push `dragScrollOffsetX` negative far enough to separate the
    /// leftmost pane from the viewport's left edge. When continuing to shrink
    /// would cross that floor, this issues a second opposing resize so the
    /// net column-width change stalls at the limit — the divider "sticks"
    /// like hitting a min-width, and no visible overshoot appears.
    private func performDividerResize(target: PaneResizeTarget, delta: CGFloat) {
        let appliedWidthDelta = onDividerResizeRequested?(target, delta) ?? 0
        let netAppliedWidthDelta = appliedWidthDelta
            + counterResizeForOvershoot(
                target: target,
                appliedWidthDelta: appliedWidthDelta
            )
        applyDividerDragScrollCompensation(
            target: target,
            appliedWidthDelta: netAppliedWidthDelta
        )
    }

    /// Returns the width delta of a corrective resize that should be applied
    /// in the same frame to keep `dragScrollOffsetX + currentOffset >= 0`
    /// (i.e. the leftmost pane stays flush with the viewport's left edge).
    /// Returns 0 when no correction is needed or when the target isn't a
    /// left-edge compensation candidate.
    private func counterResizeForOvershoot(
        target: PaneResizeTarget,
        appliedWidthDelta: CGFloat
    ) -> CGFloat {
        guard case .horizontalEdge(let horizontalTarget) = target,
              horizontalTarget.edge == .left,
              let session = dividerDragSession,
              let currentState,
              let columnIndex = currentState.columns.firstIndex(where: { $0.id == horizontalTarget.columnID }),
              columnIndex + 1 < currentState.columns.count
        else {
            return 0
        }

        let projectedCumulative = dividerDragCumulativeAppliedWidthDelta + appliedWidthDelta
        // Floor derived from `visible_first_pane_left_edge <= leadingVisibleInset`
        // (the sidebar's right edge is where the first pane should stay
        // flush, not x=0). Substituting the slack formula, `currentOffset`
        // cancels and the remaining terms are all frozen at drag start.
        let cumulativeFloor = -resolvedLeadingVisibleInset
            - session.initialScrollOffsetX
            - session.initialCurrentOffset

        guard projectedCumulative < cumulativeFloor else {
            return 0
        }

        // `.horizontalEdge(.left)` negates the raw delta before applying
        // (PaneStripState: `widthDelta = target.edge == .right ? delta : -delta`).
        // To grow the column back by `revert`, pass raw delta `-revert`.
        let revert = cumulativeFloor - projectedCumulative
        return onDividerResizeRequested?(target, -revert) ?? 0
    }

    private func applyDividerDragScrollCompensation(
        target: PaneResizeTarget,
        appliedWidthDelta: CGFloat
    ) {
        guard case .horizontalEdge(let horizontalTarget) = target,
              horizontalTarget.edge == .left,
              let currentState,
              let columnIndex = currentState.columns.firstIndex(where: { $0.id == horizontalTarget.columnID }),
              columnIndex + 1 < currentState.columns.count,
              abs(appliedWidthDelta) > 0.001 else {
            return
        }

        guard let session = dividerDragSession else { return }
        dividerDragCumulativeAppliedWidthDelta += appliedWidthDelta

        // The focused column's right edge moves right by
        // `dividerDragCumulativeAppliedWidthDelta` as the column grows. To
        // anchor that edge visually, the total content → viewport shift must
        // grow by the same amount. That shift is split between `currentOffset`
        // (which `preferredTargetOffset` advances whenever the focused pane
        // would otherwise leave the viewport) and `dragScrollOffsetX` (this
        // layer). Assign only the slack `preferredTargetOffset` hasn't already
        // absorbed — otherwise both shift by the full delta and the divider
        // lags the cursor, pulling the leftmost pane off-screen.
        let layoutOffsetDelta = currentOffset - session.initialCurrentOffset
        let targetDragScrollOffsetX = session.initialScrollOffsetX
            + dividerDragCumulativeAppliedWidthDelta
            - layoutOffsetDelta

        guard abs(targetDragScrollOffsetX - dragScrollOffsetX) > 0.001 else {
            return
        }
        dragScrollOffsetX = targetDragScrollOffsetX
        applyCurrentZoom()
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

    /// Current horizontal scroll offset in content-space. Positive values
    /// mean the content is scrolled leftward (panes live further right in
    /// content space than their on-screen position).
    var currentScrollOffset: CGFloat {
        currentOffset
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

    func cancelDividerDragForTesting() {
        cancelDividerDrag()
    }

    func handleDividerDragDeltaForTesting(_ delta: CGFloat) {
        guard var session = dividerDragSession, abs(delta) > 0.001 else {
            return
        }
        performDividerResize(target: session.target, delta: delta)
        session.lastTranslation += delta
        dividerDragSession = session
    }

    var dragScrollOffsetXForTesting: CGFloat {
        dragScrollOffsetX
    }

    var hasDividerDragEscapeMonitorForTesting: Bool {
        dividerDragEscapeMonitor != nil
    }

    #if DEBUG
        var zoomAnchorForTesting: CGPoint {
            zoomAnchor
        }
    #endif

    var currentOffsetForTesting: CGFloat {
        currentOffset
    }

    func beginPaneDragForTesting(
        paneID: PaneID,
        cursorInStrip: CGPoint
    ) {
        handleDragActivated(paneID: paneID, origin: cursorInStrip)
    }

    func setDuplicateDragEnabledForTesting(_ enabled: Bool) {
        dragCoordinator.setOptionHeldForTesting(enabled)
    }

    func endPaneDragForTesting(cursorInStrip: CGPoint) {
        dragCoordinator.endDrag(at: cursorInStrip)
    }

    func movePaneDragForTesting(cursorInStrip: CGPoint) {
        dragCoordinator.updateCursor(cursorInStrip)
    }

    func satisfySplitDwellForTesting() {
        dragCoordinator.satisfySplitDwellForTesting()
    }

    var splitDragOverlayForTesting: PaneDragSplitOverlayView? {
        dragCoordinator.splitOverlayForTesting
    }

    var dragPreviewBackgroundColorForTesting: NSColor? {
        let hostView = dragOverlayView ?? viewportView
        guard let container = hostView.subviews.reversed().first(where: { $0 is PaneDragFloatingContainer })
        else {
            return nil
        }

        guard let cgColor = container.layer?.backgroundColor else {
            return nil
        }

        return NSColor(cgColor: cgColor)
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
            settleAdjacentPane(
                switchRight: result == .switchRight,
                mouseLocation: mouseLocationForFocusArbitration(from: event)
            )
            return true
        case .consumed:
            return true
        case .none:
            return false
        }
    }

    private func settleAdjacentPane(switchRight: Bool, mouseLocation: NSPoint?) {
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
        requestFocus(
            for: targetColumn.focusedPaneID ?? targetColumn.panes.first?.id ?? focusedPaneID,
            source: .scrollSwitch,
            mouseLocation: mouseLocation
        )
    }

    private func resetScrollSwitchGestureIfFocusChanged(from previousPaneID: PaneID?, to nextPaneID: PaneID?) {
        guard previousPaneID != nextPaneID else {
            return
        }

        cancelScrollSwitchGesture()
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
        switch targetOffsetOverride {
        case .usePresentationTargetOffset:
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
        case .shiftBy(let delta):
            let proposedOffset = previousOffset + delta
            let clamped = motionController.clampedOffset(
                proposedOffset,
                contentWidth: presentation.contentWidth,
                viewportWidth: bounds.width,
                leadingVisibleInset: resolvedLeadingVisibleInset
            )
            return motionController.snappedOffset(
                clamped,
                backingScaleFactor: currentBackingScaleFactor
            )
        case .none:
            break
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            isDetachingFromWindow = true
            cleanupTransientStateForWindowDetachment()
        } else {
            isDetachingFromWindow = false
        }
        super.viewWillMove(toWindow: newWindow)
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
