import AppKit
import XCTest
@testable import Zentty

/// The float host's resize cursor rects and the cursor a live resize pins:
/// cursor rects go off for the whole press (so neither leaving the zone nor
/// crossing a terminal swaps the cursor) and always come back on.
@MainActor
final class FloatContainerViewCursorTests: AppKitTestCase {
    private let paneFrame = CGRect(x: 100, y: 100, width: 400, height: 250)
    private var window: NSWindow?

    override func tearDown() {
        window?.contentView = nil
        window?.close()
        window = nil
        super.tearDown()
    }

    func test_zones_cover_corners_and_three_edges_but_not_the_move_band() throws {
        let host = makeHost()
        let zones = host.visibleResizeCursorZones
        let bounds = host.bounds

        XCTAssertEqual(handle(at: CGPoint(x: 3, y: 3), in: zones), .bottomLeft)
        XCTAssertEqual(handle(at: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3), in: zones), .topRight)
        XCTAssertEqual(handle(at: CGPoint(x: 3, y: bounds.midY), in: zones), .left)
        XCTAssertEqual(handle(at: CGPoint(x: bounds.maxX - 3, y: bounds.midY), in: zones), .right)
        XCTAssertEqual(handle(at: CGPoint(x: bounds.midX, y: 3), in: zones), .bottom)
        XCTAssertNil(handle(at: CGPoint(x: bounds.midX, y: bounds.maxY - 3), in: zones), "move band: arrow")
        XCTAssertNil(handle(at: CGPoint(x: bounds.midX, y: bounds.midY), in: zones), "terminal: its own cursor")
    }

    func test_no_zones_while_hidden_or_leaving_or_without_a_pane() throws {
        let host = makeHost()
        XCTAssertFalse(host.visibleResizeCursorZones.isEmpty)

        host.isHidden = true
        XCTAssertTrue(host.visibleResizeCursorZones.isEmpty)
        host.isHidden = false

        host.isDeparting = true
        XCTAssertTrue(host.visibleResizeCursorZones.isEmpty)
        host.isDeparting = false

        host.relinquishHostedContainer()
        XCTAssertTrue(host.visibleResizeCursorZones.isEmpty)
    }

    func test_occlusion_rects_cut_the_zones() throws {
        let host = makeHost()
        host.cursorOcclusionRects = [CGRect(x: 0, y: 0, width: host.bounds.midX, height: host.bounds.height)]

        XCTAssertNil(handle(at: CGPoint(x: 3, y: host.bounds.midY), in: host.visibleResizeCursorZones))
        XCTAssertEqual(handle(at: CGPoint(x: host.bounds.maxX - 3, y: 3), in: host.visibleResizeCursorZones), .bottomRight)
    }

    func test_a_resize_press_pins_its_cursor_until_release() throws {
        let host = makeHost()
        let window = try XCTUnwrap(host.window)
        XCTAssertTrue(window.areCursorRectsEnabled)
        let corner = host.convert(CGPoint(x: host.bounds.maxX - 3, y: 3), to: nil)

        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner))
        let hold = try XCTUnwrap(host.resizeCursorHoldForTesting)
        XCTAssertEqual(hold.handle, .bottomRight)
        XCTAssertFalse(window.areCursorRectsEnabled, "no cursor rect can swap it mid-drag")

        // Far outside every zone: still the resize cursor.
        host.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: corner.x - 150, y: corner.y + 120)))
        XCTAssertNotNil(host.resizeCursorHoldForTesting)
        XCTAssertFalse(window.areCursorRectsEnabled)

        host.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: corner.x - 150, y: corner.y + 120)))
        XCTAssertNil(host.resizeCursorHoldForTesting)
        XCTAssertTrue(window.areCursorRectsEnabled, "back to normal after the press")
    }

    func test_a_cancelled_resize_gives_the_cursor_back() throws {
        let host = makeHost()
        let window = try XCTUnwrap(host.window)
        let edge = host.convert(CGPoint(x: 3, y: host.bounds.midY), to: nil)

        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: edge))
        XCTAssertEqual(try XCTUnwrap(host.resizeCursorHoldForTesting).handle, .left)

        host.cancelGesture()
        XCTAssertNil(host.resizeCursorHoldForTesting)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    func test_a_move_press_leaves_the_cursor_alone() throws {
        let host = makeHost()
        let window = try XCTUnwrap(host.window)
        let moveBand = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.maxY - 3), to: nil)

        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: moveBand))
        XCTAssertTrue(host.isGestureActiveForTesting)
        XCTAssertNil(host.resizeCursorHoldForTesting)
        XCTAssertTrue(window.areCursorRectsEnabled)
        host.cancelGesture()
    }

    func test_leaving_the_window_mid_resize_turns_cursor_rects_back_on() throws {
        let host = makeHost()
        let window = try XCTUnwrap(host.window)
        host.mouseDown(with: try mouseEvent(.leftMouseDown, at: host.convert(CGPoint(x: 3, y: 3), to: nil)))
        XCTAssertFalse(window.areCursorRectsEnabled)

        host.removeFromSuperview()

        XCTAssertNil(host.resizeCursorHoldForTesting)
        XCTAssertTrue(window.areCursorRectsEnabled)
        host.cancelGesture()
    }

    // MARK: - Fixtures

    private func handle(at point: CGPoint, in zones: [FloatResizeCursorZone]) -> FloatResizeHandle? {
        FloatResizeCursorZones.handle(at: point, in: zones)
    }

    private func makeHost() -> FloatContainerView {
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: false)
            .prepareForAppKitTesting()
        let root = NSView(frame: canvas)
        window.contentView = root
        self.window = window

        let host = FloatContainerView(paneID: PaneID("float"))
        root.addSubview(host)
        host.setPaneFrame(paneFrame)
        host.host(makePaneContainer())
        return host
    }

    private func makePaneContainer() -> PaneContainerView {
        let pane = PaneState(id: PaneID("float"), title: "shell")
        let runtime = PaneRuntime(
            pane: pane,
            adapter: MockTerminalAdapter(),
            metadataSink: { _, _ in },
            eventSink: { _, _ in }
        )
        return PaneContainerView(
            pane: pane,
            width: paneFrame.width,
            height: paneFrame.height,
            emphasis: 1,
            isFocused: false,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil),
            backingScaleFactorProvider: { 1 }
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType, at windowPoint: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
