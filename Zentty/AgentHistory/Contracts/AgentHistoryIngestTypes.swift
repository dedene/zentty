import Darwin
import Foundation

/// stat(2) identity of a history file. `mtimeNs` comes from `st_mtimespec`.
struct AgentHistoryFileIdentity: Hashable, Codable, Sendable {
    let dev: Int64
    let ino: Int64
    let size: Int64
    let mtimeNs: Int64

    static func stat(path: String) -> AgentHistoryFileIdentity? {
        var info = Darwin.stat()
        guard posixStat(path, &info) == 0 else {
            return nil
        }
        let mtime = info.st_mtimespec
        return AgentHistoryFileIdentity(
            dev: Int64(info.st_dev),
            ino: Int64(bitPattern: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            mtimeNs: Int64(mtime.tv_sec) &* 1_000_000_000 &+ Int64(mtime.tv_nsec)
        )
    }
}

/// stat(2) behind a free function: inside `AgentHistoryFileIdentity`, `stat` names the static method.
private func posixStat(_ path: String, _ info: inout Darwin.stat) -> Int32 {
    stat(path, &info)
}

/// One ingestible unit of a source: a transcript file, a session directory or a database.
struct AgentHistoryUnit: Hashable, Sendable {
    enum Kind: String, Sendable {
        case jsonl
        case zstdJSONL
        case directory
        case database
    }

    /// `cursors.unit_key`; stable across renames and compression.
    let key: String
    /// Primary file or directory.
    let path: String
    let kind: Kind
    /// Directory units use `mtimeNs = max(primary, auxiliary files)`.
    let identity: AgentHistoryFileIdentity?
    /// nil for database units.
    let nativeSessionID: String?
}

/// Persisted read position of one unit.
struct AgentHistoryCursor: Equatable, Sendable {
    var sourceID: Int64
    var unitKey: String
    var identity: AgentHistoryFileIdentity? = nil
    var byteOffset: Int64 = 0
    var nextSeq: Int = 0
    var watermark: Int64? = nil
    /// FNV-1a over at most 4 KB before `byteOffset`.
    var fingerprint: Int64? = nil
    /// Excluded or tombstoned unit: skipped until its identity changes.
    var isRejected = false
    /// Opaque per adapter (opencode keyset, pending commit ids, Grok ordinal).
    var adapterState: Data? = nil
}

enum AgentHistoryUnitChange: Equatable, Sendable {
    case unchanged
    case new
    case append(fromOffset: Int64, nextSeq: Int)
    case rewrite
    case identityOnly
    case missing
}

enum AgentHistoryIngestMode: Equatable, Sendable {
    case fromOffset(Int64, nextSeq: Int)
    case fromStart
}

/// Session metadata produced by an adapter; nil fields mean "unknown in this batch".
struct AgentHistorySessionDraft: Equatable, Sendable {
    let nativeID: String
    var title: String?
    var titleKind: AgentHistoryTitleKind?
    var cwd: String?
    var repoRoot: String?
    var mainRepoRoot: String?
    var branch: String?
    var model: String?
    var effort: String?
    var generation: String?
    var transcriptPath: String?
    var createdAtMs: Int64?
    var updatedAtMs: Int64?
    var lastUserAtMs: Int64?
    var archived: Bool?
    var parentNativeID: String?

    init(nativeID: String) {
        self.nativeID = nativeID
    }

