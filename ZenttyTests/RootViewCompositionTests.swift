import XCTest
@testable import Zentty

final class RootViewCompositionTests: XCTestCase {
    func test_root_controller_loads_sidebar_context_strip_and_pane_strip() {
        let controller = RootViewController()
        controller.loadViewIfNeeded()

        XCTAssertNotNil(controller.view)
        XCTAssertTrue(controller.view.subviews.contains { $0 is AppCanvasView })
    }
}
