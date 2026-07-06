import Foundation

extension CleanCopyPipeline {
    static func stripTerminalChromeDecoration(
        _ input: String,
        options: CleanCopyOptions,
        lineShapeEvidence: PlainProseLineShapeEvidence? = nil
    ) -> String? {
        var text = input
        if let cleaned = stripAgentPromptSelection(text, lineShapeEvidence: lineShapeEvidence) {
            text = cleaned
        }
        if options.flattenSlashCommandSelections, let slash = stripSlashCommandDecoration(text) {
            text = slash
        }
        return text == input ? nil : text
    }

    static func stripSlashCommandDecoration(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmptyLines.isEmpty else { return nil }

        let firstNonEmpty = nonEmptyLines[0].trimmingCharacters(in: .whitespaces)

        if firstNonEmpty.range(
            of: #"^/[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?($|[\s"])"#,
            options: .regularExpression
        ) != nil,
            nonEmptyLines.count >= 2
        {
            let result = flattenSlashContinuationLines(nonEmptyLines.map(String.init))
            return result == text ? nil : result
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.hasPrefix("\"/"), trimmedText.hasSuffix("\""), trimmedText.contains("\\\"") {
            let unquoted = String(trimmedText.dropFirst().dropLast())
            let unescaped = unquoted.replacingOccurrences(of: "\\\"", with: "\"")
            return unescaped == text ? nil : unescaped
        }

        return nil
    }

    private static func flattenSlashContinuationLines(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
