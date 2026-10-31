import AppKit
import XCTest
@testable import Zentty

/// The strip scrim: when it shows, that clicks pass through, and that it
/// stays behind every float.
@MainActor
final class FloatScrimViewTests: AppKitTestCase {
    private let floatA = PaneID("float-a")
    private let floatB = PaneID("float-b")
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
    }

    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    // MARK: - Policy

    func test_policy_visible_when_float_owns_focus() {
        XCTAssertTrue(FloatScrimPolicy.isVisible(content(focused: floatA)))
    }

    func test_policy_hidden_for_tile_focus() {
        XCTAssertFalse(FloatScrimPolicy.isVisible(content(focused: nil)))
    }

    func test_policy_hidden_when_floats_hidden() {
        XCTAssertFalse(FloatScrimPolicy.isVisible(content(focused: floatA, floatsHidden: true)))
    }

    func test_policy_hidden_with_only_pips_or_minimized() {
        let pip = content(
            focused: floatA,
            modes: [floatA: .pip(corner: .bottomRight, order: 0), floatB: .minimized(order: 0)]
        )
        XCTAssertFalse(FloatScrimPolicy.isVisible(pip), "a PiP never dims, even if it were focused")
        let minimized = content(
            focused: floatB,
            modes: [floatA: .pip(corner: .bottomRight, order: 0), floatB: .minimized(order: 0)]
        )
        XCTAssertFalse(FloatScrimPolicy.isVisible(minimized))
    }

    func test_policy_hidden_when_focused_float_is_gone() {
        XCTAssertFalse(FloatScrimPolicy.isVisible(content(focused: PaneID("closed"))))
    }

    // MARK: - View

    func test_layer_render_shows_and_hides_scrim() {
        let layer = makeLayer()
        layer.render(content(focused: floatA))
        let scrim = layer.scrimViewForTesting
        XCTAssertTrue(scrim.isScrimVisible)
        XCTAssertFalse(scrim.isHidden)
        XCTAssertEqual(scrim.frame, layer.bounds)

        layer.render(content(focused: nil))
        XCTAssertFalse(scrim.isScrimVisible)
        XCTAssertTrue(scrim.isHidden)
    }

    func test_scrim_is_hit_transparent() {
        let layer = makeLayer()
        layer.render(content(focused: floatA))
        let scrim = layer.scrimViewForTesting
        XCTAssertNil(scrim.hitTest(CGPoint(x: 10, y: 10)))
        // Outside both floats: the layer and scrim pass the click through to
        // the strip below.
        XCTAssertNil(layer.hitTest(CGPoint(x: 5, y: 695)))
    }

    func test_scrim_stays_backmost_after_raise() throws {
        let layer = makeLayer()
        layer.render(content(focused: floatB, stackOrders: [floatA: 0, floatB: 1]))
        XCTAssertTrue(layer.subviews.first === layer.scrimViewForTesting)

        // Raise the back float (A) above B.
        layer.render(content(focused: floatA, stackOrders: [floatA: 2, floatB: 1]))
        XCTAssertTrue(layer.subviews.first === layer.scrimViewForTesting)
        let hostA = try XCTUnwrap(layer.floatHostForTesting(floatA))
        XCTAssertTrue(layer.subviews.last === hostA)
    }

    func test_rapid_toggle_ends_in_last_requested_state() {
        let scrim = FloatScrimView(frame: canvas)
        scrim.setVisible(true, animated: true)
        scrim.setVisible(false, animated: true)
        scrim.setVisible(true, animated: true)
        XCTAssertTrue(scrim.isScrimVisible)

        let settled = expectation(description: "fades settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatScrimView.fadeDuration + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(scrim.isHidden)
        XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.001)

        scrim.setVisible(false, animated: true)
        scrim.setVisible(true, animated: true)
        scrim.setVisible(false, animated: true)
        let hidden = expectation(description: "fade-out settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatScrimView.fadeDuration + 0.2) {
            hidden.fulfill()
        }
        wait(for: [hidden], timeout: 2)
        XCTAssertFalse(scrim.isScrimVisible)
        XCTAssertTrue(scrim.isHidden)
        XCTAssertEqual(scrim.alphaValue, 0, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeLayer() -> FloatLayerView {
        let registry = PaneRuntimeRegistry(adapterFactory: { _ in ScrimTestTerminalAdapter() })
        let layer = FloatLayerView(runtimeRegistry: registry)
        layer.frame = canvas
        return layer
    }

    private func content(
        focused: PaneID?,
        floatsHidden: Bool = false,
        modes: [PaneID: FloatingPaneMode] = [:],
        stackOrders: [PaneID: Int] = [:]
    ) -> FloatLayerContent {
        let frames: [PaneID: NormalizedRect] = [
            floatA: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            floatB: NormalizedRect(x: 0.4, y: 0.3, width: 0.4, height: 0.4),
        ]
        let floats = [floatA, floatB].enumerated().map { index, id in
            FloatingPaneState(
                pane: PaneState(id: id, title: id.rawValue),
                mode: modes[id] ?? .floating,
                floatFrame: frames[id]!,
                stackOrder: stackOrders[id] ?? index,
                origin: nil
            )
        }
        return FloatLayerContent(floats: floats, floatsHidden: floatsHidden, focusedFloatID: focused)
    }
}

private extension FloatLayerView {
    func render(_ content: FloatLayerContent) {
        render(content, theme: ZenttyTheme.fallback(for: nil), showPaneBorders: true, smoothScrollingEnabled: false)
    }
}

@MainActor
private final class ScrimTestTerminalAdapter: TerminalAdapter {
    let hasScrollback = false
    let cellWidth: CGFloat = 0
    let cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView {
        NSView(frame: .zero)
    }

    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}
