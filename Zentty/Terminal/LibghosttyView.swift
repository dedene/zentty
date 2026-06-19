import AppKit
import GhosttyKit
import QuartzCore

@MainActor
protocol TerminalViewportSyncControlling: AnyObject {
    var hasValidViewportSync: Bool { get }

    func setViewportSyncSuspended(_ suspended: Bool)
    func forceViewportSync()
}

extension TerminalViewportSyncControlling {
    var hasValidViewportSync: Bool { true }

    func forceViewportSync() {}
}

@MainActor
private protocol LibghosttyScrollbarHandling: AnyObject {
    func applyScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate)
}

private enum TerminalBindingAction {
    static let copyToClipboard = "copy_to_clipboard"
    static let pasteFromClipboard = "paste_from_clipboard"
    static let selectAll = "select_all"
    static let scrollToBottom = "scroll_to_bottom"
}

@MainActor
private final class LibghosttyOverlayHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard !isHidden, alphaValue > 0, bounds.contains(localPoint) else {
            return nil
        }

        for subview in subviews.reversed() {
            if let hitView = subview.hitTest(localPoint) {
                return hitView
            }
        }

        return nil
    }
}

@MainActor
private final class TerminalFrameMeterHistoryGraphView: NSView {
    private var historyPoints: [TerminalFrameMeter.HistoryPoint] = []
    private var renderedHistoryPoints: [TerminalFrameMeter.HistoryPoint] = []
    private var targetFramesPerSecond = 120

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(historyPoints: [TerminalFrameMeter.HistoryPoint], targetFramesPerSecond: Int) {
        self.historyPoints = historyPoints
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
        renderedHistoryPoints = Self.smoothedHistoryPoints(
            historyPoints,
            targetFramesPerSecond: self.targetFramesPerSecond
        )
        needsDisplay = true
    }

    var historyPointCountForTesting: Int {
        historyPoints.count
    }

    var historyDipCountForTesting: Int {
        renderedHistoryPoints.filter(\.isDip).count
    }

    var historyWarningCountForTesting: Int {
        renderedHistoryPoints.filter { $0.severity == .warning }.count
    }

    var historyCriticalCountForTesting: Int {
        renderedHistoryPoints.filter { $0.severity == .critical }.count
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard bounds.width > 2, bounds.height > 2 else {
            return
        }

        drawTargetLine()
        drawFPSLine()
        drawDipMarkers()
    }

    private func drawTargetLine() {
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.width, y: 0.5))
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.stroke()
    }

    private func drawFPSLine() {
        let drawablePoints = renderedHistoryPoints.enumerated().compactMap { index, point -> NSPoint? in
            guard let framesPerSecond = point.framesPerSecond else {
                return nil
            }

            return graphPoint(index: index, framesPerSecond: framesPerSecond)
        }
        guard !drawablePoints.isEmpty else {
            return
        }

        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: drawablePoints[0])
        for point in drawablePoints.dropFirst() {
            path.line(to: point)
        }
        NSColor.systemGreen.setStroke()
        path.stroke()
    }

    private func drawDipMarkers() {
        let dipPoints = renderedHistoryPoints.enumerated().filter { $0.element.isDip }
        guard !dipPoints.isEmpty else {
            return
        }

        for (index, point) in dipPoints {
            color(for: point.severity).setStroke()
            let x = xPosition(for: index)
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.stroke()
        }
    }

    private func graphPoint(index: Int, framesPerSecond: Double) -> NSPoint {
        let clampedFPS = max(0, min(Double(targetFramesPerSecond), framesPerSecond))
        let normalized = clampedFPS / Double(targetFramesPerSecond)
        let y = bounds.height - (CGFloat(normalized) * bounds.height)
        return NSPoint(x: xPosition(for: index), y: max(0, min(bounds.height, y)))
    }

    private func xPosition(for index: Int) -> CGFloat {
        guard renderedHistoryPoints.count > 1 else {
            return bounds.width
        }

        let progress = CGFloat(index) / CGFloat(renderedHistoryPoints.count - 1)
        return progress * bounds.width
    }

    private static func smoothedHistoryPoints(
        _ points: [TerminalFrameMeter.HistoryPoint],
        targetFramesPerSecond: Int
    ) -> [TerminalFrameMeter.HistoryPoint] {
        var smoothedFramesPerSecond: Double?
        var previousRawSeverity = TerminalFrameMeter.Severity.stable

        return points.map { point in
            guard let framesPerSecond = point.framesPerSecond else {
                previousRawSeverity = point.severity
                return .init(timestamp: point.timestamp, framesPerSecond: nil, severity: .stable)
            }

            let smoothed = smoothedFramesPerSecond.map { previous in
                previous + ((framesPerSecond - previous) * 0.25)
            } ?? framesPerSecond
            smoothedFramesPerSecond = smoothed

            var severity = TerminalFrameMeter.Severity.classify(
                framesPerSecond: smoothed,
                preferredFramesPerSecond: targetFramesPerSecond
            )
            if severity != .critical,
               point.severity == .critical,
               previousRawSeverity == .critical {
                severity = .critical
            } else if severity == .stable,
                      point.severity == .warning,
                      previousRawSeverity == .warning {
                severity = .warning
            }
            previousRawSeverity = point.severity

            return .init(timestamp: point.timestamp, framesPerSecond: smoothed, severity: severity)
        }
    }

    private func color(for severity: TerminalFrameMeter.Severity) -> NSColor {
        switch severity {
        case .stable:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }
}

@MainActor
final class TerminalFrameMeterHUDView: NSView {
    struct Snapshot: Equatable {
        let isHidden: Bool
        let frame: NSRect
        let primaryText: String
        let secondaryText: String
        let graphPointCount: Int
        let graphDipCount: Int
        let graphWarningCount: Int
        let graphCriticalCount: Int
        let severity: TerminalFrameMeter.Severity
    }

    private let primaryLabel = NSTextField(labelWithString: "FPS --")
    private let secondaryLabel = NSTextField(labelWithString: "late --  max --")
    private let graphView = TerminalFrameMeterHistoryGraphView(frame: NSRect(x: 0, y: 0, width: 114, height: 12))
    private var displayedSeverity: TerminalFrameMeter.Severity = .stable

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        alphaValue = 0.92

        primaryLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        primaryLabel.textColor = .systemGreen
        primaryLabel.alignment = .left
        primaryLabel.lineBreakMode = .byClipping

        secondaryLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .left
        secondaryLabel.lineBreakMode = .byClipping

        addSubview(primaryLabel)
        addSubview(secondaryLabel)
        addSubview(graphView)
        showWaiting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        primaryLabel.frame = NSRect(x: 7, y: bounds.height - 17, width: bounds.width - 14, height: 12)
        secondaryLabel.frame = NSRect(x: 7, y: bounds.height - 29, width: bounds.width - 14, height: 11)
        graphView.frame = NSRect(x: 7, y: 5, width: bounds.width - 14, height: 12)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func showWaiting() {
        isHidden = false
        displayedSeverity = .stable
        primaryLabel.stringValue = "FPS --"
        primaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.stringValue = "sent -- late --"
        graphView.update(historyPoints: [], targetFramesPerSecond: 120)
    }

    func update(with snapshot: TerminalFrameMeter.Snapshot) {
        isHidden = false
        let fpsText = snapshot.tickFramesPerSecond.map { String(format: "%.0f", $0) } ?? "--"
        primaryLabel.stringValue = "FPS \(fpsText)/\(snapshot.preferredFramesPerSecond)"
        displayedSeverity = statusSeverity(for: snapshot)
        primaryLabel.textColor = color(for: displayedSeverity)

        let latePercentage = Int((snapshot.lateFrameRatio * 100).rounded())
        let sentText = snapshot.sentFramesPerSecond.map { String(format: "%.0f", $0) } ?? "--"
        secondaryLabel.stringValue = "sent \(sentText) late \(latePercentage)%"
        graphView.update(
            historyPoints: snapshot.historyPoints,
            targetFramesPerSecond: snapshot.preferredFramesPerSecond
        )
    }

    var snapshotForTesting: Snapshot {
        Snapshot(
            isHidden: isHidden,
            frame: frame,
            primaryText: primaryLabel.stringValue,
            secondaryText: secondaryLabel.stringValue,
            graphPointCount: graphView.historyPointCountForTesting,
            graphDipCount: graphView.historyDipCountForTesting,
            graphWarningCount: graphView.historyWarningCountForTesting,
            graphCriticalCount: graphView.historyCriticalCountForTesting,
            severity: displayedSeverity
        )
    }

    private func statusSeverity(for snapshot: TerminalFrameMeter.Snapshot) -> TerminalFrameMeter.Severity {
        guard let framesPerSecond = snapshot.framesPerSecond else {
            return .stable
        }

        return TerminalFrameMeter.Severity.classify(
            framesPerSecond: framesPerSecond,
            preferredFramesPerSecond: snapshot.preferredFramesPerSecond
        )
    }

