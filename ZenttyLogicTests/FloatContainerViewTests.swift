import AppKit
import XCTest
@testable import Zentty

@MainActor
final class FloatContainerViewTests: AppKitTestCase {
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
            width: 300,
            height: 200,
            emphasis: 1,
            isFocused: false,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil),
            backingScaleFactorProvider: { 1 }
        )
    }

    func test_pane_container_inset_by_chrome_outset() {
        let host = FloatContainerView(paneID: PaneID("float"))
        let container = makePaneContainer()
        let paneFrame = CGRect(x: 100, y: 80, width: 400, height: 250)

        host.setPaneFrame(paneFrame)
        host.host(container)

        let outset = FloatContainerView.chromeOutset
        XCTAssertEqual(outset, 10)
        XCTAssertEqual(host.frame, paneFrame.insetBy(dx: -outset, dy: -outset))
        XCTAssertEqual(host.paneFrame, paneFrame)
        XCTAssertTrue(container.superview === host)
        XCTAssertEqual(container.frame, host.bounds.insetBy(dx: outset, dy: outset))

        host.setPaneFrame(CGRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(container.frame.size, CGSize(width: 500, height: 300))
    }

    func test_resting_shadow_layers_match_spec() {
        let host = FloatContainerView(paneID: PaneID("float"))
        host.setPaneFrame(CGRect(x: 0, y: 0, width: 400, height: 250))

        let layers = host.shadowLayersForTesting
        XCTAssertEqual(layers.count, 2)
        XCTAssertTrue(layers.allSatisfy { $0.shadowPath != nil })
        XCTAssertEqual(layers.map(\.shadowRadius), [60, 10])
        XCTAssertEqual(layers.map(\.shadowOpacity), [0.55, 0.40])
        XCTAssertEqual(layers.map(\.shadowOffset.height), [-22, -3])
        XCTAssertTrue(layers.allSatisfy { $0.frame == host.bounds.insetBy(dx: 10, dy: 10) })
        XCTAssertTrue(layers.allSatisfy { $0.zPosition < 0 }, "shadows sit behind the pane")
    }

    func test_lifted_shadow_is_deeper() {
        let host = FloatContainerView(paneID: PaneID("float"))
        host.setPaneFrame(CGRect(x: 0, y: 0, width: 400, height: 250))

        host.setLifted(true, animated: false)

        let layers = host.shadowLayersForTesting
        XCTAssertEqual(layers.map(\.shadowRadius), [80, 16])
        XCTAssertEqual(layers.map(\.shadowOpacity), [0.60, 0.45])

        host.setLifted(false, animated: false)
        XCTAssertEqual(host.shadowLayersForTesting.map(\.shadowRadius), [60, 10])
    }

    func test_outset_is_hit_transparent_but_buttons_above_the_edge_are_hit() throws {
        let superview = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = FloatContainerView(paneID: PaneID("float"))
        superview.addSubview(host)
        let container = makePaneContainer()
        host.setPaneFrame(CGRect(x: 100, y: 100, width: 400, height: 250))
        host.host(container)
        container.chromeKind = .float
        container.layoutSubtreeIfNeeded()

        XCTAssertNil(host.hitTest(CGPoint(x: 95, y: 200)), "the outset passes clicks through")

        let actions = try XCTUnwrap(container.borderActionsFrameForTesting)
        let button = try XCTUnwrap(container.borderActionsViewForTesting.buttonForTesting(.close))
        let closeFrame = container.convert(button.frame, from: container.borderActionsViewForTesting)
        let pointInContainer = CGPoint(x: closeFrame.midX, y: actions.maxY - 2)
        let point = superview.convert(pointInContainer, from: container)
        XCTAssertTrue(host.hitTest(point) === button)
    }
}
