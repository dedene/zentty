import AppKit

struct ThemePreview: Equatable {
    let name: String
    let displayName: String
    let background: NSColor
    let foreground: NSColor
    let palette: [NSColor]

    static func == (lhs: ThemePreview, rhs: ThemePreview) -> Bool {
        lhs.name == rhs.name
            && lhs.displayName == rhs.displayName
            && lhs.background.themeToken == rhs.background.themeToken
            && lhs.foreground.themeToken == rhs.foreground.themeToken
            && lhs.palette.map(\.themeToken) == rhs.palette.map(\.themeToken)
    }
}

enum GhosttyThemeLibrary {
    static let fallbackThemeName = "Zentty-Default"
    static let fallbackDisplayName = "Zentty Default Theme"
    static let fallbackPersistedThemeName = "GitHub-Dark-Personal"

    private static let fallbackThemeAliases: Set<String> = [
        "Zentty-Default",
        "GitHub-Dark-Personal",
        "Github-Dark-Personal",
    ]

    private static let fallbackPalette: [Int: NSColor] = [
        0: NSColor(hexString: "#7A828E")!,
        1: NSColor(hexString: "#FF9492")!,
        2: NSColor(hexString: "#26CD4D")!,
        3: NSColor(hexString: "#FFE073")!,
        4: NSColor(hexString: "#71B7FF")!,
        5: NSColor(hexString: "#CB9EFF")!,
        6: NSColor(hexString: "#24EAF7")!,
        7: NSColor(hexString: "#D9DEE3")!,
        8: NSColor(hexString: "#9EA7B3")!,
        9: NSColor(hexString: "#FFB1AF")!,
        10: NSColor(hexString: "#4AE168")!,
        11: NSColor(hexString: "#FFE073")!,
        12: NSColor(hexString: "#91CBFF")!,
        13: NSColor(hexString: "#DBB7FF")!,
        14: NSColor(hexString: "#56D4DD")!,
        15: NSColor(hexString: "#FFFFFF")!,
    ]

    static func resolverThemeDirectories(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates = [
            homeDirectoryURL.appendingPathComponent(".config/ghostty/themes", isDirectory: true),
        ]

        if let envPath = environment["GHOSTTY_RESOURCES_DIR"], !envPath.isEmpty {
            candidates.append(
                URL(fileURLWithPath: envPath, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
        }

        candidates.append(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        candidates.append(
            homeDirectoryURL.appendingPathComponent(
                "Applications/Ghostty.app/Contents/Resources/ghostty/themes",
                isDirectory: true
            )
        )

        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appendingPathComponent("ghostty/themes", isDirectory: true))
        }

        return uniqueURLs(candidates)
    }

    static func catalogThemeDirectories(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        resolverThemeDirectories(
            homeDirectoryURL: homeDirectoryURL,
            bundleResourceURL: bundleResourceURL,
            environment: environment
        ).reversed()
    }

    static func builtInResolvedTheme(named name: String) -> GhosttyResolvedTheme? {
        guard canonicalThemeName(for: name) == fallbackThemeName else {
            return nil
        }

        return GhosttyResolvedTheme(
            background: NSColor(hexString: "#0A0C10")!,
            foreground: NSColor(hexString: "#F0F3F6")!,
            cursorColor: NSColor(hexString: "#71B7FF")!,
            selectionBackground: NSColor(hexString: "#F0F3F6")!,
            selectionForeground: NSColor(hexString: "#0A0C10")!,
            palette: fallbackPalette,
            backgroundOpacity: nil,
            backgroundBlurRadius: nil
        )
    }

    static func builtInThemePreview() -> ThemePreview {
        let resolvedTheme = builtInResolvedTheme(named: fallbackThemeName)!
        let palette = (0..<16).compactMap { resolvedTheme.palette[$0] }
        return ThemePreview(
            name: fallbackThemeName,
            displayName: fallbackDisplayName,
            background: resolvedTheme.background,
            foreground: resolvedTheme.foreground,
            palette: palette
        )
    }

    static func canonicalThemeName(for name: String) -> String {
        if fallbackThemeAliases.contains(name) {
            return fallbackThemeName
        }

        return name
    }

    static func persistedThemeName(for name: String) -> String {
        canonicalThemeName(for: name) == fallbackThemeName ? fallbackPersistedThemeName : name
    }

    static func builtInThemeConfigContents(named name: String) -> String? {
        guard let resolvedTheme = builtInResolvedTheme(named: name) else {
            return nil
        }

        var lines = [
            "background = \(resolvedTheme.background.themeHexString)",
            "foreground = \(resolvedTheme.foreground.themeHexString)",
            "cursor-color = \(resolvedTheme.cursorColor.themeHexString)",
        ]

        if let selectionBackground = resolvedTheme.selectionBackground {
            lines.append("selection-background = \(selectionBackground.themeHexString)")
        }
        if let selectionForeground = resolvedTheme.selectionForeground {
            lines.append("selection-foreground = \(selectionForeground.themeHexString)")
        }

        for index in resolvedTheme.palette.keys.sorted() {
            guard let color = resolvedTheme.palette[index] else {
                continue
            }
            lines.append("palette = \(index)=\(color.themeHexString)")
        }

        return lines.joined(separator: "\n")
    }

    static func resolveThemeFileURL(
        named themeName: String,
        themeDirectories: [URL] = resolverThemeDirectories()
    ) -> URL? {
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
            candidateURLs = themeDirectories.flatMap { directory in
                fileLookupNames(for: trimmed).flatMap { lookupName in
                    [
                        directory.appendingPathComponent(lookupName),
                        directory.appendingPathComponent(lookupName).appendingPathExtension("conf"),
                    ]
                }
            }
        }

        return candidateURLs.first { fileManager.fileExists(atPath: $0.path) }
    }

