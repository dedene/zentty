import Foundation

/// The human output of `zentty history search` and `show`. Compiled into both the app and the
/// CLI, so it may only use Foundation and the shared `HistoryIPC*` types.
///
/// Everything taken from the index (titles, snippets, turns, paths, commands) is quoted from past
/// sessions. Control characters in it are printed escaped (`\u{1B}`), so a session can't move the
/// cursor, clear the screen or restyle the caller's terminal.
enum HistoryIPCFormatting {
    static func searchText(
        _ response: HistorySearchIPCResponse,
        query: String,
        homeDirectory: String,
        timeZone: TimeZone
    ) -> String {
        let projectScope = response.scope == "project" ? response.project : nil
        guard !response.results.isEmpty else {
            return emptySearchText(response, query: query, project: projectScope, homeDirectory: homeDirectory)
        }

        let count = response.results.count
        let place = projectScope.map { "in " + abbreviated($0, homeDirectory: homeDirectory) }
            ?? "across all projects"
        var header = "\(count) \(count == 1 ? "session" : "sessions") \(place)"
        if !response.complete {
            header += "  (index still building; older sessions may be missing)"
        }

        let dates = DateText(timeZone: timeZone)
        let blocks = response.results.enumerated().map { offset, hit in
            searchBlock(hit, number: offset + 1, homeDirectory: homeDirectory, dates: dates)
        }
        return ([header] + blocks + [HistoryIPC.untrustedNote]).joined(separator: "\n\n")
    }

    static func showText(
        _ response: HistoryShowIPCResponse,
        homeDirectory: String,
        timeZone: TimeZone
    ) -> String {
        let dates = DateText(timeZone: timeZone)
        let model = response.model.map(singleLine).map { model in
            response.effort.map { "\(model) (\(singleLine($0)))" } ?? model
        }
        let meta: [String?] = [
            singleLine(response.agent),
            response.cwd.map { abbreviated($0, homeDirectory: homeDirectory) },
            response.branch.map(singleLine),
            model,
            "updated " + dates.text(response.updatedAt),
            response.live ? "live" : nil,
        ]

        var sessionLine = "Session: " + singleLine(response.sessionId)
        if let resumeCommand = response.resumeCommand {
            sessionLine += " · Resume: " + singleLine(resumeCommand)
        }
        var header = [title(response.title), joinedMeta(meta), sessionLine]
        if response.omittedTurns > 0 {
            header.append("Showing the last \(response.turns.count) of \(response.totalTurns) turns.")
        }

        guard !response.turns.isEmpty else {
            return (header + ["This session has no turns to show."]).joined(separator: "\n")
        }
        let turns = response.turns.map { turn in
            var lines = ["\(roleLabel(turn.role)) · \(dates.text(turn.at))"]
            lines += indentedLines(turn.text)
            if turn.truncated {
                lines.append("  [truncated]")
            }
            return lines.joined(separator: "\n")
        }
        return ([header.joined(separator: "\n")] + turns + [HistoryIPC.untrustedNote]).joined(separator: "\n\n")
    }

    /// The line under a search hit that says why it matched: the quoted message for a content
    /// hit (`You: …`), the field for a metadata hit (`Branch: main`), nothing for a title hit.
    static func matchReason(_ match: HistoryIPCMatch) -> String? {
        if let snippet = match.snippet {
            return roleLabel(match.role ?? "") + ": " + singleLine(snippet)
        }
        guard let field = match.field, let value = match.value, field != "title" else {
            return nil
        }
        let label = switch field {
        case "branch": "Branch"
        case "repo": "Repo"
        case "folder": "Folder"
        case "path": "Changed"
        case "command": "Ran"
        case "commit": "Commit"
        case "pr": "PR"
        default: singleLine(field).capitalized
        }
        return label + ": " + singleLine(value)
    }

    /// `~` for the home directory and `~/…` below it; other paths unchanged. Only whole path
    /// components count, so `/Users/someoneelse` is not under `/Users/someone`.
    static func abbreviated(_ path: String, homeDirectory: String) -> String {
        var home = Substring(homeDirectory)
        while home.count > 1 && home.hasSuffix("/") {
            home = home.dropLast()
        }
        let visiblePath = singleLine(path)
        guard home.count > 1 else { return visiblePath }
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + singleLine(String(path.dropFirst(home.count)))
        }
        return visiblePath
    }

    // MARK: - Search

    private static func emptySearchText(
        _ response: HistorySearchIPCResponse,
        query: String,
        project: String?,
        homeDirectory: String
    ) -> String {
        let place = project.map { abbreviated($0, homeDirectory: homeDirectory) } ?? "any project"
        var lines = ["No sessions in \(place) match \"\(singleLine(query))\"."]
        if project != nil {
            lines.append("Try --all to search every project.")
        }
        if !response.complete {
            lines.append("The index is still building, so older sessions may be missing.")
        }
        return lines.joined(separator: "\n")
    }

    private static func searchBlock(
        _ hit: HistorySearchIPCHit,
        number: Int,
        homeDirectory: String,
        dates: DateText
    ) -> String {
        let meta: [String?] = [
            singleLine(hit.agent),
            hit.branch.map(singleLine),
            hit.cwd.map { abbreviated($0, homeDirectory: homeDirectory) },
            dates.text(hit.updatedAt),
            hit.live ? "live" : nil,
        ]
        var lines = ["\(number). \(title(hit.title))", "   " + joinedMeta(meta)]
        if let reason = hit.match.flatMap(matchReason) {
            lines.append("   " + reason)
        }
        if let resumeCommand = hit.resumeCommand {
            lines.append("   Resume: " + singleLine(resumeCommand))
        } else {
            lines.append("   Session: \(singleLine(hit.agent)) \(singleLine(hit.sessionId))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text

    private static func title(_ value: String) -> String {
        let title = singleLine(value)
        return title.isEmpty ? "Untitled session" : title
    }

    private static func joinedMeta(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func roleLabel(_ role: String) -> String {
        switch role {
        case "user": "You"
        case "agent": "Agent"
        default: singleLine(role).capitalized
        }
    }

    /// Whitespace runs (newlines included) become one space; other control characters are escaped.
    private static func singleLine(_ value: String) -> String {
        let words = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return escapingControls(words.joined(separator: " "))
    }

    /// Each line indented two spaces, controls other than tab escaped.
    private static func indentedLines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { line in
            line.isEmpty ? "" : "  " + escapingControls(line, keepingTabs: true)
        }
    }

    private static func escapingControls(_ value: String, keepingTabs: Bool = false) -> String {
        guard value.unicodeScalars.contains(where: { isEscaped($0, keepingTabs: keepingTabs) }) else {
            return value
        }
        return value.unicodeScalars.map { scalar in
            isEscaped(scalar, keepingTabs: keepingTabs) ? scalar.escaped(asASCII: true) : String(scalar)
        }.joined()
    }

    private static func isEscaped(_ scalar: Unicode.Scalar, keepingTabs: Bool) -> Bool {
        guard scalar.properties.generalCategory == .control else { return false }
        return !(keepingTabs && scalar == "\t")
    }

    /// `2026-10-29 14:02` in the caller's time zone; the raw value when it isn't ISO 8601.
    private struct DateText {
        let formatter: DateFormatter

        init(timeZone: TimeZone) {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }

        func text(_ iso8601: String) -> String {
            guard let date = HistoryIPCDates.parse(iso8601) else {
                return HistoryIPCFormatting.singleLine(iso8601)
            }
            return formatter.string(from: date)
        }
    }
}
