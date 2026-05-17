import AppKit
import Foundation

struct ServerBrowserTarget: Equatable, Sendable {
    static let systemDefaultID = "system-default"

    let stableID: String
    let displayName: String
    let bundleIdentifier: String?
    let appURL: URL?
    let isSystemDefault: Bool
    let isAvailable: Bool
}

enum ServerBrowserBuiltInID: String, CaseIterable, Equatable, Sendable {
    case safari
    case chrome
    case firefox
    case arc
    case brave
    case edge
    case orion
    case dia
    case zen
    case sizzy
    case mullvadBrowser = "mullvad-browser"
    case helium
    case vivaldi
    case opera
    case chromium
    case torBrowser = "tor-browser"
    case velja
    case sigmaOS = "sigmaos"
    case floorp
    case comet
}

struct ServerBrowserBuiltInTarget: Equatable, Sendable {
    let id: ServerBrowserBuiltInID
    let displayName: String
    let bundleIdentifiers: [String]
    let exactAppNames: [String]
    let prefixAppNames: [String]

    init(
        id: ServerBrowserBuiltInID,
        displayName: String,
        bundleIdentifiers: [String] = [],
        exactAppNames: [String] = [],
        prefixAppNames: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
        self.exactAppNames = exactAppNames
        self.prefixAppNames = prefixAppNames
    }
}

