import XCTest
@testable import Zentty

@MainActor
final class LibghosttyRuntimeTests: XCTestCase {
    func testTransparentBackgroundOverrideContents_forcesTransparentEmbeddedSurfaceAndAddsFallbackBlur() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            theme = Github-Dark-Personal
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\nbackground-blur-radius = 20\n")
    }

    func testTransparentBackgroundOverrideContents_keepsTransparencyOverrideWhenBlurRadiusConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur-radius = 25
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\n")
    }

    func testTransparentBackgroundOverrideContents_keepsTransparencyOverrideWhenLegacyBackgroundBlurConfigured() {
        let contents = LibghosttyRuntime.transparentBackgroundOverrideContents(
            userConfigContents: """
            background-opacity = 0.95
            background-blur = 25
            """
        )

        XCTAssertEqual(contents, "background-opacity = 0\n")
    }
}
