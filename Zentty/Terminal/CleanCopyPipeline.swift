import AppKit

extension Notification.Name {
    static let cleanCopyDidModifyPasteboard = Notification.Name("CleanCopyDidModifyPasteboard")
}

enum CleanCopyPipeline {
    nonisolated(unsafe) static var isAutoCleanEnabled: Bool = false
    nonisolated(unsafe) static var suppressCallbackCleaning: Bool = false

    struct Result: Equatable {
        let text: String
        let wasModified: Bool
    }

    // MARK: - Public API

    static func clean(_ input: String) -> Result {
        var text = input
        text = stripANSIEscapes(text)
        let lineShapeEvidence = PlainProseLineShapeEvidence(input: text)
        text = trimTrailingWhitespacePerLine(text)
        text = trimTrailingBlankLines(text)
        if let cleaned = stripAgentPromptSelection(text) {
            text = cleaned
        }
        text = stripPrompts(text)
        text = stripLineNumberPrefixes(text)
        if let cleaned = stripBoxDrawingArtifacts(text) {
            text = cleaned
        }
        if let cleaned = reflowPlainProseSelection(text, lineShapeEvidence: lineShapeEvidence) {
            text = cleaned
        }
        text = dedentCommonPrefix(text)
        return Result(text: text, wasModified: text != input)
    }

    static func shouldCleanTerminalCopyAction(
        isAutoCleanEnabled: Bool = Self.isAutoCleanEnabled,
        suppressCallbackCleaning: Bool = Self.suppressCallbackCleaning
    ) -> Bool {
        isAutoCleanEnabled && !suppressCallbackCleaning
    }

    @discardableResult
    static func cleanPasteboardInPlace(_ pasteboard: NSPasteboard) -> Result? {
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let result = clean(raw)
        if result.wasModified {
            pasteboard.setString(result.text, forType: .string)
        }
        return result
    }

    // MARK: - Pass 1: ANSI Escape Removal

    static func stripANSIEscapes(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        // CSI sequences: \e[...letter
        // OSC sequences: \e]...(\a | \e\\)
        // Character set designations: \e(B etc.
        // Private mode set/reset: \e[?...h/l
        let pattern = #"\x1B(?:\[[0-9;?]*[A-Za-z]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-Z0-9]|=[^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    // MARK: - Pass 2: Trailing Whitespace Per Line

    static func trimTrailingWhitespacePerLine(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.map { line -> Substring in
            var end = line.endIndex
            while end > line.startIndex {
                let prev = line.index(before: end)
                let char = line[prev]
                guard char == " " || char == "\t" else { break }
                end = prev
            }
            return line[line.startIndex..<end]
        }
        return trimmed.joined(separator: "\n")
    }

    // MARK: - Pass 3: Trailing Blank Lines

    static func trimTrailingBlankLines(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        let hadTrailingNewline = input.last == "\n"
        var lines = input.split(separator: "\n", omittingEmptySubsequences: false)

        while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
            lines.removeLast()
            if lines.isEmpty { break }
        }

        guard !lines.isEmpty else { return "" }

        var result = lines.joined(separator: "\n")
        if hadTrailingNewline {
            result.append("\n")
        }
        return result
    }

    // MARK: - Pass 4: Prompt Detection

    static func stripPrompts(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !nonEmptyLines.isEmpty else { return input }

        let bestPrompt = detectPromptPattern(nonEmptyLines: nonEmptyLines)
        guard let prompt = bestPrompt else { return input }

        let stripped = lines.map { line -> String in
            stripDetectedPrompt(prompt, from: line)
        }
        return stripped.joined(separator: "\n")
    }

    private static func stripDetectedPrompt(_ prompt: String, from line: Substring) -> String {
        if line.hasPrefix(prompt) {
            return String(line.dropFirst(prompt.count))
        }

        let firstContentIndex = line.firstIndex { character in
            character != " " && character != "\t"
        } ?? line.endIndex
        guard firstContentIndex != line.startIndex else { return String(line) }

        let remainder = line[firstContentIndex...]
        if remainder.hasPrefix(prompt) {
            return String(remainder.dropFirst(prompt.count))
        }
        return String(line)
    }

