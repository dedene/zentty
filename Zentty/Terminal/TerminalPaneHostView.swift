import AppKit
import Foundation
import os

@MainActor
final class TerminalPaneHostView: NSView {
    private let adapter: any TerminalAdapter
    private let terminalView: NSView
    private let searchHUDView = PaneSearchHUDView()
    private var hasStartedSession = false
    private var lastRenderedSearchState = PaneSearchState()

    private var searchHUDContainerView: NSView {
        (terminalView as? any TerminalOverlayHosting)?.terminalOverlayHostView ?? self
    }

    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {
            adapter.metadataDidChange = onMetadataDidChange
        }
    }
    var onEventDidOccur: ((TerminalEvent) -> Void)? {
        didSet {
            adapter.eventDidOccur = onEventDidOccur
        }
    }
    var onFocusDidChange: ((Bool) -> Void)? {
        didSet {
            assert(onFocusDidChange == nil || terminalView is any TerminalFocusReporting,
                   "terminalView must conform to TerminalFocusReporting to forward onFocusDidChange")
            (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        }
    }
    var onScrollWheel: ((NSEvent) -> Bool)? {
        didSet {
            assert(onScrollWheel == nil || terminalView is any TerminalScrollRouting,
                   "terminalView must conform to TerminalScrollRouting to forward onScrollWheel")
            (terminalView as? any TerminalScrollRouting)?.onScrollWheel = onScrollWheel
        }
    }
    var onSearchQueryChange: ((String) -> Void)?
    var onSearchNext: (() -> Void)?
    var onSearchPrevious: (() -> Void)?
    var onSearchHide: (() -> Void)?
    var onSearchClose: (() -> Void)?
    var onSearchCornerChange: ((PaneSearchHUDCorner) -> Void)?
    var onSearchHUDFrameDidChange: (() -> Void)?
    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)? {
        didSet {
            assert(contextMenuBuilder == nil || terminalView is any TerminalContextMenuConfiguring,
                   "terminalView must conform to TerminalContextMenuConfiguring to forward contextMenuBuilder")
            (terminalView as? any TerminalContextMenuConfiguring)?.contextMenuBuilder = contextMenuBuilder
        }
    }

    init(adapter: any TerminalAdapter) {
        self.adapter = adapter
        self.terminalView = adapter.makeTerminalView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        adapter.eventDidOccur = onEventDidOccur
        (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        (terminalView as? any TerminalScrollRouting)?.onScrollWheel = onScrollWheel
        (terminalView as? any TerminalContextMenuConfiguring)?.contextMenuBuilder = contextMenuBuilder
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startSessionIfNeeded(using request: TerminalSessionRequest) throws {
        guard !hasStartedSession else {
            return
        }

        try ZenttyPerformanceSignposts.interval("TerminalHostStartSession") {
            try adapter.startSession(using: request)
            hasStartedSession = true
        }
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        adapter.setSurfaceActivity(activity)
    }

    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        (adapter as? any TerminalSessionInheritanceConfiguring)?
            .prepareSessionStart(from: sourceAdapter, context: context)
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        (terminalView as? any TerminalViewportSyncControlling)?
            .setViewportSyncSuspended(suspended)
    }

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        (terminalView as? any TerminalMouseInteractionSuppressionControlling)?
            .setMouseInteractionSuppressionRects(rects)
    }

    func forceViewportSync() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        (terminalView as? any TerminalViewportSyncControlling)?.forceViewportSync()
    }

    var isTerminalFocused: Bool {
        let focusTarget = (terminalView as? any TerminalFocusTargetProviding)?.terminalFocusTargetView ?? terminalView
        return focusTarget.window?.firstResponder === focusTarget
    }

    @discardableResult
    func focusTerminal() -> Bool {
        let focusTarget = (terminalView as? any TerminalFocusTargetProviding)?.terminalFocusTargetView ?? terminalView

        guard let window = focusTarget.window ?? window else {
            return false
        }
        guard window.firstResponder !== focusTarget else {
            return false
        }

        ZenttyPerformanceSignposts.event("TerminalFocusRequested")
        return window.makeFirstResponder(focusTarget)
    }

    @discardableResult
    func focusTerminalIfReady() -> Bool {
        let focusTarget = (terminalView as? any TerminalFocusTargetProviding)?.terminalFocusTargetView ?? terminalView
        guard let window = focusTarget.window else {
            return false
        }
        if window.firstResponder === focusTarget {
            return true
        }
        return window.makeFirstResponder(focusTarget)
    }

    func applySearchHUD(_ search: PaneSearchState) {
        lastRenderedSearchState = search
        searchHUDView.apply(search: search)
        if !searchHUDView.preservesInteractiveFrame {
            searchHUDView.frame = searchHUDView.frame(
                for: search.hudCorner,
                in: searchHUDContainerView.bounds
            )
        }
        window?.invalidateCursorRects(for: searchHUDView)
    }

    func focusSearchField(selectAll: Bool) {
        searchHUDView.focusField(selectAll: selectAll)
    }

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true {
            return
        }

        if let nextResponder {
            nextResponder.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func setup() {
        wantsLayer = true
        addSubview(terminalView)
        searchHUDView.isHidden = true
        searchHUDView.delegate = self
        searchHUDView.containerBoundsProvider = { [weak self] in
            self?.searchHUDContainerView.bounds ?? .zero
        }
        searchHUDContainerView.addSubview(searchHUDView, positioned: .above, relativeTo: nil)
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = [.width, .height]
        terminalView.frame = bounds
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        if !searchHUDView.preservesInteractiveFrame {
            searchHUDView.frame = searchHUDView.frame(
                for: lastRenderedSearchState.hudCorner,
                in: searchHUDContainerView.bounds
            )
        }
    }

    var terminalViewForTesting: NSView {
        terminalView
    }

    var isSearchHUDHiddenForTesting: Bool {
        searchHUDView.isHidden
    }

    var searchHUDFrameInHostCoordinates: CGRect {
        convert(searchHUDView.frame, from: searchHUDContainerView)
    }

    var searchHUDFrameForTesting: CGRect {
        searchHUDFrameInHostCoordinates
    }

    var searchHUDCountTextForTesting: String {
        searchHUDView.countTextForTesting
    }

    var searchHUDNextButtonForTesting: PaneSearchHUDButton {
        searchHUDView.nextButtonForTesting
    }

    var searchHUDPreviousButtonForTesting: PaneSearchHUDButton {
        searchHUDView.previousButtonForTesting
    }

    var searchHUDCloseButtonForTesting: PaneSearchHUDButton {
        searchHUDView.closeButtonForTesting
    }

    var searchHUDQueryFieldForTesting: NSTextField {
        searchHUDView.queryFieldForTesting
    }

    var isSearchHUDSnapAnimationInFlightForTesting: Bool {
        searchHUDView.isSnapAnimationInFlightForTesting
    }

    func configureSearchHUDSnapAnimationForTesting(
        _ runner: @escaping (CGPoint, @escaping () -> Void) -> Void
    ) {
        searchHUDView.configureSnapAnimationForTesting(runner)
    }

    func setSearchHUDOriginForTesting(_ origin: CGPoint) {
        let containerOrigin = searchHUDContainerView.convert(origin, from: self)
        searchHUDView.setOriginForTesting(containerOrigin)
    }

    func snapSearchHUDToNearestCornerForTesting() {
        searchHUDView.snapToNearestCornerForTesting()
    }

    func searchHUDFrame(for corner: PaneSearchHUDCorner) -> CGRect {
        convert(searchHUDView.frame(for: corner, in: searchHUDContainerView.bounds), from: searchHUDContainerView)
    }
}

