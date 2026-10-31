import Darwin
import Foundation

/// Codex history at one root (`$CODEX_HOME` or `~/.codex`).
///
/// Units:
/// - one per rollout under `sessions/**` or `archived_sessions/**`, plain (`.jsonl`) or
///   compressed (`.jsonl.zst`), keyed `rollout:<thread id>` from the file-name tail so the key
///   survives archiving and compression. When both forms exist (mid-compression) the plain
///   file wins; otherwise the newer one.
/// - the synthetic `.database` unit `state` for `state_5.sqlite`, which carries thread
///   renames and archive flags that do not touch the rollout.
///
/// Child threads (subagents, guardian reviews) are dropped at discovery when the thread
/// catalog knows them, else at ingest from the rollout's `session_meta` (D13).
///
/// Confined to the indexer queue; the zstd continuations and the catalog cache sit behind locks
/// so the instance stays `Sendable`.
final class CodexHistorySource: AgentHistorySource, @unchecked Sendable {
    static let stateUnitKey = "state"
    static let rolloutKeyPrefix = "rollout:"
    static let sessionsDirectory = "sessions"
    static let archivedDirectory = "archived_sessions"

    let agent = AgentHistoryAgent.codex
    let root: AgentHistorySourceRoot
    let adapterVersion = 1
    let catalog: CodexThreadCatalog

    /// Root spellings that event paths may start with: the canonical root and its realpath
    /// (FSEvents reports `/private/var/…` where the canonical form is `/var/…`).
    private let rootPrefixes: [String]
    private let continuationLock = NSLock()
    /// Parked decompressing readers, oldest first, at most one per unit key and
    /// `maxZstdContinuations` in all, so a live compressed rollout and a compressed backfill
    /// stream do not evict each other.
    private var zstdContinuations: [CodexZstdContinuation] = []
    /// Fresh decoders opened (a cache miss decompresses from byte 0); read by tests.
    private var openedZstdStreams = 0

    init(root: AgentHistorySourceRoot) {
        self.root = root
        self.catalog = CodexThreadCatalog(rootPath: root.path)
        var prefixes = [root.path]
        if let real = realpath(root.path, nil) {
            let resolved = String(cString: real)
            free(real)
            if resolved != root.path {
                prefixes.append(resolved)
            }
        }
        self.rootPrefixes = prefixes
    }

    var watchPaths: [String] { [root.path] }

    var databasePath: String { catalog.databasePath }

    // MARK: - Discovery

    func discoverUnits() throws -> [AgentHistoryUnit] {
        let childIDs = catalog.lookup().snapshot?.childIDs ?? []
        var units = rolloutUnits().filter { unit in
            !childIDs.contains(unit.nativeSessionID ?? "")
        }
        if let identity = AgentHistoryFileIdentity.stat(path: databasePath) {
            units.append(AgentHistoryUnit(
                key: Self.stateUnitKey, path: databasePath, kind: .database, identity: identity, nativeSessionID: nil
            ))
        }
        return units
    }

    /// Stat-only count of rollouts (children included: telling them apart needs the catalog,
    /// which is not opened before consent, D11).
    func estimatedSessionCount() -> Int? {
        rolloutUnits().count
    }

    /// Every rollout file, one unit per thread id.
    private func rolloutUnits() -> [AgentHistoryUnit] {
        var byKey: [String: AgentHistoryUnit] = [:]
        for directory in [Self.sessionsDirectory, Self.archivedDirectory] {
            let base = (root.path as NSString).appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(atPath: base) else {
                continue
            }
            while let relative = enumerator.nextObject() as? String {
                let name = (relative as NSString).lastPathComponent
                guard let parsed = Self.parseRolloutFileName(name) else {
                    continue
                }
                let path = (base as NSString).appendingPathComponent(relative)
                guard let identity = AgentHistoryFileIdentity.stat(path: path) else {
                    continue
                }
                let unit = AgentHistoryUnit(
                    key: Self.rolloutKeyPrefix + parsed.threadID,
                    path: path,
                    kind: parsed.isCompressed ? .zstdJSONL : .jsonl,
                    identity: identity,
                    nativeSessionID: parsed.threadID
                )
                if let existing = byKey[unit.key], !Self.prefers(unit, over: existing) {
                    continue
                }
                byKey[unit.key] = unit
            }
        }
        return Array(byKey.values)
    }

    private static func prefers(_ candidate: AgentHistoryUnit, over existing: AgentHistoryUnit) -> Bool {
        if candidate.kind != existing.kind {
            return candidate.kind == .jsonl
        }
        return (candidate.identity?.mtimeNs ?? 0) > (existing.identity?.mtimeNs ?? 0)
    }

