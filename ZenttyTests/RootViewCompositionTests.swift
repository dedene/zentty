import XCTest
@testable import Zentty

final class RootViewCompositionTests: XCTestCase {
    func test_root_controller_places_sidebar_outside_inner_canvas() {
        let controller = RootViewController()
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        let rootSubviews = controller.view.subviews
        let sidebarView = rootSubviews.first { $0 is SidebarView }
        let appCanvasView = rootSubviews.first { $0 is AppCanvasView }

        XCTAssertNotNil(sidebarView)
        XCTAssertNotNil(appCanvasView)
        XCTAssertFalse(appCanvasView?.containsDescendant(ofType: SidebarView.self) ?? true)
    }
}

private extension NSView {
    func containsDescendant<T: NSView>(ofType type: T.Type) -> Bool {
        subviews.contains { subview in
            subview is T || subview.containsDescendant(ofType: type)
        }
    }
}
