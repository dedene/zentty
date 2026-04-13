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
        text = trimTrailingWhitespacePerLine(text)
        text = trimTrailingBlankLines(text)
        text = stripPrompts(text)
        text = stripLineNumberPrefixes(text)
        text = dedentCommonPrefix(text)
        return Result(text: text, wasModified: text != input)
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

    private static let promptCharacters: Set<Character> = ["$", ">", "%", "#"]

    static func stripPrompts(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !nonEmptyLines.isEmpty else { return input }

        let bestPrompt = detectPromptPattern(nonEmptyLines: nonEmptyLines)
        guard let prompt = bestPrompt else { return input }

        let stripped = lines.map { line -> String in
            if line.hasPrefix(prompt) {
                return String(line.dropFirst(prompt.count))
            }
            return String(line)
        }
        return stripped.joined(separator: "\n")
    }

    private static func detectPromptPattern(nonEmptyLines: [Substring]) -> String? {
        let candidates = ["$ ", "> ", "% ", "# "]
        let lineCount = nonEmptyLines.count

        for candidate in candidates {
            let matchCount = nonEmptyLines.count(where: { $0.hasPrefix(candidate) })

            if lineCount <= 3 {
                // Short selection: strip if first non-empty line matches
                if nonEmptyLines.first?.hasPrefix(candidate) == true {
                    return candidate
                }
            } else {
                // Multi-line: need >60% consistency
                let ratio = Double(matchCount) / Double(lineCount)
                if ratio > 0.6 {
                    return candidate
                }
            }
        }
        return nil
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
