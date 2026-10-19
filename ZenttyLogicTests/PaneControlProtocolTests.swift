import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Zentty

final class PaneControlProtocolTests: XCTestCase {
    // MARK: - IPC arguments

    func test_send_options_round_trip_through_arguments() throws {
        let options = PaneSendIPCOptions(target: "2", submit: false, paste: true, force: true)
        XCTAssertEqual(options.arguments(), ["--target", "2", "--no-enter", "--paste", "--force"])
        XCTAssertEqual(try PaneSendIPCOptions.parse(arguments: options.arguments()), options)
    }

    func test_send_options_default_to_typing_and_submitting_into_routed_pane() throws {
        let options = try PaneSendIPCOptions.parse(arguments: [])
        XCTAssertNil(options.target)
        XCTAssertTrue(options.submit)
        XCTAssertFalse(options.paste)
        XCTAssertFalse(options.force)
    }

    func test_send_options_reject_unknown_and_incomplete_flags() {
        XCTAssertThrowsError(try PaneSendIPCOptions.parse(arguments: ["--bogus"])) { error in
            XCTAssertEqual(error as? PaneControlIPCError, .unexpectedArgument("--bogus"))
        }
        XCTAssertThrowsError(try PaneSendIPCOptions.parse(arguments: ["--target"])) { error in
            XCTAssertEqual(error as? PaneControlIPCError, .missingValue("--target"))
        }
    }

    func test_send_key_options_round_trip_and_require_keys() throws {
        let options = PaneSendKeyIPCOptions(target: "pn_abc", keys: ["C-c", "Up", "Enter"], force: true)
        XCTAssertEqual(options.arguments().last, "--force")
        XCTAssertEqual(try PaneSendKeyIPCOptions.parse(arguments: options.arguments()), options)
        XCTAssertThrowsError(try PaneSendKeyIPCOptions.parse(arguments: ["--target", "2"])) { error in
            XCTAssertEqual(error as? PaneControlIPCError, .missingKeys)
        }
    }

    func test_send_key_split_target_takes_leading_pane_reference_only_when_keys_follow() {
        XCTAssertEqual(
            PaneSendKeyIPCOptions.splitTarget(["2", "Enter"], hasExplicitPaneSelector: false).target,
            "2"
        )
        XCTAssertEqual(
            PaneSendKeyIPCOptions.splitTarget(["pn_x", "C-c"], hasExplicitPaneSelector: false).keys,
            ["C-c"]
        )
        // A lone digit is a key, not a pane.
        let lone = PaneSendKeyIPCOptions.splitTarget(["1"], hasExplicitPaneSelector: false)
        XCTAssertNil(lone.target)
        XCTAssertEqual(lone.keys, ["1"])
        // With --pane-id the positionals are all keys.
        let explicit = PaneSendKeyIPCOptions.splitTarget(["2", "Enter"], hasExplicitPaneSelector: true)
        XCTAssertNil(explicit.target)
        XCTAssertEqual(explicit.keys, ["2", "Enter"])
        // Key names never look like pane references.
        XCTAssertNil(PaneSendKeyIPCOptions.splitTarget(["Escape", "Enter"], hasExplicitPaneSelector: false).target)
    }

    func test_read_options_round_trip_and_validate_line_count() throws {
        let options = PaneReadIPCOptions(target: "3", lineLimit: 40, includeScrollback: true)
        XCTAssertEqual(try PaneReadIPCOptions.parse(arguments: options.arguments()), options)
        XCTAssertThrowsError(try PaneReadIPCOptions.parse(arguments: ["--lines", "0"])) { error in
            XCTAssertEqual(error as? PaneControlIPCError, .invalidValue("--lines", "0"))
        }
        XCTAssertThrowsError(try PaneReadIPCOptions.parse(arguments: ["--lines", "many"]))
    }

    func test_events_options_round_trip_and_reject_empty_type() throws {
        let options = PaneEventsIPCOptions(filter: PaneEventTypeFilter(patterns: ["agent.phase", "pane"]))
        XCTAssertEqual(options.arguments(), ["--type", "agent.phase", "--type", "pane"])
        XCTAssertEqual(try PaneEventsIPCOptions.parse(arguments: options.arguments()), options)
        XCTAssertThrowsError(try PaneEventsIPCOptions.parse(arguments: ["--type", " "]))
    }

    func test_routing_selectors_are_stripped_but_handler_flags_survive() throws {
        let selectors = try ParsedPaneSelectors.parse(arguments: [
            "--target", "2", "--pane-id", "pn_other", "--pane-token", "tok", "--no-enter",
        ])
        XCTAssertEqual(selectors.paneID, PaneID("pn_other"))
        XCTAssertEqual(selectors.paneToken, "tok")
        XCTAssertEqual(try PaneSendIPCOptions.parse(arguments: selectors.arguments).target, "2")
    }

    // MARK: - Event filter

    func test_event_filter_matches_exact_types_and_families() {
        let filter = PaneEventTypeFilter(patterns: ["agent.phase", "pane", "attention.*"])
        XCTAssertTrue(filter.matches("agent.phase"))
        XCTAssertTrue(filter.matches("pane.created"))
        XCTAssertTrue(filter.matches("attention.cleared"))
        XCTAssertFalse(filter.matches("worklane.created"))
        XCTAssertFalse(filter.matches("panel.created"))
    }

