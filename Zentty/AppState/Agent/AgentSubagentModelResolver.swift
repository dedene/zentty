import Foundation

/// Best-effort lookup of the model a subagent runs on. No agent CLI puts the
/// model in its hook payload, so this reads the small sidecar files each CLI
/// leaves next to the subagent transcript:
///
/// - Claude Code: `agent-<id>.meta.json` next to the transcript (written at
///   spawn, carries `model` only when the parent chose one explicitly), else
///   the first assistant line of the subagent transcript (`message.model`).
/// - Codex: the sub-thread rollout's `session_meta` (nickname, role) and its
///   first `turn_context` (`model`).
///
/// All reads are bounded to the head of the file and fail soft to `nil`.
enum AgentSubagentModelResolver {
    struct CodexThreadInfo: Equatable {
        var model: String?
        var nickname: String?
        var role: String?
    }

    static let maxHeadBytes = 256 * 1024

    // MARK: - Claude

    static func claudeModel(agentTranscriptPath: String?) -> String? {
        guard let agentTranscriptPath, !agentTranscriptPath.isEmpty else { return nil }
        if let model = claudeMetaModel(agentTranscriptPath: agentTranscriptPath) {
            return model
        }
        return claudeTranscriptModel(transcriptPath: agentTranscriptPath)
    }

    /// `…/subagents/agent-<id>.jsonl` → `…/subagents/agent-<id>.meta.json`.
    static func claudeMetaPath(agentTranscriptPath: String) -> String {
        guard agentTranscriptPath.hasSuffix(".jsonl") else {
            return agentTranscriptPath + ".meta.json"
        }
        return String(agentTranscriptPath.dropLast(".jsonl".count)) + ".meta.json"
    }

    /// Derives the subagent transcript path from the parent transcript and the
    /// agent id when the hook does not provide `agent_transcript_path`.
    static func claudeAgentTranscriptPath(sessionTranscriptPath: String?, agentID: String?) -> String? {
        guard let sessionTranscriptPath, let agentID, !agentID.isEmpty,
              sessionTranscriptPath.hasSuffix(".jsonl") else {
            return nil
        }
        let sessionDirectory = String(sessionTranscriptPath.dropLast(".jsonl".count))
        let fileName = agentID.hasPrefix("agent-") ? "\(agentID).jsonl" : "agent-\(agentID).jsonl"
        return sessionDirectory + "/subagents/" + fileName
    }

    static func claudeMetaModel(agentTranscriptPath: String) -> String? {
        let metaPath = claudeMetaPath(agentTranscriptPath: agentTranscriptPath)
        guard let data = readHead(path: metaPath, maxBytes: 64 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmpty(object["model"] as? String)
    }

    static func claudeTranscriptModel(transcriptPath: String) -> String? {
        guard let text = readHeadText(path: transcriptPath) else { return nil }
        return claudeTranscriptModel(transcriptText: text)
    }

    static func claudeTranscriptModel(transcriptText: String) -> String? {
        for line in text(transcriptText) {
            guard line.contains("\"model\""), let object = jsonObject(from: line) else { continue }
            if let message = object["message"] as? [String: Any], let model = nonEmpty(message["model"] as? String) {
                return model
            }
            if let model = nonEmpty(object["model"] as? String) {
                return model
            }
        }
        return nil
    }

    // MARK: - Codex

    static func codexThreadInfo(rolloutPath: String?) -> CodexThreadInfo? {
        guard let rolloutPath, !rolloutPath.isEmpty, let text = readHeadText(path: rolloutPath) else { return nil }
        return codexThreadInfo(rolloutText: text)
    }

    static func codexThreadInfo(rolloutText: String) -> CodexThreadInfo? {
        var info = CodexThreadInfo()
        var sawAnything = false
        for line in text(rolloutText) {
            guard let object = jsonObject(from: line),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            switch type {
            case "session_meta":
                sawAnything = true
                if let source = payload["source"] as? [String: Any],
                   let subagent = source["subagent"] as? [String: Any],
                   let spawn = subagent["thread_spawn"] as? [String: Any] {
                    info.nickname = nonEmpty(spawn["agent_nickname"] as? String)
                    info.role = nonEmpty(spawn["agent_role"] as? String)
                }
            case "turn_context":
                sawAnything = true
                if info.model == nil, let model = nonEmpty(payload["model"] as? String) {
                    info.model = model
                }
            default:
                continue
            }
            if info.model != nil, info.nickname != nil {
                break
            }
        }
        return sawAnything ? info : nil
    }

    // MARK: - IO

    private static func readHead(path: String, maxBytes: Int = maxHeadBytes) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    private static func readHeadText(path: String) -> String? {
        guard let data = readHead(path: path), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(_ value: String) -> [Substring] {
        value.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private static func jsonObject(from line: Substring) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
