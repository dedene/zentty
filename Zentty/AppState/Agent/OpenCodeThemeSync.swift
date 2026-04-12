import AppKit
import Foundation
import os

enum OpenCodeThemeSync {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "OpenCodeThemeSync")

    private static let tuiSchemaURL = "https://opencode.ai/tui.json"
    private static let tuiThemeSchemaURL = "https://opencode.ai/theme.json"
    static let syncedThemeID = "zentty-synced"
    static let syncedThemeFileName = "zentty-synced.json"

    static func apply(
        toOverlayConfigDirectory overlayConfigDirectoryURL: URL,
        appConfig: AppConfig,
        configEnvironment: GhosttyConfigEnvironment,
        effectiveAppearance: NSAppearance,
        themeDirectories: [URL] = GhosttyThemeLibrary.resolverThemeDirectories(),
        fileManager: FileManager = .default
    ) throws {
        guard appConfig.appearance.syncOpenCodeThemeWithTerminal else {
            return
        }

        let tuiURL = overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        if fileManager.fileExists(atPath: tuiURL.path) {
            guard loadTUIConfig(from: tuiURL) != nil else {
                logger.error("Skipping OpenCode theme sync because tui.json is not valid JSON: \(tuiURL.path, privacy: .public)")
                return
            }
        }

        let didWriteSyncedTheme = try writeSyncedThemeFile(
            toOverlayConfigDirectory: overlayConfigDirectoryURL,
            configEnvironment: configEnvironment,
            effectiveAppearance: effectiveAppearance,
            themeDirectories: themeDirectories,
            fileManager: fileManager
        )
        guard didWriteSyncedTheme || fileManager.fileExists(atPath: syncedThemeFileURL(in: overlayConfigDirectoryURL).path) else {
            try writeTUITheme(
                themeID: "system",
                to: tuiURL,
                fileManager: fileManager
            )
            return
        }

        try writeTUITheme(
            themeID: syncedThemeID,
            to: tuiURL,
            fileManager: fileManager
        )
    }

    static func syncedThemeFileURL(in overlayConfigDirectoryURL: URL) -> URL {
        overlayConfigDirectoryURL
            .appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent(syncedThemeFileName, isDirectory: false)
    }

    static func isSyncedThemeSelected(in overlayConfigDirectoryURL: URL) -> Bool {
        let tuiURL = overlayConfigDirectoryURL.appendingPathComponent("tui.json", isDirectory: false)
        guard let jsonObject = loadTUIConfig(from: tuiURL) else {
            return false
        }

        return jsonObject["theme"] as? String == syncedThemeID
    }

    @discardableResult
    static func writeSyncedThemeFile(
        toOverlayConfigDirectory overlayConfigDirectoryURL: URL,
        configEnvironment: GhosttyConfigEnvironment,
        effectiveAppearance: NSAppearance,
        themeDirectories: [URL] = GhosttyThemeLibrary.resolverThemeDirectories(),
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let themeData = try makeSyncedThemeData(
            configEnvironment: configEnvironment,
            effectiveAppearance: effectiveAppearance,
            themeDirectories: themeDirectories
        ) else {
            return false
        }

        let themesDirectoryURL = overlayConfigDirectoryURL.appendingPathComponent("themes", isDirectory: true)
        let themeURL = syncedThemeFileURL(in: overlayConfigDirectoryURL)
        if let existingData = try? Data(contentsOf: themeURL), existingData == themeData {
            return false
        }

        try fileManager.createDirectory(at: themesDirectoryURL, withIntermediateDirectories: true)
        try themeData.write(to: themeURL, options: .atomic)
        return true
    }

    private static func loadTUIConfig(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return jsonObject
    }

    private static func writeTUITheme(
        themeID: String,
        to tuiURL: URL,
        fileManager: FileManager
    ) throws {
        var jsonObject = loadTUIConfig(from: tuiURL) ?? [:]
        jsonObject["$schema"] = tuiSchemaURL
        jsonObject["theme"] = themeID

        if !fileManager.fileExists(atPath: tuiURL.deletingLastPathComponent().path) {
            try fileManager.createDirectory(at: tuiURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: tuiURL, options: .atomic)
    }

    private static func makeSyncedThemeData(
        configEnvironment: GhosttyConfigEnvironment,
        effectiveAppearance: NSAppearance,
        themeDirectories: [URL]
    ) throws -> Data? {
        let resolver = GhosttyThemeResolver(
            configEnvironment: configEnvironment,
            additionalThemeDirectories: themeDirectories
        )
        let darkAppearance = NSAppearance(named: .darkAqua) ?? effectiveAppearance
        let lightAppearance = NSAppearance(named: .aqua) ?? effectiveAppearance
        let darkTheme = resolver.resolve(for: darkAppearance)?.theme
            ?? resolver.resolve(for: effectiveAppearance)?.theme
        let lightTheme = resolver.resolve(for: lightAppearance)?.theme
            ?? darkTheme

        guard let darkTheme, let lightTheme else {
            return nil
        }

        return try syncedThemeData(
            darkTheme: darkTheme,
            lightTheme: lightTheme
        )
    }

    private static func syncedThemeData(
        darkTheme: GhosttyResolvedTheme,
        lightTheme: GhosttyResolvedTheme
    ) throws -> Data {
        let darkTokens = tuiThemeTokens(from: darkTheme)
        let lightTokens = tuiThemeTokens(from: lightTheme)
        let tokenKeys = Array(Set(darkTokens.keys).union(lightTokens.keys)).sorted()

        var theme: [String: Any] = [:]
        for key in tokenKeys {
            guard let dark = darkTokens[key], let light = lightTokens[key] else {
                continue
            }
            theme[key] = [
                "dark": dark,
                "light": light,
            ]
        }
        theme["thinkingOpacity"] = 0.6

        let jsonObject: [String: Any] = [
            "$schema": tuiThemeSchemaURL,
            "theme": theme,
        ]

        return try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
    }

    private static func tuiThemeTokens(from theme: GhosttyResolvedTheme) -> [String: String] {
        let background = theme.background
        let foreground = theme.foreground
        let isDark = background.isDarkThemeColor

        let primary = paletteColor(
            theme.palette,
            primary: [12, 4],
            fallbackColors: [theme.cursorColor, theme.foreground],
            fallbackHexes: []
        )
        let secondary = paletteColor(
            theme.palette,
            primary: [13, 5],
            fallbackColors: [],
            fallbackHexes: [primary]
        )
        let accent = paletteColor(
            theme.palette,
            primary: [11, 3, 13, 5],
            fallbackColors: [],
            fallbackHexes: [secondary]
        )
        let success = paletteColor(
            theme.palette,
            primary: [10, 2],
            fallbackColors: [],
            fallbackHexes: [primary]
        )
        let warning = paletteColor(
            theme.palette,
            primary: [11, 3],
            fallbackColors: [],
            fallbackHexes: [accent]
        )
        let error = paletteColor(
            theme.palette,
            primary: [9, 1],
            fallbackColors: [],
            fallbackHexes: [accent]
        )
        let info = paletteColor(
            theme.palette,
            primary: [14, 6, 12, 4],
            fallbackColors: [],
            fallbackHexes: [primary]
        )
        let text = foreground.themeHexString
        let textMuted = (
            theme.palette[8]
                ?? foreground.mixed(towards: background, amount: isDark ? 0.38 : 0.34)
        ).themeHexString
        let backgroundPanel = background.mixed(towards: foreground, amount: isDark ? 0.05 : 0.03).themeHexString
        let backgroundElement = background.mixed(towards: foreground, amount: isDark ? 0.09 : 0.06).themeHexString
        let border = background.mixed(towards: foreground, amount: isDark ? 0.24 : 0.18).themeHexString
        let borderActive = background.mixed(towards: foreground, amount: isDark ? 0.34 : 0.26).themeHexString
        let borderSubtle = background.mixed(towards: foreground, amount: isDark ? 0.14 : 0.10).themeHexString
        let diffAddedBg = background.mixed(towards: NSColor(hex: success), amount: isDark ? 0.18 : 0.14).themeHexString
        let diffRemovedBg = background.mixed(towards: NSColor(hex: error), amount: isDark ? 0.18 : 0.14).themeHexString
        let diffAddedLineNumberBg = background.mixed(towards: NSColor(hex: success), amount: isDark ? 0.10 : 0.08).themeHexString
        let diffRemovedLineNumberBg = background.mixed(towards: NSColor(hex: error), amount: isDark ? 0.10 : 0.08).themeHexString

        return [
            "primary": primary,
            "secondary": secondary,
            "accent": accent,
            "success": success,
            "warning": warning,
            "error": error,
            "info": info,
            "text": text,
            "textMuted": textMuted,
            "background": background.themeHexString,
            "backgroundPanel": backgroundPanel,
            "backgroundElement": backgroundElement,
            "backgroundMenu": backgroundElement,
            "border": border,
            "borderActive": borderActive,
            "borderSubtle": borderSubtle,
            "diffAdded": success,
            "diffRemoved": error,
            "diffContext": textMuted,
            "diffHunkHeader": info,
            "diffHighlightAdded": success,
            "diffHighlightRemoved": error,
            "diffAddedBg": diffAddedBg,
            "diffRemovedBg": diffRemovedBg,
            "diffContextBg": backgroundPanel,
            "diffLineNumber": textMuted,
            "diffAddedLineNumberBg": diffAddedLineNumberBg,
            "diffRemovedLineNumberBg": diffRemovedLineNumberBg,
            "markdownText": text,
            "markdownHeading": secondary,
            "markdownLink": primary,
            "markdownLinkText": info,
            "markdownCode": success,
            "markdownBlockQuote": warning,
            "markdownEmph": warning,
            "markdownStrong": accent,
            "markdownHorizontalRule": textMuted,
            "markdownListItem": primary,
            "markdownListEnumeration": info,
            "markdownImage": primary,
            "markdownImageText": info,
            "markdownCodeBlock": text,
            "syntaxComment": textMuted,
            "syntaxKeyword": secondary,
            "syntaxFunction": primary,
            "syntaxVariable": error,
            "syntaxString": success,
            "syntaxNumber": accent,
            "syntaxType": warning,
            "syntaxOperator": info,
            "syntaxPunctuation": text,
        ]
    }

    private static func paletteColor(
        _ palette: [Int: NSColor],
        primary indexes: [Int],
        fallbackColors: [NSColor],
        fallbackHexes: [String]
    ) -> String {
        for index in indexes {
            if let color = palette[index] {
                return color.themeHexString
            }
        }

        for color in fallbackColors {
            return color.themeHexString
        }

        for hex in fallbackHexes {
            return hex
        }

        return "#000000"
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(sanitized, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
