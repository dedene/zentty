import Foundation

/// The `history` payload of an IPC response. Exactly one side is set. The JSON keys are the
/// `zentty history --json` output keys, so changing a property name changes the CLI contract.
struct HistoryIPCResult: Codable, Equatable, Sendable {
    let search: HistorySearchIPCResponse?
    let show: HistoryShowIPCResponse?

    init(search: HistorySearchIPCResponse? = nil, show: HistoryShowIPCResponse? = nil) {
        self.search = search
        self.show = show
    }
}

struct HistorySearchIPCResponse: Codable, Equatable, Sendable {
    /// `project` or `all`.
    let scope: String
    let project: String?
    let indexedSessions: Int
    /// False while the index is still backfilling.
    let complete: Bool
    let contentIsUntrusted: Bool
    let results: [HistorySearchIPCHit]

    init(
        scope: String,
        project: String?,
        indexedSessions: Int,
        complete: Bool,
        contentIsUntrusted: Bool = true,
        results: [HistorySearchIPCHit]
    ) {
        self.scope = scope
        self.project = project
        self.indexedSessions = indexedSessions
        self.complete = complete
        self.contentIsUntrusted = contentIsUntrusted
        self.results = results
    }
}

struct HistorySearchIPCHit: Codable, Equatable, Sendable {
    let agent: String
    let sessionId: String
    let title: String
    let cwd: String?
    let branch: String?
    /// ISO 8601, UTC.
    let updatedAt: String
    let live: Bool
    let match: HistoryIPCMatch?
    let resumeCommand: String?

    init(
        agent: String,
        sessionId: String,
        title: String,
        cwd: String?,
        branch: String?,
        updatedAt: String,
        live: Bool,
        match: HistoryIPCMatch?,
        resumeCommand: String?
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.updatedAt = updatedAt
        self.live = live
        self.match = match
        self.resumeCommand = resumeCommand
    }
}

/// Why a hit matched: a quoted message (`role`, `at`, `snippet`) or a metadata field
/// (`field`, `value`). Unset keys are left out of the JSON.
struct HistoryIPCMatch: Codable, Equatable, Sendable {
    let role: String?
    let at: String?
    let snippet: String?
    let field: String?
    let value: String?

    static func content(role: String, at: String, snippet: String) -> HistoryIPCMatch {
        HistoryIPCMatch(role: role, at: at, snippet: snippet, field: nil, value: nil)
    }

    static func metadata(field: String, value: String) -> HistoryIPCMatch {
        HistoryIPCMatch(role: nil, at: nil, snippet: nil, field: field, value: value)
    }
}

struct HistoryShowIPCResponse: Codable, Equatable, Sendable {
    let scope: String
    let project: String?
    let agent: String
    let sessionId: String
    let title: String
    let cwd: String?
    let branch: String?
    let model: String?
    let effort: String?
    let createdAt: String
    let updatedAt: String
    let live: Bool
    let totalTurns: Int
    /// Turns older than the ones returned, whether cut by `--turns` or by the byte budget.
    let omittedTurns: Int
    /// Oldest first, newest last.
    let turns: [HistoryIPCTurn]
    let resumeCommand: String?
    let contentIsUntrusted: Bool

    init(
        scope: String,
        project: String?,
        agent: String,
        sessionId: String,
        title: String,
        cwd: String?,
        branch: String?,
        model: String?,
        effort: String?,
        createdAt: String,
        updatedAt: String,
        live: Bool,
        totalTurns: Int,
        omittedTurns: Int,
        turns: [HistoryIPCTurn],
        resumeCommand: String?,
        contentIsUntrusted: Bool = true
    ) {
        self.scope = scope
        self.project = project
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.model = model
        self.effort = effort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.live = live
        self.totalTurns = totalTurns
        self.omittedTurns = omittedTurns
        self.turns = turns
        self.resumeCommand = resumeCommand
        self.contentIsUntrusted = contentIsUntrusted
    }

