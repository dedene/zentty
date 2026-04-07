import AppKit
import GhosttyKit
import QuartzCore

@MainActor
protocol TerminalViewportSyncControlling: AnyObject {
    func setViewportSyncSuspended(_ suspended: Bool)
    func forceViewportSync()
}

extension TerminalViewportSyncControlling {
    func forceViewportSync() {}
}

@MainActor
private protocol LibghosttyScrollbarHandling: AnyObject {
    func applyScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate)
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

        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}

@MainActor
final class LibghosttySurfaceScrollHostView: NSView, TerminalViewportSyncControlling, TerminalFocusReporting, TerminalFocusTargetProviding, TerminalOverlayHosting, TerminalScrollRouting, TerminalMouseInteractionSuppressionControlling, LibghosttyScrollbarHandling {
    private struct ScrollHostSyncMetrics {
        let geometryApplied: Bool
        let documentHeightChanged: Bool
        let documentHeightPoints: CGFloat
        let documentHeightDeltaPoints: CGFloat
        let reflected: Bool
        let scrollbarTotalRows: UInt64?
        let scrollbarOffsetRows: UInt64?
        let scrollbarVisibleRows: UInt64?
        let wasAtBottom: Bool?
        let shouldAutoScroll: Bool?
        let autoScrollApplied: Bool?
        let userScrolledAwayFromBottom: Bool?
        let explicitScrollbarSyncAllowed: Bool?
    }

    private let paneID: PaneID
    private let diagnostics: TerminalDiagnostics
    private let scrollView: LibghosttyScrollView
    private let overlayHostView = NSView()
    private let documentView: NSView
    private let surfaceView: LibghosttyView
    private var isLiveScrolling = false
    private var pendingExplicitWheelScroll = false
    private var allowExplicitScrollbarSync = false
    private var userScrolledAwayFromBottom = false
    private var lastSentRow: Int?
    private var scrollbarUpdate: LibghosttySurfaceScrollbarUpdate?
    private static let scrollToBottomThreshold: CGFloat = 5.0

    var onFocusDidChange: ((Bool) -> Void)? {
        get { surfaceView.onFocusDidChange }
        set { surfaceView.onFocusDidChange = newValue }
    }

    var terminalFocusTargetView: NSView {
        surfaceView
    }

    var terminalOverlayHostView: NSView {
        overlayHostView
    }

    var onScrollWheel: ((NSEvent) -> Bool)? {
        get { surfaceView.onScrollWheel }
        set { surfaceView.onScrollWheel = newValue }
    }

