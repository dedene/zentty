import CoreGraphics
import Foundation

enum NewWorklanePlacement: String, CaseIterable, Equatable, Sendable {
    case top
    case afterCurrent = "after_current"
    case end

    var displayName: String {
        switch self {
        case .top:
            "Top"
        case .afterCurrent:
            "After current"
        case .end:
            "End"
        }
    }

    var settingsDescription: String {
        switch self {
        case .top:
            "Add new worklanes to the top of the list."
        case .afterCurrent:
            "Add new worklanes after the current worklane."
        case .end:
            "Append new worklanes to the bottom of the list."
        }
    }
}

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
        enum ThemeMode: String, CaseIterable, Equatable, Sendable {
            case followMacOS
            case alwaysDark
            case alwaysLight
        }

        var localThemeName: String?
        var themeMode: ThemeMode
        var preferredDarkThemeName: String?
        var preferredLightThemeName: String?
        var localBackgroundOpacity: CGFloat?
        var syncOpenCodeThemeWithTerminal: Bool

        static let `default` = Appearance(
            localThemeName: nil,
            themeMode: .alwaysDark,
            preferredDarkThemeName: nil,
            preferredLightThemeName: nil,
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

    struct ServerDetection: Equatable, Sendable {
        var passiveDetectionEnabled: Bool
        var preferredBrowserID: String
        /// Installed built-in slugs and `custom:` ids the user wants in the Open Server browser menu (never includes `system-default`).
        var enabledBrowserTargetIDs: [String]
        var customBrowsers: [ServerBrowserCustomApp]
        /// Canonical port rules whose detected servers are hidden from the menu and primary
        /// selection. Bare ports (`"9229"`) or inclusive ranges (`"24678-24680"`); see `ServerPortRule`.
        var ignoredPortRules: [String]

        static let `default` = ServerDetection(
            passiveDetectionEnabled: true,
            preferredBrowserID: ServerBrowserTarget.systemDefaultID,
            enabledBrowserTargetIDs: [],
            customBrowsers: [],
            ignoredPortRules: []
        )
    }

    struct Panes: Equatable, Sendable {
        enum FocusFollowsMouseDelay: String, CaseIterable, Equatable, Sendable {
            case immediate
            case short

            var title: String {
                switch self {
                case .immediate:
                    "Immediate"
                case .short:
                    "Short"
                }
            }

            var interval: TimeInterval {
                switch self {
                case .immediate:
                    0
                case .short:
                    0.1
                }
            }
        }

        var showLabels: Bool
        var showBorders: Bool
        var inactiveOpacity: CGFloat
        var showProjectIcons: Bool
        var smoothScrollingEnabled: Bool
        var focusFollowsMouse: Bool
        var focusFollowsMouseDelay: FocusFollowsMouseDelay

        static let minimumInactiveOpacity: CGFloat = 0.6
        static let maximumInactiveOpacity: CGFloat = 1.0

        init(
            showLabels: Bool,
            showBorders: Bool = true,
            inactiveOpacity: CGFloat,
            showProjectIcons: Bool,
            smoothScrollingEnabled: Bool = false,
            focusFollowsMouse: Bool = false,
            focusFollowsMouseDelay: FocusFollowsMouseDelay = .short
        ) {
            self.showLabels = showLabels
            self.showBorders = showBorders
            self.inactiveOpacity = inactiveOpacity
            self.showProjectIcons = showProjectIcons
            self.smoothScrollingEnabled = smoothScrollingEnabled
            self.focusFollowsMouse = focusFollowsMouse
            self.focusFollowsMouseDelay = focusFollowsMouseDelay
        }

        static let `default` = Panes(
            showLabels: true,
            showBorders: true,
            inactiveOpacity: 0.7,
            showProjectIcons: true,
            smoothScrollingEnabled: false,
            focusFollowsMouse: false,
            focusFollowsMouseDelay: .short
        )
    }

    struct Shortcuts: Equatable, Sendable {
        var bindings: [ShortcutBindingOverride]

        static let `default` = Shortcuts(bindings: [])
    }

    struct Notifications: Equatable, Sendable {
        /// Empty string means system default sound.
        var soundName: String
        /// Display name for a user-chosen custom sound file (when soundName is the internal custom file).
        var customSoundDisplayName: String?

        static let `default` = Notifications(soundName: "", customSoundDisplayName: nil)

        func normalized() -> Notifications {
            var normalized = self
            if !NotificationSoundManager.isCustomSoundName(normalized.soundName) {
                normalized.customSoundDisplayName = nil
            }
            return normalized
        }
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

    struct Worklanes: Equatable, Sendable {
        var newWorklanePlacement: NewWorklanePlacement

        static let `default` = Worklanes(newWorklanePlacement: .afterCurrent)
    }

    struct AgentTeams: Equatable, Sendable {
        var enabled: Bool

        static let `default` = AgentTeams(enabled: false)
    }

    struct AgentCaffeination: Equatable, Sendable {
        var enabled: Bool

        static let `default` = AgentCaffeination(enabled: true)
    }

    struct MenuBar: Equatable, Sendable {
        var showStatusItem: Bool

        static let `default` = MenuBar(
            showStatusItem: true
        )
    }

    /// Per-agent enable/disable state for Zentty's CLI integrations. Persistent
    /// (config-modifying) agents are tri-state and consent-gated; ephemeral
    /// agents are on by default. See `AgentIntegrationConsent`.
    struct AgentIntegrations: Equatable, Sendable {
        /// State keyed by `AgentBootstrapTool.rawValue`. Absent keys fall back to
        /// the tool's class default (`AgentBootstrapTool.defaultIntegrationState`).
        var states: [String: AgentIntegrationState]
        /// True once the one-time grandfather migration has run, marking
        /// already-installed persistent agents `on` so upgrading users are not
        /// re-prompted for consent.
        var grandfatheredV1: Bool

        static let `default` = AgentIntegrations(states: [:], grandfatheredV1: false)

        /// Effective state for a tool, applying the class default when unset.
        func state(for tool: AgentBootstrapTool) -> AgentIntegrationState {
            AgentIntegrationConsent.effectiveState(for: tool, storedState: states[tool.rawValue])
        }
    }

    var sidebar: Sidebar
    var paneLayout: PaneLayoutPreferences
    var panes: Panes
    var openWith: OpenWith
    var serverDetection: ServerDetection
    var errorReporting: ErrorReporting
    var updates: Updates
    var shortcuts: Shortcuts
    var notifications: Notifications
    var confirmations: Confirmations
    var clipboard: Clipboard
    var worklanes: Worklanes
    var appearance: Appearance
    var restore: Restore
    var agentTeams: AgentTeams
    var agentCaffeination: AgentCaffeination
    var menuBar: MenuBar
    var agentIntegrations: AgentIntegrations

    static let `default` = AppConfig(
        sidebar: Sidebar(
            width: SidebarWidthPreference.defaultWidth,
            visibility: .pinnedOpen
        ),
        paneLayout: .default,
        panes: .default,
        openWith: .default,
        serverDetection: .default,
        errorReporting: .default,
        updates: .default,
        shortcuts: .default,
        notifications: .default,
        confirmations: .default,
        clipboard: .default,
        worklanes: .default,
        appearance: .default,
        restore: .default,
        agentTeams: .default,
        agentCaffeination: .default,
        menuBar: .default,
        agentIntegrations: .default
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
            serverDetection: .default,
            errorReporting: .default,
            updates: .default,
            shortcuts: .default,
            notifications: .default,
            confirmations: .default,
            clipboard: .default,
            worklanes: .default,
            appearance: .default,
            restore: .default,
            agentTeams: .default,
            agentCaffeination: .default,
            menuBar: .default,
            agentIntegrations: .default
        )
    }

    func normalized() -> AppConfig {
        var normalized = self
        normalized.panes = normalized.panes.normalized()
        normalized.openWith = normalized.openWith.normalized()
        normalized.serverDetection = normalized.serverDetection.normalized()
        normalized.shortcuts = normalized.shortcuts.normalized()
        normalized.notifications = normalized.notifications.normalized()
        return normalized
    }
}

