import XCTest
@testable import Zentty

final class MarkdownReformatterTests: XCTestCase {

    func test_isLikelyMarkdown_detects_headings() {
        XCTAssertTrue(MarkdownReformatter.isLikelyMarkdown("## Title\n\nBody line"))
    }

    func test_reformat_joins_wrapped_paragraph_lines() {
        let input = "One long\nparagraph split\nacross lines"
        let output = MarkdownReformatter.reformat(input)
        XCTAssertEqual(output, "One long paragraph split across lines")
    }

    func test_reformat_preserves_fenced_code_block() {
        let input = """
        Intro
        ```swift
        let x = 1
        wrapped
        line
        ```
        """
        let output = MarkdownReformatter.reformat(input)
        XCTAssertTrue(output.contains("```swift"))
        XCTAssertTrue(output.contains("wrapped\nline"))
    }

    func test_reformat_preserves_markdown_table_rows() {
        let input = """
        # Results
        | name | value |
        | --- | --- |
        | a | 1 |
        """
        let output = MarkdownReformatter.reformat(input)
        XCTAssertEqual(output, input)
    }

    func test_reformat_joins_wrapped_paragraph_before_table() {
        let input = """
        A wrapped
        paragraph before
        a table.
        | name | value |
        | --- | --- |
        | a | 1 |
        """
        let output = MarkdownReformatter.reformat(input)
        XCTAssertEqual(output, """
        A wrapped paragraph before a table.
        | name | value |
        | --- | --- |
        | a | 1 |
        """)
    }
}
