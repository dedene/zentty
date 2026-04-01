@testable import Zentty
import XCTest

final class CommandAvailabilityResolverTests: XCTestCase {
    func testSinglePaneHidesPaneCommands() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1
        )
        XCTAssertFalse(available.contains(.closeFocusedPane))
        XCTAssertFalse(available.contains(.focusLeftPane))
        XCTAssertFalse(available.contains(.focusRightPane))
        XCTAssertFalse(available.contains(.focusPreviousPane))
        XCTAssertFalse(available.contains(.focusNextPane))
        XCTAssertFalse(available.contains(.resizePaneLeft))
        XCTAssertFalse(available.contains(.resetPaneLayout))
    }

    func testMultiplePanesShowsPaneCommands() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 3,
            totalPaneCount: 3
        )
        XCTAssertTrue(available.contains(.closeFocusedPane))
        XCTAssertTrue(available.contains(.focusLeftPane))
        XCTAssertTrue(available.contains(.focusPreviousPane))
        XCTAssertTrue(available.contains(.focusNextPane))
        XCTAssertTrue(available.contains(.resizePaneLeft))
        XCTAssertTrue(available.contains(.resetPaneLayout))
    }

    func testSingleWorklaneHidesWorklaneNavigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1
        )
        XCTAssertFalse(available.contains(.nextWorklane))
        XCTAssertFalse(available.contains(.previousWorklane))
    }

    func testMultipleWorklanesShowsWorklaneNavigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 3,
            activePaneCount: 1,
            totalPaneCount: 3
        )
        XCTAssertTrue(available.contains(.nextWorklane))
        XCTAssertTrue(available.contains(.previousWorklane))
        XCTAssertTrue(available.contains(.focusPreviousPane))
        XCTAssertTrue(available.contains(.focusNextPane))
    }

    func testCommandPaletteAlwaysHidden() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 5,
            activePaneCount: 5,
            totalPaneCount: 5
        )
        XCTAssertFalse(available.contains(.showCommandPalette))
    }

    func testGeneralCommandsAlwaysAvailable() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1
        )
        XCTAssertTrue(available.contains(.toggleSidebar))
        XCTAssertTrue(available.contains(.openSettings))
        XCTAssertTrue(available.contains(.reloadConfig))
        XCTAssertTrue(available.contains(.newWorklane))
    }
}