    /// `rollout-<timestamp>-<uuid>.jsonl[.zst]` → normalized thread id. nil for other names
    /// and for tails that are not a valid Codex id.
    static func parseRolloutFileName(_ name: String) -> (threadID: String, isCompressed: Bool)? {
        guard name.hasPrefix("rollout-") else {
            return nil
        }
        let stem: Substring
        let isCompressed: Bool
        if name.hasSuffix(".jsonl.zst") {
            stem = name.dropLast(".jsonl.zst".count)
            isCompressed = true
        } else if name.hasSuffix(".jsonl") {
            stem = name.dropLast(".jsonl".count)
            isCompressed = false
        } else {
            return nil
        }
        guard stem.count >= 36 + "rollout-".count,
              let id = AgentHistoryAgent.codex.normalizedSessionID(String(stem.suffix(36))),
              UUID(uuidString: id) != nil else {
            return nil
        }
        return (id, isCompressed)
    }

    // MARK: - Events

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        guard let relative = relativePath(path) else {
            return nil
        }
        if relative == CodexThreadCatalog.databaseFileName || relative == CodexThreadCatalog.databaseFileName + "-wal" {
            return .database(Self.stateUnitKey)
        }
        guard relative.hasPrefix(Self.sessionsDirectory + "/") || relative.hasPrefix(Self.archivedDirectory + "/"),
              let parsed = Self.parseRolloutFileName((relative as NSString).lastPathComponent) else {
            return nil
        }
        return .unit(Self.rolloutKeyPrefix + parsed.threadID)
    }

    private func relativePath(_ path: String) -> String? {
        for prefix in rootPrefixes where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return nil
    }

    // MARK: - Change classification (A-6)

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        switch unit.kind {
        case .database:
            guard cursor != nil else {
                return .new
            }
            return AgentHistoryFileIdentity.stat(path: unit.path) == nil ? .missing : .append(fromOffset: 0, nextSeq: 0)
        case .zstdJSONL:
            return classifyCompressed(unit: unit, cursor: cursor)
        case .jsonl, .directory:
            return AgentHistoryUnitChangeClassifier.classify(cursor: cursor, current: unit.identity) {
                AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: cursor?.byteOffset ?? 0)
            }
        }
    }

    /// Compressed rollouts compare **decompressed** offsets and fingerprints only:
    /// 1. no cursor → `.new`; file gone → `.missing`; rejected cursor → generic rule
    /// 2. same identity → `.unchanged`, or a resume `.append` when the last read stopped short
    /// 3. cursor of the plain file this one replaced, and the frame content size equals its
    ///    offset → `.identityOnly` (Codex compressed a fully indexed rollout)
    /// 4. content at least as long as the offset and the window before it unchanged → `.append`
    /// 5. otherwise → `.rewrite`
    private func classifyCompressed(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        guard let cursor else {
            return .new
        }
        guard let current = unit.identity else {
            return .missing
        }
        if cursor.isRejected {
            return AgentHistoryUnitChangeClassifier.classify(cursor: cursor, current: current) { nil }
        }
        let state = CodexRolloutState.decode(cursor.adapterState)
        if cursor.identity == current {
            return state?.reachedEOF == false ? .append(fromOffset: cursor.byteOffset, nextSeq: cursor.nextSeq) : .unchanged
        }
        let contentSize = ZstdByteSource.frameContentSize(path: unit.path)
        if state?.lastKind == .jsonl, let contentSize, contentSize == cursor.byteOffset {
            return .identityOnly
        }
        if let contentSize, contentSize < cursor.byteOffset {
            return .rewrite
        }
        guard let fingerprint = ZstdByteSource.fingerprint(path: unit.path, endOffset: cursor.byteOffset),
              fingerprint == cursor.fingerprint else {
            return .rewrite
        }
        return .append(fromOffset: cursor.byteOffset, nextSeq: cursor.nextSeq)
    }

    // MARK: - Ingest

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        switch unit.kind {
        case .database:
            return ingestCatalog(unit: unit, cursor: cursor, context: context)
        case .jsonl, .zstdJSONL:
            return try ingestRollout(unit: unit, cursor: cursor, mode: mode, context: context)
        case .directory:
            var batch = AgentHistoryIngestBatch(cursor: cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key), hasMore: false)
            batch.problem = .unsupportedFormat("Codex directory unit")
            return batch
        }
    }

    // MARK: - Zstd continuation cache

    static let maxZstdContinuations = 2

    /// Takes the cached stream of `key` when it continues exactly where the unit was left. Any
    /// stream of `key` is dropped either way (it is stale when it does not match).
    func takeZstdContinuation(key: String, identity: AgentHistoryFileIdentity, offset: Int64) -> CodexZstdContinuation? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        guard let index = zstdContinuations.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        let continuation = zstdContinuations.remove(at: index)
        guard continuation.identity == identity, continuation.offset == offset else {
            return nil
        }
        return continuation
    }

    /// Parks a stream, replacing any other stream of the same key and evicting the oldest one
    /// past `maxZstdContinuations`.
    func storeZstdContinuation(_ continuation: CodexZstdContinuation) {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        zstdContinuations.removeAll { $0.key == continuation.key }
        zstdContinuations.append(continuation)
        if zstdContinuations.count > Self.maxZstdContinuations {
            zstdContinuations.removeFirst(zstdContinuations.count - Self.maxZstdContinuations)
        }
    }

    var zstdStreamOpenCount: Int {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return openedZstdStreams
    }

    func noteZstdStreamOpened() {
        continuationLock.lock()
        openedZstdStreams += 1
        continuationLock.unlock()
    }

    func dropZstdContinuation(key: String) {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        zstdContinuations.removeAll { $0.key == key }
    }
}

