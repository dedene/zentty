import AppKit
import Foundation
import os

struct GhosttyThemeResolution {
    let theme: GhosttyResolvedTheme
    let watchedURLs: [URL]
}

private let themeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Theme")

final class GhosttyThemeResolver {
    private struct ParsedConfigStack {
        var config: ParsedConfig
        var watchedURLs: [URL]
    }

    private struct ParsedConfig {
        var themeSpec: String?
        var background: NSColor?
        var foreground: NSColor?
        var cursorColor: NSColor?
        var selectionBackground: NSColor?
        var selectionForeground: NSColor?
        var palette: [Int: NSColor] = [:]
        var backgroundOpacity: CGFloat?
        var backgroundBlurRadius: CGFloat?

        func merged(overrides: ParsedConfig) -> ParsedConfig {
            var result = self
            if let themeSpec = overrides.themeSpec {
                result.themeSpec = themeSpec
            }
            if let background = overrides.background {
                result.background = background
            }
            if let foreground = overrides.foreground {
                result.foreground = foreground
            }
            if let cursorColor = overrides.cursorColor {
                result.cursorColor = cursorColor
            }
            if let selectionBackground = overrides.selectionBackground {
                result.selectionBackground = selectionBackground
            }
            if let selectionForeground = overrides.selectionForeground {
                result.selectionForeground = selectionForeground
            }
            if !overrides.palette.isEmpty {
                result.palette.merge(overrides.palette) { _, override in override }
            }
            if let backgroundOpacity = overrides.backgroundOpacity {
                result.backgroundOpacity = backgroundOpacity
            }
            if let backgroundBlurRadius = overrides.backgroundBlurRadius {
                result.backgroundBlurRadius = backgroundBlurRadius
            }
            return result
        }

        func toResolvedTheme() -> GhosttyResolvedTheme? {
            guard let background, let foreground else {
                return nil
            }

            return GhosttyResolvedTheme(
                background: background,
                foreground: foreground,
                cursorColor: cursorColor ?? foreground,
                selectionBackground: selectionBackground,
                selectionForeground: selectionForeground,
                palette: palette,
                backgroundOpacity: backgroundOpacity,
                backgroundBlurRadius: backgroundBlurRadius
            )
        }
    }

    private let legacyConfigURL: URL
    private let additionalThemeDirectories: [URL]
    private let configEnvironment: GhosttyConfigEnvironment?

    var configURL: URL {
        configEnvironment?.resolvedStack()?.primaryWatchURL ?? legacyConfigURL
    }

    init(
        configURL: URL,
        additionalThemeDirectories: [URL] = GhosttyThemeResolver.defaultThemeDirectories()
    ) {
        self.legacyConfigURL = configURL
        self.additionalThemeDirectories = additionalThemeDirectories
        self.configEnvironment = nil
    }

    init(
        configEnvironment: GhosttyConfigEnvironment = GhosttyConfigEnvironment(),
        additionalThemeDirectories: [URL] = GhosttyThemeResolver.defaultThemeDirectories()
    ) {
        self.legacyConfigURL = configEnvironment.preferredCreateTargetURL
        self.additionalThemeDirectories = additionalThemeDirectories
        self.configEnvironment = configEnvironment
    }

    func currentThemeName(for appearance: NSAppearance?) -> String? {
        parsedConfigStack().config.themeSpec.flatMap {
            GhosttyThemeLibrary.canonicalThemeName(
                for: resolveThemeName(from: $0, appearance: appearance)
            )
        }
    }

    func currentBackgroundOpacity() -> CGFloat? {
        parsedConfigStack().config.backgroundOpacity
    }

