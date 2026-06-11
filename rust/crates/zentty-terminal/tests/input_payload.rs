use zentty_terminal::{
    clipboard::TerminalClipboardPaste,
    input::{TerminalInputAction, TerminalInputPlanner, TerminalPasteMode},
};

#[test]
fn paste_payload_sends_text_and_file_paths_as_plain_bytes() {
    assert_eq!(
        TerminalInputPlanner::paste_payload(
            &TerminalClipboardPaste::Text("echo hello".to_string()),
            TerminalPasteMode::Plain,
        )
        .into_pty_bytes(),
        b"echo hello".to_vec()
    );
    assert_eq!(
        TerminalInputPlanner::paste_payload(
            &TerminalClipboardPaste::FilePath("C:\\\\Program\\ Files\\\\Zentty".to_string()),
            TerminalPasteMode::Plain,
        )
        .into_pty_bytes(),
        b"C:\\\\Program\\ Files\\\\Zentty".to_vec()
    );
}

#[test]
fn bracketed_paste_wraps_clipboard_content_without_changing_it() {
    let payload = TerminalInputPlanner::paste_payload(
        &TerminalClipboardPaste::Text("line one\r\nline two".to_string()),
        TerminalPasteMode::Bracketed,
    );

    assert_eq!(
        payload.into_pty_bytes(),
        b"\x1b[200~line one\r\nline two\x1b[201~".to_vec()
    );
}

#[test]
fn submit_command_keeps_return_as_a_separate_action() {
    let payload = TerminalInputPlanner::submit_command("pnpm start", TerminalPasteMode::Bracketed);

    assert_eq!(
        payload.actions(),
        &[
            TerminalInputAction::Bytes(b"\x1b[200~pnpm start\x1b[201~".to_vec()),
            TerminalInputAction::ReturnKey,
        ]
    );
}

#[test]
fn submit_command_pty_bytes_place_return_after_bracketed_paste() {
    let payload = TerminalInputPlanner::submit_command("pnpm start", TerminalPasteMode::Bracketed);

    assert_eq!(
        payload.into_pty_bytes(),
        b"\x1b[200~pnpm start\x1b[201~\r".to_vec()
    );
}
