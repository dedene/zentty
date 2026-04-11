import Foundation
import XCTest

final class BundledGhosttyThemeResourcesTests: XCTestCase {
    func test_app_bundle_contains_vendored_ghostty_theme_library() throws {
        let appBundle = try makeAppBundle()
        let themesDirectoryURL = try XCTUnwrap(
            appBundle.resourceURL?.appendingPathComponent("ghostty/themes", isDirectory: true)
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: themesDirectoryURL.path, isDirectory: &isDirectory),
            "Expected bundled Ghostty themes at \(themesDirectoryURL.path)"
        )
        XCTAssertTrue(isDirectory.boolValue)

        let themes = try FileManager.default.contentsOfDirectory(
            at: themesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        XCTAssertGreaterThan(
            themes.count,
            100,
            "Expected a substantial vendored Ghostty theme library in the app bundle"
        )
    }

    private func makeAppBundle() throws -> Bundle {
        let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appBundleURL = productsURL.appendingPathComponent("Zentty.app", isDirectory: true)
        return try XCTUnwrap(Bundle(url: appBundleURL))
    }
}
