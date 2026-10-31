import Darwin
import Foundation

/// Grok sessions under `<root>/sessions/<percent-encoded cwd>/<session id>/`.
///
/// Each session directory is one `.directory` unit keyed `sessions/<enc>/<id>`. Its identity is
/// `chat_history.jsonl`'s stat with `mtimeNs = max(chat_history.jsonl, summary.json)`; the cursor's
/// byte offset is into `chat_history.jsonl` and its `watermark` is the `summary.json` mtime seen
/// at the last ingest, so a summary-only change (a generated title) re-reads metadata (A-6).
///
/// - `summary.json` gives the metadata: `chat_format_version` (only 1 is understood),
///   `session_kind` (`subagent` sessions are children and never stored; `headless` ones are
///   indexed, D12), `info.cwd`, `generated_title`, `current_model_id`, `reasoning_effort`,
///   `head_branch`, `created_at`, `last_active_at`.
/// - `chat_history.jsonl` gives messages and artifacts (`GrokHistorySource+Records.swift`).
/// - `events.jsonl` `turn_started` records give prompt times (`GrokTurnTimeline`).
///
/// Confined to the indexer queue; the turn-timeline cache is the only shared state and is
/// guarded by its own lock.
final class GrokHistorySource: AgentHistorySource, @unchecked Sendable {
    static let chatFileName = "chat_history.jsonl"
    static let summaryFileName = "summary.json"
    static let eventsFileName = "events.jsonl"
    static let supportedFormatVersion = 1
    /// `summary.json` is a few KB; anything far larger is not a Grok summary.
    static let maxSummaryBytes = 1 << 20

    let root: AgentHistorySourceRoot
    let adapterVersion = 1
    var agent: AgentHistoryAgent { .grok }

    let timelines = GrokTurnTimelineCache()
    private let sessionsPath: String

    init(root: AgentHistorySourceRoot) {
        self.root = root
        self.sessionsPath = root.path + "/sessions"
    }

    var watchPaths: [String] {
        [sessionsPath]
    }

    // MARK: - Discovery

