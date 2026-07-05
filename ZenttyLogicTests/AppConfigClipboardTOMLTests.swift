import XCTest
@testable import Zentty

final class AppConfigClipboardTOMLTests: XCTestCase {

    func test_clipboard_section_round_trips_all_keys() {
        var config = AppConfig.default
        config.clipboard = AppConfig.Clipboard(
            alwaysCleanCopies: true,
            flattenMultiLineCommands: false,
            commandFlattenAggressiveness: .high,
            preserveBlankLinesWhenFlattening: false,
            removeBoxDrawing: false,
            flattenSlashCommandSelections: false,
            stripURLTrackingParameters: false,
            quotePathsWithSpaces: false,
            showCopyMarkdownCommand: false
        )

        let encoded = AppConfigTOML.encode(config)
        let decoded = AppConfigTOML.decode(encoded)

        XCTAssertTrue(encoded.contains("command_flatten_aggressiveness = \""))
        XCTAssertEqual(decoded?.clipboard, config.clipboard)
    }

    func test_unknown_clipboard_key_does_not_fail_decode() {
        let source = """
        [clipboard]
        always_clean_copies = true
        future_clipboard_flag = true
        flatten_multi_line_commands = true
        """
        let decoded = AppConfigTOML.decode(source)
        XCTAssertEqual(decoded?.clipboard.alwaysCleanCopies, true)
        XCTAssertEqual(decoded?.clipboard.flattenMultiLineCommands, true)
    }

    func test_invalid_aggressiveness_rejects_config() {
        let source = """
        [clipboard]
        command_flatten_aggressiveness = "extreme"
        """
        XCTAssertNil(AppConfigTOML.decode(source))
    }

    func test_valid_quoted_aggressiveness_decodes() {
        let source = """
        [clipboard]
        command_flatten_aggressiveness = "high"
        """
        XCTAssertEqual(AppConfigTOML.decode(source)?.clipboard.commandFlattenAggressiveness, .high)
    }

    func test_unquoted_aggressiveness_rejects_config() {
        let source = """
        [clipboard]
        command_flatten_aggressiveness = high
        """
        XCTAssertNil(AppConfigTOML.decode(source))
    }
}
