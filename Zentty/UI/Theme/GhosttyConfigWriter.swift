import Foundation

@MainActor
protocol GhosttyConfigWriting {
    func updateValue(_ value: String, forKey key: String)
}

extension GhosttyConfigWriting {
    func writeTheme(_ name: String) {
        let sanitized = GhosttyConfigWriter.sanitizedThemeName(name)
        guard !sanitized.isEmpty else { return }
        updateValue(sanitized, forKey: "theme")
    }

    func writeBackgroundOpacity(_ opacity: CGFloat) {
        updateValue(
            GhosttyConfigWriter.formattedBackgroundOpacity(opacity),
            forKey: "background-opacity"
        )
    }
}

final class GhosttyConfigWriter: GhosttyConfigWriting {
    private let configURL: URL

    init(
        configURL: URL = GhosttyConfigEnvironment().preferredCreateTargetURL
    ) {
        self.configURL = configURL
    }

    func updateValue(_ value: String, forKey key: String) {
        let existingContent: String
        do {
            existingContent = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            writeAtomically(Self.updating(content: nil, value: value, forKey: key))
            return
        }
        writeAtomically(Self.updating(content: existingContent, value: value, forKey: key))
    }

    private func writeAtomically(_ content: String) {
        let data = Data(content.utf8)
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    static func sanitizedThemeName(_ name: String) -> String {
        name.filter { $0 != "\"" && !$0.isNewline }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formattedBackgroundOpacity(_ opacity: CGFloat) -> String {
        let clamped = min(max(opacity, 0), 1)
        return String(format: "%.2f", clamped)
    }

    static func updating(content: String?, value: String, forKey key: String) -> String {
        let newLine = "\(key) = \(value)"
        var lines = content?.components(separatedBy: "\n") ?? []
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

        let joined = lines.joined(separator: "\n")
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }
}
