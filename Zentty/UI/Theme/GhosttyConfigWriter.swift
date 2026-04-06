import Foundation

@MainActor
protocol GhosttyConfigWriting {
    func updateValue(_ value: String, forKey key: String)
}

extension GhosttyConfigWriting {
    func writeTheme(_ name: String) {
        let sanitized = name.filter { $0 != "\"" && !$0.isNewline }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        updateValue(sanitized, forKey: "theme")
    }

    func writeBackgroundOpacity(_ opacity: CGFloat) {
        let clamped = min(max(opacity, 0), 1)
        updateValue(String(format: "%.2f", clamped), forKey: "background-opacity")
    }
}

final class GhosttyConfigWriter: GhosttyConfigWriting {
    private let configURL: URL

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config")
    ) {
        self.configURL = configURL
    }

    func updateValue(_ value: String, forKey key: String) {
        let newLine = "\(key) = \(value)"

        let existingContent: String
        do {
            existingContent = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            writeAtomically(newLine + "\n")
            return
        }

        var lines = existingContent.components(separatedBy: "\n")
        var replaced = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let lineKey = parts[0].trimmingCharacters(in: .whitespaces)
            if lineKey == key {
                lines[index] = newLine
                replaced = true
                break
            }
        }

        if !replaced {
            lines.insert(newLine, at: 0)
        }

        writeAtomically(lines.joined(separator: "\n"))
    }

    private func writeAtomically(_ content: String) {
        let data = Data(content.utf8)
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }
}
