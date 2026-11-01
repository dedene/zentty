import AppKit

// MARK: - Cancellation and scheduling

/// A handle to pending work (a debounce, a search, a preview load). `cancel()` is idempotent.
@MainActor
protocol AgentHistoryCancellable: AnyObject {
    func cancel()
}

/// Runs `onCancel` on the first `cancel()` only.
@MainActor
final class AgentHistoryCancellableBlock: AgentHistoryCancellable {
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let pending = onCancel
        onCancel = nil
        pending?()
    }
}

/// Delays main-actor work. The palette's debounces go through it so tests advance time by hand.
@MainActor
protocol AgentHistoryScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AgentHistoryCancellable
}

/// Schedules on the main queue; a cancelled item never runs.
struct AgentHistoryMainQueueScheduler: AgentHistoryScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AgentHistoryCancellable {
        let item = AgentHistoryScheduledWork(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [item] in
            MainActor.assumeIsolated {
                item.fire()
            }
        }
        return item
    }
}

/// One scheduled closure: fires at most once, never after `cancel()`.
@MainActor
final class AgentHistoryScheduledWork: AgentHistoryCancellable {
    private var work: (@MainActor () -> Void)?

    init(_ work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    func fire() {
        let pending = work
        work = nil
        pending?()
    }

    func cancel() {
        work = nil
    }
}

// MARK: - Opening

/// Where the palette was opened from. The worklane context menu scopes it to that worklane's
/// repository; the others open on all projects with the focused pane's project one ⇥ away.
enum AgentHistoryEntryPoint: Equatable {
    case shortcutOrMenu
    case toolbar
    case commandPalette
    case worklaneContextMenu(WorklaneID)
}

struct AgentHistoryOpenContext: Equatable {
    var entryPoint: AgentHistoryEntryPoint
    /// The focused pane's project; nil (remote pane, no directory) disables the scope toggle.
    var currentProject: AgentHistoryProjectScope?
    var initialScope: AgentHistoryScope
    var hostWindowID: WindowID
}

// MARK: - Service seams

/// Search over the index, on main. Implementations hop to the engine's queue for anything that
/// reads SQLite and deliver exactly one completion per call (§3.14), unless cancelled first.
@MainActor
protocol AgentHistorySearchServicing: AnyObject {
    func recentSessions(scope: AgentHistoryScope, limit: Int) -> [AgentHistorySessionSummary]
    /// Indexed rows for live sessions ("Running now"); keys without a row are left out.
    func sessions(for keys: [AgentHistorySessionKey]) -> [AgentHistorySessionSummary]
    func indexedSessionCount(scope: AgentHistoryScope) -> Int
    func tokenizer() -> AgentHistoryTokenizer
    /// The metadata tier; synchronous, runs on every keystroke.
    func metadataHits(for query: HistoryQuery, context: HistorySearchContext, limit: Int) -> HistoryMetadataResponse
    func searchContent(
        _ query: HistoryQuery,
        context: HistorySearchContext,
        excluding sessionIDs: Set<Int64>,
        completion: @escaping @MainActor (Result<HistoryContentResponse, Error>) -> Void
    ) -> AgentHistoryCancellable
    func loadPreview(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryPreview, Error>) -> Void
    ) -> AgentHistoryCancellable
    func loadTranscript(
        _ sessionID: Int64,
        query: HistoryQuery,
        completion: @escaping @MainActor (Result<HistoryTranscript, Error>) -> Void
    ) -> AgentHistoryCancellable
}

/// Live sessions and launching. The launcher records opens and toasts launch outcomes (A-20);
/// the palette only reacts to the returned outcome.
@MainActor
protocol AgentHistoryLaunchServicing: AnyObject {
    func liveSnapshot() -> LiveAgentSessionSnapshot
    func observeLiveSessions(_ handler: @escaping @MainActor () -> Void) -> AgentHistoryCancellable
    func resumePlan(for source: AgentHistoryResumeSource) -> AgentHistoryResumeAvailability
    /// `folderChoice` nil is a plain ↩ / ⌘↩; non-nil answers a `.needsFolderChoice` outcome.
    func launch(
        _ source: AgentHistoryResumeSource,
        intent: AgentHistoryLaunchIntent,
        folderChoice: AgentHistoryFolderChoice?
    ) -> AgentHistoryLaunchOutcome
}

/// Everything the palette talks to. Built once per window by the services adapter (UI10); tests
/// inject fakes, a uniquely named pasteboard and temp paths.
@MainActor
struct AgentHistoryPaletteServices {
    let control: any AgentHistoryControlling
    let search: any AgentHistorySearchServicing
    let launch: any AgentHistoryLaunchServicing
    let excludedFolders: () -> [String]
    let setExcludedFolders: ([String]) -> Void
    let claudeRetention: () -> ClaudeRetentionStatus
    let raiseClaudeRetention: () throws -> ClaudeRetentionWriteOutcome
    let pasteboard: NSPasteboard
    let revealInFinder: (URL) -> Void
    /// Runs on a utility queue (the "folder gone" checks).
    let fileExists: @Sendable (String) -> Bool
    let now: () -> Date
}
