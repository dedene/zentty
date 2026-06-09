use zentty_terminal::shell::ShellEscaping;

#[test]
fn shell_escaping_matches_swift_sensitive_character_rules() {
    assert_eq!(
        ShellEscaping::escape_path("/usr/local/bin"),
        "/usr/local/bin"
    );
    assert_eq!(
        ShellEscaping::escape_path("/Users/me/my folder"),
        "/Users/me/my\\ folder"
    );
    assert_eq!(
        ShellEscaping::escape_path("/tmp/file (1).txt"),
        "/tmp/file\\ \\(1\\).txt"
    );
    assert_eq!(
        ShellEscaping::escape_path("/tmp/it's \"fun\""),
        "/tmp/it\\'s\\ \\\"fun\\\""
    );
    assert_eq!(ShellEscaping::escape_path("/tmp/a\\b"), "/tmp/a\\\\b");
    assert_eq!(ShellEscaping::escape_path(""), "");
}

#[test]
fn shell_escaping_handles_control_whitespace_and_joined_paths() {
    assert_eq!(ShellEscaping::escape_path("/tmp/a\tb"), "/tmp/a\\\tb");
    assert_eq!(ShellEscaping::escape_path("/tmp/a\nb"), "/tmp/a\\\nb");
    assert_eq!(ShellEscaping::escape_path("/tmp/a\rb"), "/tmp/a\\\rb");

    let joined = ["/tmp/a b", "/tmp/c d"]
        .map(ShellEscaping::escape_path)
        .join(" ");
    assert_eq!(joined, "/tmp/a\\ b /tmp/c\\ d");
}

#[test]
fn shell_escaping_covers_injection_sensitive_punctuation() {
    assert_eq!(
        ShellEscaping::escape_path("/tmp/a;b|c&d$(e)`f!g*?.txt"),
        "/tmp/a\\;b\\|c\\&d\\$\\(e\\)\\`f\\!g\\*\\?.txt"
    );
}
