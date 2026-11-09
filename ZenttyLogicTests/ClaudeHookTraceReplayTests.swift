import Foundation
import XCTest
@testable import Zentty

/// Replays real Claude Code hook streams through the real adapter, session
/// store and `WorklaneStore`, with the terminal titles that arrived between
/// the hooks.
///
/// The agent bench stands in for the app, so a bench pass says nothing about
/// this code. The fixtures are sanitized recordings from the `hook_trace`
/// bench scenarios (`scripts/agent-bench/README.md`), so these tests are what
/// ties the prompt handling to Claude's actual payloads. To check a new Claude
/// version, record the scenario and copy the trace over the fixture.
@MainActor
final class ClaudeHookTraceReplayTests: XCTestCase {

    func test_approved_write_resumes_and_the_turn_ends() throws {
        let replay = try replayTrace("approval")

        XCTAssertEqual(replay.status(after: "PreToolUse Write")?.state, .running)
        let prompt = replay.status(after: "PermissionRequest Write")
        XCTAssertEqual(prompt?.state, .needsInput)
        XCTAssertEqual(prompt?.interactionKind, .approval)
        XCTAssertEqual(replay.status(after: "input approve")?.state, .needsInput, "typing the key is not an answer until Claude acts on it")
        XCTAssertEqual(replay.status(after: "PostToolUse Write")?.state, .running)
        XCTAssertEqual(replay.status(after: "PostToolUse Write")?.interactionKind, PaneAgentInteractionKind.none)
        XCTAssertEqual(replay.status(after: "Stop")?.state, .idle)
        try replay.assertNoPromptStored()
    }

    func test_work_after_an_approval_stays_running_until_stop() throws {
        let replay = try replayTrace("approval-then-work")

        XCTAssertEqual(replay.status(after: "Notification permission_prompt")?.state, .needsInput)
        XCTAssertEqual(replay.status(after: "Notification permission_prompt")?.interactionKind, .approval)
        let answered = try replay.index(of: "input approve")
        let stop = try replay.index(of: "Stop")
        for step in replay.steps[(answered + 1)..<stop] {
            XCTAssertEqual(step.state, .running, step.label)
        }
        XCTAssertEqual(replay.status(after: "Stop")?.state, .idle)
        try replay.assertNoPromptStored()
    }

    func test_approved_agent_prompts_do_not_stick() throws {
        let replay = try replayTrace("approval-agent-tool")

        // Interactive Agent calls launch asynchronously: the PermissionRequest
        // has no PreToolUse (narrow matcher) and no tool_use_id, and the
        // PostToolUse lands right after the answer with the worker still alive.
        XCTAssertEqual(replay.status(after: "PermissionRequest Agent")?.state, .needsInput)
        XCTAssertEqual(replay.status(after: "PostToolUse Agent")?.state, .running)
        XCTAssertEqual(replay.status(after: "PostToolUse Agent")?.subagentCount, 1)

        // The model made a second Agent call while the first worker ran. Its
        // prompt must survive that worker's hooks and its SubagentStop.
        let second = try replay.index(of: "PermissionRequest Agent", occurrence: 2)
        let answered = try replay.index(of: "input approve-repeat-call")
        for step in replay.steps[second...answered] {
            XCTAssertEqual(step.state, .needsInput, step.label)
        }
        XCTAssertEqual(replay.status(after: "PostToolUse Agent", occurrence: 2)?.state, .running)
        XCTAssertEqual(replay.status(after: "Stop", occurrence: 2)?.state, .idle)
        try replay.assertNoPromptStored()
    }

    func test_approved_agent_prompt_resolves_without_a_spinner_title() throws {
        // Under a multiplexer Claude's title is static, so hooks alone have to
        // clear the prompt.
        let replay = try replayTrace("approval-agent-tool", includesTitles: false)

        XCTAssertEqual(replay.status(after: "PermissionRequest Agent")?.state, .needsInput)
        XCTAssertEqual(replay.status(after: "PostToolUse Agent")?.state, .running)
        XCTAssertEqual(replay.status(after: "PostToolUse Agent", occurrence: 2)?.state, .running)
        XCTAssertEqual(replay.status(after: "Stop", occurrence: 2)?.state, .idle)
        try replay.assertNoPromptStored()
    }

    func test_parent_prompt_stays_open_while_a_worker_runs_and_stops() throws {
        let replay = try replayTrace("approval-during-subagent")

        let prompt = try replay.index(of: "PermissionRequest Write")
        let answered = try replay.index(of: "input approve")
        XCTAssertEqual(replay.steps[prompt].subagentCount, 1, "the worker must be alive when the prompt opens")
        XCTAssertEqual(replay.status(after: "SubagentStop agent-1")?.subagentCount, 0)
        for step in replay.steps[prompt...answered] {
            XCTAssertEqual(step.state, .needsInput, step.label)
            XCTAssertEqual(step.interactionKind, .approval, step.label)
        }
        XCTAssertEqual(replay.status(after: "PostToolUse Write")?.state, .running)
        XCTAssertEqual(replay.status(after: "Stop")?.state, .idle)
        try replay.assertNoPromptStored()
    }

    func test_worker_prompt_survives_the_parent_ending_its_turn() throws {
        // Parent and worker prompts overlap. The parent's is answered first and
        // its turn ends, while the worker's dialog is still on screen.
        let replay = try replayTrace("approval-overlap-worker")

        let first = try replay.index(of: "PermissionRequest Write")
        let answered = try replay.index(of: "input approve-second")
        XCTAssertLessThan(first, try replay.index(of: "Stop"))
        XCTAssertLessThan(try replay.index(of: "Stop"), answered)
        for step in replay.steps[first...answered] {
            XCTAssertEqual(step.state, .needsInput, step.label)
        }
        XCTAssertEqual(replay.status(after: "PostToolUse Bash agent-1")?.state, .running)
    }

