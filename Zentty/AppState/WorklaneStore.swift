import Darwin
import Foundation
import os

private let worklaneReadyLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneReady")
private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")

@MainActor
protocol WorklaneStoreScheduledHandle: AnyObject {
    func cancel()
}

@MainActor
private final class TaskWorklaneStoreScheduledHandle: WorklaneStoreScheduledHandle {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

struct WorklaneID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct WorklaneState: Equatable, Sendable {
    let id: WorklaneID
    /// Optional user-visible name. Invariant: either nil or a non-empty
    /// trimmed string — never empty, never padded. Enforced at init and at
    /// every write boundary (`setTitle`, recipe import, template import).
    var title: String?
    var paneStripState: PaneStripState
    var nextPaneNumber: Int
    var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState]
    var color: WorklaneColor?
    var bookmarkOriginID: UUID?

    init(
        id: WorklaneID,
        title: String?,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:],
        color: WorklaneColor? = nil,
        bookmarkOriginID: UUID? = nil
    ) {
        self.id = id
        self.title = WorklaneContextFormatter.trimmed(title)
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.auxiliaryStateByPaneID = auxiliaryStateByPaneID
        self.color = color
        self.bookmarkOriginID = bookmarkOriginID
    }
}

struct WorklanePaneContext: Equatable, Sendable {
    let pane: PaneState
    let auxiliaryState: PaneAuxiliaryState?

    var paneID: PaneID { pane.id }
    var metadata: TerminalMetadata? { auxiliaryState?.metadata }
}

struct WorklaneOpenWithContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let paneID: PaneID
    let workingDirectory: String
    let scope: PaneShellContextScope
}

struct WorklaneServerContext: Equatable, Sendable {
    let worklaneID: WorklaneID
    let focusedPaneID: PaneID?
    /// Full ranking including hidden entries (for the Hidden submenu and IPC).
    /// `servers` and `primaryServer` are derived from this, so the three views can
    /// never disagree.
    let ranked: [RankedServer]

    /// Highest-ranked visible server, or nil when every detected server is hidden.
    var primaryServer: DetectedServer? {
        ranked.first { $0.tier == .primary }?.server
    }

    /// Visible (non-hidden) servers in ranked order. Hidden servers are excluded so
    /// existing consumers (menu, command palette, sidebar, chrome) drop ignored
    /// ports automatically; use `ranked` to reach hidden entries.
    var servers: [DetectedServer] {
        ranked.filter { $0.tier != .hidden }.map(\.server)
    }
}

struct PaneSplitOutResult: Equatable, Sendable {
    let destinationWorkspaceState: WindowWorkspaceState
    let movedPaneID: PaneID
    let sourceWindowShouldClose: Bool
}

enum GridFocus: String, Equatable, Sendable {
    case source
    case first
    case last
}

struct GridApplicationResult: Equatable, Sendable {
    let worklaneID: WorklaneID
    let sourcePaneID: PaneID
    let createdPaneIDs: [PaneID]
}

enum GridApplicationError: LocalizedError {
    case invalidDimensions
    case tooManyCells
    case sourcePaneNotFound

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            "Grid dimensions must be positive."
        case .tooManyCells:
            "Grid dimensions may create at most 36 panes."
        case .sourcePaneNotFound:
            "Source pane is not in the active worklane."
        }
    }
}

enum GridLaunchCommandError: LocalizedError {
    case emptyCommand
    case unsupportedToken(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "Missing grid launch command."
        case .unsupportedToken:
            "Grid launch command tokens may not contain newlines."
        }
    }
}

enum GridLaunchCommandBuilder {
    private static let bareTokenScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

    static func command(from tokens: [String]) throws -> String {
        let normalized = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.contains(where: { !$0.isEmpty }) else {
            throw GridLaunchCommandError.emptyCommand
        }
        for token in tokens where token.contains("\n") || token.contains("\r") {
            throw GridLaunchCommandError.unsupportedToken(token)
        }
        return tokens.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        if canUseBareToken(value) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func canUseBareToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { bareTokenScalars.contains($0) }
    }
}

struct PaneBorderContextDisplayModel: Equatable, Sendable {
    let text: String
    /// True when this pane is the recorded leader of a Claude Code agent
    /// teams anchor. Renders a star glyph at the leading edge of the inset.
    var isAgentTeamLeader: Bool = false
    /// True when this pane is a recorded child column member of a Claude
    /// Code agent teams anchor (excluding the leader). Renders a subordinate
    /// glyph at the leading edge of the inset.
    var isAgentTeamMember: Bool = false
}

struct WorklaneAuxiliaryInvalidation: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let sidebar = WorklaneAuxiliaryInvalidation(rawValue: 1 << 0)
    static let header = WorklaneAuxiliaryInvalidation(rawValue: 1 << 1)
    static let canvas = WorklaneAuxiliaryInvalidation(rawValue: 1 << 2)
    static let attention = WorklaneAuxiliaryInvalidation(rawValue: 1 << 3)
    static let openWith = WorklaneAuxiliaryInvalidation(rawValue: 1 << 4)
    static let reviewRefresh = WorklaneAuxiliaryInvalidation(rawValue: 1 << 5)
    static let surfaceActivities = WorklaneAuxiliaryInvalidation(rawValue: 1 << 6)
    static let serverDetection = WorklaneAuxiliaryInvalidation(rawValue: 1 << 7)

    static let presentationChrome: WorklaneAuxiliaryInvalidation = [.sidebar, .header, .attention]
}

extension WorklaneState {
    /// LEGACY-IMPORT-ONLY. Early Zentty force-titled every worklane
    /// ("MAIN", "WS 1", …); this sanitizer strips that junk when importing
    /// unversioned workspace recipes. Do NOT use it on runtime display
    /// paths — titles are optional now and display verbatim.
    static func meaningfulTitle(from rawTitle: String?) -> String? {
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        if title.caseInsensitiveCompare("MAIN") == .orderedSame {
            return nil
        }

        if title.hasPrefix("WS "), let value = Int(title.dropFirst(3)), value >= 1 {
            return nil
        }

        return title
    }

    var focusedPaneContext: WorklanePaneContext? {
        paneContext(for: paneStripState.focusedPaneID)
    }