    private static func detectPromptPattern(nonEmptyLines: [Substring]) -> String? {
        let candidates = ["$ ", "> ", "# "]
        let lineCount = nonEmptyLines.count

        for candidate in candidates {
            let matchCount = nonEmptyLines.count(where: { $0.hasPrefix(candidate) })

            if lineCount <= 3 {
                // Short selection: strip if first non-empty line matches
                if nonEmptyLines.first?.hasPrefix(candidate) == true {
                    return candidate
                }
            } else {
                // Multi-line: strict (true) majority of non-empty lines must match.
                // n/2+1 with integer division — n=4 needs 3, n=5 needs 3, n=6 needs 4, n=7 needs 4.
                // Looser than the prior >0.6 threshold for odd n (n=5 used to need 4) — this is
                // deliberate: it cleans the dominant terminal shape (e.g. 3 commands + 2 output
                // lines). Accepted trade-off: a 3-of-5 markdown blockquote/comment selection also
                // loses its `> `/`# ` markers; rare in terminal pastes, so the shell case wins.
                if matchCount >= lineCount / 2 + 1 {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Pass 4b: Agent Prompt Cleanup

    private static let agentPromptMarkers: Set<Character> = ["›", "❯", "•", "⏺", "●"]
    private static let boxDrawingCharacterClass = "[│┃║╎╏┆┇┊┋╽╿￨｜]"
    private static let borderBoxCharacterClass = "[─━┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╭╮╯╰┏┓┗┛┣┫┳┻╋]"

    private static let maxAgentPromptReflowLines = 60

    static func stripAgentPromptSelection(_ input: String) -> String? {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine = nonEmpty.first else { return nil }

        let firstTrimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard let firstCharacter = firstTrimmed.first,
              agentPromptMarkers.contains(firstCharacter)
        else {
            return nil
        }

        guard nonEmpty.count <= maxAgentPromptReflowLines else { return nil }

        // Agent reflow targets a single message: one leading marker, then continuation lines.
        // Two or more marker-led lines means a real bullet list (• a / • b), a multi-message
        // selection, or stacked ⏺ tool calls — reflowing would fuse them. Bail.
        let markerLineCount = nonEmpty.count { line in
            guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
            return agentPromptMarkers.contains(first)
        }
        if markerLineCount > 1 {
            if firstCharacter == "•", let cleaned = reflowSeparatedBulletAgentMessages(lines) {
                return cleaned
            }
            return nil
        }

        let candidateLines: [String]
        if let ruleIndex = lines.firstIndex(where: isAgentPromptRuleLine(_:)) {
            candidateLines = Array(lines.dropFirst(ruleIndex + 1))
        } else {
            var didStripPromptMarker = false
            candidateLines = lines.map { line in
                guard !didStripPromptMarker,
                      !line.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    return line
                }
                didStripPromptMarker = true
                return stripLeadingAgentPromptMarker(from: line.trimmingCharacters(in: .whitespaces))
            }
        }

        let contentLines = trimOuterBlankLines(
            candidateLines.map { $0.trimmingCharacters(in: .whitespaces) }
        )
        let nonEmptyContentLines = contentLines.filter { !$0.isEmpty }
        guard !nonEmptyContentLines.isEmpty else { return nil }

        let content = contentLines.joined(separator: "\n")
        guard !isLikelySourceCode(content),
              !isLikelyList(content),
              !isLikelyStructuredData(content),
              !isLikelyShellTranscript(content)
        else {
            return nil
        }

        let flattened = flattenWrappedPromptLines(contentLines)
        return flattened == input ? nil : flattened
    }

    static func reflowPlainProseSelection(
        _ input: String
    ) -> String? {
        reflowPlainProseSelection(
            input,
            lineShapeEvidence: PlainProseLineShapeEvidence(input: input)
        )
    }

    private static func reflowPlainProseSelection(
        _ input: String,
        lineShapeEvidence: PlainProseLineShapeEvidence
    ) -> String? {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let contentLines = trimOuterBlankLines(lines.map { $0.trimmingCharacters(in: .whitespaces) })
        let nonEmptyContentLines = contentLines.filter { !$0.isEmpty }
        guard nonEmptyContentLines.count >= 2,
              nonEmptyContentLines.count <= maxAgentPromptReflowLines,
              !lineShapeEvidence.hasMultiplePaddedShortRows,
              hasProseWrapCandidate(contentLines)
        else {
            return nil
        }

        let content = contentLines.joined(separator: "\n")
        guard !isLikelySourceCode(content),
              !isLikelyStructuredData(content),
              !isLikelyShellTranscript(content),
              !isLikelyCompactShellCommandBlock(nonEmptyContentLines)
        else {
            return nil
        }

        let flattened = flattenWrappedPromptLines(contentLines)
        return flattened == input ? nil : flattened
    }

    private static func reflowSeparatedBulletAgentMessages(_ lines: [String]) -> String? {
        let contentLines = trimOuterBlankLines(lines.map { $0.trimmingCharacters(in: .whitespaces) })
        guard !contentLines.isEmpty else { return nil }

        var blocks: [[String]] = []
        var currentBlock: [String] = []
        var sawBlockSeparator = false

        for line in contentLines {
            if line.isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = []
                    sawBlockSeparator = true
                }
                continue
            }
            currentBlock.append(line)
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        guard sawBlockSeparator, blocks.count >= 2 else { return nil }

        let reflowedBlocks = blocks.compactMap { block -> String? in
            guard let firstLine = block.first else { return nil }
            let markerCount = block.count { line in
                line.trimmingCharacters(in: .whitespaces).first == "•"
            }
            guard markerCount == 1, firstLine.first == "•" else { return nil }

            let paragraphLines = [stripLeadingAgentPromptMarker(from: firstLine)] + block.dropFirst()
            let content = paragraphLines.joined(separator: "\n")
            guard !isLikelySourceCode(content),
                  !isLikelyStructuredData(content),
                  !isLikelyShellTranscript(content)
            else {
                return nil
            }

            let flattened = flattenWrappedPromptLines(paragraphLines)
            guard !flattened.isEmpty else { return nil }
            return "• \(flattened)"
        }

        guard reflowedBlocks.count == blocks.count else { return nil }

        let flattened = reflowedBlocks.joined(separator: "\n\n")
        let original = lines.joined(separator: "\n")
        return flattened == original ? nil : flattened
    }

    private static func stripLeadingAgentPromptMarker(from line: String) -> String {
        let remainder = line.dropFirst().drop(while: \.isWhitespace)
        return String(remainder)
    }

    private static func hasProseWrapCandidate(_ lines: [String]) -> Bool {
        var paragraphLines: [String] = []

        func paragraphHasCandidate() -> Bool {
            guard paragraphLines.count >= 2 else { return false }
            if paragraphLines.allSatisfy(isListItemLine(_:)) {
                return false
            }
            if paragraphLines.contains(where: isExplicitLineContinuation(_:)) {
                return true
            }
            return paragraphLines.contains(where: isLikelyProseLine(_:))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if paragraphHasCandidate() {
                    return true
                }
                paragraphLines = []
                continue
            }
            paragraphLines.append(trimmed)
        }

        return paragraphHasCandidate()
    }

    private static func isLikelyProseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 60, trimmed.contains(" ") else { return false }
        return trimmed.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil
    }

