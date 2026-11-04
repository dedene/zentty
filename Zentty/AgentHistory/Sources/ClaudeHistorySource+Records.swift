import Foundation

/// Per-unit state carried between batches in `cursor.adapterState` (JSON).
struct ClaudeHistoryAdapterState: Codable, Equatable, Sendable {
    static let maxPendingCommitToolIDs = 64

    /// The raw record cwd chosen for the session (see `ClaudeHistorySource`).
    var cwd: String?
    /// `tool_use` ids of Bash `git commit` calls whose results have not been read yet.
    var pendingCommitToolIDs: [String] = []
    /// Time of the latest timestamped record, for records without one.
    var lastAtMs: Int64?
    var notedFirstPrompt = false

    static func decoded(from data: Data?) -> ClaudeHistoryAdapterState {
        guard let data, let state = try? JSONDecoder().decode(ClaudeHistoryAdapterState.self, from: data) else {
            return ClaudeHistoryAdapterState()
        }
        return state
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    mutating func addPendingCommit(_ toolUseID: String) {
        guard !pendingCommitToolIDs.contains(toolUseID) else {
            return
        }
        pendingCommitToolIDs.append(toolUseID)
        if pendingCommitToolIDs.count > Self.maxPendingCommitToolIDs {
            pendingCommitToolIDs.removeFirst(pendingCommitToolIDs.count - Self.maxPendingCommitToolIDs)
        }
    }
}

/// Turns Claude transcript lines into one batch's messages, artifacts and session metadata.
///
/// Every line is sniffed for its top-level `type` first; only `user`, `assistant`, title and
/// `pr-link` records go further. Main-chain filters run on sniffed top-level flags, and a line
/// is fully decoded only when it can produce a message or an artifact:
/// - `user`: skipped when `isSidechain`, `isMeta`, `isCompactSummary`,
///   `isVisibleInTranscriptOnly` or `forkedFrom` is set, or `origin.kind` is not `human`.
///   Tool results (`toolUseResult`, or a first content part of type `tool_result`) are decoded
///   only when they mention `"gitOperation"` or a pending commit call. Envelopes are dropped
///   except slash commands (`/name args`, a user message that never becomes the title) and
///   `<bash-input>` (a command artifact).
/// - `assistant`: skipped when `isSidechain`, `forkedFrom` or `isApiErrorMessage`; `text`
///   parts become one message; `tool_use` parts become artifacts (Read is never a path).
/// - Titles: `custom-title` → custom; `ai-title` and legacy `summary` → generated.
struct ClaudeTranscriptParser {
    var builder: AgentHistoryBatchBuilder
    var state: ClaudeHistoryAdapterState
    var diagnostics = AgentHistoryIngestDiagnostics()
    /// Bases for relativizing tool paths, in order (repo root, raw cwd, canonical cwd).
    let pathBases: [String]
    /// Message time when no record carried a timestamp yet (file mtime).
    let fallbackAtMs: Int64

    private static let recordStringKeys = ["type", "timestamp", "gitBranch", "requestedModel", "effort"]
    private static let recordFlagKeys = [
        "isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isApiErrorMessage",
    ]
    private static let recordPresenceKeys = ["forkedFrom", "toolUseResult", "origin"]
    private static let firstContentType: [JSONLineSniffer.PathComponent] = [
        .key("message"), .key("content"), .index(0), .key("type"),
    ]
    private static let originKind: [JSONLineSniffer.PathComponent] = [.key("origin"), .key("kind")]

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        guard let head = JSONLineSniffer.topLevel(in: line, stringKeys: ["type"], flagKeys: [], presenceKeys: []) else {
            diagnostics.malformedLines += 1
            return
        }
        switch head.strings["type"] {
        case "user":
            consumeUser(line)
        case "assistant":
            consumeAssistant(line)
        case "custom-title":
            noteTitle(line, key: "customTitle", kind: .custom)
        case "ai-title":
            noteTitle(line, key: "aiTitle", kind: .generated)
        case "summary":
            noteTitle(line, key: "summary", kind: .generated)
        case "pr-link":
            consumePRLink(line)
        default:
            break
        }
    }

    // MARK: - Records