extension TerminalPaneHostView: PaneSearchHUDViewDelegate {
    func paneSearchHUDView(_ hudView: PaneSearchHUDView, didChangeQuery query: String) {
        onSearchQueryChange?(query)
    }

    func paneSearchHUDViewDidRequestNext(_ hudView: PaneSearchHUDView) {
        onSearchNext?()
    }

    func paneSearchHUDViewDidRequestPrevious(_ hudView: PaneSearchHUDView) {
        onSearchPrevious?()
    }

    func paneSearchHUDViewDidRequestHide(_ hudView: PaneSearchHUDView) {
        onSearchHide?()
    }

    func paneSearchHUDViewDidRequestClose(_ hudView: PaneSearchHUDView) {
        onSearchClose?()
    }

    func paneSearchHUDViewFrameDidChange(_ hudView: PaneSearchHUDView) {
        onSearchHUDFrameDidChange?()
    }

    func paneSearchHUDView(_ hudView: PaneSearchHUDView, didSnapTo corner: PaneSearchHUDCorner) {
        onSearchCornerChange?(corner)
    }
}

struct PaneRuntimeSnapshot: Equatable {
    var metadata: TerminalMetadata
    var startupFailureMessage: String?
    var hasReceivedMetadata: Bool
    var search: PaneSearchState
}

