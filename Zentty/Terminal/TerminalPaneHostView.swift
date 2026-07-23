import AppKit
import Foundation
import os

@MainActor
final class TerminalPaneHostView: NSView, TerminalViewportDiagnosticsContextConfiguring {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "TerminalPaneHostView")

    private let adapter: any TerminalAdapter
    private let terminalView: NSView
    private let searchHUDView = PaneSearchHUDView()
    private var leasePlaceholderView: CompanionLeasePlaceholderView?
    private var hasStartedSession = false
    private var lastRenderedSearchState = PaneSearchState()
    private var viewportDiagnosticsContext = TerminalViewportDiagnostics.Context()

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
            if onFocusDidChange != nil, !(terminalView is any TerminalFocusReporting) {
                Self.logger.warning("terminalView must conform to TerminalFocusReporting to forward onFocusDidChange")
            }
            (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        }
    }
    var onScrollWheel: ((NSEvent) -> Bool)? {
        didSet {
            if onScrollWheel != nil, !(terminalView is any TerminalScrollRouting) {
                Self.logger.warning("terminalView must conform to TerminalScrollRouting to forward onScrollWheel")
            }
            (terminalView as? any TerminalScrollRouting)?.onScrollWheel = onScrollWheel
        }
    }
    var smoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled {
        didSet {
            (terminalView as? any TerminalSmoothScrollConfiguring)?.smoothScrollingEnabled = smoothScrollingEnabled
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
            if contextMenuBuilder != nil, !(terminalView is any TerminalContextMenuConfiguring) {
                Self.logger.warning("terminalView must conform to TerminalContextMenuConfiguring to forward contextMenuBuilder")
            }
            (terminalView as? any TerminalContextMenuConfiguring)?.contextMenuBuilder = contextMenuBuilder
        }
    }
    var remoteImagePasteHandler: ((NSPasteboard, RemoteImagePasteSource) -> Bool)? {
        didSet {
            if remoteImagePasteHandler != nil, !(terminalView is any TerminalRemoteImagePasteConfiguring) {
                Self.logger.warning("terminalView must conform to TerminalRemoteImagePasteConfiguring to forward remoteImagePasteHandler")
            }
            (terminalView as? any TerminalRemoteImagePasteConfiguring)?.remoteImagePasteHandler = remoteImagePasteHandler
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
        (terminalView as? any TerminalSmoothScrollConfiguring)?.smoothScrollingEnabled = smoothScrollingEnabled
        (terminalView as? any TerminalContextMenuConfiguring)?.contextMenuBuilder = contextMenuBuilder
        (terminalView as? any TerminalRemoteImagePasteConfiguring)?.remoteImagePasteHandler = remoteImagePasteHandler
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

    var hasValidViewportSync: Bool {
        (terminalView as? any TerminalViewportSyncControlling)?.hasValidViewportSync ?? true
    }

    func prepareSessionStart(
        from sourceAdapter: (any TerminalAdapter)?,
        context: TerminalSurfaceContext
    ) {
        (adapter as? any TerminalSessionInheritanceConfiguring)?
            .prepareSessionStart(from: sourceAdapter, context: context)
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        recordViewportDiagnostics(suspended ? .syncSuspended : .syncUnsuspended, suspended: suspended)
        if suspended {
            (terminalView as? any TerminalViewportSyncControlling)?
                .setViewportSyncSuspended(true)
            syncTerminalViewFrameIfNeeded()
            layoutTerminalSubtreeIfNeeded()
        } else {
            syncTerminalViewFrameIfNeeded()
            layoutTerminalSubtreeIfNeeded()
            (terminalView as? any TerminalViewportSyncControlling)?
                .setViewportSyncSuspended(false)
        }
    }

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        (terminalView as? any TerminalMouseInteractionSuppressionControlling)?
            .setMouseInteractionSuppressionRects(rects)
    }

    func forceViewportSync() {
        syncTerminalViewFrameIfNeeded()
        needsLayout = true
        recordViewportDiagnostics(.forceViewportSync)
        (terminalView as? any TerminalViewportSyncControlling)?.forceViewportSync()
    }

    func updateViewportDiagnosticsContext(_ context: TerminalViewportDiagnostics.Context) {
        viewportDiagnosticsContext = context
        viewportDiagnosticsContext.terminalHostBounds = bounds
        (terminalView as? any TerminalViewportDiagnosticsContextConfiguring)?
            .updateViewportDiagnosticsContext(viewportDiagnosticsContext)
    }

    private func recordViewportDiagnostics(
        _ source: TerminalViewportEventSource,
        suspended: Bool? = nil
    ) {
        var context = viewportDiagnosticsContext
        context.terminalHostBounds = bounds
        context.windowAttached = window != nil
        if let suspended {
            context.isViewportSyncSuspended = suspended
        }
        TerminalViewportDiagnostics.shared.record(source, context: context)
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

    func updateSearchHUDShortcutTooltips(_ shortcutManager: ShortcutManager) {
        searchHUDView.updateShortcutTooltips(shortcutManager)
    }

    func applySearchHUDTheme(_ theme: ZenttyTheme, animated: Bool) {
        searchHUDView.apply(theme: theme, animated: animated)
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
        syncTerminalViewFrameIfNeeded()
        if !searchHUDView.preservesInteractiveFrame {
            searchHUDView.frame = searchHUDView.frame(
                for: lastRenderedSearchState.hudCorner,
                in: searchHUDContainerView.bounds
            )
        }
    }

    private func syncTerminalViewFrameIfNeeded() {
        guard terminalView.frame != bounds else {
            return
        }
        terminalView.frame = bounds
    }

    // MARK: - Companion control lease (§2.6)

    /// Begins a control-lease takeover: pin the surface to the phone's fixed grid,
    /// occlude the desktop surface, and install the "controlled by <device>"
    /// placeholder with a Take Back Control button. Idempotent — a repeat call
    /// (resize / supersede) refreshes the grid and device name in place. Returns
    /// `false` when the adapter has no live surface to lease.
    @discardableResult
    func beginControlLease(
        cols: Int,
        rows: Int,
        deviceName: String,
        onTakeBack: @escaping () -> Void
    ) -> Bool {
        guard let leaseable = adapter as? TerminalControlLeasing,
              leaseable.applyControlLease(cols: cols, rows: rows)
        else {
            return false
        }

        if let existing = leasePlaceholderView {
            existing.updateDeviceName(deviceName)
        } else {
            let placeholder = CompanionLeasePlaceholderView(deviceName: deviceName, onTakeBack: onTakeBack)
            placeholder.frame = bounds
            placeholder.autoresizingMask = [.width, .height]
            addSubview(placeholder, positioned: .above, relativeTo: terminalView)
            leasePlaceholderView = placeholder
        }
        return true
    }

    /// Ends the control lease: restore the frame-derived viewport, re-enable
    /// desktop rendering, and remove the placeholder.
    func endControlLease() {
        (adapter as? TerminalControlLeasing)?.releaseControlLease()
        leasePlaceholderView?.removeFromSuperview()
        leasePlaceholderView = nil
    }

    var isUnderControlLeaseForTesting: Bool {
        leasePlaceholderView != nil
    }

    private func layoutTerminalSubtreeIfNeeded() {
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
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

    var searchHUDBackgroundColorTokenForTesting: String {
        searchHUDView.backgroundColorTokenForTesting
    }

    var searchHUDBorderColorTokenForTesting: String {
        searchHUDView.borderColorTokenForTesting
    }

    var searchHUDCountTextColorTokenForTesting: String {
        searchHUDView.countTextColorTokenForTesting
    }

    var searchHUDQueryTextColorTokenForTesting: String {
        searchHUDView.queryTextColorTokenForTesting
    }

    var searchHUDNextButtonTintColorTokenForTesting: String {
        searchHUDView.nextButtonTintColorTokenForTesting
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

private enum PaneRestoreDraftLifecycleState: Equatable {
    case none
    case pending(String)
    case injected
    case consumed
}

enum PaneRuntimeStartupPolicy {
    case immediate
    case deferred
}

@MainActor
final class PaneRuntime {
    static let startupFailureMessage = "GhosttyKit could not start this pane. Check your shell environment and retry."
    private static let defaultStartupCommandSettleDelay: TimeInterval = 0.12
    private static let defaultRestoreDraftSettleDelay: TimeInterval = 0.25

    private let paneIDValue: PaneID
    private let adapterValue: any TerminalAdapter
    private let hostViewValue: TerminalPaneHostView
    private var metadataSink: (PaneID, TerminalMetadata) -> Void
    private var eventSink: (PaneID, TerminalEvent) -> Void
    private let startupCommandSettleDelay: TimeInterval
    private let restoreDraftSettleDelay: TimeInterval
    private var sessionRequest: TerminalSessionRequest
    private var hasAttemptedStart = false
    private var hasReceivedMetadata = false
    private var hasSentInitialCommand = false
    private var hasObservedShellReady = false
    private var restoreDraftLifecycleState: PaneRestoreDraftLifecycleState
    private var pendingStartupTextWorkItem: DispatchWorkItem?
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
        eventSink: @escaping (PaneID, TerminalEvent) -> Void,
        startupTextSettleDelay: TimeInterval = PaneRuntime.defaultStartupCommandSettleDelay,
        restoreDraftSettleDelay: TimeInterval = PaneRuntime.defaultRestoreDraftSettleDelay
    ) {
        paneIDValue = pane.id
        sessionRequest = pane.sessionRequest
        restoreDraftLifecycleState = Self.initialRestoreDraftLifecycleState(for: pane.sessionRequest)
        adapterValue = adapter
        hostViewValue = TerminalPaneHostView(adapter: adapter)
        self.metadataSink = metadataSink
        self.eventSink = eventSink
        startupCommandSettleDelay = startupTextSettleDelay
        self.restoreDraftSettleDelay = restoreDraftSettleDelay
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

    convenience init(
        pane: PaneState,
        adapter: any TerminalAdapter,
        metadataSink: @escaping (PaneID, TerminalMetadata) -> Void,
        eventSink: @escaping (PaneID, TerminalEvent) -> Void
    ) {
        self.init(
            pane: pane,
            adapter: adapter,
            metadataSink: metadataSink,
            eventSink: eventSink,
            startupTextSettleDelay: Self.defaultStartupCommandSettleDelay,
            restoreDraftSettleDelay: Self.defaultRestoreDraftSettleDelay
        )
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

    var hasAttemptedSessionStart: Bool {
        hasAttemptedStart
    }

    var canStartDeferred: Bool {
        !hasAttemptedStart && !sessionRequest.isLaunchDeferred
    }

    var hasValidViewportSync: Bool {
        hostViewValue.hasValidViewportSync
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

    func rebindSinks(
        metadataSink: @escaping (PaneID, TerminalMetadata) -> Void,
        eventSink: @escaping (PaneID, TerminalEvent) -> Void,
        globalSearchDidChange: ((PaneID, TerminalSearchEvent) -> Void)?
    ) {
        self.metadataSink = metadataSink
        self.eventSink = eventSink
        self.globalSearchDidChange = globalSearchDidChange
    }

    func update(pane: PaneState) {
        sessionRequest = pane.sessionRequest
        if case .none = restoreDraftLifecycleState {
            restoreDraftLifecycleState = Self.initialRestoreDraftLifecycleState(for: pane.sessionRequest)
        }
    }

    func ensureStarted() {
        guard !hasAttemptedStart else {
            return
        }
        guard !sessionRequest.isLaunchDeferred else {
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

    func setSurfaceActivity(
        _ activity: TerminalSurfaceActivity,
        startupPolicy: PaneRuntimeStartupPolicy = .immediate
    ) {
        ZenttyPerformanceSignposts.interval("PaneRuntimeSetSurfaceActivity") {
            hostViewValue.setSurfaceActivity(activity)
            if activity.keepsRuntimeLive && startupPolicy == .immediate {
                ensureStarted()
            }
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

    func updateSearchHUDShortcutTooltips(_ shortcutManager: ShortcutManager) {
        hostViewValue.updateSearchHUDShortcutTooltips(shortcutManager)
    }

    func setRemoteImagePasteHandler(
        _ handler: ((NSPasteboard, RemoteImagePasteSource) -> Bool)?
    ) {
        hostViewValue.remoteImagePasteHandler = handler
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
        scheduleStartupTextIfNeeded(using: metadata)
    }

    private func handleEventDidOccur(_ event: TerminalEvent) {
        switch event {
        case .shellReady:
            hasObservedShellReady = true
            scheduleStartupTextIfNeeded(using: metadata)
        case .userEditedInput, .userSubmittedInput:
            consumeRestoreDraftIfNeeded()
        default:
            break
        }
        eventSink(paneIDValue, event)
    }

    private func scheduleStartupTextIfNeeded(using metadata: TerminalMetadata) {
        guard let settleDelay = startupTextSettleDelayIfNeeded(using: metadata) else {
            return
        }

        pendingStartupTextWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushStartupTextIfNeeded()
        }
        pendingStartupTextWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func flushStartupTextIfNeeded() {
        pendingStartupTextWorkItem = nil

        if sendInitialCommandIfNeeded(using: metadata) {
            return
        }

        _ = sendRestoreDraftIfNeeded(using: metadata)
    }

    private func startupTextSettleDelayIfNeeded(using metadata: TerminalMetadata) -> TimeInterval? {
        if canSendInitialCommand(using: metadata) {
            return startupCommandSettleDelay
        }

        if canSendRestoreDraft(using: metadata) {
            return restoreDraftSettleDelay
        }

        return nil
    }

    private func sendInitialCommandIfNeeded(using metadata: TerminalMetadata) -> Bool {
        guard let command = normalizedInitialCommand,
              canSendInitialCommand(using: metadata) else {
            return false
        }

        hasSentInitialCommand = true
        adapterValue.submitCommand(command)
        return true
    }

    private func sendRestoreDraftIfNeeded(using metadata: TerminalMetadata) -> Bool {
        guard case .pending(let draftText) = restoreDraftLifecycleState,
              canSendRestoreDraft(using: metadata) else {
            return false
        }

        restoreDraftLifecycleState = .injected
        adapterValue.sendText(draftText)
        return true
    }

    private var normalizedInitialCommand: String? {
        let command = sessionRequest.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command, !command.isEmpty else {
            return nil
        }
        return command
    }

    private func canSendInitialCommand(using metadata: TerminalMetadata) -> Bool {
        !hasSentInitialCommand
            && normalizedInitialCommand != nil
            && isReadyForStartupText(metadata)
    }

    private func canSendRestoreDraft(using metadata: TerminalMetadata) -> Bool {
        guard case .pending(let draftText) = restoreDraftLifecycleState,
              hasSentInitialCommand == false,
              normalizedInitialCommand == nil,
              hasObservedShellReady else {
            return false
        }

        return !draftText.isEmpty
    }

    private func consumeRestoreDraftIfNeeded() {
        switch restoreDraftLifecycleState {
        case .pending, .injected:
            pendingStartupTextWorkItem?.cancel()
            pendingStartupTextWorkItem = nil
            restoreDraftLifecycleState = .consumed
        case .none, .consumed:
            return
        }
    }

    private func isReadyForStartupText(_ metadata: TerminalMetadata) -> Bool {
        if hasObservedShellReady {
            return true
        }

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

    private static func initialRestoreDraftLifecycleState(
        for request: TerminalSessionRequest
    ) -> PaneRestoreDraftLifecycleState {
        guard let raw = request.prefillText,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        return .pending(raw)
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
    typealias DeferredStartScheduler = @MainActor (
        _ delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> Void

    private let adapterFactory: AdapterFactory
    private let diagnostics: TerminalDiagnostics
    private let deferredStartInitialDelay: TimeInterval
    private let deferredStartInterval: TimeInterval
    private let deferredStartScheduler: DeferredStartScheduler
    private var runtimes: [PaneID: PaneRuntime] = [:]
    private var deferredStartQueue: [PaneID] = []
    private var deferredStartPaneIDs = Set<PaneID>()
    private var isDeferredStartScheduled = false
    private var deferredStartGeneration = 0
    private var shortcutManager = ShortcutManager(shortcuts: .default)

    var onMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?
    var onEventDidOccur: ((PaneID, TerminalEvent) -> Void)?
    var onGlobalSearchDidChange: ((PaneID, TerminalSearchEvent) -> Void)?
    var onRuntimeDidCreate: ((PaneRuntime) -> Void)?

    init(
        diagnostics: TerminalDiagnostics = .shared,
        adapterFactory: @escaping AdapterFactory = { paneID in
            LibghosttyAdapter(paneID: paneID)
        },
        deferredStartInitialDelay: TimeInterval = 0.1,
        deferredStartInterval: TimeInterval = 0.05,
        deferredStartScheduler: @escaping DeferredStartScheduler = PaneRuntimeRegistry.defaultDeferredStartScheduler
    ) {
        self.diagnostics = diagnostics
        self.adapterFactory = adapterFactory
        self.deferredStartInitialDelay = deferredStartInitialDelay
        self.deferredStartInterval = deferredStartInterval
        self.deferredStartScheduler = deferredStartScheduler
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
                metadataSink: metadataSink(),
                eventSink: eventSink()
            )
            bindSinks(to: runtime)
            runtime.updateSearchHUDShortcutTooltips(shortcutManager)
            runtimes[pane.id] = runtime
            onRuntimeDidCreate?(runtime)
            return runtime
        }
    }

    func runtime(for paneID: PaneID) -> PaneRuntime? {
        runtimes[paneID]
    }

    func detachRuntime(for paneID: PaneID) -> PaneRuntime? {
        guard let runtime = runtimes.removeValue(forKey: paneID) else {
            return nil
        }

        removeDeferredStart(for: paneID)
        runtime.rebindSinks(
            metadataSink: { _, _ in },
            eventSink: { _, _ in },
            globalSearchDidChange: nil
        )
        return runtime
    }

    func adoptRuntime(_ runtime: PaneRuntime, for paneID: PaneID) {
        guard runtime.paneID == paneID else {
            return
        }

        if let existingRuntime = runtimes[paneID], existingRuntime !== runtime {
            existingRuntime.adapter.close()
        }

        removeDeferredStart(for: paneID)
        bindSinks(to: runtime)
        runtime.updateSearchHUDShortcutTooltips(shortcutManager)
        runtimes[paneID] = runtime
        onRuntimeDidCreate?(runtime)
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        runtimes.values.forEach { $0.updateSearchHUDShortcutTooltips(shortcutManager) }
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
                removeDeferredStart(for: paneID)
            }
        }
    }

    func destroyAll() {
        runtimes.values.forEach { $0.adapter.close() }
        runtimes.removeAll()
        cancelDeferredStartSchedule()
    }

    private func bindSinks(to runtime: PaneRuntime) {
        runtime.rebindSinks(
            metadataSink: metadataSink(),
            eventSink: eventSink(),
            globalSearchDidChange: globalSearchSink()
        )
    }

    private func metadataSink() -> (PaneID, TerminalMetadata) -> Void {
        { [weak self] paneID, metadata in
            self?.onMetadataDidChange?(paneID, metadata)
        }
    }

    private func eventSink() -> (PaneID, TerminalEvent) -> Void {
        { [weak self] paneID, event in
            self?.onEventDidOccur?(paneID, event)
        }
    }

    private func globalSearchSink() -> (PaneID, TerminalSearchEvent) -> Void {
        { [weak self] paneID, event in
            self?.onGlobalSearchDidChange?(paneID, event)
        }
    }

    private static func defaultDeferredStartScheduler(
        delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                operation()
            }
        }
    }

    private func removeDeferredStart(for paneID: PaneID) {
        guard deferredStartPaneIDs.remove(paneID) != nil else {
            return
        }

        deferredStartQueue.removeAll { $0 == paneID }
        if deferredStartQueue.isEmpty {
            cancelDeferredStartSchedule()
        }
    }

    private func replaceDeferredStartQueue(with paneIDs: [PaneID]) {
        var seenPaneIDs = Set<PaneID>()
        let nextQueue = paneIDs.filter { paneID in
            guard seenPaneIDs.insert(paneID).inserted else {
                return false
            }

            return runtimes[paneID]?.canStartDeferred == true
        }

        deferredStartQueue = nextQueue
        deferredStartPaneIDs = Set(nextQueue)
        if nextQueue.isEmpty {
            cancelDeferredStartSchedule()
            return
        }

        scheduleDeferredStartIfNeeded(delay: deferredStartInitialDelay)
    }

    private func cancelDeferredStartSchedule() {
        let hadPendingSchedule = isDeferredStartScheduled
        deferredStartQueue.removeAll()
        deferredStartPaneIDs.removeAll()
        isDeferredStartScheduled = false

        if hadPendingSchedule {
            deferredStartGeneration += 1
        }
    }

    private func scheduleDeferredStartIfNeeded(delay: TimeInterval) {
        guard !isDeferredStartScheduled, !deferredStartQueue.isEmpty else {
            return
        }

        isDeferredStartScheduled = true
        let generation = deferredStartGeneration
        deferredStartScheduler(delay) { [weak self] in
            self?.runNextDeferredStart(generation: generation)
        }
    }

    private func runNextDeferredStart(generation: Int) {
        guard generation == deferredStartGeneration else {
            return
        }

        isDeferredStartScheduled = false

        while !deferredStartQueue.isEmpty {
            let paneID = deferredStartQueue.removeFirst()
            deferredStartPaneIDs.remove(paneID)
            guard let runtime = runtimes[paneID], runtime.canStartDeferred else {
                continue
            }

            runtime.ensureStarted()
            break
        }

        scheduleDeferredStartIfNeeded(delay: deferredStartInterval)
    }

    func updateSurfaceActivities(
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        windowIsVisible: Bool,
        windowIsKey: Bool,
        peekVisibleWorklaneIDs: Set<WorklaneID> = []
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

        let activeWorklaneIndex = worklanes.firstIndex { $0.id == activeWorklaneID } ?? 0
        var deferredCandidates: [(distance: Int, worklaneIndex: Int, paneIndex: Int, paneID: PaneID)] = []

        for (worklaneIndex, worklane) in worklanes.enumerated() {
            let isActiveWorklane = worklane.id == activeWorklaneID
            // A worklane's surfaces are visible (i.e., un-occluded so Ghostty
            // keeps streaming frames) when the window is visible AND the
            // worklane is either the active one OR currently rendered as a
            // Worklane Peek neighbor preview. Focus stays gated on active.
            let isPeekVisible = peekVisibleWorklaneIDs.contains(worklane.id)
            for (paneIndex, pane) in worklane.paneStripState.panes.enumerated() {
                let isVisible = windowIsVisible && (isActiveWorklane || isPeekVisible)
                let isFocused = isVisible && windowIsKey && isActiveWorklane
                    && pane.id == worklane.paneStripState.focusedPaneID
                let runtime = runtime(for: pane)
                let startsImmediately = isActiveWorklane || isPeekVisible
                if startsImmediately {
                    removeDeferredStart(for: pane.id)
                }

                let activity = TerminalSurfaceActivity(
                    keepsRuntimeLive: true,
                    isVisible: isVisible,
                    isFocused: isFocused
                )
                runtime.setSurfaceActivity(
                    activity,
                    startupPolicy: startsImmediately ? .immediate : .deferred
                )
                if !startsImmediately, activity.keepsRuntimeLive, runtime.canStartDeferred {
                    deferredCandidates.append(
                        (
                            distance: abs(worklaneIndex - activeWorklaneIndex),
                            worklaneIndex: worklaneIndex,
                            paneIndex: paneIndex,
                            paneID: pane.id
                        )
                    )
                }
            }
        }

        replaceDeferredStartQueue(
            with: deferredCandidates
                .sorted {
                    if $0.distance != $1.distance {
                        return $0.distance < $1.distance
                    }

                    if $0.worklaneIndex != $1.worklaneIndex {
                        return $0.worklaneIndex < $1.worklaneIndex
                    }

                    return $0.paneIndex < $1.paneIndex
                }
                .map(\.paneID)
        )
    }
}
