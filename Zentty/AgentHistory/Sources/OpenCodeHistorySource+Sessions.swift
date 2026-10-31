import Foundation

/// Turns one opencode session read from both generations into drafts in a batch.
enum OpenCodeHistorySessionBuilder {
    /// opencode's titles before its title model has run ("New session - 2026-…",
    /// "Child session - …"): they fall back to the first prompt.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered.hasPrefix("new session - ") || lowered.hasPrefix("child session - ")
    }

    /// D17: v2 when `session_v2.version` starts with "2." or the v2 rows are newer than the v1 rows.
    static func generation(of content: OpenCodeHistorySessionContent) -> String {
        guard let v2 = content.v2 else {
            return "v1"
        }
        if content.v1 == nil || v2.version?.hasPrefix("2.") == true {
            return "v2"
        }
        guard let v2Tail = content.v2TailMs else {
            return "v1"
        }
        return v2Tail > (content.v1TailMs ?? Int64.min) ? "v2" : "v1"
    }

    /// Both generations' messages, deduped by id (newer `time_updated` wins, v2 on a tie),
    /// in `(time_created, id)` order.
    static func mergedMessages(_ content: OpenCodeHistorySessionContent) -> [OpenCodeHistoryMessage] {
        var byID: [String: OpenCodeHistoryMessage] = [:]
        for message in content.v1Messages {
            byID[message.id] = message
        }
        for message in content.v2Messages {
            if let existing = byID[message.id], existing.updatedMs > message.updatedMs {
                continue
            }
            byID[message.id] = message
        }
        return byID.values.sorted { lhs, rhs in
            lhs.createdMs == rhs.createdMs ? lhs.id < rhs.id : lhs.createdMs < rhs.createdMs
        }
    }

    /// The working directory the session is admitted and stored under: the primary
    /// generation's `directory`, else the other one's.
    static func cwd(of content: OpenCodeHistorySessionContent) -> String? {
        let generation = generation(of: content)
        let primary = generation == "v2" ? (content.v2 ?? content.v1) : (content.v1 ?? content.v2)
        let secondary = generation == "v2" ? content.v1 : content.v2
        return (primary?.directory ?? secondary?.directory).map { AgentHistoryPath.canonical($0) }
    }

    /// Adds the session to `batch` (or records why it was skipped). Returns the indexed text's
    /// UTF-8 byte count for the batch's source-bytes cap.
    static func add(
        _ content: OpenCodeHistorySessionContent,
        nativeID: String,
        to batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext
    ) -> Int {
        if content.v1?.parentID != nil || content.v2?.parentID != nil {
            batch.diagnostics.skippedSessions[nativeID] = .child
            batch.removedNativeIDs.insert(nativeID)
            return 0
        }

        let generation = generation(of: content)
        guard let primary = generation == "v2" ? (content.v2 ?? content.v1) : (content.v1 ?? content.v2) else {
            return 0
        }
        let secondary = generation == "v2" ? content.v1 : content.v2
        let cwd = cwd(of: content)

        let decision = context.admission.decide(agent: .opencode, nativeID: nativeID, cwd: cwd)
        guard decision == .admit else {
            batch.rejected[nativeID] = decision
            batch.diagnostics.skippedSessions[nativeID] = decision == .tombstoned ? .tombstoned : .excluded
            batch.removedNativeIDs.insert(nativeID)
            return 0
        }

        var draft = AgentHistorySessionDraft(nativeID: nativeID)
        draft.cwd = cwd
        if let cwd, let repository = context.repositories.identity(for: cwd) {
            draft.repoRoot = repository.repoRoot
            draft.mainRepoRoot = repository.mainRepoRoot
        }
        draft.generation = generation
        draft.createdAtMs = [primary.createdMs, secondary?.createdMs].compactMap { $0 }.min()
        draft.updatedAtMs = [primary.updatedMs, secondary?.updatedMs].compactMap { $0 }.max()
        draft.archived = primary.archivedMs != nil

        var builder = AgentHistoryBatchBuilder(session: draft, firstSeq: 0, context: context)
        if let title = primary.title ?? secondary?.title, !isPlaceholderTitle(title) {
            builder.noteTitle(title, kind: .generated)
        }

        let base = draft.repoRoot ?? cwd
        var bytes = 0
        var latestModel: String?
        var latestEffort: String?
        for message in mergedMessages(content) {
            let text = message.texts.joined(separator: "\n\n")
            switch message.kind {
            case .user:
                if builder.addMessage(role: .user, atMs: message.createdMs, rawText: text) {
                    bytes += text.utf8.count
                    if let display = AgentHistoryDisplayText.displayText(text) {
                        builder.noteFirstPrompt(display)
                    }
                }
            case .assistant:
                if builder.addMessage(role: .agent, atMs: message.createdMs, rawText: text) {
                    bytes += text.utf8.count
                }
                if let model = modelName(provider: message.modelProvider, id: message.modelID) {
                    latestModel = model
                }
            case .shell:
                break
            }
            if let effort = AgentRootMetadataResolver.normalizedModel(message.variant) {
                latestEffort = effort
            }
            for tool in message.tools {
                addArtifacts(for: tool, base: base, atMs: message.createdMs, to: &builder)
            }
        }

        var session = builder.session
        session.model = latestModel ?? modelName(provider: primary.modelProvider, id: primary.modelID)
        session.effort = latestEffort ?? AgentRootMetadataResolver.normalizedModel(primary.modelVariant)
        let (messages, artifacts) = builder.drafts()
        batch.sessions.append(session)
        batch.messages.append(contentsOf: messages)
        batch.artifacts.append(contentsOf: artifacts)
        batch.replaceContentOf.insert(nativeID)
        return bytes
    }

    static func modelName(provider: String?, id: String?) -> String? {
        guard let id = AgentRootMetadataResolver.normalizedModel(id) else {
            return nil
        }
        guard let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty else {
            return id
        }
        return AgentRootMetadataResolver.normalizedModel("\(provider)/\(id)")
    }

    /// `bash`/`shell` commands (plus commit hashes from `git commit` output), `edit`/`write`/
    /// `multiedit` file paths and `apply_patch` file headers.
    private static func addArtifacts(
        for tool: OpenCodeHistoryToolCall,
        base: String?,
        atMs: Int64,
        to builder: inout AgentHistoryBatchBuilder
    ) {
        switch tool.name {
        case "bash", "shell":
            guard let raw = tool.command, let command = AgentHistoryArtifactExtractor.command(raw) else {
                return
            }
            builder.addArtifact(.command, rawValue: command, atMs: atMs)
            if let output = tool.output, AgentHistoryArtifactExtractor.isGitCommitCommand(raw) {
                for hash in AgentHistoryArtifactExtractor.commitHashes(inGitOutput: output) {
                    builder.addArtifact(.commit, rawValue: hash, atMs: atMs)
                }
            }
        case "edit", "write", "multiedit":
            if let raw = tool.filePath, let path = AgentHistoryArtifactExtractor.path(raw, relativeTo: base) {
                builder.addArtifact(.path, rawValue: path, atMs: atMs)
            }
        case "apply_patch":
            for raw in AgentHistoryArtifactExtractor.applyPatchPaths(tool.patchText ?? "") {
                if let path = AgentHistoryArtifactExtractor.path(raw, relativeTo: base) {
                    builder.addArtifact(.path, rawValue: path, atMs: atMs)
                }
            }
        default:
            break
        }
    }
}
