import Foundation
import XCTest
@testable import Zentty

/// Codex rollout lines, rollout files (plain and zstd) and `state_5.sqlite` fixtures. Everything
/// lives in a temp `agent-history-<UUID>` root; nothing touches the real `~/.codex`.
enum CodexHistoryFixtures {
    typealias F = AgentHistoryFixtures

    static let baseTime = "2026-10-30T10:00:00.000Z"
    static let baseMs: Int64 = 1_793_354_400_000

    static func timestamp(_ offsetMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(baseMs + offsetMs) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func newThreadID() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: - Roots

    static func makeRoot(_ testCase: XCTestCase) throws -> (url: URL, source: CodexHistorySource) {
        let url = try F.makeTemporaryDirectory(testCase)
        let root = AgentHistorySourceRoot(agent: .codex, path: AgentHistoryPath.canonical(url.path), isDefault: false)
        return (URL(fileURLWithPath: root.path), CodexHistorySource(root: root))
    }

    // MARK: - Lines

    static func line(_ type: String, at offsetMs: Int64 = 0, payload: [String: Any], extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["timestamp": timestamp(offsetMs), "type": type, "payload": payload]
        object.merge(extra) { _, new in new }
        // Keys come out sorted (`payload` before `type`), which also exercises the sniffer's
        // walk past a large value to reach `type`.
        return try! F.jsonLine(object)
    }

    static func sessionMeta(
        _ id: String, cwd: String = "/work/proj", branch: String? = "main",
        source: Any = "cli", parentThreadID: String? = nil, at offsetMs: Int64 = 0
    ) -> String {
        var payload: [String: Any] = ["id": id, "cwd": cwd, "timestamp": timestamp(offsetMs), "source": source, "cli_version": "0.164.0"]
        if let branch {
            payload["git"] = ["branch": branch, "commit_hash": "abc"]
        }
        if let parentThreadID {
            payload["parent_thread_id"] = parentThreadID
        }
        return line("session_meta", at: offsetMs, payload: payload)
    }

    static func turnContext(model: String, effort: String?, at offsetMs: Int64 = 0) -> String {
        var payload: [String: Any] = ["model": model, "cwd": "/work/proj"]
        if let effort {
            payload["effort"] = effort
        }
        return line("turn_context", at: offsetMs, payload: payload)
    }

    static func message(
        role: String, parts: [(type: String, text: String)], inherited: Bool = false, at offsetMs: Int64
    ) -> String {
        line("response_item", at: offsetMs, payload: [
            "type": "message", "role": role,
            "content": parts.map { ["type": $0.type, "text": $0.text] },
        ], extra: ["metadata": ["inherited_user_message": inherited]])
    }

    static func user(_ text: String, inherited: Bool = false, at offsetMs: Int64) -> String {
        message(role: "user", parts: [("input_text", text)], inherited: inherited, at: offsetMs)
    }

    static func assistant(_ text: String, at offsetMs: Int64) -> String {
        message(role: "assistant", parts: [("output_text", text)], at: offsetMs)
    }

    static func functionCall(_ name: String, arguments: [String: Any], callID: String, at offsetMs: Int64) -> String {
        let encoded = try! F.jsonLine(arguments)
        return line("response_item", at: offsetMs, payload: [
            "type": "function_call", "name": name, "arguments": encoded, "call_id": callID,
        ])
    }

    static func customToolCall(_ name: String, input: String, callID: String, at offsetMs: Int64) -> String {
        line("response_item", at: offsetMs, payload: [
            "type": "custom_tool_call", "name": name, "input": input, "call_id": callID, "status": "completed",
        ])
    }

    /// A code-mode `exec` call as current Codex writes it: one `tools.exec_command` per command,
    /// `cmd` as a JSON-escaped string literal (or a template literal when `template` is set).
    static func execToolCall(_ commands: [String], template: Bool = false, callID: String, at offsetMs: Int64) -> String {
        let input = commands.map { command -> String in
            let array = try! JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes])
            let literal = template ? "`" + command + "`" : String(String(decoding: array, as: UTF8.self).dropFirst().dropLast())
            return "text(await tools.exec_command({cmd:\(literal),\"max_output_tokens\":6000}));\n"
        }.joined()
        return customToolCall("exec", input: input, callID: callID, at: offsetMs)
    }

    /// The `exec` result: a list of text parts, the command output JSON-encoded in the last one.
    static func execToolCallOutput(_ callID: String, output: String, at offsetMs: Int64) -> String {
        let result = try! F.jsonLine(["chunk_id": "abc123", "exit_code": 0, "output": output])
        return line("response_item", at: offsetMs, payload: [
            "type": "custom_tool_call_output", "call_id": callID,
            "output": [
                ["type": "input_text", "text": "Script completed\nWall time 0.4 seconds\nOutput:\n"],
                ["type": "input_text", "text": result],
            ],
        ])
    }

    static func functionCallOutput(_ callID: String, output: String, at offsetMs: Int64) -> String {
        line("response_item", at: offsetMs, payload: ["type": "function_call_output", "call_id": callID, "output": output])
    }

    static func agentMessage(_ text: String, at offsetMs: Int64) -> String {
        line("response_item", at: offsetMs, payload: [
            "type": "agent_message", "author": "/root", "recipient": "/root/worker",
            "content": [["type": "input_text", "text": text]],
        ])
    }

    static func reasoning(at offsetMs: Int64) -> String {
        line("response_item", at: offsetMs, payload: ["type": "reasoning", "summary": [["type": "summary_text", "text": "thinking hard"]]])
    }

    static func eventMessage(_ text: String, at offsetMs: Int64) -> String {
        line("event_msg", at: offsetMs, payload: ["type": "user_message", "message": text])
    }

    // MARK: - Rollout files

    static func rolloutName(_ id: String, compressed: Bool = false) -> String {
        "rollout-2026-10-30T10-00-00-\(id).jsonl" + (compressed ? ".zst" : "")
    }

    @discardableResult
    static func writeRollout(
        root: URL, id: String, lines: [String], compressed: Bool = false, directory: String = "sessions/2026/10/30"
    ) throws -> URL {
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(rolloutName(id, compressed: compressed))
        let text = lines.map { $0 + "\n" }.joined()
        if compressed {
            try Data(zstdFrame(Array(text.utf8))).write(to: url)
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    /// A single-segment Zstandard frame of raw (stored) blocks with the content size in the
    /// header: valid input for the vendored decoder without a compressor.
    static func zstdFrame(_ content: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        let size = content.count
        if size <= 255 {
            bytes += [0x20, UInt8(size)]
        } else if size <= 65_791 {
            let stored = size - 256
            bytes += [0x60, UInt8(stored & 0xFF), UInt8(stored >> 8)]
        } else {
            bytes += [0xA0] + (0 ..< 4).map { UInt8((size >> ($0 * 8)) & 0xFF) }
        }
        let blockMax = 128 * 1024
        var start = 0
        repeat {
            let end = min(start + blockMax, size)
            let isLast = end == size
            let value = UInt32(isLast ? 1 : 0) | UInt32(end - start) << 3
            bytes += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
            bytes += content[start ..< end]
            start = end
        } while start < size
        return bytes
    }

    // MARK: - state_5.sqlite

    struct ThreadRow {
        var id: String
        var rolloutPath = "/unused/rollout.jsonl"
        var cwd = "/work/proj"
        var title = ""
        var name: String?
        var firstUserMessage = ""
        var model: String?
        var effort: String?
        var branch: String?
        var archived = false
        var createdAtMs: Int64 = baseMs
        var updatedAtMs: Int64 = baseMs
        var source = "cli"
        var threadSource: String?
        var attachedParent: String?
    }

    static let fullThreadsSchema = """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
          git_branch TEXT, first_user_message TEXT NOT NULL DEFAULT '', model TEXT, reasoning_effort TEXT,
          created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT, name TEXT, attached_thread_parent_id TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
        """

    /// Creates (or rewrites rows of) `state_5.sqlite`. The writer is closed before returning.
    static func writeCatalog(root: URL, rows: [ThreadRow], spawnEdges: [(parent: String, child: String)] = [],
                             schema: String = fullThreadsSchema) throws {
        let url = root.appendingPathComponent(CodexThreadCatalog.databaseFileName)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        let database = try AgentHistoryDatabase(url: url, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        defer { database.close() }
        if isNew {
            try database.execute(schema)
        }
        for row in rows {
            try database.run(
                """
                INSERT OR REPLACE INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, archived, git_branch,
                  first_user_message, model, reasoning_effort, created_at_ms, updated_at_ms, thread_source, name, attached_thread_parent_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(row.id), .text(row.rolloutPath), .integer(row.createdAtMs / 1000), .integer(row.updatedAtMs / 1000),
                 .text(row.source), .text(row.cwd), .text(row.title), .integer(row.archived ? 1 : 0), .of(row.branch),
                 .text(row.firstUserMessage), .of(row.model), .of(row.effort), .integer(row.createdAtMs), .integer(row.updatedAtMs),
                 .of(row.threadSource), .of(row.name), .of(row.attachedParent)]
            )
        }
        for edge in spawnEdges {
            try database.run("INSERT INTO thread_spawn_edges VALUES (?, ?, 'open')", [.text(edge.parent), .text(edge.child)])
        }
    }

    // MARK: - Ingest helpers

    static func unit(_ source: CodexHistorySource, key: String) throws -> AgentHistoryUnit {
        try XCTUnwrap(try source.discoverUnits().first { $0.key == key })
    }

    /// Ingests a unit to the end (following `hasMore`), returning every batch.
    static func ingestAll(
        _ source: CodexHistorySource, unit: AgentHistoryUnit, cursor: AgentHistoryCursor? = nil,
        mode: AgentHistoryIngestMode = .fromStart, context: AgentHistoryIngestContext = F.context()
    ) throws -> [AgentHistoryIngestBatch] {
        var batches: [AgentHistoryIngestBatch] = []
        var mode = mode
        while true {
            let batch = try source.ingest(unit: unit, cursor: batches.last?.cursor ?? cursor, mode: mode, context: context)
            batches.append(batch)
            guard batch.hasMore, batches.count < 1_000 else {
                return batches
            }
            mode = .fromOffset(batch.cursor.byteOffset, nextSeq: batch.cursor.nextSeq)
        }
    }
}