    private mutating func consumeUser(_ line: UnsafeRawBufferPointer) {
        guard let top = sniffRecord(line) else {
            return
        }
        if top.trueFlags.contains("isSidechain") || top.presentKeys.contains("forkedFrom") {
            diagnostics.skippedRecords += 1
            return
        }
        let atMs = noteMetadata(top, isAssistant: false)
        if !top.trueFlags.isDisjoint(with: ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"]) {
            diagnostics.skippedRecords += 1
            return
        }
        if top.presentKeys.contains("origin"),
           case let .string(kind)? = JSONLineSniffer.value(at: Self.originKind, in: line), kind != "human" {
            diagnostics.skippedRecords += 1
            return
        }
        if top.presentKeys.contains("toolUseResult")
            || JSONLineSniffer.value(at: Self.firstContentType, in: line) == .string("tool_result") {
            consumeToolResult(line, atMs: atMs)
            return
        }

        guard let message = decodeMessage(line) else {
            return
        }
        var prompt: [String] = []
        var slashCommands: [String] = []
        for text in Self.textParts(of: message["content"]) {
            guard AgentHistoryDisplayText.isEnvelope(text) else {
                prompt.append(text)
                continue
            }
            if let slash = AgentHistoryDisplayText.slashCommand(fromEnvelope: text) {
                slashCommands.append(slash)
            } else if let bash = Self.tagContent("bash-input", in: text),
                      let command = AgentHistoryArtifactExtractor.command(bash) {
                builder.addArtifact(.command, rawValue: command, atMs: atMs)
            }
        }

        var added = false
        for slash in slashCommands {
            added = builder.addMessage(role: .user, atMs: atMs, rawText: slash) || added
        }
        if !prompt.isEmpty {
            let text = prompt.joined(separator: "\n\n")
            if builder.addMessage(role: .user, atMs: atMs, rawText: text) {
                added = true
                if !state.notedFirstPrompt {
                    state.notedFirstPrompt = true
                    builder.noteFirstPrompt(AgentHistoryDisplayText.displayText(text) ?? text)
                }
            }
        }
        if !added {
            diagnostics.skippedRecords += 1
        }
    }

