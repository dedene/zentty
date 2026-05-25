import XCTest
@testable import Zentty

final class HermesTitleStatusTests: XCTestCase {
    func test_hermes_tui_title_markers_map_to_realtime_phases() {
        XCTAssertEqual(
            TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                "⏳ grok-4.3 · 19.9K/1M · 2%",
                recognizedTool: .hermes
            )?.phase,
            .running
        )
        XCTAssertEqual(
            TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                "✓ grok-4.3 · 19.9K/1M",
                recognizedTool: .hermes
            )?.phase,
            .idle
        )
        XCTAssertEqual(
            TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                "⚠️ grok-4.3 · clarify",
                recognizedTool: .hermes
            )?.phase,
            .needsInput
        )
        XCTAssertTrue(
            TerminalMetadataChangeClassifier.isRealtimeAgentStatusTitle(
                "⏳ grok-4.3 · 19.9K/1M · 2%",
                recognizedTool: .hermes
            )
        )
    }

    func test_hermes_running_title_overrides_idle_hook_state() {
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "hermes",
            raw: rawState(
                title: "⏳ grok-4.3 · 19.9K/1M · 2%",
                agentState: .idle
            ),
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_hermes_running_title_sets_phase_before_hooks_arrive() {
        let metadata = TerminalMetadata(
            title: "⏳ grok-4.3 · 19.9K/1M · 2%",
            currentWorkingDirectory: "/tmp/project",
            processName: "hermes",
            gitBranch: "main"
        )

        XCTAssertEqual(AgentToolRecognizer.recognize(metadata: metadata), .hermes)

        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "hermes",
            raw: rawState(
                title: "⏳ grok-4.3 · 19.9K/1M · 2%",
                agentState: nil
            ),
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_hermes_idle_title_clears_stale_running_hook_state() {
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "hermes",
            raw: rawState(
                title: "✓ grok-4.3 · 19.9K/1M",
                agentState: .running
            ),
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .idle)
        XCTAssertNotEqual(presentation.statusText, "Running")
    }

    func test_hermes_attention_title_overrides_running_hook_state() {
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "hermes",
            raw: rawState(
                title: "⚠️ grok-4.3 · clarify",
                agentState: .running
            ),
            previous: nil
        )

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertEqual(presentation.statusText, "Needs input")
    }

    private func rawState(
        title: String,
        agentState: PaneAgentState?
    ) -> PaneRawState {
        PaneRawState(
            metadata: TerminalMetadata(
                title: title,
                currentWorkingDirectory: "/tmp/project",
                processName: "hermes",
                gitBranch: "main"
            ),
            shellContext: nil,
            agentStatus: agentState.map { state in PaneAgentStatus(
                tool: .hermes,
                state: state,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
            ) },
            terminalProgress: nil,
            reviewState: nil,
            gitContext: PaneGitContext(
                workingDirectory: "/tmp/project",
                repositoryRoot: "/tmp/project",
                reference: .branch("main")
            )
        )
    }
}
