import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalPaneHostViewTests: XCTestCase {
    func test_host_view_embeds_adapter_terminal_view_edge_to_edge() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertTrue(hostView.subviews.contains { $0 === adapter.terminalView })
        XCTAssertEqual(adapter.terminalView.frame, hostView.bounds)
    }

    func test_terminal_view_tracks_host_bounds_after_resize() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.layoutSubtreeIfNeeded()
        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(adapter.terminalView.frame, hostView.bounds)
    }

    func test_host_resize_forces_terminal_subtree_layout() {
        let terminalView = LayoutTrackingTerminalView()
        let adapter = TerminalAdapterSpy(terminalView: terminalView)
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.layoutSubtreeIfNeeded()
        let initialLayoutCallCount = terminalView.layoutCallCount

        hostView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            terminalView.layoutCallCount,
            initialLayoutCallCount,
            "Resizing the host should trigger a layout pass in the embedded terminal subtree"
        )
    }

    func test_start_session_if_needed_starts_adapter_only_once() throws {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        try hostView.startSessionIfNeeded(using: TerminalSessionRequest(workingDirectory: "/tmp/project"))
        try hostView.startSessionIfNeeded(using: TerminalSessionRequest(workingDirectory: "/tmp/project"))

        XCTAssertEqual(adapter.startSessionCallCount, 1)
        XCTAssertEqual(adapter.lastRequest, TerminalSessionRequest(workingDirectory: "/tmp/project"))
    }

    func test_metadata_callback_is_forwarded_to_host_observer() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        let metadata = TerminalMetadata(
            title: "shell",
            currentWorkingDirectory: "/tmp/project",
            processName: "zsh",
            gitBranch: "main"
        )
        var receivedMetadata: TerminalMetadata?

        hostView.onMetadataDidChange = { receivedMetadata = $0 }
        adapter.metadataDidChange?(metadata)

        XCTAssertEqual(receivedMetadata, metadata)
    }

    func test_focus_terminal_makes_adapter_view_first_responder() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }

        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        hostView.focusTerminal()

        XCTAssertTrue(window.firstResponder === hostView.terminalViewForTesting)
    }

    func test_focus_changes_from_terminal_view_are_forwarded() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        var didBecomeFocused = false

        hostView.onFocusDidChange = { isFocused in
            didBecomeFocused = isFocused
        }

        _ = adapter.terminalView.becomeFirstResponder()

        XCTAssertTrue(didBecomeFocused)
    }

    func test_surface_activity_is_forwarded_to_adapter() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.setSurfaceActivity(TerminalSurfaceActivity(isVisible: false, isFocused: false))

        XCTAssertEqual(adapter.lastSurfaceActivity, TerminalSurfaceActivity(isVisible: false, isFocused: false))
    }

    func test_viewport_sync_suspension_is_forwarded_to_terminal_view() {
        let adapter = TerminalAdapterSpy()
        let hostView = TerminalPaneHostView(adapter: adapter)
        guard let terminalView = adapter.terminalView as? FirstResponderTerminalView else {
            return XCTFail("Expected first-responder-capable terminal view")
        }

        hostView.setViewportSyncSuspended(true)
        hostView.setViewportSyncSuspended(false)

        XCTAssertEqual(terminalView.viewportSyncSuspensionUpdates, [true, false])
    }

    func test_scroll_wheel_handler_is_forwarded_to_terminal_view() throws {
        let terminalView = ScrollForwardingTerminalView()
        let adapter = TerminalAdapterSpy(terminalView: terminalView)
        let hostView = TerminalPaneHostView(adapter: adapter)
        var routedEvents: [NSEvent] = []

        hostView.onScrollWheel = { event in
            routedEvents.append(event)
            return true
        }

        terminalView.scrollWheel(with: try makeScrollEvent(deltaX: 32, precise: true))

        XCTAssertEqual(routedEvents.count, 1)
    }

    func test_search_hud_mounts_inside_terminal_provided_overlay_host() {
        let terminalView = OverlayHostingTerminalView()
        let adapter = TerminalAdapterSpy(terminalView: terminalView)
        let hostView = TerminalPaneHostView(adapter: adapter)

        hostView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        hostView.applySearchHUD(
            PaneSearchState(
                needle: "ansible",
                selected: -1,
                total: 1,
                hasRememberedSearch: true,
                isHUDVisible: true
            )
        )
        hostView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            hostView.searchHUDCloseButtonForTesting.isDescendant(of: terminalView.overlayHostView),
            "Search HUD should be mounted inside the terminal's overlay host, matching the app's overlay-hosted HUD pattern"
        )
    }

    func test_pane_container_search_hud_close_button_receives_real_window_clicks() throws {
        let terminalView = HostedMouseTrackingTerminalView()
        let adapter = PaneContainerHostedTerminalAdapterSpy(terminalView: terminalView)
        let pane = PaneState(id: PaneID("shell"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapter,
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        let paneView = PaneContainerView(
            pane: pane,
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }

        window.contentView = paneView
        window.makeKeyAndOrderFront(nil)
        runtime.showSearch()
        paneView.layoutSubtreeIfNeeded()

        let layoutSettled = expectation(description: "search HUD mounted in hosted window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            layoutSettled.fulfill()
        }
        wait(for: [layoutSettled], timeout: 2.0)

        let clickPoint = paneView.convert(
            CGPoint(
                x: paneView.searchHUDCloseButtonForTesting.bounds.midX,
                y: paneView.searchHUDCloseButtonForTesting.bounds.midY
            ),
            from: paneView.searchHUDCloseButtonForTesting
        )

        try sendHostedMouseClick(at: clickPoint, in: paneView, window: window)

        XCTAssertEqual(adapter.bindingActions.last, "endSearch")
        XCTAssertEqual(terminalView.mouseDownCount, 0)
        XCTAssertEqual(terminalView.mouseDraggedCount, 0)
    }

    func test_hosted_drag_near_top_edge_reaches_terminal_view() throws {
        let terminalView = HostedMouseTrackingTerminalView()
        let adapter = TerminalAdapterSpy(terminalView: terminalView)
        let hostView = TerminalPaneHostView(adapter: adapter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }

        hostView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 240)
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        hostView.layoutSubtreeIfNeeded()

        try sendHostedMouseDrag(
            from: CGPoint(x: 80, y: 40),
            to: CGPoint(x: 80, y: hostView.bounds.maxY - 4),
            in: hostView,
            window: window
        )

        XCTAssertEqual(terminalView.mouseDownCount, 1)
        XCTAssertGreaterThanOrEqual(terminalView.mouseDraggedCount, 2)
    }

    func test_hosted_drag_near_bottom_edge_reaches_terminal_view() throws {
        let terminalView = HostedMouseTrackingTerminalView()
        let adapter = TerminalAdapterSpy(terminalView: terminalView)
        let hostView = TerminalPaneHostView(adapter: adapter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        addTeardownBlock { window.close() }

        hostView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 480, height: 240)
        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
        hostView.layoutSubtreeIfNeeded()

        try sendHostedMouseDrag(
            from: CGPoint(x: 80, y: hostView.bounds.maxY - 40),
            to: CGPoint(x: 80, y: 4),
            in: hostView,
            window: window
        )

        XCTAssertEqual(terminalView.mouseDownCount, 1)
        XCTAssertGreaterThanOrEqual(terminalView.mouseDraggedCount, 2)
    }
}

