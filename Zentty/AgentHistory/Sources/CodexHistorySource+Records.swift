import Foundation

/// Turns rollout lines into messages, artifacts and session metadata for one thread.
///
/// Every line is sniffed first (top-level `type` and `timestamp`, then `payload.type` /
/// `payload.role`); only the records that can produce something are JSON-decoded:
/// - `session_meta` whose `payload.id` is this thread: `cwd`, `git.branch`, start time and,
///   without a catalog row, the child rules (`source.subagent`, `parent_thread_id`).
/// - `turn_context`: latest `model` / `effort` (fallback when the catalog has none).
/// - `response_item` `message`: `user` `input_text` and `assistant` `output_text` parts.
///   Skipped: other roles (`developer`), inherited parent messages
///   (`metadata.inherited_user_message`) and injected envelope parts.
/// - tool calls: `exec_command.cmd`, `shell`/`local_shell_call` commands → command artifacts;
///   `apply_patch` headers → path artifacts; outputs of pending `git commit` calls → commits.
///   PR links in assistant text → pr artifacts.
/// Everything else (`agent_message` (D20), `reasoning`, `compacted`, `event_msg`,
/// `token_usage_record`, `world_state`) is skipped without decoding.
struct CodexRolloutLineProcessor {
    enum Outcome: Equatable {
        case `continue`
        /// Admission rejected the thread (excluded folder or tombstone).
        case rejected
        /// The authoritative `session_meta` marks a child thread.
        case child
    }

    /// Leading markers of parts Codex injects into user messages.
    static let envelopePrefixes = [
        "# AGENTS.md", "<environment_context", "<user_instructions", "<role", "<user_action", "<skill", "<image",
    ]

    let nativeID: String
    let hasCatalogRow: Bool
    let catalogCwd: String?
    let context: AgentHistoryIngestContext
    var state: CodexRolloutState
    var builder: AgentHistoryBatchBuilder
    var diagnostics = AgentHistoryIngestDiagnostics()
    private(set) var decision: AgentHistoryAdmissionDecision?
    private var resolvedRepository = false
    private var artifactBase: String?

    init(
        nativeID: String,
        hasCatalogRow: Bool,
        catalogCwd: String?,
        context: AgentHistoryIngestContext,
        state: CodexRolloutState,
        builder: AgentHistoryBatchBuilder
    ) {
        self.nativeID = nativeID
        self.hasCatalogRow = hasCatalogRow
        self.catalogCwd = catalogCwd
        self.context = context
        self.state = state
        self.builder = builder
    }

    private var knownCwd: String? { catalogCwd ?? state.cwd }

    /// Decides before reading when the folder is known; otherwise only a tombstone can reject
    /// here and the folder check waits for `session_meta`. nil = not decided yet.
    mutating func decideEarly() -> AgentHistoryAdmissionDecision? {
        let early = context.admission.decide(agent: .codex, nativeID: nativeID, cwd: knownCwd)
        if early != .admit || knownCwd != nil {
            decision = early
        }
        return early
    }

    /// Decides once, with whatever folder is known by now.
    private mutating func admitted() -> Bool {
        if decision == nil {
            decision = context.admission.decide(agent: .codex, nativeID: nativeID, cwd: knownCwd)
        }
        return decision == .admit
    }

    mutating func process(_ line: UnsafeRawBufferPointer) -> Outcome {
        guard let top = JSONLineSniffer.topLevel(in: line, stringKeys: ["type", "timestamp"], flagKeys: [], presenceKeys: []),
              let type = top.strings["type"] else {
            diagnostics.malformedLines += 1
            return .continue
        }
        if let stamp = top.strings["timestamp"], let ms = AgentHistoryTimestamp.milliseconds(iso8601: stamp) {
            state.lastAtMs = ms
        }
        let atMs = state.lastAtMs ?? 0

        switch type {
        case "session_meta":
            return processSessionMeta(line, atMs: atMs)
        case "turn_context":
            if case let .string(model)? = JSONLineSniffer.value(at: [.key("payload"), .key("model")], in: line),
               let normalized = AgentRootMetadataResolver.normalizedModel(model) {
                state.model = normalized
            }
            if case let .string(effort)? = JSONLineSniffer.value(at: [.key("payload"), .key("effort")], in: line),
               !effort.isEmpty {
                state.effort = effort
            }
            return .continue
        case "response_item":
            return processResponseItem(line, atMs: atMs)
        default:
            return .continue
        }
    }

