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
    private let postUpdateTransform: ((String) -> String)?

    /// - Parameter postUpdateTransform: An optional pure transform applied to the fully
    ///   updated content just before it is written. The writer stays generic — callers use
    ///   this hook to inject domain-specific rewrites (e.g. appearance-level color healing)
    ///   without the writer needing to know about them.
    init(
        configURL: URL = GhosttyConfigEnvironment().preferredCreateTargetURL,
        postUpdateTransform: ((String) -> String)? = nil
    ) {
        self.configURL = configURL
        self.postUpdateTransform = postUpdateTransform
    }

    func updateValue(_ value: String, forKey key: String) {
        let existingContent = try? String(contentsOf: configURL, encoding: .utf8)
        let updated = Self.updating(content: existingContent, value: value, forKey: key)
        writeAtomically(postUpdateTransform?(updated) ?? updated)
    }

    private func writeAtomically(_ content: String) {
        let data = Data(content.utf8)
        let fileManager = FileManager.default
        // Write through a symlinked ghostty config so dotfile setups keep their link
        // instead of having it clobbered by the atomic temp+rename.
        let targetURL = fileManager.resolvingSymlinkTarget(at: configURL)
        let directory = targetURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: targetURL, options: .atomic)
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
