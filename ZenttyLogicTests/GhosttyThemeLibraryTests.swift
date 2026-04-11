import XCTest
@testable import Zentty

final class GhosttyThemeLibraryTests: XCTestCase {
    func test_resolverThemeDirectories_include_app_and_bundle_candidates_without_environment_variable() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let bundleResourceURL = URL(fileURLWithPath: "/Applications/Zentty.app/Contents/Resources", isDirectory: true)

        let directories = GhosttyThemeLibrary.resolverThemeDirectories(
            homeDirectoryURL: homeDirectoryURL,
            bundleResourceURL: bundleResourceURL,
            environment: [:]
        )

        XCTAssertEqual(
            directories,
            [
                homeDirectoryURL.appendingPathComponent(".config/ghostty/themes", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true),
                homeDirectoryURL.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true),
                bundleResourceURL.appendingPathComponent("ghostty/themes", isDirectory: true),
            ]
        )
    }

    func test_resolverThemeDirectories_place_environment_themes_before_app_and_bundle_candidates() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let bundleResourceURL = URL(fileURLWithPath: "/Applications/Zentty.app/Contents/Resources", isDirectory: true)
        let environment = ["GHOSTTY_RESOURCES_DIR": "/tmp/ghostty-resources"]

        let directories = GhosttyThemeLibrary.resolverThemeDirectories(
            homeDirectoryURL: homeDirectoryURL,
            bundleResourceURL: bundleResourceURL,
            environment: environment
        )

        XCTAssertEqual(
            directories,
            [
                homeDirectoryURL.appendingPathComponent(".config/ghostty/themes", isDirectory: true),
                URL(fileURLWithPath: "/tmp/ghostty-resources", isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true),
                homeDirectoryURL.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true),
                bundleResourceURL.appendingPathComponent("ghostty/themes", isDirectory: true),
            ]
        )
    }

    func test_catalogThemeDirectories_reverse_resolver_precedence_for_user_override_behavior() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let bundleResourceURL = URL(fileURLWithPath: "/Applications/Zentty.app/Contents/Resources", isDirectory: true)

        let resolverDirectories = GhosttyThemeLibrary.resolverThemeDirectories(
            homeDirectoryURL: homeDirectoryURL,
            bundleResourceURL: bundleResourceURL,
            environment: [:]
        )
        let catalogDirectories = GhosttyThemeLibrary.catalogThemeDirectories(
            homeDirectoryURL: homeDirectoryURL,
            bundleResourceURL: bundleResourceURL,
            environment: [:]
        )

        XCTAssertEqual(catalogDirectories, Array(resolverDirectories.reversed()))
    }
}
