@testable import Zentty
import XCTest

final class CommandAvailabilityResolverTests: XCTestCase {
    func testSinglePaneHidesPaneCommands() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 1, paneCount: 1)
        XCTAssertFalse(available.contains(.closeFocusedPane))
        XCTAssertFalse(available.contains(.focusLeftPane))
        XCTAssertFalse(available.contains(.focusRightPane))
        XCTAssertFalse(available.contains(.resizePaneLeft))
        XCTAssertFalse(available.contains(.resetPaneLayout))
    }

    func testMultiplePanesShowsPaneCommands() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 1, paneCount: 3)
        XCTAssertTrue(available.contains(.closeFocusedPane))
        XCTAssertTrue(available.contains(.focusLeftPane))
        XCTAssertTrue(available.contains(.resizePaneLeft))
        XCTAssertTrue(available.contains(.resetPaneLayout))
    }

    func testSingleWorklaneHidesWorklaneNavigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 1, paneCount: 1)
        XCTAssertFalse(available.contains(.nextWorklane))
        XCTAssertFalse(available.contains(.previousWorklane))
    }

    func testMultipleWorklanesShowsWorklaneNavigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 3, paneCount: 1)
        XCTAssertTrue(available.contains(.nextWorklane))
        XCTAssertTrue(available.contains(.previousWorklane))
    }

    func testCommandPaletteAlwaysHidden() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 5, paneCount: 5)
        XCTAssertFalse(available.contains(.showCommandPalette))
    }

    func testGeneralCommandsAlwaysAvailable() {
        let available = CommandAvailabilityResolver.availableCommandIDs(worklaneCount: 1, paneCount: 1)
        XCTAssertTrue(available.contains(.toggleSidebar))
        XCTAssertTrue(available.contains(.openSettings))
        XCTAssertTrue(available.contains(.reloadConfig))
        XCTAssertTrue(available.contains(.newWorklane))
    }
}
