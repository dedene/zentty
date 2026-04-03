import XCTest
@testable import Zentty

@MainActor
final class SidebarShimmerCoordinatorTests: XCTestCase {
    func test_shared_sidebar_shimmer_uses_shorter_pause_between_sweeps() {
        XCTAssertEqual(SidebarShimmerCoordinator.pauseRangeForTesting.lowerBound, 2.5)
        XCTAssertEqual(SidebarShimmerCoordinator.pauseRangeForTesting.upperBound, 4.0)
    }
}
