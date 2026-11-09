import AppKit
import QuartzCore

enum WorklaneTransitionDirection: Equatable, Sendable {
    case up
    case down
}

@MainActor
protocol RenderEnvironmentProviding: AnyObject {
    var renderTheme: ZenttyTheme { get }
    var renderSidebarWidth: CGFloat { get }
    func renderLeadingInset(sidebarWidth: CGFloat) -> CGFloat
    var renderWindowState: (isVisible: Bool, isKeyWindow: Bool) { get }
    func renderSidebarSyncNeeded()
}

@MainActor
protocol WorklaneRenderCoordinatorScheduledHandle: AnyObject {
    func cancel()
}

@MainActor
private final class TimerWorklaneRenderCoordinatorScheduledHandle: WorklaneRenderCoordinatorScheduledHandle {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class WorklaneRenderCoordinator {
    // Internal (not private) so the pure interval-selection logic can be unit-tested.
    enum ReviewPolling {
        /// Cadence while CI checks are actively running (state changes fast).
        static let activeInterval: TimeInterval = 15
        /// Cadence for an open PR with no checks in flight.
        static let idleInterval: TimeInterval = 60
        /// Cadence for a branch with no PR yet — watch for a PR opening.
        static let noPRInterval: TimeInterval = 90
        /// Cadence once the PR is merged/closed; its state rarely changes.
        static let terminalInterval: TimeInterval = 300

        /// Adaptive interval for the next poll, derived from the last-known review state.
        static func interval(for reviewState: WorklaneReviewState?) -> TimeInterval {
            guard let reviewState else {
                return idleInterval
            }
            guard let state = reviewState.pullRequest?.state else {
                // Branch with no PR yet.
                return noPRInterval
            }
            switch state {
            case .merged, .closed:
                return terminalInterval
            case .open, .draft:
                return reviewState.checksState == .running ? activeInterval : idleInterval
            }
        }
    }

    typealias ReviewPollingScheduler = @MainActor (
        _ interval: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any WorklaneRenderCoordinatorScheduledHandle

    struct ViewBindings {
        let sidebarView: SidebarView
        let windowChromeView: WindowChromeView
        let appCanvasView: AppCanvasView
    }

    let worklaneStore: WorklaneStore
    let runtimeRegistry: PaneRuntimeRegistry
    let reviewStateResolver: WorklaneReviewStateResolver
    let windowID: WindowID
    private let terminalDiagnostics: TerminalDiagnostics
    private let configStore: AppConfigStore?

    private let attentionNotificationCoordinator: WorklaneAttentionNotificationCoordinator

    private var views: ViewBindings?
    private var reviewPollingHandle: (any WorklaneRenderCoordinatorScheduledHandle)?
    private var reviewPollingTarget: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)?
    private var hasBootstrappedReviewState = false
    private var needsRuntimeSynchronization = true
    /// A canvas render hit the drag gate and nothing has rendered since. The
    /// strip only re-renders its cached state when the drag ends, so without
    /// this the skipped store change stays invisible until an unrelated render.
    private var canvasRenderDeferredByDrag = false
    private var worklaneStoreSubscription: WorklaneChangeSubscription?
    private let reviewPollingScheduler: ReviewPollingScheduler
    private var previousActiveWorklaneID: WorklaneID?
    /// Canvas motion for animated renders inside `withCanvasMotion`.
    private var canvasMotionOverride: (duration: TimeInterval, timing: CAMediaTimingFunction)?

    weak var environment: RenderEnvironmentProviding?