private let terminalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Terminal")

private enum PaneSearchOwner: Equatable {
    case none
    case local
    case global
}

@MainActor
final class PaneRuntime {
    static let startupFailureMessage = "GhosttyKit could not start this pane. Check your shell environment and retry."

    private let paneIDValue: PaneID
    private let adapterValue: any TerminalAdapter
    private let hostViewValue: TerminalPaneHostView
    private let metadataSink: (PaneID, TerminalMetadata) -> Void
    private let eventSink: (PaneID, TerminalEvent) -> Void
    private var sessionRequest: TerminalSessionRequest
    private var hasAttemptedStart = false
    private var hasReceivedMetadata = false
    private var hasSentInitialCommand = false
    private var observers: [UUID: (PaneRuntimeSnapshot) -> Void] = [:]
    private var searchUpdateWorkItem: DispatchWorkItem?
    private var ignoreNextTerminalBlurForSearchFocus = false
    private var searchOwner: PaneSearchOwner = .none
    private var globalSearchNeedle = ""
    private var globalSearchEventSink: ((PaneID, TerminalSearchEvent) -> Void)?
    private var hasActiveGlobalSearchSession = false

    private(set) var metadata = TerminalMetadata() {
        didSet {
            notifyObservers()
        }
    }

    private(set) var startupFailureMessageValue: String? {
        didSet {
            guard startupFailureMessageValue != oldValue else {
                return
            }

            notifyObservers()
        }
    }

    private(set) var search = PaneSearchState() {
        didSet {
            guard search != oldValue else {
                return
            }

            notifyObservers()
        }
    }

    init(
        pane: PaneState,
        adapter: any TerminalAdapter,
        metadataSink: @escaping (PaneID, TerminalMetadata) -> Void,
        eventSink: @escaping (PaneID, TerminalEvent) -> Void
    ) {
        paneIDValue = pane.id
        sessionRequest = pane.sessionRequest
        adapterValue = adapter
        hostViewValue = TerminalPaneHostView(adapter: adapter)
        self.metadataSink = metadataSink
        self.eventSink = eventSink
        hostViewValue.onMetadataDidChange = { [weak self] metadata in
            self?.handleMetadataDidChange(metadata)
        }
        hostViewValue.onEventDidOccur = { [weak self] event in
            self?.handleEventDidOccur(event)
        }
        (adapter as? any TerminalSearchControlling)?.searchDidChange = { [weak self] event in
            self?.handleSearchDidChange(event)
        }
    }

    var paneID: PaneID {
        paneIDValue
    }

    var hostView: TerminalPaneHostView {
        hostViewValue
    }

    var adapter: any TerminalAdapter {
        adapterValue
    }

    var hasScrollback: Bool {
        adapterValue.hasScrollback
    }

    var cellHeight: CGFloat {
        adapterValue.cellHeight
    }

    var cellWidth: CGFloat {
        adapterValue.cellWidth
    }