    private mutating func consumeAssistant(_ line: UnsafeRawBufferPointer) {
        guard let top = sniffRecord(line) else {
            return
        }
        if !top.trueFlags.isDisjoint(with: ["isSidechain", "isApiErrorMessage"]) || top.presentKeys.contains("forkedFrom") {
            diagnostics.skippedRecords += 1
            return
        }
        let atMs = noteMetadata(top, isAssistant: true)
        guard let message = decodeMessage(line) else {
            return
        }
        if top.strings["requestedModel"].flatMap(AgentRootMetadataResolver.normalizedModel) == nil,
           let model = AgentRootMetadataResolver.normalizedModel(message["model"] as? String) {
            builder.session.model = model
        }

        var texts: [String] = []
        for case let part as [String: Any] in (message["content"] as? [Any]) ?? [] {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String {
                    texts.append(text)
                }
            case "tool_use":
                consumeToolUse(part, atMs: atMs)
            default:
                break
            }
        }
        if let content = message["content"] as? String {
            texts.append(content)
        }
        guard !texts.isEmpty else {
            return
        }
        let text = texts.joined(separator: "\n\n")
        if builder.addMessage(role: .agent, atMs: atMs, rawText: text) {
            for url in AgentHistoryArtifactExtractor.pullRequestURLs(in: text) {
                builder.addArtifact(.pr, rawValue: url, atMs: atMs)
            }
        } else {
            diagnostics.skippedRecords += 1
        }
    }

    private mutating func consumeToolUse(_ part: [String: Any], atMs: Int64) {
        guard let name = part["name"] as? String, let input = part["input"] as? [String: Any] else {
            return
        }
        switch name {
        case "Edit", "Write", "MultiEdit":
            addPath(input["file_path"], atMs: atMs)
        case "NotebookEdit":
            addPath(input["notebook_path"], atMs: atMs)
        case "Bash":
            guard let raw = input["command"] as? String else {
                return
            }
            if let command = AgentHistoryArtifactExtractor.command(raw) {
                builder.addArtifact(.command, rawValue: command, atMs: atMs)
            }
            if AgentHistoryArtifactExtractor.isGitCommitCommand(raw), let id = part["id"] as? String, !id.isEmpty {
                state.addPendingCommit(id)
            }
        default:
            break
        }
    }

    /// Commit and PR artifacts from a tool result. Decoded only when the raw line mentions
    /// `"gitOperation"` or a pending `git commit` call id; other tool output is never parsed.
    private mutating func consumeToolResult(_ line: UnsafeRawBufferPointer, atMs: Int64) {
        let mentionsGitOperation = JSONLineSniffer.contains("\"gitOperation\"", in: line)
        let mentionsPending = state.pendingCommitToolIDs.contains { JSONLineSniffer.contains($0, in: line) }
        guard mentionsGitOperation || mentionsPending else {
            return
        }
        guard let object = decode(line) else {
            return
        }
        let result = object["toolUseResult"] as? [String: Any]
        var foundCommit = false
        if let gitOperation = result?["gitOperation"] as? [String: Any] {
            if let sha = (gitOperation["commit"] as? [String: Any])?["sha"] as? String, Self.isCommitHash(sha) {
                builder.addArtifact(.commit, rawValue: sha, atMs: atMs)
                foundCommit = true
            }
            if let url = (gitOperation["pr"] as? [String: Any])?["url"] as? String,
               let pr = AgentHistoryArtifactExtractor.pullRequestURLs(in: url).first {
                builder.addArtifact(.pr, rawValue: pr, atMs: atMs)
            }
        }

        let message = object["message"] as? [String: Any]
        for case let part as [String: Any] in (message?["content"] as? [Any]) ?? [] {
            guard part["type"] as? String == "tool_result", let id = part["tool_use_id"] as? String,
                  let index = state.pendingCommitToolIDs.firstIndex(of: id) else {
                continue
            }
            state.pendingCommitToolIDs.remove(at: index)
            guard !foundCommit else {
                continue
            }
            let output = (result?["stdout"] as? String) ?? Self.textParts(of: part["content"]).joined(separator: "\n")
            for hash in AgentHistoryArtifactExtractor.commitHashes(inGitOutput: output) {
                builder.addArtifact(.commit, rawValue: hash, atMs: atMs)
            }
        }
    }

    private mutating func consumePRLink(_ line: UnsafeRawBufferPointer) {
        guard let top = JSONLineSniffer.topLevel(in: line, stringKeys: ["prUrl", "timestamp"], flagKeys: [], presenceKeys: []),
              let raw = top.strings["prUrl"],
              let url = AgentHistoryArtifactExtractor.pullRequestURLs(in: raw).first else {
            return
        }
        builder.addArtifact(.pr, rawValue: url, atMs: timestamp(top.strings["timestamp"]))
    }

    private mutating func noteTitle(_ line: UnsafeRawBufferPointer, key: String, kind: AgentHistoryTitleKind) {
        guard let top = JSONLineSniffer.topLevel(in: line, stringKeys: [key], flagKeys: [], presenceKeys: []) else {
            diagnostics.malformedLines += 1
            return
        }
        builder.noteTitle(top.strings[key], kind: kind)
    }

    // MARK: - Metadata

    /// Branch, model and effort from a main-chain record; returns the record time and widens
    /// the session's created/updated range with it.
    private mutating func noteMetadata(_ top: JSONLineSniffer.TopLevel, isAssistant: Bool) -> Int64 {
        if let branch = top.strings["gitBranch"]?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            builder.session.branch = branch
        }
        if isAssistant {
            if let model = top.strings["requestedModel"].flatMap(AgentRootMetadataResolver.normalizedModel) {
                builder.session.model = model
            }
            if let effort = top.strings["effort"]?.trimmingCharacters(in: .whitespacesAndNewlines), !effort.isEmpty {
                builder.session.effort = effort
            }
        }
        let atMs = timestamp(top.strings["timestamp"])
        builder.session.createdAtMs = builder.session.createdAtMs.map { min($0, atMs) } ?? atMs
        builder.session.updatedAtMs = builder.session.updatedAtMs.map { max($0, atMs) } ?? atMs
        return atMs
    }

    private mutating func timestamp(_ text: String?) -> Int64 {
        if let text, let ms = AgentHistoryTimestamp.milliseconds(iso8601: text) {
            state.lastAtMs = ms
            return ms
        }
        return state.lastAtMs ?? fallbackAtMs
    }

    // MARK: - Decoding

    private mutating func sniffRecord(_ line: UnsafeRawBufferPointer) -> JSONLineSniffer.TopLevel? {
        guard let top = JSONLineSniffer.topLevel(
            in: line,
            stringKeys: Self.recordStringKeys,
            flagKeys: Self.recordFlagKeys,
            presenceKeys: Self.recordPresenceKeys
        ) else {
            diagnostics.malformedLines += 1
            return nil
        }
        return top
    }

    private mutating func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            diagnostics.malformedLines += 1
            return nil
        }
        return object
    }

    private mutating func decodeMessage(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let object = decode(line) else {
            return nil
        }
        guard let message = object["message"] as? [String: Any] else {
            diagnostics.skippedRecords += 1
            return nil
        }
        return message
    }

    private mutating func addPath(_ value: Any?, atMs: Int64) {
        guard let raw = value as? String else {
            return
        }
        var path: String?
        for base in pathBases {
            path = AgentHistoryArtifactExtractor.path(raw, relativeTo: base)
            if let path, !path.hasPrefix("/") {
                break
            }
        }
        if pathBases.isEmpty {
            path = AgentHistoryArtifactExtractor.path(raw, relativeTo: nil)
        }
        if let path {
            builder.addArtifact(.path, rawValue: path, atMs: atMs)
        }
    }

    /// A string content, or the `text` of each `text` part of an array content.
    private static func textParts(of content: Any?) -> [String] {
        if let text = content as? String {
            return [text]
        }
        var texts: [String] = []
        for case let part as [String: Any] in (content as? [Any]) ?? [] where part["type"] as? String == "text" {
            if let text = part["text"] as? String {
                texts.append(text)
            }
        }
        return texts
    }

    /// The text between `<name>` and the next `</name>`, trimmed; nil when absent or empty.
    private static func tagContent(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isCommitHash(_ value: String) -> Bool {
        (7...40).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
