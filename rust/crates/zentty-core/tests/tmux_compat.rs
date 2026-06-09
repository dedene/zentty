use zentty_core::tmux::{
    TmuxCompatArguments, TmuxWaitAction, capture_pane_options, launch_command_from_send_keys_text,
    send_keys_text, shell_wrapped_ghostty_command, show_options_stdout, tail_terminal_lines,
    wait_for_action,
};

#[test]
fn display_template_uses_positional_format_after_print_flag() {
    let parsed = TmuxCompatArguments::parse(
        ["-t", "%pn_leader", "-p", "#{session_name}:#{window_index}"],
        ["-F", "-t"],
        ["-p"],
    );

    assert_eq!(parsed.value("-t"), Some("%pn_leader"));
    assert!(parsed.has_flag("-p"));
    assert_eq!(
        parsed.display_template(),
        Some("#{session_name}:#{window_index}".to_string())
    );
}

#[test]
fn parse_supports_clustered_boolean_and_value_flags() {
    let parsed =
        TmuxCompatArguments::parse(["-dPh", "-F", "#{pane_id}"], ["-F"], ["-d", "-P", "-h"]);

    assert!(parsed.has_flag("-d"));
    assert!(parsed.has_flag("-P"));
    assert!(parsed.has_flag("-h"));
    assert_eq!(parsed.value("-F"), Some("#{pane_id}"));

    let parsed = TmuxCompatArguments::parse(["-l70%", "-P"], ["-l"], ["-P"]);
    assert_eq!(parsed.value("-l"), Some("70%"));
    assert!(parsed.has_flag("-P"));
}

#[test]
fn send_keys_translates_enter_and_literal_mode_preserves_special_key_names() {
    assert_eq!(
        send_keys_text(["-t", "%pane", "claude", "Enter"], None),
        "claude\r"
    );
    assert_eq!(
        send_keys_text(["-l", "-t", "%pane", "claude", "Enter"], None),
        "claude Enter"
    );
}

#[test]
fn launch_command_requires_single_trailing_enter() {
    assert_eq!(
        launch_command_from_send_keys_text(
            "cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate\r"
        ),
        Some("cd /tmp/project && env CLAUDECODE=1 claude --agent-id teammate".to_string())
    );
    assert_eq!(launch_command_from_send_keys_text("echo hello"), None);
    assert_eq!(launch_command_from_send_keys_text("\r"), None);
    assert_eq!(launch_command_from_send_keys_text("echo hello\rmore"), None);
}

#[test]
fn shell_wrapped_ghostty_command_runs_launch_text_through_shell() {
    assert_eq!(
        shell_wrapped_ghostty_command("cd /tmp/a b && env NAME='x' claude", Some("/bin/zsh")),
        Some("'/bin/zsh' -lic 'cd /tmp/a b && env NAME='\"'\"'x'\"'\"' claude'".to_string())
    );
}

#[test]
fn capture_wait_show_and_tail_helpers_match_swift_behavior() {
    let options = capture_pane_options(["-p", "-J", "-S", "-20", "-t", "%pane"]);
    assert_eq!(options.target.as_deref(), Some("%pane"));
    assert!(options.print);
    assert_eq!(options.line_limit, Some(20));
    assert!(options.include_scrollback);

    assert_eq!(
        wait_for_action(["-S", "agent-ready"]),
        TmuxWaitAction::Signal("agent-ready".to_string())
    );
    assert_eq!(
        wait_for_action(["agent-ready"]),
        TmuxWaitAction::Wait {
            name: "agent-ready".to_string(),
            timeout: 30.0,
        }
    );

    assert_eq!(show_options_stdout(["-gv", "focus-events"]), "off\n");
    assert_eq!(show_options_stdout(["mouse"]), "mouse off\n");
    assert_eq!(tail_terminal_lines("one\ntwo\nthree\n", 2), "two\nthree\n");
}