    var snapshot: PaneRuntimeSnapshot {
        PaneRuntimeSnapshot(
            metadata: metadata,
            startupFailureMessage: startupFailureMessageValue,
            hasReceivedMetadata: hasReceivedMetadata,
            search: search
        )
    }

    var globalSearchDidChange: ((PaneID, TerminalSearchEvent) -> Void)? {
        get { globalSearchEventSink }
        set { globalSearchEventSink = newValue }
    }

    func update(pane: PaneState) {
        sessionRequest = pane.sessionRequest
    }

    func ensureStarted() {
        guard !hasAttemptedStart else {
            return
        }

        ZenttyPerformanceSignposts.interval("PaneRuntimeEnsureStarted") {
            hasAttemptedStart = true
            attemptStart()
        }
    }

    func retryStartSession() {
        hasAttemptedStart = true
        attemptStart()
    }

    func showSearch() {
        searchOwner = .local
        if search.hasRememberedSearch == false {
            (adapterValue as? any TerminalSearchControlling)?.showSearch()
        }

        search.isHUDVisible = true
    }

    func useSelectionForFind() {
        searchOwner = .local
        search.isHUDVisible = true
        search.hasRememberedSearch = true
        (adapterValue as? any TerminalSearchControlling)?.useSelectionForFind()
    }