    func test_second_of_two_parallel_prompts_is_not_tracked_yet() throws {
        // Claude fires PermissionRequest for both parallel Agent calls at once
        // and shows the dialogs one at a time. There is one prompt slot and the
        // PermissionRequest carries no tool_use_id, so the first PostToolUse
        // clears the slot while the second dialog waits.
        let replay = try replayTrace("approval-overlap-agents")

        let first = try replay.index(of: "PermissionRequest Agent")
        let second = try replay.index(of: "PermissionRequest Agent", occurrence: 2)
        let firstResolved = try replay.index(of: "PostToolUse Agent")
        let secondAnswered = try replay.index(of: "input approve-second")
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, firstResolved, "both prompts are open before either resolves")
        XCTAssertLessThan(firstResolved, secondAnswered)

        XCTExpectFailure("One prompt slot: tracking this needs a queue of open prompts") {
            XCTAssertEqual(replay.steps[firstResolved].state, .needsInput)
        }
    }

    // MARK: - Replay

    private struct Step {
        let t: Double
        let label: String
        let state: PaneAgentState?
        let interactionKind: PaneAgentInteractionKind?
        let text: String?
        let subagentCount: Int
    }

    private struct Replay {
        let steps: [Step]
        let sessionStore: ClaudeHookSessionStore
        let sessionIDs: Set<String>

        func index(of label: String, occurrence: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
            let matches = steps.indices.filter { steps[$0].label == label }
            guard matches.count >= occurrence else {
                XCTFail("no occurrence \(occurrence) of \(label)", file: file, line: line)
                throw ReplayError.missingStep
            }
            return matches[occurrence - 1]
        }

        func status(after label: String, occurrence: Int = 1) -> Step? {
            guard let index = try? index(of: label, occurrence: occurrence) else { return nil }
            return steps[index]
        }

        func assertNoPromptStored(file: StaticString = #filePath, line: UInt = #line) throws {
            for sessionID in sessionIDs {
                let record = try XCTUnwrap(sessionStore.lookup(sessionID: sessionID), file: file, line: line)
                XCTAssertNil(record.structuredInteractionKind, "an answered prompt must leave the hook store", file: file, line: line)
            }
        }
    }

    private enum ReplayError: Error {
        case missingStep
    }

    private struct TraceLine: Decodable {
        let t: Double
        let title: String?
        let input: String?
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func fixture(named name: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/agent-bench/fixtures/claude-\(name)-trace.jsonl")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func replayTrace(_ name: String, includesTitles: Bool = true) throws -> Replay {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zentty-claude-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let sessionStore = ClaudeHookSessionStore(
            stateURL: directory.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        )
        let subagentStore = AgentSubagentRegistryStore(
            stateURL: directory.appendingPathComponent("agent-subagent-sessions.json", isDirectory: false),
            transcriptModificationDate: { _ in nil }
        )
        let clock = Clock()
        let start = clock.now
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            currentDateProvider: { clock.now },
            claudeHookSessionStoreProvider: { sessionStore }
        )
        let repo = directory.appendingPathComponent("repo").path
        store.knownNonRepositoryPaths.insert(repo)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklaneID)
        let environment = [
            "ZENTTY_WORKLANE_ID": worklaneID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
            "ZENTTY_WINDOW_ID": store.windowID.rawValue,
            // The session is live for as long as the test runs.
            "ZENTTY_CLAUDE_PID": String(ProcessInfo.processInfo.processIdentifier),
        ]

        var steps: [Step] = []
        var sessionIDs: Set<String> = []
        for rawLine in try fixture(named: name).split(separator: "\n") {
            let resolved = rawLine
                .replacingOccurrences(of: "$SESSION", with: directory.appendingPathComponent("session").path)
                .replacingOccurrences(of: "$SCRATCH", with: directory.appendingPathComponent("scratch").path)
                .replacingOccurrences(of: "$REPO", with: repo)
            let line = try JSONDecoder().decode(TraceLine.self, from: Data(resolved.utf8))
            clock.now = start + line.t

            let label: String
            if let title = line.title {
                guard includesTitles else { continue }
                label = "title \(title)"
                store.updateMetadata(paneID: paneID, metadata: TerminalMetadata(
                    title: title,
                    currentWorkingDirectory: repo,
                    processName: "claude",
                    gitBranch: nil
                ))
            } else if let input = line.input {
                label = "input \(input)"
            } else {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resolved.utf8)) as? [String: Any])
                let hook = try XCTUnwrap(object["hook"] as? [String: Any])
                if let sessionID = hook["session_id"] as? String {
                    sessionIDs.insert(sessionID)
                }
                label = [hook["hook_event_name"], hook["tool_name"] ?? hook["notification_type"], hook["agent_id"]]
                    .compactMap { $0 as? String }
                    .joined(separator: " ")
                let payloads = try AgentEventBridge.claudeAdapter(
                    data: JSONSerialization.data(withJSONObject: hook),
                    environment: environment,
                    sessionStore: sessionStore,
                    subagentStore: subagentStore
                )
                for payload in payloads {
                    store.applyAgentStatusPayload(payload)
                }
            }
            let status = store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus
            steps.append(Step(
                t: line.t,
                label: label,
                state: status?.state,
                interactionKind: status?.interactionKind,
                text: status?.text,
                subagentCount: status?.subagents?.entries.count ?? 0
            ))
        }
        return Replay(steps: steps, sessionStore: sessionStore, sessionIDs: sessionIDs)
    }
}
