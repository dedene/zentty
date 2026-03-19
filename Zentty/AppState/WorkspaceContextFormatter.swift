import Foundation

enum WorkspaceContextFormatter {
    static func contextText(for metadata: TerminalMetadata?) -> String {
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap { compactDirectoryName($0) }
        let branch = displayBranch(metadata?.gitBranch)
        return [compactDirectory, branch]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    static func displayWorkingDirectory(for metadata: TerminalMetadata?) -> String? {
        resolvedWorkingDirectory(for: metadata).flatMap(homeRelativePath)
    }

    static func resolvedWorkingDirectory(for metadata: TerminalMetadata?) -> String? {
        normalizedWorkingDirectoryCandidate(metadata?.currentWorkingDirectory)
            ?? inferredWorkingDirectory(fromTitle: metadata?.title)
    }

    static func homeRelativePath(_ path: String) -> String? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        if trimmedPath == homePath {
            return "~"
        }

        guard trimmedPath.hasPrefix(homePath + "/") else {
            return trimmedPath
        }

        return "~/" + trimmedPath.dropFirst(homePath.count + 1)
    }

    static func compactSidebarPath(
        _ path: String,
        minimumSegments: Int = 1
    ) -> String? {
        guard let components = sidebarPathComponents(path) else {
            return nil
        }

        guard components != ["~"] else {
            return "~"
        }

        if let worktreeLabel = worktreeSidebarPathLabel(path) {
            return worktreeLabel
        }

        let clampedSegmentCount = min(
            max(1, minimumSegments),
            components.count
        )
        return components.suffix(clampedSegmentCount).joined(separator: "/")
    }

    static func maxSidebarPathSegments(_ path: String) -> Int? {
        guard let components = sidebarPathComponents(path) else {
            return nil
        }

        if worktreeSidebarPathLabel(path) != nil {
            return 2
        }

        return components == ["~"] ? 1 : components.count
    }

    static func compactDirectoryName(
        _ path: String,
        minimumSegments: Int = 1
    ) -> String? {
        compactSidebarPath(path, minimumSegments: minimumSegments).flatMap { compactPath in
            guard compactPath != "~" else {
                return "~"
            }

            guard minimumSegments > 1 else {
                return compactPath.split(separator: "/").last.map(String.init)
            }

            return compactPath
        }
    }

    static func paneDetailLine(
        metadata: TerminalMetadata?,
        fallbackTitle: String?,
        minimumPathSegments: Int = 1
    ) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap {
            compactDirectoryName($0, minimumSegments: minimumPathSegments)
        }
        let fallback = meaningfulSidebarDetailRole(
            metadata: metadata,
            fallbackTitle: fallbackTitle
        )

        if let branch, let compactDirectory {
            return "\(branch) • \(compactDirectory)"
        }

        if let branch {
            return branch
        }

        if let fallback, let compactDirectory {
            return "\(fallback) • \(compactDirectory)"
        }

        return compactDirectory ?? fallback
    }

    static func singlePaneSidebarDetailLine(metadata: TerminalMetadata?) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = resolvedWorkingDirectory(for: metadata).flatMap {
            compactDirectoryName($0)
        }

        if let branch, let compactDirectory {
            return "\(branch) • \(compactDirectory)"
        }

        return branch
    }

    static func normalizeSidebarFallbackTitle(_ title: String?) -> String? {
        guard let normalized = trimmed(title) else {
            return nil
        }

        if normalized.range(of: #"^pane \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }

        if normalized.caseInsensitiveCompare("shell") == .orderedSame {
            return nil
        }

        if normalized.caseInsensitiveCompare("split") == .orderedSame {
            return nil
        }

        if normalized.caseInsensitiveCompare("git") == .orderedSame {
            return "git"
        }

        return normalized
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    static func displayBranch(_ value: String?) -> String? {
        guard let value = trimmed(value), !looksCompactedForDisplay(value) else {
            return nil
        }

        return value
    }

    static func looksCompactedForDisplay(_ value: String?) -> Bool {
        guard let value = trimmed(value) else {
            return false
        }

        return value.contains("...") || value.contains("…")
    }

    private static func meaningfulSidebarRole(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> String? {
        normalizeSidebarFallbackTitle(metadata?.title)
            ?? normalizeSidebarFallbackTitle(metadata?.processName)
            ?? normalizeSidebarFallbackTitle(fallbackTitle)
    }

    private static func meaningfulSidebarDetailRole(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> String? {
        guard let role = meaningfulSidebarRole(
            metadata: metadata,
            fallbackTitle: fallbackTitle
        ) else {
            return nil
        }

        switch role.lowercased() {
        case "zsh", "bash", "fish", "sh":
            return nil
        default:
            return role
        }
    }

    private static func sidebarPathComponents(_ path: String) -> [String]? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = trimmedPath.hasPrefix(homePath)
            ? trimmedPath.replacingOccurrences(of: homePath, with: "~")
            : trimmedPath

        guard normalizedPath != "~" else {
            return ["~"]
        }

        let components = normalizedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard components.isEmpty == false else {
            return nil
        }

        return components
    }

    private static func worktreeSidebarPathLabel(_ path: String) -> String? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = trimmedPath.hasPrefix(homePath)
            ? trimmedPath.replacingOccurrences(of: homePath, with: "~")
            : trimmedPath
        let components = normalizedPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let worktreesIndex = components.firstIndex(of: "worktrees"),
              worktreesIndex + 2 < components.count else {
            return nil
        }

        return components[(worktreesIndex + 1)...(worktreesIndex + 2)].joined(separator: "/")
    }

    private static func inferredWorkingDirectory(fromTitle title: String?) -> String? {
        guard let trimmedTitle = trimmed(title) else {
            return nil
        }

        var candidates = [trimmedTitle]
        candidates.append(contentsOf: trimmedTitle.split(separator: ":").reversed().map(String.init))
        return candidates.lazy.compactMap(normalizedWorkingDirectoryCandidate).first
    }

    private static func normalizedWorkingDirectoryCandidate(_ candidate: String?) -> String? {
        guard let trimmedCandidate = trimmed(candidate) else {
            return nil
        }

        if trimmedCandidate == "~" {
            return NSHomeDirectory()
        }

        if trimmedCandidate.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(trimmedCandidate.dropFirst(2)))
        }

        guard trimmedCandidate.hasPrefix("/") else {
            return nil
        }

        return trimmedCandidate
    }
}
