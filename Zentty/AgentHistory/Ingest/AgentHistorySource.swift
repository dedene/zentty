import Foundation

/// One on-disk history root of an agent (`~/.claude`, `$CODEX_HOME`, …). `path` is canonical.
struct AgentHistorySourceRoot: Hashable, Sendable {
    let agent: AgentHistoryAgent
    let path: String
    let isDefault: Bool
}

/// Per-batch caps. A batch ends at the first line boundary after either cap is reached.
struct AgentHistoryIngestLimits: Equatable, Sendable {
    var messages = 500
    var sourceBytes = 8 << 20
}

/// Everything an adapter needs besides the unit and cursor. Built by the indexer per run.
struct AgentHistoryIngestContext: Sendable {
    var limits: AgentHistoryIngestLimits
    var admission: AgentHistoryAdmission
    var repositories: RepositoryIdentityCache
    var redactor: AgentHistoryRedactor
    /// Checked every 1,024 lines inside JSONL loops and between database pages.
    var isCancelled: @Sendable () -> Bool

    init(
        limits: AgentHistoryIngestLimits = AgentHistoryIngestLimits(),
        admission: AgentHistoryAdmission,
        repositories: RepositoryIdentityCache,
        redactor: AgentHistoryRedactor = .shared,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.limits = limits
        self.admission = admission
        self.repositories = repositories
        self.redactor = redactor
        self.isCancelled = isCancelled
    }
}

/// What an FSEvents path means to a source: a file unit (by unit key) or its database.
enum AgentHistoryEventTarget: Equatable, Sendable {
    case unit(String)
    case database(String)
}

/// One agent's history at one root. Instances are confined to the indexer queue; `Sendable`
/// lets the indexer hand them across when it starts.
protocol AgentHistorySource: AnyObject, Sendable {
    var agent: AgentHistoryAgent { get }
    /// One instance per root.
    var root: AgentHistorySourceRoot { get }
    /// Bumping it re-ingests every unit of the source.
    var adapterVersion: Int { get }
    /// FSEvents roots; the indexer realpaths them.
    var watchPaths: [String] { get }

    /// Stat-only listing of the source's units. Never opens transcript contents.
    func discoverUnits() throws -> [AgentHistoryUnit]
    /// The unit or database a changed path belongs to; nil for noise.
    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget?
    /// The unit re-stat'ed just before the indexer classifies it (discovery may be minutes old).
    /// `identity` is nil when the unit is gone. Stat-only.
    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit
    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange
    /// Reads one batch. The returned `batch.cursor` is complete (A-5): the indexer persists it
    /// verbatim and only sets `isRejected`.
    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch
    /// Native ids that still exist upstream, for database-backed sources; nil for file sources
    /// (their deletions show up as missing units).
    func existingNativeIDs() throws -> Set<String>?
    /// Pre-consent probe; nil when counting would mean opening a database.
    func estimatedSessionCount() -> Int?
    /// True when the adapter holds back sessions without a usable folder while any folder is
    /// excluded (an exclusion might cover them). The indexer then purges such stored sessions
    /// when the first exclusion is added, so the live index matches a fresh one.
    var holdsBackSessionsWithoutFolder: Bool { get }
}

extension AgentHistorySource {
    /// Plain files and databases: a fresh stat of `unit.path`. Directory units override.
    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit {
        AgentHistoryUnit(
            key: unit.key,
            path: unit.path,
            kind: unit.kind,
            identity: AgentHistoryFileIdentity.stat(path: unit.path),
            nativeSessionID: unit.nativeSessionID
        )
    }

    /// Generic file rules; non-plain units (zstd, directories, databases) override (A-6).
    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        AgentHistoryUnitChangeClassifier.classify(cursor: cursor, current: unit.identity) {
            AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: cursor?.byteOffset ?? 0)
        }
    }

    func existingNativeIDs() throws -> Set<String>? {
        nil
    }

    var holdsBackSessionsWithoutFolder: Bool {
        false
    }
}
