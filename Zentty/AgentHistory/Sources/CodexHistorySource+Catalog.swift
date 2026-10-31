import Foundation

/// `cursor.adapterState` of the Codex `state` unit.
struct CodexCatalogUnitState: Codable, Equatable, Sendable {
    /// Keyset tie-breaker: the last id delivered at `cursor.watermark`.
    var lastID = ""
    /// `flagDigest` of every non-child thread that is archived or has a custom name, as of the
    /// last complete pass. A thread whose digest changed, appeared or disappeared is re-emitted.
    var flags: [String: UInt32] = [:]

    static func decode(_ data: Data?) -> CodexCatalogUnitState {
        data.flatMap { try? JSONDecoder().decode(CodexCatalogUnitState.self, from: $0) } ?? CodexCatalogUnitState()
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// FNV-1a over the archive flag and the custom name (raw names never reach the cursor).
    static func flagDigest(_ row: CodexThreadRow) -> UInt32 {
        let text = (row.archived ? "1" : "0") + "\u{0}" + (row.name ?? "")
        return UInt32(truncatingIfNeeded: AgentHistoryFileFingerprint.hash(Array(text.utf8)))
    }
}

// MARK: - Catalog unit

extension CodexHistorySource {
    /// Metadata-only drafts for non-child threads, `limits.messages` per batch:
    /// - rows changed since the cursor's watermark, oldest first. Keyset `(updated_at_ms, id)`:
    ///   the watermark plus `lastID` in `adapterState`.
    /// - every thread whose archive flag or custom name differs from the last pass (`flags` in
    ///   `adapterState`), whatever its `updated_at_ms`: Codex archives, unarchives and renames
    ///   threads without bumping it, and an archive move does not change the rollout's content.
    ///
    /// Only rows that are already indexed are updated (`updatesExistingSessionsOnly`); new threads
    /// arrive with their rollouts.
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

        var state = CodexCatalogUnitState.decode(base.adapterState)
        let watermark = base.watermark ?? Int64.min
        let threads = snapshot.rows.values.filter { !$0.isChild }
        let pending = threads
            .filter { row in
                let updated = row.updatedAtMs ?? 0
                return updated > watermark || (updated == watermark && row.id > state.lastID)
            }
            .sorted { ($0.updatedAtMs ?? 0, $0.id) < ($1.updatedAtMs ?? 0, $1.id) }
        let page = pending.prefix(max(1, context.limits.messages))

        var flags: [String: UInt32] = [:]
        for row in threads where row.archived || row.name != nil {
            flags[row.id] = CodexCatalogUnitState.flagDigest(row)
        }
        let pageIDs = Set(page.map(\.id))
        let flipped = Set(flags.keys).union(state.flags.keys)
            .filter { flags[$0] != state.flags[$0] && !pageIDs.contains($0) }
            .sorted()
            .compactMap { id in snapshot.rows[id].flatMap { $0.isChild ? nil : $0 } }

        func deliver(_ row: CodexThreadRow) {
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
        }

        for row in page {
            if context.isCancelled() {
                break
            }
            deliver(row)
            batch.cursor.watermark = row.updatedAtMs ?? 0
            state.lastID = row.id
        }
        var deliveredFlips = true
        for row in flipped {
            if context.isCancelled() {
                deliveredFlips = false
                break
            }
            deliver(row)
        }
        if deliveredFlips, !context.isCancelled() {
            state.flags = flags
        }
        batch.hasMore = page.count < pending.count && !context.isCancelled()
        batch.cursor.adapterState = state.encoded()
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
