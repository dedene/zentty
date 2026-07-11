import Foundation

/// Per-tool status reconciliation seam. A resolver owns the title / interrupt /
/// suppression policy for one agent tool and reconciles it against a pane's
/// `PaneAuxiliaryState`, returning outcome flags that the store honors by
/// performing the store-level side effects (ready-status reveal/clear,
/// cancelling pending enrichment tasks, scheduling sweeps).
///
/// The resolver mutates only `PaneAuxiliaryState`; it never touches the
/// store's async side-tables or the ready-status scheduler directly. Time is
/// threaded in explicitly at every entry point so the same reconciliation runs
/// deterministically under a fixed clock in tests.
///
/// Only `CodexToolStatusResolver` conforms today; Claude/Grok/Kimi/Vibe follow
/// once the shape is proven.
@MainActor
protocol PaneToolStatusResolving {
    var tool: AgentTool { get }
}

/// Result of reconciling a Codex terminal-title transition against pane state.
struct TitleReconcileOutcome: Equatable {
    /// The reconciliation mutated the pane's agent status.
    var didChangeStatus = false
    /// The store should clear any pending/visible "Agent ready" status.
    var clearReadyStatus = false
    /// The store should request the "Agent ready" reveal.
    var requestReadyReveal = false
    /// The transition was a user interrupt (Esc), not a natural completion, so
    /// the store should roll back the running→idle ready promotion after
    /// recompute.
    var suppressReadyAfterRecompute = false
}

/// Result of applying a user interrupt to pane state.
struct InterruptOutcome: Equatable {
    var didClear = false
    var suppressReadyAfterRecompute = false
}

/// Result of clearing stale Codex state after the shell returns to a prompt.
struct ShellReturnOutcome: Equatable {
    var didClear = false
    /// The store should cancel any in-flight transcript-enrichment tasks for
    /// this pane, matching the inline cancel the store used to perform.
    var cancelPendingQuestionTasks = false
}
