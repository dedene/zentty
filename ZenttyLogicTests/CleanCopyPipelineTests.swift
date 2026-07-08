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
        let result = (CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input)
        XCTAssertEqual(result, "ls\ncd foo\npwd\noutput\necho hi")
    }

    func test_stripPrompts_does_not_strip_percent_prefix() {
        // % is no longer a candidate prompt — too many false positives in prose
        // (e.g. "10% done", "5% used"). zsh users who genuinely paste % prompts
        // pay a small tax in exchange for far fewer false strips.
        let input = "% ls\n% cd\n% pwd\n% echo"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_hash_sign() {
        let input = "# apt update\n# apt install foo\n# systemctl start bar\n# exit"
        XCTAssertEqual(
            (CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input),
            "apt update\napt install foo\nsystemctl start bar\nexit"
        )
    }

    func test_stripPrompts_does_not_strip_below_threshold_multiline() {
        // Only 1 of 5 lines has prompt — below 60%
        let input = "$ ls\nfoo\nbar\nbaz\nqux"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_short_selection_strips_first_line() {
        let input = "$ ls -la"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), "ls -la")
    }

    func test_stripPrompts_short_selection_two_lines() {
        let input = "$ git status\n$ git diff"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), "git status\ngit diff")
    }

    func test_stripPrompts_does_not_strip_dollar_without_space() {
        let input = "$500 is the price"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_does_not_strip_dollar_variable_without_space() {
        let input = "$HOME is set"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_does_not_strip_dollar_path_without_space() {
        let input = "$PATH"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_does_not_strip_hash_shebang_without_space() {
        let input = "#!/bin/bash"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_does_not_strip_hash_define_without_space() {
        let input = "#define MAX 10"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_does_not_strip_single_line_markdown_heading() {
        let input = "# Title"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_strips_single_line_hash_command() {
        let input = "# apt update"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), "apt update")
    }

    func test_stripPrompts_identity_for_no_prompts() {
        let input = "just regular\ntext here\nno prompts"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_chevron_in_markdown_not_stripped_when_minority() {
        // Only 2 of 6 lines have "> " — below threshold
        let input = "Hello\nWorld\nFoo\nBar\n> quote1\n> quote2"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_preserves_empty_lines() {
        let input = "$ first\n\n$ second\n\n$ third\n\n$ fourth"
        let result = (CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input)
        XCTAssertEqual(result, "first\n\nsecond\n\nthird\n\nfourth")
    }

    // MARK: - Copy Cleaning Policy

    func test_shouldCleanTerminalCopyAction_is_false_for_copy_raw_suppression() {
        XCTAssertFalse(
            CleanCopyPipeline.shouldCleanTerminalCopyAction(
                isAutoCleanEnabled: true,
                suppressCallbackCleaning: true
            )
        )
    }

    func test_shouldCleanTerminalCopyAction_is_true_for_auto_clean_copy() {
        XCTAssertTrue(
            CleanCopyPipeline.shouldCleanTerminalCopyAction(
                isAutoCleanEnabled: true,
                suppressCallbackCleaning: false
            )
        )
    }

    func test_shouldCleanTerminalCopyAction_is_false_when_auto_clean_is_disabled() {
        XCTAssertFalse(
            CleanCopyPipeline.shouldCleanTerminalCopyAction(
                isAutoCleanEnabled: false,
                suppressCallbackCleaning: false
            )
        )
    }

    // MARK: - Agent Prompt Cleanup

    func test_stripAgentPromptSelection_unwraps_chevron_prompt() {
        let input = """
        › i want to add support from predefined task runners, similar to existing terminal task runner configs, but i'd like
          to support also VSCode tasks or Taskfiles (from https://taskfile.dev)

          first research what the most popular terminal task runners are and what vscode is doing
          after that lets usete the $shaping skill and interview me in detail
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "i want to add support from predefined task runners, similar to existing terminal task runner configs, but i'd like to support also VSCode tasks or Taskfiles (from https://taskfile.dev)\n\nfirst research what the most popular terminal task runners are and what vscode is doing after that lets usete the $shaping skill and interview me in detail"
        )
    }

    func test_stripAgentPromptSelection_strips_single_line_heavy_chevron_prompt() {
        XCTAssertEqual(CleanCopyPipeline.stripAgentPromptSelection("❯ /commit"), "/commit")
    }

    func test_stripAgentPromptSelection_uses_content_after_rule() {
        let input = """
        ❯ /my-skill:run-task "Analyze the dataset
          for patterns and report findings"
        ────────────────────────────────────────
        /my-skill:run-task "Analyze the dataset
          for patterns and report findings"
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "/my-skill:run-task \"Analyze the dataset for patterns and report findings\""
        )
    }

    func test_stripAgentPromptSelection_preserves_multiple_paragraphs_without_padding() {
        let input = """
        › first paragraph wraps
          onto a second line

          second paragraph wraps
          onto another line
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "first paragraph wraps onto a second line\n\nsecond paragraph wraps onto another line"
        )
    }

    func test_stripAgentPromptSelection_preserves_repeated_blank_lines_without_padding() {
        let input = """
        › first paragraph


          second paragraph
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "first paragraph\n\n\nsecond paragraph"
        )
    }

    func test_stripAgentPromptSelection_does_not_flatten_source_code() {
        let input = """
        › func hello() {
              print("world")
          }
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_source_code_without_braces() {
        let input = """
        › let value = makeValue()
          await render(value)
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_lists() {
        let input = """
        › - first item
          - second item
          - third item
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_structured_data() {
        let input = """
        › {
            "name": "Zentty",
            "enabled": true
          }
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_shell_transcript() {
        let input = """
        › $ git status
          On branch main
          $ git diff
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    // MARK: - Bullet / Marker Agent Output

    func test_pipeline_cleans_bullet_led_agent_output() {
        // Peter's example: a • bullet message with an indented continuation paragraph.
        let input = """
        • Hi Peter — I'll keep this review tight and focus only on issues worth fixing before merge.

          Using the code-review skill because this is a branch diff review.
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "Hi Peter — I'll keep this review tight and focus only on issues worth fixing before merge."
                + "\n\nUsing the code-review skill because this is a branch diff review."
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_stripAgentPromptSelection_reflows_bullet_wrapped_paragraph() {
        let input = """
        • Hi Peter — I'll keep this review
          tight and focus only on issues.

          Using the code-review skill.
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Hi Peter — I'll keep this review tight and focus only on issues."
                + "\n\nUsing the code-review skill."
        )
    }

    func test_pipeline_reflows_separated_bullet_agent_messages_preserving_markers() {
        let input = """
        • The push reached GitHub (main -> main), but sandboxing blocked Git from updating the local origin/main tracking ref afterward. I’m verifying the remote
         and then refreshing the local tracking ref with escalation so the repo state is sane.


        • Remote main is at 7ff742d, so the push itself landed. The local tracking ref is stale because of the lock error; I’m fetching with Git metadata write
         access to update it.
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "• The push reached GitHub (main -> main), but sandboxing blocked Git from updating the local origin/main tracking ref afterward. I’m verifying the remote and then refreshing the local tracking ref with escalation so the repo state is sane."
                + "\n\n• Remote main is at 7ff742d, so the push itself landed. The local tracking ref is stale because of the lock error; I’m fetching with Git metadata write access to update it."
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_stripAgentPromptSelection_reflows_separated_bullets_without_outer_padding() {
        let input = """

        • First status wraps
          onto another line.

        • Second status wraps
          too.

        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "• First status wraps onto another line.\n\n• Second status wraps too."
        )
    }

    func test_pipeline_reflows_plain_agent_copy_without_marker() {
        let input = """
        Clean Copy now handles blank-separated • assistant/status blocks before the existing multi-marker bailout. It preserves the bullet markers, reflows
        wrapped continuation lines inside each block, normalizes the gap to one blank line, and still bails for source code, structured data, shell transcripts,
        compact lists, and stacked non-bullet markers. See Zentty/Terminal/CleanCopyPipeline.swift:180.

        Added regression coverage for your screenshot shape plus outer-padding cleanup in ZenttyLogicTests/CleanCopyPipelineTests.swift:364.

        Verification:

        - New tests failed first for the expected reason: original wrapped text / nil.
        - New tests pass after the fix.
        - CleanCopyPipelineTests: 106 tests, 0 failures.
        - git diff --check: clean.
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "Clean Copy now handles blank-separated • assistant/status blocks before the existing multi-marker bailout. It preserves the bullet markers, reflows wrapped continuation lines inside each block, normalizes the gap to one blank line, and still bails for source code, structured data, shell transcripts, compact lists, and stacked non-bullet markers. See Zentty/Terminal/CleanCopyPipeline.swift:180."
                + "\n\nAdded regression coverage for your screenshot shape plus outer-padding cleanup in ZenttyLogicTests/CleanCopyPipelineTests.swift:364."
                + "\n\nVerification:"
                + "\n\n- New tests failed first for the expected reason: original wrapped text / nil."
                + "\n- New tests pass after the fix."
                + "\n- CleanCopyPipelineTests: 106 tests, 0 failures."
                + "\n- git diff --check: clean."
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_reflows_wrapped_chevron_quote_without_embedded_prompt_marker() {
        let input = """
        > “Your plan includes generous resource capacity. Most customers never need to think about it. If your usage grows materially, we’ll warn you before
          > anything changes.”
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "“Your plan includes generous resource capacity. Most customers never need to think about it. If your usage grows materially, we’ll warn you before anything changes.”"
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_preserves_compact_command_block_line_breaks() {
        let input = """
          git status --short --branch
          pnpm install --frozen-lockfile
          pnpm run pack:check
          node dist/cli.js --help
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            """
            git status --short --branch
            pnpm install --frozen-lockfile
            pnpm run pack:check
            node dist/cli.js --help
            """
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_trims_padded_short_rows_without_reflowing_them() {
        let input = "git status --short --branch        \npnpm install --frozen-lockfile       \nnode dist/cli.js --help              "

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "git status --short --branch\npnpm install --frozen-lockfile\nnode dist/cli.js --help"
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_trims_padded_short_prose_rows_without_reflowing_them() {
        let input = "Status: done       \nOwner: peter      \nNext step is review       \nThis is a longer prose line that is intentionally past sixty characters."

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "Status: done\nOwner: peter\nNext step is review\nThis is a longer prose line that is intentionally past sixty characters."
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_reflows_wrapped_single_command_with_continuation_lines() {
        let input = """
        curl https://example.com/api \\
          --fail \\
          --silent
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "curl https://example.com/api --fail --silent")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_preserves_env_and_script_command_block_line_breaks() {
        let input = """
        RAILS_ENV=test bundle exec rspec spec/models/drops/channel_collection_proxy_spec.rb:311
        scripts/test-on-virtual-display -only-testing:ZenttyLogicTests/CleanCopyPipelineTests
        cargo test --all-targets --all-features
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(result.wasModified)
    }

    func test_pipeline_preserves_list_items_inside_marker_led_agent_copy() {
        let input = """
        • Implemented.

        Verification:

        - New tests failed first for the expected reason: original wrapped text / nil.
        - New tests pass after the fix.
        - CleanCopyPipelineTests: 106 tests, 0 failures.
        - git diff --check: clean.
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "Implemented."
                + "\n\nVerification:"
                + "\n\n- New tests failed first for the expected reason: original wrapped text / nil."
                + "\n- New tests pass after the fix."
                + "\n- CleanCopyPipelineTests: 106 tests, 0 failures."
                + "\n- git diff --check: clean."
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_does_not_reflow_plain_markdown_list() {
        let input = """
        Verification:

        - first item
        - second item
        - third item
        """

        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, input)
        XCTAssertFalse(result.wasModified)
    }

    func test_stripAgentPromptSelection_cleans_record_circle_message() {
        // ⏺ (U+23FA) is Claude Code's message/tool-line marker.
        let input = """
        ⏺ Ran the analysis and found two
          issues worth fixing.
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Ran the analysis and found two issues worth fixing."
        )
    }

    func test_stripAgentPromptSelection_cleans_filled_circle_message() {
        // ● (U+25CF) is used as a leading status/message glyph by some agents.
        let input = """
        ● Models available and ready
          to take the next task.
        """

        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Models available and ready to take the next task."
        )
    }

    func test_stripAgentPromptSelection_does_not_flatten_bullet_list() {
        let input = """
        • first item
        • second item
        • third item
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_short_wrapped_bullet_list() {
        // The regression the multi-marker guard exists for: a 2-item • list whose first item
        // wraps. Stripping the first bullet would undercount the list, so the older post-strip
        // isLikelyList check alone would have reflowed these into one run.
        let input = """
        • First item that wraps onto
          a second line
        • Second item
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_stacked_tool_calls() {
        // Two ⏺ tool-call lines are separate messages, not one wrapped paragraph.
        let input = """
        ⏺ Read(CleanCopyPipeline.swift)
        ⏺ Edit(CleanCopyPipeline.swift)
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_does_not_flatten_filled_circle_list() {
        let input = """
        ● one
        ● two
        ● three
        """

        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    func test_stripAgentPromptSelection_strips_single_bullet_line() {
        // Accepted trade-off: a lone single-line bullet loses its marker, consistent with how
        // › / ❯ treat single lines. Rare in terminal pastes.
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection("• just one thing"),
            "just one thing"
        )
    }

    // MARK: - Box Drawing Cleanup

    func test_stripBoxDrawingArtifacts_removes_pipe_decoration() {
        XCTAssertEqual(
            CleanCopyPipeline.stripBoxDrawingArtifacts("curl -I https://example.com | │ head -n 5"),
            "curl -I https://example.com | head -n 5"
        )
    }

    func test_stripBoxDrawingArtifacts_repairs_wrapped_path_separator() {
        let input = "curl -I https://github.com/zenjoy/zentty/releases/ │ download/app.zip | head -n 5"
        XCTAssertEqual(
            CleanCopyPipeline.stripBoxDrawingArtifacts(input),
            "curl -I https://github.com/zenjoy/zentty/releases/download/app.zip | head -n 5"
        )
    }

    func test_stripBoxDrawingArtifacts_identity_without_box_artifacts() {
        XCTAssertNil(CleanCopyPipeline.stripBoxDrawingArtifacts("curl -I https://example.com | head -n 5"))
    }

    func test_stripBoxDrawingArtifacts_preserves_final_newline() {
        XCTAssertEqual(CleanCopyPipeline.stripBoxDrawingArtifacts("│ hello\n"), "hello\n")
    }

    func test_stripBoxDrawingArtifacts_does_not_strip_single_box_diagram_line() {
        let input = """
        keep
        │ legitimate diagram line
        done
        """

        XCTAssertNil(CleanCopyPipeline.stripBoxDrawingArtifacts(input))
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

    func test_stripLineNumbers_does_not_strip_ipv6_record() {
        let input = "2400:52e0:fff0::1"
        XCTAssertEqual(CleanCopyPipeline.stripLineNumberPrefixes(input), input)
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

    func test_pipeline_preserves_ipv6_record() {
        let input = "2400:52e0:fff0::1"
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

    func test_pipeline_cleans_agent_prompt_selection() {
        let input = """
        › i want to add support from predefined task runners, similar to common terminal task runner configs, but i'd like
          to support also VSCode tasks or Taskfiles
        """
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(
            result.text,
            "i want to add support from predefined task runners, similar to common terminal task runner configs, but i'd like to support also VSCode tasks or Taskfiles"
        )
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_cleans_box_drawing_artifacts() {
        let input = "curl -I https://example.com | │ head -n 5"
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "curl -I https://example.com | head -n 5")
        XCTAssertTrue(result.wasModified)
    }

    // MARK: - Strict-Majority Prompt Threshold

    func test_stripPrompts_below_strict_majority_does_not_strip() {
        // 3 of 6 lines have "$ " — needs >= n/2+1 = 4 to strip
        let input = "$ ls\n$ cd\n$ pwd\nout1\nout2\nout3"
        XCTAssertEqual((CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input), input)
    }

    func test_stripPrompts_at_strict_majority_strips() {
        // 4 of 6 lines have "$ " — meets n/2+1 = 4
        let input = "$ ls\n$ cd\n$ pwd\n$ echo\nout1\nout2"
        XCTAssertEqual(
            (CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input),
            "ls\ncd\npwd\necho\nout1\nout2"
        )
    }

    func test_stripPrompts_n5_three_matches_strips() {
        // n=5, 3 matches: strict-majority threshold (n/2+1 = 3) — strips.
        // The prior >0.6 continuous threshold would have required 4 here;
        // this test pins the looser-for-odd-n behavior down.
        let input = "$ ls\n$ cd\n$ pwd\nout1\nout2"
        XCTAssertEqual(
            (CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input),
            "ls\ncd\npwd\nout1\nout2"
        )
    }

    func test_stripPrompts_n5_three_blockquote_lines_not_stripped() {
        // Smart prompt strip only handles $ and # — blockquote `> ` is preserved.
        let input = "> quoted one\n> quoted two\n> quoted three\nplain four\nplain five"
        XCTAssertEqual(
            CleanCopyPipeline.stripSmartPromptPrefixes(input) ?? input,
            input
        )
    }

    // MARK: - Agent Prompt Rule Detection

    func test_stripAgentPromptSelection_ignores_ascii_dash_rule() {
        // A plain "----------" run is a markdown HR, not an agent rule separator.
        // Earlier behavior treated it as a rule and discarded the content above it.
        let input = """
        › Here is text above
        ----------
        And text below the rule
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Here is text above ---------- And text below the rule"
        )
    }

    func test_stripAgentPromptSelection_skips_reflow_over_60_lines() {
        // Synthetic 70 non-empty lines under a chevron — safety valve returns nil.
        let body = Array(repeating: "more content here", count: 70).joined(separator: "\n")
        let input = "› first line\n" + body
        XCTAssertNil(CleanCopyPipeline.stripAgentPromptSelection(input))
    }

    // MARK: - Token-Preserving Flatten

    func test_stripAgentPromptSelection_preserves_hyphen_wrapped_token() {
        let input = """
        › open /tmp/scan-qr-f1cc4328-eb1d-4a3c-9bd2-
          f1a4ccda5f6a.png
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "open /tmp/scan-qr-f1cc4328-eb1d-4a3c-9bd2-f1a4ccda5f6a.png"
        )
    }

    func test_stripAgentPromptSelection_rejoins_capitalized_identifier() {
        let input = """
        › export N
          ODE_PATH=/usr/bin
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "export NODE_PATH=/usr/bin"
        )
    }

    func test_stripAgentPromptSelection_does_not_fuse_standalone_capitals() {
        // A single uppercase word at a wrap boundary must NOT fuse with the next
        // line's leading capital. The rejoin rule requires the second token to be
        // 2+ identifier chars, so split identifiers (N -> ODE_PATH) still join
        // while two real words stay separated.
        let input = """
        › Grade A
          B students passed
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Grade A B students passed"
        )
    }

    func test_stripAgentPromptSelection_preserves_space_after_period() {
        // Sentence-boundary "." must NOT fuse with the next-line capital. The
        // capital regex's LHS class excludes "." for this reason — the newline
        // has to survive to the "\n+ -> ' '" pass so a space lands between sentences.
        let input = """
        › Here is the answer.
          Here is more context.
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "Here is the answer. Here is more context."
        )
    }

    func test_stripAgentPromptSelection_rejoins_path_segment() {
        let input = """
        › open ~/Library/
          Application Support/Zentty
        """
        XCTAssertEqual(
            CleanCopyPipeline.stripAgentPromptSelection(input),
            "open ~/Library/Application Support/Zentty"
        )
    }

    // MARK: - Horizontal Box Drawing

    func test_stripBoxDrawingArtifacts_removes_full_border_box() {
        let input = "┌──────┐\n│ hello │\n└──────┘"
        XCTAssertEqual(CleanCopyPipeline.stripBoxDrawingArtifacts(input), "hello")
    }

    func test_stripBoxDrawingArtifacts_drops_internal_horizontal_separator() {
        let input = "above\n──────\nbelow"
        XCTAssertEqual(CleanCopyPipeline.stripBoxDrawingArtifacts(input), "above\nbelow")
    }

    func test_stripBoxDrawingArtifacts_handles_rounded_corner_panel() {
        let input = "╭──────╮\n│ hello │\n╰──────╯"
        XCTAssertEqual(CleanCopyPipeline.stripBoxDrawingArtifacts(input), "hello")
    }

    func test_stripBoxDrawingArtifacts_preserves_em_dash() {
        // U+2014 em-dash is NOT a box-drawing character; prose stays intact.
        XCTAssertNil(CleanCopyPipeline.stripBoxDrawingArtifacts("em — dash — usage"))
    }

    func test_stripBoxDrawingArtifacts_lone_separator_returns_nil() {
        // A selection that is nothing but a divider has no real content to clean —
        // returning nil keeps the original on the clipboard instead of emptying it.
        XCTAssertNil(CleanCopyPipeline.stripBoxDrawingArtifacts("──────"))
    }

    func test_pipeline_lone_separator_is_unmodified() {
        let result = CleanCopyPipeline.clean("──────")
        XCTAssertEqual(result.text, "──────")
        XCTAssertFalse(result.wasModified)
    }

    // MARK: - End-to-End Panel

    func test_pipeline_strips_full_claude_code_panel() {
        let input = """
        ╭──────────────────────────────────╮
        │   Hello, this is the message.    │
        ╰──────────────────────────────────╯
        """
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "Hello, this is the message.")
        XCTAssertTrue(result.wasModified)
    }

    func test_pipeline_strips_double_line_panel() {
        // ║ (U+2551) is the double-line vertical; needs to be in boxDrawingCharacterClass
        // so the middle line gets its leading/trailing decoration stripped end-to-end.
        let input = """
        ╔══════════════════╗
        ║   Hello, world.   ║
        ╚══════════════════╝
        """
        let result = CleanCopyPipeline.clean(input)
        XCTAssertEqual(result.text, "Hello, world.")
        XCTAssertTrue(result.wasModified)
    }
}