    /// Worklanes whose surfaces should be kept un-occluded even though they
    /// aren't the active worklane — used by Worklane Peek so neighbor lane
    /// previews keep streaming live instead of freezing on a still frame.
    /// Default returns an empty set (nothing peek-visible).
    var peekVisibleWorklaneIDsProvider: () -> Set<WorklaneID> = { [] }
    /// Minimized panes whose pill peek draws their live terminal: kept
    /// un-occluded while it shows. Default: none.
    var pillPeekedPaneIDsProvider: () -> Set<PaneID> = { [] }
    var sidebarFocusOverrideProvider: () -> WorklaneSidebarFocusOverride? = { nil }

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        worklaneStore: WorklaneStore,
        runtimeRegistry: PaneRuntimeRegistry,
        notificationStore: NotificationStore,
        configStore: AppConfigStore? = nil,
        reviewStateResolver: WorklaneReviewStateResolver = WorklaneReviewStateResolver(),
        reviewPollingScheduler: @escaping ReviewPollingScheduler = WorklaneRenderCoordinator.defaultReviewPollingScheduler,
        terminalDiagnostics: TerminalDiagnostics = .shared
    ) {
        self.windowID = windowID
        self.worklaneStore = worklaneStore
        self.runtimeRegistry = runtimeRegistry
        self.reviewStateResolver = reviewStateResolver
        self.reviewPollingScheduler = reviewPollingScheduler
        self.terminalDiagnostics = terminalDiagnostics
        self.configStore = configStore
        self.attentionNotificationCoordinator = WorklaneAttentionNotificationCoordinator(
            notificationStore: notificationStore,
            configStore: configStore
        )
    }

    deinit {
        MainActorShim.assumeIsolated {
            cancelReviewPolling()
            if let worklaneStoreSubscription {
                worklaneStore.unsubscribe(worklaneStoreSubscription)
            }
        }
    }

    func notificationReplyToken(worklaneID: WorklaneID, paneID: PaneID) -> String? {
        attentionNotificationCoordinator.replyToken(worklaneID: worklaneID, paneID: paneID)
    }

    func bind(to views: ViewBindings) {
        self.views = views
    }

    func startObserving() {
        guard worklaneStoreSubscription == nil else {
            return
        }

        worklaneStoreSubscription = worklaneStore.subscribe { [weak self] change in
            self?.handleWorklaneChange(change)
        }
    }

    // MARK: - Public render API

    func render(animated: Bool = false) {
        renderCurrentWorklane(animated: animated)
    }

    /// Catches the canvas up with store changes the drag held back. Goes
    /// through `renderCurrentWorklane` for its notification-suppression scope.
    func flushCanvasRenderDeferredByDrag() {
        guard canvasRenderDeferredByDrag else {
            return
        }
        renderCurrentWorklane(animated: false)
    }

    func renderCanvas(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        renderCanvasForCurrentWorklane(
            leadingVisibleInsetOverride: leadingVisibleInsetOverride,
            animated: animated,
            duration: duration,
            timingFunction: timingFunction
        )
    }

    /// Runs `body` (a store change) so every animated canvas render it
    /// triggers uses `duration`/`timing`. A float op notifies `.paneStructure`
    /// before `.floats`, so the strip reflow happens in the first render; this
    /// gives all of them the same curve.
    func withCanvasMotion(
        duration: TimeInterval,
        timing: CAMediaTimingFunction,
        _ body: () -> Void
    ) {
        let previous = canvasMotionOverride
        canvasMotionOverride = (duration, timing)
        defer { canvasMotionOverride = previous }
        body()
    }

    func updateSurfaceActivities() {
        updateReviewPolling()
        updateRuntimeSurfaceActivities()
    }

    func renderSidebar() {
        guard let views else {
            return
        }

        renderSidebar(in: views)
    }

    #if DEBUG
    var reviewPollingTargetForTesting: (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)? {
        reviewPollingTarget
    }
    #endif

    // MARK: - Internal

    private var currentTheme: ZenttyTheme {
        environment?.renderTheme ?? ZenttyTheme.fallback(for: nil)
    }

    private var activePaneID: PaneID? {
        worklaneStore.activeWorklane?.focusedPaneID
    }

    private func renderSidebar(in views: ViewBindings) {
        terminalDiagnostics.recordRender(.sidebar, activePaneID: activePaneID)
        views.sidebarView.render(
            summaries: WorklaneSidebarSummaryBuilder.summaries(
                for: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                focusOverride: sidebarFocusOverrideProvider(),
                serverContextsByWorklaneID: serverContextsByWorklaneID(),
                // `show_overlays` now hides temporary (overlay) floats only.
                showsTemporaryFloats: configStore?.current.sidebar.showOverlays ?? true
            ),
            theme: currentTheme
        )
        environment?.renderSidebarSyncNeeded()
    }