    func discoverUnits() throws -> [AgentHistoryUnit] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        var units: [AgentHistoryUnit] = []
        for encoded in try fileManager.contentsOfDirectory(atPath: sessionsPath) where !encoded.hasPrefix(".") {
            let projectPath = sessionsPath + "/" + encoded
            guard let entries = try? fileManager.contentsOfDirectory(atPath: projectPath) else {
                continue
            }
            for entry in entries where !entry.hasPrefix(".") {
                guard
                    let nativeID = agent.normalizedSessionID(entry),
                    let identity = Self.unitIdentity(directory: projectPath + "/" + entry)
                else {
                    continue
                }
                units.append(AgentHistoryUnit(
                    key: "sessions/\(encoded)/\(entry)",
                    path: projectPath + "/" + entry,
                    kind: .directory,
                    identity: identity,
                    nativeSessionID: nativeID
                ))
            }
        }
        return units
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        for prefix in sessionsPrefixes where path.hasPrefix(prefix) {
            let components = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2 || components.count == 3 else {
                return nil
            }
            if components.count == 3, components[2] != Self.chatFileName, components[2] != Self.summaryFileName {
                return nil
            }
            guard !components[0].isEmpty, agent.normalizedSessionID(String(components[1])) != nil else {
                return nil
            }
            return .unit("sessions/\(components[0])/\(components[1])")
        }
        return nil
    }

    func estimatedSessionCount() -> Int? {
        (try? discoverUnits())?.count
    }

    /// The sessions dir as configured and as realpath(3) sees it (FSEvents reports the latter).
    private var sessionsPrefixes: [String] {
        var prefixes = [sessionsPath + "/"]
        if let resolved = realpath(sessionsPath, nil) {
            let real = String(cString: resolved) + "/"
            free(resolved)
            if real != prefixes[0] {
                prefixes.append(real)
            }
        }
        return prefixes
    }

    // MARK: - Change classification (A-6)

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        let chatPath = unit.path + "/" + Self.chatFileName
        let generic = AgentHistoryUnitChangeClassifier.classify(cursor: cursor, current: unit.identity) {
            AgentHistoryFileFingerprint.compute(path: chatPath, endOffset: cursor?.byteOffset ?? 0)
        }
        guard generic == .unchanged, let cursor, !cursor.isRejected else {
            return generic
        }
        if let summary = AgentHistoryFileIdentity.stat(path: unit.path + "/" + Self.summaryFileName),
           summary.mtimeNs > (cursor.watermark ?? Int64.min) {
            return .append(fromOffset: cursor.byteOffset, nextSeq: cursor.nextSeq)
        }
        return .unchanged
    }

    /// Directory identity re-read from `chat_history.jsonl` and `summary.json`.
    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit {
        AgentHistoryUnit(
            key: unit.key,
            path: unit.path,
            kind: unit.kind,
            identity: Self.unitIdentity(directory: unit.path),
            nativeSessionID: unit.nativeSessionID
        )
    }

    /// `chat_history.jsonl`'s stat with the newer of its and `summary.json`'s mtime; nil
    /// without a chat history.
    static func unitIdentity(directory: String) -> AgentHistoryFileIdentity? {
        guard let chat = AgentHistoryFileIdentity.stat(path: directory + "/" + chatFileName) else {
            return nil
        }
        let summaryMtime = AgentHistoryFileIdentity.stat(path: directory + "/" + summaryFileName)?.mtimeNs ?? chat.mtimeNs
        return AgentHistoryFileIdentity(dev: chat.dev, ino: chat.ino, size: chat.size, mtimeNs: max(chat.mtimeNs, summaryMtime))
    }

    // MARK: - Ingest

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        let directory = unit.path
        let chatPath = directory + "/" + Self.chatFileName
        // A-5: identity and the summary watermark are taken before reading.
        let identity = Self.unitIdentity(directory: directory)
        let summaryMtime = AgentHistoryFileIdentity.stat(path: directory + "/" + Self.summaryFileName)?.mtimeNs
        let base = cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key)

        let startOffset: Int64
        let firstSeq: Int
        var state: GrokCursorState
        switch mode {
        case .fromStart:
            startOffset = 0
            firstSeq = 0
            state = GrokCursorState()
        case let .fromOffset(offset, nextSeq):
            startOffset = max(offset, 0)
            firstSeq = max(nextSeq, 0)
            state = GrokCursorState.decode(cursor?.adapterState)
        }

        var batch = AgentHistoryIngestBatch(cursor: base, hasMore: false)
        batch.cursor = base.advanced(
            identity: identity,
            byteOffset: startOffset,
            nextSeq: firstSeq,
            fingerprint: AgentHistoryFileFingerprint.compute(path: chatPath, endOffset: startOffset),
            adapterState: state.encoded()
        )
        batch.cursor.watermark = summaryMtime

        guard let nativeID = unit.nativeSessionID.flatMap(agent.normalizedSessionID) else {
            let raw = unit.nativeSessionID ?? unit.key
            batch.diagnostics.skippedSessions[raw] = .invalidSessionID
            return batch
        }
        guard let summary = GrokSessionSummary.load(path: directory + "/" + Self.summaryFileName) else {
            // Mid-creation or unreadable: keep the offset so the next change retries.
            batch.diagnostics.skippedSessions[nativeID] = .unreadable(Self.summaryFileName)
            return batch
        }
        if let version = summary.formatVersion, version != Self.supportedFormatVersion {
            let reason = "Grok format \(version)"
            batch.problem = .unsupportedFormat(reason)
            batch.diagnostics.skippedSessions[nativeID] = .unsupportedFormat(reason)
            return batch
        }
        if summary.isSubagent {
            batch.diagnostics.skippedSessions[nativeID] = .child
            batch.removedNativeIDs = [nativeID]
            let end = identity?.size ?? startOffset
            batch.cursor.byteOffset = end
            batch.cursor.fingerprint = AgentHistoryFileFingerprint.compute(path: chatPath, endOffset: end)
            return batch
        }

        let cwd = (summary.cwd ?? Self.projectCwd(sessionDirectory: directory)).map { AgentHistoryPath.canonical($0) }
        var decision = context.admission.decide(agent: agent, nativeID: nativeID, cwd: cwd)
        if decision == .admit, cwd == nil, !context.admission.exclusions.isEmpty {
            // No usable folder at all: an exclusion might cover it, so hold the session back
            // (as excluded) rather than let it bypass the user's excluded folders.
            decision = .excludedFolder
        }
        guard decision == .admit else {
            batch.rejected[nativeID] = decision
            return batch
        }

        var session = AgentHistorySessionDraft(nativeID: nativeID)
        session.cwd = cwd
        if let cwd, let repository = context.repositories.identity(for: cwd) {
            session.repoRoot = repository.repoRoot
            session.mainRepoRoot = repository.mainRepoRoot
        }
        session.branch = summary.branch
        session.model = AgentRootMetadataResolver.normalizedModel(summary.model)
        session.effort = summary.effort
        session.transcriptPath = chatPath
        session.createdAtMs = summary.createdAtMs
        session.updatedAtMs = summary.lastActiveAtMs

        var builder = AgentHistoryBatchBuilder(session: session, firstSeq: firstSeq, context: context)
        builder.noteTitle(summary.title, kind: .generated)

        let fallbackMs = identity.map { $0.mtimeNs / 1_000_000 } ?? 0
        var reader = GrokChatReader(
            builder: builder,
            state: state,
            turns: timelines.turns(eventsPath: directory + "/" + Self.eventsFileName),
            pathBase: session.repoRoot ?? cwd,
            interpolation: GrokTimeInterpolation(
                startMs: summary.createdAtMs ?? fallbackMs,
                endMs: summary.lastActiveAtMs ?? summary.createdAtMs ?? fallbackMs,
                size: identity?.size ?? 0
            )
        )
        let progress = try reader.read(path: chatPath, from: startOffset, context: context)
        builder = reader.builder
        state = reader.state

        let (messages, artifacts) = builder.drafts()
        batch.sessions = [builder.session]
        batch.messages = messages
        batch.artifacts = artifacts
        if mode == .fromStart {
            batch.replaceContentOf = [nativeID]
        }
        batch.diagnostics.malformedLines = progress.malformedLines
        batch.diagnostics.oversizedLines = progress.oversizedLines
        batch.hasMore = progress.hasMore
        batch.cursor = base.advanced(
            identity: identity,
            byteOffset: progress.committedOffset,
            nextSeq: builder.nextSeq,
            fingerprint: AgentHistoryFileFingerprint.compute(path: chatPath, endOffset: progress.committedOffset),
            adapterState: state.encoded()
        )
        batch.cursor.watermark = summaryMtime
        return batch
    }
}

