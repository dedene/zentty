import AppKit
import Foundation
import os

@MainActor
final class ProjectIconResolver {
    static let shared = ProjectIconResolver()

    enum CachedResolution {
        case image(NSImage, resolvedAt: Date)
        case missing(checkedAt: Date)
    }

    enum CachedLookup {
        case hit(NSImage)
        case miss
        case unknown
    }

    static let defaultRenderSize = NSSize(width: 18, height: 18)

    private static let bundleExtensions: Set<String> = [
        "app", "xcodeproj", "xcworkspace", "framework", "bundle", "playground",
    ]

    private static let faviconCandidates: [String] = [
        "favicon.svg",
        "favicon.ico",
        "favicon.png",
        "public/favicon.svg",
        "public/favicon.ico",
        "public/favicon.png",
        "public/apple-touch-icon.png",
        "apple-touch-icon.png",
        "images/favicon/favicon.svg",
        "images/favicon/apple-touch-icon.png",
        "images/favicon/favicon-32x32.png",
        "images/favicon/favicon.ico",
        "images/favicon.svg",
        "images/favicon.ico",
        "images/favicon.png",
        "images/logo_color.svg",
        "images/logo.svg",
        "images/logo_color.png",
        "images/logo.png",
        "app/favicon.ico",
        "app/favicon.png",
        "app/icon.svg",
        "app/icon.png",
        "app/icon.ico",
        "src/favicon.ico",
        "src/favicon.svg",
        "src/app/favicon.ico",
        "src/app/icon.svg",
        "src/app/icon.png",
        "assets/icon.svg",
        "assets/icon.png",
        "assets/logo.svg",
        "assets/logo.png",
        ".idea/icon.svg",
    ]

    private static let iconSourceFiles: [String] = [
        "index.html",
        "public/index.html",
        "app/routes/__root.tsx",
        "src/routes/__root.tsx",
        "app/root.tsx",
        "src/root.tsx",
        "src/index.html",
    ]

    private static let appIconRelativePaths: [String] = [
        "Assets.xcassets/AppIcon.appiconset/Contents.json",
        "Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
    ]

    private static let linkIconHtmlPattern = #"<link\b(?=[^>]*\brel=["'](?:icon|shortcut icon)["'])(?=[^>]*\bhref=["']([^"'?]+))[^>]*>"#
    private static let linkIconObjPattern  = #"(?=[^}]*\brel\s*:\s*["'](?:icon|shortcut icon)["'])(?=[^}]*\bhref\s*:\s*["']([^"'?]+))[^}]*"#

