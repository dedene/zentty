import Foundation

enum WorklaneContextFormatter {
    static func contextText(for metadata: TerminalMetadata?) -> String {
        let branch = displayBranch(metadata?.gitBranch)
        let formattedDirectory = formattedWorkingDirectory(
            resolvedWorkingDirectory(for: metadata),
            branch: branch
        )
        return [branch, formattedDirectory]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    static func displayTerminalIdentity(
        for metadata: TerminalMetadata?,
        fallbackTitle: String? = nil
    ) -> String? {
        normalizeDisplayIdentity(metadata?.title)
            ?? normalizeDisplayIdentity(metadata?.processName)
            ?? normalizeDisplayIdentity(fallbackTitle)
    }

    static func displayMeaningfulTerminalIdentity(
        for metadata: TerminalMetadata?,
        fallbackTitle: String? = nil
    ) -> String? {
        [
            normalizeDisplayIdentity(metadata?.title),
            normalizeDisplayIdentity(metadata?.processName),
            normalizeDisplayIdentity(fallbackTitle),
        ].first {
            guard let candidate = $0 else {
                return false
            }

            return !isGenericShellIdentity(candidate)
                && !looksLikeResolvedPathIdentity(candidate)
        } ?? nil
    }

    static func displayWorkingDirectory(
        for metadata: TerminalMetadata?,
        shellContext: PaneShellContext? = nil,
        branch: String? = nil
    ) -> String? {
        formattedWorkingDirectory(
            resolvedWorkingDirectory(for: metadata, shellContext: shellContext),
            branch: branch ?? metadata?.gitBranch
        )
    }

    static func displayStablePaneIdentity(
        for metadata: TerminalMetadata?,
        fallbackTitle: String? = nil,
        workingDirectory: String? = nil,
        branch: String? = nil
    ) -> String? {
        let resolvedWorkingDirectory = workingDirectory ?? self.resolvedWorkingDirectory(for: metadata)
        let preferredBranch = displayBranch(branch ?? metadata?.gitBranch)
        let formattedWorkingDirectory = formattedWorkingDirectory(
            resolvedWorkingDirectory,
            branch: preferredBranch
        )

        if shouldPreferFormattedWorkingDirectory(
            metadata: metadata,
            fallbackTitle: fallbackTitle
        ) {
            return formattedWorkingDirectory
                ?? displayTerminalIdentity(for: metadata, fallbackTitle: fallbackTitle)
                ?? normalizeSidebarFallbackTitle(fallbackTitle)
        }

        return displayMeaningfulTerminalIdentity(for: metadata, fallbackTitle: fallbackTitle)
            ?? formattedWorkingDirectory
            ?? displayTerminalIdentity(for: metadata, fallbackTitle: fallbackTitle)
            ?? normalizeSidebarFallbackTitle(fallbackTitle)
    }

    static func formattedWorkingDirectory(
        _ workingDirectory: String?,
        branch: String? = nil
    ) -> String? {
        guard let standardizedPath = standardizedPath(workingDirectory) else {
            return nil
        }

        let preferredBranch = displayBranch(branch)

        if standardizedPath == standardPath(NSHomeDirectory()) {
            return "~"
        }

        if let compactRepositoryPath = compactRepositoryPathLabel(
            for: standardizedPath,
            branch: preferredBranch
        ) {
            return compactRepositoryPath
        }

        if let developerRootLabel = developerRootLabel(for: standardizedPath) {
            return developerRootLabel
        }

        return standardizedPath
    }

    static func branchPrefixedLocationLabel(
        workingDirectory: String?,
        branch: String?
    ) -> String? {
        let preferredBranch = displayBranch(branch)
        let formattedWorkingDirectory = formattedWorkingDirectory(
            workingDirectory,
            branch: preferredBranch
        )

        if let preferredBranch, let formattedWorkingDirectory {
            return "\(preferredBranch) · \(formattedWorkingDirectory)"
        }

        return preferredBranch ?? formattedWorkingDirectory
    }

    static func resolvedWorkingDirectory(
        for metadata: TerminalMetadata?,
        shellContext: PaneShellContext? = nil
    ) -> String? {
        let reportedWorkingDirectory = normalizedWorkingDirectoryCandidate(metadata?.currentWorkingDirectory)
        let titleDerivedWorkingDirectory = inferredWorkingDirectory(fromTitle: metadata?.title)
        let shellContextWorkingDirectory = normalizedWorkingDirectoryCandidate(shellContext?.path)

        let metadataPreferredWorkingDirectory = preferredWorkingDirectory(
            reportedWorkingDirectory: reportedWorkingDirectory,
            titleDerivedWorkingDirectory: titleDerivedWorkingDirectory
        )

        if shellContext?.scope == .local,
           let shellContextWorkingDirectory {
            guard let metadataPreferredWorkingDirectory else {
                return shellContextWorkingDirectory
            }

            return standardPath(metadataPreferredWorkingDirectory) == standardPath(shellContextWorkingDirectory)
                ? metadataPreferredWorkingDirectory
                : shellContextWorkingDirectory
        }

        return preferredWorkingDirectory(
            reportedWorkingDirectory: metadataPreferredWorkingDirectory,
            titleDerivedWorkingDirectory: shellContextWorkingDirectory
        )
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
        guard let standardizedPath = standardizedPath(path) else {
            return nil
        }

        if standardizedPath == standardPath(NSHomeDirectory()) {
            return "~"
        }

        if let repoComponents = repositoryExpansionComponents(for: standardizedPath) {
            let clampedSegmentCount = min(max(1, minimumSegments), repoComponents.count)
            return "…/" + repoComponents.suffix(clampedSegmentCount).joined(separator: "/")
        }

        if let developerRootLabel = developerRootLabel(
            for: standardizedPath,
            minimumSegments: minimumSegments
        ) {
            return developerRootLabel
        }

        guard let components = sidebarPathComponents(standardizedPath) else {
            return nil
        }

        let clampedSegmentCount = min(
            max(1, minimumSegments),
            components.count
        )
        return components.suffix(clampedSegmentCount).joined(separator: "/")
    }

    static func compactRepositorySidebarPath(
        _ path: String,
        minimumSegments: Int = 1
    ) -> String? {
        guard let standardizedPath = standardizedPath(path) else {
            return nil
        }

        let repoComponents = repositoryExpansionComponents(for: standardizedPath)
            ?? sidebarPathComponents(standardizedPath)?.filter { $0 != "~" }
        guard let repoComponents, repoComponents.isEmpty == false else {
            return nil
        }

        let clampedSegmentCount = min(max(1, minimumSegments), repoComponents.count)
        return "…/" + repoComponents.suffix(clampedSegmentCount).joined(separator: "/")
    }

    static func maxSidebarPathSegments(_ path: String) -> Int? {
        guard let standardizedPath = standardizedPath(path) else {
            return nil
        }

        if standardizedPath == standardPath(NSHomeDirectory()) {
            return 1
        }

        if let repoComponents = repositoryExpansionComponents(for: standardizedPath) {
            return repoComponents.count
        }

        if let developerRoot = developerRootMatch(for: standardizedPath) {
            return max(1, developerRoot.relativeComponents.count)
        }

        guard let components = sidebarPathComponents(standardizedPath) else {
            return nil
        }

        return components.count
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
        workingDirectory: String? = nil,
        minimumPathSegments: Int = 1
    ) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = formattedWorkingDirectory(
            workingDirectory ?? resolvedWorkingDirectory(for: metadata),
            branch: branch
        )
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

    static func singlePaneSidebarDetailLine(
        metadata: TerminalMetadata?,
        workingDirectory: String? = nil
    ) -> String? {
        let branch = displayBranch(metadata?.gitBranch)
        let compactDirectory = formattedWorkingDirectory(
            workingDirectory ?? resolvedWorkingDirectory(for: metadata),
            branch: branch
        )

        if let branch, let compactDirectory {
            return "\(branch) • \(compactDirectory)"
        }

        return branch ?? compactDirectory
    }

    static func normalizeSidebarFallbackTitle(_ title: String?) -> String? {
        normalizeDisplayIdentity(title)
    }

    static func normalizeDisplayIdentity(_ title: String?) -> String? {
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

    static func isDeveloperRootPath(_ path: String?) -> Bool {
        guard let standardizedPath = standardizedPath(path) else {
            return false
        }

        return developerRootMatch(for: standardizedPath) != nil
    }

    private static func meaningfulSidebarRole(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> String? {
        displayMeaningfulTerminalIdentity(for: metadata, fallbackTitle: fallbackTitle)
            ?? displayTerminalIdentity(for: metadata, fallbackTitle: fallbackTitle)
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

    private static func shouldPreferFormattedWorkingDirectory(
        metadata: TerminalMetadata?,
        fallbackTitle: String?
    ) -> Bool {
        if let processName = normalizeDisplayIdentity(metadata?.processName),
           isGenericShellIdentity(processName) {
            return true
        }

        let candidates = [
            normalizeDisplayIdentity(metadata?.title),
            normalizeDisplayIdentity(fallbackTitle),
        ].compactMap { $0 }

        return candidates.contains { inferredWorkingDirectory(fromTitle: $0) != nil }
    }

    private static func sidebarPathComponents(_ path: String) -> [String]? {
        guard let standardizedPath = standardizedPath(path) else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = standardizedPath.hasPrefix(homePath)
            ? standardizedPath.replacingOccurrences(of: homePath, with: "~")
            : standardizedPath

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

    private static func repositoryExpansionComponents(for path: String) -> [String]? {
        guard let repoRootPath = gitRepositoryRoot(for: path),
              let components = sidebarPathComponents(repoRootPath) else {
            return nil
        }

        let filtered = components.filter { $0 != "~" }
        guard filtered.isEmpty == false else {
            return nil
        }

        return filtered
    }

    private static func compactRepositoryPathLabel(
        for path: String,
        branch: String?
    ) -> String? {
        guard let components = repositoryExpansionComponents(for: path) ?? (
            displayBranch(branch) != nil ? sidebarPathComponents(path)?.filter({ $0 != "~" }) : nil
        ),
        let repositoryName = components.last else {
            return nil
        }

        return "…/\(repositoryName)"
    }

    private static func developerRootLabel(
        for path: String,
        minimumSegments: Int = 1
    ) -> String? {
        guard let match = developerRootMatch(for: path) else {
            return nil
        }

        guard match.relativeComponents.isEmpty == false else {
            return "~/\(match.rootName)"
        }

        let clampedSegmentCount = min(
            max(1, minimumSegments),
            match.relativeComponents.count
        )
        return "~/\(match.rootName)/" + match.relativeComponents.suffix(clampedSegmentCount).joined(separator: "/")
    }

    private static func developerRootMatch(for path: String) -> (rootName: String, root: String, relativeComponents: [String])? {
        let homePath = standardPath(NSHomeDirectory())
        let roots = ["Development", "Developer"].map { rootName in
            (
                rootName: rootName,
                root: standardPath((homePath as NSString).appendingPathComponent(rootName))
            )
        }

        for root in roots {
            if path == root.root {
                return (root.rootName, root.root, [])
            }

            let prefix = root.root + "/"
            guard path.hasPrefix(prefix) else {
                continue
            }

            let relativePath = String(path.dropFirst(prefix.count))
            let relativeComponents = relativePath
                .split(separator: "/")
                .map(String.init)
                .filter { !$0.isEmpty }
            return (root.rootName, root.root, relativeComponents)
        }

        return nil
    }

    private static func gitRepositoryRoot(for path: String) -> String? {
        var currentPath = standardPath(path)
        let fileManager = FileManager.default

        while true {
            let gitMarkerPath = (currentPath as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMarkerPath) {
                return currentPath
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath.isEmpty || parentPath == currentPath {
                return nil
            }

            currentPath = parentPath
        }
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

    private static func looksLikeResolvedPathIdentity(_ candidate: String) -> Bool {
        inferredWorkingDirectory(fromTitle: candidate) != nil
    }

    private static func preferredWorkingDirectory(
        reportedWorkingDirectory: String?,
        titleDerivedWorkingDirectory: String?
    ) -> String? {
        switch (reportedWorkingDirectory, titleDerivedWorkingDirectory) {
        case let (reported?, titleDerived?):
            return titleDerivedPathLooksFresher(
                titleDerivedWorkingDirectory: titleDerived,
                thanReportedWorkingDirectory: reported
            )
                ? titleDerived
                : reported
        case let (reported?, nil):
            return reported
        case let (nil, titleDerived?):
            return titleDerived
        case (nil, nil):
            return nil
        }
    }

    private static func titleDerivedPathLooksFresher(
        titleDerivedWorkingDirectory: String,
        thanReportedWorkingDirectory reportedWorkingDirectory: String
    ) -> Bool {
        let normalizedReported = standardPath(reportedWorkingDirectory)
        let normalizedTitleDerived = standardPath(titleDerivedWorkingDirectory)

        guard
            normalizedReported != normalizedTitleDerived,
            normalizedTitleDerived.hasPrefix(normalizedReported)
        else {
            return false
        }

        let prefix = normalizedReported == "/" ? normalizedReported : normalizedReported + "/"
        return normalizedTitleDerived.hasPrefix(prefix)
    }

    private static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func standardizedPath(_ path: String?) -> String? {
        guard let trimmedPath = trimmed(path) else {
            return nil
        }

        return standardPath(trimmedPath)
    }

    private static func isGenericShellIdentity(_ value: String) -> Bool {
        switch value.lowercased() {
        case "zsh", "bash", "fish", "sh":
            return true
        default:
            return false
        }
    }
}
