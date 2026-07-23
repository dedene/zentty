import Foundation

// MARK: - Adapter seam (per-tool)

/// Turns a stream of an agent's session-file bytes into normalized wire
/// `CompanionTranscriptEntry` values, buffering across reads so a mid-write
/// partial last line is held until its terminating newline arrives.
///
/// Reference-typed because it carries the cross-read partial-line buffer for one
/// tailed file.
protocol CompanionTranscriptScanner: AnyObject {
    /// Appends freshly-read bytes and returns entries for every line completed by
    /// this chunk. An unterminated trailing line is retained until a later
    /// `consume` supplies its newline.
    func consume(_ bytes: Data) -> [CompanionTranscriptEntry]
}

/// A per-tool transcript adapter: it knows where a tool writes its session file
/// and how to parse it. v1 ships Claude Code; adding Codex is a matter of
/// dropping a sibling adapter and registering it below.
protocol CompanionTranscriptAdapter: Sendable {
    /// Resolves the on-disk session file. Prefers the live path the running agent
    /// reported (correct even when the working directory is a symlink); otherwise
    /// derives the canonical location from the session id + working directory.
    func transcriptURL(
        sessionID: String?,
        workingDirectory: String?,
        liveTranscriptPath: String?
    ) -> URL?

    /// A fresh scanner for one tailed file (holds that file's partial-line buffer).
    func makeScanner() -> CompanionTranscriptScanner
}

/// Maps an `AgentTool` to its transcript adapter, if one exists. Pure and
/// AppKit-free so both the dashboard mapping (`hasTranscript`) and the feed can
/// consult it from any actor.
struct CompanionTranscriptAdapterRegistry: Sendable {
    static let `default` = CompanionTranscriptAdapterRegistry()

    func adapter(for tool: AgentTool) -> CompanionTranscriptAdapter? {
        switch tool {
        case .claudeCode:
            return ClaudeTranscriptAdapter()
        default:
            return nil
        }
    }

    /// Whether a pane on this tool can offer a Conversation tab at all.
    func hasAdapter(for tool: AgentTool) -> Bool {
        adapter(for: tool) != nil
    }
}

// MARK: - Claude adapter

/// Claude Code session files live at
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where `<encoded-cwd>`
/// replaces every non-`[A-Za-z0-9]` character of the absolute working directory
/// with `-` (so `/`, `.`, `_` all collapse to `-`).
struct ClaudeTranscriptAdapter: CompanionTranscriptAdapter {
    func transcriptURL(
        sessionID: String?,
        workingDirectory: String?,
        liveTranscriptPath: String?
    ) -> URL? {
        ClaudeTranscriptLocator.transcriptURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            liveTranscriptPath: liveTranscriptPath
        )
    }

    func makeScanner() -> CompanionTranscriptScanner {
        ClaudeTranscriptTail()
    }
}

