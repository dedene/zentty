import Foundation

/// Codex-specific title / interrupt / suppression reconciliation, extracted
/// from `WorklaneStore`'s metadata and agent-status extensions. Stateless: all
/// mutable per-pane state stays on `PaneRawState`; the resolver only reads and
/// writes the `PaneAuxiliaryState` handed to it and returns outcome flags the
/// store honors.
///
/// `now` is injected for parity with the store's clock, but every entry point
/// also threads an explicit `now` so reconciliation stays deterministic under a
/// fixed clock in tests.
///
/// Split by MARK section across `CodexToolStatusResolver+*.swift` (moves keep
/// each file under the repo's ~500 LOC guideline):
/// - `+Title.swift`: the volatile-title fast-path gate, blocked-title ready
///   clearing, needs-input/running title promotion, the running-status
///   factory, and running-promotion diagnostics.
/// - `+Idle.swift`: ready-title → needs-input recovery and idle-title ready
///   surfacing.
/// - `+ShellReturn.swift`: stale-state clearing after a shell prompt returns.
/// - `+Predicates.swift`: static status/title predicates shared across the
///   running- and idle-title paths (hence `internal`, not `private`).
/// - `+Interrupt.swift`: user-input/progress promotion, the interrupt /
///   suppression payload policy, and transient-state / transcript-context
///   clearing.
@MainActor
struct CodexToolStatusResolver: PaneToolStatusResolving {
    let tool: AgentTool = .codex
    let now: @MainActor () -> Date

    // Suppress stale title ticks briefly after a ready-title-forced idle transition.
    static let titleIdleSuppressionWindow: TimeInterval = 1
    static let readyNotificationRecoveryWindow: TimeInterval = 10
    static let interruptSuppressionWindow: TimeInterval = PaneAgentReducerState.stopGraceWindow + 1
    static let inputSubmitStabilizationWindow: TimeInterval = 0.35

    init(now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Suppression windows

    func clearExpiredTitleIdleSuppression(_ aux: inout PaneAuxiliaryState, now: Date) {
        guard let deadline = aux.raw.codexTitleIdleSuppressionUntil, now >= deadline else {
            return
        }
        aux.raw.codexTitleIdleSuppressionUntil = nil
    }

    func clearExpiredInterruptSuppression(_ aux: inout PaneAuxiliaryState, now: Date) {
        guard let deadline = aux.raw.codexInterruptSuppressionUntil, now >= deadline else {
            return
        }
        aux.raw.codexInterruptSuppressionUntil = nil
    }

    func titleIdleSuppressionIsActive(_ raw: PaneRawState, now: Date) -> Bool {
        guard let deadline = raw.codexTitleIdleSuppressionUntil else {
            return false
        }
        return now < deadline
    }
}
