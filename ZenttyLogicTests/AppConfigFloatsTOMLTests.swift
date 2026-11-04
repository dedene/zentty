import XCTest
@testable import Zentty

final class AppConfigFloatsTOMLTests: XCTestCase {

    func test_auto_pop_defaults_to_on() {
        XCTAssertTrue(AppConfig.default.floats.autoPopNeedsInput)
    }

    func test_missing_floats_section_decodes_to_defaults() {
        let decoded = AppConfigTOML.decode("""
            [menu_bar]
            show_status_item = true
            """)

        XCTAssertEqual(decoded?.floats, .default)
    }

    func test_auto_pop_opt_out_round_trips() {
        var config = AppConfig.default
        config.floats.autoPopNeedsInput = false

        let encoded = AppConfigTOML.encode(config)
        let decoded = AppConfigTOML.decode(encoded)

        XCTAssertTrue(encoded.contains("[floats]\nauto_pop_needs_input = false"))
        XCTAssertEqual(decoded?.floats.autoPopNeedsInput, false)
    }

    func test_unknown_floats_key_is_preserved_not_rejected() {
        let decoded = AppConfigTOML.decode("""
            [floats]
            auto_pop_needs_input = false
            future_knob = "on"
            """)

        XCTAssertEqual(decoded?.floats.autoPopNeedsInput, false)
        XCTAssertEqual(decoded.map(AppConfigTOML.encode)?.contains("future_knob = \"on\""), true)
    }

    func test_pip_size_defaults_to_small() {
        XCTAssertEqual(AppConfig.default.floats.pipSize, .small)
        XCTAssertTrue(AppConfigTOML.encode(.default).contains("[floats]\nauto_pop_needs_input = true\npip_size = \"small\""))
    }

    func test_pip_size_medium_round_trips() {
        var config = AppConfig.default
        config.floats.pipSize = .medium

        let decoded = AppConfigTOML.decode(AppConfigTOML.encode(config))

        XCTAssertEqual(decoded?.floats.pipSize, .medium)
        XCTAssertEqual(decoded?.floats.autoPopNeedsInput, true)
    }

    func test_pip_size_rejects_unknown_value() {
        XCTAssertNil(AppConfigTOML.decode("""
            [floats]
            pip_size = "large"
            """))
    }

    func test_pip_size_maps_to_the_spec_widths() {
        XCTAssertEqual(FloatLayout.pipWidth(for: .small), 232)
        XCTAssertEqual(FloatLayout.pipWidth(for: .medium), 300)
    }

    func test_auto_pop_rejects_non_bool_value() {
        XCTAssertNil(AppConfigTOML.decode("""
            [floats]
            auto_pop_needs_input = "yes"
            """))
    }
}
