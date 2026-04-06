import AppKit
import Foundation
import os

struct GhosttyThemeResolution {
    let theme: GhosttyResolvedTheme
    let watchedURLs: [URL]
}

private let themeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Theme")

final class GhosttyThemeResolver {
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

    let configURL: URL
    private let additionalThemeDirectories: [URL]

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config"),
        additionalThemeDirectories: [URL] = GhosttyThemeResolver.defaultThemeDirectories()
    ) {
        self.configURL = configURL
        self.additionalThemeDirectories = additionalThemeDirectories
    }

    func currentThemeName(for appearance: NSAppearance?) -> String? {
        let userConfig = parseConfig(at: configURL)
        return userConfig.themeSpec.flatMap {
            resolveThemeName(from: $0, appearance: appearance)
        }
    }

    func currentBackgroundOpacity() -> CGFloat? {
        parseConfig(at: configURL).backgroundOpacity
    }

    func resolve(for appearance: NSAppearance?) -> GhosttyThemeResolution? {
        let userConfig = parseConfig(at: configURL)
        let resolvedThemeName = userConfig.themeSpec.flatMap {
            resolveThemeName(from: $0, appearance: appearance)
        }
        let themeURL = resolvedThemeName.flatMap(resolveThemeURL(named:))
        let baseConfig = themeURL.flatMap(parseConfig(at:)) ?? ParsedConfig()
        let merged = baseConfig.merged(overrides: userConfig)

        guard let theme = merged.toResolvedTheme() else {
            return nil
        }

        var watchedURLs: [URL] = [configURL]
        if let themeURL {
            watchedURLs.append(themeURL)
        }

        return GhosttyThemeResolution(
            theme: theme,
            watchedURLs: watchedURLs
        )
    }

    static func defaultThemeDirectories() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var urls = [
            home.appendingPathComponent(".config/ghostty/themes"),
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
            home.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty/themes"),
        ]

        if let envPath = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] {
            urls.append(URL(fileURLWithPath: envPath).appendingPathComponent("themes"))
        }

        return urls
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
        let trimmed = themeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        let candidateURLs: [URL]
        if trimmed.hasPrefix("/") {
            candidateURLs = [URL(fileURLWithPath: trimmed)]
        } else if trimmed.hasPrefix("~") {
            candidateURLs = [URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)]
        } else {
            candidateURLs = additionalThemeDirectories.flatMap { directory in
                [
                    directory.appendingPathComponent(trimmed),
                    directory.appendingPathComponent(trimmed).appendingPathExtension("conf"),
                ]
            }
        }

        return candidateURLs.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func parseConfig(at url: URL) -> ParsedConfig {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            themeLogger.error("Failed to read theme config at \(url.path): \(error.localizedDescription)")
            return ParsedConfig()
        }

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
            apply(value: value, forKey: key, to: &parsed)
        }

        return parsed
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
