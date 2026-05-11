import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreMetadataVolatileFastPathTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func test_codex_action_required_title_enriches_from_transcript_question() async throws {
        let enriched = expectation(description: "question enrichment applied")
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { request in
                XCTAssertEqual(request.transcriptPath, "/tmp/codex-question.jsonl")
                XCTAssertEqual(request.sessionID, "session-1")
                return CodexTranscriptQuestion(
                    text: "What is your ideal weekend breakfast?\n[Coffee + pastry] [Eggs + toast]",
                    interactionKind: .decision
                )
            }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-question.jsonl"
            )
        )

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let updatedPaneID, _) = change,
                  updatedPaneID == paneID,
                  store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text
                    == "What is your ideal weekend breakfast?\n[Coffee + pastry] [Eggs + toast]" else {
                return
            }
            enriched.fulfill()
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "[ . ] Action Required | zentty"
        )

        await fulfillment(of: [enriched], timeout: 1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "What is your ideal weekend breakfast?\n[Coffee + pastry] [Eggs + toast]"
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind, .decision)
    }

    func test_codex_transcript_question_enrichment_ignores_stale_result_after_running_resumes() async throws {
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { _ in
                CodexTranscriptQuestion(
                    text: "This stale prompt should not appear",
                    interactionKind: .decision
                )
            }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-question.jsonl"
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-question.jsonl"
            )
        )

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text)
    }

    func test_codex_plan_mode_prompt_enriches_from_existing_transcript_context() async throws {
        let enriched = expectation(description: "plan mode prompt enriched")
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { request in
                XCTAssertEqual(request.transcriptPath, "/tmp/codex-plan-question.jsonl")
                XCTAssertEqual(request.sessionID, "session-1")
                return CodexTranscriptQuestion(
                    text: "Which would you rather have right now?\n[Good coffee] [Quiet hour]",
                    interactionKind: .decision
                )
            }
        )
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-plan-question.jsonl"
            )
        )

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let updatedPaneID, _) = change,
                  updatedPaneID == paneID,
                  store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text
                    == "Which would you rather have right now?\n[Good coffee] [Quiet hour]" else {
                return
            }
            enriched.fulfill()
        }
        defer { store.unsubscribe(subscription) }

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Plan mode prompt: Random"
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.origin, .heuristic)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.sessionID, "session-1")
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.codexTranscriptContext?.path,
            "/tmp/codex-plan-question.jsonl"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.codexTranscriptContext?.sessionID,
            "session-1"
        )
        await fulfillment(of: [enriched], timeout: 1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Which would you rather have right now?\n[Good coffee] [Quiet hour]"
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.interactionKind, .decision)
    }

    func test_codex_plan_mode_prompt_retries_until_transcript_question_is_flushed() async throws {
        actor AttemptCounter {
            private var value = 0

            func next() -> Int {
                value += 1
                return value
            }
        }

        let attempts = AttemptCounter()
        let enriched = expectation(description: "delayed transcript question enriched")
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { request in
                XCTAssertEqual(request.transcriptPath, "/tmp/codex-delayed-question.jsonl")
                XCTAssertEqual(request.sessionID, "session-1")
                let attempt = await attempts.next()
                guard attempt >= 3 else {
                    return nil
                }
                return CodexTranscriptQuestion(
                    text: "Peter, which tiny upgrade would improve your day most?\n[Cleaner desk] [Short walk]",
                    interactionKind: .decision
                )
            }
        )
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-delayed-question.jsonl"
            )
        )

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let updatedPaneID, _) = change,
                  updatedPaneID == paneID,
                  store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text
                    == "Peter, which tiny upgrade would improve your day most?\n[Cleaner desk] [Short walk]" else {
                return
            }
            enriched.fulfill()
        }
        defer { store.unsubscribe(subscription) }

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        await fulfillment(of: [enriched], timeout: 1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "Peter, which tiny upgrade would improve your day most?\n[Cleaner desk] [Short walk]"
        )
    }

    func test_codex_plan_mode_prompt_enriches_from_located_transcript_when_context_is_missing() async throws {
        let home = try makeTemporaryCodexHome()
        let transcript = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
            .appendingPathComponent("rollout-matching.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"turn_context","payload":{"cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"header\\":\\"Random\\",\\"id\\":\\"upgrade\\",\\"question\\":\\"Which small upgrade would you pick today?\\",\\"options\\":[{\\"label\\":\\"Better coffee\\"},{\\"label\\":\\"Cleaner desk\\"}]}]}","call_id":"call_1"}}
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let enriched = expectation(description: "question enriched from located transcript")
        let store = WorklaneStore(
            processEnvironment: ["CODEX_HOME": home.path],
            readyStatusDebounceInterval: 0
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let subscription = store.subscribe { change in
            guard case .auxiliaryStateUpdated(_, let updatedPaneID, _) = change,
                  updatedPaneID == paneID,
                  store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text
                    == "Which small upgrade would you pick today?\n[Better coffee] [Cleaner desk]" else {
                return
            }
            enriched.fulfill()
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        await fulfillment(of: [enriched], timeout: 1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw.codexTranscriptContext?.path,
            transcript.path
        )
    }

    func test_codex_new_running_session_clears_stale_needs_input_session() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: "old-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "new-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.sessionID, "new-session")
        XCTAssertNil(status.text)
        XCTAssertEqual(status.interactionKind, .none)
    }

    func test_codex_same_session_running_hook_clears_stale_needs_input_session() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.sessionID, "session-1")
        XCTAssertNil(status.text)
        XCTAssertEqual(status.interactionKind, .none)
    }

    func test_codex_fallback_running_hook_clears_stale_needs_input_session() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                confidence: .explicit,
                sessionID: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertNil(status.text)
        XCTAssertEqual(status.interactionKind, .none)
    }

    func test_codex_new_session_without_transcript_path_does_not_reuse_previous_transcript_context() async throws {
        let staleResolverCalled = expectation(description: "stale resolver should not be called")
        staleResolverCalled.isInverted = true
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { _ in
                staleResolverCalled.fulfill()
                return CodexTranscriptQuestion(
                    text: "Question from stale transcript",
                    interactionKind: .decision
                )
            }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/old-codex-question.jsonl"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .starting,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-2",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        await fulfillment(of: [staleResolverCalled], timeout: 0.1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "[ . ] Action Required | zentty"
        )
    }

    func test_codex_new_running_session_without_transcript_path_does_not_reuse_previous_transcript_context() async throws {
        let staleResolverCalled = expectation(description: "stale resolver should not be called")
        staleResolverCalled.isInverted = true
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            codexQuestionResolver: { _ in
                staleResolverCalled.fulfill()
                return CodexTranscriptQuestion(
                    text: "Question from stale transcript",
                    interactionKind: .decision
                )
            }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/old-codex-question.jsonl"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-2",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        await fulfillment(of: [staleResolverCalled], timeout: 0.1)
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.text,
            "[ . ] Action Required | zentty"
        )
    }

    func test_volatileTitleTick_fires_volatileAgentTitleUpdated_not_auxiliaryStateUpdated() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Seed a running codex volatile title via the normal slow path.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Pure volatile tick — only the elapsed counter moves, phase+subject signature unchanged.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        let auxiliaryUpdates = received.filter { change in
            if case .auxiliaryStateUpdated = change { return true }
            return false
        }
        XCTAssertEqual(volatileUpdates.count, 1, "expected one volatileAgentTitleUpdated")
        XCTAssertEqual(auxiliaryUpdates.count, 0, "slow path should not fire for volatile-only tick")
    }

    func test_volatileTitleTick_updates_stored_metadata() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.metadata?.title,
            "Working ⠙ zentty"
        )
    }

    func test_codexTaskProgressChange_takesSlowPath_andUpdatesPresentationProgress() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty | Tasks 1/5",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty | Tasks 2/5",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        let sidebarAuxiliaryUpdates = received.filter { change in
            if case .auxiliaryStateUpdated(_, _, let impacts) = change {
                return impacts.contains(.sidebar)
            }
            return false
        }
        XCTAssertEqual(volatileUpdates.count, 0, "task-progress changes must not use the title-only fast path")
        XCTAssertGreaterThan(sidebarAuxiliaryUpdates.count, 0, "task-progress changes must invalidate sidebar UI")
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.taskProgress,
            PaneAgentTaskProgress(doneCount: 2, totalCount: 5)
        )
    }

    func test_meaningfulTitleChange_takes_slowPath() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Phase transition running → idle — not volatileTitleOnly.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(volatileUpdates.count, 0, "meaningful transition must not take the fast path")
    }

    func test_interactionRequired_declinesFastPath() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Put the agent into an approval-required state via explicit payload.
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Approval requested",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        // Seed a metadata title that would otherwise be a volatile tick.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ ! ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "[ . ] Action Required | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            0,
            "fast path must decline while the agent state requires human attention"
        )
    }

    func test_codex_approval_clears_when_running_title_resumes_without_progress_report() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let sessionID = "session-auto-approved"

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Codex",
                text: "Codex needs your approval",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Requires approval")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_running_title_clears_stale_plan_mode_prompt() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .heuristic,
                toolName: "Codex",
                text: "Plan mode prompt: Random",
                interactionKind: .approval,
                confidence: .strong,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let status = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(status.state, .running)
        XCTAssertNil(status.text)
        XCTAssertEqual(status.interactionKind, .none)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_generic_input_survives_when_running_title_resumes_without_progress_report() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let sessionID = "session-awaiting-input"

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                lifecycleEvent: .toolActivity,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitHook,
                toolName: "Codex",
                text: "Codex needs your input",
                interactionKind: .genericInput,
                confidence: .explicit,
                sessionID: sessionID,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .needsInput)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Needs input")
    }

    func test_codex_stale_idle_running_tick_declinesFastPath_and_recovers_running() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .idle,
                origin: .explicitAPI,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .idle)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        let auxiliaryUpdates = received.filter { change in
            if case .auxiliaryStateUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            0,
            "fast path must decline when Codex title says Working but stored status is stale Idle"
        )
        XCTAssertGreaterThan(auxiliaryUpdates.count, 0)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_running_tick_without_status_declinesFastPath_and_recovers_after_interruptSuppression() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.worklanes[0].auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
            .raw.codexInterruptSuppressionUntil = Date().addingTimeInterval(10)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)

        store.worklanes[0].auxiliaryStateByPaneID[paneID]?
            .raw.codexInterruptSuppressionUntil = Date().addingTimeInterval(-1)

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        let auxiliaryUpdates = received.filter { change in
            if case .auxiliaryStateUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            0,
            "fast path must decline when there is no Codex status to keep in sync"
        )
        XCTAssertGreaterThan(auxiliaryUpdates.count, 0)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_new_prompt_after_interrupt_clearsSuppression_andRecoversRunning() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "codex-session",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertTrue(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw
                .codexInterruptSuppressionIsActive() == true
        )

        store.handleTerminalEvent(paneID: paneID, event: .userSubmittedInput)
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_shell_return_after_interrupt_allows_same_pane_restart() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "codex-session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(paneID: paneID, event: .userInterrupted)
        XCTAssertTrue(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw
                .codexInterruptSuppressionIsActive() == true
        )

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )

        XCTAssertFalse(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.raw
                .codexInterruptSuppressionIsActive() == true
        )
        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.presentation.statusText, "Running")
    }

    func test_codex_shell_command_does_not_surface_running_when_hooks_are_absent() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "codex",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        var auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertEqual(auxiliaryState.shellActivityState, .commandRunning)
        XCTAssertTrue(auxiliaryState.hasCommandHistory)
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Running")

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(auxiliaryState.agentStatus?.tool, .codex)
        XCTAssertEqual(auxiliaryState.agentStatus?.state, .running)
        XCTAssertEqual(auxiliaryState.presentation.statusText, "Running")
    }

    func test_codex_shell_command_stays_neutral_when_title_returns_to_project_prompt() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "codex",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertNil(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "~/project",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Running")
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Stopped early")
    }

    func test_codex_shell_command_finished_stays_neutral_instead_of_stopped() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "codex",
                currentWorkingDirectory: "/tmp/project",
                processName: nil,
                gitBranch: "main"
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .shellState,
                state: nil,
                shellActivityState: .commandRunning,
                origin: .shell,
                toolName: "Codex",
                text: nil,
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 0, durationNanoseconds: 250_000_000)
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Stopped early")
    }

    func test_codex_command_finished_after_shell_return_clears_stale_codex_state() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "codex-session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil,
                agentTranscriptPath: "/tmp/codex-session-1.jsonl"
            )
        )
        store.worklanes[0].auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationText =
            "Plan mode prompt: Random"
        store.worklanes[0].auxiliaryStateByPaneID[paneID]?.raw.lastDesktopNotificationDate = Date()

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "zsh",
                currentWorkingDirectory: "/tmp/project",
                processName: "zsh",
                gitBranch: "main"
            )
        )
        store.handleTerminalEvent(
            paneID: paneID,
            event: .commandFinished(exitCode: 130, durationNanoseconds: 250_000_000)
        )

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertNil(auxiliaryState.agentStatus)
        XCTAssertTrue(auxiliaryState.agentReducerState.sessionsByID.isEmpty)
        XCTAssertNil(auxiliaryState.raw.codexTranscriptContext)
        XCTAssertNil(auxiliaryState.raw.lastDesktopNotificationText)
        XCTAssertNil(auxiliaryState.raw.lastDesktopNotificationDate)
        XCTAssertFalse(auxiliaryState.raw.showsReadyStatus)
        XCTAssertFalse(auxiliaryState.presentation.isReady)
        XCTAssertNotEqual(auxiliaryState.presentation.statusText, "Stopped early")
    }

    func test_hiddenWorklane_doesNotCoalesceVolatileNotifications() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let activeWorklaneID = try XCTUnwrap(store.activeWorklane?.id)

        // Open a second worklane and leave the first active.
        store.createWorklane()
        store.selectWorklane(id: activeWorklaneID)
        let hiddenWorklane = try XCTUnwrap(
            store.worklanes.first(where: { $0.id != activeWorklaneID })
        )
        let hiddenPaneID = try XCTUnwrap(hiddenWorklane.paneStripState.focusedPaneID)

        // Seed running codex state in the hidden worklane.
        store.updateMetadata(
            paneID: hiddenPaneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Fire three rapid volatile ticks on the hidden pane — different
        // spinner frames so each call is a non-noop volatile update.
        let frames = ["⠙", "⠹", "⠸"]
        for frame in frames {
            store.updateMetadata(
                paneID: hiddenPaneID,
                metadata: TerminalMetadata(
                    title: "Working \(frame) zentty",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                )
            )
        }

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            3,
            "hidden-worklane volatile ticks should stay realtime so background panes feel active"
        )

        XCTAssertEqual(
            store.worklanes.first(where: { $0.id == hiddenWorklane.id })?
                .auxiliaryStateByPaneID[hiddenPaneID]?.metadata?.title,
            "Working ⠸ zentty"
        )
    }

    func test_hiddenWorklane_claudeVolatileTicks_emitEveryNotification() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let activeWorklaneID = try XCTUnwrap(store.activeWorklane?.id)

        store.createWorklane()
        store.selectWorklane(id: activeWorklaneID)
        let hiddenWorklane = try XCTUnwrap(
            store.worklanes.first(where: { $0.id != activeWorklaneID })
        )
        let hiddenPaneID = try XCTUnwrap(hiddenWorklane.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: hiddenPaneID,
            metadata: TerminalMetadata(
                title: "Thinking ✳ Investigate pane title updates",
                currentWorkingDirectory: "/tmp/project",
                processName: "claude",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        let frames = ["●", "✶", "✦"]
        for frame in frames {
            store.updateMetadata(
                paneID: hiddenPaneID,
                metadata: TerminalMetadata(
                    title: "Thinking \(frame) Investigate pane title updates",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "claude",
                    gitBranch: "main"
                )
            )
        }

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            3,
            "supported background agent titles should emit every volatile tick"
        )
        XCTAssertEqual(
            store.worklanes.first(where: { $0.id == hiddenWorklane.id })?
                .auxiliaryStateByPaneID[hiddenPaneID]?.metadata?.title,
            "Thinking ✦ Investigate pane title updates"
        )
    }

    func test_activeWorklane_doesNotCoalesceVolatileNotifications() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        let frames = ["⠙", "⠹", "⠸"]
        for frame in frames {
            store.updateMetadata(
                paneID: paneID,
                metadata: TerminalMetadata(
                    title: "Working \(frame) zentty",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                )
            )
        }

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            3,
            "active-worklane volatile ticks must not be throttled — they drive the realtime spinner"
        )
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WorklaneStoreMetadataVolatileFastPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