    private func serverContextsByWorklaneID() -> [WorklaneID: WorklaneServerContext] {
        Dictionary(
            uniqueKeysWithValues: worklaneStore.worklanes.map { worklane in
                (worklane.id, worklaneStore.serverContext(for: worklane.id))
            }
        )
    }

    private func handleWorklaneChange(_ change: WorklaneChange) {
        switch change {
        case .paneStructure:
            needsRuntimeSynchronization = true
            renderCurrentWorklane(animated: true)
            updateRuntimeSurfaceActivities()
        case .floats:
            needsRuntimeSynchronization = true
            let motion = canvasMotionOverride ?? FloatMotion.reflowMotion
            renderCurrentWorklane(animated: true, duration: motion.duration, timingFunction: motion.timing)
            updateRuntimeSurfaceActivities()
        case .focusChanged:
            renderCurrentWorklane(animated: true)
            updateRuntimeSurfaceActivities()
        case .layoutResized(_, let animation):
            renderCurrentWorklane(animated: animation == .splitCurve)
        case .worklaneListChanged:
            needsRuntimeSynchronization = true
            renderCurrentWorklane(animated: false)
            updateRuntimeSurfaceActivities()
            bootstrapReviewRefresh(force: true)
        case .activeWorklaneChanged:
            renderCurrentWorklane(animated: true)
            updateRuntimeSurfaceActivities()
            bootstrapReviewRefresh(force: true)
        case .auxiliaryStateUpdated(let worklaneID, let paneID, let impacts):
            handleAuxiliaryStateUpdate(worklaneID: worklaneID, paneID: paneID, impacts: impacts)
        case .volatileAgentTitleUpdated(let worklaneID, let paneID):
            handleVolatileAgentTitleUpdate(worklaneID: worklaneID, paneID: paneID)
        case .teamAnchorsChanged(let worklaneID):
            if worklaneID == worklaneStore.activeWorklaneID {
                renderCanvasForCurrentWorklane(animated: false)
            }
        case .historyChanged:
            break
        }
    }