    static func fileLookupNames(for name: String) -> [String] {
        let canonicalName = canonicalThemeName(for: name)
        if canonicalName == fallbackThemeName {
            return [fallbackPersistedThemeName, "Github-Dark-Personal", fallbackThemeName]
        }

        return [name]
    }

    static func displayName(for name: String) -> String {
        canonicalThemeName(for: name) == fallbackThemeName ? fallbackDisplayName : name
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
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
}

@MainActor
protocol ThemeCatalogProviding {
    func loadThemes() async -> [ThemePreview]
}

final class ThemeCatalogService: ThemeCatalogProviding {
    private let themeDirectories: [URL]

    init(themeDirectories: [URL] = GhosttyThemeLibrary.catalogThemeDirectories()) {
        self.themeDirectories = themeDirectories
    }

    func loadThemes() async -> [ThemePreview] {
        let themeDirectories = self.themeDirectories
        return await Task.detached(priority: .userInitiated) {
            Self.discoverThemes(in: themeDirectories)
        }.value
    }

    func loadThemesSynchronouslyForTesting() -> [ThemePreview] {
        Self.discoverThemes(in: themeDirectories)
    }

    nonisolated private static func discoverThemes(in directories: [URL]) -> [ThemePreview] {
        let fileManager = FileManager.default
        var themesByName: [String: ThemePreview] = [:]

        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }

            for file in files {
                let path = directory.appendingPathComponent(file).path
                guard let theme = parseThemeFile(atPath: path, name: file) else {
                    continue
                }
                themesByName[theme.name] = theme
            }
        }

        let fallbackTheme = GhosttyThemeLibrary.builtInThemePreview()
        if themesByName[fallbackTheme.name] == nil {
            themesByName[fallbackTheme.name] = fallbackTheme
        }

        return themesByName.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    nonisolated private static func parseThemeFile(atPath path: String, name: String) -> ThemePreview? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var background: NSColor?
        var foreground: NSColor?
        var palette: [Int: NSColor] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else {
                continue
            }

            if trimmed.hasPrefix("background"), !trimmed.hasPrefix("background-") {
                background = extractColor(from: trimmed)
            } else if trimmed.hasPrefix("foreground"), !trimmed.hasPrefix("foreground-") {
                foreground = extractColor(from: trimmed)
            } else if trimmed.hasPrefix("palette") {
                parsePaletteEntry(trimmed, into: &palette)
            }
        }

        guard let background, let foreground else {
            return nil
        }

        let canonicalName = GhosttyThemeLibrary.canonicalThemeName(for: name)
        let sortedPalette = (0..<16).compactMap { palette[$0] }
        return ThemePreview(
            name: canonicalName,
            displayName: GhosttyThemeLibrary.displayName(for: canonicalName),
            background: background,
            foreground: foreground,
            palette: sortedPalette
        )
    }

    nonisolated private static func extractColor(from line: String) -> NSColor? {
        guard let equalIndex = line.firstIndex(of: "=") else {
            return nil
        }
        let value = line[line.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
        return NSColor(hexString: value)
    }

    nonisolated private static func parsePaletteEntry(_ line: String, into palette: inout [Int: NSColor]) {
        guard let equalIndex = line.firstIndex(of: "=") else {
            return
        }
        let afterPalette = line[line.index(after: equalIndex)...].trimmingCharacters(in: .whitespaces)
        guard let secondEqual = afterPalette.firstIndex(of: "=") else {
            return
        }
        guard let index = Int(afterPalette[..<secondEqual].trimmingCharacters(in: .whitespaces)) else {
            return
        }
        guard index >= 0, index < 16 else {
            return
        }
        let hexValue = afterPalette[afterPalette.index(after: secondEqual)...].trimmingCharacters(in: .whitespaces)
        guard let color = NSColor(hexString: hexValue) else {
            return
        }
        palette[index] = color
    }
}
