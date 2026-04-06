import AppKit

struct ThemePreview: Equatable {
    let name: String
    let background: NSColor
    let foreground: NSColor
    let palette: [NSColor]

    static func == (lhs: ThemePreview, rhs: ThemePreview) -> Bool {
        lhs.name == rhs.name
            && lhs.background.themeToken == rhs.background.themeToken
            && lhs.foreground.themeToken == rhs.foreground.themeToken
            && lhs.palette.map(\.themeToken) == rhs.palette.map(\.themeToken)
    }
}

@MainActor
protocol ThemeCatalogProviding {
    func loadThemes() async -> [ThemePreview]
}

final class ThemeCatalogService: ThemeCatalogProviding {
    private let themeDirectories: [URL]

    init(themeDirectories: [URL] = GhosttyThemeResolver.defaultThemeDirectories()) {
        self.themeDirectories = themeDirectories
    }

    func loadThemes() async -> [ThemePreview] {
        let directories = themeDirectories
        return await Task.detached {
            Self.discoverThemes(in: directories)
        }.value
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

        return themesByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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

        let sortedPalette = (0..<16).compactMap { palette[$0] }
        return ThemePreview(name: name, background: background, foreground: foreground, palette: sortedPalette)
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