extension GrokHistorySource {
    /// The cwd Grok encoded in the project folder name (`sessions/<percent-encoded cwd>/<id>`),
    /// used when `summary.json` has no absolute `info.cwd`; nil unless it decodes to an
    /// absolute path.
    static func projectCwd(sessionDirectory: String) -> String? {
        let encoded = ((sessionDirectory as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("/") else {
            return nil
        }
        return decoded
    }
}

/// The parts of `summary.json` the adapter uses.
struct GrokSessionSummary: Equatable {
    var formatVersion: Int?
    var sessionKind: String?
    var cwd: String?
    var title: String?
    var model: String?
    var effort: String?
    var branch: String?
    var createdAtMs: Int64?
    var lastActiveAtMs: Int64?

    var isSubagent: Bool {
        sessionKind == "subagent"
    }

    /// nil when the file is missing, too large or not a JSON object.
    static func load(path: String) -> GrokSessionSummary? {
        guard
            let identity = AgentHistoryFileIdentity.stat(path: path),
            identity.size <= GrokHistorySource.maxSummaryBytes,
            let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return GrokSessionSummary(object: object)
    }

    init(object: [String: Any]) {
        formatVersion = (object["chat_format_version"] as? NSNumber)?.intValue
        sessionKind = Self.string(object["session_kind"])
        cwd = Self.string((object["info"] as? [String: Any])?["cwd"]).flatMap { $0.hasPrefix("/") ? $0 : nil }
        title = Self.string(object["generated_title"])
        model = Self.string(object["current_model_id"])
        effort = Self.string(object["reasoning_effort"])?.lowercased()
        branch = Self.string(object["head_branch"])
        createdAtMs = Self.string(object["created_at"]).flatMap { AgentHistoryTimestamp.milliseconds(iso8601: $0) }
        lastActiveAtMs = (Self.string(object["last_active_at"]) ?? Self.string(object["updated_at"]))
            .flatMap { AgentHistoryTimestamp.milliseconds(iso8601: $0) }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// What the adapter remembers between batches of one session (`cursor.adapterState`).
struct GrokCursorState: Codable, Equatable {
    /// Start time of the turn being read and the `seq` it is counted from.
    var turnAtMs: Int64?
    var turnSeq = -1
    /// The latest `turn_started` time already matched to a prompt.
    var lastTurnStartMs: Int64?
    /// Typed prompts seen so far (the first becomes the `first_prompt` title).
    var promptCount = 0
    /// Tool call ids of `git commit` commands whose result has not been read yet.
    var pendingCommitCallIDs: [String] = []

    static let maxPendingCommitCalls = 32

    static func decode(_ data: Data?) -> GrokCursorState {
        guard let data, let state = try? JSONDecoder().decode(GrokCursorState.self, from: data) else {
            return GrokCursorState()
        }
        return state
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
