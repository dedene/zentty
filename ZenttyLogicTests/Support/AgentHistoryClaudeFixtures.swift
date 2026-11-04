import Foundation
@testable import Zentty

/// Claude Code transcript line builders. Lines go through `jsonLine` (sorted keys), so `type`
/// lands after `message` the way it does in real `assistant` records.
extension AgentHistoryFixtures {
    static let claudeSessionID = "3f2a9c1e-6d1b-4c7e-9a2f-0b1c2d3e4f50"
    static let claudeCwd = "/Users/example/dev/app"
    static let claudeBaseMs: Int64 = 1_790_000_000_000

    /// `[^A-Za-z0-9]` → `-`, the way Claude Code names project folders.
    static func claudeProjectDirectoryName(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func claudeTimestamp(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }

    static func claudeTextPart(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func claudeToolUse(_ name: String, id: String = "toolu_\(UUID().uuidString.prefix(8))", input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    /// A main-chain user record. `content` is a string or an array of parts.
    static func claudeUser(
        _ content: Any,
        atMs: Int64 = claudeBaseMs,
        cwd: String? = claudeCwd,
        branch: String? = "main",
        sessionID: String = claudeSessionID,
        extra: [String: Any] = [:]
    ) throws -> String {
        var object: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString.lowercased(),
            "sessionId": sessionID,
            "timestamp": claudeTimestamp(atMs),
            "isSidechain": false,
            "userType": "external",
            "message": ["role": "user", "content": content],
        ]
        object["cwd"] = cwd
        object["gitBranch"] = branch
        object.merge(extra) { _, new in new }
        return try jsonLine(object)
    }

    static func claudeAssistant(
        _ parts: [[String: Any]],
        atMs: Int64 = claudeBaseMs,
        model: String? = "claude-opus-5-5",
        requestedModel: String? = nil,
        effort: String? = nil,
        cwd: String? = claudeCwd,
        branch: String? = "main",
        sessionID: String = claudeSessionID,
        extra: [String: Any] = [:]
    ) throws -> String {
        var message: [String: Any] = ["role": "assistant", "type": "message", "content": parts]
        message["model"] = model
        var object: [String: Any] = [
            "type": "assistant",
            "uuid": UUID().uuidString.lowercased(),
            "sessionId": sessionID,
            "timestamp": claudeTimestamp(atMs),
            "isSidechain": false,
            "message": message,
        ]
        object["cwd"] = cwd
        object["gitBranch"] = branch
        object["requestedModel"] = requestedModel
        object["effort"] = effort
        object.merge(extra) { _, new in new }
        return try jsonLine(object)
    }

    /// `custom-title` (`customTitle`), `ai-title` (`aiTitle`) or legacy `summary` (`summary`).
    static func claudeTitle(_ type: String, _ value: String, sessionID: String = claudeSessionID) throws -> String {
        let key: String
        switch type {
        case "custom-title": key = "customTitle"
        case "ai-title": key = "aiTitle"
        default: key = "summary"
        }
        var object: [String: Any] = ["type": type, key: value]
        if type != "summary" {
            object["sessionId"] = sessionID
        } else {
            object["leafUuid"] = UUID().uuidString.lowercased()
        }
        return try jsonLine(object)
    }

    static func claudePRLink(_ url: String, atMs: Int64 = claudeBaseMs, sessionID: String = claudeSessionID) throws -> String {
        try jsonLine([
            "type": "pr-link",
            "sessionId": sessionID,
            "prNumber": 1,
            "prUrl": url,
            "timestamp": claudeTimestamp(atMs),
        ])
    }

    /// A user record carrying a tool result; `gitOperation` goes inside `toolUseResult`.
    static func claudeToolResult(
        toolUseID: String,
        stdout: String,
        gitOperation: [String: Any]? = nil,
        atMs: Int64 = claudeBaseMs,
        cwd: String = claudeCwd,
        sessionID: String = claudeSessionID
    ) throws -> String {
        var result: [String: Any] = ["stdout": stdout, "stderr": "", "interrupted": false]
        result["gitOperation"] = gitOperation
        return try jsonLine([
            "type": "user",
            "uuid": UUID().uuidString.lowercased(),
            "sessionId": sessionID,
            "timestamp": claudeTimestamp(atMs),
            "isSidechain": false,
            "cwd": cwd,
            "gitBranch": "main",
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": toolUseID, "content": stdout]],
            ],
            "toolUseResult": result,
        ])
    }
}
