import AppKit
import XCTest
@testable import Zentty

/// Detached float layer: transient gesture frames, unmount during a gesture
/// and lift-in-place mounting. Gesture phases are driven through the float
/// container's callbacks (the hosted suite sends real window events).
@MainActor
final class FloatLayerViewInteractionTests: AppKitTestCase {
    private let floatID = PaneID("float")
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)
    private var adapters: [PaneID: ViewportLoggingAdapter] = [:]

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        adapters = [:]
        super.tearDown()
    }

    func test_interactive_frame_wins_over_store_until_gesture_ends() throws {
        let layer = makeLayer()
        layer.render(content(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let dragged = CGRect(x: 300, y: 200, width: 400, height: 280)
        var ended: [FloatGestureOutcome] = []
        layer.onFloatGestureEnded = { _, outcome, canvas in
            ended.append(outcome)
            XCTAssertEqual(canvas, self.canvas)
        }

        host.onGestureBegan?(.resize(.bottomRight))
        host.onGestureChanged?(dragged)
        XCTAssertEqual(layer.interactiveFrameForTesting(floatID), dragged)

        // A store change mid-gesture re-renders with another frame.
        layer.render(content(frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)))
        XCTAssertEqual(host.paneFrame, dragged, "the gesture frame wins")

        host.onGestureEnded?(.resize(frame: dragged), .zero)
        XCTAssertEqual(ended, [.resize(frame: dragged)])
        XCTAssertNil(layer.interactiveFrameForTesting(floatID))

        layer.render(content(frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)))
        XCTAssertEqual(host.paneFrame, CGRect(x: 500, y: 350, width: 300, height: 210), "the store wins again")
    }

    func test_unmount_cancels_live_gesture() throws {
        FloatMotion.reduceMotionOverride = false
        let layer = makeLayer()
        layer.render(content(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let startFrame = host.paneFrame
        host.activeGesture = ActiveFloatGesture(
            kind: .move,
            session: FloatDragSession(startMouse: .zero, startFrame: startFrame, timestamp: 0),
            didBegin: true,
            startedOverLegend: false
        )
        host.onGestureBegan?(.move)
        host.onGestureChanged?(startFrame.offsetBy(dx: 40, dy: 0))
        XCTAssertTrue(host.isLifted)
        XCTAssertEqual(adapters[floatID]?.view.isSuspended, true, "lifted floats freeze their grid")
        var ended = 0
        layer.onFloatGestureEnded = { _, _, _ in ended += 1 }

        layer.render(.empty)

        XCTAssertFalse(host.isGestureActiveForTesting)
        XCTAssertFalse(host.isLifted)
        XCTAssertNil(layer.interactiveFrameForTesting(floatID))
        XCTAssertNil(layer.containerForTesting(floatID))
        XCTAssertEqual(ended, 0, "nothing is committed")
        XCTAssertEqual(adapters[floatID]?.view.isSuspended, false, "the lift's freeze is undone")
    }

    func test_dock_mode_release_over_target_becomes_dock_outcome() throws {
        let layer = makeLayer()
        let column = CGRect(x: 0, y: 0, width: 400, height: 700)
        layer.dockColumnsProvider = {
            [ColumnPresentation(
                columnID: PaneColumnID("col_a"),
                frame: column,
                panes: [PanePresentation(paneID: PaneID("a"), columnID: PaneColumnID("col_a"), frame: column, emphasis: 1, isFocused: false)]
            )]
        }
        layer.render(content(frame: NormalizedRect(x: 0.5, y: 0.3, width: 0.4, height: 0.4)))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        var session = FloatDragSession(startMouse: CGPoint(x: 700, y: 600), startFrame: host.paneFrame, timestamp: 0)
        // Past A's right edge: the gap after the last column.
        session.move(to: CGPoint(x: 420, y: 300), timestamp: 1)
        host.activeGesture = ActiveFloatGesture(kind: .move, session: session, didBegin: true, startedOverLegend: false, isDockMode: true)
        var ended: [FloatGestureOutcome] = []
        layer.onFloatGestureEnded = { _, outcome, _ in ended.append(outcome) }

        host.onGestureBegan?(.move)
        host.onDockModeChanged?(true)
        let dropped = host.paneFrame.offsetBy(dx: -280, dy: -300)
        host.onGestureChanged?(dropped)

        XCTAssertEqual(host.alphaValue, FloatLayerView.dockModeAlpha, accuracy: 0.001)
        XCTAssertEqual(layer.dockCoordinator.currentTarget, .columnGap(index: 1))
        XCTAssertTrue(layer.dockPreviewView.subviews.contains { $0 is FloatDockLabelView })

        host.activeGesture = nil
        host.onGestureEnded?(.move(frame: dropped), .zero)

        XCTAssertEqual(ended, [.dock(target: .columnGap(index: 1), frame: dropped)])
        XCTAssertFalse(layer.dockCoordinator.isActive)
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)
        XCTAssertTrue(layer.dockPreviewView.subviews.isEmpty)
    }

    func test_dock_mode_toggled_off_restores_plain_move() throws {
        let layer = makeLayer()
        layer.render(content(frame: NormalizedRect(x: 0.5, y: 0.3, width: 0.4, height: 0.4)))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        host.activeGesture = ActiveFloatGesture(
            kind: .move,
            session: FloatDragSession(startMouse: CGPoint(x: 700, y: 600), startFrame: host.paneFrame, timestamp: 0),
            didBegin: true,
            startedOverLegend: false
        )
        var ended: [FloatGestureOutcome] = []
        layer.onFloatGestureEnded = { _, outcome, _ in ended.append(outcome) }
        host.onGestureBegan?(.move)

        host.setDockMode(true)
        XCTAssertTrue(layer.dockCoordinator.isActive)
        XCTAssertEqual(layer.dockCoordinator.currentTarget, .columnGap(index: 0), "no columns: the strip is empty")
        host.setDockMode(false)
        XCTAssertFalse(layer.dockCoordinator.isActive)
        XCTAssertEqual(host.alphaValue, 1, accuracy: 0.001)

        let moved = host.paneFrame.offsetBy(dx: -40, dy: 0)
        host.activeGesture = nil
        host.onGestureEnded?(.move(frame: moved), .zero)
        XCTAssertEqual(ended, [.move(frame: moved)])
    }

    func test_prepareLift_mounts_at_tile_frame() throws {
        let layer = makeLayer()
        let tileFrame = CGRect(x: 0, y: 20, width: 500, height: 640)
        let landed = expectation(description: "lift landed")
        layer.onLiftInPlaceFinishedForTesting = { _ in landed.fulfill() }

        layer.prepareLift(paneID: floatID, fromTileFrame: tileFrame)
        layer.render(content(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))

        let view = try XCTUnwrap(adapters[floatID]?.view)
        let mountSuspend = try XCTUnwrap(view.log.last { $0.suspended })
        XCTAssertEqual(mountSuspend.containerSize, tileFrame.size, "mounted at the tile's slot")
        XCTAssertEqual(view.isSuspended, true, "frozen until the lift lands")
        XCTAssertEqual(layer.floatHostForTesting(floatID)?.paneFrame, CGRect(x: 100, y: 70, width: 400, height: 280))

        wait(for: [landed], timeout: 2)
        XCTAssertEqual(view.isSuspended, false)
        XCTAssertEqual(view.log.last?.containerSize, CGSize(width: 400, height: 280))
    }

    func test_prepareLift_is_dropped_when_the_render_does_not_mount_it() throws {
        let layer = makeLayer()
        layer.prepareLift(paneID: floatID, fromTileFrame: CGRect(x: 0, y: 0, width: 500, height: 600))
        layer.render(.empty)

        layer.render(content(frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)))

        let view = try XCTUnwrap(adapters[floatID]?.view)
        XCTAssertEqual(view.isSuspended, false, "a later plain mount resumes sync at once")
    }

    // MARK: - Fixtures

    private func makeLayer() -> FloatLayerView {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = ViewportLoggingAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let layer = FloatLayerView(runtimeRegistry: registry)
        layer.frame = canvas
        return layer
    }

    private func content(frame: NormalizedRect) -> FloatLayerContent {
        FloatLayerContent(
            floats: [
                FloatingPaneState(
                    pane: PaneState(id: floatID, title: "float"),
                    mode: .floating,
                    floatFrame: frame,
                    stackOrder: 0,
                    origin: nil
                ),
            ],
            floatsHidden: false,
            focusedFloatID: nil
        )
    }
}

private extension FloatLayerView {
    func render(_ content: FloatLayerContent) {
        render(content, theme: ZenttyTheme.fallback(for: nil), showPaneBorders: true, smoothScrollingEnabled: false)
    }
}

@MainActor
private final class ViewportLoggingAdapter: TerminalAdapter {
    let view = ViewportLoggingView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView { view }
    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}

private final class ViewportLoggingView: NSView, TerminalViewportSyncControlling {
    struct Entry {
        let suspended: Bool
        let containerSize: CGSize?
    }

    private(set) var isSuspended: Bool?
    private(set) var log: [Entry] = []

    func setViewportSyncSuspended(_ suspended: Bool) {
        isSuspended = suspended
        var view = superview
        while let current = view, !(current is PaneContainerView) {
            view = current.superview
        }
        log.append(Entry(suspended: suspended, containerSize: view?.frame.size))
    }
}