@MainActor
private final class TerminalAdapterSpy: TerminalAdapter {
    let terminalView: NSView
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastRequest: TerminalSessionRequest?
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity(isVisible: true, isFocused: false)

    init(terminalView: NSView = FirstResponderTerminalView()) {
        self.terminalView = terminalView
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startSessionCallCount += 1
        lastRequest = request
    }

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private final class FirstResponderTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }
}

extension FirstResponderTerminalView: TerminalViewportSyncControlling {
    func setViewportSyncSuspended(_ suspended: Bool) {
        viewportSyncSuspensionUpdates.append(suspended)
    }
}

private final class ScrollForwardingTerminalView: NSView, TerminalFocusReporting, TerminalScrollRouting {
    var onFocusDidChange: ((Bool) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        _ = onScrollWheel?(event)
    }
}

private final class LayoutTrackingTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var layoutCallCount = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

    override func layout() {
        layoutCallCount += 1
        super.layout()
    }
}

private final class OverlayHostingTerminalView: NSView, TerminalFocusReporting, TerminalOverlayHosting {
    let overlayHostView = NSView()
    var onFocusDidChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlayHostView.translatesAutoresizingMaskIntoConstraints = true
        overlayHostView.autoresizingMask = [.width, .height]
        overlayHostView.frame = bounds
        addSubview(overlayHostView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

    var terminalOverlayHostView: NSView {
        overlayHostView
    }
}

@MainActor
private final class PaneContainerHostedTerminalAdapterSpy: TerminalAdapter, TerminalSearchControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    private let terminalView: NSView
    private(set) var bindingActions: [String] = []

