import Foundation

/// Maps a byte position in `chat_history.jsonl` linearly onto `[startMs, endMs]`
/// (`created_at` … `last_active_at`). Used for records whose turn has no `turn_started` event.
struct GrokTimeInterpolation {
    let startMs: Int64
    let endMs: Int64
    let size: Int64

    func milliseconds(atOffset offset: Int64) -> Int64 {
        guard size > 0, endMs > startMs else {
            return startMs
        }
        let fraction = min(max(Double(offset) / Double(size), 0), 1)
        return startMs + Int64((Double(endMs - startMs) * fraction).rounded(.down))
    }
}

/// Reads one batch of `chat_history.jsonl` records into a batch builder.
///
/// - `user`: text parts, joined by newlines. Interactive Grok wraps what the user typed in
///   `<user_query>…</user_query>`, sometimes after an `<image_files>` block or inside an
///   interrupt preamble (`prior_turn_interrupt`); only the query body is indexed. Text without
///   a `<user_query>` (headless `-p` prompts) is indexed as is unless it is a pure tag envelope
///   (`<user_info>…`). Records with a `synthetic_reason` (system reminders, project
///   instructions, compaction summaries, task notifications) are not indexed. A record with a
///   `prompt_index`, or a typed one, starts a turn.
/// - `assistant`: the `content` string; `tool_calls[].arguments` give artifacts
///   (`run_terminal_command.command` → command, `search_replace`/`write` `file_path` → path);
///   PR links in the reply → pr.
/// - `tool_result`: decoded only when it answers a pending `git commit` call → commit hashes.
/// - `system`, `reasoning`, `backend_tool_call` and anything else: skipped unread.
///
/// Times: a turn starts at the first `turn_started` (after the previous match) whose
/// `turn_number` equals the prompt's `prompt_index`; a prompt without an index takes the next
/// `turn_started`. Without a match the time is interpolated by byte offset. Replies in a turn
/// get the turn start plus their `seq` distance, so they sort after the prompt.
struct GrokChatReader {
    struct Progress {
        var committedOffset: Int64
        var hasMore: Bool
        var malformedLines: Int
        var oversizedLines: Int
    }

    var builder: AgentHistoryBatchBuilder
    var state: GrokCursorState
    let turns: [GrokTurnStart]
    /// Repo root or cwd; edited file paths under it are stored relative.
    let pathBase: String?
    let interpolation: GrokTimeInterpolation

    private var malformedLines = 0

    init(
        builder: AgentHistoryBatchBuilder,
        state: GrokCursorState,
        turns: [GrokTurnStart],
        pathBase: String?,
        interpolation: GrokTimeInterpolation
    ) {
        self.builder = builder
        self.state = state
        self.turns = turns
        self.pathBase = pathBase
        self.interpolation = interpolation
    }

    mutating func read(path: String, from startOffset: Int64, context: AgentHistoryIngestContext) throws -> Progress {
        let byteLimit = Int64(context.limits.sourceBytes)
        var reader = JSONLTailReader(
            source: try FileByteSource(path: path, offset: startOffset),
            startOffset: startOffset,
            isCancelled: context.isCancelled
        )
        var stoppedEarly = false
        let stats = try reader.readLines { line, endOffset in
            handle(line, endOffset: endOffset)
            if builder.isFull || endOffset - startOffset >= byteLimit {
                stoppedEarly = true
                return .stop
            }
            return .continue
        }
        let fileSize = AgentHistoryFileIdentity.stat(path: path)?.size ?? stats.committedOffset
        let hasMore = (stoppedEarly || stats.cancelled) && stats.committedOffset < fileSize
        return Progress(
            committedOffset: stats.committedOffset,
            hasMore: hasMore,
            malformedLines: malformedLines,
            oversizedLines: stats.oversizedLines
        )
    }

    // MARK: - Records

    private mutating func handle(_ line: UnsafeRawBufferPointer, endOffset: Int64) {
        guard
            let top = JSONLineSniffer.topLevel(in: line, stringKeys: ["type"], flagKeys: [], presenceKeys: []),
            let type = top.strings["type"]
        else {
            malformedLines += 1
            return
        }
        switch type {
        case "user":
            guard let record = decode(line) else { return }
            handleUser(record, endOffset: endOffset)
        case "assistant":
            guard let record = decode(line) else { return }
            handleAssistant(record, endOffset: endOffset)
        case "tool_result":
            guard state.pendingCommitCallIDs.contains(where: { JSONLineSniffer.contains($0, in: line) }),
                  let record = decode(line) else {
                return
            }
            handleToolResult(record, endOffset: endOffset)
        default:
            return
        }
    }