    func updateSearchNeedle(_ needle: String) {
        searchOwner = .local
        search.needle = needle
        if needle.isEmpty == false {
            search.hasRememberedSearch = true
        }

        search.selected = -1
        search.total = 0

        searchUpdateWorkItem?.cancel()

        let dispatchUpdate = { [weak self] in
            guard let self else {
                return
            }

            (self.adapterValue as? any TerminalSearchControlling)?.updateSearch(needle: needle)
        }

        if needle.isEmpty || needle.count >= 3 {
            dispatchUpdate()
            return
        }

        let workItem = DispatchWorkItem(block: dispatchUpdate)
        searchUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func findNext() {
        guard search.hasRememberedSearch else {
            return
        }

        searchOwner = .local
        search.isHUDVisible = true
        (adapterValue as? any TerminalSearchControlling)?.findNext()
    }

    func findPrevious() {
        guard search.hasRememberedSearch else {
            return
        }

        searchOwner = .local
        search.isHUDVisible = true
        (adapterValue as? any TerminalSearchControlling)?.findPrevious()
    }

    func hideSearch() {
        guard search.hasRememberedSearch else {
            return
        }

        search.isHUDVisible = false
    }

    func endSearch() {
        searchUpdateWorkItem?.cancel()
        searchOwner = .none
        globalSearchNeedle = ""
        globalSearchEventSink = nil
        hasActiveGlobalSearchSession = false
        (adapterValue as? any TerminalSearchControlling)?.endSearch()
        search = clearedSearchState()
    }

    func hideSearchHUD() {
        guard search.isHUDVisible else {
            return
        }

        search.isHUDVisible = false
    }

    func prepareSearchFieldFocusTransfer() {
        ignoreNextTerminalBlurForSearchFocus = true
    }

    func handleTerminalFocusChange(_ isFocused: Bool) {
        guard !isFocused, search.isHUDVisible else {
            return
        }

        if ignoreNextTerminalBlurForSearchFocus {
            ignoreNextTerminalBlurForSearchFocus = false
            return
        }

        hideSearchHUD()
    }

    func setSearchHUDCorner(_ corner: PaneSearchHUDCorner) {
        guard search.hudCorner != corner else {
            return
        }

        search.hudCorner = corner
    }

    func beginGlobalSearch(eventSink: @escaping (PaneID, TerminalSearchEvent) -> Void) {
        searchUpdateWorkItem?.cancel()
        searchOwner = .global
        globalSearchEventSink = eventSink
        guard !hasActiveGlobalSearchSession else {
            return
        }

        hasActiveGlobalSearchSession = true
        (adapterValue as? any TerminalSearchControlling)?.showSearch()
    }

    func updateGlobalSearchNeedle(_ needle: String) {
        searchOwner = .global
        globalSearchNeedle = needle
        (adapterValue as? any TerminalSearchControlling)?.updateSearch(needle: needle)
    }

    func findNextInGlobalSearch() {
        guard globalSearchEventSink != nil else {
            return
        }

        searchOwner = .global
        (adapterValue as? any TerminalSearchControlling)?.findNext()
    }

    func findPreviousInGlobalSearch() {
        guard globalSearchEventSink != nil else {
            return
        }

        searchOwner = .global
        (adapterValue as? any TerminalSearchControlling)?.findPrevious()
    }

    func resetGlobalSearchSelection() {
        guard globalSearchEventSink != nil else {
            return
        }

        searchOwner = .global
        (adapterValue as? any TerminalSearchControlling)?.updateSearch(needle: globalSearchNeedle)
    }

    func endGlobalSearch() {
        searchUpdateWorkItem?.cancel()
        guard hasActiveGlobalSearchSession || globalSearchEventSink != nil || searchOwner == .global else {
            return
        }

        searchOwner = .none
        globalSearchNeedle = ""
        globalSearchEventSink = nil
        hasActiveGlobalSearchSession = false
        (adapterValue as? any TerminalSearchControlling)?.endSearch()
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        ZenttyPerformanceSignposts.interval("PaneRuntimeSetSurfaceActivity") {
            if activity.keepsRuntimeLive {
                ensureStarted()
            }
            hostViewValue.setSurfaceActivity(activity)
        }
    }

    func forceViewportSync() {
        hostViewValue.forceViewportSync()
    }

    func prepareSessionStart(from sourceRuntime: PaneRuntime?) {
        hostViewValue.prepareSessionStart(
            from: sourceRuntime?.adapter,
            context: sessionRequest.surfaceContext
        )
    }

    func addObserver(_ observer: @escaping (PaneRuntimeSnapshot) -> Void) -> UUID {
        let observerID = UUID()
        observers[observerID] = observer
        observer(snapshot)
        return observerID
    }

    func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    private func attemptStart() {
        do {
            try hostViewValue.startSessionIfNeeded(using: sessionRequest)
            startupFailureMessageValue = nil
        } catch {
            terminalLogger.error("Terminal session failed for pane \(self.paneIDValue.rawValue): \(error.localizedDescription)")
            startupFailureMessageValue = "Terminal session failed: \(error.localizedDescription)"
        }
    }

    private func handleMetadataDidChange(_ metadata: TerminalMetadata) {
        hasReceivedMetadata = true
        self.metadata = metadata
        metadataSink(paneIDValue, metadata)
        sendInitialCommandIfNeeded(using: metadata)
    }

    private func handleEventDidOccur(_ event: TerminalEvent) {
        eventSink(paneIDValue, event)
    }

    private func sendInitialCommandIfNeeded(using metadata: TerminalMetadata) {
        guard !hasSentInitialCommand,
              let command = sessionRequest.command?.trimmingCharacters(in: .whitespacesAndNewlines),
              isReadyForInitialCommand(metadata),
              !command.isEmpty else {
            return
        }
        hasSentInitialCommand = true
        adapterValue.sendText(command + "\n")
    }

    private func isReadyForInitialCommand(_ metadata: TerminalMetadata) -> Bool {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return true
        }

        if let processName = metadata.processName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processName.isEmpty {
            return true
        }

        return false
    }

    private func handleSearchDidChange(_ event: TerminalSearchEvent) {
        switch searchOwner {
        case .none:
            return
        case .local:
            switch event {
            case .started(let needle):
                if let needle {
                    search.needle = needle
                }
                search.hasRememberedSearch = true
                search.isHUDVisible = true
            case .ended:
                searchOwner = .none
                search = clearedSearchState()
            case .total(let total):
                search.total = total
            case .selected(let selected):
                search.selected = selected
            }
        case .global:
            globalSearchEventSink?(paneIDValue, event)
        }
    }

    private func clearedSearchState() -> PaneSearchState {
        PaneSearchState(hudCorner: search.hudCorner)
    }