    /// Merges an update into an existing draft. Must agree with the SQL session upsert:
    /// - Title: a higher rank replaces a lower one; at equal rank `custom` and `generated` take the
    ///   update while `first_prompt` keeps the earliest. An empty title never wins and a stored empty
    ///   title always loses. A nil kind counts as `first_prompt`.
    /// - `createdAtMs` takes the minimum; `updatedAtMs` and `lastUserAtMs` the maximum; nil never
    ///   replaces a value.
    /// - Every other field (including `archived`): a non-nil update wins, nil never clears.
    static func merged(
        existing: AgentHistorySessionDraft?,
        update: AgentHistorySessionDraft
    ) -> AgentHistorySessionDraft {
        guard let existing else {
            return update
        }

        var result = existing
        if takesTitle(existing: existing, update: update) {
            result.title = update.title
            result.titleKind = update.titleKind ?? .firstPrompt
        }

        result.cwd = update.cwd ?? existing.cwd
        result.repoRoot = update.repoRoot ?? existing.repoRoot
        result.mainRepoRoot = update.mainRepoRoot ?? existing.mainRepoRoot
        result.branch = update.branch ?? existing.branch
        result.model = update.model ?? existing.model
        result.effort = update.effort ?? existing.effort
        result.generation = update.generation ?? existing.generation
        result.transcriptPath = update.transcriptPath ?? existing.transcriptPath
        result.archived = update.archived ?? existing.archived
        result.parentNativeID = update.parentNativeID ?? existing.parentNativeID

        result.createdAtMs = combine(existing.createdAtMs, update.createdAtMs, min)
        result.updatedAtMs = combine(existing.updatedAtMs, update.updatedAtMs, max)
        result.lastUserAtMs = combine(existing.lastUserAtMs, update.lastUserAtMs, max)
        return result
    }

    private static func takesTitle(existing: AgentHistorySessionDraft, update: AgentHistorySessionDraft) -> Bool {
        guard let incoming = update.title, !incoming.isEmpty else {
            return false
        }
        guard let stored = existing.title, !stored.isEmpty else {
            return true
        }
        let incomingKind = update.titleKind ?? .firstPrompt
        let storedKind = existing.titleKind ?? .firstPrompt
        if incomingKind.rank != storedKind.rank {
            return incomingKind.rank > storedKind.rank
        }
        return incomingKind != .firstPrompt
    }

    private static func combine(_ lhs: Int64?, _ rhs: Int64?, _ pick: (Int64, Int64) -> Int64) -> Int64? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return pick(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}

struct AgentHistoryMessageDraft: Equatable, Sendable {
    let sessionNativeID: String
    let seq: Int
    let role: AgentHistoryRole
    let atMs: Int64
    /// Redacted display text.
    let text: String
    /// `AgentHistorySearchText.normalize(text)`.
    let searchText: String
}

struct AgentHistoryArtifactDraft: Equatable, Sendable {
    let sessionNativeID: String
    let seq: Int
    let kind: AgentHistoryArtifactKind
    let value: String
    let searchText: String
    let atMs: Int64
}

enum AgentHistoryAdmissionDecision: Equatable, Sendable {
    case admit
    case excludedFolder
    case tombstoned
}

enum AgentHistorySkipReason: Equatable, Sendable {
    case excluded
    case tombstoned
    case child
    case invalidSessionID
    case unsupportedFormat(String)
    case unreadable(String)
}

enum AgentHistorySourceProblem: Equatable, Sendable {
    case rootMissing
    case permissionDenied
    case busy
    case unreadableDatabase(code: Int32)
    case unsupportedFormat(String)
    case unsupportedSchema(String)
    case metadataFromTranscripts
    case discoveryFailed
}

struct AgentHistoryIngestDiagnostics: Equatable, Sendable {
    var malformedLines = 0
    var oversizedLines = 0
    var skippedRecords = 0
    var skippedSessions: [String: AgentHistorySkipReason] = [:]
}

/// The result of ingesting one slice of a unit. Applied in one transaction by the indexer.
struct AgentHistoryIngestBatch: Sendable {
    var sessions: [AgentHistorySessionDraft] = []
    var messages: [AgentHistoryMessageDraft] = []
    var artifacts: [AgentHistoryArtifactDraft] = []
    /// Delete these sessions' messages and artifacts first, in the same transaction.
    var replaceContentOf: Set<String> = []
    /// Purge stored rows (became child, excluded or gone).
    var removedNativeIDs: Set<String> = []
    var rejected: [String: AgentHistoryAdmissionDecision] = [:]
    /// Metadata-only batches from a catalog unit (Codex `state`): `sessions` only update rows that
    /// are already stored and keep their `unit_key`, so the catalog never creates rows of its own
    /// and never re-points a session away from the transcript unit that owns it.
    var updatesExistingSessionsOnly = false
    /// Complete state to persist after this batch.
    var cursor: AgentHistoryCursor
    var hasMore: Bool
    var diagnostics = AgentHistoryIngestDiagnostics()
    var problem: AgentHistorySourceProblem? = nil
}