struct OpenWithCustomApp: Equatable, Sendable {
    var id: String
    var name: String
    var appPath: String
}

struct ServerBrowserCustomApp: Equatable, Sendable {
    var id: String
    var name: String
    var appPath: String
    var bundleIdentifier: String?
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

extension AppConfig.ServerDetection {
    func normalized() -> AppConfig.ServerDetection {
        var canonicalBrowsers: [ServerBrowserCustomApp] = []
        var seenIDs: Set<String> = []
        var canonicalIDByDuplicateID: [String: String] = [:]

        for browser in customBrowsers {
            guard !browser.id.isEmpty, !browser.name.isEmpty, !browser.appPath.isEmpty else {
                continue
            }

            if let existing = canonicalBrowsers.first(where: { $0.appPath == browser.appPath }) {
                canonicalIDByDuplicateID[browser.id] = existing.id
                continue
            }

            guard seenIDs.insert(browser.id).inserted else {
                continue
            }

            canonicalBrowsers.append(browser)
        }

        let validCustomIDs = Set(canonicalBrowsers.map(\.id))
        let validBuiltInIDs = ServerBrowserCatalog.builtInStableIDs()
        let orderedValidIDs = ServerBrowserCatalog.orderedBrowserTargetIDs(customBrowserIDs: canonicalBrowsers.map(\.id))
        let validToggleTargetIDs = Set(orderedValidIDs)

        let enabledSource = enabledBrowserTargetIDs.isEmpty ? orderedValidIDs : enabledBrowserTargetIDs
        var normalizedEnabledBrowserTargetIDs: [String] = []
        var seenEnabled: Set<String> = []
        for stableID in enabledSource {
            let canonicalID = canonicalIDByDuplicateID[stableID] ?? stableID
            guard validToggleTargetIDs.contains(canonicalID), seenEnabled.insert(canonicalID).inserted else {
                continue
            }
            normalizedEnabledBrowserTargetIDs.append(canonicalID)
        }

        let enabledSet = Set(normalizedEnabledBrowserTargetIDs)

        let resolvedPreferred = canonicalIDByDuplicateID[preferredBrowserID] ?? preferredBrowserID

        let normalizedPreferredBrowserID: String
        if resolvedPreferred == ServerBrowserTarget.systemDefaultID {
            normalizedPreferredBrowserID = ServerBrowserTarget.systemDefaultID
        } else if resolvedPreferred.hasPrefix("bundle:") {
            let bundleID = String(resolvedPreferred.dropFirst("bundle:".count))
            if bundleID.isEmpty {
                normalizedPreferredBrowserID = ServerBrowserTarget.systemDefaultID
            } else if let slug = ServerBrowserCatalog.builtInSlug(forBundleIdentifier: bundleID) {
                normalizedPreferredBrowserID = enabledSet.contains(slug)
                    ? resolvedPreferred
                    : ServerBrowserTarget.systemDefaultID
            } else {
                normalizedPreferredBrowserID = ServerBrowserTarget.systemDefaultID
            }
        } else if validBuiltInIDs.contains(resolvedPreferred) || validCustomIDs.contains(resolvedPreferred) {
            normalizedPreferredBrowserID = enabledSet.contains(resolvedPreferred)
                ? resolvedPreferred
                : ServerBrowserTarget.systemDefaultID
        } else {
            normalizedPreferredBrowserID = ServerBrowserTarget.systemDefaultID
        }

        return AppConfig.ServerDetection(
            passiveDetectionEnabled: passiveDetectionEnabled,
            preferredBrowserID: normalizedPreferredBrowserID,
            enabledBrowserTargetIDs: normalizedEnabledBrowserTargetIDs,
            customBrowsers: canonicalBrowsers,
            ignoredPortRules: ServerPortRule.canonicalStrings(ignoredPortRules)
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
            showBorders: showBorders,
            inactiveOpacity: min(
                max(inactiveOpacity, AppConfig.Panes.minimumInactiveOpacity),
                AppConfig.Panes.maximumInactiveOpacity
            ),
            showProjectIcons: showProjectIcons,
            smoothScrollingEnabled: smoothScrollingEnabled,
            focusFollowsMouse: focusFollowsMouse,
            focusFollowsMouseDelay: focusFollowsMouseDelay
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

        if let themeSpec = localThemeSpec(from: appearance) {
            lines.append("theme = \(themeSpec.rawValue)")
        }

        if let opacity = appearance.localBackgroundOpacity {
            let clamped = min(max(opacity, 0), 1)
            lines.append("background-opacity = \(String(format: "%.2f", clamped))")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func localThemeSpec(from appearance: AppConfig.Appearance) -> GhosttyThemeSpec? {
        let preferredDarkThemeName = sanitizedThemeName(appearance.preferredDarkThemeName)
            ?? sanitizedThemeName(appearance.localThemeName)
        let preferredLightThemeName = sanitizedThemeName(appearance.preferredLightThemeName)

        guard preferredDarkThemeName != nil
            || preferredLightThemeName != nil
            || appearance.themeMode != AppConfig.Appearance.default.themeMode else {
            return nil
        }

        return GhosttyThemeSpec(
            mode: appearance.themeMode,
            darkThemeName: preferredDarkThemeName,
            lightThemeName: preferredLightThemeName
        )
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
