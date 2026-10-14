import XCTest
@testable import Zentty

/// Muse Code shows a braille spinner in front of its terminal title for as
/// long as it is busy, and only drops it once the turn is truly over.
/// Captured from Muse Code 1.4.7 (`muse-wonder-1.0`):
///
///   "zentty" → "⠋ zentty" → "⠙ zentty" … → "zentty"
///
/// Its hooks disagree with that in two ways. A trivial first turn ("hello!")
/// fires `UserPromptSubmit` but never `Stop`. And after a normal turn's root
/// `Stop`, the post-turn `goal-reminder` / `verify-reminder` threads keep the
/// TUI on "Double checking" for up to ~10 s. The title is what the user sees.
@MainActor
final class MuseTitleStatusTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 100)

    func test_turn_without_a_stop_hook_ends_when_the_spinner_stops() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))
        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠋ zentty"))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠙ zentty"))
        assertWorking(store, paneID: paneID)

        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))

        assertAgentReady(store, paneID: paneID)
    }

    func test_stop_hook_while_muse_is_still_double_checking_keeps_the_pane_running() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠋ zentty"))
        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .idle))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠙ zentty"))

        assertWorking(store, paneID: paneID)

        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))

        assertAgentReady(store, paneID: paneID)
    }

    func test_stop_hook_after_the_spinner_stopped_still_shows_agent_ready() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠋ zentty"))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))
        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .idle))

        assertAgentReady(store, paneID: paneID)
    }

    func test_static_title_leaves_the_turn_to_the_hooks() throws {
        // Under a multiplexer the title may never animate; the plain title
        // then says nothing about the turn.
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))
        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty", cwd: "/tmp/project/src"))
        assertWorking(store, paneID: paneID)

        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .idle))
        assertAgentReady(store, paneID: paneID)
    }

    func test_spinner_stopping_does_not_clear_an_open_prompt() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.applyAgentStatusPayload(musePayload(store, paneID: paneID, state: .running))
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "⠋ zentty"))
        store.applyAgentStatusPayload(
            musePayload(store, paneID: paneID, state: .needsInput, interactionKind: .approval)
        )
        store.updateMetadata(paneID: paneID, metadata: museMetadata(title: "zentty"))

        let auxiliaryState = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID])
        XCTAssertEqual(auxiliaryState.agentStatus?.state, .needsInput)
        XCTAssertEqual(auxiliaryState.presentation.runtimePhase, .needsInput)
    }

    func test_spinner_title_parsing() {
        XCTAssertTrue(MuseTitleActivity.isBusy("⠋ zentty"))
        XCTAssertTrue(MuseTitleActivity.isBusy("⠏ muse-multi_turn"))
        XCTAssertFalse(MuseTitleActivity.isBusy("zentty"))
        XCTAssertFalse(MuseTitleActivity.isBusy("⠋"))
        XCTAssertFalse(MuseTitleActivity.isBusy("⠋zentty"))
        XCTAssertFalse(MuseTitleActivity.isBusy(nil))
    }

    // MARK: - Helpers

    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore(
            readyStatusDebounceInterval: 0,
            currentDateProvider: { [unowned self] in now }
        )
        store.knownNonRepositoryPaths.insert("/tmp/project")
        store.knownNonRepositoryPaths.insert("/tmp/project/src")
        return store
    }

    private func assertWorking(
        _ store: WorklaneStore,
        paneID: PaneID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let auxiliaryState = store.activeWorklane?.auxiliaryStateByPaneID[paneID]
        XCTAssertEqual(auxiliaryState?.agentStatus?.state, .running, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.runtimePhase, .running, file: file, line: line)
        XCTAssertNotEqual(auxiliaryState?.presentation.statusText, "Agent ready", file: file, line: line)
    }

    private func assertAgentReady(
        _ store: WorklaneStore,
        paneID: PaneID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let auxiliaryState = store.activeWorklane?.auxiliaryStateByPaneID[paneID]
        XCTAssertEqual(auxiliaryState?.agentStatus?.state, .idle, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.runtimePhase, .idle, file: file, line: line)
        XCTAssertEqual(auxiliaryState?.presentation.statusText, "Agent ready", file: file, line: line)
    }

    private func museMetadata(title: String, cwd: String = "/tmp/project") -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: cwd,
            processName: "muse-bin-1.4.7",
            gitBranch: "main"
        )
    }

    private func musePayload(
        _ store: WorklaneStore,
        paneID: PaneID,
        state: PaneAgentState,
        interactionKind: PaneAgentInteractionKind? = nil
    ) -> AgentStatusPayload {
        AgentStatusPayload(
            worklaneID: store.activeWorklaneID,
            paneID: paneID,
            signalKind: .lifecycle,
            state: state,
            origin: .explicitHook,
            toolName: AgentTool.muse.displayName,
            text: state == .needsInput ? "Muse Code wants to run bash" : nil,
            interactionKind: interactionKind,
            confidence: .explicit,
            sessionID: "muse-session",
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }
}