    private static let linkIconHtmlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: linkIconHtmlPattern, options: [.caseInsensitive])
    }()

    private static let linkIconObjRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: linkIconObjPattern, options: [.caseInsensitive])
    }()

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "ProjectIcon")
    private let negativeTTL: TimeInterval
    private let now: () -> Date
    private var cache: [String: CachedResolution] = [:]

    init(negativeTTL: TimeInterval = 5 * 60, now: @escaping () -> Date = Date.init) {
        self.negativeTTL = negativeTTL
        self.now = now
    }

    func resolve(cwd: String, size: NSSize, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[cwd] {
            switch cached {
            case .image(let image, _):
                DispatchQueue.main.async { completion(image) }
                return
            case .missing(let checkedAt):
                if now().timeIntervalSince(checkedAt) < negativeTTL {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            }
        }

        let nowSnapshot = now()
        let logLabel = (cwd as NSString).lastPathComponent

        let cwdExtension = (cwd as NSString).pathExtension.lowercased()
        if Self.bundleExtensions.contains(cwdExtension) {
            let icon = NSWorkspace.shared.icon(forFile: cwd)
            icon.size = size
            cache[cwd] = .image(icon, resolvedAt: nowSnapshot)
            Self.logger.debug("Resolved bundle icon for \(logLabel)")
            DispatchQueue.main.async { completion(icon) }
            return
        }

        Task { [self] in
            let image = await Self.performScan(cwd: cwd, size: size)
            if let image {
                self.cache[cwd] = .image(image, resolvedAt: nowSnapshot)
                Self.logger.debug("Resolved project icon for \(logLabel)")
            } else {
                self.cache[cwd] = .missing(checkedAt: nowSnapshot)
                Self.logger.debug("No project icon for \(logLabel)")
            }
            completion(image)
        }
    }

    func prewarm(cwd: String) {
        if case .unknown = cachedLookup(cwd: cwd) {
            resolve(cwd: cwd, size: Self.defaultRenderSize) { _ in }
        }
    }

    func cachedLookup(cwd: String) -> CachedLookup {
        guard let cached = cache[cwd] else { return .unknown }
        switch cached {
        case .image(let image, _):
            return .hit(image)
        case .missing(let checkedAt):
            if now().timeIntervalSince(checkedAt) < negativeTTL {
                return .miss
            }
            return .unknown
        }
    }

    func invalidate(cwd: String) {
        cache.removeValue(forKey: cwd)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private static func performScan(cwd: String, size: NSSize) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let image = scan(cwd: cwd, size: size)
                continuation.resume(returning: image)
            }
        }
    }

    private static func scan(cwd: String, size: NSSize) -> NSImage? {
        let fileManager = FileManager.default
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let cwdResolvedPath = cwdURL.resolvingSymlinksInPath().path

        for candidate in faviconCandidates {
            let candidateURL = cwdURL.appendingPathComponent(candidate)
            if let image = loadFile(
                at: candidateURL,
                cwdResolvedPath: cwdResolvedPath,
                size: size,
                fileManager: fileManager
            ) {
                return image
            }
        }

        for relativePath in appIconRelativePaths {
            let contentsURL = cwdURL.appendingPathComponent(relativePath)
            if let filename = largestAppIconFilename(at: contentsURL, fileManager: fileManager) {
                let iconURL = contentsURL.deletingLastPathComponent().appendingPathComponent(filename)
                if let image = loadFile(
                    at: iconURL,
                    cwdResolvedPath: cwdResolvedPath,
                    size: size,
                    fileManager: fileManager
                ) {
                    return image
                }
            }
        }

        for sourceFile in iconSourceFiles {
            let sourceURL = cwdURL.appendingPathComponent(sourceFile)
            guard isRegularFile(at: sourceURL, fileManager: fileManager),
                  isPathWithinCWD(candidateURL: sourceURL, cwdResolvedPath: cwdResolvedPath)
            else {
                continue
            }
            let source: String
            do {
                source = try String(contentsOf: sourceURL, encoding: .utf8)
            } catch {
                logger.debug("Failed to read \(sourceFile): \(error.localizedDescription)")
                continue
            }
            guard let href = extractIconHref(from: source) else {
                continue
            }

            let stripped = href.hasPrefix("/") ? String(href.dropFirst()) : href
            let candidates: [URL] = [
                cwdURL.appendingPathComponent(stripped),
                cwdURL.appendingPathComponent("public").appendingPathComponent(stripped),
            ]
            for candidateURL in candidates {
                if let image = loadFile(
                    at: candidateURL,
                    cwdResolvedPath: cwdResolvedPath,
                    size: size,
                    fileManager: fileManager
                ) {
                    return image
                }
            }
        }

        return nil
    }

    private static func loadFile(
        at url: URL,
        cwdResolvedPath: String,
        size: NSSize,
        fileManager: FileManager
    ) -> NSImage? {
        guard isRegularFile(at: url, fileManager: fileManager),
              isPathWithinCWD(candidateURL: url, cwdResolvedPath: cwdResolvedPath) else {
            return nil
        }
        guard let image = NSImage(contentsOfFile: url.path) else {
            return nil
        }
        image.size = size
        return image
    }

    private static func isRegularFile(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private static func isPathWithinCWD(candidateURL: URL, cwdResolvedPath: String) -> Bool {
        let resolved = candidateURL.resolvingSymlinksInPath().path
        if resolved == cwdResolvedPath {
            return true
        }
        return resolved.hasPrefix(cwdResolvedPath + "/")
    }

    private static func largestAppIconFilename(at contentsURL: URL, fileManager: FileManager) -> String? {
        guard isRegularFile(at: contentsURL, fileManager: fileManager) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: contentsURL)
        } catch {
            logger.debug("Failed to read \(contentsURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.debug("Failed to parse \(contentsURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        guard let json = parsed as? [String: Any],
              let images = json["images"] as? [[String: Any]] else {
            return nil
        }

        var bestFilename: String?
        var bestScore: Double = -1

        for entry in images {
            guard let filename = entry["filename"] as? String, !filename.isEmpty else {
                continue
            }
            let parsedSize = parseSizeDimension(entry["size"] as? String)
            let parsedScale = parseScaleDimension(entry["scale"] as? String)
            let score = parsedSize * parsedScale
            if score > bestScore {
                bestScore = score
                bestFilename = filename
            }
        }

        return bestFilename
    }

    private static func parseSizeDimension(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 0 }
        let parts = value.lowercased().split(separator: "x")
        guard let first = parts.first, let parsed = Double(first) else { return 0 }
        return parsed
    }

    private static func parseScaleDimension(_ value: String?) -> Double {
        guard let value, !value.isEmpty else { return 1 }
        let trimmed = value.lowercased().replacingOccurrences(of: "x", with: "")
        return Double(trimmed) ?? 1
    }

    private static func extractIconHref(from source: String) -> String? {
        if let regex = linkIconHtmlRegex, let match = firstCaptureGroup(of: regex, in: source) {
            return match
        }
        if let regex = linkIconObjRegex, let match = firstCaptureGroup(of: regex, in: source) {
            return match
        }
        return nil
    }

    private static func firstCaptureGroup(of regex: NSRegularExpression, in source: String) -> String? {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }
        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound,
              let swiftRange = Range(captureRange, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }
}
