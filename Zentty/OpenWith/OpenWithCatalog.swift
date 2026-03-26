import Foundation

enum OpenWithTargetKind: String, Equatable, Sendable {
    case editor
    case fileManager
    case terminal
}

enum OpenWithBuiltInTargetID: String, CaseIterable, Equatable, Sendable {
    case vscode = "vscode"
    case vscodeInsiders = "vscode-insiders"
    case cursor = "cursor"
    case zed = "zed"
    case windsurf = "windsurf"
    case antigravity = "antigravity"
    case finder = "finder"
    case xcode = "xcode"
    case androidStudio = "android-studio"
    case intellijIdea = "intellij-idea"
    case rider = "rider"
    case goland = "goland"
    case rustrover = "rustrover"
    case pycharm = "pycharm"
    case webstorm = "webstorm"
    case phpstorm = "phpstorm"
    case sublimeText = "sublime-text"
    case bbedit = "bbedit"
    case textmate = "textmate"
}

struct OpenWithBuiltInTarget: Equatable, Sendable {
    let id: OpenWithBuiltInTargetID
    let displayName: String
    let kind: OpenWithTargetKind
}

struct OpenWithResolvedTarget: Equatable, Sendable {
    let stableID: String
    let kind: OpenWithTargetKind
    let displayName: String
    let builtInID: OpenWithBuiltInTargetID?
    let appPath: String?

    var id: OpenWithBuiltInTargetID? {
        builtInID
    }
}

struct OpenWithDetectedTarget: Equatable, Sendable {
    let target: OpenWithResolvedTarget
    let isAvailable: Bool
}

enum OpenWithCatalog {
    static let macOSBuiltInTargets: [OpenWithBuiltInTarget] = [
        .init(id: .vscode, displayName: "VS Code", kind: .editor),
        .init(id: .vscodeInsiders, displayName: "VS Code Insiders", kind: .editor),
        .init(id: .cursor, displayName: "Cursor", kind: .editor),
        .init(id: .zed, displayName: "Zed", kind: .editor),
        .init(id: .windsurf, displayName: "Windsurf", kind: .editor),
        .init(id: .antigravity, displayName: "Antigravity", kind: .editor),
        .init(id: .finder, displayName: "Finder", kind: .fileManager),
        .init(id: .xcode, displayName: "Xcode", kind: .editor),
        .init(id: .androidStudio, displayName: "Android Studio", kind: .editor),
        .init(id: .intellijIdea, displayName: "IntelliJ IDEA", kind: .editor),
        .init(id: .rider, displayName: "Rider", kind: .editor),
        .init(id: .goland, displayName: "GoLand", kind: .editor),
        .init(id: .rustrover, displayName: "RustRover", kind: .editor),
        .init(id: .pycharm, displayName: "PyCharm", kind: .editor),
        .init(id: .webstorm, displayName: "WebStorm", kind: .editor),
        .init(id: .phpstorm, displayName: "PhpStorm", kind: .editor),
        .init(id: .sublimeText, displayName: "Sublime Text", kind: .editor),
        .init(id: .bbedit, displayName: "BBEdit", kind: .editor),
        .init(id: .textmate, displayName: "TextMate", kind: .editor),
    ]
}

enum OpenWithPreferencesResolver {
    static func primaryTarget(
        preferences: AppConfig.OpenWith,
        availableTargetIDs: [String]
    ) -> OpenWithResolvedTarget? {
        let enabledTargets = enabledTargets(
            preferences: preferences,
            availableTargetIDs: availableTargetIDs
        )
        guard !enabledTargets.isEmpty else {
            return nil
        }

        if let requestedTarget = enabledTargets.first(where: { $0.stableID == preferences.primaryTargetID }) {
            return requestedTarget
        }

        return enabledTargets.first
    }

    static func enabledTargets(
        preferences: AppConfig.OpenWith,
        availableTargetIDs: [String]
    ) -> [OpenWithResolvedTarget] {
        let enabledIDs = Set(preferences.enabledTargetIDs)
        let availableIDs = Set(availableTargetIDs)

        let builtInTargets = OpenWithCatalog.macOSBuiltInTargets.compactMap { target -> OpenWithResolvedTarget? in
            let stableID = target.id.rawValue
            guard enabledIDs.contains(stableID), availableIDs.contains(stableID) else {
                return nil
            }

            return OpenWithResolvedTarget(
                stableID: stableID,
                kind: target.kind,
                displayName: target.displayName,
                builtInID: target.id,
                appPath: nil
            )
        }

        let customTargets = preferences.customApps.compactMap { app -> OpenWithResolvedTarget? in
            guard enabledIDs.contains(app.id), availableIDs.contains(app.id) else {
                return nil
            }

            return OpenWithResolvedTarget(
                stableID: app.id,
                kind: .editor,
                displayName: app.name,
                builtInID: nil,
                appPath: app.appPath
            )
        }

        return builtInTargets + customTargets
    }
}