    func test_event_filter_always_passes_stream_notices_and_defaults_to_everything() {
        XCTAssertTrue(PaneEventTypeFilter(patterns: ["agent"]).matches("stream.dropped"))
        XCTAssertTrue(PaneEventTypeFilter().matches("worklane.closed"))
    }

    func test_event_types_must_name_a_known_type_or_family() throws {
        for pattern in ["agent.phase", "pane", "pane.*", "attention", "worklane.activated", "stream.ready"] {
            XCTAssertTrue(PaneEventTypeFilter.isKnownPattern(pattern), pattern)
        }
        for pattern in ["agents.phase", "pan", "pane.create", "*", "agent.phase.x"] {
            XCTAssertFalse(PaneEventTypeFilter.isKnownPattern(pattern), pattern)
        }
        XCTAssertThrowsError(try PaneEventsIPCOptions.parse(arguments: ["--type", "agents.phase"])) { error in
            XCTAssertEqual(error as? PaneControlIPCError, .unknownEventType("agents.phase"))
        }
    }

    // MARK: - Send size

    func test_send_size_counts_json_escaping_not_just_raw_bytes() throws {
        // Raw size is well under the text limit, but every control byte
        // becomes a six-byte `\u00XX` escape on the wire.
        let escapeHeavy = String(repeating: "\u{1b}", count: 60 * 1024)
        XCTAssertLessThan(escapeHeavy.utf8.count, PaneControlIPC.maxSendTextBytes)
        XCTAssertThrowsError(try PaneControlIPC.validateSendSize(text: escapeHeavy, request: sendRequest(escapeHeavy))) { error in
            guard case .textTooLarge(_, let limit)? = error as? PaneControlIPCError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(limit, PaneControlIPC.maxRequestBytes)
        }

        let plain = String(repeating: "a", count: 100 * 1024)
        XCTAssertNoThrow(try PaneControlIPC.validateSendSize(text: plain, request: sendRequest(plain)))

        let oversized = String(repeating: "a", count: PaneControlIPC.maxSendTextBytes + 1)
        XCTAssertThrowsError(try PaneControlIPC.validateSendSize(text: oversized, request: sendRequest(oversized))) { error in
            XCTAssertEqual(
                error as? PaneControlIPCError,
                .textTooLarge(bytes: oversized.utf8.count, limit: PaneControlIPC.maxSendTextBytes)
            )
        }
    }

    private func sendRequest(_ text: String) -> AgentIPCRequest {
        AgentIPCRequest(
            kind: .pane,
            arguments: ["--target", "2"],
            standardInput: text,
            environment: [:],
            expectsResponse: true,
            subcommand: PaneControlIPC.sendSubcommand
        )
    }

    // MARK: - Text helpers

    func test_text_action_escapes_only_backslashes() {
        XCTAssertEqual(TerminalPaneInputEncoding.ghosttyTextAction("echo hi"), "text:echo hi")
        XCTAssertEqual(TerminalPaneInputEncoding.ghosttyTextAction(#"a\nb"#), #"text:a\\nb"#)
        XCTAssertEqual(TerminalPaneInputEncoding.ghosttyTextAction("x:y \"q\""), "text:x:y \"q\"")
    }

    func test_tail_keeps_last_lines_and_trailing_newline() {
        XCTAssertEqual(PaneTextLines.tail("a\nb\nc\n", maxLines: 2), "b\nc\n")
        XCTAssertEqual(PaneTextLines.tail("a\nb\nc", maxLines: 1), "c")
        XCTAssertEqual(PaneTextLines.tail("a\nb", maxLines: 0), "")
    }

    func test_read_result_survives_json_round_trip_in_response() throws {
        let result = AgentIPCResponseResult(paneRead: PaneReadResult(
            paneID: "pn_a",
            worklaneID: "wl_a",
            windowID: "wd_a",
            columns: 120,
            rows: 40,
            includesScrollback: false,
            lineLimit: nil,
            text: "$ ls\n"
        ))
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(AgentIPCResponseResult.self, from: data), result)
    }

    func test_response_without_read_payload_still_decodes() throws {
        let data = Data(#"{"stdout":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentIPCResponseResult.self, from: data)
        XCTAssertNil(decoded.paneRead)
        XCTAssertEqual(decoded.stdout, "x")
    }

    // MARK: - Key events

    func test_named_keys_become_key_presses_with_matching_key_codes() throws {
        let enter = try XCTUnwrap(TerminalPaneInputEncoding.keyEvent(for: .key(.enter, shift: false)))
        XCTAssertEqual(Int(enter.keyCode), kVK_Return)
        XCTAssertEqual(enter.characters, "\r")

        let up = try XCTUnwrap(TerminalPaneInputEncoding.keyEvent(for: .key(.up, shift: true)))
        XCTAssertEqual(Int(up.keyCode), kVK_UpArrow)
        XCTAssertTrue(up.modifierFlags.contains(.shift))
    }

    func test_control_letters_become_control_key_presses() throws {
        let event = try XCTUnwrap(TerminalPaneInputEncoding.keyEvent(for: .control("c")))
        XCTAssertEqual(Int(event.keyCode), kVK_ANSI_C)
        XCTAssertTrue(event.modifierFlags.contains(.control))
        XCTAssertEqual(event.characters, "\u{03}")
        XCTAssertEqual(event.charactersIgnoringModifiers, "c")
    }

    func test_text_strokes_are_typed_not_pressed() {
        XCTAssertNil(TerminalPaneInputEncoding.keyEvent(for: .text("y")))
    }
}