    init(terminalView: NSView) {
        self.terminalView = terminalView
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {}

    func close() {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}

    func showSearch() {
        bindingActions.append("showSearch")
        searchDidChange?(.started(needle: nil))
    }

    func useSelectionForFind() {
        bindingActions.append("useSelectionForFind")
        searchDidChange?(.started(needle: nil))
    }

    func updateSearch(needle: String) {
        bindingActions.append("updateSearch:\(needle)")
    }

    func findNext() {
        bindingActions.append("navigate_search:next")
    }

    func findPrevious() {
        bindingActions.append("navigate_search:previous")
    }

    func endSearch() {
        bindingActions.append("endSearch")
        searchDidChange?(.ended)
    }
}

@MainActor
private final class HostedMouseTrackingTerminalView: NSView, TerminalFocusReporting {
    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var mouseDownCount = 0
    private(set) var mouseDraggedCount = 0

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDraggedCount += 1
    }
}

private func makeScrollEvent(
    deltaX: Int32 = 0,
    deltaY: Int32 = 0,
    precise: Bool
) throws -> NSEvent {
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let units: CGScrollEventUnit = precise ? .pixel : .line
    let cgEvent = try XCTUnwrap(
        CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )
    )

    if precise {
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(deltaX))
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    }

    return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
}

private func sendHostedMouseClick(at point: CGPoint, in view: NSView, window: NSWindow) throws {
    let locationInWindow = view.convert(point, to: nil)
    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )

    NSApp.postEvent(mouseUp, atStart: false)
    window.sendEvent(mouseDown)
}

private func sendHostedMouseDrag(
    from start: CGPoint,
    to end: CGPoint,
    in view: NSView,
    window: NSWindow
) throws {
    let startLocation = view.convert(start, to: nil)
    let endLocation = view.convert(end, to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let dragLocations = stride(from: 1, through: 4, by: 1).map { step -> CGPoint in
        let progress = CGFloat(step) / 4
        return CGPoint(
            x: startLocation.x + ((endLocation.x - startLocation.x) * progress),
            y: startLocation.y + ((endLocation.y - startLocation.y) * progress)
        )
    }

    let mouseDown = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startLocation,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )
    let mouseUp = try XCTUnwrap(
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endLocation,
            modifierFlags: [],
            timestamp: timestamp + 0.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: dragLocations.count + 1,
            clickCount: 1,
            pressure: 0
        )
    )

    let target = window.contentView?.hitTest(startLocation) ?? window.contentView!
    target.mouseDown(with: mouseDown)
    for (index, dragLocation) in dragLocations.enumerated() {
        let mouseDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: dragLocation,
                modifierFlags: [],
                timestamp: timestamp + (0.01 * Double(index + 1)),
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: index + 1,
                clickCount: 1,
                pressure: 1
            )
        )
        target.mouseDragged(with: mouseDragged)
    }
    target.mouseUp(with: mouseUp)
}
