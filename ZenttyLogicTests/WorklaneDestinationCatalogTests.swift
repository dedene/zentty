import XCTest
@testable import Zentty

@MainActor
final class WorklaneDestinationCatalogTests: XCTestCase {

    private let testWindowID = WindowID("wd_test")

    func test_destinationSummaries_excludesNamedWorklane() {
        let store = makeStore(activeID: "A")
        let summaries = store.destinationSummaries(
            windowID: testWindowID,
            excluding: WorklaneID("A")
        )
        XCTAssertEqual(summaries.map(\.worklaneID), [WorklaneID("B"), WorklaneID("C")])
    }

    func test_destinationSummaries_includesAllWhenExclusionIsNil() {
        let store = makeStore(activeID: "A")
        let summaries = store.destinationSummaries(
            windowID: testWindowID,
            excluding: nil
        )
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.map(\.windowID), Array(repeating: testWindowID, count: 3))
    }

    func test_destinationSummaries_preservesWorklaneOrder() {
        let store = makeStore(activeID: "B")
        let summaries = store.destinationSummaries(
            windowID: testWindowID,
            excluding: WorklaneID("B")
        )
        XCTAssertEqual(summaries.map(\.worklaneID), [WorklaneID("A"), WorklaneID("C")])
    }

    func test_summary_primaryPaneTitleAndAdditionalCount_multiplePanes() {
        let store = WorklaneStore(
            windowID: testWindowID,
            worklanes: [
                WorklaneState(
                    id: WorklaneID("multi"),
                    title: "Worklane",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("p1"), title: "vim"),
                            PaneState(id: PaneID("p2"), title: "npm dev"),
                            PaneState(id: PaneID("p3"), title: "ssh"),
                        ],
                        focusedPaneID: PaneID("p1")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("multi")
        )

        let summary = store.destinationSummaries(windowID: testWindowID, excluding: nil).first
        XCTAssertEqual(summary?.primaryPaneTitle, "vim")
        XCTAssertEqual(summary?.additionalPaneCount, 2)
    }

    func test_summary_singlePaneHasZeroAdditional() {
        let store = makeStore(activeID: "A")
        let summary = store.destinationSummaries(windowID: testWindowID, excluding: nil).first
        XCTAssertEqual(summary?.additionalPaneCount, 0)
    }

    func test_summary_emptyTitleFallsBackToUntitled() {
        let store = WorklaneStore(
            windowID: testWindowID,
            worklanes: [
                WorklaneState(
                    id: WorklaneID("blank"),
                    title: "",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("p1"), title: "  ")],
                        focusedPaneID: PaneID("p1")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("blank")
        )
        let summary = store.destinationSummaries(windowID: testWindowID, excluding: nil).first
        XCTAssertEqual(summary?.primaryPaneTitle, "Untitled")
    }

    func test_summary_usesFocusedPaneSidebarIdentityBeforeGeneratedPaneTitle() {
        let paneID = PaneID("p1")
        let projectPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Development/Personal/zentty"
        )
        let store = WorklaneStore(
            windowID: testWindowID,
            worklanes: [
                WorklaneState(
                    id: WorklaneID("contextual"),
                    title: "Contextual",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: paneID, title: "pane 7")],
                        focusedPaneID: paneID
                    ),
                    metadataByPaneID: [
                        paneID: TerminalMetadata(
                            title: "zsh",
                            currentWorkingDirectory: NSHomeDirectory(),
                            processName: "zsh",
                            gitBranch: "main"
                        )
                    ],
                    paneContextByPaneID: [
                        paneID: PaneShellContext(
                            scope: .local,
                            path: projectPath,
                            home: NSHomeDirectory(),
                            user: "peter",
                            host: "m1-pro-peter"
                        )
                    ]
                )
            ],
            activeWorklaneID: WorklaneID("contextual")
        )

        let summary = store.destinationSummaries(windowID: testWindowID, excluding: nil).first

        XCTAssertEqual(summary?.primaryPaneTitle, "main · …/zentty")
    }

    func test_summary_carriesWorklaneColor() {
        let store = WorklaneStore(
            windowID: testWindowID,
            worklanes: [
                WorklaneState(
                    id: WorklaneID("colored"),
                    title: "Colored",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("p1"), title: "vim")],
                        focusedPaneID: PaneID("p1")
                    ),
                    color: .blue
                )
            ],
            activeWorklaneID: WorklaneID("colored")
        )
        let summary = store.destinationSummaries(windowID: testWindowID, excluding: nil).first
        XCTAssertEqual(summary?.color, .blue)
    }

    func test_catalog_hasAnyDestination_emptyAndCanCreateFalse_returnsFalse() {
        let catalog = WorklaneDestinationCatalog(groups: [], canCreateNewWorklane: false)
        XCTAssertFalse(catalog.hasAnyDestination)
    }

    func test_catalog_hasAnyDestination_emptyButCanCreate_returnsTrue() {
        let catalog = WorklaneDestinationCatalog(groups: [], canCreateNewWorklane: true)
        XCTAssertTrue(catalog.hasAnyDestination)
    }

    func test_catalog_hasAnyDestination_withGroups_returnsTrue() {
        let summary = WorklaneDestinationSummary(
            windowID: testWindowID,
            worklaneID: WorklaneID("X"),
            color: nil,
            primaryPaneTitle: "vim",
            additionalPaneCount: 0
        )
        let catalog = WorklaneDestinationCatalog(
            groups: [WorklaneDestinationGroup(windowID: testWindowID, summaries: [summary])],
            canCreateNewWorklane: false
        )
        XCTAssertTrue(catalog.hasAnyDestination)
    }

    private func makeStore(activeID: String) -> WorklaneStore {
        WorklaneStore(
            windowID: testWindowID,
            worklanes: [
                makeWorklane("A"),
                makeWorklane("B"),
                makeWorklane("C"),
            ],
            activeWorklaneID: WorklaneID(activeID)
        )
    }

    private func makeWorklane(_ id: String) -> WorklaneState {
        let paneID = PaneID("pane-\(id)")
        return WorklaneState(
            id: WorklaneID(id),
            title: id,
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: id)],
                focusedPaneID: paneID
            )
        )
    }
}