    // MARK: - Records

    private mutating func processSessionMeta(_ line: UnsafeRawBufferPointer, atMs: Int64) -> Outcome {
        guard let object = Self.decode(line), let payload = object["payload"] as? [String: Any] else {
            diagnostics.malformedLines += 1
            return .continue
        }
        guard let rawID = payload["id"] as? String,
              AgentHistoryAgent.codex.normalizedSessionID(rawID) == nativeID else {
            return .continue
        }
        if let cwd = Self.nonEmpty(payload["cwd"]) {
            state.cwd = AgentHistoryPath.canonical(cwd)
        }
        if let branch = Self.nonEmpty((payload["git"] as? [String: Any])?["branch"]) {
            state.branch = branch
        }
        let started = Self.nonEmpty(payload["timestamp"]).flatMap(AgentHistoryTimestamp.milliseconds(iso8601:)) ?? atMs
        state.startedAtMs = state.startedAtMs.map { min($0, started) } ?? started
        if !hasCatalogRow,
           (payload["source"] as? [String: Any])?["subagent"] != nil || Self.nonEmpty(payload["parent_thread_id"]) != nil {
            state.isChild = true
            return .child
        }
        return admitted() ? .continue : .rejected
    }

    private mutating func processResponseItem(_ line: UnsafeRawBufferPointer, atMs: Int64) -> Outcome {
        guard case let .string(payloadType)? = JSONLineSniffer.value(at: [.key("payload"), .key("type")], in: line) else {
            return .continue
        }
        switch payloadType {
        case "message":
            guard case let .string(role)? = JSONLineSniffer.value(at: [.key("payload"), .key("role")], in: line),
                  role == "user" || role == "assistant" else {
                return .continue
            }
            guard admitted() else {
                return .rejected
            }
            processMessage(line, isUser: role == "user", atMs: atMs)
        case "function_call", "custom_tool_call", "local_shell_call":
            guard admitted() else {
                return .rejected
            }
            processToolCall(line, payloadType: payloadType, atMs: atMs)
        case "function_call_output", "custom_tool_call_output":
            guard !state.pendingCommitCallIDs.isEmpty,
                  state.pendingCommitCallIDs.contains(where: { JSONLineSniffer.contains($0, in: line) }) else {
                return .continue
            }
            guard admitted() else {
                return .rejected
            }
            processToolOutput(line, atMs: atMs)
        default:
            break
        }
        return .continue
    }