    private mutating func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard
            let base = line.baseAddress,
            let object = try? JSONSerialization.jsonObject(with: Data(bytes: base, count: line.count)) as? [String: Any]
        else {
            malformedLines += 1
            return nil
        }
        return object
    }

    private mutating func handleUser(_ record: [String: Any], endOffset: Int64) {
        let promptIndex = (record["prompt_index"] as? NSNumber)?.intValue
        let isSynthetic = (record["synthetic_reason"] as? String).map { !$0.isEmpty } ?? false
        let typed = isSynthetic ? nil : Self.text(of: record["content"]).flatMap(Self.typedText)
        guard promptIndex != nil || typed != nil else {
            return
        }

        let atMs: Int64
        if let matched = GrokTurnStart.match(in: turns, promptIndex: promptIndex, after: state.lastTurnStartMs) {
            atMs = matched
            state.lastTurnStartMs = matched
        } else {
            atMs = interpolation.milliseconds(atOffset: endOffset)
        }
        state.turnAtMs = atMs

        if let typed, builder.addMessage(role: .user, atMs: atMs, rawText: typed) {
            if state.promptCount == 0 {
                builder.noteFirstPrompt(AgentHistoryDisplayText.displayText(typed) ?? typed)
            }
            state.promptCount += 1
        }
        state.turnSeq = builder.nextSeq - 1
    }

    private mutating func handleAssistant(_ record: [String: Any], endOffset: Int64) {
        let atMs: Int64
        if let turnAtMs = state.turnAtMs {
            atMs = turnAtMs + Int64(max(builder.nextSeq - state.turnSeq, 1))
        } else {
            atMs = interpolation.milliseconds(atOffset: endOffset)
        }
        if let content = record["content"] as? String {
            builder.addMessage(role: .agent, atMs: atMs, rawText: content)
            for url in AgentHistoryArtifactExtractor.pullRequestURLs(in: content) {
                builder.addArtifact(.pr, rawValue: url, atMs: atMs)
            }
        }
        for call in record["tool_calls"] as? [[String: Any]] ?? [] {
            handleToolCall(call, atMs: atMs)
        }
    }

    private mutating func handleToolCall(_ call: [String: Any], atMs: Int64) {
        guard
            let name = call["name"] as? String,
            let rawArguments = call["arguments"] as? String,
            let arguments = try? JSONSerialization.jsonObject(with: Data(rawArguments.utf8)) as? [String: Any]
        else {
            return
        }
        switch name {
        case "run_terminal_command":
            guard let command = arguments["command"] as? String else { return }
            if let value = AgentHistoryArtifactExtractor.command(command) {
                builder.addArtifact(.command, rawValue: value, atMs: atMs)
            }
            if AgentHistoryArtifactExtractor.isGitCommitCommand(command), let id = call["id"] as? String, !id.isEmpty {
                state.pendingCommitCallIDs.append(id)
                if state.pendingCommitCallIDs.count > GrokCursorState.maxPendingCommitCalls {
                    state.pendingCommitCallIDs.removeFirst(state.pendingCommitCallIDs.count - GrokCursorState.maxPendingCommitCalls)
                }
            }
        case "search_replace", "write":
            guard
                let filePath = arguments["file_path"] as? String,
                let value = AgentHistoryArtifactExtractor.path(filePath, relativeTo: pathBase)
            else {
                return
            }
            builder.addArtifact(.path, rawValue: value, atMs: atMs)
        default:
            return
        }
    }

    private mutating func handleToolResult(_ record: [String: Any], endOffset: Int64) {
        guard
            let id = record["tool_call_id"] as? String,
            let index = state.pendingCommitCallIDs.firstIndex(of: id)
        else {
            return
        }
        state.pendingCommitCallIDs.remove(at: index)
        guard let output = Self.text(of: record["content"]) else {
            return
        }
        let atMs = state.turnAtMs ?? interpolation.milliseconds(atOffset: endOffset)
        for hash in AgentHistoryArtifactExtractor.commitHashes(inGitOutput: output) {
            builder.addArtifact(.commit, rawValue: hash, atMs: atMs)
        }
    }

    static let queryOpenTag = "<user_query>"
    static let queryCloseTag = "</user_query>"

    /// What the user typed in a non-synthetic user record's text, or nil when it is plumbing.
    ///
    /// With a `<user_query>` element: its body, from the first opening tag to the last closing
    /// tag (to the end when unterminated), so `<image_files>` blocks, the interrupt preamble and
    /// trailing `<system-reminder>`s are dropped; nil when the body is blank. Without one: the
    /// text itself unless it is a pure tag envelope (`AgentHistoryDisplayText.isEnvelope`).
    static func typedText(_ text: String) -> String? {
        guard let open = text.range(of: queryOpenTag) else {
            return AgentHistoryDisplayText.isEnvelope(text) ? nil : text
        }
        let rest = text[open.upperBound...]
        let body = rest.range(of: queryCloseTag, options: .backwards).map { rest[..<$0.lowerBound] } ?? rest
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A string, or the `text` parts of a content array joined by newlines; nil when empty.
    static func text(of content: Any?) -> String? {
        if let string = content as? String {
            return string.isEmpty ? nil : string
        }
        guard let parts = content as? [[String: Any]] else {
            return nil
        }
        let texts = parts.compactMap { part -> String? in
            guard (part["type"] as? String) == "text", let text = part["text"] as? String, !text.isEmpty else {
                return nil
            }
            return text
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
