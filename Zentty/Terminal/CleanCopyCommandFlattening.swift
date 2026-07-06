import Foundation

extension CleanCopyPipeline {
    static let commandFlattenKnownPrefixes: [String] = {
        let commonCommandPrefixes: [String] = [
            "sudo", "./", "~/", "apt", "brew", "git", "python", "pip", "pnpm", "npm", "yarn", "cargo",
            "bundle", "rails", "go", "make", "xcodebuild", "swift", "kubectl", "docker", "podman", "aws",
            "gcloud", "az", "ls", "cd", "pwd", "cat", "echo", "env", "export", "open", "node", "java", "ruby",
            "perl", "bash", "zsh", "fish", "pwsh", "sh", "exit", "systemctl",
        ]
        var seen = Set<String>()
        var merged: [String] = []
        for item in commonCommandPrefixes + Array(knownShellCommands) {
            let key = item.lowercased()
            if seen.insert(key).inserted {
                merged.append(item)
            }
        }
        return merged
    }()

    static func transformMultiLineCommandIfNeeded(
        _ input: String,
        options: CleanCopyOptions,
        lineShapeEvidence: PlainProseLineShapeEvidence? = nil
    ) -> String? {
        guard options.flattenMultiLineCommands else { return nil }
        guard input.contains("\n") else { return nil }

        let lines = input.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return nil }
        if lines.count > 10 { return nil }

        let hasLineContinuation = input.contains("\\\n")
        let hasLineJoinerAtEOL = input.range(
            of: #"(?m)(\\|[|&]{1,2}|;)\s*$"#,
            options: .regularExpression
        ) != nil
        let hasIndentedPipeline = input.range(
            of: #"(?m)^\s*[|&]{1,2}\s+\S"#,
            options: .regularExpression
        ) != nil
        let hasExplicitLineJoin = hasLineContinuation || hasLineJoinerAtEOL || hasIndentedPipeline

        if lineShapeEvidence?.hasMultiplePaddedShortRows == true,
           !hasExplicitLineJoin
        {
            // Padded short rows indicate deliberately line-broken columnar output, not a soft wrap.
            return nil
        }

        let aggressiveness = options.commandFlattenAggressiveness
        if aggressiveness != .high, lines.count > 4 {
            return nil
        }

        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if aggressiveness != .high,
           nonEmptyLines.count >= 2,
           nonEmptyLines.allSatisfy({ line in
               let trimmed = line.trimmingCharacters(in: .whitespaces)
               return trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
           })
        {
            return nil
        }

        if nonEmptyLines.count >= 2,
           nonEmptyLines.allSatisfy(isSeparateTerminalCommandLine(_:))
        {
            return nil
        }

        if nonEmptyLines.count >= 2,
           isLikelyCompactShellCommandBlock(nonEmptyLines.map(String.init))
        {
            return nil
        }

        if aggressiveness != .high,
           !hasExplicitLineJoin,
           commandLineCount(in: nonEmptyLines) == nonEmptyLines.count,
           nonEmptyLines.count >= 2
        {
            return nil
        }

        if aggressiveness != .high, isLikelyCommandList(lines) {
            return nil
        }


