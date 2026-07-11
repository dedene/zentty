import XCTest
@testable import Zentty

/// Pins the write-back contract between `WorklaneStore` and
/// `CodexToolStatusResolver`: the store delegators
/// (`promoteCodexSessionIfTitleIndicatesRunning`,
/// `surfaceReadyCodexSessionIfTitleIndicatesIdle`) write the resolver's
/// `PaneAuxiliaryState` back to the worklane UNCONDITIONALLY after every
/// call. That's only safe because the resolver methods mutate a local
/// `working` copy and only commit it (`aux = working`) at real transition
/// points — every early "skip" return leaves the caller's `aux` untouched.
///
/// These tests drive `WorklaneStore.updateMetadata` through public API into
/// two of those skip branches and assert the pane's `agentReducerState` is
/// byte-identical before/after — i.e. any reducer mutation the resolver made
/// on its local `working` copy before the skip return was discarded, not
/// written back. If a future edit hoists `aux = working` above one of these
/// skip returns, these tests must go red.
@MainActor
final class WorklaneStoreCodexWriteBackTests: XCTestCase {
    // MARK: - surfaceReadyFromIdleTitle: reducer-gated skip

    /// Seeds two independent Codex reducer sessions: an explicit-hook
    /// `running` session (the one `markExplicitCodexSessionIdleFromReadyTitle`
    /// will find and flip to `.idle` on its local `working` copy) and a
    /// separate `.inferred`-origin `running` session that outranks it in
    /// `reducedStatus()` priority. Once the explicit session is marked idle,
    /// `reducedStatus()` picks the inferred session instead — whose `source`
    /// is `.inferred`, not `.explicit` — so the resolver's own
    /// `reducedStatus.source == .explicit` guard fails and it returns without
    /// committing (`codex.title.idle firstBranch reducer-gated`). The
    /// explicit session must therefore still show `.running` afterward: the
    /// reducer-side idle flip on `working` was discarded.
    func test_surfaceReadyFromIdleTitle_reducerGatedSkip_discardsWorkingCopyMutation() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)
        let worklaneID = try XCTUnwrap(store.activeWorklane?.id)

        // Explicit-hook running session: sole candidate for
        // markExplicitCodexSessionIdleFromReadyTitle.
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
                sessionID: "session-explicit",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        // Separate, lower-confidence inferred running session. Excluded from
        // the idle-flip candidate filter (origin != explicitHook/explicitAPI)
        // but still `running`, so it outranks the flipped session once the
        // explicit one goes idle.
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .running,
                origin: .inferred,
                toolName: "Codex",
                text: nil,
                sessionID: "session-inferred",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        // Tie-break sanity: the explicit session should still be "current"
        // going into the title update (higher confidence wins the tie).
        let statusBefore = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(statusBefore.state, .running)
        XCTAssertEqual(statusBefore.sessionID, "session-explicit")

        let reducerBefore = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentReducerState)
        XCTAssertEqual(reducerBefore.sessionsByID.count, 2)
        XCTAssertEqual(reducerBefore.sessionsByID["session-explicit"]?.state, .running)

        // Idle-phase title tick: enters surfaceReadyFromIdleTitle's
        // reducer-gated branch.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready codex",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let reducerAfter = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentReducerState)
        XCTAssertEqual(
            reducerAfter,
            reducerBefore,
            "resolver's local idle-flip on the explicit session must be discarded on the reducer-gated skip"
        )
        XCTAssertEqual(
            reducerAfter.sessionsByID["session-explicit"]?.state,
            .running,
            "explicit session must NOT have been committed to idle"
        )
        XCTAssertEqual(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state, .running)
    }

    // MARK: - promoteTitleRunning: explicitHookIdle skip

    /// Seeds an explicit-hook Codex session that just went `.idle` (fresh
    /// `updatedAt`, `hasObservedRunning`). A `running`-phase title tick
    /// arriving within `titleIdleSuppressionWindow` of that idle transition
    /// must not force the session back to `.running` — the explicit hook is
    /// authoritative and the title may lag by a tick or two
    /// (`codex.title.running skip=explicitHookIdle`). Assert both the status
    /// and the reducer session stay `.idle`.
    func test_promoteTitleRunning_explicitHookIdleSkip_discardsWorkingCopyMutation() throws {
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
                sessionID: "session-explicit",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: worklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .idle,
                origin: .explicitHook,
                toolName: "Codex",
                text: nil,
                confidence: .explicit,
                sessionID: "session-explicit",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        let statusBefore = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus)
        XCTAssertEqual(statusBefore.state, .idle)
        XCTAssertEqual(statusBefore.origin, .explicitHook)
        XCTAssertTrue(statusBefore.hasObservedRunning)

        // Force the reducer side empty (as if the pane had never gone
        // through the reducer-driven path) so the resolver's own
        // `seededReducerState(from:)` call has to rebuild a session on its
        // local `working` copy from `aux.agentStatus`. That reseed is a real
        // mutation, distinct from the untouched `aux` — exactly the kind of
        // work a buggy early `aux = working` commit would leak.
        store.worklanes[0].auxiliaryStateByPaneID[paneID]?.agentReducerState = PaneAgentReducerState()
        let reducerBefore = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentReducerState)
        XCTAssertTrue(reducerBefore.sessionsByID.isEmpty)

        // First metadata for this pane (no previousMetadata), so
        // previousMetadataCanBeStaleCodexRunningTail(nil) is true, and this
        // fires immediately after the idle transition above — well within
        // titleIdleSuppressionWindow.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let reducerAfter = try XCTUnwrap(store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentReducerState)
        XCTAssertEqual(
            reducerAfter,
            reducerBefore,
            "resolver's local running-promotion must be discarded on the explicitHookIdle skip"
        )
        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.agentStatus?.state,
            .idle,
            "explicit-hook idle status must survive a same-tick running title"
        )
    }
}
