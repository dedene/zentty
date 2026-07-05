import Foundation

extension CleanCopyPipeline {
    static func dedentParagraphIndent(_ input: String) -> String? {
        guard input.contains(where: \.isNewline) else { return nil }

        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmptyIndices = lines.indices.filter {
            !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard nonEmptyIndices.count >= 2 else { return nil }

        let nonEmptyLines = nonEmptyIndices.map { lines[$0][...] }
        guard !isLikelyCommandList(nonEmptyLines.map(Substring.init)),
              !isLikelyCommandFlattenSourceCode(input),
              !isLikelyStructuredDataForDedent(nonEmptyLines),
              !hasCommandPunctuation(input)
        else {
            return nil
        }

        let indentedProseLines = nonEmptyIndices.compactMap { index -> Int? in
            let line = lines[index]
            let indent = line.prefix(while: \.isWhitespace).count
            guard indent > 0 else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard isLikelyDedentProseLine(trimmed) else { return nil }
            return indent
        }

        let requiredIndentedLines = max(2, nonEmptyIndices.count / 2 + 1)
        guard indentedProseLines.count >= requiredIndentedLines,
              let commonIndent = indentedProseLines.min(),
              commonIndent > 0
        else {
            return nil
        }

        let dedented = lines.map { line -> String in
            let indent = line.prefix(while: \.isWhitespace).count
            guard indent >= commonIndent else { return line }
            return String(line.dropFirst(commonIndent))
        }.joined(separator: "\n")

        return dedented == input ? nil : dedented
    }

    private static func isLikelyStructuredDataForDedent(_ lines: [Substring]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if ["{", "}", "[", "]"].contains(trimmed) { return true }
            return trimmed.range(of: #"^["'][^"']+["']\s*:"#, options: .regularExpression) != nil
        }
    }

    private static func isLikelyDedentProseLine(_ line: String) -> Bool {
        guard let first = line.first, first.isLetter || "\"'(".contains(first) else { return false }
        if line.range(of: #"^[-*•]|^[0-9]+[.)]\s|^(?:\$|#|>|[|&;{}])"#, options: .regularExpression) != nil {
            return false
        }
        if line.range(of: #"^["'][^"']+["']\s*:"#, options: .regularExpression) != nil {
            return false
        }
        if line.range(
            of: #"^(?:sudo|git|npm|pnpm|yarn|swift|xcodebuild|docker|kubectl|cd|ls|cat|echo|make)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return false
        }
        return line.contains(where: \.isWhitespace)
            || line.range(of: #"[,.!?;:]"#, options: .regularExpression) != nil
    }
}