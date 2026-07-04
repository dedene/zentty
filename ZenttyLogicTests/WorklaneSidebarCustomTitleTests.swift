import XCTest
@testable import Zentty

@MainActor
final class WorklaneSidebarCustomTitleTests: XCTestCase {
    func test_summary_uses_custom_title_as_primary_and_cwd_as_detail() throws {
        let paneID = PaneID("pn_a")
        let auxiliary = PaneAuxiliaryState(
            raw: PaneRawState(
                shellContext: PaneShellContext(
                    scope: .local,
                    path: "/Users/peter/proj/nimbu",
                    home: "/Users/peter",
                    user: "peter",
                    host: nil
                )
            )
        )
        let worklane = WorklaneState(
            id: WorklaneID("wl_a"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        customTitle: "Nimbu API"
                    ),
                ],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliary]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let paneRow = try XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(paneRow.primaryText, "Nimbu API")
        XCTAssertTrue(paneRow.usesCustomTitle)
        XCTAssertNotNil(paneRow.detailText)
    }

    func test_summary_uses_custom_title_as_primary_for_remote_shell() throws {
        let paneID = PaneID("pn_remote")
        let auxiliary = PaneAuxiliaryState(
            presentation: PanePresentationState(
                rememberedTitle: "ssh",
                isRemoteShell: true,
                remoteHostLabel: "api.example.com",
                remotePathLabel: "/srv/nimbu",
                remoteLocationLabel: "api.example.com:/srv/nimbu"
            )
        )
        let worklane = WorklaneState(
            id: WorklaneID("wl_remote"),
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        customTitle: "Nimbu API"
                    ),
                ],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliary]
        )

        let summary = WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: true)
        let paneRow = try XCTUnwrap(summary.paneRows.first)

        XCTAssertEqual(summary.primaryText, "Nimbu API")
        XCTAssertEqual(paneRow.primaryText, "Nimbu API")
        XCTAssertEqual(paneRow.trailingText, "api.example.com")
        XCTAssertEqual(paneRow.detailText, "/srv/nimbu")
        XCTAssertTrue(paneRow.usesCustomTitle)
    }
}