    /// Drops the oldest turns until the encoded response fits `maxBytes`, adding them to
    /// `omittedTurns`. Sizes are measured on the JSON, so escape-heavy text is counted as sent.
    func fittingByteBudget(_ maxBytes: Int) throws -> HistoryShowIPCResponse {
        let keptCount = try HistoryIPCByteBudget.fittingSuffixCount(
            of: turns,
            maxBytes: maxBytes,
            whole: self,
            emptied: keeping(lastTurns: 0)
        )
        return keptCount == turns.count ? self : keeping(lastTurns: keptCount)
    }

    private func keeping(lastTurns count: Int) -> HistoryShowIPCResponse {
        HistoryShowIPCResponse(
            scope: scope,
            project: project,
            agent: agent,
            sessionId: sessionId,
            title: title,
            cwd: cwd,
            branch: branch,
            model: model,
            effort: effort,
            createdAt: createdAt,
            updatedAt: updatedAt,
            live: live,
            totalTurns: totalTurns,
            omittedTurns: omittedTurns + (turns.count - count),
            turns: Array(turns.suffix(count)),
            resumeCommand: resumeCommand,
            contentIsUntrusted: contentIsUntrusted
        )
    }
}

struct HistoryIPCTurn: Codable, Equatable, Sendable {
    /// `user` or `agent`.
    let role: String
    let at: String
    let text: String
    let truncated: Bool
}

extension HistorySearchIPCResponse {
    /// Drops hits from the tail (lowest ranked) until the encoded response fits `maxBytes`.
    func fittingByteBudget(_ maxBytes: Int) throws -> HistorySearchIPCResponse {
        let reversedResults = Array(results.reversed())
        let keptCount = try HistoryIPCByteBudget.fittingSuffixCount(
            of: reversedResults,
            maxBytes: maxBytes,
            whole: self,
            emptied: keeping(firstResults: 0)
        )
        return keptCount == results.count ? self : keeping(firstResults: keptCount)
    }

    private func keeping(firstResults count: Int) -> HistorySearchIPCResponse {
        HistorySearchIPCResponse(
            scope: scope,
            project: project,
            indexedSessions: indexedSessions,
            complete: complete,
            contentIsUntrusted: contentIsUntrusted,
            results: Array(results.prefix(count))
        )
    }
}

enum HistoryIPCText {
    /// Cuts `text` to at most `maxBytes` of UTF-8 without splitting a character.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var usedBytes = 0
        var end = text.startIndex
        for index in text.indices {
            let characterBytes = text[index].utf8.count
            guard usedBytes + characterBytes <= maxBytes else { break }
            usedBytes += characterBytes
            end = text.index(after: index)
        }
        return (String(text[..<end]), true)
    }
}

enum HistoryIPCDates {
    /// ISO 8601 in UTC, whole seconds (`2026-10-29T14:02:00Z`).
    static func iso8601(milliseconds: Int64) -> String {
        let seconds = (Double(milliseconds) / 1000).rounded(.down)
        return Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle())
    }

    /// Accepts the format above, with or without fractional seconds.
    static func parse(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle().parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    }
}

/// Fits a response to a byte budget by keeping the longest suffix of one of its arrays.
private enum HistoryIPCByteBudget {
    /// - Parameters:
    ///   - elements: the droppable elements, ordered so the ones to keep longest come last.
    ///   - whole: the full response, returned untouched when it already fits.
    ///   - emptied: the response with every droppable element removed (and counted as dropped),
    ///     so its size is an upper bound for the fixed part.
    /// - Returns: how many trailing `elements` fit.
    static func fittingSuffixCount<Element: Encodable, Response: Encodable>(
        of elements: [Element],
        maxBytes: Int,
        whole: Response,
        emptied: Response
    ) throws -> Int {
        let encoder = JSONEncoder()
        if try encoder.encode(whole).count <= maxBytes {
            return elements.count
        }
        let fixedBytes = try encoder.encode(emptied).count
        guard fixedBytes <= maxBytes else {
            throw HistoryIPCError.responseTooLarge
        }
        // In compact JSON each kept element adds its own encoding plus one comma after the first.
        var remaining = maxBytes - fixedBytes
        var kept = 0
        for element in elements.reversed() {
            let cost = try encoder.encode(element).count + (kept > 0 ? 1 : 0)
            guard cost <= remaining else { break }
            remaining -= cost
            kept += 1
        }
        return kept
    }
}
