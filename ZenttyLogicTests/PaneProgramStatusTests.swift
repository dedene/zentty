import XCTest
@testable import Zentty

/// OSC 9;4 → program status mapping and clearing rules.
final class PaneProgramStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func test_report_states_map_to_program_status() {
        XCTAssertNil(PaneProgramStatus(report: report(.remove), now: now))

        let percent = PaneProgramStatus(report: report(.set, 42), now: now)
        XCTAssertEqual(percent?.state, .working)
        XCTAssertEqual(percent?.percent, 42)

        let setWithoutPercent = PaneProgramStatus(report: report(.set), now: now)
        XCTAssertEqual(setWithoutPercent?.state, .working)
        XCTAssertNil(setWithoutPercent?.percent)

        let indeterminate = PaneProgramStatus(report: report(.indeterminate), now: now)
        XCTAssertEqual(indeterminate?.state, .working)
        XCTAssertNil(indeterminate?.percent)

        XCTAssertEqual(PaneProgramStatus(report: report(.error), now: now)?.state, .error)
        XCTAssertEqual(PaneProgramStatus(report: report(.pause), now: now)?.state, .paused)
    }

    func test_percent_drives_a_progress_ring_only_while_working_below_100() throws {
        let working = PaneProgramStatus(state: .working, percent: 42, updatedAt: now)
        let ring = try XCTUnwrap(working.taskProgress)
        XCTAssertEqual(ring.unit, .percent)
        XCTAssertEqual(ring.doneCount, 42)
        XCTAssertEqual(ring.totalCount, 100)
        XCTAssertEqual(ring.readoutText, "42%")
        XCTAssertEqual(working.presentedStatusText, "Running (42%)")

        XCTAssertNil(PaneProgramStatus(state: .working, percent: 100, updatedAt: now).taskProgress)
        XCTAssertNil(PaneProgramStatus(state: .error, percent: 42, updatedAt: now).taskProgress)
        XCTAssertEqual(PaneProgramStatus(state: .working, updatedAt: now).presentedStatusText, "Running")
    }

    func test_prompt_return_clears_working_and_paused_but_keeps_error() {
        XCTAssertNil(status(.working).surviving(.commandFinished))
        XCTAssertNil(status(.paused).surviving(.commandFinished))
        let finishedError = status(.error).surviving(.commandFinished)
        XCTAssertEqual(finishedError?.state, .error)
        XCTAssertEqual(finishedError?.outlivedPrompt, true)
    }

    func test_next_command_clears_a_previous_error_but_not_a_fresh_report() {
        let previousError = status(.error).surviving(.commandFinished)
        XCTAssertNil(previousError?.surviving(.commandStarted))
        XCTAssertEqual(status(.error).surviving(.commandStarted), status(.error))
        XCTAssertEqual(status(.working).surviving(.commandStarted), status(.working))
        XCTAssertEqual(status(.paused).surviving(.commandStarted), status(.paused))
    }

    func test_submitted_input_resolves_paused_and_error_but_keeps_working() {
        XCTAssertEqual(status(.working).surviving(.userSubmittedInput), status(.working))
        XCTAssertNil(status(.paused).surviving(.userSubmittedInput))
        XCTAssertNil(status(.error).surviving(.userSubmittedInput))
    }

    func test_interrupt_and_fresh_shell_clear_everything() {
        for state in [PaneProgramStatus.State.working, .paused, .error] {
            XCTAssertNil(status(state).surviving(.userInterrupted))
            XCTAssertNil(status(state).surviving(.shellReady))
        }
    }

    func test_only_a_working_status_goes_stale() {
        let later = now.addingTimeInterval(PaneProgramStatus.staleInterval)
        XCTAssertFalse(status(.working).isStale(now: later.addingTimeInterval(-1)))
        XCTAssertTrue(status(.working).isStale(now: later))
        XCTAssertFalse(status(.paused).isStale(now: later))
        XCTAssertFalse(status(.error).isStale(now: later))
    }

    func test_program_name_prefers_foreground_process_then_last_command() {
        XCTAssertEqual(
            PaneProgramStatus.programName(
                metadata: TerminalMetadata(title: nil, currentWorkingDirectory: nil, processName: "cargo", gitBranch: nil),
                lastRunCommand: "make"
            ),
            "cargo"
        )
        XCTAssertEqual(
            PaneProgramStatus.programName(
                metadata: TerminalMetadata(title: nil, currentWorkingDirectory: nil, processName: "zsh", gitBranch: nil),
                lastRunCommand: "CI=1 ./scripts/build.sh --fast"
            ),
            "build.sh"
        )
        XCTAssertEqual(PaneProgramStatus.programName(metadata: nil, lastRunCommand: nil), "Terminal")
    }

    func test_panes_program_status_config_round_trips() throws {
        var config = AppConfig.default
        XCTAssertTrue(config.panes.programStatusEnabled)
        config.panes.programStatusEnabled = false

        let encoded = AppConfigTOML.encode(config)
        XCTAssertTrue(encoded.contains("program_status = false"))
        let decoded = try XCTUnwrap(AppConfigTOML.decode(encoded))
        XCTAssertFalse(decoded.panes.programStatusEnabled)
    }

    private func status(_ state: PaneProgramStatus.State) -> PaneProgramStatus {
        PaneProgramStatus(state: state, updatedAt: now)
    }

    private func report(_ state: TerminalProgressReport.State, _ progress: UInt8? = nil) -> TerminalProgressReport {
        TerminalProgressReport(state: state, progress: progress)
    }
}

