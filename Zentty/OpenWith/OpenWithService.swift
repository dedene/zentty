import AppKit

@MainActor
protocol OpenWithServing: AnyObject {
    func detectedTargets(preferences: AppConfig.OpenWith) -> [OpenWithDetectedTarget]
    func availableTargets(preferences: AppConfig.OpenWith) -> [OpenWithResolvedTarget]
    func primaryTarget(preferences: AppConfig.OpenWith) -> OpenWithResolvedTarget?
    func icon(for target: OpenWithResolvedTarget) -> NSImage?
    @discardableResult
    func open(target: OpenWithResolvedTarget, workingDirectory: String) -> Bool
}

@MainActor
final class OpenWithService: OpenWithServing {
    private let workspace: NSWorkspace
    private let fileManager: FileManager

    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func detectedTargets(preferences: AppConfig.OpenWith) -> [OpenWithDetectedTarget] {
        let availableTargetIDs = Set(discoveredAvailableTargetIDs(preferences: preferences))
        let builtInTargets = OpenWithCatalog.macOSBuiltInTargets.map { target in
            OpenWithDetectedTarget(
                target: OpenWithResolvedTarget(
                    stableID: target.id.rawValue,
                    kind: target.kind,
                    displayName: target.displayName,
                    builtInID: target.id,
                    appPath: nil
                ),
                isAvailable: availableTargetIDs.contains(target.id.rawValue)
            )
        }
        let customTargets = preferences.customApps.map { app in
            OpenWithDetectedTarget(
                target: OpenWithResolvedTarget(
                    stableID: app.id,
                    kind: .editor,
                    displayName: app.name,
                    builtInID: nil,
                    appPath: app.appPath
                ),
                isAvailable: availableTargetIDs.contains(app.id)
            )
        }

        return builtInTargets + customTargets
    }

    func availableTargets(preferences: AppConfig.OpenWith) -> [OpenWithResolvedTarget] {
        detectedTargets(preferences: preferences)
            .compactMap { $0.isAvailable ? $0.target : nil }
            .filter { preferences.enabledTargetIDs.contains($0.stableID) }
    }

    func primaryTarget(preferences: AppConfig.OpenWith) -> OpenWithResolvedTarget? {
        OpenWithPreferencesResolver.primaryTarget(
            preferences: preferences,
            availableTargetIDs: discoveredAvailableTargetIDs(preferences: preferences)
        )
    }

    func icon(for target: OpenWithResolvedTarget) -> NSImage? {
        if let applicationURL = applicationURL(for: target) {
            let icon = workspace.icon(forFile: applicationURL.path)
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }

        if target.id == .finder {
            return NSImage(systemSymbolName: "folder", accessibilityDescription: target.displayName)
        }

        return nil
    }

    @discardableResult
    func open(target: OpenWithResolvedTarget, workingDirectory: String) -> Bool {
        guard !workingDirectory.isEmpty else {
            return false
        }

        if target.id == .finder {
            return runOpen(arguments: [workingDirectory])
        }

        guard let applicationURL = applicationURL(for: target) else {
            return false
        }

        return runOpen(arguments: ["-a", applicationURL.path, workingDirectory])
    }

    private func discoveredAvailableTargetIDs(preferences: AppConfig.OpenWith) -> [String] {
        let builtInTargetIDs = OpenWithCatalog.macOSBuiltInTargets.compactMap { target -> String? in
            applicationURL(forBuiltInTarget: target.id) == nil ? nil : target.id.rawValue
        }
        let customTargetIDs = preferences.customApps.compactMap { app -> String? in
            guard isReadableApplication(at: app.appPath) else {
                return nil
            }

            return app.id
        }

        return builtInTargetIDs + customTargetIDs
    }

    private func applicationURL(for target: OpenWithResolvedTarget) -> URL? {
        if let builtInID = target.id {
            return applicationURL(forBuiltInTarget: builtInID)
        }

        guard let appPath = target.appPath, isReadableApplication(at: appPath) else {
            return nil
        }

        return URL(fileURLWithPath: appPath)
    }