    private func handleVolatileAgentTitleUpdate(
        worklaneID: WorklaneID,
        paneID: PaneID
    ) {
        guard let views,
              let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }),
              let pane = worklane.pane(id: paneID),
              PaneDisplayIdentityResolver.hasCustomTitle(for: pane) == false,
              let metadata = worklane.auxiliaryStateByPaneID[paneID]?.metadata,
              let titleText = WorklaneContextFormatter.trimmed(metadata.title)
        else {
            return
        }

        views.sidebarView.setVolatilePaneTitle(
            worklaneID: worklaneID,
            paneID: paneID,
            text: titleText
        )

        if worklaneID == worklaneStore.activeWorklaneID,
           worklane.focusedPaneID == paneID {
            views.windowChromeView.setFocusedLabelText(titleText)
        }
    }

    private func renderCurrentWorklane(
        animated: Bool = false,
        duration: TimeInterval? = nil,
        timingFunction: CAMediaTimingFunction? = nil
    ) {
        ZenttyPerformanceSignposts.interval("WorklaneRenderCurrent") {
            guard let views else {
                return
            }

            let previousID = previousActiveWorklaneID
            let currentID = worklaneStore.activeWorklaneID
            previousActiveWorklaneID = currentID

            var transitionDirection: WorklaneTransitionDirection? = nil
            if animated, let previousID, previousID != currentID {
                let worklanes = worklaneStore.worklanes
                if let prevIndex = worklanes.firstIndex(where: { $0.id == previousID }),
                   let currIndex = worklanes.firstIndex(where: { $0.id == currentID }) {
                    transitionDirection = currIndex > prevIndex ? .down : .up
                }
            }

            terminalDiagnostics.recordRender(.full, activePaneID: activePaneID)
            // Renders, not mutations: this must drop any synchronous
            // notification the render tree raises (re-entrancy guard), not
            // replay it via batchUpdate's coalesce-and-flush semantics.
            worklaneStore.withNotificationsSuppressed { [self] in
                if needsRuntimeSynchronization {
                    runtimeRegistry.synchronize(with: worklaneStore.worklanes)
                    needsRuntimeSynchronization = false
                }
                renderSidebar(in: views)

                guard let worklane = worklaneStore.activeWorklane else {
                    terminalDiagnostics.recordRender(.header, activePaneID: activePaneID)
                    renderWindowChrome(
                        WorklaneChromeSummary(
                        focusedLabel: nil,
                        branch: nil,
                        pullRequest: nil,
                        reviewChips: []
                        ),
                        in: views
                    )
                    return
                }

                let headerSummary = WorklaneHeaderSummaryBuilder.summary(for: worklane)
                terminalDiagnostics.recordRender(.header, activePaneID: activePaneID)
                renderWindowChrome(headerSummary, in: views)
                let motion = canvasMotionOverride
                renderCanvasForCurrentWorklane(
                    animated: animated,
                    transitionDirection: transitionDirection,
                    duration: duration ?? motion?.duration ?? PaneStripMotionController.defaultAnimationDuration,
                    timingFunction: timingFunction
                        ?? motion?.timing
                        ?? PaneStripMotionController.defaultAnimationTimingFunction
                )
                let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
                attentionNotificationCoordinator.update(
                    windowID: windowID,
                    worklanes: worklaneStore.worklanes,
                    activeWorklaneID: worklaneStore.activeWorklaneID,
                    windowIsKey: windowState.isKeyWindow
                )
                updateReviewPolling()
            }
            bootstrapReviewRefresh(force: false)
        }
    }

    private func renderCanvasForCurrentWorklane(
        leadingVisibleInsetOverride: CGFloat? = nil,
        animated: Bool = false,
        transitionDirection: WorklaneTransitionDirection? = nil,
        duration: TimeInterval = PaneStripMotionController.defaultAnimationDuration,
        timingFunction: CAMediaTimingFunction = PaneStripMotionController.defaultAnimationTimingFunction
    ) {
        ZenttyPerformanceSignposts.interval("WorklaneRenderCanvas") {
            guard let views, let worklane = worklaneStore.activeWorklane else {
                return
            }

            guard !views.appCanvasView.paneStripView.isDragActive
                  || views.appCanvasView.paneStripView.isDropSettling else {
                canvasRenderDeferredByDrag = true
                return
            }
            canvasRenderDeferredByDrag = false

            let sidebarWidth = environment?.renderSidebarWidth ?? SidebarWidthPreference.defaultWidth
            let effectiveInset = leadingVisibleInsetOverride
                ?? environment?.renderLeadingInset(sidebarWidth: sidebarWidth)
                ?? 0
            let config = configStore?.current ?? .default
            let paneSettings = config.panes
            let paneLayout = config.paneLayout
            let focusFollowsMouseEnabled = paneSettings.focusFollowsMouse
                && paneLayout.allowsFocusFollowsMouse

            terminalDiagnostics.recordRender(.canvas, activePaneID: worklane.focusedPaneID)
            let teamAnchor = worklaneStore.teamAnchorByWorklaneID[worklane.id]
            let leaderPaneID = teamAnchor.map { PaneID($0.leaderPaneID) }
            let memberPaneIDs: Set<PaneID> = teamAnchor
                .map { Set($0.columnPaneIDs.map(PaneID.init)) }
                ?? []
            let paneBorderContextByPaneID = worklane.paneBorderContextDisplayByPaneID(
                leaderPaneID: leaderPaneID,
                memberPaneIDs: memberPaneIDs
            )
            views.appCanvasView.render(
                state: worklane.paneStripState,
                floats: FloatLayerContent(
                    worklane: worklane,
                    borderContextByPaneID: paneBorderContextByPaneID
                ),
                pills: PillBarContent(worklane: worklane),
                metadataByPaneID: worklane.auxiliaryStateByPaneID.compactMapValues(\.metadata),
                paneBorderContextByPaneID: paneBorderContextByPaneID,
                showsPaneLabels: paneSettings.showLabels,
                inactivePaneOpacity: paneSettings.inactiveOpacity,
                smoothScrollingEnabled: paneSettings.smoothScrollingEnabled,
                showPaneBorders: paneSettings.showBorders,
                focusFollowsMouseEnabled: focusFollowsMouseEnabled,
                focusFollowsMouseDelay: paneSettings.focusFollowsMouseDelay,
                worklaneColor: worklane.color,
                theme: currentTheme,
                leadingVisibleInset: effectiveInset,
                animated: animated,
                transitionDirection: transitionDirection,
                duration: duration,
                timingFunction: timingFunction
            )
        }
    }

    private func updateRuntimeSurfaceActivities() {
        ZenttyPerformanceSignposts.interval("WorklaneUpdateSurfaceActivities") {
            guard !worklaneStore.worklanes.isEmpty else {
                return
            }

            let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
            runtimeRegistry.updateSurfaceActivities(
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsVisible: windowState.isVisible,
                windowIsKey: windowState.isKeyWindow,
                peekVisibleWorklaneIDs: peekVisibleWorklaneIDsProvider(),
                pillPeekedPaneIDs: pillPeekedPaneIDsProvider()
            )
        }
    }

    private func updateReviewPolling() {
        guard let target = makeReviewPollingTarget() else {
            reviewPollingTarget = nil
            cancelReviewPolling()
            return
        }

        let previous = reviewPollingTarget
        let worklaneChanged = previous?.worklaneID != target.worklaneID
        let paneChanged = previous?.paneID != target.paneID
        let targetChanged = worklaneChanged || paneChanged
            || previous?.repoRoot != target.repoRoot
            || previous?.branch != target.branch

        reviewPollingTarget = target
        if targetChanged || reviewPollingHandle == nil {
            armReviewPoll(after: ReviewPolling.interval(for: currentTargetReviewState()))
        }

        // Focus moved to a *different pane in the same worklane*. The other target-change triggers
        // already fetch their case — worklane switches bootstrap, branch/agent changes hit
        // `.reviewRefresh`, and window refocus has its own hook — but this one has none, so the new
        // pane's badge would sit stale until the adaptive timer fires (up to 300s). Refresh it now,
        // cache-respecting so rapid pane cycling reuses fresh data instead of a `gh` call per switch.
        if previous != nil, !worklaneChanged, paneChanged, hasBootstrappedReviewState {
            refreshReviewState(for: target.worklaneID, paneID: target.paneID, forceReload: false)
        }
    }

    /// Force-refreshes the current poll target and re-arms the next poll from the FRESH result,
    /// so the adaptive cadence reflects the state we just fetched (fast while CI runs, slow when
    /// terminal). A provisional arm from the last-known state is set first so a dropped completion
    /// can never stall the loop.
    private func performAdaptiveReviewPoll() {
        guard let target = reviewPollingTarget else {
            return
        }

        // Keep the loop alive immediately using the last-known cadence; the completion below
        // replaces this with the fresh cadence once the fetch lands.
        armReviewPoll(after: ReviewPolling.interval(for: currentTargetReviewState()))

        reviewStateResolver.refreshPane(
            repoRoot: target.repoRoot,
            branch: target.branch,
            paneID: target.paneID,
            forceReload: true
        ) { [weak self] paneID, resolution in
            // `applyReviewResolution` re-arms from the fresh result when this pane is still the
            // active target, so the cadence tracks the just-fetched CI state. It drops the result if
            // the pane switched repo/branch mid-flight, so a stale poll can't clobber the new target.
            self?.applyReviewResolution(
                paneID: paneID,
                resolution: resolution,
                fetchedRepoRoot: target.repoRoot,
                fetchedBranch: target.branch
            )
        }
    }

    /// Arms the single-shot timer for the next poll. On fire it runs another adaptive poll, which
    /// re-arms in turn — an adaptive loop without a repeating timer. Cancels any prior handle
    /// before replacing it so there is always exactly one live poll handle.
    private func armReviewPoll(after interval: TimeInterval) {
        reviewPollingHandle?.cancel()
        reviewPollingHandle = reviewPollingScheduler(interval) { [weak self] in
            guard let self else {
                return
            }
            // Do not nil the handle here: production timer fires hop through MainActor, and a
            // re-arm may have replaced the handle in that gap. Nilling would orphan the replacement
            // without cancelling it; the poll's next arm cancels whichever handle is current.
            self.performAdaptiveReviewPoll()
        }
    }

    private func currentTargetReviewState() -> WorklaneReviewState? {
        guard
            let target = reviewPollingTarget,
            let worklane = worklaneStore.worklanes.first(where: { $0.id == target.worklaneID }),
            let auxiliaryState = worklane.auxiliaryStateByPaneID[target.paneID]
        else {
            return nil
        }
        return auxiliaryState.reviewState
    }

    private func cancelReviewPolling() {
        reviewPollingHandle?.cancel()
        reviewPollingHandle = nil
    }

    /// Refresh when this window regains key focus. Only the key window polls, so a background
    /// window's badge freezes while inactive; refresh it on refocus — cache-respecting, so hopping
    /// between windows with still-fresh data doesn't fire a `gh` call each time. No-op until the
    /// first bootstrap has run, so it never doubles the initial load's fetch.
    func refreshFocusedReviewStateOnWindowFocus() {
        guard hasBootstrappedReviewState else {
            return
        }
        refreshFocusedReviewState(forceReload: false)
    }

    private static func defaultReviewPollingScheduler(
        interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any WorklaneRenderCoordinatorScheduledHandle {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                operation()
            }
        }
        return TimerWorklaneRenderCoordinatorScheduledHandle(timer: timer)
    }

    private func makeReviewPollingTarget() -> (worklaneID: WorklaneID, paneID: PaneID, repoRoot: String, branch: String)? {
        let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
        guard windowState.isVisible, windowState.isKeyWindow,
              let worklane = worklaneStore.activeWorklane,
              let paneID = worklane.focusedPaneID,
              let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              let repoRoot = auxiliaryState.presentation.repoRoot,
              let branch = auxiliaryState.presentation.lookupBranch
        else {
            return nil
        }

        return (
            worklaneID: worklane.id,
            paneID: paneID,
            repoRoot: repoRoot,
            branch: branch
        )
    }

    private func handleAuxiliaryStateUpdate(
        worklaneID: WorklaneID,
        paneID: PaneID,
        impacts: WorklaneAuxiliaryInvalidation
    ) {
        guard let views else {
            return
        }

        if impacts.contains(.sidebar) || impacts.contains(.serverDetection) {
            if impacts.contains(.serverDetection) {
                ZenttyBreadcrumbs.record(
                    category: "zentty.render.sidebar",
                    data: [
                        "serverDetection": true,
                    ]
                )
            }
            renderSidebar(in: views)
        }

        if impacts.contains(.header) {
            renderHeader()
        }

        if impacts.contains(.canvas),
           worklaneID == worklaneStore.activeWorklaneID {
            renderCanvasForCurrentWorklane(animated: false)
        } else if worklaneID == worklaneStore.activeWorklaneID,
                  let worklane = worklaneStore.activeWorklane,
                  let mode = worklane.floatingPane(id: paneID)?.mode {
            // A pill's or PiP's status dot, name and cwd follow its pane's
            // state without a canvas render.
            switch mode {
            case .minimized:
                views.appCanvasView.updatePills(PillBarContent(worklane: worklane))
            case .pip:
                views.appCanvasView.floatLayerView.updatePipStatuses(FloatLayerContent.pipStatuses(worklane: worklane))
            case .floating:
                break
            }
        }

        if impacts.contains(.attention) {
            let windowState = environment?.renderWindowState ?? (isVisible: false, isKeyWindow: false)
            attentionNotificationCoordinator.update(
                windowID: windowID,
                worklanes: worklaneStore.worklanes,
                activeWorklaneID: worklaneStore.activeWorklaneID,
                windowIsKey: windowState.isKeyWindow
            )
        }

        if impacts.contains(.reviewRefresh) {
            updateReviewPolling()
            refreshReviewState(for: worklaneID, paneID: paneID, forceReload: true)
        }

        if impacts.contains(.surfaceActivities) {
            updateRuntimeSurfaceActivities()
        }
    }

    private func renderHeader() {
        guard let views else {
            return
        }

        guard let worklane = worklaneStore.activeWorklane else {
            renderWindowChrome(
                WorklaneChromeSummary(
                focusedLabel: nil,
                branch: nil,
                pullRequest: nil,
                reviewChips: []
                ),
                in: views
            )
            return
        }

        renderWindowChrome(WorklaneHeaderSummaryBuilder.summary(for: worklane), in: views)
    }

    private func renderWindowChrome(_ summary: WorklaneChromeSummary, in views: ViewBindings) {
        views.windowChromeView.render(summary: summary)
    }

    private func bootstrapReviewRefresh(force: Bool) {
        guard force || !hasBootstrappedReviewState else {
            return
        }

        hasBootstrappedReviewState = true
        // Capture each pane's lookup target so an out-of-order result can be rejected if the pane
        // switched repo/branch before its `gh` lookup returned (same guard the poll/refresh paths use).
        var fetchedTargets: [PaneID: (repoRoot: String, branch: String)] = [:]
        for worklane in worklaneStore.worklanes {
            for (paneID, auxiliaryState) in worklane.auxiliaryStateByPaneID {
                if let repoRoot = auxiliaryState.presentation.repoRoot,
                   let branch = auxiliaryState.presentation.lookupBranch {
                    fetchedTargets[paneID] = (repoRoot, branch)
                }
            }
        }
        reviewStateResolver.refresh(for: worklaneStore.worklanes) { [weak self] paneID, resolution in
            let fetchedTarget = fetchedTargets[paneID]
            self?.applyReviewResolution(
                paneID: paneID,
                resolution: resolution,
                fetchedRepoRoot: fetchedTarget?.repoRoot,
                fetchedBranch: fetchedTarget?.branch
            )
        }
    }

    /// Refreshes the focused pane's PR status. Backs the manual "Refresh PR Status" command and the
    /// badge's right-click menu (`forceReload: true`, bypassing the TTL cache) as well as the
    /// window-refocus hook (`forceReload: false`, reusing still-fresh cache).
    func refreshFocusedReviewState(forceReload: Bool = true) {
        guard
            let worklane = worklaneStore.activeWorklane,
            let paneID = worklane.focusedPaneID
        else {
            return
        }
        refreshReviewState(for: worklane.id, paneID: paneID, forceReload: forceReload)
    }

    private func refreshReviewState(
        for worklaneID: WorklaneID,
        paneID: PaneID,
        forceReload: Bool = false
    ) {
        guard
            let worklane = worklaneStore.worklanes.first(where: { $0.id == worklaneID }),
            let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
            let repoRoot = auxiliaryState.presentation.repoRoot,
            let branch = auxiliaryState.presentation.lookupBranch
        else {
            return
        }

        reviewStateResolver.refreshPane(
            repoRoot: repoRoot,
            branch: branch,
            paneID: paneID,
            forceReload: forceReload
        ) { [weak self] paneID, resolution in
            self?.applyReviewResolution(
                paneID: paneID,
                resolution: resolution,
                fetchedRepoRoot: repoRoot,
                fetchedBranch: branch
            )
        }
    }

    /// Applies a fetched resolution to the store and, when the pane is the active poll target,
    /// re-aligns the adaptive cadence to the freshly-fetched state. Every review fetch — the poll,
    /// bootstrap, `.reviewRefresh`, focus-regain, and manual refresh — funnels through here so the
    /// cadence tracks the latest CI state immediately instead of only after the next poll fires.
    ///
    /// `fetchedRepoRoot`/`fetchedBranch` identify the exact target the fetch was issued for. When
    /// provided, a completion is dropped if the pane has since moved to a different repo/branch, so a
    /// slow, out-of-order fetch can neither overwrite fresher state nor arm the poll from a stale
    /// target (e.g. a merged old PR pushing the next poll out to 300s after a branch switch).
    private func applyReviewResolution(
        paneID: PaneID,
        resolution: WorklaneReviewResolution,
        fetchedRepoRoot: String? = nil,
        fetchedBranch: String? = nil
    ) {
        if let fetchedRepoRoot, let fetchedBranch,
           !paneMatches(paneID: paneID, repoRoot: fetchedRepoRoot, branch: fetchedBranch) {
            return
        }
        worklaneStore.updateReviewResolution(paneID: paneID, resolution: resolution)
        if reviewPollingTarget?.paneID == paneID {
            armReviewPoll(after: ReviewPolling.interval(for: resolution.reviewState))
        }
    }

    /// Whether the pane still resolves to the given repo/branch — used to reject out-of-order
    /// review fetches whose target changed while the request was in flight.
    private func paneMatches(paneID: PaneID, repoRoot: String, branch: String) -> Bool {
        for worklane in worklaneStore.worklanes {
            guard let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
                continue
            }
            return auxiliaryState.presentation.repoRoot == repoRoot
                && auxiliaryState.presentation.lookupBranch == branch
        }
        return false
    }
}