    func resolve(for appearance: NSAppearance?) -> GhosttyThemeResolution? {
        let parsedStack = parsedConfigStack()
        let resolvedThemeName = parsedStack.config.themeSpec.flatMap {
            GhosttyThemeLibrary.canonicalThemeName(
                for: resolveThemeName(from: $0, appearance: appearance)
            )
        }
        let themeURL = resolvedThemeName.flatMap(resolveThemeURL(named:))
        let baseConfig = themeURL.flatMap(parseConfig(at:))
            ?? resolvedThemeName.flatMap(builtInParsedConfig(named:))
            ?? ParsedConfig()
        let merged = baseConfig.merged(overrides: parsedStack.config)

        guard let theme = merged.toResolvedTheme() else {
            return nil
        }

        var watchedURLs = parsedStack.watchedURLs
        if let themeURL {
            watchedURLs.append(themeURL)
        }

        return GhosttyThemeResolution(
            theme: theme,
            watchedURLs: watchedURLs
        )
    }

    static func defaultThemeDirectories() -> [URL] {
        GhosttyThemeLibrary.resolverThemeDirectories()
    }

    private func resolveThemeName(from themeSpec: String, appearance: NSAppearance?) -> String {
        let components = themeSpec
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let isDarkMode = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for component in components {
            if component.hasPrefix("light:"), !isDarkMode {
                return String(component.dropFirst("light:".count))
            }
            if component.hasPrefix("dark:"), isDarkMode {
                return String(component.dropFirst("dark:".count))
            }
        }

        if let first = components.first {
            if first.hasPrefix("light:") {
                return String(first.dropFirst("light:".count))
            }
            if first.hasPrefix("dark:") {
                return String(first.dropFirst("dark:".count))
            }
            return first
        }

        return themeSpec
    }

    private func resolveThemeURL(named themeName: String) -> URL? {
        GhosttyThemeLibrary.resolveThemeFileURL(
            named: themeName,
            themeDirectories: additionalThemeDirectories
        )
    }

    private func parseConfig(at url: URL) -> ParsedConfig {
        var visitedPaths: Set<String> = []
        var watchedURLs = [url]
        return parseConfig(at: url, visitedPaths: &visitedPaths, watchedURLs: &watchedURLs)
    }

    private func parseConfig(
        at url: URL,
        visitedPaths: inout Set<String>,
        watchedURLs: inout [URL]
    ) -> ParsedConfig {
        let normalizedPath = url.standardizedFileURL.path
        guard visitedPaths.insert(normalizedPath).inserted else {
            return ParsedConfig()
        }

        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            themeLogger.error("Failed to read theme config at \(url.path): \(error.localizedDescription)")
            return ParsedConfig()
        }