    private func applicationURL(forBuiltInTarget id: OpenWithBuiltInTargetID) -> URL? {
        switch id {
        case .finder:
            let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            return fileManager.fileExists(atPath: finderURL.path) ? finderURL : nil
        case .vscode:
            return applicationURL(
                bundleIdentifiers: ["com.microsoft.VSCode"],
                exactNames: ["Visual Studio Code.app"]
            )
        case .vscodeInsiders:
            return applicationURL(
                bundleIdentifiers: ["com.microsoft.VSCodeInsiders"],
                exactNames: ["Visual Studio Code - Insiders.app"]
            )
        case .cursor:
            return applicationURL(
                bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
                exactNames: ["Cursor.app"]
            )
        case .zed:
            return applicationURL(
                bundleIdentifiers: ["dev.zed.Zed"],
                exactNames: ["Zed.app"]
            )
        case .windsurf:
            return applicationURL(
                bundleIdentifiers: ["com.exafunction.windsurf"],
                exactNames: ["Windsurf.app"]
            )
        case .antigravity:
            return applicationURL(
                bundleIdentifiers: [],
                exactNames: ["Antigravity.app"]
            )
        case .xcode:
            return applicationURL(
                bundleIdentifiers: ["com.apple.dt.Xcode"],
                exactNames: ["Xcode.app"]
            )
        case .androidStudio:
            return applicationURL(
                bundleIdentifiers: ["com.google.android.studio"],
                exactNames: ["Android Studio.app"],
                prefixNames: ["Android Studio"]
            )
        case .intellijIdea:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.intellij"],
                exactNames: ["IntelliJ IDEA.app"],
                prefixNames: ["IntelliJ IDEA"]
            )
        case .rider:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.rider"],
                exactNames: ["Rider.app"],
                prefixNames: ["Rider"]
            )
        case .goland:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.goland"],
                exactNames: ["GoLand.app"],
                prefixNames: ["GoLand"]
            )
        case .rustrover:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.rustrover"],
                exactNames: ["RustRover.app"],
                prefixNames: ["RustRover"]
            )
        case .pycharm:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.pycharm"],
                exactNames: ["PyCharm.app"],
                prefixNames: ["PyCharm"]
            )
        case .webstorm:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.webstorm"],
                exactNames: ["WebStorm.app"],
                prefixNames: ["WebStorm"]
            )
        case .phpstorm:
            return applicationURL(
                bundleIdentifiers: ["com.jetbrains.phpstorm"],
                exactNames: ["PhpStorm.app"],
                prefixNames: ["PhpStorm"]
            )
        case .sublimeText:
            return applicationURL(
                bundleIdentifiers: ["com.sublimetext.4"],
                exactNames: ["Sublime Text.app"]
            )
        case .bbedit:
            return applicationURL(
                bundleIdentifiers: ["com.barebones.bbedit"],
                exactNames: ["BBEdit.app"]
            )
        case .textmate:
            return applicationURL(
                bundleIdentifiers: ["com.macromates.TextMate"],
                exactNames: ["TextMate.app"]
            )
        }
    }

    private func applicationURL(
        bundleIdentifiers: [String],
        exactNames: [String],
        prefixNames: [String] = []
    ) -> URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return applicationURL
            }
        }

        let searchDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        for directoryURL in searchDirectories {
            for exactName in exactNames {
                let candidateURL = directoryURL.appendingPathComponent(exactName, isDirectory: true)
                if fileManager.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
            }

            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let prefixMatch = entries.first(where: { url in
                let name = url.lastPathComponent
                return prefixNames.contains(where: { name.hasPrefix($0) }) && name.hasSuffix(".app")
            }) {
                return prefixMatch
            }
        }

        return nil
    }

    private func isReadableApplication(at path: String) -> Bool {
        path.hasSuffix(".app") && fileManager.fileExists(atPath: path)
    }

    private func runOpen(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
