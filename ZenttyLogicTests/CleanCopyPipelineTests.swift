import XCTest
@testable import Zentty

final class CleanCopyPipelineTests: XCTestCase {

    // MARK: - Pass 1: ANSI Escape Removal

    func test_stripANSI_removes_color_codes() {
        let input = "\u{1B}[31mError:\u{1B}[0m something broke"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "Error: something broke")
    }

    func test_stripANSI_removes_256_color_and_bold() {
        let input = "\u{1B}[1;38;5;208mwarning\u{1B}[0m"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "warning")
    }

    func test_stripANSI_removes_OSC_title_sequence() {
        let input = "\u{1B}]0;Terminal Title\u{07}actual text"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "actual text")
    }

    func test_stripANSI_removes_OSC_with_ST_terminator() {
        let input = "\u{1B}]0;Title\u{1B}\\content"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "content")
    }

    func test_stripANSI_removes_charset_designation() {
        let input = "\u{1B}(Bhello"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "hello")
    }

    func test_stripANSI_identity_for_clean_text() {
        let input = "no escapes here\njust plain text"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), input)
    }

    func test_stripANSI_empty_string() {
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(""), "")
    }

    func test_stripANSI_removes_cursor_movement() {
        let input = "\u{1B}[2Jhello\u{1B}[H"
        XCTAssertEqual(CleanCopyPipeline.stripANSIEscapes(input), "hello")
    }

    // MARK: - Pass 2: Trailing Whitespace Per Line

    func test_trimTrailingWS_strips_trailing_spaces() {
        let input = "hello   \nworld  "
        XCTAssertEqual(
            CleanCopyPipeline.trimTrailingWhitespacePerLine(input),
            "hello\nworld"
        )
    }

    func test_trimTrailingWS_strips_trailing_tabs() {
        let input = "hello\t\t\nworld\t"
        XCTAssertEqual(
            CleanCopyPipeline.trimTrailingWhitespacePerLine(input),
            "hello\nworld"
        )
    }

    func test_trimTrailingWS_preserves_leading_whitespace() {
        let input = "    indented   "
        XCTAssertEqual(
            CleanCopyPipeline.trimTrailingWhitespacePerLine(input),
            "    indented"
        )
    }

    func test_trimTrailingWS_identity_for_clean_text() {
        let input = "clean\ntext"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingWhitespacePerLine(input), input)
    }

    func test_trimTrailingWS_handles_empty_lines() {
        let input = "first\n\nsecond"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingWhitespacePerLine(input), "first\n\nsecond")
    }

    func test_trimTrailingWS_whitespace_only_line_becomes_empty() {
        let input = "hello\n   \nworld"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingWhitespacePerLine(input), "hello\n\nworld")
    }

    // MARK: - Pass 3: Trailing Blank Lines

    func test_trimTrailingBlanks_removes_trailing_empty_lines() {
        let input = "hello\nworld\n\n\n"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "hello\nworld\n")
    }

    func test_trimTrailingBlanks_removes_trailing_whitespace_only_lines() {
        let input = "hello\nworld\n   \n\t\n"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "hello\nworld\n")
    }

    func test_trimTrailingBlanks_preserves_final_newline() {
        let input = "hello\nworld\n"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "hello\nworld\n")
    }

    func test_trimTrailingBlanks_no_final_newline_stays_that_way() {
        let input = "hello\nworld"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "hello\nworld")
    }

    func test_trimTrailingBlanks_preserves_interior_blank_lines() {
        let input = "hello\n\nworld\n\n\n"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "hello\n\nworld\n")
    }

    func test_trimTrailingBlanks_empty_input() {
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(""), "")
    }

    func test_trimTrailingBlanks_all_blank_lines() {
        let input = "\n\n\n"
        XCTAssertEqual(CleanCopyPipeline.trimTrailingBlankLines(input), "")
    }

    // MARK: - Pass 4: Prompt Detection

    func test_stripPrompts_dollar_sign_multiline_majority() {
        let input = "$ ls\n$ cd foo\n$ pwd\noutput\n$ echo hi"
        let result = CleanCopyPipeline.stripPrompts(input)
        XCTAssertEqual(result, "ls\ncd foo\npwd\noutput\necho hi")
    }

    func test_stripPrompts_percent_sign() {
        let input = "% ls\n% cd\n% pwd\n% echo"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), "ls\ncd\npwd\necho")
    }

    func test_stripPrompts_hash_sign() {
        let input = "# apt update\n# apt install foo\n# systemctl start bar\n# exit"
        XCTAssertEqual(
            CleanCopyPipeline.stripPrompts(input),
            "apt update\napt install foo\nsystemctl start bar\nexit"
        )
    }

    func test_stripPrompts_does_not_strip_below_threshold_multiline() {
        // Only 1 of 5 lines has prompt — below 60%
        let input = "$ ls\nfoo\nbar\nbaz\nqux"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), input)
    }

    func test_stripPrompts_short_selection_strips_first_line() {
        let input = "$ ls -la"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), "ls -la")
    }

    func test_stripPrompts_short_selection_two_lines() {
        let input = "$ git status\n$ git diff"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), "git status\ngit diff")
    }

    func test_stripPrompts_does_not_strip_dollar_without_space() {
        let input = "$500 is the price"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), input)
    }

    func test_stripPrompts_identity_for_no_prompts() {
        let input = "just regular\ntext here\nno prompts"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), input)
    }

    func test_stripPrompts_chevron_in_markdown_not_stripped_when_minority() {
        // Only 2 of 6 lines have "> " — below threshold
        let input = "Hello\nWorld\nFoo\nBar\n> quote1\n> quote2"
        XCTAssertEqual(CleanCopyPipeline.stripPrompts(input), input)
    }

    func test_stripPrompts_preserves_empty_lines() {
        let input = "$ first\n\n$ second\n\n$ third\n\n$ fourth"
        let result = CleanCopyPipeline.stripPrompts(input)
        XCTAssertEqual(result, "first\n\nsecond\n\nthird\n\nfourth")
    }

    // MARK: - Pass 5: Line Number Prefix Detection

    func test_stripLineNumbers_cat_n_format() {
        let input = "     1\thello\n     2\tworld\n     3\tfoo\n     4\tbar"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "hello\nworld\nfoo\nbar")
    }

    func test_stripLineNumbers_grep_n_format() {
        let input = "1:first match\n5:second match\n12:third match\n20:fourth match"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "first match\nsecond match\nthird match\nfourth match")
    }

    func test_stripLineNumbers_pipe_format() {
        let input = "1| hello\n2| world\n3| foo\n4| bar"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "hello\nworld\nfoo\nbar")
    }

    func test_stripLineNumbers_does_not_strip_below_threshold() {
        // Only 2 of 5 lines have number prefix — below 80%
        let input = "1:match\nhello\nworld\nfoo\nbar"
        XCTAssertEqual(CleanCopyPipeline.stripLineNumberPrefixes(input), input)
    }

    func test_stripLineNumbers_does_not_strip_non_monotonic() {
        let input = "5:fifth\n3:third\n1:first\n2:second\n4:fourth"
        XCTAssertEqual(CleanCopyPipeline.stripLineNumberPrefixes(input), input)
    }

    func test_stripLineNumbers_short_selection_all_must_match() {
        let input = "1:hello\n2:world"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "hello\nworld")
    }

    func test_stripLineNumbers_short_selection_partial_does_not_strip() {
        let input = "1:hello\nno number here"
        XCTAssertEqual(CleanCopyPipeline.stripLineNumberPrefixes(input), input)
    }

    func test_stripLineNumbers_bat_box_drawing_pipe() {
        let input = "47 │ Host *\n48 │ SetEnv TERM=xterm-256color"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "Host *\nSetEnv TERM=xterm-256color")
    }

    func test_stripLineNumbers_bat_format_multiline() {
        let input = " 1 │ func hello() {\n 2 │     print(\"hi\")\n 3 │ }\n 4 │ func bye() {"
        let result = CleanCopyPipeline.stripLineNumberPrefixes(input)
        XCTAssertEqual(result, "func hello() {\n    print(\"hi\")\n}\nfunc bye() {")
    }

    func test_stripLineNumbers_identity_for_no_numbers() {
        let input = "no numbers\njust text\nhere today"
        XCTAssertEqual(CleanCopyPipeline.stripLineNumberPrefixes(input), input)
    }

    // MARK: - Pass 6: Common-Prefix Dedent

    func test_dedent_strips_common_4_space_indent() {
        let input = "    hello\n    world\n    foo"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), "hello\nworld\nfoo")
    }

    func test_dedent_preserves_relative_indentation() {
        let input = "    hello\n        nested\n    back"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), "hello\n    nested\nback")
    }

    func test_dedent_ignores_empty_lines_for_minimum() {
        let input = "    hello\n\n    world"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), "hello\n\nworld")
    }

    func test_dedent_handles_tabs() {
        let input = "\t\thello\n\t\tworld"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), "hello\nworld")
    }

    func test_dedent_no_common_indent() {
        let input = "hello\n  world"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), input)
    }

    func test_dedent_single_line() {
        let input = "    indented"
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(input), "indented")
    }

    func test_dedent_empty_input() {
        XCTAssertEqual(CleanCopyPipeline.dedentCommonPrefix(""), "")
    }

    func test_dedent_whitespace_only_lines_not_dedented() {
        let input = "    hello\n  \n    world"
        let result = CleanCopyPipeline.dedentCommonPrefix(input)
        XCTAssertEqual(result, "hello\n  \nworld")
    }

    // MARK: - Pipeline Composition

    func test_pipeline_cleans_terminal_output_with_multiple_artifacts() {
        let input = "\u{1B}[32m$ ls -la   \u{1B}[0m\n\u{1B}[32m$ pwd   \u{1B}[0m\n\n"
        let result = CleanCopyPipeline.clean(input)
        // Final \n preserved because original was newline-terminated
        XCTAssertEqual(result.text, "ls -la\npwd\n")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_cleans_cat_n_output_with_indent() {
        let input = "     1\t    func hello() {\n     2\t        print(\"hi\")\n     3\t    }\n     4\t    func bye() {"
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "func hello() {\n    print(\"hi\")\n}\nfunc bye() {")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_wasModified_false_for_clean_input() {
        let input = "already clean\nno artifacts"
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(result.wasModified)
    }

    func test_pipeline_empty_string() {
        let result = CleanCopyPipeline.clean("")
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.wasModified)
    }

    func test_pipeline_single_line_with_trailing_whitespace() {
        let result = CleanCopyPipeline.clean("hello   ")
        XCTAssertEqual(result.text, "hello")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_unicode_content_preserved() {
        let input = "    こんにちは\n    世界"
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "こんにちは\n世界")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_mixed_tabs_and_spaces() {
        let input = "\t\thello   \n\t\tworld\t\t"
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "hello\nworld")
        XCTAssertTrue(result.wasModified)
    }
}
