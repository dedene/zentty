@testable import Zentty
import XCTest

final class CommandAvailabilityResolverTests: XCTestCase {
    func testSinglePaneHidesPaneCommands() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1
        )
        // `closeFocusedPane` stays available: closing the last pane in the
        // last worklane closes the window, which is a legitimate action.
        XCTAssertTrue(available.contains(.closeFocusedPane))
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

    func testTwoPaneWorklaneHidesThirdsAndQuartersPresets() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 2,
            totalPaneCount: 2,
            activeColumnCount: 2,
            focusedColumnPaneCount: 1
        )

        XCTAssertTrue(available.contains(.arrangeWidthFull))
        XCTAssertTrue(available.contains(.arrangeWidthHalves))
        XCTAssertFalse(available.contains(.arrangeWidthThirds))
        XCTAssertFalse(available.contains(.arrangeWidthQuarters))
        XCTAssertTrue(available.contains(.arrangeHeightFull))
        XCTAssertTrue(available.contains(.arrangeHeightTwoPerColumn))
        XCTAssertFalse(available.contains(.arrangeHeightThreePerColumn))
        XCTAssertFalse(available.contains(.arrangeHeightFourPerColumn))
    }

    func testThreePaneWorklaneEnablesThirdsButNotQuartersPresets() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 3,
            totalPaneCount: 3,
            activeColumnCount: 3,
            focusedColumnPaneCount: 3
        )

        XCTAssertTrue(available.contains(.arrangeWidthThirds))
        XCTAssertFalse(available.contains(.arrangeWidthQuarters))
        XCTAssertTrue(available.contains(.arrangeHeightThreePerColumn))
        XCTAssertFalse(available.contains(.arrangeHeightFourPerColumn))
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

    func testGlobalSearchRememberedStateEnablesSearchNavigation() {
        let available = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: 1,
            activePaneCount: 1,
            totalPaneCount: 1,
            focusedPaneHasRememberedSearch: false,
            globalSearchHasRememberedSearch: true
        )

        XCTAssertTrue(available.contains(.findNext))
        XCTAssertTrue(available.contains(.findPrevious))
    }
}
