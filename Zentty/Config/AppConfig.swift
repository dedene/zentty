import CoreGraphics
import Foundation

enum AppUpdateChannel: String, CaseIterable, Equatable, Sendable {
    case stable
    case beta

    var displayName: String {
        switch self {
        case .stable:
            "Stable"
        case .beta:
            "Beta"
        }
    }
}

struct AppConfig: Equatable, Sendable {
    struct Appearance: Equatable, Sendable {
        var localThemeName: String?
        var localBackgroundOpacity: CGFloat?
        var syncOpenCodeThemeWithTerminal: Bool

        static let `default` = Appearance(
            localThemeName: nil,
            localBackgroundOpacity: nil,
            syncOpenCodeThemeWithTerminal: true
        )
    }

    struct Sidebar: Equatable, Sendable {
        var width: CGFloat
        var visibility: SidebarVisibilityMode
    }

    struct OpenWith: Equatable, Sendable {
        var primaryTargetID: String
        var enabledTargetIDs: [String]
        var customApps: [OpenWithCustomApp]

        static let `default` = OpenWith(
            primaryTargetID: "finder",
            enabledTargetIDs: ["finder", "vscode", "cursor", "xcode"],
            customApps: []
        )
    }

    struct Panes: Equatable, Sendable {
        var showLabels: Bool
        var inactiveOpacity: CGFloat

        static let minimumInactiveOpacity: CGFloat = 0.6
        static let maximumInactiveOpacity: CGFloat = 1.0

        static let `default` = Panes(
            showLabels: true,
            inactiveOpacity: 0.7
        )
    }

    struct Shortcuts: Equatable, Sendable {
        var bindings: [ShortcutBindingOverride]

        static let `default` = Shortcuts(bindings: [])
    }

    struct Notifications: Equatable, Sendable {
        /// Empty string means system default sound.
        var soundName: String

        static let `default` = Notifications(soundName: "")
    }

    struct Confirmations: Equatable, Sendable {
        var confirmBeforeClosingPane: Bool
        var confirmBeforeClosingWindow: Bool
        var confirmBeforeQuitting: Bool

        static let `default` = Confirmations(
            confirmBeforeClosingPane: true,
            confirmBeforeClosingWindow: true,
            confirmBeforeQuitting: true
        )
    }

    struct ErrorReporting: Equatable, Sendable {
        var enabled: Bool

        static let `default` = ErrorReporting(enabled: true)
    }

    struct Updates: Equatable, Sendable {
        var channel: AppUpdateChannel

        static let `default` = Updates(channel: .stable)
    }

    struct Restore: Equatable, Sendable {
        var restoreWorkspaceOnLaunch: Bool

        static let `default` = Restore(restoreWorkspaceOnLaunch: true)
    }

    struct Clipboard: Equatable, Sendable {
        var alwaysCleanCopies: Bool

        static let `default` = Clipboard(alwaysCleanCopies: false)
    }

    var sidebar: Sidebar
    var paneLayout: PaneLayoutPreferences
    var panes: Panes
    var openWith: OpenWith
    var errorReporting: ErrorReporting
    var updates: Updates
    var shortcuts: Shortcuts
    var notifications: Notifications
    var confirmations: Confirmations
    var clipboard: Clipboard
    var appearance: Appearance
    var restore: Restore

    static let `default` = AppConfig(
        sidebar: Sidebar(
            width: SidebarWidthPreference.defaultWidth,
            visibility: .pinnedOpen
        ),
        paneLayout: .default,
        panes: .default,
        openWith: .default,
        errorReporting: .default,
        updates: .default,
        shortcuts: .default,
        notifications: .default,
        confirmations: .default,
        clipboard: .default,
        appearance: .default,
        restore: .default
    )

    static func migrated(
        sidebarWidthDefaults: UserDefaults,
        sidebarVisibilityDefaults: UserDefaults,
        paneLayoutDefaults: UserDefaults
    ) -> AppConfig {
        AppConfig(
            sidebar: Sidebar(
                width: SidebarWidthPreference.restoredWidth(from: sidebarWidthDefaults),
                visibility: SidebarVisibilityPreference.restoredVisibility(from: sidebarVisibilityDefaults)
            ),
            paneLayout: PaneLayoutPreferenceStore.restoredPreferences(from: paneLayoutDefaults),
            panes: .default,
            openWith: .default,
            errorReporting: .default,
            updates: .default,
            shortcuts: .default,
            notifications: .default,
            confirmations: .default,
            clipboard: .default,
            appearance: .default,
            restore: .default
        )
    }

    func normalized() -> AppConfig {
        var normalized = self
        normalized.panes = normalized.panes.normalized()
        normalized.openWith = normalized.openWith.normalized()
        normalized.shortcuts = normalized.shortcuts.normalized()
        return normalized
    }
}

