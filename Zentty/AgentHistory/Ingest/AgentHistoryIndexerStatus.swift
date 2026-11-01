import Foundation

/// Why backfill is paused. Live events and database polls keep running except on `.diskFull`
/// and `.configUnreadable`.
enum AgentHistoryPauseReason: String, Sendable {
    case lowPower
    case thermal
    case diskFull
    /// Another Zentty instance of this flavor owns the index (it keeps it fresh); this one
    /// shows the stored sessions read-only and takes over once that instance stops.
    case anotherInstance
    /// config.toml couldn't be read at launch, so the excluded folders are unknown. Set by the
    /// controller, never by the indexer: no indexer runs and nothing can be searched until a
    /// readable config.toml loads.
    case configUnreadable
}

/// Why the index can't be used at all.
enum AgentHistoryFailureReason: Equatable, Sendable {
    /// The writer could not open the database (SQLite result code).
    case openFailed(code: Int32)
    /// The file was written by a newer build; it is never read or modified (D14, A-16).
    case newerSchema(found: Int32)
    case corrupt
    /// `removals.json` exists but can't be read: nothing is indexed, so no removed session comes
    /// back. "Delete Index" clears it.
    case removalsUnreadable
}

/// Sessions indexed so far against the sessions discovered by the current backfill.
struct AgentHistoryBackfillProgress: Equatable, Sendable {
    var indexedSessions: Int
    var totalSessions: Int
}

enum AgentHistoryIndexerState: Equatable, Sendable {
    case off
    case starting
    case backfilling(AgentHistoryBackfillProgress)
    case watching
    case paused(AgentHistoryPauseReason, AgentHistoryBackfillProgress?)
    case failed(AgentHistoryFailureReason)

    /// A short, stable name for logs and breadcrumbs (never carries paths or counts).
    var logName: String {
        switch self {
        case .off: return "off"
        case .starting: return "starting"
        case .backfilling: return "backfilling"
        case .watching: return "watching"
        case .paused(let reason, _): return "paused.\(reason.rawValue)"
        case .failed: return "failed"
        }
    }
}

/// Health of one source root. The Settings formatter groups these by agent.
struct AgentHistorySourceHealth: Equatable, Sendable {
    let agent: AgentHistoryAgent
    let root: String
    let isDefaultRoot: Bool
    var isEnabled: Bool
    var discovered: Int
    var indexed: Int
    var skipped: Int
    var problem: AgentHistorySourceProblem?
    var lastError: String?
    var lastScanAt: Date?

    init(
        agent: AgentHistoryAgent,
        root: String,
        isDefaultRoot: Bool,
        isEnabled: Bool = true,
        discovered: Int = 0,
        indexed: Int = 0,
        skipped: Int = 0,
        problem: AgentHistorySourceProblem? = nil,
        lastError: String? = nil,
        lastScanAt: Date? = nil
    ) {
        self.agent = agent
        self.root = root
        self.isDefaultRoot = isDefaultRoot
        self.isEnabled = isEnabled
        self.discovered = discovered
        self.indexed = indexed
        self.skipped = skipped
        self.problem = problem
        self.lastError = lastError
        self.lastScanAt = lastScanAt
    }
}

/// Everything the palette, Settings and the CLI show about the index. Published by the indexer
/// on main (≤ 1 Hz, immediately on a state change); `revision` grows with every publish.
struct AgentHistoryStatus: Equatable, Sendable {
    /// False until `state.json` has been read: `isEnabled`, `hasConsented` and `enabledAgents`
    /// are placeholders until then, so nothing may ask for consent or record it on them.
    var isStateLoaded: Bool
    var isEnabled: Bool
    var hasConsented: Bool
    var enabledAgents: Set<AgentHistoryAgent>
    /// The configured excluded folders, as config.toml lists them. The controller stamps them on
    /// every publish and publishes when they change, so the palette can drop sessions they hide.
    var excludedFolders: [String]
    var state: AgentHistoryIndexerState
    var sources: [AgentHistorySourceHealth]
    var indexedSessions: Int
    var removedSessionCount: Int
    var indexExists: Bool
    var indexSizeBytes: Int64
    var lastUpdatedAt: Date?
    /// nil = not known yet (no index open). `.some(.none)` = no usable FTS5 → "Limited search".
    var tokenizer: AgentHistoryTokenizer?
    var isBackfillComplete: Bool
    var revision: UInt64

    static let off = AgentHistoryStatus(
        isStateLoaded: false,
        isEnabled: false,
        hasConsented: false,
        enabledAgents: [],
        excludedFolders: [],
        state: .off,
        sources: [],
        indexedSessions: 0,
        removedSessionCount: 0,
        indexExists: false,
        indexSizeBytes: 0,
        lastUpdatedAt: nil,
        tokenizer: nil,
        isBackfillComplete: false,
        revision: 0
    )
}

/// What the pre-consent probe found for one agent root (stat-only, D11). An agent with no root
/// on disk gets one entry with `isFound == false` and the paths that were checked.
struct AgentHistoryDetectedSource: Equatable, Sendable {
    let agent: AgentHistoryAgent
    let rootPath: String?
    let isFound: Bool
    /// nil when counting would mean opening a database (opencode, Codex catalog) or when not found.
    let sessionCount: Int?
    let checkedPaths: [String]
    let problem: AgentHistorySourceProblem?
}
