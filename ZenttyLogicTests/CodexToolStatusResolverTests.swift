import XCTest
@testable import Zentty

@MainActor
final class CodexToolStatusResolverTests: XCTestCase {
    // A fixed instant near the present: the reducer's idle/unresolved-stop
    // visibility windows are evaluated against the real wall clock inside
    // reducedStatus(), so the fixture clock must sit close to "now".
    private let clock = Date()

    private func makeResolver() -> CodexToolStatusResolver {
        CodexToolStatusResolver(now: { [clock] in clock })
    }

    private func codexStatus(
        state: PaneAgentState,
        origin: AgentSignalOrigin = .explicitHook,
        source: PaneAgentStatusSource = .explicit,
        interactionKind: PaneAgentInteractionKind? = nil,
        hasObservedRunning: Bool = true,
        text: String? = nil,
        updatedAt: Date? = nil
    ) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .codex,
            state: state,
            text: text,
            artifactLink: nil,
            updatedAt: updatedAt ?? clock,
            source: source,
            origin: origin,
            interactionKind: interactionKind,
            confidence: nil,
            hasObservedRunning: hasObservedRunning,
            sessionID: "codex-session"
        )
    }

    /// Builds a pane aux with the given codex status and a matching reducer
    /// session seeded from it (so the reducer-driven resolver paths have a
    /// session to operate on).
    private func makeAux(
        status: PaneAgentStatus?,
        metadata: TerminalMetadata? = nil
    ) -> PaneAuxiliaryState {
        var aux = PaneAuxiliaryState()
        aux.raw.metadata = metadata
        aux.agentStatus = status
        if status != nil {
            aux.agentReducerState = AgentStatusReconciliation.seededReducerState(
                PaneAgentReducerState(),
                from: status
            )
        }
        return aux
    }

    private func metadata(title: String?, processName: String?) -> TerminalMetadata {
        TerminalMetadata(
            title: title,
            currentWorkingDirectory: "/tmp/project",
            processName: processName,
            gitBranch: nil
        )
    }

    // MARK: - Suppression windows

    func test_titleIdleSuppression_activeWithinWindow_thenExpires() {
        let resolver = makeResolver()
        var aux = PaneAuxiliaryState()
        aux.raw.codexTitleIdleSuppressionUntil = clock.addingTimeInterval(1)

        XCTAssertTrue(resolver.titleIdleSuppressionIsActive(aux.raw, now: clock))
        XCTAssertFalse(resolver.titleIdleSuppressionIsActive(aux.raw, now: clock.addingTimeInterval(2)))
    }

    func test_clearExpiredTitleIdleSuppression_onlyClearsAtOrAfterDeadline() {
        let resolver = makeResolver()
        var aux = PaneAuxiliaryState()
        aux.raw.codexTitleIdleSuppressionUntil = clock.addingTimeInterval(1)

        resolver.clearExpiredTitleIdleSuppression(&aux, now: clock)
        XCTAssertNotNil(aux.raw.codexTitleIdleSuppressionUntil, "not yet expired")

        resolver.clearExpiredTitleIdleSuppression(&aux, now: clock.addingTimeInterval(1))
        XCTAssertNil(aux.raw.codexTitleIdleSuppressionUntil, "cleared at deadline")
    }

    func test_clearExpiredInterruptSuppression_onlyClearsAtOrAfterDeadline() {
        let resolver = makeResolver()
        var aux = PaneAuxiliaryState()
        aux.raw.codexInterruptSuppressionUntil = clock.addingTimeInterval(3)

        resolver.clearExpiredInterruptSuppression(&aux, now: clock)
        XCTAssertNotNil(aux.raw.codexInterruptSuppressionUntil)

        resolver.clearExpiredInterruptSuppression(&aux, now: clock.addingTimeInterval(3))
        XCTAssertNil(aux.raw.codexInterruptSuppressionUntil)
    }

    // MARK: - Title → running gated by suppression

    func test_promoteRunningFromCurrentTitle_promotesStartingSession() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .starting),
            metadata: metadata(title: "Working ⠋ codex", processName: "codex")
        )

        let didPromote = resolver.promoteRunningFromCurrentTitle(&aux, paneID: PaneID("p"), now: clock)

        XCTAssertTrue(didPromote)
        XCTAssertEqual(aux.agentStatus?.state, .running)
    }

    func test_promoteRunningFromCurrentTitle_gatedByInterruptSuppression() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .starting),
            metadata: metadata(title: "Working ⠋ codex", processName: "codex")
        )
        // Real-clock window: the running-title guard checks suppression against
        // wall-clock time, so pin the deadline into the real future.
        aux.raw.codexInterruptSuppressionUntil = Date().addingTimeInterval(60)

        let didPromote = resolver.promoteRunningFromCurrentTitle(&aux, paneID: PaneID("p"), now: clock)

        XCTAssertFalse(didPromote, "suppression window blocks title-driven running promotion")
        XCTAssertEqual(aux.agentStatus?.state, .starting)
    }

    // MARK: - Ready-title → idle stamping

    func test_surfaceReadyFromIdleTitle_stampsTitleIdleSuppressionAndInterrupts() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .running, origin: .explicitHook, hasObservedRunning: true),
            metadata: metadata(title: "Ready codex", processName: "codex")
        )

        let outcome = resolver.surfaceReadyFromIdleTitle(
            &aux,
            paneID: PaneID("p"),
            previousMetadata: metadata(title: "Working ⠋ codex", processName: "codex"),
            metadata: metadata(title: "Ready codex", processName: "codex"),
            readyPromotionAllowed: true,
            now: clock
        )

        XCTAssertTrue(outcome.suppressReadyAfterRecompute, "idle title after running reads as interrupt candidate")
        XCTAssertEqual(aux.agentStatus?.state, .idle)
        XCTAssertEqual(
            aux.raw.codexTitleIdleSuppressionUntil,
            clock.addingTimeInterval(CodexToolStatusResolver.titleIdleSuppressionWindow)
        )
    }

    // MARK: - Ready-title recovers needs-input in recovery window

    func test_recoverNeedsInputFromReadyTitle_withinWindow_recoversApproval() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .running, source: .explicit, hasObservedRunning: true),
            metadata: metadata(title: "Ready codex", processName: "codex")
        )
        aux.raw.lastDesktopNotificationText = "Codex needs your approval"
        aux.raw.lastDesktopNotificationDate = clock

        let outcome = resolver.recoverNeedsInputFromReadyTitle(
            &aux,
            paneID: PaneID("p"),
            previousMetadata: metadata(title: "Working ⠋ codex", processName: "codex"),
            metadata: metadata(title: "Ready codex", processName: "codex"),
            now: clock.addingTimeInterval(3)
        )

        XCTAssertTrue(outcome.didChangeStatus)
        XCTAssertTrue(outcome.clearReadyStatus)
        XCTAssertEqual(aux.agentStatus?.state, .needsInput)
        XCTAssertEqual(aux.agentStatus?.interactionKind, .approval)
    }

    func test_recoverNeedsInputFromReadyTitle_pastWindow_isNoop() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .running, source: .explicit, hasObservedRunning: true),
            metadata: metadata(title: "Ready codex", processName: "codex")
        )
        aux.raw.lastDesktopNotificationText = "Codex needs your approval"
        aux.raw.lastDesktopNotificationDate = clock

        let outcome = resolver.recoverNeedsInputFromReadyTitle(
            &aux,
            paneID: PaneID("p"),
            previousMetadata: metadata(title: "Working ⠋ codex", processName: "codex"),
            metadata: metadata(title: "Ready codex", processName: "codex"),
            now: clock.addingTimeInterval(CodexToolStatusResolver.readyNotificationRecoveryWindow + 1)
        )

        XCTAssertFalse(outcome.didChangeStatus)
        XCTAssertEqual(aux.agentStatus?.state, .running)
    }

    // MARK: - Shell-return stale-state clearing

    func test_clearStaleStateAfterShellReturn_shellPrompt_clearsAndCancelsTasks() {
        let resolver = makeResolver()
        var aux = makeAux(
            status: codexStatus(state: .needsInput, interactionKind: .approval),
            metadata: nil
        )

        let outcome = resolver.clearStaleStateAfterShellReturn(
            &aux,
            paneID: PaneID("p"),
            metadata: metadata(title: nil, processName: "zsh"),
            allowsNonCodexPromptFallback: false
        )

        XCTAssertTrue(outcome.didClear)
        XCTAssertTrue(outcome.cancelPendingQuestionTasks)
        XCTAssertNil(aux.agentStatus)
        XCTAssertTrue(aux.agentReducerState.sessionsByID.isEmpty)
    }

    func test_clearStaleStateAfterShellReturn_noStaleCodex_isNoop() {
        let resolver = makeResolver()
        var aux = makeAux(status: codexStatus(state: .idle, hasObservedRunning: true), metadata: nil)
        aux.agentReducerState = PaneAgentReducerState()

        let outcome = resolver.clearStaleStateAfterShellReturn(
            &aux,
            paneID: PaneID("p"),
            metadata: metadata(title: nil, processName: "zsh"),
            allowsNonCodexPromptFallback: false
        )

        XCTAssertFalse(outcome.didClear)
        XCTAssertFalse(outcome.cancelPendingQuestionTasks)
        XCTAssertNotNil(aux.agentStatus)
    }

    // MARK: - Weak-terminal-fallback clearing

    func test_clearStaleStateAfterShellReturn_weakTerminalFallback_gatedByFlag() {
        let resolver = makeResolver()
        // Inferred (weak) codex running status; a non-codex, non-shell prompt.
        func makeWeakAux() -> PaneAuxiliaryState {
            makeAux(
                status: codexStatus(state: .running, origin: .inferred, source: .inferred),
                metadata: nil
            )
        }

        var gated = makeWeakAux()
        let gatedOutcome = resolver.clearStaleStateAfterShellReturn(
            &gated,
            paneID: PaneID("p"),
            metadata: metadata(title: nil, processName: "python3"),
            allowsNonCodexPromptFallback: false
        )
        XCTAssertFalse(gatedOutcome.didClear, "weak fallback stays put when non-codex-prompt fallback is disabled")
        XCTAssertNotNil(gated.agentStatus)

        var allowed = makeWeakAux()
        let allowedOutcome = resolver.clearStaleStateAfterShellReturn(
            &allowed,
            paneID: PaneID("p"),
            metadata: metadata(title: nil, processName: "python3"),
            allowsNonCodexPromptFallback: true
        )
        XCTAssertTrue(allowedOutcome.didClear, "weak inferred codex fallback clears on a non-codex prompt")
        XCTAssertNil(allowed.agentStatus)
    }
}