struct OpenWithCustomApp: Equatable, Sendable {
    var id: String
    var name: String
    var appPath: String
}

extension AppConfig.OpenWith {
    func normalized() -> AppConfig.OpenWith {
        let builtInIDs = Set(OpenWithCatalog.macOSBuiltInTargets.map { $0.id.rawValue })
        var canonicalApps: [OpenWithCustomApp] = []
        var seenCustomIDs: Set<String> = []
        var canonicalIDByDuplicateID: [String: String] = [:]

        for app in customApps {
            guard !app.id.isEmpty, !app.name.isEmpty, !app.appPath.isEmpty else {
                continue
            }

            if let existing = canonicalApps.first(where: { $0.appPath == app.appPath }) {
                canonicalIDByDuplicateID[app.id] = existing.id
                continue
            }

            guard !builtInIDs.contains(app.id), seenCustomIDs.insert(app.id).inserted else {
                continue
            }

            canonicalApps.append(app)
        }

        let validTargetIDs = builtInIDs.union(canonicalApps.map(\.id))
        var normalizedEnabledTargetIDs: [String] = []
        var seenEnabledTargetIDs: Set<String> = []

        for targetID in enabledTargetIDs {
            let canonicalTargetID = canonicalIDByDuplicateID[targetID] ?? targetID
            guard
                validTargetIDs.contains(canonicalTargetID),
                seenEnabledTargetIDs.insert(canonicalTargetID).inserted
            else {
                continue
            }

            normalizedEnabledTargetIDs.append(canonicalTargetID)
        }

        let normalizedPrimaryTargetID: String = {
            let requestedTargetID = canonicalIDByDuplicateID[primaryTargetID] ?? primaryTargetID
            if validTargetIDs.contains(requestedTargetID) {
                return requestedTargetID
            }

            return normalizedEnabledTargetIDs.first ?? AppConfig.OpenWith.default.primaryTargetID
        }()

        return AppConfig.OpenWith(
            primaryTargetID: normalizedPrimaryTargetID,
            enabledTargetIDs: normalizedEnabledTargetIDs,
            customApps: canonicalApps
        )
    }
}

extension AppConfig.Shortcuts {
    func normalized() -> AppConfig.Shortcuts {
        AppConfig.Shortcuts(bindings: ShortcutManager.sanitizedBindings(bindings))
    }

    func updating(commandID: AppCommandID, shortcut: KeyboardShortcut?) -> AppConfig.Shortcuts {
        AppConfig.Shortcuts(
            bindings: ShortcutManager.updatedBindings(
                from: bindings,
                commandID: commandID,
                shortcut: shortcut
            )
        )
    }
}

extension AppConfig.Panes {
    func normalized() -> AppConfig.Panes {
        AppConfig.Panes(
            showLabels: showLabels,
            inactiveOpacity: min(
                max(inactiveOpacity, AppConfig.Panes.minimumInactiveOpacity),
                AppConfig.Panes.maximumInactiveOpacity
            )
        )
    }
}

struct GhosttyConfigEnvironment {
    enum Mode: Equatable {
        case sharedGhostty
        case zenttyLocal
    }

    struct ResolvedStack: Equatable {
        let mode: Mode
        let loadFiles: [URL]
        let writeTargetURL: URL?
        let preferredCreateTargetURL: URL
        let localOverrideContents: String?
        let usesBundledDefaultsOnly: Bool

        var primaryWatchURL: URL {
            writeTargetURL ?? preferredCreateTargetURL
        }

        func mergedUserConfigContents(fileManager: FileManager = .default) -> String? {
            var visitedPaths: Set<String> = []
            var sections: [String] = []

            for url in loadFiles {
                sections.append(
                    contentsRecursively(
                        at: url,
                        visitedPaths: &visitedPaths,
                        fileManager: fileManager
                    )
                )
            }

            if let localOverrideContents, !localOverrideContents.isEmpty {
                sections.append(localOverrideContents)
            }

            let nonEmptySections = sections
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !nonEmptySections.isEmpty else {
                return nil
            }

            return nonEmptySections.joined(separator: "\n")
        }

        private func contentsRecursively(
            at url: URL,
            visitedPaths: inout Set<String>,
            fileManager: FileManager
        ) -> String {
            let normalizedPath = url.standardizedFileURL.path
            guard visitedPaths.insert(normalizedPath).inserted else {
                return ""
            }

            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return ""
            }

            var sections = [contents]

            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else {
                    continue
                }

                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    continue
                }

                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard key == "config-file",
                      let includedURL = resolveIncludedConfigURL(
                          rawValue: value,
                          relativeTo: url,
                          fileManager: fileManager
                      ) else {
                    continue
                }

