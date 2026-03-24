import Foundation
import XCTest
@testable import Zentty

final class WorkspaceAttentionSummaryBuilderTests: XCTestCase {
    func test_summary_uses_canonical_presentation_state_instead_of_raw_agent_fallbacks() {
        let paneID = PaneID("pane-shell")
        let expectedArtifact = WorkspaceArtifactLink(
            kind: .share,
            label: "Share transcript",
            url: URL(string: "https://example.com/share")!,
            isExplicit: true
        )

        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .completed,
            text: "Completed",
            artifactLink: WorkspaceArtifactLink(
                kind: .session,
                label: "Old session",
                url: URL(string: "https://example.com/session")!,
                isExplicit: true
            ),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Test session setup",
            contextText: "main · /tmp/project",
            rememberedTitle: "Test session setup",
            recognizedTool: .codex,
            runtimePhase: .needsInput,
            statusText: "Needs input",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: expectedArtifact,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false
        )

        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorkspaceAttentionSummaryBuilder.summary(for: workspace)

        XCTAssertEqual(summary?.paneID, paneID)
        XCTAssertEqual(summary?.tool, .codex)
        XCTAssertEqual(summary?.state, .needsInput)
        XCTAssertEqual(summary?.primaryText, "Test session setup")
        XCTAssertEqual(summary?.statusText, "Needs input")
        XCTAssertEqual(summary?.contextText, "main · /tmp/project")
        XCTAssertEqual(summary?.artifactLink, expectedArtifact)
        XCTAssertEqual(summary?.updatedAt, Date(timeIntervalSince1970: 42))
    }

    func test_summary_returns_nil_for_starting_phase_even_with_artifact_metadata() {
        let paneID = PaneID("pane-shell")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "main · /tmp/project",
            contextText: "main · /tmp/project",
            rememberedTitle: nil,
            recognizedTool: .claudeCode,
            runtimePhase: .starting,
            statusText: nil,
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: WorkspaceArtifactLink(
                kind: .share,
                label: "Share transcript",
                url: URL(string: "https://example.com/share")!,
                isExplicit: true
            ),
            updatedAt: Date(timeIntervalSince1970: 99),
            isWorking: false
        )

        let workspace = WorkspaceState(
            id: WorkspaceID("workspace-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        XCTAssertNil(WorkspaceAttentionSummaryBuilder.summary(for: workspace))
    }
}
