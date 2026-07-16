import Foundation

extension CleanCopyPipeline {
    static func stripSmartPromptPrefixes(_ input: String) -> String? {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !nonEmptyLines.isEmpty else { return nil }

        let promptCandidateCount = nonEmptyLines.count(where: isSmartPromptCandidateLine(_:))
        let majorityThreshold = nonEmptyLines.count / 2 + 1
        let shouldStripPromptCandidates = nonEmptyLines.count > 1
            && promptCandidateCount >= majorityThreshold

        if shouldStripPromptCandidates {
            var rebuilt: [String] = []
            rebuilt.reserveCapacity(lines.count)
            for line in lines {
                // "#" is ambiguous with shell-script prose comments, so even in the
                // majority path it still needs to look like a command (e.g. a root-shell
                // transcript). "$" has no such prose reading, so it stays relaxed.
                let requireCommandShape = leadingMarker(of: line) == "#"
                if isSmartPromptCandidateLine(line),
                   let stripped = stripSmartPromptPrefix(in: line, requireCommandShape: requireCommandShape)
                {
                    rebuilt.append(stripped)
                } else {
                    rebuilt.append(String(line))
                }
            }
            let result = rebuilt.joined(separator: "\n")
            return result == input ? nil : result
        }

        var strippedCount = 0
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(lines.count)

        for line in lines {
            if let stripped = stripSmartPromptPrefix(in: line, requireCommandShape: true) {
                strippedCount += 1
                rebuilt.append(stripped)
            } else {
                rebuilt.append(String(line))
            }
        }

        let shouldStrip = nonEmptyLines.count == 1 ? strippedCount == 1 : strippedCount >= majorityThreshold
        guard shouldStrip else { return nil }

        let result = rebuilt.joined(separator: "\n")
        return result == input ? nil : result
    }

    private static func leadingMarker(of line: Substring) -> Character? {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        return line.dropFirst(leadingWhitespace.count).first
    }

    private static func isSmartPromptCandidateLine(_ line: Substring) -> Bool {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        let remainder = line.dropFirst(leadingWhitespace.count)
        guard let first = remainder.first, first == "#" || first == "$" else { return false }
        let afterMarker = remainder.dropFirst()
        guard let next = afterMarker.first, next.isWhitespace else { return false }
        let afterPrompt = afterMarker.drop { $0.isWhitespace }
        return !afterPrompt.isEmpty
    }

    private static func stripSmartPromptPrefix(in line: Substring, requireCommandShape: Bool) -> String? {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        let remainder = line.dropFirst(leadingWhitespace.count)
        guard let first = remainder.first, first == "#" || first == "$" else { return nil }

        let afterMarker = remainder.dropFirst()
        guard let next = afterMarker.first, next.isWhitespace else { return nil }

        let afterPrompt = afterMarker.drop { $0.isWhitespace }
        if requireCommandShape {
            guard isLikelyPromptCommand(afterPrompt) else { return nil }
        } else {
            guard !afterPrompt.isEmpty else { return nil }
        }
        return String(leadingWhitespace) + String(afterPrompt)
    }

    private static func isLikelyPromptCommand(_ content: Substring) -> Bool {
        let trimmed = String(content.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty else { return false }
        if let last = trimmed.last, [".", "?", "!"].contains(last) { return false }

        let hasCommandPunctuation =
            trimmed.contains(where: { "-./~$".contains($0) }) || trimmed.contains(where: \.isNumber)
        let firstToken = trimmed.split(separator: " ").first?.lowercased() ?? ""
        let startsWithKnown = commandFlattenKnownPrefixes.contains(where: { firstToken.hasPrefix($0) })

        guard hasCommandPunctuation || startsWithKnown else { return false }
        return isLikelyCommandLine(trimmed[...])
    }
}
