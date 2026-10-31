import Foundation
import XCTest
@testable import Zentty

/// Grok session fixtures: `<root>/sessions/<percent-encoded cwd>/<id>/` with `summary.json`,
/// `chat_history.jsonl` and `events.jsonl`, shaped like Grok's on-disk format 1.
extension AgentHistoryFixtures {
    static func grokSummary(
        id: String,
        cwd: String,
        title: String? = nil,
        model: String? = "grok-4.6",
        effort: String? = "high",
        branch: String? = nil,
        kind: String? = nil,
        formatVersion: Int = 1,
        createdAt: String = "2026-09-05T17:00:00.000000Z",
        lastActiveAt: String = "2026-09-05T17:10:00.000000Z"
    ) -> [String: Any] {
        var summary: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "chat_format_version": formatVersion,
            "created_at": createdAt,
            "updated_at": lastActiveAt,
            "last_active_at": lastActiveAt,
            "agent_name": "grok-build-plan",
            "session_summary": "",
        ]
        summary["generated_title"] = title
        summary["current_model_id"] = model
        summary["reasoning_effort"] = effort
        summary["head_branch"] = branch
        summary["session_kind"] = kind
        return summary
    }

    /// One `chat_history.jsonl` record. `user`: `text` becomes one text part (or pass `parts`).
    /// Like interactive Grok, a non-synthetic `text` is wrapped as
    /// `<user_query>\n…\n</user_query>`; pass `plain: true` for a headless `-p` prompt or an
    /// envelope stored as is. `assistant`: `text` is the `content` string. `extra` adds keys.
    static func grokChat(
        _ type: String,
        text: String? = nil,
        parts: [[String: Any]]? = nil,
        promptIndex: Int? = nil,
        syntheticReason: String? = nil,
        plain: Bool = false,
        toolCalls: [(id: String, name: String, arguments: [String: Any])] = [],
        toolCallID: String? = nil,
        extra: [String: Any] = [:]
    ) throws -> String {
        var record: [String: Any] = ["type": type]
        switch type {
        case "user":
            let raw = text ?? ""
            let wrapped = plain || syntheticReason != nil ? raw : grokUserQuery(raw)
            record["content"] = parts ?? [["type": "text", "text": wrapped]]
            record["prompt_index"] = promptIndex
            record["synthetic_reason"] = syntheticReason
        case "assistant":
            record["content"] = text ?? ""
            record["model_id"] = "grok-4.6"
            record["reasoning_effort"] = "high"
            if !toolCalls.isEmpty {
                record["tool_calls"] = try toolCalls.map { call -> [String: Any] in
                    let arguments = try JSONSerialization.data(withJSONObject: call.arguments, options: [.sortedKeys])
                    return ["id": call.id, "name": call.name, "arguments": String(decoding: arguments, as: UTF8.self)]
                }
            }
        case "tool_result":
            record["tool_call_id"] = toolCallID ?? ""
            record["content"] = text ?? ""
        case "reasoning":
            record["id"] = "rs_1"
            record["summary"] = [["type": "summary_text", "text": text ?? "thinking"]]
            record["status"] = "completed"
        case "backend_tool_call":
            record["kind"] = ["tool_type": "web_search", "action": ["type": "search", "query": text ?? "q"]]
        default:
            record["content"] = text ?? ""
        }
        record.merge(extra) { _, new in new }
        return try jsonLine(record)
    }

    /// `text` as interactive Grok stores a typed prompt.
    static func grokUserQuery(_ text: String) -> String {
        "<user_query>\n\(text)\n</user_query>"
    }

    /// One `events.jsonl` record; `turn_started` carries `turnNumber`.
    static func grokEvent(_ type: String, ts: String, turnNumber: Int? = nil) throws -> String {
        var record: [String: Any] = ["type": type, "ts": ts]
        if type == "turn_started" {
            record["turn_number"] = turnNumber ?? 0
            record["session_relationship"] = "primary"
            record["schema_version"] = "1.0"
        }
        return try jsonLine(record)
    }

    /// A source over the Grok home `root` (never the real `~/.grok`).
    static func grokSource(root: URL) -> GrokHistorySource {
        GrokHistorySource(root: AgentHistorySourceRoot(
            agent: .grok,
            path: AgentHistoryPath.canonical(root.path),
            isDefault: false
        ))
    }

    static func grokUnit(_ source: GrokHistorySource, id: String) throws -> AgentHistoryUnit {
        try XCTUnwrap(try source.discoverUnits().first { $0.nativeSessionID == id })
    }

    /// Ingests `id` from the start, or from `cursor` when given.
    static func grokIngest(
        _ source: GrokHistorySource,
        id: String,
        cursor: AgentHistoryCursor? = nil
    ) throws -> AgentHistoryIngestBatch {
        let mode: AgentHistoryIngestMode = cursor.map { .fromOffset($0.byteOffset, nextSeq: $0.nextSeq) } ?? .fromStart
        return try source.ingest(unit: try grokUnit(source, id: id), cursor: cursor, mode: mode, context: context())
    }

    /// Creates `<root>/sessions/<encoded cwd>/<id>/` with the given files; returns the session dir.
    @discardableResult
    static func writeGrokSession(
        root: URL,
        id: String,
        cwd: String,
        summary: [String: Any]? = nil,
        chat: [String],
        events: [String]? = nil
    ) throws -> URL {
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "cwd"
        let directory = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summaryObject = summary ?? grokSummary(id: id, cwd: cwd)
        let summaryData = try JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys, .withoutEscapingSlashes])
        try summaryData.write(to: directory.appendingPathComponent("summary.json"))
        try writeJSONL(chat, to: directory.appendingPathComponent("chat_history.jsonl"))
        if let events {
            try writeJSONL(events, to: directory.appendingPathComponent("events.jsonl"))
        }
        return directory
    }
}
