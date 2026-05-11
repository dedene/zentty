import Foundation

struct CodexTranscriptQuestion: Equatable, Sendable {
    let text: String
    let interactionKind: PaneAgentInteractionKind
}

struct CodexTranscriptQuestionRequest: Equatable, Sendable {
    let sessionID: String?
    let transcriptPath: String
}

struct CodexTranscriptQuestionCacheKey: Hashable, Sendable {
    let path: String
    let fileSize: UInt64
    let modificationDate: Date?
}

enum CodexTranscriptQuestionExtractor {
    private static let maxTailBytes: UInt64 = 256 * 1024
    private static let maxTranscriptCandidates = 12
    private static let maxSessionDayDirectories = 4

    static func question(fromTranscriptPath path: String) -> CodexTranscriptQuestion? {
        guard let text = readTextFileTail(path: path, maxBytes: maxTailBytes) else {
            return nil
        }
        return question(fromTranscriptText: text)
    }

    static func question(fromTranscriptText text: String) -> CodexTranscriptQuestion? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = responsePayload(from: object),
                  (payload["type"] as? String) == "function_call",
                  isQuestionToolName(payload["name"] as? String),
                  let toolInput = toolInput(fromArguments: payload["arguments"]),
                  let question = question(fromToolInput: toolInput) else {
                continue
            }
            return question
        }
        return nil
    }

    static func question(fromToolInput toolInput: [String: Any]) -> CodexTranscriptQuestion? {
        let first = (toolInput["questions"] as? [[String: Any]])?.first ?? toolInput

        var lines: [String] = []
        if let question = trimmed(first["question"] as? String) {
            lines.append(question)
        } else if let header = trimmed(first["header"] as? String) {
            lines.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { option in
                trimmed(option["label"] as? String)
            }
            if !labels.isEmpty {
                lines.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        guard !lines.isEmpty else {
            return nil
        }
        return CodexTranscriptQuestion(text: lines.joined(separator: "\n"), interactionKind: .decision)
    }

    static func locateRecentTranscriptPath(
        workingDirectory: String?,
        environment: [String: String],
        now _: Date = Date(),
        fileManager: FileManager = .default
    ) -> String? {
        let codexHome = trimmed(environment["CODEX_HOME"])
            ?? NSHomeDirectory().appending("/.codex")
        let sessionsURL = URL(fileURLWithPath: NSString(string: codexHome).expandingTildeInPath)
            .appendingPathComponent("sessions", isDirectory: true)
        let normalizedWorkingDirectory = normalizedPath(workingDirectory)

        let candidates = recentTranscriptCandidates(
            sessionsURL: sessionsURL,
            fileManager: fileManager
        )
        guard !candidates.isEmpty else {
            return nil
        }

        guard let normalizedWorkingDirectory else {
            return nil
        }
        for candidate in candidates {
            guard let text = readTextFileTail(path: candidate.path, maxBytes: maxTailBytes),
                  transcriptText(text, containsWorkingDirectory: normalizedWorkingDirectory),
                  question(fromTranscriptText: text) != nil else {
                continue
            }
            return candidate.path
        }
        return nil
    }

    static func cacheKey(forTranscriptPath path: String) -> CodexTranscriptQuestionCacheKey? {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardized),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }

        return CodexTranscriptQuestionCacheKey(
            path: standardized,
            fileSize: size,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private struct TranscriptCandidate {
        let url: URL
        let modificationDate: Date

        var path: String {
            (url.path as NSString).standardizingPath
        }
    }

    private static func recentTranscriptCandidates(
        sessionsURL: URL,
        fileManager: FileManager
    ) -> [TranscriptCandidate] {
        let dayDirectories = recentSessionDayDirectories(sessionsURL: sessionsURL, fileManager: fileManager)
        let candidates = dayDirectories.flatMap { dayURL in
            ((try? fileManager.contentsOfDirectory(
                at: dayURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []).compactMap { url -> TranscriptCandidate? in
                guard url.pathExtension == "jsonl" else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true,
                      let modificationDate = values?.contentModificationDate else {
                    return nil
                }
                return TranscriptCandidate(url: url, modificationDate: modificationDate)
            }
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.modificationDate == rhs.modificationDate {
                    return lhs.path > rhs.path
                }
                return lhs.modificationDate > rhs.modificationDate
            }
            .prefix(maxTranscriptCandidates)
            .map { $0 }
    }

    private static func recentSessionDayDirectories(
        sessionsURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let years = directoryChildren(of: sessionsURL, fileManager: fileManager)
        let months = years.flatMap { directoryChildren(of: $0, fileManager: fileManager) }
        let days = months.flatMap { directoryChildren(of: $0, fileManager: fileManager) }
        return days
            .sorted { $0.path > $1.path }
            .prefix(maxSessionDayDirectories)
            .map { $0 }
    }

    private static func directoryChildren(of url: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func transcriptText(_ text: String, containsWorkingDirectory workingDirectory: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmedLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let payload = (object["payload"] as? [String: Any]) ?? object
            let cwd = (payload["cwd"] as? String)
                ?? (payload["current_working_directory"] as? String)
                ?? (payload["currentWorkingDirectory"] as? String)
            guard let cwd else {
                continue
            }
            return normalizedPath(cwd) == workingDirectory
        }
        return false
    }

    private static func responsePayload(from object: [String: Any]) -> [String: Any]? {
        if (object["type"] as? String) == "response_item" {
            return object["payload"] as? [String: Any]
        }
        return object
    }

    private static func toolInput(fromArguments arguments: Any?) -> [String: Any]? {
        if let dictionary = arguments as? [String: Any] {
            return dictionary
        }
        guard let string = arguments as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func isQuestionToolName(_ value: String?) -> Bool {
        guard let value = trimmed(value) else {
            return false
        }
        let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "requestuserinput"
            || normalized == "askuserquestion"
            || normalized == "askuserquestiontool"
    }

    private static func readTextFileTail(path: String, maxBytes: UInt64) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expanded)) else {
            return nil
        }
        defer { try? handle.close() }

        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > maxBytes ? endOffset - maxBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }

        var data = handle.readDataToEndOfFile()
        if startOffset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(0...newline)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else {
            return nil
        }
        return (NSString(string: NSString(string: trimmed).expandingTildeInPath).standardizingPath)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