enum ServerBrowserCatalog {
    static let macOSBuiltInBrowsers: [ServerBrowserBuiltInTarget] = [
        ServerBrowserBuiltInTarget(
            id: .safari,
            displayName: "Safari",
            bundleIdentifiers: ["com.apple.Safari"],
            exactAppNames: ["Safari.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .chrome,
            displayName: "Google Chrome",
            bundleIdentifiers: ["com.google.Chrome"],
            exactAppNames: ["Google Chrome.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .firefox,
            displayName: "Firefox",
            bundleIdentifiers: ["org.mozilla.firefox"],
            exactAppNames: ["Firefox.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .arc,
            displayName: "Arc",
            bundleIdentifiers: ["company.thebrowser.Browser"],
            exactAppNames: ["Arc.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .brave,
            displayName: "Brave",
            bundleIdentifiers: ["com.brave.Browser"],
            exactAppNames: ["Brave Browser.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .edge,
            displayName: "Microsoft Edge",
            bundleIdentifiers: ["com.microsoft.edgemac"],
            exactAppNames: ["Microsoft Edge.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .orion,
            displayName: "Orion",
            bundleIdentifiers: ["com.kagi.kagimacOS.Browser", "com.mac.Orion"],
            exactAppNames: ["Orion.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .dia,
            displayName: "Dia",
            bundleIdentifiers: ["company.thebrowser.dia"],
            exactAppNames: ["Dia.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .zen,
            displayName: "Zen",
            bundleIdentifiers: ["io.github.zen_browser.zen", "app.zen-browser.zen"],
            exactAppNames: ["Zen Browser.app", "Zen.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .sizzy,
            displayName: "Sizzy",
            bundleIdentifiers: ["com.sizzy.Sizzy"],
            exactAppNames: ["Sizzy.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .mullvadBrowser,
            displayName: "Mullvad Browser",
            bundleIdentifiers: ["org.mullvad.mullvadbrowser", "org.mozilla.mullvadbrowser"],
            exactAppNames: ["Mullvad Browser.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .helium,
            displayName: "Helium",
            bundleIdentifiers: ["com.JadenGeller.Helium"],
            exactAppNames: ["Helium.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .vivaldi,
            displayName: "Vivaldi",
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            exactAppNames: ["Vivaldi.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .opera,
            displayName: "Opera",
            bundleIdentifiers: ["com.operasoftware.Opera"],
            exactAppNames: ["Opera.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .chromium,
            displayName: "Chromium",
            bundleIdentifiers: ["org.chromium.Chromium"],
            exactAppNames: ["Chromium.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .torBrowser,
            displayName: "Tor Browser",
            bundleIdentifiers: ["org.torproject.torbrowser"],
            exactAppNames: ["Tor Browser.app"],
            prefixAppNames: ["Tor Browser"]
        ),
        ServerBrowserBuiltInTarget(
            id: .velja,
            displayName: "Velja",
            bundleIdentifiers: ["com.sindresorhus.Velja"],
            exactAppNames: ["Velja.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .sigmaOS,
            displayName: "SigmaOS",
            bundleIdentifiers: ["company.sigmaos.sigmaos.macos"],
            exactAppNames: ["SigmaOS.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .floorp,
            displayName: "Floorp",
            bundleIdentifiers: ["xyz.floorp.browser"],
            exactAppNames: ["Floorp.app"]
        ),
        ServerBrowserBuiltInTarget(
            id: .comet,
            displayName: "Comet",
            bundleIdentifiers: ["ai.perplexity.comet", "com.perplexity.comet"],
            exactAppNames: ["Comet.app", "Perplexity Comet.app"]
        ),
    ]

    static func preferenceMatchesTarget(_ preferenceID: String, target: ServerBrowserTarget) -> Bool {
        if target.stableID == preferenceID {
            return true
        }
        if preferenceID.hasPrefix("bundle:") {
            let bundleID = String(preferenceID.dropFirst("bundle:".count))
            return target.bundleIdentifier == bundleID
        }
        return false
    }

    static func builtInStableIDs() -> Set<String> {
        Set(macOSBuiltInBrowsers.map(\.id.rawValue))
    }

    static func orderedBrowserTargetIDs(customBrowserIDs: [String]) -> [String] {
        macOSBuiltInBrowsers.map(\.id.rawValue) + customBrowserIDs
    }

    static func builtInSlug(forBundleIdentifier bundleIdentifier: String) -> String? {
        for definition in macOSBuiltInBrowsers where definition.bundleIdentifiers.contains(bundleIdentifier) {
            return definition.id.rawValue
        }
        return nil
    }

    @MainActor
    static func targets(
        preferences: AppConfig.ServerDetection,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isApplicationAvailable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> [ServerBrowserTarget] {
        let resolvedBuiltIns = resolveBuiltInTargets(
            workspace: workspace,
            fileManager: fileManager,
            currentBundleIdentifier: currentBundleIdentifier,
            isApplicationAvailable: isApplicationAvailable
        )
        return targets(
            preferences: preferences,
            resolvedBuiltIns: resolvedBuiltIns,
            currentBundleIdentifier: currentBundleIdentifier,
            isApplicationAvailable: isApplicationAvailable
        )
    }

    static func targets(
        preferences: AppConfig.ServerDetection,
        resolvedBuiltIns: [ServerBrowserTarget],
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isApplicationAvailable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> [ServerBrowserTarget] {
        var browserTargets: [ServerBrowserTarget] = [
            ServerBrowserTarget(
                stableID: ServerBrowserTarget.systemDefaultID,
                displayName: "System Default",
                bundleIdentifier: nil,
                appURL: nil,
                isSystemDefault: true,
                isAvailable: true
            ),
        ]

        var seenKeys: Set<String> = []
        for browser in resolvedBuiltIns {
            guard browser.bundleIdentifier != currentBundleIdentifier else {
                continue
            }
            guard let path = browser.appURL?.path, isNormalApplicationPath(path) else {
                continue
            }
            guard isApplicationAvailable(path) else {
                continue
            }

            let dedupeKey = browser.bundleIdentifier.map { "bundle:\($0)" } ?? browser.appURL.map { "path:\($0.path)" } ?? browser.stableID
            guard seenKeys.insert(dedupeKey).inserted else {
                continue
            }

            browserTargets.append(browser)
        }

        var existingTargetIDs = Set(browserTargets.map(\.stableID))
        for browser in preferences.customBrowsers {
            guard !browser.appPath.isEmpty else {
                continue
            }
            guard isApplicationAvailable(browser.appPath), isNormalApplicationPath(browser.appPath) else {
                continue
            }

            let appURL = URL(fileURLWithPath: browser.appPath)
            let inferredBundleID = browser.bundleIdentifier ?? Bundle(url: appURL)?.bundleIdentifier
            if let inferredBundleID, inferredBundleID == currentBundleIdentifier {
                continue
            }
            let dedupeKey = inferredBundleID.map { "bundle:\($0)" } ?? "path:\(browser.appPath)"
            guard seenKeys.insert(dedupeKey).inserted else {
                continue
            }
            guard !existingTargetIDs.contains(browser.id) else {
                continue
            }

            browserTargets.append(
                ServerBrowserTarget(
                    stableID: browser.id,
                    displayName: browser.name,
                    bundleIdentifier: inferredBundleID,
                    appURL: appURL,
                    isSystemDefault: false,
                    isAvailable: true
                )
            )
            existingTargetIDs.insert(browser.id)
        }

        if preferences.preferredBrowserID.hasPrefix("bundle:"),
           !existingTargetIDs.contains(preferences.preferredBrowserID)
        {
            let bundleIdentifier = String(preferences.preferredBrowserID.dropFirst("bundle:".count))
            browserTargets.append(
                ServerBrowserTarget(
                    stableID: preferences.preferredBrowserID,
                    displayName: bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    appURL: nil,
                    isSystemDefault: false,
                    isAvailable: false
                )
            )
        }

        let enabledSet = Set(preferences.enabledBrowserTargetIDs)
        browserTargets = browserTargets.filter { target in
            if target.isSystemDefault {
                return true
            }
            if enabledSet.contains(target.stableID) {
                return true
            }
            guard preferences.preferredBrowserID.hasPrefix("bundle:"),
                  target.stableID == preferences.preferredBrowserID
            else {
                return false
            }
            let bundleID = String(preferences.preferredBrowserID.dropFirst("bundle:".count))
            if let slug = builtInSlug(forBundleIdentifier: bundleID) {
                return enabledSet.contains(slug)
            }
            return false
        }

        return browserTargets
    }

    static func preferredTarget(
        preferences: AppConfig.ServerDetection,
        resolvedBuiltIns: [ServerBrowserTarget],
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isApplicationAvailable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> ServerBrowserTarget {
        let browserTargets = targets(
            preferences: preferences,
            resolvedBuiltIns: resolvedBuiltIns,
            currentBundleIdentifier: currentBundleIdentifier,
            isApplicationAvailable: isApplicationAvailable
        )

        if let preferred = browserTargets.first(where: {
            preferenceMatchesTarget(preferences.preferredBrowserID, target: $0) && $0.isAvailable
        }) {
            return preferred
        }

        return browserTargets[0]
    }

    @MainActor
    static func preferredTarget(
        preferences: AppConfig.ServerDetection,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isApplicationAvailable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }
    ) -> ServerBrowserTarget {
        let resolvedBuiltIns = resolveBuiltInTargets(
            workspace: workspace,
            fileManager: fileManager,
            currentBundleIdentifier: currentBundleIdentifier,
            isApplicationAvailable: isApplicationAvailable
        )
        return preferredTarget(
            preferences: preferences,
            resolvedBuiltIns: resolvedBuiltIns,
            currentBundleIdentifier: currentBundleIdentifier,
            isApplicationAvailable: isApplicationAvailable
        )
    }

    @MainActor
    private static func resolveBuiltInTargets(
        workspace: NSWorkspace,
        fileManager: FileManager,
        currentBundleIdentifier: String?,
        isApplicationAvailable: (String) -> Bool
    ) -> [ServerBrowserTarget] {
        var seenBundleIDs: Set<String> = []
        var results: [ServerBrowserTarget] = []

        for builtIn in macOSBuiltInBrowsers {
            guard
                let appURL = applicationURL(
                    workspace: workspace,
                    fileManager: fileManager,
                    bundleIdentifiers: builtIn.bundleIdentifiers,
                    exactNames: builtIn.exactAppNames,
                    prefixNames: builtIn.prefixAppNames
                )
            else {
                continue
            }

            guard isApplicationAvailable(appURL.path) else {
                continue
            }

            let bundle = Bundle(url: appURL)
            guard let bundleIdentifier = bundle?.bundleIdentifier, !bundleIdentifier.isEmpty else {
                continue
            }

            guard bundleIdentifier != currentBundleIdentifier else {
                continue
            }

            guard seenBundleIDs.insert(bundleIdentifier).inserted else {
                continue
            }

            results.append(
                ServerBrowserTarget(
                    stableID: builtIn.id.rawValue,
                    displayName: builtIn.displayName,
                    bundleIdentifier: bundleIdentifier,
                    appURL: appURL,
                    isSystemDefault: false,
                    isAvailable: true
                )
            )
        }

        return results
    }

    private static func applicationURL(
        workspace: NSWorkspace,
        fileManager: FileManager,
        bundleIdentifiers: [String],
        exactNames: [String],
        prefixNames: [String]
    ) -> URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return applicationURL.standardizedFileURL
            }
        }

        let searchDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]

        for directoryURL in searchDirectories {
            for exactName in exactNames {
                let candidateURL = directoryURL.appendingPathComponent(exactName, isDirectory: true).standardizedFileURL
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
                return prefixMatch.standardizedFileURL
            }
        }

        return nil
    }

    private static func isNormalApplicationPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let normalizedPath = url.path
        guard url.pathExtension == "app" else {
            return false
        }
        guard !normalizedPath.contains(".app/Contents/") else {
            return false
        }

        let homeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
            .path

        return normalizedPath.hasPrefix("/Applications/")
            || normalizedPath.hasPrefix("/System/Applications/")
            || normalizedPath.hasPrefix("/System/Library/CoreServices/")
            || normalizedPath.hasPrefix("\(homeApplicationsPath)/")
    }
}
