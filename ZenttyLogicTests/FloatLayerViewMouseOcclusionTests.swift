import AppKit
import XCTest
@testable import Zentty

/// Terminal tracking areas are geometric, so the float layer tells each
/// terminal it hosts where to ignore the pointer: everywhere for a PiP (and
/// for a leaving copy), under floats and PiPs drawn above it for a float.
/// Review finding: PiPs and overlapping floats leaked pointer motion (and so
/// mouse-tracking reports) to the terminals under them.
@MainActor
final class FloatLayerViewMouseOcclusionTests: AppKitTestCase {
    private let lowID = PaneID("low")
    private let highID = PaneID("high")
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)
    private var adapters: [PaneID: SuppressionSpyAdapter] = [:]
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        window?.close()
        window = nil
        adapters = [:]
        super.tearDown()
    }

    func test_a_float_ignores_the_pointer_under_a_float_above_it() throws {
        let layer = makeLayer()
        // High overlaps the right part of low.
        layer.render(content(
            float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0),
            float(highID, frame: NormalizedRect(x: 0.4, y: 0.2, width: 0.4, height: 0.4), stackOrder: 1)
        ))
        let overlap = CGPoint(x: 500, y: 300)
        let lowOnly = CGPoint(x: 200, y: 200)

        XCTAssertTrue(try suppresses(lowID, at: overlap, in: layer), "covered by the float above")
        XCTAssertFalse(try suppresses(lowID, at: lowOnly, in: layer))
        XCTAssertFalse(try suppresses(highID, at: overlap, in: layer), "the top float keeps the pointer")

        // Raising low swaps who is covered.
        layer.render(content(
            float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 1),
            float(highID, frame: NormalizedRect(x: 0.4, y: 0.2, width: 0.4, height: 0.4), stackOrder: 0)
        ))
        XCTAssertFalse(try suppresses(lowID, at: overlap, in: layer))
        XCTAssertTrue(try suppresses(highID, at: overlap, in: layer))
    }

    func test_a_pip_terminal_ignores_the_pointer_everywhere_until_it_is_a_float_again() throws {
        let layer = makeLayer()
        layer.render(content(float(lowID, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 0)))
        let pip = try XCTUnwrap(layer.pipHostForTesting(lowID))
        let centre = CGPoint(x: pip.frame.midX, y: pip.frame.midY)

        XCTAssertTrue(try suppresses(lowID, at: centre, in: layer), "the PiP owns every event over it")
        XCTAssertTrue(try suppresses(lowID, at: CGPoint(x: pip.frame.minX + 2, y: pip.frame.minY + 2), in: layer))

        layer.render(content(float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0)))
        XCTAssertFalse(try suppresses(lowID, at: CGPoint(x: 300, y: 250), in: layer), "restored: tracked again")
    }

    func test_a_float_ignores_the_pointer_under_a_pip_above_it() throws {
        let layer = makeLayer()
        layer.render(content(
            float(lowID, frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), stackOrder: 0),
            float(highID, mode: .pip(corner: .bottomRight, order: 0), stackOrder: 1)
        ))
        let pip = try XCTUnwrap(layer.pipHostForTesting(highID))

        XCTAssertTrue(try suppresses(lowID, at: CGPoint(x: pip.frame.midX, y: pip.frame.midY), in: layer))
        XCTAssertFalse(try suppresses(lowID, at: CGPoint(x: 300, y: 350), in: layer))
    }

    func test_moving_a_float_updates_what_it_covers_without_a_render() throws {
        let layer = makeLayer()
        layer.render(content(
            float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0),
            float(highID, frame: NormalizedRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2), stackOrder: 1)
        ))
        var notified = 0
        layer.onOccludingFramesChanged = { notified += 1 }
        let target = CGPoint(x: 200, y: 200)
        XCTAssertFalse(try suppresses(lowID, at: target, in: layer))
        let host = try XCTUnwrap(layer.floatHostForTesting(highID))

        host.onGestureBegan?(.move)
        host.onGestureChanged?(CGRect(x: 150, y: 150, width: 200, height: 140))

        XCTAssertTrue(try suppresses(lowID, at: target, in: layer), "follows the drag")
        XCTAssertGreaterThan(notified, 0, "the canvas hears it, to re-tell the strip")
        host.onGestureCancelled?()
    }

    func test_a_leaving_copy_mutes_its_terminal() throws {
        let layer = makeLayer()
        layer.render(content(float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0)))
        let point = CGPoint(x: 300, y: 250)
        XCTAssertFalse(try suppresses(lowID, at: point, in: layer))

        layer.prepareTransitions(departures: [lowID: .close], entries: [:])
        layer.render(content())

        XCTAssertEqual(layer.departingPaneIDsForTesting, [lowID], "precondition: a leaving copy draws")
        XCTAssertTrue(try suppresses(lowID, at: point, in: layer), "a fading copy reports no pointer motion")
    }

    // MARK: - Resize cursors

    /// A float's resize zones are cursor rects on its host; the terminal
    /// inside reaches under their inner half, so it must leave them out of
    /// its own (I-beam) cursor rects, without ignoring the pointer there.
    func test_a_float_terminal_shows_no_cursor_in_its_resize_zones_but_keeps_the_pointer() throws {
        let layer = makeLayer()
        layer.render(content(float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0)))
        let host = try XCTUnwrap(layer.floatHostForTesting(lowID))
        let pane = host.paneFrame
        let insideBottomEdge = CGPoint(x: pane.midX, y: pane.minY + 4)
        let insideRightEdge = CGPoint(x: pane.maxX - 4, y: pane.midY)
        let centre = CGPoint(x: pane.midX, y: pane.midY)

        XCTAssertTrue(try excludesCursor(lowID, at: insideBottomEdge, in: layer))
        XCTAssertTrue(try excludesCursor(lowID, at: insideRightEdge, in: layer))
        XCTAssertFalse(try excludesCursor(lowID, at: centre, in: layer))
        XCTAssertFalse(try suppresses(lowID, at: insideBottomEdge, in: layer), "selections near the edge still work")
        XCTAssertTrue(host.cursorOcclusionRects.isEmpty, "nothing above it")
        XCTAssertEqual(
            FloatResizeCursorZones.handle(
                at: host.convert(insideBottomEdge, from: layer),
                in: host.visibleResizeCursorZones
            ),
            .bottom
        )
    }

    func test_a_covered_float_shows_no_cursor_where_the_float_above_owns_presses() throws {
        let layer = makeLayer()
        layer.render(content(
            float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0),
            // Taller than low: its left ring crosses low's lower edge.
            float(highID, frame: NormalizedRect(x: 0.4, y: 0.05, width: 0.4, height: 0.9), stackOrder: 1)
        ))
        let low = try XCTUnwrap(layer.floatHostForTesting(lowID))
        let high = try XCTUnwrap(layer.floatHostForTesting(highID))
        // Low's bottom edge, under high's left resize zone (just outside high's pane).
        let underHighRing = CGPoint(x: high.paneFrame.minX - 5, y: low.paneFrame.minY + 3)
        XCTAssertTrue(low.paneFrame.contains(underHighRing), "precondition: over low's terminal")
        XCTAssertFalse(high.paneFrame.contains(underHighRing), "precondition: outside high's pane")
        XCTAssertEqual(
            FloatResizeCursorZones.handle(
                at: low.convert(underHighRing, from: layer),
                in: FloatResizeCursorZones.zones(bounds: low.bounds, band: FloatGesture.band, cornerZone: FloatGesture.cornerZone)
            ),
            .bottom,
            "precondition: in low's bottom zone"
        )

        XCTAssertNil(
            FloatResizeCursorZones.handle(at: low.convert(underHighRing, from: layer), in: low.visibleResizeCursorZones),
            "the covered float's zone gives way"
        )
        XCTAssertEqual(
            FloatResizeCursorZones.handle(at: high.convert(underHighRing, from: layer), in: high.visibleResizeCursorZones),
            .left
        )
        XCTAssertTrue(try excludesCursor(lowID, at: underHighRing, in: layer), "nor does low's terminal claim it")
        XCTAssertEqual(
            FloatResizeCursorZones.handle(
                at: low.convert(CGPoint(x: low.paneFrame.minX + 3, y: low.paneFrame.midY), from: layer),
                in: low.visibleResizeCursorZones
            ),
            .left,
            "uncovered zones stay"
        )
    }

    func test_strip_cursor_exclusion_covers_each_float_outset() throws {
        let layer = makeLayer()
        layer.render(content(float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0)))
        let host = try XCTUnwrap(layer.floatHostForTesting(lowID))
        XCTAssertEqual(layer.cursorOwningFrames(in: layer), [host.frame])
    }

    func test_a_leaving_copy_shows_no_resize_cursor() throws {
        let layer = makeLayer()
        layer.render(content(float(lowID, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), stackOrder: 0)))
        let host = try XCTUnwrap(layer.floatHostForTesting(lowID))
        XCTAssertFalse(host.visibleResizeCursorZones.isEmpty)

        layer.prepareTransitions(departures: [lowID: .close], entries: [:])
        layer.render(content())

        XCTAssertTrue(host.isDeparting, "precondition: the host is the leaving copy")
        XCTAssertTrue(host.visibleResizeCursorZones.isEmpty)
        XCTAssertTrue(layer.cursorOwningFrames(in: layer).isEmpty, "the strip gets its cursors back")
    }

    // MARK: - Fixtures

    private func excludesCursor(_ paneID: PaneID, at pointInLayer: CGPoint, in layer: FloatLayerView) throws -> Bool {
        let view = try XCTUnwrap(adapters[paneID]?.view)
        let point = view.convert(pointInLayer, from: layer)
        return view.cursorExclusionRects.contains { $0.contains(point) }
    }

    private func suppresses(_ paneID: PaneID, at pointInLayer: CGPoint, in layer: FloatLayerView) throws -> Bool {
        let view = try XCTUnwrap(adapters[paneID]?.view)
        let point = view.convert(pointInLayer, from: layer)
        return view.suppressionRects.contains { $0.contains(point) }
    }

    private func makeLayer() -> FloatLayerView {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = SuppressionSpyAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let layer = FloatLayerView(runtimeRegistry: registry)
        layer.frame = canvas
        let window = NSWindow(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: canvas)
        window.contentView = root
        root.addSubview(layer)
        self.window = window
        return layer
    }

    private func float(
        _ id: PaneID,
        mode: FloatingPaneMode = .floating,
        frame: NormalizedRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        stackOrder: Int
    ) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: id, title: id.rawValue),
            mode: mode,
            floatFrame: frame,
            stackOrder: stackOrder,
            origin: nil
        )
    }

    private func content(_ floats: FloatingPaneState...) -> FloatLayerContent {
        FloatLayerContent(floats: floats, floatsHidden: false, focusedFloatID: nil)
    }
}

private extension FloatLayerView {
    func render(_ content: FloatLayerContent) {
        render(content, theme: ZenttyTheme.fallback(for: nil), showPaneBorders: true, smoothScrollingEnabled: false)
        layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class SuppressionSpyAdapter: TerminalAdapter {
    let view = SuppressionSpyView()
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

private final class SuppressionSpyView: NSView, TerminalMouseInteractionSuppressionControlling,
    TerminalCursorExclusionControlling {
    private(set) var suppressionRects: [CGRect] = []
    private(set) var cursorExclusionRects: [CGRect] = []

    func setMouseInteractionSuppressionRects(_ rects: [CGRect]) {
        suppressionRects = rects
    }

    func setCursorExclusionRects(_ rects: [CGRect]) {
        cursorExclusionRects = rects
    }
}
