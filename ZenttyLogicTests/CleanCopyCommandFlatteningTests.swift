import XCTest
@testable import Zentty

final class CleanCopyCommandFlatteningTests: XCTestCase {

    func test_flattenCommandText_joins_backslash_continuation() {
        let input = "curl https://example.com \\\n  -H 'Accept: application/json'"
        let output = CleanCopyPipeline.flattenCommandText(input, preserveBlankLines: false)
        XCTAssertFalse(output.contains("\n"))
        XCTAssertTrue(output.contains("curl"))
        XCTAssertTrue(output.contains("-H"))
    }

    func test_transformMultiLineCommandIfNeeded_respects_disabled_option() {
        let options = CleanCopyOptions(
            flattenMultiLineCommands: false,
            commandFlattenAggressiveness: .normal,
            preserveBlankLinesWhenFlattening: true,
            removeBoxDrawing: true,
            flattenSlashCommandSelections: true,
            stripURLTrackingParameters: true,
            quotePathsWithSpaces: true
        )
        let input = "git status \\\n  --short"
        XCTAssertNil(CleanCopyPipeline.transformMultiLineCommandIfNeeded(input, options: options))
    }

    func test_transformMultiLineCommandIfNeeded_flattens_when_enabled() {
        let input = "git status \\\n  --short"
        let output = CleanCopyPipeline.transformMultiLineCommandIfNeeded(input, options: .default)
        XCTAssertEqual(output, "git status --short")
    }
}