    private static func isExplicitLineContinuation(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
    }

    private static func isLikelyCompactShellCommandBlock(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        guard !lines.contains(where: isLikelyShellContinuationLine(_:)) else { return false }
        return lines.allSatisfy(isLikelyStandaloneShellCommandLine(_:))
    }

    private static func isLikelyShellContinuationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("--")
            || trimmed.hasPrefix("|")
            || trimmed.hasPrefix("&&")
            || trimmed.hasPrefix("||")
            || trimmed.hasPrefix("\\")
            || trimmed.hasPrefix("\"")
            || trimmed.hasPrefix("'")
    }

    private static func isLikelyStandaloneShellCommandLine(_ line: String) -> Bool {
        var tokens = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        while let first = tokens.first,
              first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) != nil {
            tokens.removeFirst()
        }
        while let first = tokens.first, shellCommandPrefixes.contains(first) {
            tokens.removeFirst()
        }
        guard let command = tokens.first else { return false }
        return knownShellCommands.contains(command)
            || command.hasPrefix("./")
            || command.hasPrefix("../")
            || command.hasPrefix("/")
            || command.hasPrefix("scripts/")
    }

    private static let shellCommandPrefixes: Set<String> = [
        "builtin", "command", "env", "sudo", "time"
    ]

    private static let knownShellCommands: Set<String> = [
        "awk", "brew", "bun", "bundle", "cargo", "cat", "cd", "chmod", "cmake",
        "cp", "curl", "deno", "docker", "docker-compose", "find", "frontcli",
        "gh", "git", "go", "grep", "jq", "kubectl", "linear", "ls", "make",
        "mcporter", "mkdir", "mise", "mv", "nimbu", "node", "npm", "npx", "op",
        "oracle", "pip", "pip3", "pnpm", "pytest", "python", "python3", "rails",
        "rake", "rg", "rsync", "ruby", "sed", "ssh", "swift", "tar", "terraform",
        "touch", "trash", "uv", "wget", "xcodebuild", "yarn", "zip"
    ]

    private static func trailingWhitespaceCount(_ line: String) -> Int {
        var index = line.endIndex
        var count = 0
        while index > line.startIndex {
            let previous = line.index(before: index)
            let character = line[previous]
            guard character == " " || character == "\t" else { break }
            count += 1
            index = previous
        }
        return count
    }

    private struct PlainProseLineShapeEvidence {
        let hasMultiplePaddedShortRows: Bool

        init(input: String) {
            let rows = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let paddedShortRows = rows.count { row in
                let trailingCount = trailingWhitespaceCount(row)
                let visibleCount = row.count - trailingCount
                return visibleCount > 0 && visibleCount < 60 && trailingCount >= 4
            }
            hasMultiplePaddedShortRows = paddedShortRows >= 2
        }
    }

    private static func trimOuterBlankLines(_ lines: [String]) -> [String] {
        guard let firstNonEmpty = lines.firstIndex(where: { !$0.isEmpty }),
              let lastNonEmpty = lines.lastIndex(where: { !$0.isEmpty })
        else {
            return []
        }
        return Array(lines[firstNonEmpty...lastNonEmpty])
    }

    private static func isAgentPromptRuleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return false }
        let ruleCharacters: Set<Character> = ["─", "━", "—"]
        let ruleCount = trimmed.count(where: { ruleCharacters.contains($0) })
        return ruleCount >= 10 && ruleCount == trimmed.count
    }

    private static func flattenWrappedPromptLines(_ lines: [String]) -> String {
        var result = ""
        var paragraphLines: [String] = []
        var pendingBlankLineCount = 0

        func appendParagraph() {
            guard !paragraphLines.isEmpty else { return }

            if !result.isEmpty, pendingBlankLineCount > 0 {
                result += String(repeating: "\n", count: pendingBlankLineCount + 1)
            }
            result += flattenPromptParagraph(paragraphLines)
            paragraphLines = []
            pendingBlankLineCount = 0
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                appendParagraph()
                pendingBlankLineCount += 1
                continue
            }
            paragraphLines.append(trimmed)
        }

        appendParagraph()
        return result
    }

    /// Collapses a single agent-reply paragraph (already split on blank lines by
    /// `flattenWrappedPromptLines`) into one flat string. The ordered rejoin regexes
    /// assume the input is one paragraph with no double newlines — passing
    /// multi-paragraph input here would let `\n+ -> " "` swallow paragraph breaks.
    ///
    /// Known accepted false-positive: the path-segment rule fuses any line ending in
    /// `/` or `~` with the next line, including prose shapes like
    /// `"Save in /tmp/\n  Then run command"`. Path-wrap is far more common in agent
    /// output than this shape, so the trade-off favours the path-wrap case.
    private static func flattenPromptParagraph(_ lines: [String]) -> String {
        if lines.contains(where: isListItemLine(_:)) {
            return flattenListParagraph(lines)
        }

        return flattenNonListParagraph(lines)
    }

    private static func flattenListParagraph(_ lines: [String]) -> String {
        var result: [String] = []
        var currentItemLines: [String] = []

        func appendCurrentItem() {
            guard !currentItemLines.isEmpty else { return }
            result.append(flattenNonListParagraph(currentItemLines))
            currentItemLines = []
        }

        for line in lines {
            if isListItemLine(line) {
                appendCurrentItem()
            }
            currentItemLines.append(line)
        }

        appendCurrentItem()
        return result.joined(separator: "\n")
    }

    private static func flattenNonListParagraph(_ lines: [String]) -> String {
        var result = lines.joined(separator: "\n")

        // Hyphen-token boundary: keep wrapped tokens like UUIDs joined without an inserted space.
        // Lookbehind excludes "-" so a markdown HR run (----------) does not fuse with the next line.
        result = result.replacingOccurrences(
            of: #"(?<=[A-Za-z0-9._~])-\s*\n\s*([A-Za-z0-9._~-])"#,
            with: "-$1",
            options: .regularExpression
        )

        // Capitalized identifier mid-break: "N\nODE_PATH" -> "NODE_PATH".
        // "." is intentionally absent from the LHS so a sentence-boundary like
        // "Here is the answer.\nHere is more context." does NOT fuse into ".H" —
        // the later "\n+ -> ' '" pass needs the newline to survive and become a space.
        // "-" is absent from both sides so a dash run (markdown HR) doesn't fuse with the next line.
        // The trailing (?=[A-Z0-9_.]) requires the next-line token to continue as an
        // identifier (2+ chars), so a split identifier (N -> ODE_PATH) still joins while
        // two standalone capitals don't: "Grade A\nB students" stays "Grade A B students"
        // (the newline survives to the "\n+ -> ' '" pass). It also subsumes the old (?!\n).
        result = result.replacingOccurrences(
            of: #"(?<!\n)([A-Z0-9_])\s*\n\s*([A-Z0-9_.])(?=[A-Z0-9_.])"#,
            with: "$1$2",
            options: .regularExpression
        )

        // Path segment after / or ~: ".../foo/\nbar" -> ".../foo/bar".
        // Pinned by test_stripAgentPromptSelection_rejoins_path_segment.
        // Accepted false-positive: prose ending with a trailing "/" or "~" fuses with
        // the next line ("Save in /tmp/\n  Then run command" -> "Save in /tmp/Then run command").
        // Don't "fix" this by tightening without a replacement rule for the real path-wrap case.
        result = result.replacingOccurrences(
            of: #"(?<=[/~])\s*\n\s*([A-Za-z0-9._-])"#,
            with: "$1",
            options: .regularExpression
        )

        // Backslash line continuations collapse to a single space
        result = result.replacingOccurrences(
            of: #"\\\s*\n"#,
            with: " ",
            options: .regularExpression
        )

        // Remaining newlines fold to a single space
        result = result.replacingOccurrences(
            of: #"\n+"#,
            with: " ",
            options: .regularExpression
        )

        // Final whitespace squeeze
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelySourceCode(_ text: String) -> Bool {
        let hasBraces = text.contains("{") || text.contains("}") || text.lowercased().contains("begin")
        let keywordPattern =
            #"(?m)^\s*(import|package|namespace|using|template|class|struct|enum|extension|protocol|"#
                + #"interface|func|def|fn|let|var|public|private|internal|open|protected|if|for|while)\b"#
        let hasKeywords = text.range(of: keywordPattern, options: .regularExpression) != nil
        if hasBraces && hasKeywords {
            return true
        }

        let codeLinePattern =
            #"(?m)^\s*(let|var|await|try|return|guard|func|class|struct|enum|import|extension|protocol)\s+\S"#
        let hasCodeLine = text.range(of: codeLinePattern, options: .regularExpression) != nil
        let hasCodePunctuation = text.range(of: #"[=(){};]"#, options: .regularExpression) != nil
        return hasCodeLine && hasCodePunctuation
    }

    private static func isLikelyList(_ text: String) -> Bool {
        let nonEmpty = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 2 else { return false }

        return isListItemLine(nonEmpty[0])
    }

    private static func isListItemLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^[-*•]\s+\S"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^[0-9]+[.)]\s+\S"#, options: .regularExpression) != nil
    }

    private static func isLikelyStructuredData(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["{", "}", "[", "]"].contains(trimmed) { return true }
            return trimmed.range(of: #"^["'][^"']+["']\s*:"#, options: .regularExpression) != nil
        }
    }

    private static func isLikelyShellTranscript(_ text: String) -> Bool {
        let promptLineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("$ ")
                || trimmed.hasPrefix("# ")
                || trimmed.hasPrefix("% ")
        }
        return promptLineCount >= 1
    }

    // MARK: - Pass 5: Line Number Prefix Detection

    static func stripLineNumberPrefixes(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !nonEmptyLines.isEmpty else { return input }

        guard let prefixPattern = detectLineNumberPattern(nonEmptyLines: nonEmptyLines) else {
            return input
        }

        let stripped = lines.map { line -> String in
            guard let match = prefixPattern.firstMatch(
                in: String(line),
                range: NSRange(line.startIndex..., in: line)
            ) else {
                return String(line)
            }
            let matchRange = Range(match.range, in: line)!
            return String(line[matchRange.upperBound...])
        }
        return stripped.joined(separator: "\n")
    }

    private static func detectLineNumberPattern(
        nonEmptyLines: [Substring]
    ) -> NSRegularExpression? {
        // Patterns: "  1\t" (cat -n), "42:" (grep -n), "1| " or "1 │ " (bat, editors)
        let patterns: [(regex: String, name: String)] = [
            (#"^\s*\d+\t"#, "cat-n"),              // cat -n: right-aligned number + tab
            (#"^\s*\d+:\s?"#, "grep-n"),            // grep -n: number + colon
            (#"^\s*\d+\s?[|│┃]\s?"#, "pipe"),      // number + optional space + pipe (ASCII or box-drawing) — bat, editors
        ]

        let lineCount = nonEmptyLines.count

        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let matchCount = nonEmptyLines.count(where: { line in
                let str = String(line)
                return regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil
            })

            if lineCount <= 3 {
                // Short: ALL non-empty lines must match
                guard matchCount == lineCount else { continue }
            } else {
                // Multi-line: >80% consistency + monotonic check
                let ratio = Double(matchCount) / Double(lineCount)
                guard ratio > 0.8 else { continue }
                guard numbersAreMonotonic(nonEmptyLines: nonEmptyLines, regex: regex) else {
                    continue
                }
            }

            return regex
        }
        return nil
    }

    // MARK: - Pass 5b: Box Drawing Cleanup

    static func stripBoxDrawingArtifacts(_ input: String) -> String? {
        let boxRegex = try? NSRegularExpression(pattern: boxDrawingCharacterClass)
        let borderRegex = try? NSRegularExpression(pattern: borderBoxCharacterClass)
        let fullRange = NSRange(input.startIndex..., in: input)
        guard boxRegex?.firstMatch(in: input, range: fullRange) != nil
            || borderRegex?.firstMatch(in: input, range: fullRange) != nil
        else { return nil }

        // Drop full-border lines (e.g. ┌────┐ / └────┘ panel edges, ──── separators).
        // Requires at least 3 border chars so a lone diagram glyph stays untouched.
        let borderLinePattern = #"^\s*\#(borderBoxCharacterClass){3,}\s*$"#
        var result = input.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.range(of: borderLinePattern, options: .regularExpression) == nil
            }
            .joined(separator: "\n")

        result = result.replacingOccurrences(of: "│ │", with: " ")

        let boxAfterPipePattern = #"\|[ \t]*\#(boxDrawingCharacterClass)+[ \t]*"#
        result = result.replacingOccurrences(
            of: boxAfterPipePattern,
            with: "| ",
            options: .regularExpression
        )

        let boxPathJoinPattern = #"([:/])[ \t]*\#(boxDrawingCharacterClass)+[ \t]*([A-Za-z0-9])"#
        result = result.replacingOccurrences(
            of: boxPathJoinPattern,
            with: "$1$2",
            options: .regularExpression
        )

        let boxMidTokenPattern = #"(\S)[ \t]*\#(boxDrawingCharacterClass)+[ \t]*(\S)"#
        result = result.replacingOccurrences(
            of: boxMidTokenPattern,
            with: "$1 $2",
            options: .regularExpression
        )

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmptyLines.isEmpty {
            let leadingPattern = #"^\s*\#(boxDrawingCharacterClass)+ ?"#
            let trailingPattern = #" ?\#(boxDrawingCharacterClass)+\s*$"#
            let majorityThreshold = nonEmptyLines.count == 1 ? 1 : nonEmptyLines.count / 2 + 1

            let leadingMatches = nonEmptyLines.count {
                $0.range(of: leadingPattern, options: .regularExpression) != nil
            }
            let trailingMatches = nonEmptyLines.count {
                $0.range(of: trailingPattern, options: .regularExpression) != nil
            }

            let stripLeading = leadingMatches >= majorityThreshold
            let stripTrailing = trailingMatches >= majorityThreshold

            if stripLeading || stripTrailing {
                result = lines.map { line in
                    var line = line
                    if stripLeading {
                        line = line.replacingOccurrences(
                            of: leadingPattern,
                            with: "",
                            options: .regularExpression
                        )
                    }
                    if stripTrailing {
                        line = line.replacingOccurrences(
                            of: trailingPattern,
                            with: "",
                            options: .regularExpression
                        )
                    }
                    return line
                }.joined(separator: "\n")
            }
        }

        result = result.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression
        )

        let cleaned = trimTrailingWhitespacePerLine(result)
        // Decoration-only selections (e.g. a lone "──────" divider or "│" fragment) can
        // reduce to nothing. Treat that as a no-op so we never overwrite the clipboard with
        // an empty string — an unchanged selection beats an emptied one.
        if cleaned.allSatisfy(\.isWhitespace), !input.allSatisfy(\.isWhitespace) {
            return nil
        }
        return cleaned == input ? nil : cleaned
    }

    private static func numbersAreMonotonic(
        nonEmptyLines: [Substring],
        regex: NSRegularExpression
    ) -> Bool {
        var lastNumber = Int.min
        for line in nonEmptyLines {
            let str = String(line)
            guard let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str))
            else {
                continue
            }
            let matchedText = String(str[Range(match.range, in: str)!])
            let digits = matchedText.filter(\.isWholeNumber)
            guard let number = Int(digits) else { continue }
            guard number >= lastNumber else { return false }
            lastNumber = number
        }
        return true
    }

    // MARK: - Pass 6: Common-Prefix Dedent

    static func dedentCommonPrefix(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !nonEmptyLines.isEmpty else { return input }

        let minLeadingWhitespace = nonEmptyLines.map { line -> Int in
            line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }.min() ?? 0

        guard minLeadingWhitespace > 0 else { return input }

        let dedented = lines.map { line -> String in
            if line.allSatisfy(\.isWhitespace) {
                return String(line)
            }
            return String(line.dropFirst(minLeadingWhitespace))
        }
        return dedented.joined(separator: "\n")
    }
}
