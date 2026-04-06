import Foundation
import XCTest
@testable import Zentty

final class WorklaneAttentionSummaryBuilderTests: XCTestCase {
    func test_summary_ignores_idle_phase() {
        let paneID = PaneID("pane-shell")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = PanePresentationState(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            branch: "main",
            branchDisplayText: "main",
            lookupBranch: "main",
            identityText: "Codex",
            contextText: "main · /tmp/project",
            rememberedTitle: "Codex",
            recognizedTool: .codex,
            runtimePhase: .idle,
            statusText: "Idle",
            pullRequest: nil,
            reviewChips: [],
            attentionArtifactLink: nil,
            updatedAt: Date(timeIntervalSince1970: 42),
            isWorking: false
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        XCTAssertNil(WorklaneAttentionSummaryBuilder.summary(for: worklane))
    }

    func test_summary_uses_canonical_presentation_state_instead_of_raw_agent_fallbacks() {
        let paneID = PaneID("pane-shell")
        let expectedArtifact = WorklaneArtifactLink(
            kind: .share,
            label: "Share transcript",
            url: URL(string: "https://example.com/share")!,
            isExplicit: true
        )

        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .idle,
            text: "Idle",
            artifactLink: WorklaneArtifactLink(
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
            isWorking: false,
            interactionKind: .question,
            interactionLabel: "Needs decision",
            interactionSymbolName: "list.bullet"
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneAttentionSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary?.paneID, paneID)
        XCTAssertEqual(summary?.tool, .codex)
        XCTAssertEqual(summary?.state, .needsInput)
        XCTAssertEqual(summary?.interactionKind, .question)
        XCTAssertEqual(summary?.interactionLabel, "Needs decision")
        XCTAssertEqual(summary?.primaryText, "Test session setup")
        XCTAssertEqual(summary?.statusText, "Needs decision")
        XCTAssertEqual(summary?.contextText, "main · /tmp/project")
        XCTAssertEqual(summary?.artifactLink, expectedArtifact)
        XCTAssertEqual(summary?.interactionSymbolName, "list.bullet")
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
            attentionArtifactLink: WorklaneArtifactLink(
                kind: .share,
                label: "Share transcript",
                url: URL(string: "https://example.com/share")!,
                isExplicit: true
            ),
            updatedAt: Date(timeIntervalSince1970: 99),
            isWorking: false
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        XCTAssertNil(WorklaneAttentionSummaryBuilder.summary(for: worklane))
    }

    func test_summary_surfaces_ready_state_for_completed_agent_turn() {
        let paneID = PaneID("pane-shell")
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "Implement ready notifications",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: PaneAgentStatus(
                tool: .claudeCode,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true
            ),
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            ),
            showsReadyStatus: true,
            lastDesktopNotificationText: "Agent ready",
            lastDesktopNotificationDate: Date(timeIntervalSince1970: 42)
        )
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: auxiliaryState.raw,
            previous: nil
        )

        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "shell")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        let summary = WorklaneAttentionSummaryBuilder.summary(for: worklane)

        XCTAssertEqual(summary?.state, .ready)
        XCTAssertEqual(summary?.statusText, "Agent ready")
        XCTAssertEqual(summary?.primaryText, "Implement ready notifications")
    }

}