    private func notifyObservers() {
        let snapshot = snapshot
        observers.values.forEach { observer in
            observer(snapshot)
        }
    }
}

@MainActor
final class PaneRuntimeRegistry {
    typealias AdapterFactory = @MainActor (PaneID) -> any TerminalAdapter

    private let adapterFactory: AdapterFactory
    private let diagnostics: TerminalDiagnostics
    private var runtimes: [PaneID: PaneRuntime] = [:]

    var onMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?
    var onEventDidOccur: ((PaneID, TerminalEvent) -> Void)?
    var onGlobalSearchDidChange: ((PaneID, TerminalSearchEvent) -> Void)?

    init(
        diagnostics: TerminalDiagnostics = .shared,
        adapterFactory: @escaping AdapterFactory = { paneID in
            LibghosttyAdapter(paneID: paneID)
        }
    ) {
        self.diagnostics = diagnostics
        self.adapterFactory = adapterFactory
    }

    func runtime(for pane: PaneState) -> PaneRuntime {
        if let runtime = runtimes[pane.id] {
            runtime.update(pane: pane)
            return runtime
        }

        return ZenttyPerformanceSignposts.interval("PaneRuntimeCreate") {
            let runtime = PaneRuntime(
                pane: pane,
                adapter: adapterFactory(pane.id),
                metadataSink: { [weak self] paneID, metadata in
                    self?.onMetadataDidChange?(paneID, metadata)
                },
                eventSink: { [weak self] paneID, event in
                    self?.onEventDidOccur?(paneID, event)
                }
            )
            runtime.globalSearchDidChange = { [weak self] paneID, event in
                self?.onGlobalSearchDidChange?(paneID, event)
            }
            runtimes[pane.id] = runtime
            return runtime
        }
    }

    func runtime(for paneID: PaneID) -> PaneRuntime? {
        runtimes[paneID]
    }

    func synchronize(with worklanes: [WorklaneState]) {
        ZenttyPerformanceSignposts.interval("PaneRuntimeSynchronize") {
            var nextPaneIDs = Set<PaneID>()

            for worklane in worklanes {
                for pane in worklane.paneStripState.panes {
                    nextPaneIDs.insert(pane.id)
                    let runtime = runtime(for: pane)
                    let sourcePaneID = pane.sessionRequest.configInheritanceSourcePaneID
                        ?? pane.sessionRequest.inheritFromPaneID
                    let sourceRuntime = sourcePaneID.flatMap { runtimes[$0] }
                    runtime.prepareSessionStart(from: sourceRuntime)
                }
            }

            let obsoletePaneIDs = Set(runtimes.keys).subtracting(nextPaneIDs)
            obsoletePaneIDs.forEach { paneID in
                runtimes[paneID]?.adapter.close()
                runtimes.removeValue(forKey: paneID)
            }
        }
    }

    func destroyAll() {
        runtimes.values.forEach { $0.adapter.close() }
        runtimes.removeAll()
    }

    func updateSurfaceActivities(
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        windowIsVisible: Bool,
        windowIsKey: Bool
    ) {
        let visiblePaneCount = worklanes
            .first(where: { $0.id == activeWorklaneID && windowIsVisible })?
            .paneStripState
            .panes
            .count ?? 0
        diagnostics.recordRuntimeTopology(
            liveRuntimeCount: runtimes.count,
            visiblePaneCount: visiblePaneCount,
            windowVisible: windowIsVisible,
            windowKey: windowIsKey
        )

        for worklane in worklanes {
            let isActiveWorklane = worklane.id == activeWorklaneID
            for pane in worklane.paneStripState.panes {
                let isVisible = windowIsVisible && isActiveWorklane
                let isFocused = isVisible && windowIsKey && pane.id == worklane.paneStripState.focusedPaneID
                let runtime = runtime(for: pane)
                runtime.setSurfaceActivity(
                    TerminalSurfaceActivity(
                        keepsRuntimeLive: true,
                        isVisible: isVisible,
                        isFocused: isFocused
                    )
                )
            }
        }
    }
}