/// Resolves the Claude session-file location. Split out from the adapter so the
/// slug encoding can be unit-tested directly.
enum ClaudeTranscriptLocator {
    static func transcriptURL(
        sessionID: String?,
        workingDirectory: String?,
        liveTranscriptPath: String?
    ) -> URL? {
        if let liveTranscriptPath, !liveTranscriptPath.isEmpty {
            let expanded = (liveTranscriptPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        guard
            let sessionID, !sessionID.isEmpty,
            let workingDirectory, !workingDirectory.isEmpty
        else {
            return nil
        }
        let slug = encodedProjectSlug(forWorkingDirectory: workingDirectory)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    /// Mirrors Claude Code's `cwd.replace(/[^a-zA-Z0-9]/g, '-')`.
    static func encodedProjectSlug(forWorkingDirectory workingDirectory: String) -> String {
        let expanded = (workingDirectory as NSString).expandingTildeInPath
        return String(expanded.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }
}

// MARK: - Line-buffering tail

/// Splits a byte stream into newline-terminated JSONL lines, retaining an
/// unterminated trailing line across `consume` calls. This is what makes a
/// mid-write truncated last line safe: the line is parsed only once its newline
/// lands, so a half-written JSON object is never handed to the parser.
final class ClaudeTranscriptTail: CompanionTranscriptScanner {
    private static let newline = UInt8(ascii: "\n")
    private var pending = Data()

    func consume(_ bytes: Data) -> [CompanionTranscriptEntry] {
        pending.append(bytes)
        var entries: [CompanionTranscriptEntry] = []
        while let newlineIndex = pending.firstIndex(of: Self.newline) {
            let lineData = Data(pending[pending.startIndex..<newlineIndex])
            // Re-base the buffer so indices stay zero-based for the next scan.
            pending = Data(pending[pending.index(after: newlineIndex)...])
            if let line = String(data: lineData, encoding: .utf8) {
                entries.append(contentsOf: ClaudeTranscriptParser.entries(fromLine: line))
            }
        }
        return entries
    }
}

// MARK: - Parser

/// Parses one Claude Code JSONL line into zero or more normalized transcript
/// entries. Deliberately lossy: meta lines (`summary`, `file-history-snapshot`,
/// `mode`, …) and undecodable lines yield nothing; a single `assistant` line can
/// fan out into several entries (text plus one per `tool_use` block).
enum ClaudeTranscriptParser {
    /// Tool-result summaries are truncated to keep deltas small.
    static let toolResultSummaryLimit = 500

    static func entries(fromLine line: String) -> [CompanionTranscriptEntry] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        guard let raw = try? decoder.decode(RawLine.self, from: data) else {
            // Incomplete or malformed JSON (e.g. a torn line) is skipped; the tail
            // buffer already guards against unterminated lines, this is defense in
            // depth for genuinely corrupt content.
            return []
        }

        let uuid = raw.uuid ?? UUID().uuidString
        let ts = raw.timestamp.flatMap(Self.epochMilliseconds(fromISO8601:))

        switch raw.type {
        case "user":
            return finalize(uuid: uuid, ts: ts, drafts: userDrafts(from: raw.message?.content))
        case "assistant":
            return finalize(uuid: uuid, ts: ts, drafts: assistantDrafts(from: raw.message?.content))
        case "system":
            guard case .text(let text)? = raw.content, !text.trimmed.isEmpty else { return [] }
            return finalize(uuid: uuid, ts: ts, drafts: [
                EntryDraft(role: .system, text: text)
            ])
        default:
            return []
        }
    }

    // MARK: Draft assembly

    /// A pre-id entry; ids are assigned once the whole line's drafts are known so
    /// a single draft keeps the bare line uuid and a multi-block line gets stable
    /// `<uuid>#<index>` ids.
    private struct EntryDraft {
        var role: CompanionTranscriptRole
        var text: String?
        var toolName: String?
        var toolInput: CompanionJSONValue?
        var toolResultSummary: String?
        var status: String?
    }

    private static func finalize(uuid: String, ts: Int?, drafts: [EntryDraft]) -> [CompanionTranscriptEntry] {
        let single = drafts.count == 1
        return drafts.enumerated().map { index, draft in
            CompanionTranscriptEntry(
                id: single ? uuid : "\(uuid)#\(index)",
                role: draft.role,
                ts: ts,
                text: draft.text,
                toolName: draft.toolName,
                toolInput: draft.toolInput,
                toolResultSummary: draft.toolResultSummary,
                status: draft.status
            )
        }
    }

    private static func userDrafts(from content: RawContent?) -> [EntryDraft] {
        switch content {
        case .text(let text):
            guard !text.trimmed.isEmpty else { return [] }
            return [EntryDraft(role: .user, text: text)]
        case .blocks(let blocks):
            return blocks.compactMap { block in
                switch block.type {
                case "text":
                    guard let text = block.text, !text.trimmed.isEmpty else { return nil }
                    return EntryDraft(role: .user, text: text)
                case "tool_result":
                    let summary = block.content
                        .map(Self.flatten)
                        .map { Self.truncate($0, limit: toolResultSummaryLimit) }
                    return EntryDraft(
                        role: .toolResult,
                        toolResultSummary: summary,
                        status: (block.isError ?? false) ? "error" : "ok"
                    )
                default:
                    return nil
                }
            }
        case .none:
            return []
        }
    }

    private static func assistantDrafts(from content: RawContent?) -> [EntryDraft] {
        guard case .blocks(let blocks)? = content else {
            if case .text(let text)? = content, !text.trimmed.isEmpty {
                return [EntryDraft(role: .assistant, text: text)]
            }
            return []
        }
        return blocks.compactMap { block in
            switch block.type {
            case "text":
                guard let text = block.text, !text.trimmed.isEmpty else { return nil }
                return EntryDraft(role: .assistant, text: text)
            case "tool_use":
                return EntryDraft(
                    role: .toolUse,
                    toolName: block.name,
                    toolInput: block.input
                )
            default:
                return nil
            }
        }
    }

    // MARK: Helpers

    /// Flattens a tool_result's `content` (a string, or an array of text blocks)
    /// into a single plain-text summary.
    private static func flatten(_ content: RawContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { $0.text }.joined(separator: "\n")
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func epochMilliseconds(fromISO8601 string: String) -> Int? {
        guard let date = iso8601.date(from: string) ?? iso8601NoFraction.date(from: string) else {
            return nil
        }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let decoder = JSONDecoder()

    // Configured once and only read from thereafter; Foundation's date formatters
    // are safe for concurrent parsing.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Raw JSONL shapes

private struct RawLine: Decodable {
    var type: String?
    var uuid: String?
    var timestamp: String?
    /// Present on `system` lines (a plain string).
    var content: RawContent?
    var message: RawMessage?
}

private struct RawMessage: Decodable {
    var role: String?
    var content: RawContent?
}

private struct RawBlock: Decodable {
    var type: String
    var text: String?
    var name: String?
    var input: CompanionJSONValue?
    var isError: Bool?
    /// Present on `tool_result` blocks (a string, or an array of text blocks).
    var content: RawContent?

    enum CodingKeys: String, CodingKey {
        case type, text, name, input, content
        case isError = "is_error"
    }
}

/// Claude's polymorphic `content`: either a bare string or an array of blocks.
private enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks(try container.decode([RawBlock].self))
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
