import AppKit
import XCTest
@testable import Zentty

@MainActor
final class ProjectIconResolverTests: AppKitTestCase {
    private let iconSize = NSSize(width: 16, height: 16)

    // MARK: - Candidate paths

    func test_resolves_root_favicon_svg() throws {
        let root = try makeProject { url in
            try writeSVG(at: url.appendingPathComponent("favicon.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_public_favicon_png() throws {
        let root = try makeProject { url in
            let publicDir = url.appendingPathComponent("public")
            try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
            try writePNG(at: publicDir.appendingPathComponent("favicon.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_app_icon_png() throws {
        let root = try makeProject { url in
            let appDir = url.appendingPathComponent("app")
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            try writePNG(at: appDir.appendingPathComponent("icon.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_src_app_icon_png() throws {
        let root = try makeProject { url in
            let srcApp = url.appendingPathComponent("src/app")
            try FileManager.default.createDirectory(at: srcApp, withIntermediateDirectories: true)
            try writePNG(at: srcApp.appendingPathComponent("icon.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_assets_logo_svg() throws {
        let root = try makeProject { url in
            let assets = url.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try writeSVG(at: assets.appendingPathComponent("logo.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_images_favicon_dir_apple_touch_icon() throws {
        let root = try makeProject { url in
            let faviconDir = url.appendingPathComponent("images/favicon")
            try FileManager.default.createDirectory(at: faviconDir, withIntermediateDirectories: true)
            try writePNG(at: faviconDir.appendingPathComponent("apple-touch-icon.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_images_favicon_dir_favicon_ico_when_no_apple_touch() throws {
        let root = try makeProject { url in
            let faviconDir = url.appendingPathComponent("images/favicon")
            try FileManager.default.createDirectory(at: faviconDir, withIntermediateDirectories: true)
            try writePNG(at: faviconDir.appendingPathComponent("favicon.ico"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_images_logo_color_svg() throws {
        let root = try makeProject { url in
            let imagesDir = url.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try writeSVG(at: imagesDir.appendingPathComponent("logo_color.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_images_logo_png() throws {
        let root = try makeProject { url in
            let imagesDir = url.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try writePNG(at: imagesDir.appendingPathComponent("logo.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_idea_icon_svg() throws {
        let root = try makeProject { url in
            let idea = url.appendingPathComponent(".idea")
            try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
            try writeSVG(at: idea.appendingPathComponent("icon.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_resolves_apple_touch_icon() throws {
        let root = try makeProject { url in
            try writePNG(at: url.appendingPathComponent("apple-touch-icon.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    // MARK: - Xcode AppIcon

    func test_xcode_appicon_picks_largest() throws {
        let root = try makeProject { url in
            let iconset = url.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

            try writePNG(at: iconset.appendingPathComponent("small.png"))
            try writePNG(at: iconset.appendingPathComponent("big.png"))
            try writePNG(at: iconset.appendingPathComponent("largest.png"))

            let contents = """
            {
              "images" : [
                { "size" : "16x16",     "scale" : "1x", "filename" : "small.png" },
                { "size" : "512x512",   "scale" : "2x", "filename" : "big.png" },
                { "size" : "1024x1024", "scale" : "2x", "filename" : "largest.png" }
              ],
              "info" : { "version" : 1, "author" : "xcode" }
            }
            """
            try contents.write(
                to: iconset.appendingPathComponent("Contents.json"),
                atomically: true,
                encoding: .utf8
            )

            // Tag the "largest" image with distinct dimensions so we can verify pick.
            try writeDistinctPNG(at: iconset.appendingPathComponent("largest.png"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        let unwrapped = try XCTUnwrap(image)
        // largest.png is the 4x4 rep, small/big are 1x1.
        let pixelWidth = unwrapped.representations.compactMap { rep in
            (rep as? NSBitmapImageRep).map { CGFloat($0.pixelsWide) }
        }.max() ?? 0
        XCTAssertEqual(pixelWidth, 4, "Largest entry should have been chosen (4px rep)")
    }

    // MARK: - HTML / TSX fallback

    func test_html_link_rel_icon_fallback() throws {
        let root = try makeProject { url in
            let staticDir = url.appendingPathComponent("static")
            try FileManager.default.createDirectory(at: staticDir, withIntermediateDirectories: true)
            try writePNG(at: staticDir.appendingPathComponent("favicon.png"))

            let html = """
            <!doctype html>
            <html><head>
              <link rel="icon" href="/static/favicon.png" />
            </head><body></body></html>
            """
            try html.write(to: url.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_html_link_rel_icon_public_prefix() throws {
        let root = try makeProject { url in
            let publicDir = url.appendingPathComponent("public")
            try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
            try writePNG(at: publicDir.appendingPathComponent("site-favicon.png"))

            let html = """
            <!doctype html>
            <html><head>
              <link rel="icon" href="/site-favicon.png" />
            </head><body></body></html>
            """
            try html.write(to: url.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_ts_object_link_rel_icon_fallback() throws {
        let root = try makeProject { url in
            let iconsDir = url.appendingPathComponent("icons")
            try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            try writeSVG(at: iconsDir.appendingPathComponent("site.svg"))

            let appDir = url.appendingPathComponent("app")
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let source = """
            export const links = () => [
              { rel: "icon", href: "/icons/site.svg" },
            ];
            """
            try source.write(to: appDir.appendingPathComponent("root.tsx"), atomically: true, encoding: .utf8)
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    // MARK: - Symlinks

    func test_symlink_inside_cwd_accepted() throws {
        let root = try makeProject { url in
            let assets = url.appendingPathComponent("assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let realIcon = assets.appendingPathComponent("icon.svg")
            try writeSVG(at: realIcon)

            // favicon.svg -> assets/icon.svg (inside cwd)
            try FileManager.default.createSymbolicLink(
                at: url.appendingPathComponent("favicon.svg"),
                withDestinationURL: realIcon
            )
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(image)
    }

    func test_symlink_escapes_cwd_rejected() throws {
        // Create an external target file inside another UUID dir so the symlink truly escapes.
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let externalSVG = externalRoot.appendingPathComponent("outside.svg")
        try writeSVG(at: externalSVG)
        defer { cleanup(externalRoot) }

        let root = try makeProject { url in
            try FileManager.default.createSymbolicLink(
                at: url.appendingPathComponent("favicon.svg"),
                withDestinationURL: externalSVG
            )
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNil(image)
    }

    // MARK: - Negative cache

    func test_negative_cache_returns_nil_within_ttl() throws {
        let root = try makeProject { _ in }
        // Don't defer cleanup — we remove it manually below.

        let resolver = ProjectIconResolver(negativeTTL: 60)
        let firstImage = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNil(firstImage)

        // Even after the directory is gone, the cached negative should hold.
        try FileManager.default.removeItem(at: root)

        let secondImage = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNil(secondImage)
    }

    func test_negative_cache_expires_after_ttl() throws {
        let root = try makeProject { _ in }
        defer { cleanup(root) }

        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let resolver = ProjectIconResolver(negativeTTL: 1, now: { currentTime })

        let firstImage = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNil(firstImage)

        // Advance past TTL and add an icon
        currentTime = currentTime.addingTimeInterval(10)
        try writeSVG(at: root.appendingPathComponent("favicon.svg"))

        let secondImage = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNotNil(secondImage)
    }

    // MARK: - Bundle short-circuit

    func test_bundle_short_circuit_app() throws {
        let calculatorPath = "/System/Applications/Calculator.app"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: calculatorPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Calculator.app not available on this system")
        }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: calculatorPath)
        let unwrapped = try XCTUnwrap(image)
        XCTAssertEqual(unwrapped.size, iconSize)
    }

    // MARK: - Robustness

    func test_missing_image_file_falls_back_to_nil() throws {
        let root = try makeProject { url in
            let iconset = url.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

            let contents = """
            {
              "images" : [
                { "size" : "1024x1024", "scale" : "1x", "filename" : "nonexistent.png" }
              ],
              "info" : { "version" : 1, "author" : "xcode" }
            }
            """
            try contents.write(
                to: iconset.appendingPathComponent("Contents.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let image = try awaitResolve(resolver: resolver, cwd: root.path)
        XCTAssertNil(image)
    }

    // MARK: - Threading

    func test_completion_fires_on_main() throws {
        let root = try makeProject { url in
            try writeSVG(at: url.appendingPathComponent("favicon.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        let expectation = self.expectation(description: "completion on main")
        var completedOnMain = false
        resolver.resolve(cwd: root.path, size: iconSize) { _ in
            completedOnMain = Thread.isMainThread
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(completedOnMain)
    }

    func test_cache_hit_completion_fires_on_main() throws {
        let root = try makeProject { url in
            try writeSVG(at: url.appendingPathComponent("favicon.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        _ = try awaitResolve(resolver: resolver, cwd: root.path)

        let expectation = self.expectation(description: "cache-hit completion on main")
        var completedOnMain = false
        resolver.resolve(cwd: root.path, size: iconSize) { _ in
            completedOnMain = Thread.isMainThread
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(completedOnMain)
    }

    func test_cached_lookup_returns_unknown_for_fresh_cwd() throws {
        let root = try makeProject { _ in }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        guard case .unknown = resolver.cachedLookup(cwd: root.path) else {
            XCTFail("Expected .unknown for fresh cwd")
            return
        }
    }

    func test_cached_lookup_returns_hit_after_positive_resolve() throws {
        let root = try makeProject { url in
            try writeSVG(at: url.appendingPathComponent("favicon.svg"))
        }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        _ = try awaitResolve(resolver: resolver, cwd: root.path)

        guard case .hit = resolver.cachedLookup(cwd: root.path) else {
            XCTFail("Expected .hit after positive resolve")
            return
        }
    }

    func test_cached_lookup_returns_miss_within_negative_ttl() throws {
        let root = try makeProject { _ in }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        _ = try awaitResolve(resolver: resolver, cwd: root.path)

        guard case .miss = resolver.cachedLookup(cwd: root.path) else {
            XCTFail("Expected .miss within TTL")
            return
        }
    }

    func test_cached_lookup_returns_unknown_after_negative_ttl_expires() throws {
        var currentTime = Date()
        let root = try makeProject { _ in }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver(negativeTTL: 60, now: { currentTime })
        _ = try awaitResolve(resolver: resolver, cwd: root.path)

        guard case .miss = resolver.cachedLookup(cwd: root.path) else {
            XCTFail("Expected .miss within TTL")
            return
        }

        currentTime = currentTime.addingTimeInterval(120)

        guard case .unknown = resolver.cachedLookup(cwd: root.path) else {
            XCTFail("Expected .unknown after TTL expiry")
            return
        }
    }

    func test_negative_cache_completion_fires_on_main() throws {
        let root = try makeProject { _ in }
        defer { cleanup(root) }

        let resolver = ProjectIconResolver()
        _ = try awaitResolve(resolver: resolver, cwd: root.path)

        let expectation = self.expectation(description: "negative-cache completion on main")
        var completedOnMain = false
        resolver.resolve(cwd: root.path, size: iconSize) { _ in
            completedOnMain = Thread.isMainThread
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(completedOnMain)
    }

    // MARK: - Helpers

    private func makeProject(_ block: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try block(root)
        return root
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func awaitResolve(
        resolver: ProjectIconResolver,
        cwd: String,
        timeout: TimeInterval = 5
    ) throws -> NSImage? {
        let expectation = self.expectation(description: "resolve completes for \(cwd)")
        var result: NSImage?
        resolver.resolve(cwd: cwd, size: iconSize) { image in
            result = image
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
        return result
    }

    private func writeSVG(at url: URL) throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">
          <rect width="14" height="14" fill="#FF0000"/>
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePNG(at url: URL) throws {
        guard let data = makePNGData(pixelsWide: 1, pixelsHigh: 1) else {
            throw NSError(domain: "ProjectIconResolverTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to build PNG data",
            ])
        }
        try data.write(to: url)
    }

    private func writeDistinctPNG(at url: URL) throws {
        guard let data = makePNGData(pixelsWide: 4, pixelsHigh: 4) else {
            throw NSError(domain: "ProjectIconResolverTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to build distinct PNG data",
            ])
        }
        try data.write(to: url)
    }

    private func makePNGData(pixelsWide: Int, pixelsHigh: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
