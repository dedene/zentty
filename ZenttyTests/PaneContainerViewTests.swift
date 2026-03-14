import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneContainerViewTests: XCTestCase {
    func test_pane_hosts_terminal_edge_to_edge_without_internal_header() {
        let paneView = PaneContainerView(
            pane: PaneState(id: PaneID("editor"), title: "editor"),
            width: 420,
            height: 520,
            emphasis: 1,
            isFocused: true
        )
        paneView.layoutSubtreeIfNeeded()

        guard let terminalSurfaceView = paneView.descendantSubviews().first(where: {
            String(describing: type(of: $0)) == "TerminalPaneHostView"
        }) else {
            return XCTFail("Expected dedicated terminal host view")
        }

        XCTAssertFalse(paneView.descendantSubviews().contains { $0 is NSStackView })
        XCTAssertEqual(terminalSurfaceView.frame, paneView.bounds)
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