    var paneContextsPrioritizingFocus: [WorklanePaneContext] {
        let panes = paneStripState.panes
        guard
            let focusedPaneID = paneStripState.focusedPaneID,
            let focusedPaneIndex = panes.firstIndex(where: { $0.id == focusedPaneID })
        else {
            return panes.map { WorklanePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
        }

        var orderedPanes = panes
        if focusedPaneIndex != 0 {
            let focusedPane = orderedPanes.remove(at: focusedPaneIndex)
            orderedPanes.insert(focusedPane, at: 0)
        }

        return orderedPanes.map { WorklanePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
    }

    func paneContext(for paneID: PaneID?) -> WorklanePaneContext? {
        guard
            let paneID,
            let pane = paneStripState.panes.first(where: { $0.id == paneID })
        else {
            return nil
        }

        return WorklanePaneContext(pane: pane, auxiliaryState: auxiliaryStateByPaneID[paneID])
    }

    var paneBorderContextDisplayByPaneID: [PaneID: PaneBorderContextDisplayModel] {
        let panesByID = Dictionary(uniqueKeysWithValues: paneStripState.panes.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: auxiliaryStateByPaneID.compactMap { paneID, auxiliaryState in
            if let pane = panesByID[paneID],
               let borderText = PaneDisplayIdentityResolver.borderLabelText(
                   pane: pane,
                   presentation: auxiliaryState.presentation
               ) {
                return (paneID, PaneBorderContextDisplayModel(text: borderText))
            }
            guard let borderText = auxiliaryState.shellContext?.borderContextDisplayText else {
                return nil
            }
            return (paneID, PaneBorderContextDisplayModel(text: borderText))
        })
    }

    /// Variant of `paneBorderContextDisplayByPaneID` that flags the recorded
    /// Claude Code agent-teams leader pane and any column members. Forces an
    /// entry for the leader even when the pane has no shell-context text —
    /// the leader glyph needs a host view to draw into. Members only get
    /// flagged when they already have a context entry (their cwd label).
    func paneBorderContextDisplayByPaneID(
        leaderPaneID: PaneID?,
        memberPaneIDs: Set<PaneID> = []
    ) -> [PaneID: PaneBorderContextDisplayModel] {
        var result = paneBorderContextDisplayByPaneID
        let livePaneIDs = Set(paneStripState.panes.map(\.id))

        if let leaderPaneID, livePaneIDs.contains(leaderPaneID) {
            if let existing = result[leaderPaneID] {
                result[leaderPaneID] = PaneBorderContextDisplayModel(
                    text: existing.text,
                    isAgentTeamLeader: true
                )
            } else {
                result[leaderPaneID] = PaneBorderContextDisplayModel(
                    text: "",
                    isAgentTeamLeader: true
                )
            }
        }

        for memberID in memberPaneIDs where memberID != leaderPaneID && livePaneIDs.contains(memberID) {
            if let existing = result[memberID] {
                result[memberID] = PaneBorderContextDisplayModel(
                    text: existing.text,
                    isAgentTeamMember: true
                )
            }
        }

        return result
    }
}

enum WorklaneChange: Equatable, Sendable {
    case paneStructure(WorklaneID)
    case focusChanged(WorklaneID)
    case layoutResized(WorklaneID, animation: WorklaneLayoutResizeAnimation)
    case auxiliaryStateUpdated(WorklaneID, PaneID, WorklaneAuxiliaryInvalidation)
    /// Emitted by WorklaneStore.updateMetadata's volatile-title fast path when
    /// a supported agent pane's terminal title changes in a way that the
    /// classifier recognizes as `.volatileTitleOnly`. Consumers should call the surgical
    /// sidebar/chrome label setters (not a full render) to update the UI
    /// without re-running summary builders or auxiliary invalidation.
    case volatileAgentTitleUpdated(worklaneID: WorklaneID, paneID: PaneID)
    /// Emitted when a Claude Code agent-teams anchor is added, removed, or
    /// its column membership changes. Title-strip views redraw to add/remove
    /// the leader star.
    case teamAnchorsChanged(WorklaneID)
    case activeWorklaneChanged
    case worklaneListChanged
    case historyChanged
}

enum WorklaneLayoutResizeAnimation: Equatable, Sendable {
    case immediate
    case splitCurve
}

struct WorklaneChangeSubscription {
    fileprivate let id: UUID
    fileprivate static let legacyID = UUID()
}

struct WorklaneRuntimeIdentity: Sendable {
    var nextOpaqueValue: @Sendable () -> String

    static let live = WorklaneRuntimeIdentity {
        UUID().uuidString.lowercased()
    }

    func makeWorklaneID() -> WorklaneID {
        WorklaneID("wl_\(nextOpaqueValue())")
    }

    func makePaneID() -> PaneID {
        PaneID("pn_\(nextOpaqueValue())")
    }

    func makeColumnID() -> PaneColumnID {
        PaneColumnID("col_\(nextOpaqueValue())")
    }
}

@MainActor
final class WorklaneStore {
    typealias ReadyStatusScheduler = @MainActor (
        _ interval: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any WorklaneStoreScheduledHandle
    typealias CodexQuestionResolver = @Sendable (CodexTranscriptQuestionRequest) async -> CodexTranscriptQuestion?

    struct PaneReference: Hashable, Sendable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private struct PaneLaunchContext {
        let path: String
        let scope: PaneShellContextScope?
    }

    var worklanes: [WorklaneState]
    let gitContextResolver: any PaneGitContextResolving
    let terminalDiagnostics: TerminalDiagnostics
    private(set) var layoutContext: PaneLayoutContext
    private(set) var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedPaneReference: PaneReference?
    private var lastFocusedLocalPaneReference: PaneReference?
    private var lastFocusedLocalWorkingDirectory: String?
    var cachedGitContextByPath: [String: PaneGitContext] = [:]
    var knownNonRepositoryPaths: Set<String> = []
    var nonRepositoryRetryDeadlineByPath: [String: Date] = [:]
    var pendingGitContextPaths: Set<String> = []
    var waitingPaneReferencesByPath: [String: Set<PaneReference>] = [:]
    private var pendingReadyStatusTasks: [PaneReference: any WorklaneStoreScheduledHandle] = [:]
    private var pendingAgentStatusSweepTasks: [PaneReference: any WorklaneStoreScheduledHandle] = [:]
    var pendingCodexQuestionTasks: [PaneReference: Task<Void, Never>] = [:]
    var pendingCodexQuestionRequests: [PaneReference: CodexTranscriptQuestionRequest] = [:]
    var cachedCodexTranscriptQuestions: [CodexTranscriptQuestionCacheKey: CodexTranscriptQuestion] = [:]
    let processEnvironment: [String: String]
    private let readyStatusDebounceInterval: TimeInterval
    let nonRepositoryRetryInterval: TimeInterval
    let currentDateProvider: @MainActor () -> Date
    private let scheduleReadyStatusTask: ReadyStatusScheduler
    let codexQuestionResolver: CodexQuestionResolver
    let codexResolver: CodexToolStatusResolver
    private let newWorklanePlacementProvider: @MainActor () -> NewWorklanePlacement
    private let agentTeamsEnabledProvider: @MainActor () -> Bool
    private let serverDetectionProvider: @MainActor () -> AppConfig.ServerDetection
    /// In-memory mirror of `TmuxCompatStore.anchors` for this app session.
    /// Refreshed via `refreshTeamAnchors()` after any handler that mutates
    /// the on-disk store (split-window, kill-pane, kill-window, leader-close
    /// cascade). Read by `paneBorderContextDisplayByPaneID` to flag the
    /// leader pane.
    private(set) var teamAnchorByWorklaneID: [WorklaneID: WorklaneAnchor] = [:]
    let windowID: WindowID
    let runtimeIdentity: WorklaneRuntimeIdentity
    let serverRegistry: ServerRegistry
    private var rememberedPrimaryServerOriginByWorklaneID: [WorklaneID: String] = [:]
    let focusHistoryController = PaneFocusHistoryController()
    private var isNavigatingHistory = false

    /// Per-window LIFO stack of recently closed panes for ⌘⇧T restore.
    /// Populated in `closePane(id:source:)` for `.userCommand` closures only.
    var closedPaneStack = ClosedPaneStack()

    /// Set by the view layer to provide pane scrollback right before close.
    /// Returns nil if the runtime is gone or the read fails.
    var scrollbackProvider: ((PaneID) -> String?)?

    var activeWorklaneID: WorklaneID

    private var subscribers: [(id: UUID, handler: (WorklaneChange) -> Void)] = []

    /// Nesting depth of active `batchUpdate` calls. `> 0` means changes passed
    /// to `notify(_:)` are collected instead of delivered; they flush when the
    /// outermost batch exits. Using a depth counter (not a `Bool`) makes nested
    /// `batchUpdate` calls reentrant — only the outermost exit flushes.
    private var batchDepth = 0

    /// Changes captured by `notify(_:)` while a batch is open, awaiting a
    /// coalesced flush when the outermost `batchUpdate` returns.
    private var pendingBatchedChanges: [WorklaneChange] = []

    /// Nesting depth of active `withNotificationsSuppressed` calls. `> 0` means
    /// changes passed to `notify(_:)` are dropped outright — neither delivered
    /// nor queued for replay. See `withNotificationsSuppressed` for why this is
    /// distinct from `batchDepth`.
    private var suppressionDepth = 0

    @discardableResult
    func subscribe(_ handler: @escaping (WorklaneChange) -> Void) -> WorklaneChangeSubscription {
        let id = UUID()
        subscribers.append((id: id, handler: handler))
        return WorklaneChangeSubscription(id: id)
    }

    func unsubscribe(_ subscription: WorklaneChangeSubscription) {
        subscribers.removeAll { $0.id == subscription.id }
    }

    /// Deprecated compatibility shim — use subscribe() for new code.
    var onChange: ((WorklaneChange) -> Void)? {
        get { nil }
        set {
            subscribers.removeAll { $0.id == WorklaneChangeSubscription.legacyID }
            if let handler = newValue {
                subscribers.append((id: WorklaneChangeSubscription.legacyID, handler: handler))
            }
        }
    }

    #if DEBUG
    var subscriberCountForTesting: Int {
        subscribers.count
    }
    #endif

    init(
        windowID: WindowID = WindowID("wd_\(UUID().uuidString.lowercased())"),
        worklanes: [WorklaneState] = [],
        layoutContext: PaneLayoutContext = .fallback,
        activeWorklaneID: WorklaneID? = nil,
        gitContextResolver: any PaneGitContextResolving = WorklaneGitContextResolver(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        readyStatusDebounceInterval: TimeInterval = 0.25,
        nonRepositoryRetryInterval: TimeInterval = 5,
        currentDateProvider: @escaping @MainActor () -> Date = Date.init,
        readyStatusScheduler: @escaping ReadyStatusScheduler = WorklaneStore.defaultReadyStatusScheduler,
        codexQuestionResolver: @escaping CodexQuestionResolver = { request in
            CodexTranscriptQuestionExtractor.question(fromTranscriptPath: request.transcriptPath)
        },
        runtimeIdentity: WorklaneRuntimeIdentity = .live,
        serverRegistry: ServerRegistry = ServerRegistry(),
        terminalDiagnostics: TerminalDiagnostics = .shared,
        newWorklanePlacementProvider: @escaping @MainActor () -> NewWorklanePlacement = { .afterCurrent },
        agentTeamsEnabledProvider: @escaping @MainActor () -> Bool = { false },
        serverDetectionProvider: @escaping @MainActor () -> AppConfig.ServerDetection = { .default }
    ) {
        self.windowID = windowID
        self.gitContextResolver = gitContextResolver
        self.terminalDiagnostics = terminalDiagnostics
        self.layoutContext = layoutContext
        self.processEnvironment = processEnvironment
        self.readyStatusDebounceInterval = readyStatusDebounceInterval
        self.nonRepositoryRetryInterval = nonRepositoryRetryInterval
        self.currentDateProvider = currentDateProvider
        self.scheduleReadyStatusTask = readyStatusScheduler
        self.codexQuestionResolver = codexQuestionResolver
        self.codexResolver = CodexToolStatusResolver(now: currentDateProvider)
        self.newWorklanePlacementProvider = newWorklanePlacementProvider
        self.agentTeamsEnabledProvider = agentTeamsEnabledProvider
        self.serverDetectionProvider = serverDetectionProvider
        self.runtimeIdentity = runtimeIdentity
        self.serverRegistry = serverRegistry
        let initialWorklanes = worklanes.isEmpty
            ? WorklaneStore.defaultWorklanes(
                windowID: windowID,
                layoutContext: layoutContext,
                processEnvironment: processEnvironment,
                runtimeIdentity: runtimeIdentity,
                agentTeamsEnabled: agentTeamsEnabledProvider()
            )
            : worklanes
        let seededAnchors = WorklaneStore.pruneStaleTeamAnchors(in: initialWorklanes)
        let requestedActiveWorklaneID = activeWorklaneID ?? initialWorklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        let resolvedActiveWorklaneID = initialWorklanes.contains(where: { $0.id == requestedActiveWorklaneID })
            ? requestedActiveWorklaneID
            : initialWorklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        self.worklanes = initialWorklanes
        self.activeWorklaneID = resolvedActiveWorklaneID
        self.teamAnchorByWorklaneID = seededAnchors
        normalizeAllPanePresentationState()
        refreshLastFocusedLocalWorkingDirectory()
        refreshAllPaneGitContexts()

        focusHistoryController.onChange = { [weak self] in
            self?.notify(.historyChanged)
        }
    }

    var activeWorklane: WorklaneState? {
        get {
            worklanes.first { $0.id == activeWorklaneID }
        }
        set {
            guard let newValue, let index = worklanes.firstIndex(where: { $0.id == newValue.id }) else {
                return
            }

            worklanes[index] = newValue
        }
    }

    var activeServerContext: WorklaneServerContext {
        serverContext(for: activeWorklaneID)
    }

    func serverContext(for worklaneID: WorklaneID) -> WorklaneServerContext {
        let worklane = worklanes.first { $0.id == worklaneID }
        let focusedPaneID = worklane?.paneStripState.focusedPaneID
        let merged = serverRegistry.servers(in: worklaneID)

        let relevanceContext = ServerRelevanceContext(
            focusedPaneID: focusedPaneID,
            runningPaneIDs: runningPaneIDs(in: worklane),
            ignoredPortRules: ServerPortRule.normalize(serverDetectionProvider().ignoredPortRules),
            sessionSelectedOrigin: rememberedPrimaryServerOriginByWorklaneID[worklaneID],
            now: currentDateProvider()
        )
        let ranked = ServerRelevance.rank(merged, context: relevanceContext)

        return WorklaneServerContext(
            worklaneID: worklaneID,
            focusedPaneID: focusedPaneID,
            ranked: ranked
        )
    }

    /// Panes in `worklane` whose shell is currently executing a command — the
    /// "active work" signal `ServerRelevance` boosts.
    private func runningPaneIDs(in worklane: WorklaneState?) -> Set<PaneID> {
        guard let worklane else {
            return []
        }
        let livePaneIDs = Set(worklane.paneStripState.panes.map(\.id))
        return Set(
            worklane.auxiliaryStateByPaneID
                .filter { paneID, auxiliary in
                    livePaneIDs.contains(paneID) && auxiliary.shellActivityState == .commandRunning
                }
                .keys
        )
    }

    func register(server: DetectedServer) {
        serverRegistry.upsert(server)
        notifyServerDetectionChanged(worklaneID: server.worklaneID, paneID: server.paneID)
    }

    func rememberPrimaryServer(_ server: DetectedServer) {
        guard rememberedPrimaryServerOriginByWorklaneID[server.worklaneID] != server.origin else {
            return
        }

        rememberedPrimaryServerOriginByWorklaneID[server.worklaneID] = server.origin
        notifyServerDetectionChanged(worklaneID: server.worklaneID, paneID: server.paneID)
    }

    func clearServers(worklaneID: WorklaneID, paneID: PaneID) {
        serverRegistry.clear(worklaneID: worklaneID, paneID: paneID)
        notifyServerDetectionChanged(worklaneID: worklaneID, paneID: paneID)
    }

    func clearServers(worklaneID: WorklaneID) {
        serverRegistry.clear(worklaneID: worklaneID)
        notifyServerDetectionChanged(worklaneID: worklaneID, paneID: nil)
    }

    func clearServers(worklaneID: WorklaneID, paneID: PaneID, source: DetectedServerSource) {
        serverRegistry.clearSource(source, worklaneID: worklaneID, paneID: paneID)
        notifyServerDetectionChanged(worklaneID: worklaneID, paneID: paneID)
    }

    func clearPassiveServers(worklaneID: WorklaneID) {
        serverRegistry.clearSource(.scanner, worklaneID: worklaneID, paneID: nil)
        serverRegistry.clearSource(.docker, worklaneID: worklaneID, paneID: nil)
        notifyServerDetectionChanged(worklaneID: worklaneID, paneID: nil)
    }

    func replacePassiveServers(
        worklaneID: WorklaneID,
        source: DetectedServerSource,
        servers: [DetectedServer]
    ) {
        serverRegistry.replaceSource(source, worklaneID: worklaneID, servers: servers)
        notifyServerDetectionChanged(worklaneID: worklaneID, paneID: nil)
    }

    enum PaneCloseReason {
        case runningProcess
        case sessionHistory
    }

    func paneCloseConfirmationReason(_ paneID: PaneID) -> PaneCloseReason? {
        for worklane in worklanes {
            guard let aux = worklane.auxiliaryStateByPaneID[paneID] else { continue }
            return quitConfirmationReason(for: aux)
        }
        return nil
    }

    func worklaneCloseConfirmationReason(_ worklaneID: WorklaneID) -> PaneCloseReason? {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return nil
        }

        var hasSessionHistory = false
        for pane in worklane.paneStripState.panes {
            guard let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id],
                  let reason = quitConfirmationReason(for: auxiliaryState)
            else {
                continue
            }

            switch reason {
            case .runningProcess:
                return .runningProcess
            case .sessionHistory:
                hasSessionHistory = true
            }
        }

        return hasSessionHistory ? .sessionHistory : nil
    }

    var anyPaneRequiresQuitConfirmation: Bool {
        worklanes.contains { worklane in
            worklane.auxiliaryStateByPaneID.values.contains {
                quitConfirmationReason(for: $0) != nil
            }
        }
    }

    var hasRunningAgentPane: Bool {
        worklanes.contains { worklane in
            let livePaneIDs = Set(worklane.paneStripState.panes.map(\.id))
            return worklane.auxiliaryStateByPaneID.contains { paneID, auxiliaryState in
                guard livePaneIDs.contains(paneID) else {
                    return false
                }

                let statusRunning = auxiliaryState.agentStatus?.state == .running
                let presentationRunning = auxiliaryState.presentation.recognizedTool != nil
                    && auxiliaryState.presentation.runtimePhase == .running
                return statusRunning || presentationRunning
            }
        }
    }

    private func quitConfirmationReason(for auxiliaryState: PaneAuxiliaryState) -> PaneCloseReason? {
        if auxiliaryState.shellActivityState == .commandRunning
            || auxiliaryState.terminalProgress?.state.indicatesActivity == true {
            return .runningProcess
        }

        if auxiliaryState.hasCommandHistory {
            return .sessionHistory
        }

        return nil
    }

    private func notifyServerDetectionChanged(worklaneID: WorklaneID, paneID: PaneID?) {
        guard let notificationPaneID = paneID
            ?? worklanes.first(where: { $0.id == worklaneID })?.paneStripState.focusedPaneID
            ?? worklanes.first(where: { $0.id == worklaneID })?.paneStripState.panes.first?.id
        else {
            notify(.worklaneListChanged)
            return
        }

        notify(.auxiliaryStateUpdated(worklaneID, notificationPaneID, .serverDetection))
    }

    // MARK: - Focus History Navigation

    private var currentPaneReference: PaneReference? {
        guard let worklane = activeWorklane,
              let paneID = worklane.paneStripState.focusedPaneID else { return nil }
        return PaneReference(worklaneID: worklane.id, paneID: paneID)
    }

    var currentPaneReferenceForCommandPalette: PaneReference? {
        currentPaneReference
    }

    private var allLivePaneReferences: Set<PaneReference> {
        Set(worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map {
                PaneReference(worklaneID: worklane.id, paneID: $0.id)
            }
        })
    }

    var recentPaneReferencesForCommandPalette: [PaneReference] {
        focusHistoryController.history.recentReferences(allPaneIDs: allLivePaneReferences)
    }

    func restoredRerunnableCommand(for paneID: PaneID) -> String? {
        guard let auxiliaryState = liveAuxiliaryState(for: paneID),
              auxiliaryState.shellActivityState == .promptIdle,
              auxiliaryState.terminalProgress?.state.indicatesActivity != true,
              agentStatusAllowsRestoredCommand(auxiliaryState.agentStatus),
              let command = Self.trimmedRestoredCommand(auxiliaryState.raw.restoredRerunnableCommand)
        else {
            return nil
        }

        return command
    }

    func consumeRestoredRerunnableCommand(for paneID: PaneID) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        guard worklanes[worklaneIndex]
            .auxiliaryStateByPaneID[paneID]?.raw.restoredRerunnableCommand != nil
        else {
            return
        }

        worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]?.raw.restoredRerunnableCommand = nil
        notify(.auxiliaryStateUpdated(worklanes[worklaneIndex].id, paneID, .sidebar))
    }

    private var paneReferencesInSidebarOrder: [PaneReference] {
        worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map { pane in
                PaneReference(worklaneID: worklane.id, paneID: pane.id)
            }
        }
    }

    func navigateBack() {
        guard let current = currentPaneReference else { return }
        guard let target = focusHistoryController.navigateBack(
            current: current,
            allPaneIDs: allLivePaneReferences
        ) else { return }

        isNavigatingHistory = true
        defer { isNavigatingHistory = false }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    func navigateForward() {
        guard let current = currentPaneReference else { return }
        guard let target = focusHistoryController.navigateForward(
            current: current,
            allPaneIDs: allLivePaneReferences
        ) else { return }

        isNavigatingHistory = true
        defer { isNavigatingHistory = false }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    private func recordFocusTransition(from previous: PaneReference?) {
        guard !isNavigatingHistory, let previous else { return }
        focusHistoryController.recordFocusChange(from: previous)
    }

    private func focusPaneBySidebarOrder(offset: Int) {
        let paneReferences = paneReferencesInSidebarOrder
        guard paneReferences.count > 1,
              let current = currentPaneReference,
              let currentIndex = paneReferences.firstIndex(of: current) else {
            return
        }

        let nextIndex = (currentIndex + offset + paneReferences.count) % paneReferences.count
        let target = paneReferences[nextIndex]
        guard target != current else {
            return
        }

        if target.worklaneID == activeWorklaneID {
            focusPane(id: target.paneID)
        } else {
            selectWorklaneAndFocusPane(worklaneID: target.worklaneID, paneID: target.paneID)
        }
    }

    var focusedOpenWithContext: WorklaneOpenWithContext? {
        guard let worklane = activeWorklane else {
            return nil
        }

        return focusedOpenWithContext(in: worklane)
    }

    var state: PaneStripState {
        activeWorklane?.paneStripState ?? .pocDefault
    }

    func updateLayoutContext(
        _ layoutContext: PaneLayoutContext,
        notifyLayoutResize: Bool = true
    ) {
        let previousLayoutContext = self.layoutContext
        self.layoutContext = layoutContext
        var didUpdateWorklaneState = false
        let readableWidthScaleFactor = Self.readableWidthScaleFactor(
            from: previousLayoutContext,
            to: layoutContext
        )

        for index in worklanes.indices {
            if worklanes[index].paneStripState.updateLayoutSizing(layoutContext.sizing) {
                didUpdateWorklaneState = true
            }

            if worklanes[index].paneStripState.updateSingleColumnWidth(layoutContext.singlePaneWidth) {
                didUpdateWorklaneState = true
                continue
            }

            if let readableWidthScaleFactor,
               worklanes[index].paneStripState.scalePaneWidths(by: readableWidthScaleFactor) {
                didUpdateWorklaneState = true
            }
        }

        if didUpdateWorklaneState, notifyLayoutResize {
            notifyLayoutResized(animation: .immediate)
        }
    }

    func updatePaneViewportHeight(_ height: CGFloat) {
        paneViewportHeight = max(1, height)
    }

    func send(_ command: PaneCommand) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousPaneRef = currentPaneReference
        let changeType: WorklaneChange

        switch command {
        case .duplicateFocusedPane:
            guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
                return
            }

            let targetColumnIndex = (
                worklane.paneStripState.columns.firstIndex { $0.id == worklane.paneStripState.focusedColumnID } ?? 0
            ) + 1

            duplicatePaneAsColumn(
                paneID: focusedPaneID,
                toColumnIndex: targetColumnIndex,
                singleColumnWidth: layoutContext.singlePaneWidth
            )

            let newPaneRef = currentPaneReference
            if previousPaneRef != newPaneRef {
                recordFocusTransition(from: previousPaneRef)
            }
            return
        case .split, .splitHorizontally:
            insertNewPaneRight(into: &worklane, behavior: layoutContext.rightPaneInsertionBehavior)
            changeType = .paneStructure(activeWorklaneID)
        case .splitRightVisibly:
            insertNewPaneRight(into: &worklane, behavior: .visibleSplit)
            changeType = .paneStructure(activeWorklaneID)
        case .addPaneRightWithoutResizing:
            insertNewPaneRight(into: &worklane, behavior: .worklaneAdd)
            changeType = .paneStructure(activeWorklaneID)
        case .splitAfterFocusedPane:
            insertNewPaneHorizontally(into: &worklane, placement: .afterFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .splitVertically:
            insertNewPaneVertically(into: &worklane, placement: .afterFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .splitVerticallyBefore:
            insertNewPaneVertically(into: &worklane, placement: .beforeFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .splitBeforeFocusedPane:
            insertNewPaneHorizontally(into: &worklane, placement: .beforeFocused)
            changeType = .paneStructure(activeWorklaneID)
        case .closeFocusedPane:
            _ = closeFocusedPane()
            return
        case .focusPreviousPaneBySidebarOrder:
            focusPaneBySidebarOrder(offset: -1)
            return
        case .focusNextPaneBySidebarOrder:
            focusPaneBySidebarOrder(offset: 1)
            return
        case .focusLeft:
            worklane.paneStripState.moveFocusLeft()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusRight:
            worklane.paneStripState.moveFocusRight()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusUp:
            if worklane.paneStripState.isFocusedPaneAtTopOfColumn {
                selectPreviousWorklane()
                return
            }
            worklane.paneStripState.moveFocusUp()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusDown:
            if worklane.paneStripState.isFocusedPaneAtBottomOfColumn {
                selectNextWorklane()
                return
            }
            worklane.paneStripState.moveFocusDown()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusFirst, .focusFirstColumn:
            worklane.paneStripState.moveFocusToFirstColumn()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .focusLast, .focusLastColumn:
            worklane.paneStripState.moveFocusToLastColumn()
            clearReadyStatusForFocusedPane(in: &worklane)
            changeType = .focusChanged(activeWorklaneID)
        case .moveLeft:
            if worklane.paneStripState.movePaneLeft() {
                changeType = .paneStructure(activeWorklaneID)
            } else {
                return
            }
        case .moveRight:
            if worklane.paneStripState.movePaneRight() {
                changeType = .paneStructure(activeWorklaneID)
            } else {
                return
            }
        case .moveUp:
            if worklane.paneStripState.movePaneUp() {
                changeType = .paneStructure(activeWorklaneID)
            } else {
                return
            }
        case .moveDown:
            if worklane.paneStripState.movePaneDown() {
                changeType = .paneStructure(activeWorklaneID)
            } else {
                return
            }
        case .resizeLeft,
            .resizeRight,
            .resizeUp,
            .resizeDown,
            .arrangeHorizontally,
            .arrangeVertically,
            .arrangeGoldenRatio,
            .resetLayout,
            .restoreClosedPane:
            activeWorklane = worklane
            return
        }

        activeWorklane = worklane

        let newPaneRef = currentPaneReference
        if previousPaneRef != newPaneRef {
            recordFocusTransition(from: previousPaneRef)
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(changeType)
    }

    @discardableResult
    func splitWithLayout(
        placement: PanePlacement,
        isHorizontal: Bool,
        layout: SplitLayoutAction,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize],
        targetPaneID: PaneID? = nil,
        preserveFocusPaneID: PaneID? = nil,
        sessionRequest: TerminalSessionRequest? = nil
    ) -> PaneID? {
        guard var worklane = activeWorklane else {
            return nil
        }

        let previousPaneRef = currentPaneReference
        if let targetPaneID {
            worklane.paneStripState.focusPane(id: targetPaneID)
        }

        if isHorizontal {
            insertNewPaneHorizontally(into: &worklane, placement: placement, sessionRequest: sessionRequest)
        } else {
            insertNewPaneVertically(into: &worklane, placement: placement, sessionRequest: sessionRequest)
        }
        let newPaneID = worklane.paneStripState.focusedPaneID

        switch layout {
        case .none:
            break
        case .equal:
            if isHorizontal {
                _ = worklane.paneStripState.arrangeHorizontally(
                    .halfWidth,
                    availableWidth: availableWidth,
                    leadingVisibleInset: leadingVisibleInset
                )
            } else {
                _ = worklane.paneStripState.equalizeFocusedColumnPaneHeights()
            }
        case .golden:
            if isHorizontal {
                _ = worklane.paneStripState.arrangeGoldenWidth(
                    focusWide: true,
                    availableWidth: availableWidth,
                    leadingVisibleInset: leadingVisibleInset
                )
            } else {
                _ = worklane.paneStripState.arrangeGoldenHeight(
                    focusTall: true,
                    availableSize: availableSize
                )
            }
        case .ratio(let fraction):
            if isHorizontal {
                _ = worklane.paneStripState.resizeFocusedColumnToFraction(
                    fraction,
                    availableWidth: availableWidth,
                    leadingVisibleInset: leadingVisibleInset,
                    minimumSizeByPaneID: minimumSizeByPaneID
                )
            } else {
                _ = worklane.paneStripState.resizeFocusedPaneHeightToFraction(fraction)
            }
        }

        if let preserveFocusPaneID {
            worklane.paneStripState.focusPane(id: preserveFocusPaneID)
        }

        activeWorklane = worklane

        let newPaneRef = currentPaneReference
        if previousPaneRef != newPaneRef {
            recordFocusTransition(from: previousPaneRef)
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
        return newPaneID
    }

    @discardableResult
    func applyGrid(
        sourcePaneID: PaneID,
        rows: Int,
        columns: Int,
        command: String?,
        includeSource: Bool,
        focus: GridFocus
    ) throws -> GridApplicationResult {
        guard rows > 0, columns > 0 else {
            throw GridApplicationError.invalidDimensions
        }
        let cellCount = rows * columns
        guard cellCount <= 36 else {
            throw GridApplicationError.tooManyCells
        }
        guard let startingWorklane = activeWorklane,
              startingWorklane.paneStripState.panes.contains(where: { $0.id == sourcePaneID }) else {
            throw GridApplicationError.sourcePaneNotFound
        }

        if startingWorklane.paneStripState.panes.count > 1 {
            transferPaneToNewWorklane(
                paneID: sourcePaneID,
                singleColumnWidth: layoutContext.singlePaneWidth
            )
        }

        guard var worklane = activeWorklane,
              let sourcePane = worklane.paneStripState.panes.first(where: { $0.id == sourcePaneID }) else {
            throw GridApplicationError.sourcePaneNotFound
        }

        let readableWidth = layoutContext.sizing.readableWidth(
            for: layoutContext.viewportWidth,
            leadingVisibleInset: layoutContext.leadingVisibleInset
        )
        let totalSpacing = layoutContext.sizing.interPaneSpacing * CGFloat(max(0, columns - 1))
        let columnWidth = max(1, (readableWidth - totalSpacing) / CGFloat(columns))
        let launchRequest = command.map {
            TerminalSessionRequest(command: $0)
        }

        var panes: [PaneState] = {
            var pane = sourcePane
            pane.width = columnWidth
            if includeSource {
                applySessionRequestOverride(launchRequest, to: &pane)
            }
            return [pane]
        }()
        var createdPaneIDs: [PaneID] = []
        panes.reserveCapacity(cellCount)

        while panes.count < cellCount {
            var pane = makePane(in: &worklane, existingPaneCount: panes.count)
            pane.width = columnWidth
            applySessionRequestOverride(launchRequest, to: &pane)
            createdPaneIDs.append(pane.id)
            panes.append(pane)
        }

        var rebuiltColumns: [PaneColumnState] = []
        rebuiltColumns.reserveCapacity(columns)
        var usedColumnIDs: Set<PaneColumnID> = []
        let previousColumns = worklane.paneStripState.columns
        for columnIndex in 0..<columns {
            let start = columnIndex * rows
            let end = min(start + rows, panes.count)
            let paneSlice = Array(panes[start..<end])
            guard let firstPane = paneSlice.first else {
                continue
            }
            let preferredID = columnIndex < previousColumns.count
                ? previousColumns[columnIndex].id
                : runtimeIdentity.makeColumnID()
            let columnID = uniqueGridColumnID(preferredID, usedColumnIDs: &usedColumnIDs)
            let focusedPaneID = paneSlice.contains(where: { $0.id == sourcePaneID })
                ? sourcePaneID
                : firstPane.id
            rebuiltColumns.append(
                PaneColumnState(
                    id: columnID,
                    panes: paneSlice,
                    width: columnWidth,
                    paneHeights: Array(repeating: 1, count: paneSlice.count),
                    focusedPaneID: focusedPaneID,
                    lastFocusedPaneID: focusedPaneID
                )
            )
        }

        let focusPaneID: PaneID = switch focus {
        case .source, .first:
            panes[0].id
        case .last:
            panes[panes.count - 1].id
        }
        let focusedColumnID = rebuiltColumns.first { column in
            column.panes.contains { $0.id == focusPaneID }
        }?.id ?? rebuiltColumns.first?.id

        worklane.paneStripState = PaneStripState(
            columns: rebuiltColumns,
            focusedColumnID: focusedColumnID,
            layoutSizing: layoutContext.sizing
        )
        worklane.paneStripState.focusPane(id: focusPaneID)
        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
        notify(.layoutResized(activeWorklaneID, animation: .splitCurve))

        return GridApplicationResult(
            worklaneID: activeWorklaneID,
            sourcePaneID: sourcePaneID,
            createdPaneIDs: createdPaneIDs
        )
    }

    private func uniqueGridColumnID(
        _ preferredID: PaneColumnID,
        usedColumnIDs: inout Set<PaneColumnID>
    ) -> PaneColumnID {
        if !usedColumnIDs.contains(preferredID) {
            usedColumnIDs.insert(preferredID)
            return preferredID
        }
        while true {
            let candidate = runtimeIdentity.makeColumnID()
            if !usedColumnIDs.contains(candidate) {
                usedColumnIDs.insert(candidate)
                return candidate
            }
        }
    }

    func markDividerInteraction(_ divider: PaneDivider) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState.markDividerInteraction(divider)
        activeWorklane = worklane
    }

    func resizeDivider(
        _ divider: PaneDivider,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resizeDivider(
            divider,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .immediate)
    }

    @discardableResult
    func resize(
        _ target: PaneResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> CGFloat {
        guard var worklane = activeWorklane else {
            return 0
        }

        let applied = worklane.paneStripState.resize(
            target,
            delta: delta,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        )

        guard abs(applied) > 0.001 else {
            return 0
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .immediate)
        return applied
    }

    @discardableResult
    func launchDeferredPane(id paneID: PaneID, nativeCommand: String) -> Bool {
        guard var worklane = activeWorklane else {
            return false
        }
        let trimmedCommand = nativeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return false
        }

        for columnIndex in worklane.paneStripState.columns.indices {
            guard let paneIndex = worklane.paneStripState.columns[columnIndex].panes.firstIndex(where: { $0.id == paneID }) else {
                continue
            }
            guard worklane.paneStripState.columns[columnIndex].panes[paneIndex].sessionRequest.isLaunchDeferred else {
                return false
            }

            worklane.paneStripState.columns[columnIndex].panes[paneIndex].sessionRequest.command = nil
            worklane.paneStripState.columns[columnIndex].panes[paneIndex].sessionRequest.nativeCommand = trimmedCommand
            worklane.paneStripState.columns[columnIndex].panes[paneIndex].sessionRequest.waitAfterNativeCommand = true
            worklane.paneStripState.columns[columnIndex].panes[paneIndex].sessionRequest.isLaunchDeferred = false
            activeWorklane = worklane
            notify(.paneStructure(activeWorklaneID))
            return true
        }

        return false
    }

    @discardableResult
    func setPaneTitle(id paneID: PaneID, title: String) -> Bool {
        guard var worklane = activeWorklane else {
            return false
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return false
        }

        for columnIndex in worklane.paneStripState.columns.indices {
            guard let paneIndex = worklane.paneStripState.columns[columnIndex].panes.firstIndex(where: { $0.id == paneID }) else {
                continue
            }
            worklane.paneStripState.columns[columnIndex].panes[paneIndex].title = trimmedTitle
            activeWorklane = worklane
            notify(.paneStructure(activeWorklaneID))
            return true
        }

        return false
    }

    func focusedHorizontalKeyboardResizeAction(
        for delta: CGFloat
    ) -> FocusedHorizontalKeyboardResizeAction? {
        activeWorklane?.paneStripState.focusedHorizontalKeyboardResizeAction(for: delta)
    }

    func equalizeDivider(
        _ divider: PaneDivider,
        availableSize: CGSize
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.equalizeDivider(divider, availableSize: availableSize) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    @discardableResult
    func resizeFocusedPane(
        in axis: PaneResizeAxis,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize],
        animation: WorklaneLayoutResizeAnimation = .splitCurve
    ) -> Bool {
        guard var worklane = activeWorklane else {
            return false
        }

        guard worklane.paneStripState.resizeFocusedPane(
            in: axis,
            delta: delta,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return false
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: animation)
        return true
    }

    func resizeFocusedColumnToFraction(
        _ fraction: CGFloat,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resizeFocusedColumnToFraction(
            fraction,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func resizeColumnContainingPane(
        id paneID: PaneID,
        toFraction fraction: CGFloat,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousPaneID = worklane.paneStripState.focusedPaneID
        worklane.paneStripState.focusPane(id: paneID)
        let phi: CGFloat = (1 + sqrt(5)) / 2
        let goldenNarrowFraction = 1 / (1 + phi)
        let goldenWideFraction = phi / (1 + phi)
        let didResize: Bool
        if abs(fraction - goldenWideFraction) < 0.001 {
            didResize = worklane.paneStripState.arrangeGoldenWidth(
                focusWide: true,
                availableWidth: availableWidth,
                leadingVisibleInset: leadingVisibleInset
            )
        } else if abs(fraction - goldenNarrowFraction) < 0.001 {
            didResize = worklane.paneStripState.arrangeGoldenWidth(
                focusWide: false,
                availableWidth: availableWidth,
                leadingVisibleInset: leadingVisibleInset
            )
        } else {
            didResize = worklane.paneStripState.resizeFocusedColumnToFraction(
                fraction,
                availableWidth: availableWidth,
                leadingVisibleInset: leadingVisibleInset,
                minimumSizeByPaneID: minimumSizeByPaneID
            )
        }
        guard didResize else {
            if let previousPaneID {
                worklane.paneStripState.focusPane(id: previousPaneID)
            }
            activeWorklane = worklane
            return
        }
        if let previousPaneID {
            worklane.paneStripState.focusPane(id: previousPaneID)
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    /// Read the absolute pixel width of the column containing `paneID` in
    /// `worklaneID`. Used by the agent-teams flow to snapshot the leader's
    /// column width before the team's first split, so the pre-team layout
    /// can be restored when the team dissolves.
    func columnWidthForPane(id paneID: PaneID, in worklaneID: WorklaneID) -> CGFloat? {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }),
              let columnIndex = worklane.paneStripState.columns.firstIndex(where: { column in
                  column.panes.contains(where: { $0.id == paneID })
              }) else {
            return nil
        }
        return worklane.paneStripState.columns[columnIndex].width
    }

    /// Resize the column containing `paneID` to an absolute pixel width using
    /// the non-arrangement path. This works after the team column has been
    /// removed and only the leader column remains, and it avoids the
    /// user-facing fractional resize clamp when restoring snapshotted widths.
    @discardableResult
    func resizeColumnContainingPanePreservingNeighbors(
        id paneID: PaneID,
        toWidth width: CGFloat,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> Bool {
        guard var worklane = activeWorklane else {
            return false
        }
        let previousPaneID = worklane.paneStripState.focusedPaneID
        worklane.paneStripState.focusPane(id: paneID)
        let didResize = worklane.paneStripState.resizeFocusedColumnToWidth(
            width,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        )
        if let previousPaneID {
            worklane.paneStripState.focusPane(id: previousPaneID)
        }
        guard didResize else {
            activeWorklane = worklane
            return false
        }
        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
        return true
    }

    func resizeFocusedPaneHeightToFraction(_ fraction: CGFloat) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.resizeFocusedPaneHeightToFraction(fraction) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func equalizeFocusedColumnPaneHeights() {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.equalizeFocusedColumnPaneHeights() else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func restorePaneLayout(_ paneStripState: PaneStripState) {
        guard var worklane = activeWorklane else {
            return
        }

        worklane.paneStripState = paneStripState
        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func resetActiveWorklaneLayout() {
        guard var worklane = activeWorklane else {
            return
        }

        var columns = worklane.paneStripState.columns
        guard !columns.isEmpty else {
            return
        }

        let defaultColumnWidth = layoutContext.newPaneWidth
        let firstColumnWidth = columns.count == 1
            ? layoutContext.singlePaneWidth
            : (layoutContext.firstPaneWidthAfterSingleSplit ?? defaultColumnWidth)
        for index in columns.indices {
            let width: CGFloat
            if index == 0 {
                width = firstColumnWidth
            } else if columns.count == 2, layoutContext.firstPaneWidthAfterSingleSplit != nil {
                width = firstColumnWidth
            } else {
                width = defaultColumnWidth
            }
            columns[index].width = width
            columns[index].resetPaneHeights()
        }

        worklane.paneStripState = PaneStripState(
            columns: columns,
            focusedColumnID: worklane.paneStripState.focusedColumnID,
            layoutSizing: layoutContext.sizing
        )
        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneHorizontally(
        _ arrangement: PaneHorizontalArrangement,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeHorizontally(
            arrangement,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneVertically(_ arrangement: PaneVerticalArrangement) {
        guard var worklane = activeWorklane else {
            return
        }

        let didArrange = worklane.paneStripState.arrangeVertically(arrangement)
        let didNormalizeSingleColumnWidth =
            worklane.paneStripState.updateSingleColumnWidth(layoutContext.singlePaneWidth)

        guard didArrange || didNormalizeSingleColumnWidth else {
            return
        }

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneGoldenWidth(
        focusWide: Bool,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeGoldenWidth(
            focusWide: focusWide,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    func arrangeActiveWorklaneGoldenHeight(
        focusTall: Bool,
        availableSize: CGSize
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        guard worklane.paneStripState.arrangeGoldenHeight(
            focusTall: focusTall,
            availableSize: availableSize
        ) else {
            return
        }

        activeWorklane = worklane
        notifyLayoutResized(animation: .splitCurve)
    }

    private func insertNewPaneHorizontally(
        into worklane: inout WorklaneState,
        placement: PanePlacement,
        sessionRequest: TerminalSessionRequest? = nil
    ) {
        let existingColumnCount = worklane.paneStripState.columns.count
        let sourceWidth = worklane.paneStripState.focusedColumn?.width
            ?? worklane.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &worklane, existingPaneCount: existingColumnCount)
        applySessionRequestOverride(sessionRequest, to: &insertedPane)
        insertedPane.width = sourceWidth

        if existingColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            worklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        worklane.paneStripState.insertPaneHorizontally(insertedPane, placement: placement)
    }

    private func insertNewPaneRight(
        into worklane: inout WorklaneState,
        behavior: PaneRightInsertionBehavior,
        sessionRequest: TerminalSessionRequest? = nil
    ) {
        switch behavior {
        case .visibleSplit:
            insertNewPaneRightVisibly(into: &worklane, sessionRequest: sessionRequest)
        case .worklaneAdd:
            insertNewPaneHorizontally(
                into: &worklane,
                placement: .afterFocused,
                sessionRequest: sessionRequest
            )
        }
    }

    private func insertNewPaneRightVisibly(
        into worklane: inout WorklaneState,
        sessionRequest: TerminalSessionRequest? = nil
    ) {
        let existingColumnCount = worklane.paneStripState.columns.count
        var insertedPane = makePane(in: &worklane, existingPaneCount: existingColumnCount)
        applySessionRequestOverride(sessionRequest, to: &insertedPane)
        insertedPane.width = layoutContext.visibleSplitColumnWidth

        _ = worklane.paneStripState.resizeFocusedColumnToWidth(
            layoutContext.visibleSplitColumnWidth,
            availableWidth: layoutContext.availableWidth,
            minimumSizeByPaneID: [:]
        )

        worklane.paneStripState.insertPaneHorizontally(insertedPane, placement: .afterFocused)
    }

    private func insertNewPaneVertically(
        into worklane: inout WorklaneState,
        placement: PanePlacement = .afterFocused,
        sessionRequest: TerminalSessionRequest? = nil
    ) {
        let existingPaneCount = worklane.paneStripState.panes.count
        let sourceWidth = worklane.paneStripState.focusedColumn?.width
            ?? worklane.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &worklane, existingPaneCount: existingPaneCount)
        applySessionRequestOverride(sessionRequest, to: &insertedPane)
        insertedPane.width = sourceWidth
        _ = worklane.paneStripState.insertPaneVertically(
            insertedPane,
            placement: placement,
            availableHeight: paneViewportHeight
        )
    }

    private func applySessionRequestOverride(
        _ override: TerminalSessionRequest?,
        to pane: inout PaneState
    ) {
        guard let override else {
            return
        }

        if let workingDirectory = override.workingDirectory {
            pane.sessionRequest.workingDirectory = workingDirectory
        }
        pane.sessionRequest.command = override.command
        pane.sessionRequest.nativeCommand = override.nativeCommand
        pane.sessionRequest.waitAfterNativeCommand = override.waitAfterNativeCommand
        pane.sessionRequest.isLaunchDeferred = override.isLaunchDeferred
        if !override.environmentVariables.isEmpty {
            pane.sessionRequest.environmentVariables.merge(override.environmentVariables) { _, new in new }
        }
    }

    func selectWorklane(id: WorklaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == id }) else {
            return
        }

        let previousPaneRef = currentPaneReference
        clearReadyStatusForFocusedPane(in: &worklanes[index])
        activeWorklaneID = id
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func selectNextWorklane() {
        guard worklanes.count > 1,
              let currentIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return
        }

        let nextIndex = (currentIndex + 1) % worklanes.count
        selectWorklane(id: worklanes[nextIndex].id)
    }

    func selectPreviousWorklane() {
        guard worklanes.count > 1,
              let currentIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return
        }

        let previousIndex = (currentIndex - 1 + worklanes.count) % worklanes.count
        selectWorklane(id: worklanes[previousIndex].id)
    }

    func insertionIndexForNewWorklane(anchorWorklaneID: WorklaneID? = nil) -> Int {
        switch newWorklanePlacementProvider() {
        case .top:
            return 0
        case .afterCurrent:
            let resolvedAnchorID = anchorWorklaneID ?? activeWorklaneID
            return worklanes
                .firstIndex(where: { $0.id == resolvedAnchorID })
                .map { worklanes.index(after: $0) } ?? worklanes.endIndex
        case .end:
            return worklanes.endIndex
        }
    }

    @discardableResult
    func createWorklane() -> WorklaneID {
        let previousPaneRef = currentPaneReference
        let id = runtimeIdentity.makeWorklaneID()
        let workingDirectory = resolveWorkingDirectoryForNewWorklane()
        let configInheritanceSourcePaneID = resolveConfigInheritanceSourcePaneIDForNewWorklane()

        let worklane = Self.makeDefaultWorklane(
            id: id,
            title: nil,
            windowID: windowID,
            layoutContext: layoutContext,
            workingDirectory: workingDirectory,
            surfaceContext: .tab,
            configInheritanceSourcePaneID: configInheritanceSourcePaneID,
            processEnvironment: processEnvironment,
            runtimeIdentity: runtimeIdentity,
            agentTeamsEnabled: agentTeamsEnabledProvider()
        )
        let insertionIndex = insertionIndexForNewWorklane(anchorWorklaneID: activeWorklaneID)
        worklanes.insert(worklane, at: insertionIndex)
        activeWorklaneID = id
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
        return id
    }

    func gridWindowWorkspaceState(
        inheritingFrom sourcePaneID: PaneID,
        destinationWindowID: WindowID
    ) -> WindowWorkspaceState? {
        guard let sourceWorklane = worklanes.first(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == sourcePaneID })
        }) else {
            return nil
        }

        let launchContext = resolveLaunchContext(for: sourcePaneID, in: sourceWorklane)
        let workingDirectory: String
        if let launchContext, launchContext.scope != .remote {
            workingDirectory = launchContext.path
        } else {
            workingDirectory = lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
        }

        let worklaneID = runtimeIdentity.makeWorklaneID()
        let worklane = Self.makeDefaultWorklane(
            id: worklaneID,
            title: nil,
            windowID: destinationWindowID,
            layoutContext: layoutContext,
            workingDirectory: workingDirectory,
            surfaceContext: .window,
            processEnvironment: processEnvironment,
            runtimeIdentity: runtimeIdentity,
            agentTeamsEnabled: agentTeamsEnabledProvider()
        )
        return WindowWorkspaceState(worklanes: [worklane], activeWorklaneID: worklaneID)
    }

    @discardableResult
    func applyTemplate(_ template: WorkspaceTemplate) -> WorkspaceTemplateImporter.Result {
        let previousPaneRef = currentPaneReference
        let id = runtimeIdentity.makeWorklaneID()
        let fallback: String? = template.kind == .preset ? resolveWorkingDirectoryForNewWorklane() : nil
        let result = WorkspaceTemplateImporter.makeWorklane(
            from: template,
            worklaneID: id,
            fallbackWorkingDirectory: fallback,
            windowID: windowID,
            layoutContext: layoutContext,
            processEnvironment: processEnvironment,
            runtimeIdentity: runtimeIdentity
        )
        worklanes.append(result.worklane)
        activeWorklaneID = id
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
        return result
    }

    var focusedWorklaneSnapshot: WorklaneState? {
        activeWorklane
    }

    func snapshot(of worklaneID: WorklaneID) -> WorklaneState? {
        worklanes.first { $0.id == worklaneID }
    }

    func setBookmarkOrigin(_ originID: UUID?, on worklaneID: WorklaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            return
        }
        if worklanes[index].bookmarkOriginID == originID {
            return
        }
        worklanes[index].bookmarkOriginID = originID
        notify(.auxiliaryStateUpdated(worklaneID, worklanes[index].paneStripState.focusedPaneID ?? PaneID(""), .sidebar))
    }

    func focusPane(id: PaneID) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousWorklane = worklane
        let previousPaneRef = currentPaneReference
        let wasFocusedPaneID = worklane.paneStripState.focusedPaneID
        let hadReadyStatus = worklane.auxiliaryStateByPaneID[id]?.raw.showsReadyStatus == true
            || worklane.auxiliaryStateByPaneID[id]?.raw.wantsReadyStatus == true
        if wasFocusedPaneID == id, !hadReadyStatus {
            return
        }

        worklane.paneStripState.focusPane(id: id)
        clearReadyStatusIfNeeded(for: id, in: &worklane)
        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        if wasFocusedPaneID == id {
            let impacts = auxiliaryInvalidation(for: id, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(activeWorklaneID, id, impacts))
            }
        } else {
            recordFocusTransition(from: previousPaneRef)
            notify(.focusChanged(activeWorklaneID))
        }
    }

    func selectWorklaneAndFocusPane(worklaneID: WorklaneID, paneID: PaneID) {
        guard let index = worklanes.firstIndex(where: { $0.id == worklaneID }) else {
            return
        }

        let previousPaneRef = currentPaneReference
        worklanes[index].paneStripState.focusPane(id: paneID)
        clearReadyStatusIfNeeded(for: paneID, in: &worklanes[index])
        activeWorklaneID = worklaneID
        recordFocusTransition(from: previousPaneRef)
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func closeActiveWorklane() {
        guard removeActiveWorklaneIfPossible() else {
            return
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(.worklaneListChanged)
    }

    enum PaneCloseResult {
        case closed
        case closeWindow
        case notFound
    }

    func closePaneFromShellExit(id paneID: PaneID) -> PaneCloseResult {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return .notFound
        }

        var worklane = worklanes[worklaneIndex]

        if worklane.paneStripState.panes.count == 1 {
            if worklanes.count == 1 {
                worklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
                worklanes[worklaneIndex] = worklane
                serverRegistry.clear(worklaneID: worklane.id, paneID: paneID)
                return .closeWindow
            }

            let removedID = worklane.id
            worklanes.remove(at: worklaneIndex)
            serverRegistry.clear(worklaneID: removedID)
            if activeWorklaneID == removedID {
                let replacementIndex = min(max(worklaneIndex - 1, 0), worklanes.count - 1)
                activeWorklaneID = worklanes[replacementIndex].id
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
            return .closed
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        if let removal = worklane.paneStripState.removePane(id: paneID, singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removal.pane.id, in: &worklane)
            serverRegistry.clear(worklaneID: worklane.id, paneID: removal.pane.id)
            applyColumnWidthNormalization(
                &worklane,
                previousColumnCount: previousColumnCount,
                singleColumnWidth: layoutContext.singlePaneWidth
            )
        }
        worklanes[worklaneIndex] = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(worklane.id))
        return .closed
    }

    func closeFocusedPane() -> PaneCloseResult {
        guard let paneID = activeWorklane?.paneStripState.focusedPaneID else {
            return .notFound
        }

        return closePane(id: paneID, source: .userCommand)
    }

    @discardableResult
    func closePane(id: PaneID, source: PaneCloseSource = .userCommand) -> PaneCloseResult {
        guard var worklane = activeWorklane else {
            return .notFound
        }

        // If this pane is a leader of a Claude Code agent-teams column, close
        // the subagent column first so the
        // leader-close action takes the whole team down with it.
        cascadeCloseTeamColumnIfLeader(paneID: id, in: &worklane)

        let previousPaneRef = currentPaneReference
        worklane.paneStripState.focusPane(id: id)
        guard worklane.paneStripState.panes.contains(where: { $0.id == id }) else {
            return .notFound
        }

        let isLastPaneInLastColumn = worklane.paneStripState.columns.count == 1
            && worklane.paneStripState.panes.count == 1

        // Closing the last pane in the only worklane just signals the view
        // layer to close the window — the pane itself isn't removed here, and
        // the user may still cancel the window-close prompt. Skip capture in
        // that case to avoid leaving a stack entry pointing at a still-live
        // pane (which would let ⌘⇧T duplicate it).
        if isLastPaneInLastColumn, worklanes.count == 1 {
            return .closeWindow
        }

        if source == .userCommand {
            captureClosedPane(paneID: id, in: worklane)
        }

        if isLastPaneInLastColumn {
            guard removeActiveWorklaneIfPossible() else {
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return .closed
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
            return .closed
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        if let removedPane = worklane.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removedPane.id, in: &worklane)
            serverRegistry.clear(worklaneID: worklane.id, paneID: removedPane.id)
            applyColumnWidthNormalization(
                &worklane,
                previousColumnCount: previousColumnCount,
                singleColumnWidth: layoutContext.singlePaneWidth
            )
        }

        activeWorklane = worklane

        // Record the previous focus only if the closed pane was not the one
        // we were already focused on. When closing a non-focused pane from the
        // sidebar, previousPaneRef is the real focus origin (alive) and should
        // be recorded so back returns there.
        let newPaneRef = currentPaneReference
        if let previousPaneRef, previousPaneRef.paneID != id, previousPaneRef != newPaneRef {
            recordFocusTransition(from: previousPaneRef)
        }

        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
        return .closed
    }

    #if DEBUG
    func replaceWorklanes(_ worklanes: [WorklaneState], activeWorklaneID: WorklaneID? = nil) {
        self.worklanes = worklanes
        let fallbackID = activeWorklaneID ?? worklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        self.activeWorklaneID = worklanes.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : worklanes.first?.id ?? runtimeIdentity.makeWorklaneID()
        normalizeAllPanePresentationState()
        refreshLastFocusedLocalWorkingDirectory()
        refreshAllPaneGitContexts()
        notify(.worklaneListChanged)
    }
    #endif

    private func makePane(in worklane: inout WorklaneState, existingPaneCount: Int) -> PaneState {
        defer {
            worklane.nextPaneNumber += 1
        }

        let title = "pane \(worklane.nextPaneNumber)"
        let paneID = runtimeIdentity.makePaneID()
        let focusedPaneID = worklane.paneStripState.focusedPaneID
        let launchContext = focusedPaneID.flatMap { resolveLaunchContext(for: $0, in: worklane) }
        let workingDirectory = launchContext?.path
            ?? lastFocusedLocalWorkingDirectory
            ?? Self.defaultWorkingDirectory()
        let inheritFromPaneID = sourcePaneIDForSessionInheritance(in: worklane)
        let configInheritanceSourcePaneID = sourcePaneIDForConfigInheritance(in: worklane)

        let initialShellContext = seededShellContext(
            launchContext: launchContext,
            sourceShellContext: inheritFromPaneID.flatMap { worklane.auxiliaryStateByPaneID[$0]?.shellContext },
            fallbackWorkingDirectory: workingDirectory
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: title,
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: inheritFromPaneID == nil ? workingDirectory : nil
        )
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            raw: initialRaw,
            presentation: initialPresentation
        )

        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: inheritFromPaneID,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                surfaceContext: .split,
                environmentVariables: sessionEnvironment(
                    worklaneID: worklane.id,
                    paneID: paneID,
                    initialWorkingDirectory: inheritFromPaneID == nil ? workingDirectory : nil
                )
            ),
            width: layoutContext.newPaneWidth(existingPaneCount: existingPaneCount)
        )
    }

    /// Create a new pane in the given worklane with an explicit working directory.
    /// Used by duplicate-pane operations where the CWD comes from the source pane.
    func makePaneWithDirectory(
        in worklane: inout WorklaneState,
        existingPaneCount: Int,
        workingDirectory: String?,
        sourceShellContext: PaneShellContext? = nil,
        command: String? = nil
    ) -> PaneState {
        defer { worklane.nextPaneNumber += 1 }

        let title = "pane \(worklane.nextPaneNumber)"
        let paneID = runtimeIdentity.makePaneID()
        let resolvedDirectory = workingDirectory ?? Self.defaultWorkingDirectory()
        let configSource = sourcePaneIDForConfigInheritance(in: worklane)

        let initialShellContext = seededShellContext(
            launchContext: sourceShellContext.map {
                PaneLaunchContext(path: resolvedDirectory, scope: $0.scope)
            },
            sourceShellContext: sourceShellContext,
            fallbackWorkingDirectory: resolvedDirectory
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: title,
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: resolvedDirectory
        )
        worklane.auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            raw: initialRaw,
            presentation: initialPresentation
        )

        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: resolvedDirectory,
                command: command,
                inheritFromPaneID: nil,
                configInheritanceSourcePaneID: configSource,
                surfaceContext: .split,
                environmentVariables: sessionEnvironment(
                    worklaneID: worklane.id,
                    paneID: paneID,
                    initialWorkingDirectory: resolvedDirectory
                )
            ),
            width: layoutContext.newPaneWidth(existingPaneCount: existingPaneCount)
        )
    }

    private func seededShellContext(
        launchContext: PaneLaunchContext?,
        sourceShellContext: PaneShellContext?,
        fallbackWorkingDirectory: String
    ) -> PaneShellContext {
        let resolvedPath = launchContext?.path ?? sourceShellContext?.path ?? fallbackWorkingDirectory

        if sourceShellContext?.scope == .remote || launchContext?.scope == .remote {
            return PaneShellContext(
                scope: .remote,
                path: resolvedPath,
                home: sourceShellContext?.home,
                user: sourceShellContext?.user,
                host: sourceShellContext?.host,
                gitBranch: sourceShellContext?.gitBranch
            )
        }

        return PaneShellContext(
            scope: .local,
            path: resolvedPath,
            home: processEnvironment["HOME"],
            user: processEnvironment["USER"],
            host: nil
        )
    }

    private static func defaultWorklanes(
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String],
        runtimeIdentity: WorklaneRuntimeIdentity,
        agentTeamsEnabled: Bool
    ) -> [WorklaneState] {
        [
            makeDefaultWorklane(
                id: runtimeIdentity.makeWorklaneID(),
                title: nil,
                windowID: windowID,
                layoutContext: layoutContext,
                workingDirectory: Self.defaultWorkingDirectory(),
                surfaceContext: .window,
                processEnvironment: processEnvironment,
                runtimeIdentity: runtimeIdentity,
                agentTeamsEnabled: agentTeamsEnabled
            ),
        ]
    }

    private static func makeDefaultWorklane(
        id: WorklaneID,
        title: String?,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        workingDirectory: String,
        surfaceContext: TerminalSurfaceContext,
        configInheritanceSourcePaneID: PaneID? = nil,
        processEnvironment: [String: String],
        runtimeIdentity: WorklaneRuntimeIdentity,
        agentTeamsEnabled: Bool
    ) -> WorklaneState {
        let shellPaneID = runtimeIdentity.makePaneID()
        let initialShellContext = PaneShellContext(
            scope: .local,
            path: workingDirectory,
            home: processEnvironment["HOME"],
            user: processEnvironment["USER"],
            host: nil
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: workingDirectory
        )
        return WorklaneState(
            id: id,
            title: title,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: shellPaneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            workingDirectory: workingDirectory,
                            configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                            surfaceContext: surfaceContext,
                            environmentVariables: Self.sessionEnvironment(
                                windowID: windowID,
                                worklaneID: id,
                                paneID: shellPaneID,
                                initialWorkingDirectory: workingDirectory,
                                processEnvironment: processEnvironment,
                                agentTeamsEnabled: agentTeamsEnabled
                            )
                        ),
                        width: layoutContext.singlePaneWidth
                    ),
                ],
                focusedPaneID: shellPaneID,
                layoutSizing: layoutContext.sizing
            ),
            auxiliaryStateByPaneID: [
                shellPaneID: PaneAuxiliaryState(
                    raw: initialRaw,
                    presentation: initialPresentation
                ),
            ]
        )
    }

    /// Runs `body` with change notifications suppressed, then delivers a single
    /// coalesced burst of everything `body` (and anything it called) tried to
    /// emit. This keeps subscribers from re-rendering on each intermediate
    /// mutation of a multi-step operation while guaranteeing that no change is
    /// silently dropped — the earlier behavior lost every notification raised
    /// inside the batch and relied on callers to hand-re-emit them.
    ///
    /// Reentrant: nested `batchUpdate` calls share one pending buffer and only
    /// the outermost exit flushes.
    func batchUpdate(_ body: () -> Void) {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0 {
                flushBatchedChanges()
            }
        }
        body()
    }

    /// Runs `body` with change notifications dropped outright — the pre-replay
    /// `batchUpdate` semantics. Intended for wrapping a *render* pass that must
    /// not re-enter its own change handler: if something in the render tree
    /// synchronously raises a `WorklaneChange` (e.g. as a side effect of
    /// reading state), that notification is discarded rather than queued for
    /// replay, which would otherwise re-trigger the render and risk a loop.
    ///
    /// Do NOT use this for mutation batching — mutations wrapped here lose
    /// their notifications permanently. Use `batchUpdate` for that; it
    /// coalesces and replays instead of dropping.
    ///
    /// Composes with `batchUpdate` nesting via one rule: while suppression
    /// depth is greater than zero, `notify(_:)` drops immediately, regardless
    /// of `batchDepth`. So `batchUpdate` nested inside `withNotificationsSuppressed`
    /// drops (suppression wins), and `withNotificationsSuppressed` nested
    /// inside `batchUpdate` also drops for its duration — nothing it raises is
    /// queued into the enclosing batch's replay buffer.
    func withNotificationsSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        suppressionDepth += 1
        defer { suppressionDepth -= 1 }
        return try body()
    }

    /// Internal — called by WorklaneStore extension files to dispatch change notifications.
    /// Not intended for use outside WorklaneStore and its extensions.
    func notify(_ change: WorklaneChange) {
        guard suppressionDepth == 0 else {
            return
        }
        guard batchDepth == 0 else {
            pendingBatchedChanges.append(change)
            return
        }
        for subscriber in subscribers {
            subscriber.handler(change)
        }
    }

    /// Delivers the changes captured during a batch as one coalesced burst.
    ///
    /// Coalescing is order-preserving exact-duplicate removal: the first
    /// occurrence of each distinct `WorklaneChange` is kept in emission order,
    /// later exact repeats are dropped. Because `WorklaneChange` is `Equatable`
    /// over its associated values (paneID, invalidation impacts, animation),
    /// semantically distinct payloads are always preserved — only redundant
    /// exact repeats collapse. This is the conservative choice: subscribers see
    /// every distinct change they would have seen without batching, just once
    /// and in order, with no broad "re-render everything" substitution.
    private func flushBatchedChanges() {
        guard !pendingBatchedChanges.isEmpty else {
            return
        }

        var coalesced: [WorklaneChange] = []
        for change in pendingBatchedChanges where !coalesced.contains(change) {
            coalesced.append(change)
        }
        // Clear before delivery so any change a subscriber raises synchronously
        // (batchDepth is 0 here) is delivered immediately rather than requeued.
        pendingBatchedChanges.removeAll(keepingCapacity: true)

        for change in coalesced {
            notify(change)
        }
    }

    private func notifyLayoutResized(animation: WorklaneLayoutResizeAnimation) {
        notify(.layoutResized(activeWorklaneID, animation: animation))
    }

    private func sessionEnvironment(
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil
    ) -> [String: String] {
        Self.sessionEnvironment(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            initialWorkingDirectory: initialWorkingDirectory,
            processEnvironment: processEnvironment,
            agentTeamsEnabled: agentTeamsEnabledProvider()
        )
    }

    func sessionEnvironment(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil
    ) -> [String: String] {
        Self.sessionEnvironment(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            initialWorkingDirectory: initialWorkingDirectory,
            processEnvironment: processEnvironment
        )
    }

    private static func sessionEnvironment(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil,
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool = false
    ) -> [String: String] {
        WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            initialWorkingDirectory: initialWorkingDirectory,
            processEnvironment: processEnvironment,
            agentTeamsEnabled: agentTeamsEnabled
        )
    }

    /// When a Claude Code agent-teams leader pane is closed (either by Claude
    /// emitting `tmux kill-pane` or by the user clicking close in the UI),
    /// cascade-close every subagent pane in the recorded column and prune the
    /// anchor entry. Recorded panes that no longer exist are silently
    /// skipped — `closeFocusedPane` is a no-op for unknown IDs.
    private func cascadeCloseTeamColumnIfLeader(
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        guard let anchor = teamAnchorByWorklaneID[worklane.id],
              anchor.leaderPaneID == paneID.rawValue else {
            return
        }

        for paneRaw in anchor.columnPaneIDs {
            let teammateID = PaneID(paneRaw)
            guard worklane.paneStripState.panes.contains(where: { $0.id == teammateID }) else {
                continue
            }
            worklane.paneStripState.focusPane(id: teammateID)
            if let removed = worklane.paneStripState.closeFocusedPane(
                singleColumnWidth: layoutContext.singlePaneWidth
            ) {
                clearPaneState(for: removed.id, in: &worklane)
            }
        }

        TmuxCompatStoreIO.mutate { store in
            store.anchors.removeValue(forKey: worklane.id.rawValue)
        }
        teamAnchorByWorklaneID.removeValue(forKey: worklane.id)
        notify(.teamAnchorsChanged(worklane.id))
    }

    /// Reload the in-memory anchor cache from the on-disk JSON store. The
    /// IPC handler calls this after every mutation (split-window,
    /// kill-pane, set-buffer, …) so the title-strip sees the change without
    /// disk I/O on its hot path.
    func refreshTeamAnchors() {
        let next = TmuxCompatStoreIO.load().anchors.reduce(into: [WorklaneID: WorklaneAnchor]()) {
            partial, entry in
            partial[WorklaneID(entry.key)] = entry.value
        }
        let changedWorklanes = Set(teamAnchorByWorklaneID.keys).symmetricDifference(next.keys)
            .union(next.compactMap { worklaneID, anchor -> WorklaneID? in
                teamAnchorByWorklaneID[worklaneID] == anchor ? nil : worklaneID
            })
        teamAnchorByWorklaneID = next
        for worklaneID in changedWorklanes {
            notify(.teamAnchorsChanged(worklaneID))
        }
    }

    /// Drop on-disk anchor entries whose recorded panes no longer exist.
    /// Called from `init` so a workspace restored with fresh pane IDs
    /// doesn't keep showing the LEADER star on a pane that has nothing to
    /// do with the original team.
    private static func pruneStaleTeamAnchors(
        in worklanes: [WorklaneState]
    ) -> [WorklaneID: WorklaneAnchor] {
        let livePaneIDsByWorklane = Dictionary(
            uniqueKeysWithValues: worklanes.map { worklane in
                (worklane.id, Set(worklane.paneStripState.panes.map(\.id.rawValue)))
            }
        )
        let diskAnchors = TmuxCompatStoreIO.load().anchors
        var seeded: [WorklaneID: WorklaneAnchor] = [:]
        var pruned = false
        for (rawWorklaneID, anchor) in diskAnchors {
            let worklaneID = WorklaneID(rawWorklaneID)
            guard let alive = livePaneIDsByWorklane[worklaneID],
                  alive.contains(anchor.leaderPaneID) else {
                pruned = true
                continue
            }
            let liveColumn = anchor.columnPaneIDs.filter(alive.contains)
            if liveColumn.count != anchor.columnPaneIDs.count {
                pruned = true
            }
            seeded[worklaneID] = WorklaneAnchor(
                leaderPaneID: anchor.leaderPaneID,
                columnPaneIDs: liveColumn
            )
        }
        if pruned {
            TmuxCompatStoreIO.mutate { store in
                store.anchors = Dictionary(uniqueKeysWithValues:
                    seeded.map { ($0.key.rawValue, $0.value) }
                )
            }
        }
        return seeded
    }

    private func sourcePaneIDForSessionInheritance(in worklane: WorklaneState) -> PaneID? {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return nil
        }

        if let paneContext = worklane.auxiliaryStateByPaneID[focusedPaneID]?.shellContext {
            return paneContext.scope == .remote ? focusedPaneID : nil
        }

        guard let pane = pane(for: focusedPaneID, in: worklane) else {
            return nil
        }

        return pane.sessionRequest.inheritFromPaneID == nil ? nil : focusedPaneID
    }

    private func sourcePaneIDForConfigInheritance(in worklane: WorklaneState) -> PaneID? {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID,
              pane(for: focusedPaneID, in: worklane) != nil else {
            return nil
        }

        return focusedPaneID
    }

    private func resolveLaunchContext(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> PaneLaunchContext? {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )

        return terminalLocation.workingDirectory.map {
            PaneLaunchContext(path: $0, scope: terminalLocation.scope)
        }
    }

    func localReviewWorkingDirectory(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> String? {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )
        guard terminalLocation.scope != .remote else {
            return nil
        }

        return terminalLocation.workingDirectory
    }

    func focusedOpenWithContext(in worklane: WorklaneState) -> WorklaneOpenWithContext? {
        guard
            let focusedPaneID = worklane.paneStripState.focusedPaneID,
            let launchContext = resolveLaunchContext(for: focusedPaneID, in: worklane),
            canTreatLaunchContextAsLocal(launchContext, for: focusedPaneID, in: worklane)
        else {
            return nil
        }

        return WorklaneOpenWithContext(
            worklaneID: worklane.id,
            paneID: focusedPaneID,
            workingDirectory: launchContext.path,
            scope: .local
        )
    }

    private func canTreatLaunchContextAsLocal(
        _ launchContext: PaneLaunchContext,
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> Bool {
        switch launchContext.scope {
        case .local:
            return true
        case .remote:
            return false
        case nil:
            return nonInheritedSessionWorkingDirectory(for: paneID, in: worklane) != nil
        }
    }

    func refreshLastFocusedLocalWorkingDirectory() {
        guard
            let worklane = activeWorklane,
            let focusedPaneID = worklane.paneStripState.focusedPaneID
        else {
            lastFocusedPaneReference = nil
            return
        }

        lastFocusedPaneReference = PaneReference(worklaneID: worklane.id, paneID: focusedPaneID)
        updateLastFocusedLocalWorkingDirectory(using: focusedPaneID, in: worklane)
    }

    func refreshLastFocusedLocalWorkingDirectoryIfNeeded(
        worklane: WorklaneState,
        paneID: PaneID
    ) {
        guard worklane.id == activeWorklaneID, worklane.paneStripState.focusedPaneID == paneID else {
            return
        }

        updateLastFocusedLocalWorkingDirectory(using: paneID, in: worklane)
    }

    private func updateLastFocusedLocalWorkingDirectory(
        using paneID: PaneID,
        in worklane: WorklaneState
    ) {
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
            shellContext: worklane.auxiliaryStateByPaneID[paneID]?.shellContext,
            requestWorkingDirectory: nonInheritedSessionWorkingDirectory(for: paneID, in: worklane)
        )
        guard terminalLocation.scope != .remote,
              let workingDirectory = terminalLocation.workingDirectory else {
            return
        }

        lastFocusedLocalPaneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        lastFocusedLocalWorkingDirectory = workingDirectory
    }

    private func clearReadyStatusForFocusedPane(in worklane: inout WorklaneState) {
        guard let focusedPaneID = worklane.paneStripState.focusedPaneID else {
            return
        }

        clearReadyStatusIfNeeded(for: focusedPaneID, in: &worklane)
    }

    func clearReadyStatusIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        cancelPendingReadyStatus(for: paneReference)

        guard worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true
            || worklane.auxiliaryStateByPaneID[paneID]?.raw.wantsReadyStatus == true
        else {
            stopSignalLogger.debug("ready.clear.noop pane=\(paneID.rawValue, privacy: .public)")
            return
        }

        worklane.auxiliaryStateByPaneID[paneID]?.raw.wantsReadyStatus = false
        worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus = false
        let worklaneIDRaw = worklane.id.rawValue
        worklaneReadyLogger.debug(
            "Cleared ready status worklane=\(worklaneIDRaw, privacy: .public) pane=\(paneID.rawValue, privacy: .public)"
        )
        stopSignalLogger.debug("ready.clear.applied pane=\(paneID.rawValue, privacy: .public)")
        recomputePresentation(for: paneID, in: &worklane)
    }

    func markCodexCurrentRunActivityIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        guard worklane.auxiliaryStateByPaneID[paneID]?.raw.codexCurrentRunHasObservedActivity != true else {
            return
        }
        worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].raw.codexCurrentRunHasObservedActivity = true
    }

    func clearCodexCurrentRunActivity(for paneID: PaneID, in worklane: inout WorklaneState) {
        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexCurrentRunHasObservedActivity = false
    }

    func codexReadyPromotionAllowed(in auxiliaryState: PaneAuxiliaryState?) -> Bool {
        guard let auxiliaryState else {
            return false
        }

        if auxiliaryState.raw.codexCurrentRunHasObservedActivity {
            return true
        }

        return Self.codexStatusIsExplicitCurrentRunActivity(auxiliaryState.agentStatus)
    }

    static func codexStatusIsExplicitCurrentRunActivity(_ status: PaneAgentStatus?) -> Bool {
        guard let status,
              status.tool == .codex,
              status.state == .running || status.state == .needsInput else {
            return false
        }

        return status.origin == .explicitHook || status.origin == .explicitAPI
    }

    static func metadataIndicatesCodexCurrentRunActivity(_ metadata: TerminalMetadata?) -> Bool {
        guard let metadata,
              AgentToolRecognizer.recognize(metadata: metadata) == .codex else {
            return false
        }

        if TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: metadata.title) != nil {
            return true
        }
        if TerminalMetadataChangeClassifier.codexWaitingTitleKind(for: metadata.title) == .needsInput {
            return true
        }

        let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            metadata.title,
            recognizedTool: .codex
        )
        return signature?.phase == .running || signature?.phase == .needsInput
    }

    func requestReadyStatusIfNeeded(for paneID: PaneID, in worklane: inout WorklaneState) {
        let paneReference = PaneReference(worklaneID: worklane.id, paneID: paneID)
        var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
        auxiliaryState.raw.wantsReadyStatus = true
        let shouldSchedule = auxiliaryState.raw.showsReadyStatus == false
        if shouldSchedule,
           readyStatusDebounceInterval <= 0,
           readyStatusMayBecomeVisible(in: auxiliaryState) {
            auxiliaryState.raw.showsReadyStatus = true
        }
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        let worklaneIDRaw = worklane.id.rawValue
        let showsReadyImmediately = auxiliaryState.raw.showsReadyStatus
        worklaneReadyLogger.debug(
            "Requested ready status worklane=\(worklaneIDRaw, privacy: .public) pane=\(paneID.rawValue, privacy: .public) immediate=\(showsReadyImmediately, privacy: .public)"
        )
        stopSignalLogger.debug(
            "ready.request pane=\(paneID.rawValue, privacy: .public) immediate=\(showsReadyImmediately, privacy: .public) scheduled=\(shouldSchedule && self.readyStatusDebounceInterval > 0, privacy: .public)"
        )

        guard shouldSchedule else {
            cancelPendingReadyStatus(for: paneReference)
            return
        }

        guard readyStatusDebounceInterval > 0 else {
            cancelPendingReadyStatus(for: paneReference)
            return
        }

        scheduleReadyStatusReveal(for: paneReference)
    }

    func cancelPendingReadyStatus(for paneReference: PaneReference) {
        pendingReadyStatusTasks[paneReference]?.cancel()
        pendingReadyStatusTasks[paneReference] = nil
    }

    func scheduleAgentStatusSweep(for paneReference: PaneReference, after interval: TimeInterval) {
        pendingAgentStatusSweepTasks[paneReference]?.cancel()
        pendingAgentStatusSweepTasks[paneReference] = scheduleReadyStatusTask(interval) { [weak self] in
            self?.pendingAgentStatusSweepTasks[paneReference] = nil
            self?.clearStaleAgentSessions()
        }
    }

    private func scheduleReadyStatusReveal(for paneReference: PaneReference) {
        cancelPendingReadyStatus(for: paneReference)

        let debounceInterval = readyStatusDebounceInterval
        guard debounceInterval > 0 else {
            commitReadyStatusReveal(for: paneReference)
            return
        }

        pendingReadyStatusTasks[paneReference] = scheduleReadyStatusTask(debounceInterval) { [weak self] in
            self?.commitReadyStatusReveal(for: paneReference)
        }
    }

    private static func defaultReadyStatusScheduler(
        interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any WorklaneStoreScheduledHandle {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else {
                return
            }

            operation()
        }
        return TaskWorklaneStoreScheduledHandle(task: task)
    }

    private func commitReadyStatusReveal(for paneReference: PaneReference) {
        pendingReadyStatusTasks[paneReference] = nil

        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == paneReference.worklaneID }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneReference.paneID],
              readyStatusMayBecomeVisible(in: auxiliaryState),
              auxiliaryState.raw.showsReadyStatus == false
        else {
            return
        }

        auxiliaryState.raw.showsReadyStatus = true
        worklane.auxiliaryStateByPaneID[paneReference.paneID] = auxiliaryState
        worklaneReadyLogger.debug(
            "Committed ready status worklane=\(paneReference.worklaneID.rawValue, privacy: .public) pane=\(paneReference.paneID.rawValue, privacy: .public)"
        )
        recomputePresentation(for: paneReference.paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane

        let impacts = auxiliaryInvalidation(
            for: paneReference.paneID,
            previousWorklane: previousWorklane,
            nextWorklane: worklane
        )
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneReference.paneID, impacts))
        }
    }

    private func readyStatusMayBecomeVisible(in auxiliaryState: PaneAuxiliaryState) -> Bool {
        guard auxiliaryState.raw.wantsReadyStatus else {
            return false
        }

        if let agentStatus = auxiliaryState.agentStatus,
           agentStatus.state == .idle,
           agentStatus.hasObservedRunning {
            if agentStatus.tool == .codex {
                return codexReadyPromotionAllowed(in: auxiliaryState)
            }
            return true
        }

        guard let notificationText = WorklaneContextFormatter.trimmed(
            auxiliaryState.raw.lastDesktopNotificationText
        )?.lowercased() else {
            return false
        }

        if notificationText.contains("agent run complete")
            || notificationText.contains("agent ready")
            || notificationText.contains("agent turn complete") {
            let recognizedTool = auxiliaryState.agentStatus?.tool
                ?? AgentToolRecognizer.recognize(metadata: auxiliaryState.metadata)
            if recognizedTool == .codex {
                return codexReadyPromotionAllowed(in: auxiliaryState)
            }
            return true
        }

        let recognizedTool = auxiliaryState.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: auxiliaryState.metadata)
        return recognizedTool == .gemini && notificationText.contains("session complete")
    }

    private func resolveWorkingDirectoryForNewWorklane() -> String {
        if let lastFocusedPaneReference,
           let worklane = worklanes.first(where: { $0.id == lastFocusedPaneReference.worklaneID }),
           let launchContext = resolveLaunchContext(for: lastFocusedPaneReference.paneID, in: worklane),
           launchContext.scope != .remote {
            return launchContext.path
        }

        return lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
    }

    private func resolveConfigInheritanceSourcePaneIDForNewWorklane() -> PaneID? {
        guard let lastFocusedLocalPaneReference,
              let worklane = worklanes.first(where: { $0.id == lastFocusedLocalPaneReference.worklaneID }),
              pane(for: lastFocusedLocalPaneReference.paneID, in: worklane) != nil else {
            return nil
        }

        return lastFocusedLocalPaneReference.paneID
    }

    func nonInheritedSessionWorkingDirectory(
        for paneID: PaneID,
        in worklane: WorklaneState
    ) -> String? {
        guard let pane = pane(for: paneID, in: worklane),
              pane.sessionRequest.inheritFromPaneID == nil else {
            return nil
        }

        return Self.trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
    }

    private func pane(for paneID: PaneID, in worklane: WorklaneState) -> PaneState? {
        worklane.paneStripState.panes.first { $0.id == paneID }
    }

    private func liveAuxiliaryState(for paneID: PaneID) -> PaneAuxiliaryState? {
        for worklane in worklanes {
            guard worklane.paneStripState.panes.contains(where: { $0.id == paneID }) else {
                continue
            }
            return worklane.auxiliaryStateByPaneID[paneID]
        }
        return nil
    }

    private func agentStatusAllowsRestoredCommand(_ status: PaneAgentStatus?) -> Bool {
        guard let status else { return true }
        switch status.state {
        case .starting, .running, .needsInput:
            return false
        case .idle, .unresolvedStop:
            return true
        }
    }

    private static func trimmedRestoredCommand(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultWorkingDirectory() -> String {
        NSHomeDirectory()
    }

    private static func trimmedWorkingDirectory(_ workingDirectory: String?) -> String? {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return nil
        }

        return workingDirectory
    }

    private static func readableWidthScaleFactor(
        from previousLayoutContext: PaneLayoutContext,
        to nextLayoutContext: PaneLayoutContext
    ) -> CGFloat? {
        let previousReadableWidth = previousLayoutContext.readableWidth
        let nextReadableWidth = nextLayoutContext.readableWidth
        guard previousReadableWidth > 0, nextReadableWidth > 0 else {
            return nil
        }

        return nextReadableWidth / previousReadableWidth
    }

    @discardableResult
    private func removeActiveWorklaneIfPossible() -> Bool {
        guard worklanes.count > 1, let activeIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return false
        }

        let removedWorklaneID = worklanes[activeIndex].id
        worklanes.remove(at: activeIndex)
        serverRegistry.clear(worklaneID: removedWorklaneID)
        let replacementIndex = min(max(activeIndex - 1, 0), worklanes.count - 1)
        activeWorklaneID = worklanes[replacementIndex].id
        return true
    }
}

private extension WorklaneStore {
    func normalizeAllPanePresentationState() {
        for worklaneIndex in worklanes.indices {
            let paneIDs = worklanes[worklaneIndex].paneStripState.panes.map(\.id)
            for paneID in paneIDs {
                recomputePresentation(for: paneID, in: &worklanes[worklaneIndex])
            }
        }
    }

    func refreshAllPaneGitContexts() {
        for worklane in worklanes {
            for pane in worklane.paneStripState.panes {
                refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: pane.id))
            }
        }
    }
}
