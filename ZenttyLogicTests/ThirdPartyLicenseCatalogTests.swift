import XCTest
@testable import Zentty

final class ThirdPartyLicenseCatalogTests: XCTestCase {
    func test_bundled_catalog_includes_current_shipped_dependencies() throws {
        let catalog = try ThirdPartyLicenseCatalog.load(from: .main)

        let versionsByID = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0.version) })

        XCTAssertEqual(versionsByID["ghostty"], "e75f895")
        XCTAssertEqual(versionsByID["sentry-cocoa"], "9.9.0")
        XCTAssertEqual(versionsByID["sparkle"], "2.9.1")
        XCTAssertEqual(versionsByID["swift-argument-parser"], "1.7.1")
    }

    func test_bundled_catalog_entries_have_required_fields() throws {
        let catalog = try ThirdPartyLicenseCatalog.load(from: .main)

        XCTAssertFalse(catalog.entries.isEmpty)

        for entry in catalog.entries {
            XCTAssertFalse(entry.id.isEmpty)
            XCTAssertFalse(entry.displayName.isEmpty)
            XCTAssertFalse(entry.version.isEmpty)
            XCTAssertFalse(entry.licenseName.isEmpty)
            XCTAssertFalse(entry.sourceURLString.isEmpty)
            XCTAssertFalse(entry.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func test_bundled_catalog_includes_iterm2_color_schemes_for_vendored_ghostty_themes() throws {
        let catalog = try ThirdPartyLicenseCatalog.load(from: .main)

        let entry = try XCTUnwrap(catalog.entries.first { $0.id == "iterm2-color-schemes" })
        XCTAssertEqual(entry.displayName, "iTerm2 Color Schemes")
        XCTAssertEqual(entry.licenseName, "MIT License")
        XCTAssertEqual(entry.spdxID, "MIT")
        XCTAssertEqual(entry.homepageURLString, "https://github.com/mbadolato/iTerm2-Color-Schemes")
        XCTAssertEqual(
            entry.sourceURLString,
            "https://github.com/mbadolato/iTerm2-Color-Schemes/blob/master/LICENSE"
        )
        XCTAssertTrue(entry.fullText.contains("Permission is hereby granted, free of charge"))
    }

    func test_load_throws_decoding_error_for_malformed_catalog_object() throws {
        let bundle = try makeTemporaryBundle(
            resourceName: "ThirdPartyLicenses",
            resourceExtension: "json",
            contents: """
            {
              "entries": [
                {
                  "id": 123
                }
              ]
            }
            """
        )

        XCTAssertThrowsError(try ThirdPartyLicenseCatalog.load(from: bundle)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }
}

private func makeTemporaryBundle(
    resourceName: String,
    resourceExtension: String,
    contents: String
) throws -> Bundle {
    let fileManager = FileManager.default
    let bundleRoot = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bundle")
    let contentsDirectory = bundleRoot.appendingPathComponent("Contents")
    let resourcesDirectory = contentsDirectory.appendingPathComponent("Resources")

    try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

    let infoPlist = contentsDirectory.appendingPathComponent("Info.plist")
    let infoPlistContents = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>be.zenjoy.tests.\(UUID().uuidString)</string>
        <key>CFBundleName</key>
        <string>ThirdPartyLicenseCatalogTests</string>
        <key>CFBundlePackageType</key>
        <string>BNDL</string>
    </dict>
    </plist>
    """
    try infoPlistContents.write(to: infoPlist, atomically: true, encoding: .utf8)

    let resourceURL = resourcesDirectory.appendingPathComponent(resourceName).appendingPathExtension(resourceExtension)
    try contents.write(to: resourceURL, atomically: true, encoding: .utf8)

    return try XCTUnwrap(Bundle(url: bundleRoot))
}
