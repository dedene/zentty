import Foundation
import XCTest
@testable import Zentty

/// The inert test host must never index the user's agent history (critic d9).
@MainActor
final class AgentHistoryHostedGateTests: XCTestCase {
    func test_hosted_app_never_starts_indexer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directoryURL = ZenttyBuildFlavor.current.stateDirectoryURL(homeDirectoryURL: home)
            .appendingPathComponent(AgentHistoryPaths.directoryName, isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: directoryURL.path)

        let controller = AgentHistoryController.shared

        XCTAssertFalse(controller.isLaunchStartScheduled, "the test host never schedules the launch start")
        XCTAssertEqual(controller.status.state, .off)
        XCTAssertEqual(controller.threadSafeStatus.state, .off)
        XCTAssertNil(controller.storage)
        if !existedBefore {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directoryURL.path),
                "no Agent History directory is created during the test run"
            )
        }
    }
}
