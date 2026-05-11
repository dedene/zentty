import AppKit
import XCTest
@testable import Zentty

@MainActor
final class MoveToWorklaneMenuBuilderTests: XCTestCase {

    private let sourcePaneID = PaneID("source-pane")

    func test_singleWorklaneRow_singlePane_omitsAdditionalSuffix() {
        let summary = makeSummary(windowID: "w1", worklaneID: "A", primary: "vim", additional: 0)
        let catalog = WorklaneDestinationCatalog(
            groups: [WorklaneDestinationGroup(windowID: WindowID("w1"), summaries: [summary])],
            canCreateNewWorklane: false
        )

        let menu = MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: sourcePaneID)

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, "vim")
        XCTAssertFalse(menu.items[0].isSeparatorItem)
    }

    func test_singleWorklaneRow_multiplePanes_appendsAdditionalSuffix() {
        let summary = makeSummary(windowID: "w1", worklaneID: "A", primary: "vim", additional: 2)
        let catalog = WorklaneDestinationCatalog(
            groups: [WorklaneDestinationGroup(windowID: WindowID("w1"), summaries: [summary])],
            canCreateNewWorklane: false
        )

        let menu = MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: sourcePaneID)

        XCTAssertEqual(menu.items[0].title, "vim  +2 more")
    }

    func test_multipleGroups_insertsSeparatorBetweenWindows() {
        let g1 = WorklaneDestinationGroup(
            windowID: WindowID("w1"),
            summaries: [
                makeSummary(windowID: "w1", worklaneID: "A", primary: "vim", additional: 0),
                makeSummary(windowID: "w1", worklaneID: "B", primary: "shell", additional: 0),
            ]
        )
        let g2 = WorklaneDestinationGroup(
            windowID: WindowID("w2"),
            summaries: [
                makeSummary(windowID: "w2", worklaneID: "C", primary: "ssh", additional: 0),
            ]
        )
        let catalog = WorklaneDestinationCatalog(
            groups: [g1, g2],
            canCreateNewWorklane: false
        )

        let menu = MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: sourcePaneID)

        XCTAssertEqual(menu.items.count, 4)
        XCTAssertEqual(menu.items[0].title, "vim")
        XCTAssertEqual(menu.items[1].title, "shell")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "ssh")
    }

    func test_canCreateNewWorklane_appendsItemAfterSeparator() {
        let summary = makeSummary(windowID: "w1", worklaneID: "A", primary: "vim", additional: 0)
        let catalog = WorklaneDestinationCatalog(
            groups: [WorklaneDestinationGroup(windowID: WindowID("w1"), summaries: [summary])],
            canCreateNewWorklane: true
        )

        let menu = MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: sourcePaneID)

        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].title, "vim")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "New Worklane in This Window")
    }

    func test_emptyGroupsButCanCreateNewWorklane_omitsLeadingSeparator() {
        let catalog = WorklaneDestinationCatalog(
            groups: [],
            canCreateNewWorklane: true
        )

        let menu = MoveToWorklaneMenuBuilder.makeSubmenu(catalog: catalog, paneID: sourcePaneID)

        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, "New Worklane in This Window")
        XCTAssertFalse(menu.items[0].isSeparatorItem)
    }

    func test_destinationItem_carriesRequestRepresentedObject() {
        let summary = makeSummary(windowID: "w7", worklaneID: "X", primary: "vim", additional: 0)
        let item = MoveToWorklaneMenuBuilder.makeDestinationItem(summary: summary, paneID: sourcePaneID)

        let request = item.representedObject as? MovePaneToWorklaneRequest
        XCTAssertEqual(request?.sourcePaneID, sourcePaneID)
        XCTAssertEqual(request?.destinationWindowID, WindowID("w7"))
        XCTAssertEqual(request?.destinationWorklaneID, WorklaneID("X"))
    }

    func test_newWorklaneItem_carriesPaneIDRepresentedObject() {
        let item = MoveToWorklaneMenuBuilder.makeNewWorklaneItem(paneID: sourcePaneID)
        XCTAssertEqual(item.representedObject as? PaneID, sourcePaneID)
    }

    func test_destinationItem_actionTargetsMovePaneToWorklane() {
        let summary = makeSummary(windowID: "w1", worklaneID: "A", primary: "vim", additional: 0)
        let item = MoveToWorklaneMenuBuilder.makeDestinationItem(summary: summary, paneID: sourcePaneID)
        XCTAssertEqual(item.action, #selector(MainWindowController.movePaneToWorklane(_:)))
    }

    func test_newWorklaneItem_actionTargetsMovePaneToNewWorklaneInThisWindow() {
        let item = MoveToWorklaneMenuBuilder.makeNewWorklaneItem(paneID: sourcePaneID)
        XCTAssertEqual(item.action, #selector(MainWindowController.movePaneToNewWorklaneInThisWindow(_:)))
    }

    func test_worklaneColorDotImage_isNonNil() {
        let withColor = MoveToWorklaneMenuBuilder.worklaneColorDotImage(for: .blue)
        let withoutColor = MoveToWorklaneMenuBuilder.worklaneColorDotImage(for: nil)
        XCTAssertGreaterThan(withColor.size.width, 0)
        XCTAssertGreaterThan(withoutColor.size.width, 0)
    }

    private func makeSummary(
        windowID: String,
        worklaneID: String,
        primary: String,
        additional: Int,
        color: WorklaneColor? = nil
    ) -> WorklaneDestinationSummary {
        WorklaneDestinationSummary(
            windowID: WindowID(windowID),
            worklaneID: WorklaneID(worklaneID),
            color: color,
            primaryPaneTitle: primary,
            additionalPaneCount: additional
        )
    }
}
