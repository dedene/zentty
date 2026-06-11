use zentty_terminal::clean_copy::{CleanCopyPipeline, CleanCopyResult};

#[test]
fn clean_copy_strips_ansi_sequences() {
    assert_eq!(
        CleanCopyPipeline::strip_ansi_escapes("\x1b[31mError:\x1b[0m something broke"),
        "Error: something broke"
    );
    assert_eq!(
        CleanCopyPipeline::strip_ansi_escapes("\x1b]0;Terminal Title\x07actual text"),
        "actual text"
    );
    assert_eq!(
        CleanCopyPipeline::strip_ansi_escapes("\x1b[2Jhello\x1b[H"),
        "hello"
    );
}

#[test]
fn clean_copy_trims_trailing_whitespace_and_blank_lines_like_swift() {
    assert_eq!(
        CleanCopyPipeline::trim_trailing_whitespace_per_line("hello   \nworld\t"),
        "hello\nworld"
    );
    assert_eq!(
        CleanCopyPipeline::trim_trailing_blank_lines("hello\nworld\n   \n\t\n"),
        "hello\nworld\n"
    );
    assert_eq!(CleanCopyPipeline::trim_trailing_blank_lines("\n\n\n"), "");
}

#[test]
fn clean_copy_strips_shell_prompts_by_strict_majority() {
    assert_eq!(
        CleanCopyPipeline::strip_prompts("$ ls\n$ cd\n$ pwd\nout1\nout2"),
        "ls\ncd\npwd\nout1\nout2"
    );
    assert_eq!(
        CleanCopyPipeline::strip_prompts("$ ls\n$ cd\n$ pwd\nout1\nout2\nout3"),
        "$ ls\n$ cd\n$ pwd\nout1\nout2\nout3"
    );
    assert_eq!(
        CleanCopyPipeline::strip_prompts("% ls\n% cd\n% pwd\n% echo"),
        "% ls\n% cd\n% pwd\n% echo"
    );
}

#[test]
fn clean_copy_strips_line_number_prefixes_when_consistent_and_monotonic() {
    assert_eq!(
        CleanCopyPipeline::strip_line_number_prefixes(
            "     1\thello\n     2\tworld\n     3\tfoo\n     4\tbar"
        ),
        "hello\nworld\nfoo\nbar"
    );
    assert_eq!(
        CleanCopyPipeline::strip_line_number_prefixes(
            " 1 | func hello() {\n 2 |     print(\"hi\")\n 3 | }\n 4 | func bye() {"
        ),
        "func hello() {\n    print(\"hi\")\n}\nfunc bye() {"
    );
    assert_eq!(
        CleanCopyPipeline::strip_line_number_prefixes("5:fifth\n3:third\n1:first\n2:second"),
        "5:fifth\n3:third\n1:first\n2:second"
    );
}

#[test]
fn clean_copy_strips_box_drawing_artifacts_without_emptying_decorations() {
    assert_eq!(
        CleanCopyPipeline::strip_box_drawing_artifacts("curl -I https://example.com | │ head -n 5"),
        Some("curl -I https://example.com | head -n 5".to_string())
    );
    assert_eq!(
        CleanCopyPipeline::strip_box_drawing_artifacts("┌──────┐\n│ hello │\n└──────┘"),
        Some("hello".to_string())
    );
    assert_eq!(
        CleanCopyPipeline::strip_box_drawing_artifacts("──────"),
        None
    );
}

#[test]
fn clean_copy_dedents_common_prefix() {
    assert_eq!(
        CleanCopyPipeline::dedent_common_prefix("    hello\n        nested\n    back"),
        "hello\n    nested\nback"
    );
    assert_eq!(
        CleanCopyPipeline::dedent_common_prefix("    hello\n  \n    world"),
        "hello\n  \nworld"
    );
}

#[test]
fn clean_copy_reflows_single_agent_prompt_selection() {
    let input = "› open /tmp/scan-qr-f1cc4328-eb1d-4a3c-9bd2-\n  f1a4ccda5f6a.png";

    assert_eq!(
        CleanCopyPipeline::strip_agent_prompt_selection(input),
        Some("open /tmp/scan-qr-f1cc4328-eb1d-4a3c-9bd2-f1a4ccda5f6a.png".to_string())
    );
    assert_eq!(
        CleanCopyPipeline::strip_agent_prompt_selection("• one\n• two"),
        None
    );
}

#[test]
fn clean_copy_policy_respects_auto_clean_and_copy_raw_suppression() {
    assert!(CleanCopyPipeline::should_clean_terminal_copy_action(
        true, false
    ));
    assert!(!CleanCopyPipeline::should_clean_terminal_copy_action(
        true, true
    ));
    assert!(!CleanCopyPipeline::should_clean_terminal_copy_action(
        false, false
    ));
}

#[test]
fn clean_copy_pipeline_composes_passes_and_tracks_modification() {
    assert_eq!(
        CleanCopyPipeline::clean("\x1b[32m$ ls -la   \x1b[0m\n\x1b[32m$ pwd   \x1b[0m\n\n"),
        CleanCopyResult {
            text: "ls -la\npwd\n".to_string(),
            was_modified: true,
        }
    );
    assert_eq!(
        CleanCopyPipeline::clean("already clean\nno artifacts"),
        CleanCopyResult {
            text: "already clean\nno artifacts".to_string(),
            was_modified: false,
        }
    );
    assert_eq!(
        CleanCopyPipeline::clean("──────"),
        CleanCopyResult {
            text: "──────".to_string(),
            was_modified: false,
        }
    );
}