    init(
        surfaceView: LibghosttyView,
        paneID: PaneID,
        diagnostics: TerminalDiagnostics
    ) {
        self.paneID = paneID
        self.diagnostics = diagnostics
        self.surfaceView = surfaceView
        self.scrollView = LibghosttyScrollView()
        self.documentView = NSView(frame: .zero)
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
        surfaceView.onExplicitWheelScroll = { [weak self] in
            self?.pendingExplicitWheelScroll = true
        }

        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)
        addSubview(scrollView)
        overlayHostView.translatesAutoresizingMaskIntoConstraints = true
        overlayHostView.autoresizingMask = [.width, .height]
        overlayHostView.frame = bounds
        addSubview(overlayHostView)

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        ZenttyPerformanceSignposts.interval("LibghosttyScrollHostLayout") {
            super.layout()
            scrollView.frame = bounds
            overlayHostView.frame = bounds
            surfaceView.frame.size = scrollView.bounds.size
            documentView.frame.size.width = scrollView.bounds.width
            recordScrollHostSync { synchronizeScrollView() }
            synchronizeSurfaceView()
            synchronizeCoreSurface()
        }
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        surfaceView.setViewportSyncSuspended(suspended)
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
            if pendingExplicitWheelScroll {
                userScrolledAwayFromBottom = rowsBelowViewport(for: update) > 0
                allowExplicitScrollbarSync = true
                pendingExplicitWheelScroll = false
            }
            scrollbarUpdate = update
            recordScrollHostSync { synchronizeScrollView() }
            diagnostics.recordScrollbarApply(
                paneID: paneID,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
            )
        }
    }

    var surfaceViewForTesting: LibghosttyView {
        surfaceView
    }

    @objc
    private func handleScrollChangeNotification(_ notification: Notification) {
        handleScrollChange()
    }

    @objc
    private func handleWillStartLiveScrollNotification(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc
    private func handleDidEndLiveScrollNotification(_ notification: Notification) {
        isLiveScrolling = false
    }

    @objc
    private func handleDidLiveScrollNotification(_ notification: Notification) {
        handleLiveScroll()
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func synchronizeCoreSurface() {
        guard scrollView.contentSize.width > 0, surfaceView.frame.height > 0 else {
            return
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        surfaceView.syncViewport()
        diagnostics.recordViewportSync(
            paneID: paneID,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt
        )
    }

    private func synchronizeScrollView() -> ScrollHostSyncMetrics {
        var didChangeGeometry = false
        let previousDocumentHeight = documentView.frame.height
        let targetDocumentHeight = documentHeight()
        var scrollbarTotalRows: UInt64?
        var scrollbarOffsetRows: UInt64?
        var scrollbarVisibleRows: UInt64?
        var wasAtBottom: Bool?
        var shouldAutoScroll: Bool?
        var autoScrollApplied = false
        var explicitScrollbarSyncAllowed: Bool?
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.terminalCellHeight
            if cellHeight > 0, let scrollbarUpdate {
                scrollbarTotalRows = scrollbarUpdate.total
                scrollbarOffsetRows = scrollbarUpdate.offset
                scrollbarVisibleRows = scrollbarUpdate.len
                let offsetY = CGFloat(rowsBelowViewport(for: scrollbarUpdate)) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                let currentOrigin = scrollView.contentView.bounds.origin
                let documentHeight = documentView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let distanceFromBottom = documentHeight - currentOrigin.y - viewportHeight
                let isAtBottom = distanceFromBottom <= Self.scrollToBottomThreshold
                wasAtBottom = isAtBottom
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                let explicitScrollbarSyncAllowedNow = allowExplicitScrollbarSync
                explicitScrollbarSyncAllowed = explicitScrollbarSyncAllowedNow
                let shouldAutoScrollNow = !userScrolledAwayFromBottom || explicitScrollbarSyncAllowedNow
                shouldAutoScroll = shouldAutoScrollNow
                if shouldAutoScrollNow && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                    autoScrollApplied = true
                }
                lastSentRow = Int(clamping: scrollbarUpdate.offset)
            }
        }

        allowExplicitScrollbarSync = false

        var reflected = false
        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
        synchronizeSurfaceView()
        updateUserScrolledAwayFromBottomState()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.terminalCellHeight
        guard cellHeight > 0 else {
            return
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let scrollOffset = scrollOffsetFromBottom(for: visibleRect)
        updateUserScrolledAwayFromBottomState(visibleRect: visibleRect)

        let row = Int(scrollOffset / cellHeight)
        guard row != lastSentRow else {
            return
        }

        lastSentRow = row
        diagnostics.recordScrollToRowAction(paneID: paneID)
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
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

    private func scrollOffsetFromBottom(for visibleRect: NSRect) -> CGFloat {
        max(0, documentView.frame.height - visibleRect.origin.y - visibleRect.height)
    }

    private func updateUserScrolledAwayFromBottomState(visibleRect: NSRect? = nil) {
        let visibleRect = visibleRect ?? scrollView.contentView.documentVisibleRect
        userScrolledAwayFromBottom = scrollOffsetFromBottom(for: visibleRect) > Self.scrollToBottomThreshold
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.terminalCellHeight
        if cellHeight > 0, let scrollbarUpdate {
            let documentGridHeight = CGFloat(scrollbarUpdate.total) * cellHeight
            let padding = max(0, contentHeight - (CGFloat(scrollbarUpdate.len) * cellHeight))
            return documentGridHeight + padding
        }

        return contentHeight
    }

    private func rowsBelowViewport(for update: LibghosttySurfaceScrollbarUpdate) -> UInt64 {
        let clampedOffset = min(update.offset, update.total)
        let remainingRows = update.total - clampedOffset
        let visibleRows = min(update.len, remainingRows)
        return remainingRows - visibleRows
    }

    private func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }
}

final class LibghosttyView: NSView, TerminalFocusReporting {
    private struct ViewportSignature: Equatable {
        let size: CGSize
        let scale: CGFloat
        let displayID: UInt32?
    }

    private enum BindingAction {
        static let copyToClipboard = "copy_to_clipboard"
        static let pasteFromClipboard = "paste_from_clipboard"
        static let selectAll = "select_all"
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

    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var lastViewportSignature: ViewportSignature?
    private var isViewportSyncSuspended = false
    private var keyTextAccumulator = ""
    private var markedTextStorage = ""
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var selectedTextStorageRange = NSRange(location: NSNotFound, length: 0)
    private var currentCursor: NSCursor = .iBeam
    private var mouseTrackingArea: NSTrackingArea?
    private var mouseInteractionSuppressionRects: [CGRect] = []
    fileprivate weak var scrollbarHandler: (any LibghosttyScrollbarHandling)?
    var onFocusDidChange: ((Bool) -> Void)?
    var onLocalEventDidOccur: ((TerminalEvent) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var onExplicitWheelScroll: (() -> Void)?

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
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
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
        window?.makeFirstResponder(self)
        forwardMousePosition(event)
        surfaceController?.sendMouseButton(
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
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        forwardMousePosition(event)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isPointInsideSuppressedMouseRegion(convert(event.locationInWindow, from: nil)) else {
            return
        }
        if onScrollWheel?(event) == true {
            return
        }

        guard let surfaceController else {
            super.scrollWheel(with: event)
            return
        }

        onExplicitWheelScroll?()
        surfaceController.sendMouseScroll(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            precision: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase
        )
    }

    override func keyDown(with event: NSEvent) {
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
        MainActor.assumeIsolated {
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

    @IBAction func copy(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(BindingAction.copyToClipboard)
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
        _ = surfaceController?.performBindingAction(BindingAction.pasteFromClipboard)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(BindingAction.selectAll)
    }

    func bind(surfaceController: any LibghosttySurfaceControlling) {
        self.surfaceController = surfaceController
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        guard isViewportSyncSuspended != suspended else {
            return
        }

        isViewportSyncSuspended = suspended
        if !suspended {
            syncViewport()
        }
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
        window?.backingScaleFactor ?? layer?.contentsScale ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    fileprivate func syncViewport() {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        if isViewportSyncSuspended {
            return
        }

        let backingBounds = convertToBacking(bounds)
        syncLayerGeometry(backingBounds: backingBounds)
        let viewportSize = CGSize(
            width: max(1, backingBounds.width),
            height: max(1, backingBounds.height)
        )
        let viewportSignature = ViewportSignature(
            size: viewportSize,
            scale: currentScaleFactor,
            displayID: currentDisplayID
        )

        guard viewportSignature != lastViewportSignature else {
            return
        }

        lastViewportSignature = viewportSignature
        surfaceController?.updateViewport(
            size: viewportSignature.size,
            scale: viewportSignature.scale,
            displayID: viewportSignature.displayID
        )
        surfaceController?.refresh()
    }

    func invalidateAndSyncViewport() {
        lastViewportSignature = nil
        syncViewport()
    }

    var terminalCellHeight: CGFloat {
        surfaceController?.cellHeight ?? 0
    }

    func performBindingAction(_ action: String) -> Bool {
        surfaceController?.performBindingAction(action) ?? false
    }

    func applyScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate) {
        scrollbarHandler?.applyScrollbarUpdate(update)
    }

    private func syncLayerGeometry(backingBounds: CGRect) {
        let scale = currentScaleFactor
        let drawableSize = CGSize(
            width: max(1, floor(backingBounds.width)),
            height: max(1, floor(backingBounds.height))
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        if let metalLayer = layer as? CAMetalLayer, metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        CATransaction.commit()
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
        let position = CGPoint(x: point.x, y: bounds.height - point.y)
        surfaceController?.sendMousePosition(
            position,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
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

extension LibghosttyView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
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

        MainActor.assumeIsolated {
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

        MainActor.assumeIsolated {
            self.markedTextStorage = text
            self.markedTextSelection = selectedRange
            self.selectedTextStorageRange = replacementRange
        }
    }

    nonisolated func unmarkText() {
        MainActor.assumeIsolated {
            self.markedTextStorage = ""
            self.markedTextSelection = NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func selectedRange() -> NSRange {
        MainActor.assumeIsolated {
            self.selectedTextStorageRange
        }
    }

    nonisolated func markedRange() -> NSRange {
        MainActor.assumeIsolated {
            !self.markedTextStorage.isEmpty
                ? NSRange(location: 0, length: self.markedTextStorage.utf16.count)
                : NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func hasMarkedText() -> Bool {
        MainActor.assumeIsolated {
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
        let rect = MainActor.assumeIsolated {
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