    private mutating func processMessage(_ line: UnsafeRawBufferPointer, isUser: Bool, atMs: Int64) {
        guard let object = Self.decode(line),
              let payload = CodexTranscriptQuestionExtractor.responsePayload(from: object) else {
            diagnostics.malformedLines += 1
            return
        }
        if (object["metadata"] as? [String: Any])?["inherited_user_message"] as? Bool == true {
            return
        }
        let partType = isUser ? "input_text" : "output_text"
        let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
            guard part["type"] as? String == partType, let text = part["text"] as? String else {
                return nil
            }
            if isUser, Self.isEnvelopePart(text) {
                return nil
            }
            return text
        }
        guard !texts.isEmpty else {
            return
        }
        let text = texts.joined(separator: "\n\n")
        guard builder.addMessage(role: isUser ? .user : .agent, atMs: atMs, rawText: text) else {
            diagnostics.skippedRecords += 1
            return
        }
        if isUser {
            if let display = AgentHistoryDisplayText.displayText(context.redactor.redact(text)) {
                builder.noteFirstPrompt(display)
            }
        } else {
            for url in AgentHistoryArtifactExtractor.pullRequestURLs(in: text) {
                builder.addArtifact(.pr, rawValue: url, atMs: atMs)
            }
        }
    }

    private mutating func processToolCall(_ line: UnsafeRawBufferPointer, payloadType: String, atMs: Int64) {
        guard let object = Self.decode(line),
              let payload = CodexTranscriptQuestionExtractor.responsePayload(from: object) else {
            diagnostics.malformedLines += 1
            return
        }
        let name = payload["name"] as? String ?? ""
        let callID = payload["call_id"] as? String
        switch payloadType {
        case "local_shell_call":
            addCommand(Self.commandText((payload["action"] as? [String: Any])?["command"]), callID: callID, atMs: atMs)
        case "custom_tool_call":
            if name == "apply_patch", let patch = payload["input"] as? String {
                addPatchPaths(patch, atMs: atMs)
            }
        default:
            let arguments = CodexTranscriptQuestionExtractor.toolInput(fromArguments: payload["arguments"]) ?? [:]
            switch name {
            case "exec_command":
                addCommand(Self.commandText(arguments["cmd"]), callID: callID, atMs: atMs)
            case "shell", "shell_command", "local_shell", "container.exec":
                addCommand(Self.commandText(arguments["command"]), callID: callID, atMs: atMs)
            case "apply_patch":
                if let patch = (arguments["input"] ?? arguments["patch"]) as? String {
                    addPatchPaths(patch, atMs: atMs)
                }
            default:
                break
            }
        }
    }

    private mutating func processToolOutput(_ line: UnsafeRawBufferPointer, atMs: Int64) {
        guard let object = Self.decode(line),
              let payload = CodexTranscriptQuestionExtractor.responsePayload(from: object),
              let callID = payload["call_id"] as? String,
              let index = state.pendingCommitCallIDs.firstIndex(of: callID) else {
            return
        }
        state.pendingCommitCallIDs.remove(at: index)
        let output: String
        if let text = payload["output"] as? String {
            output = text
        } else if let parts = payload["output"] as? [[String: Any]] {
            output = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return
        }
        for hash in AgentHistoryArtifactExtractor.commitHashes(inGitOutput: output) {
            builder.addArtifact(.commit, rawValue: hash, atMs: atMs)
        }
    }

    // MARK: - Artifacts

    private mutating func addCommand(_ raw: String?, callID: String?, atMs: Int64) {
        guard let raw, let command = AgentHistoryArtifactExtractor.command(raw) else {
            return
        }
        builder.addArtifact(.command, rawValue: command, atMs: atMs)
        if let callID, AgentHistoryArtifactExtractor.isGitCommitCommand(raw), !state.pendingCommitCallIDs.contains(callID) {
            state.pendingCommitCallIDs.append(callID)
            if state.pendingCommitCallIDs.count > CodexRolloutState.maxPendingCommitCalls {
                state.pendingCommitCallIDs.removeFirst()
            }
        }
    }

    private mutating func addPatchPaths(_ patch: String, atMs: Int64) {
        let base = relativeBase()
        for raw in AgentHistoryArtifactExtractor.applyPatchPaths(patch) {
            if let path = AgentHistoryArtifactExtractor.path(raw, relativeTo: base) {
                builder.addArtifact(.path, rawValue: path, atMs: atMs)
            }
        }
    }

    /// The repository root of the thread's folder, else the folder; resolved once per batch.
    private mutating func relativeBase() -> String? {
        if !resolvedRepository {
            resolvedRepository = true
            if let cwd = knownCwd {
                artifactBase = context.repositories.identity(for: cwd)?.repoRoot ?? cwd
            }
        }
        return artifactBase
    }

    // MARK: - Helpers

    static func isEnvelopePart(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        return envelopePrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// A command string, or an argv array (a `bash -lc <script>` wrapper is reduced to the script).
    static func commandText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let argv = value as? [String], !argv.isEmpty else {
            return nil
        }
        if argv.count == 3, ["-lc", "-c"].contains(argv[1]),
           ["bash", "zsh", "sh"].contains((argv[0] as NSString).lastPathComponent) {
            return argv[2]
        }
        return argv.joined(separator: " ")
    }

    private static func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