    private func color(for severity: TerminalFrameMeter.Severity) -> NSColor {
        switch severity {
        case .stable:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }
}

@MainActor
private final class LibghosttyScrollView: NSScrollView {
    weak var surfaceView: LibghosttyView?

    override var acceptsFirstResponder: Bool {
        false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        if surfaceView.consumeScrollWheelBeforeTerminalFocusIfNeeded(event) {
            return
        }
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        if surfaceView.consumeScrollWheelForTerminalInputIfNeeded(event, routeOutwardFirst: false) {
            return
        }

        super.scrollWheel(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surfaceView else {
            super.rightMouseDown(with: event)
            return
        }

        if surfaceView.handleSecondaryMouseDownForContextMenuRouting(event) {
            return
        }

        if surfaceView.presentContextMenuForSecondaryClick(event, anchorView: self) {
            return
        }

        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surfaceView else {
            super.rightMouseUp(with: event)
            return
        }

        if surfaceView.handleSecondaryMouseUpForContextMenuRouting(event) {
            return
        }

        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let surfaceView else {
            super.rightMouseDragged(with: event)
            return
        }

        surfaceView.rightMouseDragged(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surfaceView else {
            return super.menu(for: event)
        }

        return surfaceView.menu(for: event)
    }
}

@MainActor
final class LibghosttySurfaceScrollHostView: NSView, TerminalViewportSyncControlling, TerminalFocusReporting, TerminalFocusTargetProviding, TerminalOverlayHosting, TerminalScrollRouting, TerminalSmoothScrollConfiguring, TerminalMouseInteractionSuppressionControlling, TerminalContextMenuConfiguring, TerminalViewportDiagnosticsContextConfiguring, LibghosttyScrollbarHandling {
    private struct ScrollHostSyncMetrics {
        let geometryApplied: Bool
        let documentHeightChanged: Bool
        let documentHeightPoints: CGFloat
        let documentHeightDeltaPoints: CGFloat
        let reflected: Bool
        let scrollbarTotalRows: UInt64?
        let scrollbarOffsetRows: Double?
        let scrollbarVisibleRows: UInt64?
        let wasAtBottom: Bool?
        let shouldAutoScroll: Bool?
        let autoScrollApplied: Bool?
        let userScrolledAwayFromBottom: Bool?
        let explicitScrollbarSyncAllowed: Bool?
    }

    private struct BackingMetricsTransition {
        // AppKit reports backing changes before Ghostty emits fresh cell_size
        // metrics, so bottom restoration waits for point-space cell metrics.
        var wasBottomPinned: Bool
        var receivedCellSize = false
    }

    private let paneID: PaneID
    private let diagnostics: TerminalDiagnostics
    private let scrollFrameSampler: any TerminalScrollFrameSampling
    private let scrollView: LibghosttyScrollView
    private let overlayHostView = LibghosttyOverlayHostView()
    private let frameMeterSampler: any TerminalScrollFrameSampling
    private let frameMeterHUDView = TerminalFrameMeterHUDView(frame: NSRect(x: 0, y: 0, width: 128, height: 48))
    private let documentView: NSView
    private let surfaceView: LibghosttyView
    private var isLiveScrolling = false
    private var needsLiveScrollReconciliation = false
    private var pendingExplicitWheelScroll = false
    private var allowExplicitScrollbarSync = false
    private var backingMetricsTransition: BackingMetricsTransition?
    private var programmaticScrollUpdateDepth = 0
    private var userScrolledAwayFromBottom = false
    private var lastSentRow: Int?
    private var lastSentOffset: Double?
    private var lastSampledSmoothScrollOffset: Double?
    private var smoothScrollStableFrameCount = 0
    private var scrollbarUpdate: LibghosttySurfaceScrollbarUpdate?
    private var viewportDiagnosticsContext = TerminalViewportDiagnostics.Context()
    private let selectionAutoscrollController = LibghosttySelectionAutoscrollController()
    private var selectionAutoscrollTimer: Timer?
    private var lastSelectionAutoscrollTickTime: TimeInterval?
    private static let scrollToBottomThreshold: CGFloat = 5.0
    private static let smoothElasticOverscrollMultiplier = 1.15
    private static let smoothScrollStableFrameLimit = 3

    var onScrollWheel: ((NSEvent) -> Bool)? {
        get { surfaceView.onScrollWheel }
        set { surfaceView.onScrollWheel = newValue }
    }

    var onFocusDidChange: ((Bool) -> Void)? {
        get { surfaceView.onFocusDidChange }
        set { surfaceView.onFocusDidChange = newValue }
    }

    var hasValidViewportSync: Bool {
        surfaceView.hasValidViewportSync
    }

    var terminalFocusTargetView: NSView {
        surfaceView
    }

    var terminalOverlayHostView: NSView {
        overlayHostView
    }

    var smoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled {
        didSet {
            guard oldValue != smoothScrollingEnabled else {
                return
            }
            if !smoothScrollingEnabled {
                stopSmoothScrollFrameSampling()
                snapCurrentScrollToRowAndNotifySurfaceIfNeeded()
            }
            updateScrollElasticity()
            surfaceView.setSmoothScrollingEnabled(smoothScrollingEnabled)
        }
    }

    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)? {
        get { surfaceView.contextMenuBuilder }
        set { surfaceView.contextMenuBuilder = newValue }
    }

    init(
        surfaceView: LibghosttyView,
        paneID: PaneID,
        diagnostics: TerminalDiagnostics,
        scrollFrameSampler: any TerminalScrollFrameSampling = TerminalScrollFrameSampler(),
        frameMeterSampler: (any TerminalScrollFrameSampling)? = nil
    ) {
        self.paneID = paneID
        self.diagnostics = diagnostics
        self.scrollFrameSampler = scrollFrameSampler
        self.surfaceView = surfaceView
        self.scrollView = LibghosttyScrollView()
        self.documentView = NSView(frame: .zero)
        self.frameMeterSampler = frameMeterSampler ?? TerminalScrollFrameSampler()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.surfaceView = surfaceView
        updateScrollElasticity()
        surfaceView.onExplicitWheelScroll = { [weak self] in
            self?.cancelBackingMetricsTransition()
            self?.pendingExplicitWheelScroll = true
        }
        surfaceView.onSelectionDragStateDidChange = { [weak self] isActive in
            self?.selectionAutoscrollController.setSelectionDragActive(isActive)
            self?.updateSelectionAutoscrollTimerState()
        }
        surfaceView.onMouseLocationDidChange = { [weak self] location in
            self?.selectionAutoscrollController.setMouseLocation(location)
        }
        surfaceView.onBackingPropertiesDidChange = { [weak self] in
            self?.beginBackingMetricsReconciliation()
        }
        surfaceView.onCellSizeDidChange = { [weak self] in
            self?.handleTerminalCellSizeDidChange()
        }
        scrollFrameSampler.onFrame = { [weak self] in
            self?.sampleSmoothScrollFrame()
        }
        self.frameMeterSampler.onFrame = { [weak self] in
            self?.recordFrameMeterDisplayTick()
        }

        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)
        addSubview(scrollView)
        overlayHostView.translatesAutoresizingMaskIntoConstraints = true
        overlayHostView.autoresizingMask = [.width, .height]
        overlayHostView.frame = bounds
        addSubview(overlayHostView)
        overlayHostView.addSubview(frameMeterHUDView)
        syncFrameMeterHUDVisibility()

        surfaceView.scrollbarHandler = self

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollChangeNotification),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillStartLiveScrollNotification),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEndLiveScrollNotification),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidLiveScrollNotification),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameMeterStateDidChangeNotification),
            name: TerminalFrameMeter.stateDidChangeNotification,
            object: TerminalFrameMeter.shared
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActorShim.assumeIsolated {
            surfaceView.onBackingPropertiesDidChange = nil
            surfaceView.onCellSizeDidChange = nil
            scrollFrameSampler.stop()
            frameMeterSampler.stop()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopSmoothScrollFrameSampling()
            stopFrameMeterSampling()
            stopSelectionAutoscrollTimer()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startFrameMeterSamplingIfNeeded()
    }

    override func layout() {
        ZenttyPerformanceSignposts.interval("LibghosttyScrollHostLayout") {
            super.layout()
            scrollView.frame = bounds
            overlayHostView.frame = bounds
            layoutFrameMeterHUD()
            surfaceView.frame.size = scrollView.bounds.size
            documentView.frame.size.width = scrollView.bounds.width
            updateSurfaceViewportDiagnosticsContext()
            recordViewportDiagnostics(.scrollHostLayout)
            recordScrollHostSync { synchronizeScrollView() }
            synchronizeSurfaceView()
            synchronizeCoreSurface()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if surfaceView.handleSecondaryMouseDownForContextMenuRouting(event) {
            return
        }

        if surfaceView.presentContextMenuForSecondaryClick(event, anchorView: self) {
            return
        }

        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if surfaceView.handleSecondaryMouseUpForContextMenuRouting(event) {
            return
        }

        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        surfaceView.rightMouseDragged(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        surfaceView.menu(for: event)
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        recordViewportDiagnostics(.scrollHostSyncSuspended, suspended: suspended)
        if suspended {
            surfaceView.setViewportSyncSuspended(true)
        } else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            surfaceView.setViewportSyncSuspended(false)
        }
    }

    func forceViewportSync() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        surfaceView.invalidateAndSyncViewport()
    }

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        let surfaceRects = rects.map { surfaceView.convert($0, from: self) }
        surfaceView.setMouseInteractionSuppressionRects(surfaceRects)
    }

    func applyScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate) {
        ZenttyPerformanceSignposts.interval("LibghosttyApplyScrollbar") {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let previousOffset = scrollbarUpdate.map { effectiveScrollOffset(for: $0) }
            let forceFollowBackingTransition = backingMetricsTransition?.wasBottomPinned == true &&
                backingMetricsTransition?.receivedCellSize == true
            if pendingExplicitWheelScroll {
                userScrolledAwayFromBottom = rowsBelowViewport(for: update) > 0
                allowExplicitScrollbarSync = true
                pendingExplicitWheelScroll = false
            }
            scrollbarUpdate = update
            if forceFollowBackingTransition {
                userScrolledAwayFromBottom = false
                allowExplicitScrollbarSync = true
            }
            if isLiveScrolling {
                needsLiveScrollReconciliation = true
            }
            selectionAutoscrollController.setViewportHeight(scrollView.contentView.bounds.height)
            selectionAutoscrollController.setScrollbarUpdate(update)
            recordScrollHostSync { synchronizeScrollView(forceFollowScrollbar: forceFollowBackingTransition) }
            if backingMetricsTransition?.receivedCellSize == true {
                cancelBackingMetricsTransition()
            }
            if previousOffset != effectiveScrollOffset(for: update),
               surfaceView.isSelectionDragActive,
               let location = selectionAutoscrollController.syntheticMouseLocation() ?? surfaceView.lastMouseLocationInView {
                surfaceView.forwardSyntheticMousePosition(location)
            }
            diagnostics.recordScrollbarApply(
                paneID: paneID,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
            )
        }
    }

    var surfaceViewForTesting: LibghosttyView {
        surfaceView
    }

    var debugFrameMeterHUDSnapshotForTesting: TerminalFrameMeterHUDView.Snapshot {
        frameMeterHUDView.snapshotForTesting
    }

    @objc
    private func handleScrollChangeNotification(_ notification: Notification) {
        handleScrollChange()
    }

    @objc
    private func handleWillStartLiveScrollNotification(_ notification: Notification) {
        cancelBackingMetricsTransition()
        isLiveScrolling = true
        startSmoothScrollFrameSamplingIfNeeded()
    }

    @objc
    private func handleDidEndLiveScrollNotification(_ notification: Notification) {
        handleEndLiveScroll()
    }

    @objc
    private func handleDidLiveScrollNotification(_ notification: Notification) {
        if smoothScrollingEnabled {
            sampleSmoothScrollFrame()
        } else {
            handleLiveScroll()
        }
    }

    @objc
    private func handleFrameMeterStateDidChangeNotification(_ notification: Notification) {
        syncFrameMeterHUDVisibility()
    }

    private func syncFrameMeterHUDVisibility() {
        guard TerminalFrameMeter.shared.isEnabled else {
            stopFrameMeterSampling()
            frameMeterHUDView.isHidden = true
            return
        }

        startFrameMeterSamplingIfNeeded()
        if let snapshot = TerminalFrameMeter.shared.latestSnapshot(for: paneID) {
            frameMeterHUDView.update(with: snapshot)
        } else {
            frameMeterHUDView.showWaiting()
        }
    }

    private func layoutFrameMeterHUD() {
        let size = NSSize(width: 128, height: 48)
        let inset: CGFloat = 8
        frameMeterHUDView.frame = NSRect(
            x: max(inset, overlayHostView.bounds.width - size.width - inset),
            y: max(inset, overlayHostView.bounds.height - size.height - inset),
            width: size.width,
            height: size.height
        )
    }

    private func startFrameMeterSamplingIfNeeded() {
        guard TerminalFrameMeter.shared.isEnabled else {
            return
        }

        frameMeterSampler.start(
            attachedTo: surfaceView,
            preferredFramesPerSecond: preferredScrollFramesPerSecond()
        )
    }

    private func stopFrameMeterSampling() {
        frameMeterSampler.stop()
    }

    private func updateSelectionAutoscrollTimerState() {
        if surfaceView.isSelectionDragActive {
            startSelectionAutoscrollTimerIfNeeded()
        } else {
            stopSelectionAutoscrollTimer()
        }
    }

    private func startSelectionAutoscrollTimerIfNeeded() {
        guard selectionAutoscrollTimer == nil else {
            return
        }

        lastSelectionAutoscrollTickTime = ProcessInfo.processInfo.systemUptime
        selectionAutoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.handleSelectionAutoscrollTick()
        }
        if let selectionAutoscrollTimer {
            RunLoop.main.add(selectionAutoscrollTimer, forMode: .common)
        }
    }

    private func stopSelectionAutoscrollTimer() {
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
        lastSelectionAutoscrollTickTime = nil
    }

    private func updateScrollElasticity() {
        scrollView.verticalScrollElasticity = smoothScrollingEnabled ? .allowed : .none
        scrollView.horizontalScrollElasticity = .none
    }

    private func handleEndLiveScroll() {
        isLiveScrolling = false
        if smoothScrollingEnabled {
            needsLiveScrollReconciliation = false
            sampleSmoothScrollFrame(force: true)
            return
        }

        stopSmoothScrollFrameSampling()
        guard needsLiveScrollReconciliation else {
            return
        }

        needsLiveScrollReconciliation = false
        DispatchQueue.main.async { [weak self] in
            self?.handleLiveScroll(force: true)
        }
    }

    private func startSmoothScrollFrameSamplingIfNeeded() {
        guard smoothScrollingEnabled else {
            return
        }

        smoothScrollStableFrameCount = 0
        lastSampledSmoothScrollOffset = nil
        scrollFrameSampler.start(
            attachedTo: surfaceView,
            preferredFramesPerSecond: preferredScrollFramesPerSecond()
        )
    }

    private func stopSmoothScrollFrameSampling() {
        scrollFrameSampler.stop()
        smoothScrollStableFrameCount = 0
        lastSampledSmoothScrollOffset = nil
    }

    private func sampleSmoothScrollFrame(force: Bool = false) {
        guard smoothScrollingEnabled else {
            stopSmoothScrollFrameSampling()
            return
        }

        guard let offset = currentLiveRowOffset(),
              let maxOffset = maxLiveRowOffset() else {
            if !isLiveScrolling {
                stopSmoothScrollFrameSampling()
            }
            return
        }

        let offsetChanged = lastSampledSmoothScrollOffset
            .map { abs($0 - offset) > smoothScrollOffsetEpsilonRows } ?? true

        if offsetChanged {
            recordFrameMeterSample(
                kind: .offset,
                rowOffset: offset,
                pacingMode: scrollFrameSampler.pacingMode
            )
        }

        let didSendScroll = handleLiveScroll(force: force)

        if didSendScroll {
            recordFrameMeterSample(
                kind: .sent,
                rowOffset: offset,
                pacingMode: scrollFrameSampler.pacingMode
            )
        }

        let isInBounds = offset >= 0 && offset <= maxOffset
        let isStable = lastSampledSmoothScrollOffset
            .map { abs($0 - offset) <= smoothScrollOffsetEpsilonRows } ?? false
        if !isLiveScrolling && isInBounds && isStable {
            smoothScrollStableFrameCount += 1
        } else {
            smoothScrollStableFrameCount = 0
        }
        lastSampledSmoothScrollOffset = offset

        if smoothScrollStableFrameCount >= Self.smoothScrollStableFrameLimit {
            stopSmoothScrollFrameSampling()
        }
    }

    private func preferredScrollFramesPerSecond() -> Int {
        let framesPerSecond = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 120
        return max(60, min(240, framesPerSecond))
    }

    private func recordFrameMeterDisplayTick() {
        let rowOffset = currentLiveRowOffset() ??
            lastSampledSmoothScrollOffset ??
            lastSentOffset ??
            0
        recordFrameMeterSample(
            kind: .tick,
            rowOffset: rowOffset,
            pacingMode: frameMeterSampler.pacingMode
        )
    }

    private func recordFrameMeterSample(
        kind: TerminalFrameMeter.SampleKind,
        rowOffset: Double,
        pacingMode: TerminalScrollFramePacingMode
    ) {
        if let frameMeterSnapshot = TerminalFrameMeter.shared.recordScrollFrameSample(
            paneID: paneID,
            rowOffset: rowOffset,
            preferredFramesPerSecond: preferredScrollFramesPerSecond(),
            displayID: surfaceView.currentDisplayID,
            isLiveScrolling: isLiveScrolling,
            sampleKind: kind,
            pacingMode: pacingMode
        ) {
            frameMeterHUDView.update(with: frameMeterSnapshot)
        } else {
            frameMeterHUDView.isHidden = true
        }
    }

    private func beginBackingMetricsReconciliation() {
        guard smoothScrollingEnabled else {
            return
        }

        let wasBottomPinned = isPinnedToScrollbarBottom()
        backingMetricsTransition = BackingMetricsTransition(wasBottomPinned: wasBottomPinned)
        isLiveScrolling = false
        needsLiveScrollReconciliation = false
        pendingExplicitWheelScroll = false
        stopSmoothScrollFrameSampling()
        if wasBottomPinned {
            userScrolledAwayFromBottom = false
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        recordScrollHostSync { synchronizeScrollView() }
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    private func handleTerminalCellSizeDidChange() {
        guard smoothScrollingEnabled else {
            backingMetricsTransition = nil
            needsLayout = true
            layoutSubtreeIfNeeded()
            recordScrollHostSync { synchronizeScrollView() }
            synchronizeSurfaceView()
            synchronizeCoreSurface()
            return
        }

        let shouldRestoreBottom = backingMetricsTransition?.wasBottomPinned == true
        if backingMetricsTransition != nil {
            backingMetricsTransition?.receivedCellSize = true
        }

        isLiveScrolling = false
        needsLiveScrollReconciliation = false
        pendingExplicitWheelScroll = false
        stopSmoothScrollFrameSampling()
        if shouldRestoreBottom {
            userScrolledAwayFromBottom = false
            allowExplicitScrollbarSync = true
            _ = surfaceView.performBindingAction(TerminalBindingAction.scrollToBottom)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        recordScrollHostSync { synchronizeScrollView(forceFollowScrollbar: shouldRestoreBottom) }
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    private func cancelBackingMetricsTransition() {
        backingMetricsTransition = nil
    }

    private func handleSelectionAutoscrollTick() {
        selectionAutoscrollController.setViewportHeight(scrollView.contentView.bounds.height)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - (lastSelectionAutoscrollTickTime ?? now))
        lastSelectionAutoscrollTickTime = now

        guard let result = selectionAutoscrollController.tick(elapsed: elapsed) else {
            return
        }

        diagnostics.recordScrollToRowAction(paneID: paneID)
        _ = surfaceView.performBindingAction("scroll_to_row:\(result.targetRow)")
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func snapLiveScrollToRowIfNeeded(offset: Double, cellHeight: CGFloat) {
        guard !smoothScrollingEnabled else {
            return
        }

        let targetOrigin = visibleOrigin(forLiveScrollOffset: offset, cellHeight: cellHeight)
        guard !pointApproximatelyEqual(scrollView.contentView.bounds.origin, targetOrigin) else {
            return
        }

        performProgrammaticScrollUpdate {
            scrollView.contentView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func snapCurrentScrollToRowAndNotifySurfaceIfNeeded() {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            return
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let scrollOffset = scrollOffsetFromTop(for: visibleRect)
        let rowOffset = normalizedScrollOffset(
            clampedLiveScrollOffset(forScrollOffset: scrollOffset, cellHeight: cellHeight)
        )
        let targetOrigin = visibleOrigin(forLiveScrollOffset: rowOffset, cellHeight: cellHeight)
        let didSnap = !pointApproximatelyEqual(scrollView.contentView.bounds.origin, targetOrigin)
        if didSnap {
            performProgrammaticScrollUpdate {
                scrollView.contentView.scroll(to: targetOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        synchronizeSurfaceView()
        guard didSnap || lastSentOffset.map({ abs($0 - rowOffset) >= 0.01 }) ?? true else {
            return
        }

        lastSentOffset = rowOffset
        lastSentRow = Int(rowOffset.rounded(.down))
        surfaceView.scroll(toOffset: rowOffset)
    }

    private var smoothScrollOffsetEpsilonRows: Double {
        let cellHeight = surfaceView.terminalCellHeight
        guard cellHeight > 0 else {
            return 0.01
        }

        return max(0.0001, 0.25 / Double(cellHeight))
    }

    private var terminalCellHeightPoints: CGFloat {
        surfaceView.terminalCellHeightInPoints
    }

    private func visibleOrigin(forLiveScrollOffset offset: Double, cellHeight: CGFloat) -> CGPoint {
        let viewportHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentView.frame.height - viewportHeight)
        let y = max(0, min(maxY, maxY - (CGFloat(offset) * cellHeight)))
        return CGPoint(x: 0, y: y)
    }

    private func currentLiveRowOffset() -> Double? {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            return nil
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let scrollOffset = scrollOffsetFromTop(for: visibleRect)
        return Double(scrollOffset / cellHeight)
    }

    private func maxLiveRowOffset() -> Double? {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            return nil
        }

        let maxOffset = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        return Double(maxOffset / cellHeight)
    }

    private func elasticLiveRowOffset(_ rowOffset: Double) -> Double {
        guard let maxOffset = maxLiveRowOffset() else {
            return rowOffset
        }

        if rowOffset < 0 {
            return rowOffset * Self.smoothElasticOverscrollMultiplier
        }

        if rowOffset > maxOffset {
            return maxOffset + ((rowOffset - maxOffset) * Self.smoothElasticOverscrollMultiplier)
        }

        return rowOffset
    }

    private func isPinnedToScrollbarBottom() -> Bool {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0,
              let scrollbarUpdate,
              let currentRowOffset = currentLiveRowOffset() else {
            return !userScrolledAwayFromBottom
        }

        let maxOffset = max(0, Double(scrollbarUpdate.total) - Double(scrollbarUpdate.len))
        let bottomSnapRows = Double(Self.scrollToBottomThreshold / cellHeight)
        if !userScrolledAwayFromBottom,
           rowsBelowViewport(for: scrollbarUpdate) <= bottomSnapRows {
            return true
        }

        return maxOffset - min(currentRowOffset, maxOffset) <= bottomSnapRows
    }

    private func adjustedLiveRowOffset(_ rowOffset: Double, previousMaxOffset: Double) -> Double {
        guard let newMaxOffset = maxLiveRowOffset() else {
            return rowOffset
        }

        if rowOffset > previousMaxOffset {
            return newMaxOffset + (rowOffset - previousMaxOffset)
        }

        return rowOffset
    }

    private func scroll(toLiveRowOffset rowOffset: Double) {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            return
        }

        performProgrammaticScrollUpdate {
            scrollView.contentView.scroll(to: visibleOrigin(forLiveScrollOffset: rowOffset, cellHeight: cellHeight))
        }
    }

    private func synchronizeCoreSurface() {
        guard scrollView.contentSize.width > 0, surfaceView.frame.height > 0 else {
            return
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        updateSurfaceViewportDiagnosticsContext()
        recordViewportDiagnostics(.scrollHostSync)
        surfaceView.syncViewport()
        diagnostics.recordViewportSync(
            paneID: paneID,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    func updateViewportDiagnosticsContext(_ context: TerminalViewportDiagnostics.Context) {
        viewportDiagnosticsContext = context
        updateSurfaceViewportDiagnosticsContext()
    }

    private func updateSurfaceViewportDiagnosticsContext() {
        var context = viewportDiagnosticsContext
        context.scrollHostBounds = bounds
        context.surfaceBounds = surfaceView.bounds
        context.windowAttached = window != nil
        surfaceView.updateViewportDiagnosticsContext(context)
    }

    private func recordViewportDiagnostics(
        _ source: TerminalViewportEventSource,
        suspended: Bool? = nil
    ) {
        var context = viewportDiagnosticsContext
        context.scrollHostBounds = bounds
        context.surfaceBounds = surfaceView.bounds
        context.windowAttached = window != nil
        if let suspended {
            context.isViewportSyncSuspended = suspended
        }
        TerminalViewportDiagnostics.shared.record(source, context: context)
    }

    private func synchronizeScrollView(forceFollowScrollbar: Bool = false) -> ScrollHostSyncMetrics {
        var didChangeGeometry = false
        let previousDocumentHeight = documentView.frame.height
        let liveRowOffset = isLiveScrolling && smoothScrollingEnabled ? currentLiveRowOffset() : nil
        let liveMaxRowOffset = isLiveScrolling && smoothScrollingEnabled ? maxLiveRowOffset() : nil
        let targetDocumentHeight = documentHeight()
        var scrollbarTotalRows: UInt64?
        var scrollbarOffsetRows: Double?
        var scrollbarVisibleRows: UInt64?
        var wasAtBottom: Bool?
        var shouldAutoScroll: Bool?
        var autoScrollApplied = false
        var explicitScrollbarSyncAllowed: Bool?
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if isLiveScrolling, smoothScrollingEnabled,
           let liveRowOffset,
           let liveMaxRowOffset {
            scroll(toLiveRowOffset: adjustedLiveRowOffset(liveRowOffset, previousMaxOffset: liveMaxRowOffset))
            didChangeGeometry = true
        } else if !isLiveScrolling {
            let cellHeight = terminalCellHeightPoints
            if cellHeight > 0, let scrollbarUpdate {
                scrollbarTotalRows = scrollbarUpdate.total
                let effectiveOffset = effectiveScrollOffset(for: scrollbarUpdate)
                scrollbarOffsetRows = effectiveOffset
                scrollbarVisibleRows = scrollbarUpdate.len
                let offsetY = CGFloat(rowsBelowViewport(for: scrollbarUpdate)) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                let currentOrigin = scrollView.contentView.bounds.origin
                let visibleRect = NSRect(origin: currentOrigin, size: scrollView.contentView.bounds.size)
                let currentRowOffset = Double(scrollOffsetFromTop(for: visibleRect) / cellHeight)
                let maxOffset = max(0, Double(scrollbarUpdate.total) - Double(scrollbarUpdate.len))
                let bottomSnapRows = Double(Self.scrollToBottomThreshold / cellHeight)
                let isAtBottom = maxOffset - min(currentRowOffset, maxOffset) <= bottomSnapRows
                wasAtBottom = isAtBottom
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                let explicitScrollbarSyncAllowedNow = allowExplicitScrollbarSync
                explicitScrollbarSyncAllowed = explicitScrollbarSyncAllowedNow
                let offsetChanged = lastSentOffset.map { abs($0 - effectiveOffset) >= 0.01 } ?? true
                let shouldFollowSelectionDrag = surfaceView.isSelectionDragActive && offsetChanged
                let shouldAutoScrollNow = forceFollowScrollbar ||
                    shouldFollowSelectionDrag ||
                    !userScrolledAwayFromBottom ||
                    explicitScrollbarSyncAllowedNow
                shouldAutoScroll = shouldAutoScrollNow
                if shouldAutoScrollNow && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    performProgrammaticScrollUpdate {
                        scrollView.contentView.scroll(to: targetOrigin)
                    }
                    didChangeGeometry = true
                    autoScrollApplied = true
                }
                lastSentOffset = effectiveOffset
                lastSentRow = Int(effectiveOffset.rounded(.down))
            }
        }

        allowExplicitScrollbarSync = false

        var reflected = false
        if didChangeGeometry {
            performProgrammaticScrollUpdate {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            reflected = true
        }

        let documentHeightDelta = abs(targetDocumentHeight - previousDocumentHeight)
        return ScrollHostSyncMetrics(
            geometryApplied: didChangeGeometry,
            documentHeightChanged: documentHeightDelta > 0.5,
            documentHeightPoints: targetDocumentHeight,
            documentHeightDeltaPoints: documentHeightDelta,
            reflected: reflected,
            scrollbarTotalRows: scrollbarTotalRows,
            scrollbarOffsetRows: scrollbarOffsetRows,
            scrollbarVisibleRows: scrollbarVisibleRows,
            wasAtBottom: wasAtBottom,
            shouldAutoScroll: shouldAutoScroll,
            autoScrollApplied: autoScrollApplied,
            userScrolledAwayFromBottom: scrollbarUpdate.map { _ in userScrolledAwayFromBottom },
            explicitScrollbarSyncAllowed: explicitScrollbarSyncAllowed
        )
    }

    private func handleScrollChange() {
        if isLiveScrolling, !smoothScrollingEnabled {
            let cellHeight = terminalCellHeightPoints
            if cellHeight > 0 {
                let visibleRect = scrollView.contentView.documentVisibleRect
                let scrollOffset = scrollOffsetFromTop(for: visibleRect)
                let rowOffset = clampedLiveScrollOffset(
                    forScrollOffset: scrollOffset,
                    cellHeight: cellHeight
                ).rounded(.down)
                snapLiveScrollToRowIfNeeded(offset: rowOffset, cellHeight: cellHeight)
            }
        }
        synchronizeSurfaceView()
        if programmaticScrollUpdateDepth == 0,
           shouldRecordUserScrollChange() {
            updateUserScrolledAwayFromBottomState()
        }
    }

    private func shouldRecordUserScrollChange() -> Bool {
        if smoothScrollingEnabled {
            return isLiveScrolling
        }

        return backingMetricsTransition?.wasBottomPinned != true || isLiveScrolling
    }

    private func performProgrammaticScrollUpdate(_ body: () -> Void) {
        // Internal scroll synchronization also emits bounds-change notifications;
        // those must not be treated as user intent to leave the bottom.
        programmaticScrollUpdateDepth += 1
        defer {
            programmaticScrollUpdateDepth -= 1
        }
        body()
    }

    @discardableResult
    private func handleLiveScroll(force: Bool = false) -> Bool {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            return false
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let rawScrollOffset = scrollOffsetFromTop(for: visibleRect)
        let clampedScrollOffset = max(0, rawScrollOffset)
        if smoothScrollingEnabled {
            updateUserScrolledAwayFromBottomState(liveRowOffset: Double(rawScrollOffset / cellHeight))
        } else {
            updateUserScrolledAwayFromBottomState(visibleRect: visibleRect)
        }

        let offset: Double
        if smoothScrollingEnabled {
            offset = elasticLiveRowOffset(Double(rawScrollOffset / cellHeight))
        } else {
            offset = normalizedScrollOffset(
                clampedLiveScrollOffset(forScrollOffset: clampedScrollOffset, cellHeight: cellHeight)
            )
        }
        snapLiveScrollToRowIfNeeded(offset: offset, cellHeight: cellHeight)
        let offsetEpsilon = smoothScrollingEnabled ? smoothScrollOffsetEpsilonRows : 0.01
        guard force || lastSentOffset.map({ abs($0 - offset) >= offsetEpsilon }) ?? true else {
            return false
        }

        lastSentOffset = offset
        lastSentRow = Int(max(0, offset).rounded(.down))
        diagnostics.recordScrollToRowAction(paneID: paneID)
        surfaceView.scroll(toOffset: offset)
        return true
    }

    private func recordScrollHostSync(_ body: () -> ScrollHostSyncMetrics) {
        ZenttyPerformanceSignposts.interval("LibghosttySynchronizeScrollView") {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let metrics = body()
            diagnostics.recordScrollHostSync(
                paneID: paneID,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt,
                geometryApplied: metrics.geometryApplied,
                documentHeightChanged: metrics.documentHeightChanged,
                documentHeightPoints: metrics.documentHeightPoints,
                documentHeightDeltaPoints: metrics.documentHeightDeltaPoints,
                reflected: metrics.reflected,
                scrollbarTotalRows: metrics.scrollbarTotalRows,
                scrollbarOffsetRows: metrics.scrollbarOffsetRows,
                scrollbarVisibleRows: metrics.scrollbarVisibleRows,
                wasAtBottom: metrics.wasAtBottom,
                shouldAutoScroll: metrics.shouldAutoScroll,
                autoScrollApplied: metrics.autoScrollApplied,
                userScrolledAwayFromBottom: metrics.userScrolledAwayFromBottom,
                explicitScrollbarSyncAllowed: metrics.explicitScrollbarSyncAllowed
            )
        }
    }

    private func scrollOffsetFromTop(for visibleRect: NSRect) -> CGFloat {
        documentView.frame.height - visibleRect.origin.y - visibleRect.height
    }

    private func updateUserScrolledAwayFromBottomState(visibleRect: NSRect? = nil) {
        let cellHeight = terminalCellHeightPoints
        guard cellHeight > 0 else {
            userScrolledAwayFromBottom = false
            return
        }

        let visibleRect = visibleRect ?? scrollView.contentView.documentVisibleRect
        updateUserScrolledAwayFromBottomState(liveRowOffset: Double(scrollOffsetFromTop(for: visibleRect) / cellHeight))
    }

    private func updateUserScrolledAwayFromBottomState(liveRowOffset: Double) {
        guard let scrollbarUpdate else {
            userScrolledAwayFromBottom = liveRowOffset > 0
            return
        }

        let maxOffset = max(0, Double(scrollbarUpdate.total) - Double(scrollbarUpdate.len))
        userScrolledAwayFromBottom = maxOffset - min(liveRowOffset, maxOffset) > 0.01
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = terminalCellHeightPoints
        if cellHeight > 0, let scrollbarUpdate {
            let documentGridHeight = CGFloat(scrollbarUpdate.total) * cellHeight
            let padding = max(0, contentHeight - (CGFloat(scrollbarUpdate.len) * cellHeight))
            return documentGridHeight + padding
        }

        return contentHeight
    }

    private func rowsBelowViewport(for update: LibghosttySurfaceScrollbarUpdate) -> Double {
        let remainingRows = Double(update.total) - effectiveScrollOffset(for: update)
        let visibleRows = min(Double(update.len), max(0, remainingRows))
        return max(0, remainingRows - visibleRows)
    }

    private func clampedOffset(for update: LibghosttySurfaceScrollbarUpdate) -> Double {
        min(max(update.offset, 0), max(0, Double(update.total) - Double(update.len)))
    }

    private func effectiveScrollOffset(for update: LibghosttySurfaceScrollbarUpdate) -> Double {
        normalizedScrollOffset(clampedOffset(for: update))
    }

    private func normalizedScrollOffset(_ offset: Double) -> Double {
        smoothScrollingEnabled ? offset : offset.rounded(.down)
    }

    private func clampedLiveScrollOffset(forScrollOffset scrollOffset: CGFloat, cellHeight: CGFloat) -> Double {
        let rawOffset = Double(scrollOffset / cellHeight)
        guard let scrollbarUpdate else {
            return max(rawOffset, 0)
        }

        let maxOffset = max(0, Double(scrollbarUpdate.total) - Double(scrollbarUpdate.len))
        let clampedOffset = min(max(rawOffset, 0), maxOffset)
        let bottomSnapRows = Double(Self.scrollToBottomThreshold / cellHeight)
        if maxOffset - clampedOffset <= bottomSnapRows {
            return maxOffset
        }

        return clampedOffset
    }

    private func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }
}

final class LibghosttyView: NSView, TerminalFocusReporting, TerminalViewportDiagnosticsContextConfiguring {
    private struct ViewportSignature: Equatable {
        let size: CGSize
        let scale: CGFloat
        let displayID: UInt32?
    }

    private static let terminalCommandSelectors: [Selector] = [
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.deleteBackward(_:)),
        #selector(NSResponder.deleteForward(_:)),
        #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.moveLeft(_:)),
        #selector(NSResponder.moveRight(_:)),
        #selector(NSResponder.moveToBeginningOfDocument(_:)),
        #selector(NSResponder.moveToBeginningOfLine(_:)),
        #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.moveToEndOfLine(_:)),
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.pageDown(_:)),
        #selector(NSResponder.pageUp(_:)),
        #selector(NSResponder.scrollPageDown(_:)),
        #selector(NSResponder.scrollPageUp(_:)),
    ]

    private struct SecondaryMouseRouting {
        let button: ghostty_input_mouse_button_e
        let behavesLikePrimarySelection: Bool
    }

    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var smoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled
    private var lastViewportSignature: ViewportSignature?
    private var lastLayerGeometrySignature: ViewportSignature?
    private var isViewportSyncSuspended = false
    private(set) var hasValidViewportSync = false
    private var viewportDiagnosticsContext = TerminalViewportDiagnostics.Context()
    private let inputBreadcrumbThrottler = TerminalInputBreadcrumbThrottler()
    private var keyTextAccumulator = ""
    private var markedTextStorage = ""
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var selectedTextStorageRange = NSRange(location: NSNotFound, length: 0)
    private var currentCursor: NSCursor = .iBeam
    private var mouseTrackingArea: NSTrackingArea?
    private var mouseInteractionSuppressionRects: [CGRect] = []
    private var activeSecondaryMouseRouting: SecondaryMouseRouting?
    private var forwardsActiveSecondaryMouseDrag = false
    fileprivate private(set) var isSelectionDragActive = false
    fileprivate private(set) var lastMouseLocationInView: CGPoint?
    private var lastMouseModifiers: NSEvent.ModifierFlags = []
    fileprivate weak var scrollbarHandler: (any LibghosttyScrollbarHandling)?
    var onFocusDidChange: ((Bool) -> Void)?
    var onLocalEventDidOccur: ((TerminalEvent) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var onExplicitWheelScroll: (() -> Void)?
    var onSelectionDragStateDidChange: ((Bool) -> Void)?
    var onMouseLocationDidChange: ((CGPoint?) -> Void)?
    var onBackingPropertiesDidChange: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?
    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)?
    var contextMenuPresenter: ((NSMenu, NSEvent, NSView) -> Void)?
    private var terminalCellSizeInPoints: CGSize?

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer.contentsScale = currentScaleFactor
        metalLayer.displaySyncEnabled = true
        return metalLayer
    }

    override func layout() {
        ZenttyPerformanceSignposts.interval("LibghosttyViewLayout") {
            super.layout()
            syncViewport()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = currentScaleFactor
        CATransaction.commit()
        syncViewport()
        onBackingPropertiesDidChange?()
    }

    override func becomeFirstResponder() -> Bool {
        ZenttyPerformanceSignposts.event("LibghosttyBecameFirstResponder")
        surfaceController?.setFocused(true)
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        surfaceController?.setFocused(false)
        onFocusDidChange?(false)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons != 0 {
            return
        }

        lastMouseLocationInView = nil
        onMouseLocationDidChange?(nil)
        lastMouseModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        surfaceController?.sendMousePosition(
            CGPoint(x: -1, y: -1),
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: currentCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        currentCursor.set()
    }

    func setMouseCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            .resizeUpDown
        default:
            .arrow
        }

        guard cursor != currentCursor else { return }
        currentCursor = cursor
        if let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !isPointInsideSuppressedMouseRegion(location) {
                currentCursor.set()
            }
        } else {
            currentCursor.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        isSelectionDragActive = true
        onSelectionDragStateDidChange?(true)
        window?.makeFirstResponder(self)
        forwardMousePosition(event)
        _ = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
    }

    override func mouseUp(with event: NSEvent) {
        isSelectionDragActive = false
        onSelectionDragStateDidChange?(false)
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
        _ = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        if handleSecondaryMouseDownForContextMenuRouting(event) {
            return
        }

        if presentContextMenuForSecondaryClick(event, anchorView: self) {
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard forwardsActiveSecondaryMouseDrag else {
            return
        }
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        _ = handleSecondaryMouseUpForContextMenuRouting(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.ghosttyMouseButton(forButtonNumber: event.buttonNumber) else {
            super.otherMouseDown(with: event)
            return
        }
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        // Match left/right click: focus the clicked pane so a middle-click paste (and
        // any subsequent typing) lands in the pane the user actually clicked.
        window?.makeFirstResponder(self)
        forwardMousePosition(event)
        _ = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: button,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.ghosttyMouseButton(forButtonNumber: event.buttonNumber) else {
            super.otherMouseUp(with: event)
            return
        }
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
        _ = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: button,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    /// Maps an AppKit `otherMouse*` button number to the libghostty mouse button enum.
    ///
    /// `otherMouseDown` fires for the middle button and any extra buttons (back/forward),
    /// so we map only the buttons libghostty understands and ignore the rest. Mirrors
    /// Ghostty's own `Ghostty.Input.MouseButton(fromNSEventButtonNumber:)` mapping; the
    /// middle button is what enables middle-click paste (libghostty pastes the selection
    /// clipboard on a middle-button press).
    private static func ghosttyMouseButton(
        forButtonNumber buttonNumber: Int
    ) -> ghostty_input_mouse_button_e? {
        switch buttonNumber {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT // back
        case 4: return GHOSTTY_MOUSE_NINE // forward
        default: return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if consumeScrollWheelForTerminalInputIfNeeded(event) {
            return
        } else {
            super.scrollWheel(with: event)
        }
    }

    fileprivate func consumeScrollWheelBeforeTerminalFocusIfNeeded(_ event: NSEvent) -> Bool {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return true
        }
        if onScrollWheel?(event) == true {
            return true
        }

        return false
    }

    fileprivate func consumeScrollWheelForTerminalInputIfNeeded(
        _ event: NSEvent,
        routeOutwardFirst: Bool = true
    ) -> Bool {
        if routeOutwardFirst, consumeScrollWheelBeforeTerminalFocusIfNeeded(event) {
            return true
        }

        guard let surfaceController else {
            return false
        }

        if smoothScrollingEnabled && !surfaceController.mouseScrollIsTerminalInput {
            return false
        }

        onExplicitWheelScroll?()
        recordTerminalInputBreadcrumb(
            message: "scroll",
            data: [
                "precision": event.hasPreciseScrollingDeltas,
                "momentum": event.momentumPhase != [],
            ]
        )
        surfaceController.sendMouseScroll(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            precision: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase
        )
        return true
    }

    override func keyDown(with event: NSEvent) {
        recordTerminalInputBreadcrumb(
            message: "key",
            data: [
                "repeat": event.isARepeat,
            ]
        )
        guard let surfaceController else {
            super.keyDown(with: event)
            return
        }

        if Self.shouldDeferToSystemWindowTiling(for: event) {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldEmitUserSubmittedInput = Self.shouldEmitUserSubmittedInput(for: event)
        let shouldEmitUserEditedInput = Self.shouldEmitUserEditedInput(for: event)
        let shouldEmitUserInterrupted = Self.shouldEmitUserInterrupted(for: event)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            let controlText = event.charactersIgnoringModifiers ?? event.characters
            let handled = surfaceController.sendKey(
                event: event,
                action: event.isARepeat ? .repeatPress : .press,
                text: controlText,
                composing: false
            )
            if handled {
                if shouldEmitUserSubmittedInput {
                    onLocalEventDidOccur?(.userSubmittedInput)
                }
                if shouldEmitUserEditedInput {
                    onLocalEventDidOccur?(.userEditedInput)
                }
                if shouldEmitUserInterrupted {
                    onLocalEventDidOccur?(.userInterrupted)
                }
                return
            }
        }

        keyTextAccumulator = ""
        interpretKeyEvents([event])
        let keyText = keyTextAccumulator.isEmpty ? fallbackText(for: event) : keyTextAccumulator
        _ = surfaceController.sendKey(
            event: event,
            action: event.isARepeat ? .repeatPress : .press,
            text: keyText,
            composing: hasMarkedText()
        )
        if shouldEmitUserSubmittedInput {
            onLocalEventDidOccur?(.userSubmittedInput)
        }
        if shouldEmitUserEditedInput {
            onLocalEventDidOccur?(.userEditedInput)
        }
        if shouldEmitUserInterrupted {
            onLocalEventDidOccur?(.userInterrupted)
        }
        keyTextAccumulator = ""
    }

    override func keyUp(with event: NSEvent) {
        guard let surfaceController else {
            super.keyUp(with: event)
            return
        }

        _ = surfaceController.sendKey(event: event, action: .release, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        lastMouseModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let surfaceController else {
            super.flagsChanged(with: event)
            return
        }

        _ = surfaceController.sendKey(event: event, action: .press, text: nil, composing: false)
    }

    nonisolated override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    nonisolated override func doCommand(by selector: Selector) {
        MainActorShim.assumeIsolated {
            // Terminal navigation/editing commands should be handled by Ghostty via keycode,
            // not converted into printable fallback text by AppKit.
            if Self.terminalCommandSelectors.contains(where: { $0 == selector }) {
                self.keyTextAccumulator = ""
            }
        }
    }

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        mouseInteractionSuppressionRects = rects
        window?.invalidateCursorRects(for: self)
    }

    private func isPointInsideSuppressedMouseRegion(_ point: CGPoint) -> Bool {
        mouseInteractionSuppressionRects.contains { $0.contains(point) }
    }

    fileprivate func handleSecondaryMouseDownForContextMenuRouting(_ event: NSEvent) -> Bool {
        activeSecondaryMouseRouting = nil
        forwardsActiveSecondaryMouseDrag = false
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return true
        }
        window?.makeFirstResponder(self)
        forwardMousePosition(event)
        let routing = secondaryMouseRouting(for: event)
        activeSecondaryMouseRouting = routing

        let consumed = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: routing.button,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        ) ?? false

        if consumed, routing.behavesLikePrimarySelection {
            forwardsActiveSecondaryMouseDrag = true
            isSelectionDragActive = true
            onSelectionDragStateDidChange?(true)
        }

        return consumed
    }

    fileprivate func handleSecondaryMouseUpForContextMenuRouting(_ event: NSEvent) -> Bool {
        let routing = activeSecondaryMouseRouting ?? secondaryMouseRouting(for: event)
        let wasForwardingActiveSecondaryMouseDrag = forwardsActiveSecondaryMouseDrag
        activeSecondaryMouseRouting = nil
        forwardsActiveSecondaryMouseDrag = false
        if wasForwardingActiveSecondaryMouseDrag {
            isSelectionDragActive = false
            onSelectionDragStateDidChange?(false)
        }

        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return true
        }
        forwardMousePosition(event)

        return surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: routing.button,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        ) ?? false
    }

    private func secondaryMouseRouting(for event: NSEvent) -> SecondaryMouseRouting {
        if event.modifierFlags.contains(.control), event.buttonNumber == 0 {
            return SecondaryMouseRouting(button: GHOSTTY_MOUSE_LEFT, behavesLikePrimarySelection: true)
        }

        return SecondaryMouseRouting(button: GHOSTTY_MOUSE_RIGHT, behavesLikePrimarySelection: false)
    }

    @IBAction func copy(_ sender: Any?) {
        if CleanCopyPipeline.shouldCleanTerminalCopyAction() {
            CleanCopyPipeline.suppressCallbackCleaning = true
            _ = surfaceController?.performBindingAction(TerminalBindingAction.copyToClipboard)
            CleanCopyPipeline.suppressCallbackCleaning = false
            let result = CleanCopyPipeline.cleanPasteboardInPlace(.general)
            if result?.wasModified == true {
                NotificationCenter.default.post(name: .cleanCopyDidModifyPasteboard, object: nil)
            }
        } else {
            _ = surfaceController?.performBindingAction(TerminalBindingAction.copyToClipboard)
        }
    }

    private static func shouldEmitUserSubmittedInput(for event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) || flags.contains(.shift) || flags.contains(.function) {
            return false
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            return true
        }

        let characters = event.charactersIgnoringModifiers ?? event.characters
        return characters == "\r" || characters == "\n" || characters == "\u{3}"
    }

    private static func shouldEmitUserEditedInput(for event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) || flags.contains(.function) {
            return false
        }

        // Return, Tab, Enter, Home, PgUp, forward delete, End, PgDn, and arrows
        // are navigation/editing control keys. Only forward delete mutates input here.
        switch event.keyCode {
        case 36, 48, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            return event.keyCode == 117
        case 51:
            return true
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers ?? event.characters
        guard let characters, !characters.isEmpty else {
            return false
        }

        return sanitizedInputText(characters) != nil
    }

    private static func shouldEmitUserInterrupted(for event: NSEvent) -> Bool {
        TerminalInterruptKeyRecognizer.matchesUserInterrupt(event)
    }

    private static func shouldDeferToSystemWindowTiling(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.function), !flags.contains(.command) else {
            return false
        }

        switch event.keyCode {
        case 123, 124, 125, 126:
            let allowedFlags: NSEvent.ModifierFlags = [.control, .function, .shift, .option]
            return flags.subtracting(allowedFlags).isEmpty
        default:
            let requiredFlags: NSEvent.ModifierFlags = [.control, .function]
            let normalizedCharacters = (event.charactersIgnoringModifiers ?? event.characters)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return flags == requiredFlags && normalizedCharacters.map { ["f", "c", "r"].contains($0) } == true
        }
    }

    @IBAction func paste(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(TerminalBindingAction.pasteFromClipboard)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(TerminalBindingAction.selectAll)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            guard event.modifierFlags.contains(.control) else {
                return nil
            }

            guard surfaceController?.mouseCaptured != true else {
                return nil
            }

            forwardContextMenuMousePress(event)
        default:
            return nil
        }

        let systemMenu = super.menu(for: event)
        return contextMenuBuilder?(event, systemMenu) ?? systemMenu
    }

    @discardableResult
    fileprivate func presentContextMenuForSecondaryClick(_ event: NSEvent, anchorView: NSView) -> Bool {
        guard let menu = menu(for: event) else {
            return false
        }

        if let contextMenuPresenter {
            contextMenuPresenter(menu, event, anchorView)
        } else {
            NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        }

        return true
    }

    private func forwardContextMenuMousePress(_ event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }

        window?.makeFirstResponder(self)
        forwardMousePosition(event)
        _ = surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    func bind(surfaceController: any LibghosttySurfaceControlling) {
        self.surfaceController = surfaceController
        updateTerminalCellSizeCache(
            width: surfaceController.cellWidth,
            height: surfaceController.cellHeight
        )
        surfaceController.setSmoothScrollingEnabled(smoothScrollingEnabled)
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        guard isViewportSyncSuspended != suspended else {
            return
        }

        isViewportSyncSuspended = suspended
        recordViewportDiagnostics(suspended ? .syncSuspended : .syncUnsuspended)
        if !suspended {
            syncViewport()
        }
    }

    func updateViewportDiagnosticsContext(_ context: TerminalViewportDiagnostics.Context) {
        viewportDiagnosticsContext = context
    }

    var viewportDiagnosticsContextForSurface: TerminalViewportDiagnostics.Context {
        var context = viewportDiagnosticsContext
        context.surfaceBounds = bounds
        context.windowAttached = window != nil
        context.isViewportSyncSuspended = isViewportSyncSuspended
        return context
    }

    var currentDisplayID: UInt32? {
        guard let screen = window?.screen ?? NSScreen.main else {
            return nil
        }

        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }

        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private var currentScaleFactor: CGFloat {
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? NSScreen.main?.backingScaleFactor ?? 1
        return max(scale, 1)
    }

    var normalizedBackingViewportSize: CGSize {
        Self.normalizedBackingViewportSize(from: convertToBacking(bounds).size)
    }

    fileprivate func syncViewport() {
        recordViewportDiagnostics(.syncAttempt)
        guard bounds.width > 0, bounds.height > 0 else {
            recordViewportDiagnostics(.syncSkippedZeroBounds)
            return
        }

        guard window != nil else {
            recordViewportDiagnostics(.syncSkippedNoWindow)
            return
        }

        if isViewportSyncSuspended {
            recordViewportDiagnostics(.syncSkippedSuspended)
            return
        }

        let viewportSize = normalizedBackingViewportSize
        let viewportSignature = ViewportSignature(
            size: viewportSize,
            scale: currentScaleFactor,
            displayID: currentDisplayID
        )

        syncLayerGeometryIfNeeded(signature: viewportSignature)

        guard viewportSignature != lastViewportSignature else {
            recordViewportDiagnostics(.syncSkippedDuplicate, nextSignature: viewportSignature)
            return
        }

        let previousSignature = lastViewportSignature
        lastViewportSignature = viewportSignature
        recordViewportDiagnostics(
            .libghosttyUpdateViewport,
            previousSignature: previousSignature,
            nextSignature: viewportSignature
        )
        surfaceController?.updateViewport(
            size: viewportSignature.size,
            scale: viewportSignature.scale,
            displayID: viewportSignature.displayID
        )
        surfaceController?.refresh()
        hasValidViewportSync = true
    }

    private func recordViewportDiagnostics(
        _ source: TerminalViewportEventSource,
        previousSignature: ViewportSignature? = nil,
        nextSignature: ViewportSignature? = nil
    ) {
        var context = viewportDiagnosticsContext
        context.surfaceBounds = bounds
        context.windowAttached = window != nil
        context.isViewportSyncSuspended = isViewportSyncSuspended
        context.previousViewportSize = previousSignature?.size ?? lastViewportSignature?.size
        context.viewportSize = nextSignature?.size
        context.scale = nextSignature?.scale ?? currentScaleFactor
        context.displayID = nextSignature?.displayID ?? currentDisplayID
        TerminalViewportDiagnostics.shared.record(source, context: context)
    }

    func invalidateAndSyncViewport() {
        lastViewportSignature = nil
        syncViewport()
    }

    var terminalCellHeight: CGFloat {
        surfaceController?.cellHeight ?? 0
    }

    var terminalCellHeightInPoints: CGFloat {
        if let pointHeight = terminalCellSizeInPoints?.height, pointHeight > 0 {
            return pointHeight
        }

        let cellHeight = terminalCellHeight
        guard cellHeight > 0 else {
            return 0
        }

        updateTerminalCellSizeCache(
            width: surfaceController?.cellWidth ?? 0,
            height: cellHeight
        )
        return terminalCellSizeInPoints?.height ?? 0
    }

    func performBindingAction(_ action: String) -> Bool {
        surfaceController?.performBindingAction(action) ?? false
    }

    func scroll(toOffset offset: Double) {
        surfaceController?.scroll(toOffset: offset)
    }

    func setSmoothScrollingEnabled(_ enabled: Bool) {
        guard smoothScrollingEnabled != enabled else {
            return
        }
        smoothScrollingEnabled = enabled
        surfaceController?.setSmoothScrollingEnabled(enabled)
    }

    func applyScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate) {
        scrollbarHandler?.applyScrollbarUpdate(update)
    }

    func applyCellSizeUpdate(width: CGFloat, height: CGFloat) {
        updateTerminalCellSizeCache(width: width, height: height)
        onCellSizeDidChange?()
    }

    private func updateTerminalCellSizeCache(width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else {
            return
        }

        let scale = currentScaleFactor
        terminalCellSizeInPoints = CGSize(width: width / scale, height: height / scale)
    }

    private static func normalizedBackingViewportSize(from backingSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, backingSize.width.rounded()),
            height: max(1, backingSize.height.rounded())
        )
    }

    private func syncLayerGeometryIfNeeded(signature: ViewportSignature) {
        let shouldUpdateLayerScale = layer?.contentsScale != signature.scale
        let shouldUpdateDrawableSize = (layer as? CAMetalLayer).map { $0.drawableSize != signature.size } ?? false
        guard shouldUpdateLayerScale || shouldUpdateDrawableSize || lastLayerGeometrySignature != signature else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shouldUpdateLayerScale {
            layer?.contentsScale = signature.scale
        }
        if shouldUpdateDrawableSize, let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = signature.size
        }
        CATransaction.commit()
        lastLayerGeometrySignature = signature
    }

    private func recordTerminalInputBreadcrumb(message: String, data: [String: Any]) {
        let now = Date()
        guard inputBreadcrumbThrottler.shouldRecord(now: now) else {
            return
        }
        ZenttyBreadcrumbs.record(
            category: "zentty.input.terminal",
            message: message,
            data: data,
            now: now
        )
    }

    private func fallbackText(for event: NSEvent) -> String? {
        LibghosttySurface.textForKeyEvent(event)
    }

    private static func sanitizedInputText(_ text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        let scalars = text.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }

        if scalars.allSatisfy({ $0.value >= 0xF700 && $0.value <= 0xF8FF }) {
            return nil
        }

        return text
    }

    private func forwardMousePosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocationInView = point
        onMouseLocationDidChange?(point)
        lastMouseModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let position = CGPoint(x: point.x, y: bounds.height - point.y)
        surfaceController?.sendMousePosition(
            position,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    fileprivate func forwardSyntheticMousePosition(_ point: CGPoint) {
        let position = CGPoint(x: point.x, y: bounds.height - point.y)
        surfaceController?.sendMousePosition(position, modifiers: lastMouseModifiers)
    }
}