/// Program status in pane presentation and the sidebar, and its precedence
/// below agent status.
final class PaneProgramStatusPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func test_working_with_percent_presents_running_with_a_percent_ring() throws {
        let presentation = normalize(PaneProgramStatus(state: .working, percent: 42, updatedAt: now))

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertTrue(presentation.isWorking)
        XCTAssertEqual(presentation.statusText, "Running (42%)")
        XCTAssertEqual(presentation.taskProgress?.unit, .percent)
        XCTAssertEqual(presentation.programName, "cargo")

        let row = WorklaneSidebarSummaryBuilder.paneRow(for: paneContext(presentation), isFocused: false)
        XCTAssertEqual(row.statusText, "Running")
        XCTAssertEqual(row.attentionState, .running)
        XCTAssertEqual(row.taskProgress?.doneCount, 42)
        XCTAssertTrue(row.isWorking)
    }

    func test_paused_presents_needs_attention_labelled_paused() {
        let presentation = normalize(PaneProgramStatus(state: .paused, updatedAt: now))

        XCTAssertEqual(presentation.runtimePhase, .needsInput)
        XCTAssertNil(presentation.interactionKind)
        XCTAssertEqual(presentation.interactionLabel, "Paused")

        let row = WorklaneSidebarSummaryBuilder.paneRow(for: paneContext(presentation), isFocused: false)
        XCTAssertEqual(row.statusText, "Paused")
        XCTAssertEqual(row.attentionState, .needsInput)
        XCTAssertEqual(row.interactionSymbolName, "pause.circle")
        XCTAssertFalse(row.isWorking)
    }

    func test_error_presents_an_error_attention_state() {
        let presentation = normalize(PaneProgramStatus(state: .error, updatedAt: now))

        XCTAssertEqual(presentation.runtimePhase, .unresolvedStop)
        XCTAssertEqual(presentation.statusText, "Error")

        let row = WorklaneSidebarSummaryBuilder.paneRow(for: paneContext(presentation), isFocused: false)
        XCTAssertEqual(row.statusText, "Error")
        XCTAssertEqual(row.attentionState, .unresolvedStop)
    }

    func test_agent_status_wins_over_program_status() {
        var raw = rawState(programStatus: PaneProgramStatus(state: .error, updatedAt: now))
        raw.agentStatus = PaneAgentStatus(
            tool: .claudeCode,
            state: .running,
            text: nil,
            artifactLink: nil,
            updatedAt: now
        )

        let presentation = PanePresentationNormalizer.normalize(paneTitle: nil, raw: raw, previous: nil)

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertNil(presentation.programStatus)
        XCTAssertEqual(presentation.statusText, "Running")
    }

    func test_recognized_agent_without_hooks_hides_program_status() {
        var raw = rawState(programStatus: PaneProgramStatus(state: .paused, updatedAt: now))
        raw.metadata = TerminalMetadata(
            title: "Claude Code",
            currentWorkingDirectory: "/tmp/project",
            processName: "claude",
            gitBranch: nil
        )

        let presentation = PanePresentationNormalizer.normalize(paneTitle: nil, raw: raw, previous: nil)

        XCTAssertEqual(presentation.recognizedTool, .claudeCode)
        XCTAssertNil(presentation.programStatus)
        XCTAssertNotEqual(presentation.runtimePhase, .needsInput)
    }

    func test_copilot_osc_activity_still_promotes_its_idle_session() {
        var raw = rawState(programStatus: nil)
        raw.metadata = TerminalMetadata(
            title: "GitHub Copilot",
            currentWorkingDirectory: "/tmp/project",
            processName: "copilot",
            gitBranch: nil
        )
        raw.agentStatus = PaneAgentStatus(tool: .copilot, state: .idle, text: nil, artifactLink: nil, updatedAt: now)
        raw.terminalProgress = TerminalProgressReport(state: .indeterminate, progress: nil)

        let presentation = PanePresentationNormalizer.normalize(paneTitle: nil, raw: raw, previous: nil)

        XCTAssertEqual(presentation.runtimePhase, .running)
        XCTAssertNil(presentation.programStatus)
    }

    func test_raw_terminal_progress_alone_no_longer_marks_a_plain_pane_running() {
        var raw = rawState(programStatus: nil)
        raw.terminalProgress = TerminalProgressReport(state: .indeterminate, progress: nil)

        let presentation = PanePresentationNormalizer.normalize(paneTitle: nil, raw: raw, previous: nil)

        XCTAssertEqual(presentation.runtimePhase, .idle)
    }

    private func normalize(_ programStatus: PaneProgramStatus) -> PanePresentationState {
        PanePresentationNormalizer.normalize(
            paneTitle: nil,
            raw: rawState(programStatus: programStatus),
            previous: nil
        )
    }

    private func rawState(programStatus: PaneProgramStatus?) -> PaneRawState {
        var raw = PaneRawState(
            metadata: TerminalMetadata(
                title: "cargo build",
                currentWorkingDirectory: "/tmp/project",
                processName: "cargo",
                gitBranch: nil
            )
        )
        raw.programStatus = programStatus
        return raw
    }

    private func paneContext(_ presentation: PanePresentationState) -> WorklanePaneContext {
        var auxiliaryState = PaneAuxiliaryState()
        auxiliaryState.presentation = presentation
        return WorklanePaneContext(
            pane: PaneState(id: PaneID("pane-program"), title: "cargo"),
            auxiliaryState: auxiliaryState
        )
    }
}
