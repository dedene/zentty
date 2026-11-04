import AppKit
import XCTest
@testable import Zentty

/// Mock terminal that records what the registry does to it.
@MainActor
final class HostedSpyTerminalAdapter: TerminalAdapter {
    private let terminalView = HostedSpyTerminalView()
    var spyView: HostedSpyTerminalView { terminalView }

    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private(set) var closeCount = 0
    private(set) var startCount = 0
    private(set) var lastActivity: TerminalSurfaceActivity?
    private(set) var lastRequest: TerminalSessionRequest?
    var needsConfirmQuit = false

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startCount += 1
        lastRequest = request
    }

    func close() {
        closeCount += 1
    }

    func sendText(_ text: String) {}

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastActivity = activity
    }
}

final class HostedSpyTerminalView: NSView, TerminalFocusReporting, TerminalViewportSyncControlling {
    struct SuspensionCall {
        let suspended: Bool
        /// Whether the view sat under a scaled PiP host at the time.
        let wasInPip: Bool
        let containerSize: CGSize?
    }

    var onFocusDidChange: ((Bool) -> Void)?
    private(set) var isViewportSyncSuspended: Bool?
    var suspensionLog: [SuspensionCall] = []
    /// Forced viewport syncs (`suspended` = state at the time).
    var forcedSyncLog: [SuspensionCall] = []

    func forceViewportSync() {
        forcedSyncLog.append(SuspensionCall(
            suspended: isViewportSyncSuspended ?? false,
            wasInPip: ancestor(of: PipContainerView.self) != nil,
            containerSize: ancestor(of: PaneContainerView.self)?.frame.size
        ))
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        isViewportSyncSuspended = suspended
        suspensionLog.append(SuspensionCall(
            suspended: suspended,
            wasInPip: ancestor(of: PipContainerView.self) != nil,
            containerSize: ancestor(of: PaneContainerView.self)?.frame.size
        ))
    }

    private func ancestor<T: NSView>(of type: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    // MARK: Mouse delivery (float gesture latching)

    /// Mouse events AppKit delivered to the terminal itself.
    private(set) var mouseEventTypes: [NSEvent.EventType] = []
    private(set) var menuRequestCount = 0

    func resetMouseEventsForTesting() {
        mouseEventTypes.removeAll()
        menuRequestCount = 0
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseEventTypes.append(event.type)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseEventTypes.append(event.type)
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseEventTypes.append(event.type)
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        mouseEventTypes.append(event.type)
        super.rightMouseDown(with: event)
    }

    /// Scroll events AppKit delivered to the terminal itself.
    private(set) var scrollEventCount = 0

    override func scrollWheel(with event: NSEvent) {
        scrollEventCount += 1
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuRequestCount += 1
        return super.menu(for: event)
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
