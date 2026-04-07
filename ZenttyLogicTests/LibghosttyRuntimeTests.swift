import XCTest
@testable import Zentty

@MainActor
final class LibghosttyRuntimeTests: XCTestCase {
    func testTransparentBackgroundOverrideContents_preservesConfiguredOpacity() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            theme = Github-Dark-Personal
            """
        )

        XCTAssertEqual(contents, "background-blur-radius = 20\n")
        XCTAssertFalse(contents?.contains("background-opacity") ?? false)
    }

    func testTransparentBackgroundOverrideContents_skipsFallbackWhenBlurRadiusConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur-radius = 25
            """
        )

        XCTAssertNil(contents)
    }

    func testTransparentBackgroundOverrideContents_treatsLegacyBackgroundBlurAsConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur = 25
            """
        )

        XCTAssertNil(contents)
    }
}