@MainActor
extension LibghosttyView: TerminalViewportSyncControlling {}

@MainActor
extension LibghosttyView: TerminalFocusTargetProviding {
    var terminalFocusTargetView: NSView { self }
}

@MainActor
extension LibghosttyView: TerminalScrollRouting {}

@MainActor
extension LibghosttyView: TerminalContextMenuConfiguring {}

extension LibghosttyView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)),
             #selector(MainWindowController.cleanCopy(_:)),
             #selector(MainWindowController.copyRaw(_:)):
            return surfaceController?.hasSelection() ?? false
        default:
            return true
        }
    }
}

extension LibghosttyView: NSTextInputClient {
    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = "\(string)"
        }

        MainActorShim.assumeIsolated {
            self.markedTextStorage = ""
            self.markedTextSelection = NSRange(location: NSNotFound, length: 0)
            self.selectedTextStorageRange = NSRange(location: NSNotFound, length: 0)

            guard let text = Self.sanitizedInputText(text) else {
                return
            }

            if self.keyTextAccumulator.isEmpty, NSApp.currentEvent == nil {
                self.surfaceController?.sendText(text)
                return
            }

            self.keyTextAccumulator += text
        }
    }

    nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = "\(string)"
        }

        MainActorShim.assumeIsolated {
            self.markedTextStorage = text
            self.markedTextSelection = selectedRange
            self.selectedTextStorageRange = replacementRange
        }
    }

    nonisolated func unmarkText() {
        MainActorShim.assumeIsolated {
            self.markedTextStorage = ""
            self.markedTextSelection = NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func selectedRange() -> NSRange {
        MainActorShim.assumeIsolated {
            self.selectedTextStorageRange
        }
    }

    nonisolated func markedRange() -> NSRange {
        MainActorShim.assumeIsolated {
            !self.markedTextStorage.isEmpty
                ? NSRange(location: 0, length: self.markedTextStorage.utf16.count)
                : NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func hasMarkedText() -> Bool {
        MainActorShim.assumeIsolated {
            !self.markedTextStorage.isEmpty
        }
    }

    nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = MainActorShim.assumeIsolated {
            guard let window = self.window else {
                return NSRect.zero
            }

            let rectInWindow = self.convert(self.bounds, to: nil)
            return window.convertToScreen(rectInWindow)
        }
        actualRange?.pointee = range
        return rect
    }

    nonisolated func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

// MARK: - NSDraggingDestination

extension LibghosttyView {
    private static let acceptedDropTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .URL, .string, .png, .tiff,
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.acceptedDropTypes) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        let content: String?
        if let url = pasteboard.string(forType: .URL) {
            content = ShellEscaping.escapePath(url)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty {
            content = urls
                .map { ShellEscaping.escapePath($0.path) }
                .joined(separator: " ")
        } else if let string = pasteboard.string(forType: .string) {
            content = string
        } else if let imagePath = TerminalClipboard.pastedContent(from: pasteboard),
                  case .filePath(let path) = imagePath {
            content = path
        } else {
            content = nil
        }

        guard let content else { return false }
        surfaceController?.sendText(content)
        return true
    }
}
