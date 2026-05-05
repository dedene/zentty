import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreTeamAnchorTests: XCTestCase {
    func test_paneBorderContextDisplay_marks_recorded_leader() throws {
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklane = try XCTUnwrap(store.activeWorklane)

        let display = worklane.paneBorderContextDisplayByPaneID(leaderPaneID: paneID)

        XCTAssertEqual(display[paneID]?.isAgentTeamLeader, true)
    }

    func test_paneBorderContextDisplay_preserves_existing_text_when_marking_leader() throws {
        // When the leader pane already has shell-context text, the model
        // should keep that text and just toggle the leader flag.
        let store = WorklaneStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklane = try XCTUnwrap(store.activeWorklane)

        let baselineText = worklane.paneBorderContextDisplayByPaneID[paneID]?.text
        let display = worklane.paneBorderContextDisplayByPaneID(leaderPaneID: paneID)

        XCTAssertEqual(display[paneID]?.isAgentTeamLeader, true)
        XCTAssertEqual(display[paneID]?.text, baselineText)
    }

    func test_paneBorderContextDisplay_returns_unmodified_when_no_leader() throws {
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)

        let baseline = worklane.paneBorderContextDisplayByPaneID
        let display = worklane.paneBorderContextDisplayByPaneID(leaderPaneID: nil)

        XCTAssertEqual(baseline, display)
    }

    func test_paneBorderContextDisplay_marks_recorded_members_with_existing_text() throws {
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)
        let memberID = try XCTUnwrap(worklane.paneStripState.focusedPaneID)

        // Only flag members that already have shell-context text — empty
        // members should not be force-created.
        guard worklane.paneBorderContextDisplayByPaneID[memberID] != nil else {
            throw XCTSkip("Active pane has no shell-context text in this fixture")
        }

        let display = worklane.paneBorderContextDisplayByPaneID(
            leaderPaneID: PaneID("pn_other_leader"),
            memberPaneIDs: [memberID]
        )

        XCTAssertEqual(display[memberID]?.isAgentTeamMember, true)
        XCTAssertEqual(display[memberID]?.isAgentTeamLeader, false)
    }

    func test_paneBorderContextDisplay_does_not_flag_member_when_id_matches_leader() throws {
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)
        let paneID = try XCTUnwrap(worklane.paneStripState.focusedPaneID)

        let display = worklane.paneBorderContextDisplayByPaneID(
            leaderPaneID: paneID,
            memberPaneIDs: [paneID]
        )

        XCTAssertEqual(display[paneID]?.isAgentTeamLeader, true)
        XCTAssertEqual(display[paneID]?.isAgentTeamMember, false)
    }

    func test_paneBorderContextDisplay_ignores_leader_id_pointing_at_unknown_pane() throws {
        // Stale anchor (workspace restored with fresh pane IDs) — should not
        // create a phantom entry for a pane that doesn't exist.
        let store = WorklaneStore()
        let worklane = try XCTUnwrap(store.activeWorklane)

        let display = worklane.paneBorderContextDisplayByPaneID(
            leaderPaneID: PaneID("pn_does_not_exist")
        )

        XCTAssertNil(display[PaneID("pn_does_not_exist")])
    }
}
