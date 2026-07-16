import XCTest
@testable import Zentty

final class CleanCopyCommandFlatteningTests: XCTestCase {

    func test_clean_preserves_padded_gitStatusRows() {
        let input = [
            padded("❯ g"),
            padded(" M .github/workflows/ci.yml"),
            padded("?? .github/workflows/promote.yml"),
            padded("?? .github/workflows/test-build.yml"),
        ].joined(separator: "\n")

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(
            result.text,
            [
                "g",
                " M .github/workflows/ci.yml",
                "?? .github/workflows/promote.yml",
                "?? .github/workflows/test-build.yml",
            ].joined(separator: "\n")
        )
    }

    func test_clean_flattens_backslashContinuationEvenWithPaddedShortRows() {
        let input = [
            padded("xcodebuild test \\"),
            padded("  -scheme Zentty"),
        ].joined(separator: "\n")

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(result.text, "xcodebuild test -scheme Zentty")
    }

    func test_clean_flattens_explicitPipelineJoinEvenWithPaddedShortRows() {
        let input = [
            padded("git log --oneline |"),
            padded("  head -n 5"),
        ].joined(separator: "\n")

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(result.text, "git log --oneline | head -n 5")
    }

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

    func test_transformMultiLineCommandIfNeeded_vetoes_paddedShortRowsEvidence() {
        let input = "$ g\n M .github/workflows/ci.yml\n?? .github/workflows/promote.yml"
        let paddedInput = [
            padded("$ g"),
            padded(" M .github/workflows/ci.yml"),
            padded("?? .github/workflows/promote.yml"),
        ].joined(separator: "\n")
        let evidence = CleanCopyPipeline.PlainProseLineShapeEvidence(input: paddedInput)

        XCTAssertNil(
            CleanCopyPipeline.transformMultiLineCommandIfNeeded(
                input,
                options: .default,
                lineShapeEvidence: evidence
            )
        )
        XCTAssertNotNil(
            CleanCopyPipeline.transformMultiLineCommandIfNeeded(
                input,
                options: .default,
                lineShapeEvidence: nil
            )
        )
    }

    func test_clean_preserves_twoLineProse_mentioningBranchName() {
        let input = "I pushed the fix to feature/login-flow.\nCan you review it today?"

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(result.text, input)
    }

    func test_clean_preserves_twoLineProse_mentioningFilePath() {
        let input = "The fix is in src/main.rs.\nLet me know what you think."

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(result.text, input)
    }

    func test_clean_flattens_wrappedGitCommand_withPathAndBackslashContinuation() {
        let input = "git push origin feature/login-flow \\\n  --force"

        let result = CleanCopyPipeline.clean(input)

        XCTAssertEqual(result.text, "git push origin feature/login-flow --force")
    }

    private func padded(_ line: String, width: Int = 100) -> String {
        line + String(repeating: " ", count: max(0, width - line.count))
    }
}
