import AppKit

@MainActor
protocol ServerOpening: AnyObject {
    func availableBrowsers(config: AppConfig.ServerDetection) -> [ServerBrowserTarget]
    func preferredBrowser(config: AppConfig.ServerDetection) -> ServerBrowserTarget
    func icon(for browser: ServerBrowserTarget) -> NSImage?
    @discardableResult
    func open(server: DetectedServer, browserID: String?, config: AppConfig.ServerDetection) -> Bool
}

@MainActor
final class ServerOpenService: ServerOpening {
    private enum CachedIcon {
        case image(NSImage)
        case missing
    }

    private let workspace: NSWorkspace
    private var iconCache: [String: CachedIcon] = [:]

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func availableBrowsers(config: AppConfig.ServerDetection) -> [ServerBrowserTarget] {
        ServerBrowserCatalog.targets(
            preferences: config,
            workspace: workspace
        )
    }

    func preferredBrowser(config: AppConfig.ServerDetection) -> ServerBrowserTarget {
        ServerBrowserCatalog.preferredTarget(
            preferences: config,
            workspace: workspace
        )
    }

    func icon(for browser: ServerBrowserTarget) -> NSImage? {
        if browser.isSystemDefault {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: browser.displayName)
        }

        let cacheKey = browser.appURL?.path ?? browser.stableID
        if let cached = iconCache[cacheKey] {
            switch cached {
            case .image(let image):
                return image
            case .missing:
                return nil
            }
        }

        guard let appURL = browser.appURL else {
            iconCache[cacheKey] = .missing
            return nil
        }

        let icon = workspace.icon(forFile: appURL.path)
        icon.size = NSSize(width: 18, height: 18)
        iconCache[cacheKey] = .image(icon)
        return icon
    }

    @discardableResult
    func open(server: DetectedServer, browserID: String?, config: AppConfig.ServerDetection) -> Bool {
        let browsers = availableBrowsers(config: config)
        let target = browserTarget(browserID: browserID, browsers: browsers, config: config)

        if target.isSystemDefault {
            return workspace.open(server.url)
        }

        guard target.isAvailable else {
            return workspace.open(server.url)
        }

        if let appURL = target.appURL {
            return runOpen(arguments: ["-a", appURL.path, server.url.absoluteString])
        }

        if let bundleIdentifier = target.bundleIdentifier {
            return runOpen(arguments: ["-b", bundleIdentifier, server.url.absoluteString])
        }

        return workspace.open(server.url)
    }

    private func browserTarget(
        browserID: String?,
        browsers: [ServerBrowserTarget],
        config: AppConfig.ServerDetection
    ) -> ServerBrowserTarget {
        if let browserID,
           let browser = browsers.first(where: {
               ServerBrowserCatalog.preferenceMatchesTarget(normalizedBrowserID(browserID), target: $0) && $0.isAvailable
           })
        {
            return browser
        }

        if let browser = browsers.first(where: {
            ServerBrowserCatalog.preferenceMatchesTarget(config.preferredBrowserID, target: $0) && $0.isAvailable
        }) {
            return browser
        }

        return browsers[0]
    }

    private func normalizedBrowserID(_ browserID: String) -> String {
        if browserID == ServerBrowserTarget.systemDefaultID
            || browserID.hasPrefix("bundle:")
            || browserID.hasPrefix("custom:")
        {
            return browserID
        }

        if ServerBrowserBuiltInID(rawValue: browserID) != nil {
            return browserID
        }

        return "bundle:\(browserID)"
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
