import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewTests: XCTestCase {
    func test_pane_uses_dedicated_terminal_surface_that_fills_below_header() {
        let paneView = PaneContainerView(
            title: "editor",
            subtitle: "focused",
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true
        )
        paneView.layoutSubtreeIfNeeded()

        guard let headerView = paneView.descendantSubviews().first(where: { $0 is NSStackView }) else {
            return XCTFail("Expected header stack view")
        }

        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalSurfaceMockView"
        }) else {
            return XCTFail("Expected dedicated terminal surface view")
        }

        XCTAssertLessThan(terminalSurfaceView.frame.maxY, headerView.frame.minY)
        XCTAssertGreaterThan(terminalSurfaceView.frame.height, paneView.frame.height * 0.5)
    }
}

private extension NSView {
    func descendantSubviews() -> [NSView] {
        var views: [NSView] = []

        func walk(_ view: NSView) {
            views.append(view)
            view.subviews.forEach(walk)
        }

        subviews.forEach(walk)
        return views
    }
}