// MARK: - Catalog unit

extension CodexHistorySource {
    /// Metadata-only drafts for non-child threads changed since the cursor's watermark,
    /// oldest first, `limits.messages` per batch. Keyset `(updated_at_ms, id)`: the watermark
    /// plus the last id in `adapterState`. Only rows that are already indexed are updated
    /// (`updatesExistingSessionsOnly`); new threads arrive with their rollouts.
    func ingestCatalog(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?, context: AgentHistoryIngestContext) -> AgentHistoryIngestBatch {
        let base = cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key)
        let identity = AgentHistoryFileIdentity.stat(path: unit.path)
        let lookup = catalog.lookup()
        var batch = AgentHistoryIngestBatch(cursor: base, hasMore: false)
        batch.problem = lookup.problem
        batch.updatesExistingSessionsOnly = true
        guard let snapshot = lookup.snapshot else {
            batch.cursor.identity = identity
            return batch
        }

        let watermark = base.watermark ?? Int64.min
        let lastID = base.adapterState.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let pending = snapshot.rows.values
            .filter { row in
                let updated = row.updatedAtMs ?? 0
                return !row.isChild && (updated > watermark || (updated == watermark && row.id > lastID))
            }
            .sorted { ($0.updatedAtMs ?? 0, $0.id) < ($1.updatedAtMs ?? 0, $1.id) }
        let page = pending.prefix(max(1, context.limits.messages))

        for row in page {
            if context.isCancelled() {
                break
            }
            let cwd = row.cwd.map { AgentHistoryPath.canonical($0) }
            switch context.admission.decide(agent: .codex, nativeID: row.id, cwd: cwd) {
            case .admit:
                var builder = AgentHistoryBatchBuilder(session: AgentHistorySessionDraft(nativeID: row.id), firstSeq: 0, context: context)
                Self.applyCatalogRow(row, to: &builder, context: context)
                batch.sessions.append(builder.session)
            case .excludedFolder:
                batch.diagnostics.skippedSessions[row.id] = .excluded
            case .tombstoned:
                batch.diagnostics.skippedSessions[row.id] = .tombstoned
            }
            batch.cursor.watermark = row.updatedAtMs ?? 0
            batch.cursor.adapterState = Data(row.id.utf8)
        }
        let delivered = page.count
        batch.hasMore = delivered < pending.count && !context.isCancelled()
        batch.cursor.identity = identity
        batch.cursor.isRejected = false
        return batch
    }

    /// Titles (redacted by the builder), folder, repository and settings from a catalog row.
    static func applyCatalogRow(_ row: CodexThreadRow, to builder: inout AgentHistoryBatchBuilder, context: AgentHistoryIngestContext) {
        if let raw = row.firstUserMessage,
           let display = AgentHistoryDisplayText.displayText(context.redactor.redact(raw)) {
            builder.noteFirstPrompt(display)
        }
        builder.noteTitle(row.title, kind: .generated)
        builder.noteTitle(row.name, kind: .custom)
        if let cwd = row.cwd {
            applyFolder(AgentHistoryPath.canonical(cwd), to: &builder.session, context: context)
        }
        builder.session.branch = row.branch ?? builder.session.branch
        builder.session.model = row.model ?? builder.session.model
        builder.session.effort = row.effort ?? builder.session.effort
        builder.session.archived = row.archived
        builder.session.createdAtMs = row.createdAtMs ?? builder.session.createdAtMs
        builder.session.updatedAtMs = row.updatedAtMs ?? builder.session.updatedAtMs
    }

    /// Sets a canonical `cwd` and the repository identity resolved for it.
    static func applyFolder(_ canonicalCwd: String, to session: inout AgentHistorySessionDraft, context: AgentHistoryIngestContext) {
        session.cwd = canonicalCwd
        if let identity = context.repositories.identity(for: canonicalCwd) {
            session.repoRoot = identity.repoRoot
            session.mainRepoRoot = identity.mainRepoRoot
        }
    }
}
