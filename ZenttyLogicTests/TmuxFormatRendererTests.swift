import XCTest
@testable import Zentty

final class TmuxFormatRendererTests: XCTestCase {
    func test_substitutes_simple_variable() {
        let result = TmuxFormatRenderer.render(
            "#{pane_id}",
            context: ["pane_id": "%abc"]
        )
        XCTAssertEqual(result, "%abc")
    }

    func test_returns_empty_for_unbound_variable() {
        let result = TmuxFormatRenderer.render(
            "#{pane_id}",
            context: [:]
        )
        XCTAssertEqual(result, "")
    }

    func test_passes_literal_text_through() {
        let result = TmuxFormatRenderer.render(
            "id=#{pane_id} width=#{pane_width}",
            context: ["pane_id": "%abc", "pane_width": "120"]
        )
        XCTAssertEqual(result, "id=%abc width=120")
    }

    func test_double_hash_escapes_to_literal_hash() {
        let result = TmuxFormatRenderer.render(
            "## not a format ## marker",
            context: [:]
        )
        XCTAssertEqual(result, "# not a format # marker")
    }

    func test_lone_hash_passes_through() {
        let result = TmuxFormatRenderer.render(
            "no-format-here#",
            context: [:]
        )
        XCTAssertEqual(result, "no-format-here#")
    }

    func test_conditional_picks_when_true_for_non_empty_value() {
        let result = TmuxFormatRenderer.render(
            "#{?pane_active,active,inactive}",
            context: ["pane_active": "1"]
        )
        XCTAssertEqual(result, "active")
    }

    func test_conditional_picks_when_false_for_empty_value() {
        let result = TmuxFormatRenderer.render(
            "#{?pane_active,active,inactive}",
            context: ["pane_active": ""]
        )
        XCTAssertEqual(result, "inactive")
    }

    func test_conditional_picks_when_false_for_unbound_value() {
        let result = TmuxFormatRenderer.render(
            "#{?pane_active,active,inactive}",
            context: [:]
        )
        XCTAssertEqual(result, "inactive")
    }

    func test_renders_typical_list_panes_format() {
        // Approximation of what Claude Code's `tmux list-panes -F` template looks like.
        let template = "#{pane_id} #{pane_index} #{pane_width}x#{pane_height} #{?pane_active,*,-}"
        let context = [
            "pane_id": "%leader",
            "pane_index": "0",
            "pane_width": "100",
            "pane_height": "40",
            "pane_active": "1",
        ]
        XCTAssertEqual(
            TmuxFormatRenderer.render(template, context: context),
            "%leader 0 100x40 *"
        )
    }

    func test_handles_nested_braces_in_branches() {
        // tmux does not escape commas inside branches but does balance braces.
        let result = TmuxFormatRenderer.render(
            "#{?has_value,{wrapped: #{value}},none}",
            context: ["has_value": "1", "value": "v"]
        )
        XCTAssertEqual(result, "{wrapped: v}")
    }

    func test_unterminated_brace_substitutes_what_was_collected() {
        // Defensive: don't crash on malformed input. We treat the
        // accumulated body as a variable name and look it up.
        let result = TmuxFormatRenderer.render(
            "before #{pane_id",
            context: ["pane_id": "%abc"]
        )
        XCTAssertEqual(result, "before %abc")
    }

    func test_short_token_S_resolves_to_session_name() {
        let result = TmuxFormatRenderer.render(
            "#S",
            context: ["session_name": "zentty"]
        )
        XCTAssertEqual(result, "zentty")
    }

    func test_short_token_I_resolves_to_window_index() {
        let result = TmuxFormatRenderer.render(
            "#I",
            context: ["window_index": "4"]
        )
        XCTAssertEqual(result, "4")
    }

    func test_short_token_P_resolves_to_pane_index() {
        let result = TmuxFormatRenderer.render(
            "#P",
            context: ["pane_index": "1"]
        )
        XCTAssertEqual(result, "1")
    }

    func test_short_tokens_combine_in_display_message_probe_template() {
        // Reproduces Claude Code's probe of the current pane: `#S:#I.#P`.
        // Before short-token support this passed through verbatim, leaving
        // the harness unable to identify the current pane/window.
        let result = TmuxFormatRenderer.render(
            "#S:#I.#P",
            context: [
                "session_name": "zentty",
                "window_index": "4",
                "pane_index": "1",
            ]
        )
        XCTAssertEqual(result, "zentty:4.1")
    }

    func test_short_token_resolves_to_empty_when_long_name_unbound() {
        let result = TmuxFormatRenderer.render(
            "[#S]",
            context: [:]
        )
        XCTAssertEqual(result, "[]")
    }

    func test_unknown_short_token_passes_through_unchanged() {
        // Real tmux silently swallows unknown one-character tokens; we
        // preserve the literal so unsupported template fragments are visible
        // for debugging instead of disappearing.
        let result = TmuxFormatRenderer.render(
            "left #X right",
            context: [:]
        )
        XCTAssertEqual(result, "left #X right")
    }

    func test_long_form_still_renders_when_short_token_mapping_exists() {
        // Sanity check: `#{session_name}` must keep working even though `#S`
        // now also resolves to it.
        let result = TmuxFormatRenderer.render(
            "#{session_name}",
            context: ["session_name": "zentty"]
        )
        XCTAssertEqual(result, "zentty")
    }
}
