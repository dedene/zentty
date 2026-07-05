import Foundation

enum MarkdownReformatter {
    static func isLikelyMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("```") { return true }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headingCount = lines.count {
            $0.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil
        }
        let listCount = lines.count {
            $0.range(of: #"^[-*+]\s+\S"#, options: .regularExpression) != nil
                || $0.range(of: #"^[0-9]+[.)]\s+\S"#, options: .regularExpression) != nil
        }
        return headingCount >= 1 || listCount >= 2
    }

    static func reformat(_ text: String) -> String {
        var inFence = false
        var output: [String] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if !joined.isEmpty {
                output.append(joined)
            }
            paragraph = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                inFence.toggle()
                output.append(line)
                continue
            }
            if inFence {
                output.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                output.append("")
                continue
            }
            if trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^[0-9]+[.)]\s"#, options: .regularExpression) != nil
                || trimmed.hasPrefix(">")
                || trimmed.hasPrefix("|")
            {
                flushParagraph()
                output.append(line)
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return output.joined(separator: "\n")
    }
}