        let strongCommandSignals = input.contains("\\\n")
            || input.range(of: #"[|&]{1,2}"#, options: .regularExpression) != nil
            || input.range(of: #"(^|\n)\s*\$"#, options: .regularExpression) != nil
            || input.range(of: #"[A-Za-z0-9._~-]+/[A-Za-z0-9._~-]+"#, options: .regularExpression) != nil

        let hasKnownCommandPrefix = containsKnownCommandPrefix(in: lines)
        if aggressiveness != .high,
           !strongCommandSignals,
           !hasKnownCommandPrefix,
           !hasCommandPunctuation(input)
        {
            return nil
        }

        if aggressiveness != .high,
           isLikelyCommandFlattenSourceCode(input),
           !strongCommandSignals
        {
            return nil
        }

        var score = 0
        if input.contains("\\\n") { score += 1 }
        if input.range(of: #"[|&]{1,2}"#, options: .regularExpression) != nil { score += 1 }
        if input.range(of: #"(^|\n)\s*\$"#, options: .regularExpression) != nil { score += 1 }
        if isSingleCommandWithIndentedContinuations(nonEmptyLines) { score += 1 }
        if lines.allSatisfy(isLikelyCommandLine(_:)) { score += 1 }
        if input.range(of: #"(?m)^\s*(sudo\s+)?[A-Za-z0-9./~_-]+"#, options: .regularExpression) != nil {
            score += 1
        }
        if input.range(of: #"[A-Za-z0-9._~-]+/[A-Za-z0-9._~-]+"#, options: .regularExpression) != nil {
            score += 1
        }

        guard score >= aggressiveness.scoreThreshold else { return nil }

        let flattened = flattenCommandText(
            input,
            preserveBlankLines: options.preserveBlankLinesWhenFlattening
        )
        return flattened == input ? nil : flattened
    }

    static func flattenCommandText(_ text: String, preserveBlankLines: Bool) -> String {
        let placeholder = "__BLANK_SEP__"
        var result = text
        if preserveBlankLines {
            result = result.replacingOccurrences(
                of: "\n\\s*\n",
                with: placeholder,
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"(?<=[A-Za-z0-9._~])-\s*\n\s*([A-Za-z0-9._~-])"#,
            with: "-$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<!\n)([A-Z0-9_.-])\s*\n\s*(?!-)([A-Z0-9_.-])(?!\n)"#,
            with: "$1$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<=[/~])\s*\n\s*([A-Za-z0-9._-])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"\\\s*\n"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if preserveBlankLines {
            result = result.replacingOccurrences(of: placeholder, with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isLikelyCommandLine(_ lineSubstr: Substring) -> Bool {
        let line = lineSubstr.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        if line.hasPrefix("[[") { return true }
        if line.last == "." { return false }
        let pattern = #"^(sudo\s+)?[A-Za-z0-9./~_-]+(?:\s+|\z)"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    static func hasCommandPunctuation(_ text: String) -> Bool {
        if text.contains("@") { return true }
        if text.range(
            of: #"(?m)(?:^|\s)--[A-Za-z0-9][A-Za-z0-9_-]*"#,
            options: .regularExpression
        ) != nil { return true }
        if text.range(
            of: #"(?m)(?:^|\s)-[A-Za-z](?:\s|\z)"#,
            options: .regularExpression
        ) != nil { return true }
        if text.range(
            of: #"(?m)\b[A-Za-z_][A-Za-z0-9_]*="#,
            options: .regularExpression
        ) != nil { return true }
        if text.range(
            of: #"(?m)(?:^|\s)(?:\./|~/|/)"#,
            options: .regularExpression
        ) != nil { return true }
        if text.range(
            of: #"(?m)(?:^|\s)\.[A-Za-z0-9_-]+"#,
            options: .regularExpression
        ) != nil { return true }
        if text.contains("<") || text.contains(">") { return true }
        return false
    }

    static func isLikelyCommandFlattenSourceCode(_ text: String) -> Bool {
        let hasBraces = text.contains("{") || text.contains("}") || text.lowercased().contains("begin")
        let keywordPattern =
            #"(?m)^\s*(import|package|namespace|using|template|class|struct|enum|extension|protocol|"#
                + #"interface|func|def|fn|let|var|public|private|internal|open|protected|if|for|while)\b"#
        let hasKeywords = text.range(of: keywordPattern, options: .regularExpression) != nil
        return hasBraces && hasKeywords
    }

    static func isLikelyCommandList(_ lines: [Substring]) -> Bool {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 2 else { return false }

        let listishCount = nonEmpty.count(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hasSpaces = trimmed.contains(where: \.isWhitespace)
            let bulletPattern = #"^[-*•]\s+\S"#
            let numberedPattern = #"^[0-9]+[.)]\s+\S"#
            let bareTokenPattern = #"^[A-Za-z0-9]{4,}$"#

            if trimmed.range(of: bulletPattern, options: .regularExpression) != nil { return true }
            if trimmed.range(of: numberedPattern, options: .regularExpression) != nil { return true }
            if !hasSpaces,
               trimmed.range(of: bareTokenPattern, options: .regularExpression) != nil,
               trimmed.range(of: #"[./$]"#, options: .regularExpression) == nil
            {
                return true
            }
            return false
        })

        return listishCount >= (nonEmpty.count / 2 + 1)
    }

    private static func isSingleCommandWithIndentedContinuations(_ lines: [Substring]) -> Bool {
        guard lines.count >= 2 else { return false }
        guard isLikelyCommandLine(lines[0]) else { return false }

        var sawIndentedLine = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if line.first?.isWhitespace == true {
                sawIndentedLine = true
                continue
            }

            if trimmed.hasPrefix("|")
                || trimmed.hasPrefix("&&")
                || trimmed.hasPrefix("||")
                || trimmed.hasPrefix(";")
                || trimmed.hasPrefix(">")
                || trimmed.hasPrefix("2>")
                || trimmed.hasPrefix("<")
                || trimmed.hasPrefix("--")
                || trimmed.hasPrefix("-")
            {
                continue
            }
            return false
        }
        return sawIndentedLine
    }

    private static func containsKnownCommandPrefix(in lines: [Substring]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstToken = trimmed.split(separator: " ").first else { return false }
            let lower = firstToken.lowercased()
            return commandFlattenKnownPrefixes.contains(where: { lower.hasPrefix($0) })
        }
    }


    private static func isSeparateTerminalCommandLine(_ line: Substring) -> Bool {
        isLikelyStandaloneShellCommandLine(String(line))
    }

    private static func commandLineCount(in lines: [Substring]) -> Int {
        lines.count(where: isLikelyCommandLine(_:))
    }
}