        return parseConfig(
            contents: contents,
            relativeTo: url,
            visitedPaths: &visitedPaths,
            watchedURLs: &watchedURLs
        )
    }

    private func parseConfig(contents: String) -> ParsedConfig {
        var visitedPaths: Set<String> = []
        var watchedURLs: [URL] = []
        return parseConfig(
            contents: contents,
            relativeTo: nil,
            visitedPaths: &visitedPaths,
            watchedURLs: &watchedURLs
        )
    }

    private func parseConfig(
        contents: String,
        relativeTo sourceURL: URL?,
        visitedPaths: inout Set<String>,
        watchedURLs: inout [URL]
    ) -> ParsedConfig {
        var parsed = ParsedConfig()
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

            if key == "config-file",
               let sourceURL,
               let includedURL = resolveIncludedConfigURL(rawValue: value, relativeTo: sourceURL) {
                watchedURLs.append(includedURL)
                parsed = parsed.merged(
                    overrides: parseConfig(
                        at: includedURL,
                        visitedPaths: &visitedPaths,
                        watchedURLs: &watchedURLs
                    )
                )
                continue
            }

            apply(value: value, forKey: key, to: &parsed)
        }

        return parsed
    }

    private func parsedConfigStack() -> ParsedConfigStack {
        guard let configEnvironment, let stack = configEnvironment.resolvedStack() else {
            return ParsedConfigStack(
                config: parseConfig(at: configURL),
                watchedURLs: [configURL]
            )
        }

        var visitedPaths: Set<String> = []
        var watchedURLs = stack.loadFiles
        var merged = ParsedConfig()

        for loadFile in stack.loadFiles {
            merged = merged.merged(
                overrides: parseConfig(
                    at: loadFile,
                    visitedPaths: &visitedPaths,
                    watchedURLs: &watchedURLs
                )
            )
        }

        if let localOverrideContents = stack.localOverrideContents {
            merged = merged.merged(overrides: parseConfig(contents: localOverrideContents))
        }

        return ParsedConfigStack(
            config: merged,
            watchedURLs: uniqueURLs(watchedURLs)
        )
    }

    private func resolveIncludedConfigURL(rawValue: String, relativeTo sourceURL: URL) -> URL? {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        if value.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }

        return sourceURL.deletingLastPathComponent().appendingPathComponent(value)
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seenPaths: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let normalizedPath = url.standardizedFileURL.path
            if seenPaths.insert(normalizedPath).inserted {
                result.append(url)
            }
        }

        return result
    }

    private func builtInParsedConfig(named name: String) -> ParsedConfig? {
        guard let builtInTheme = GhosttyThemeLibrary.builtInResolvedTheme(named: name) else {
            return nil
        }

        return ParsedConfig(
            themeSpec: GhosttyThemeLibrary.canonicalThemeName(for: name),
            background: builtInTheme.background,
            foreground: builtInTheme.foreground,
            cursorColor: builtInTheme.cursorColor,
            selectionBackground: builtInTheme.selectionBackground,
            selectionForeground: builtInTheme.selectionForeground,
            palette: builtInTheme.palette,
            backgroundOpacity: builtInTheme.backgroundOpacity,
            backgroundBlurRadius: builtInTheme.backgroundBlurRadius
        )
    }

    private func apply(value rawValue: String, forKey key: String, to parsed: inout ParsedConfig) {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        switch key {
        case "theme":
            parsed.themeSpec = value
        case "background":
            parsed.background = NSColor(hexString: value)
        case "foreground":
            parsed.foreground = NSColor(hexString: value)
        case "cursor-color":
            parsed.cursorColor = NSColor(hexString: value)
        case "selection-background":
            parsed.selectionBackground = NSColor(hexString: value)
        case "selection-foreground":
            parsed.selectionForeground = NSColor(hexString: value)
        case "background-opacity":
            parsed.backgroundOpacity = CGFloat(Double(value) ?? 0)
        case "background-blur-radius":
            parsed.backgroundBlurRadius = CGFloat(Double(value) ?? 0)
        case "palette":
            let components = value.split(separator: "=").map(String.init)
            guard components.count == 2,
                  let index = Int(components[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let color = NSColor(hexString: components[1])
            else {
                return
            }
            parsed.palette[index] = color
        default:
            return
        }
    }
}

final class GhosttyThemeWatcher {
    private final class WatchHandle {
        let url: URL
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32

        init(url: URL, source: DispatchSourceFileSystemObject, descriptor: Int32) {
            self.url = url
            self.source = source
            self.descriptor = descriptor
        }
    }

    var onChange: (@MainActor @Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.zentty.ghostty-theme-watcher")
    private var handles: [WatchHandle] = []
    private var watchedPaths: Set<String> = []
    private var debounceWorkItem: DispatchWorkItem?

    func watch(urls: [URL]) {
        let normalizedURLs = Set(urls.map { normalizedWatchURL(for: $0).path })

        stop()
        watchedPaths = normalizedURLs

        for path in normalizedURLs.sorted() {
            let url = URL(fileURLWithPath: path)
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleChangeNotification()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            handles.append(WatchHandle(url: url, source: source, descriptor: descriptor))
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchedPaths = []
        handles.forEach { $0.source.cancel() }
        handles.removeAll()
    }

    deinit {
        stop()
    }

    private func normalizedWatchURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private func scheduleChangeNotification() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            let callback = self?.onChange
            guard let callback else { return }
            Task { @MainActor in
                callback()
            }
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