                sections.append(
                    contentsRecursively(
                        at: includedURL,
                        visitedPaths: &visitedPaths,
                        fileManager: fileManager
                    )
                )
            }

            return sections
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        private func resolveIncludedConfigURL(
            rawValue: String,
            relativeTo sourceURL: URL,
            fileManager: FileManager
        ) -> URL? {
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else {
                return nil
            }

            let candidateURL: URL
            if value.hasPrefix("/") {
                candidateURL = URL(fileURLWithPath: value)
            } else if value.hasPrefix("~") {
                candidateURL = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            } else {
                candidateURL = sourceURL.deletingLastPathComponent().appendingPathComponent(value)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }

            return candidateURL
        }
    }

    private let fileManager: FileManager
    private let appConfigProvider: () -> AppConfig

    let homeDirectoryURL: URL
    let bundledDefaultsURL: URL?
    let ghosttyBundleIdentifier: String

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundledDefaultsURL: URL? = GhosttyConfigEnvironment.defaultBundledDefaultsURL(),
        ghosttyBundleIdentifier: String = "com.mitchellh.ghostty",
        fileManager: FileManager = .default,
        appConfigProvider: @escaping () -> AppConfig = GhosttyConfigEnvironment.defaultAppConfig
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.bundledDefaultsURL = bundledDefaultsURL
        self.ghosttyBundleIdentifier = ghosttyBundleIdentifier
        self.fileManager = fileManager
        self.appConfigProvider = appConfigProvider
    }

    var preferredCreateTargetURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    func resolvedStack() -> ResolvedStack? {
        let sharedConfigURLs = existingSharedConfigURLs()
        if !sharedConfigURLs.isEmpty {
            return ResolvedStack(
                mode: .sharedGhostty,
                loadFiles: sharedConfigURLs,
                writeTargetURL: sharedConfigURLs.last(where: isXDGGhosttyConfigURL),
                preferredCreateTargetURL: preferredCreateTargetURL,
                localOverrideContents: nil,
                usesBundledDefaultsOnly: false
            )
        }

        guard let bundledDefaultsURL else {
            return nil
        }

        return ResolvedStack(
            mode: .zenttyLocal,
            loadFiles: [bundledDefaultsURL],
            writeTargetURL: nil,
            preferredCreateTargetURL: preferredCreateTargetURL,
            localOverrideContents: localOverrideContents(from: appConfigProvider().appearance),
            usesBundledDefaultsOnly: true
        )
    }

    func existingSharedConfigURLs() -> [URL] {
        var urls: [URL] = []

        #if os(macOS)
        let appSupportDirectoryURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(ghosttyBundleIdentifier, isDirectory: true)

        let legacyAppSupportURL = appSupportDirectoryURL.appendingPathComponent("config", isDirectory: false)
        if isExistingFile(at: legacyAppSupportURL) {
            urls.append(legacyAppSupportURL)
        }

        let appSupportURL = appSupportDirectoryURL.appendingPathComponent("config.ghostty", isDirectory: false)
        if isExistingFile(at: appSupportURL) {
            urls.append(appSupportURL)
        }
        #endif

        let legacyXDGURL = homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        if isExistingFile(at: legacyXDGURL) {
            urls.append(legacyXDGURL)
        }

        let xdgURL = homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        if isExistingFile(at: xdgURL) {
            urls.append(xdgURL)
        }

        return urls
    }

    private func isExistingFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        return !isDirectory.boolValue
    }

    private func isXDGGhosttyConfigURL(_ url: URL) -> Bool {
        let xdgGhosttyDirectory = homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
            .standardizedFileURL

        return url.deletingLastPathComponent().standardizedFileURL == xdgGhosttyDirectory
    }

    private func localOverrideContents(from appearance: AppConfig.Appearance) -> String? {
        var lines: [String] = []

        if let themeName = sanitizedThemeName(appearance.localThemeName) {
            lines.append("theme = \(themeName)")
        }

        if let opacity = appearance.localBackgroundOpacity {
            let clamped = min(max(opacity, 0), 1)
            lines.append("background-opacity = \(String(format: "%.2f", clamped))")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func sanitizedThemeName(_ rawThemeName: String?) -> String? {
        guard let rawThemeName else {
            return nil
        }

        let sanitized = rawThemeName
            .filter { $0 != "\"" && !$0.isNewline }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func defaultBundledDefaultsURL() -> URL? {
        Bundle.main.url(forResource: "zentty-defaults", withExtension: "ghostty", subdirectory: "ghostty")
            ?? Bundle.main.url(forResource: "zentty-defaults", withExtension: "ghostty")
    }

    private static func defaultAppConfig() -> AppConfig {
        let fileURL = AppConfigStore.defaultFileURL()
        guard
            let source = try? String(contentsOf: fileURL, encoding: .utf8),
            let config = AppConfigTOML.decode(source)
        else {
            return .default
        }

        return config.normalized()
    }
}
