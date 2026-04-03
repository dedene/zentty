import CoreGraphics
import Foundation

struct AppConfig: Equatable, Sendable {
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

    var sidebar: Sidebar
    var paneLayout: PaneLayoutPreferences
    var openWith: OpenWith
    var errorReporting: ErrorReporting
    var shortcuts: Shortcuts
    var notifications: Notifications
    var confirmations: Confirmations

    static let `default` = AppConfig(
        sidebar: Sidebar(
            width: SidebarWidthPreference.defaultWidth,
            visibility: .pinnedOpen
        ),
        paneLayout: .default,
        openWith: .default,
        errorReporting: .default,
        shortcuts: .default,
        notifications: .default,
        confirmations: .default
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
            openWith: .default,
            errorReporting: .default,
            shortcuts: .default,
            notifications: .default,
            confirmations: .default
        )
    }

    func normalized() -> AppConfig {
        var normalized = self
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
