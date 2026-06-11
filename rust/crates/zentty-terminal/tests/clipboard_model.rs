use zentty_terminal::{
    clipboard::{
        ClipboardImage, TerminalClipboardContent, TerminalClipboardInput, TerminalClipboardPaste,
        TerminalCopyMode, TerminalCopyPlanner,
    },
    screen::{TerminalScreen, TerminalTextPoint},
    selection::TerminalSelection,
};

#[test]
fn clipboard_pasted_string_accepts_plain_text_only_when_no_file_urls_are_present() {
    let plain = TerminalClipboardInput::new().with_text("echo hello world");
    assert_eq!(plain.pasted_string(), Some("echo hello world".to_string()));

    let file_only = TerminalClipboardInput::new().with_file_path("C:\\tmp\\screenshot.png");
    assert_eq!(file_only.pasted_string(), None);

    let file_and_text = TerminalClipboardInput::new()
        .with_file_path("C:\\tmp\\screenshot.png")
        .with_text("C:\\tmp\\screenshot.png");
    assert_eq!(file_and_text.pasted_string(), None);

    let image_only = TerminalClipboardInput::new().with_image(ClipboardImage {
        escaped_path: "C:\\tmp\\clipboard.png".to_string(),
        byte_len: 1024,
    });
    assert_eq!(image_only.pasted_string(), None);
}

#[test]
fn clipboard_pasted_content_prefers_escaped_file_paths_then_text_then_image_path() {
    let files = TerminalClipboardInput::new()
        .with_file_path("C:\\Program Files\\Zentty\\zentty.exe")
        .with_file_path("C:\\tmp\\plain.txt")
        .with_text("ignored text");
    assert_eq!(
        files.pasted_content(),
        Some(TerminalClipboardPaste::FilePath(
            "C:\\\\Program\\ Files\\\\Zentty\\\\zentty.exe C:\\\\tmp\\\\plain.txt".to_string()
        ))
    );

    let text = TerminalClipboardInput::new().with_text("cargo test");
    assert_eq!(
        text.pasted_content(),
        Some(TerminalClipboardPaste::Text("cargo test".to_string()))
    );

    let image = TerminalClipboardInput::new().with_image(ClipboardImage {
        escaped_path: "C:\\tmp\\clipboard-1234.png".to_string(),
        byte_len: 10 * 1024 * 1024,
    });
    assert_eq!(
        image.pasted_content(),
        Some(TerminalClipboardPaste::FilePath(
            "C:\\tmp\\clipboard-1234.png".to_string()
        ))
    );
}

#[test]
fn clipboard_rejects_oversized_image_paste_content() {
    let image = TerminalClipboardInput::new().with_image(ClipboardImage {
        escaped_path: "C:\\tmp\\clipboard-too-large.png".to_string(),
        byte_len: 10 * 1024 * 1024 + 1,
    });

    assert_eq!(image.pasted_content(), None);
}

#[test]
fn copy_planner_returns_raw_or_cleaned_selected_text_with_modification_flag() {
    let mut screen = TerminalScreen::new(20, 1);
    screen.feed(b"\x1b[32m$ cargo test   \x1b[0m");
    let mut selection = TerminalSelection::new();
    selection.begin(TerminalTextPoint {
        line_index: 0,
        column: 0,
    });
    selection.extend(TerminalTextPoint {
        line_index: 0,
        column: 15,
    });

    assert_eq!(
        TerminalCopyPlanner::copy_selection(&screen, &selection, TerminalCopyMode::Raw),
        Some(TerminalClipboardContent {
            text: "$ cargo test".to_string(),
            was_cleaned: false,
        })
    );
    assert_eq!(
        TerminalCopyPlanner::copy_selection(&screen, &selection, TerminalCopyMode::Clean),
        Some(TerminalClipboardContent {
            text: "cargo test".to_string(),
            was_cleaned: true,
        })
    );
}

#[test]
fn copy_planner_auto_mode_respects_clean_copy_policy() {
    let mut screen = TerminalScreen::new(16, 1);
    screen.feed(b"$ pwd   ");
    let mut selection = TerminalSelection::new();
    selection.begin(TerminalTextPoint {
        line_index: 0,
        column: 0,
    });
    selection.extend(TerminalTextPoint {
        line_index: 0,
        column: 8,
    });

    assert_eq!(
        TerminalCopyPlanner::copy_selection(
            &screen,
            &selection,
            TerminalCopyMode::Auto {
                is_auto_clean_enabled: true,
                suppress_callback_cleaning: false,
            },
        ),
        Some(TerminalClipboardContent {
            text: "pwd".to_string(),
            was_cleaned: true,
        })
    );
    assert_eq!(
        TerminalCopyPlanner::copy_selection(
            &screen,
            &selection,
            TerminalCopyMode::Auto {
                is_auto_clean_enabled: true,
                suppress_callback_cleaning: true,
            },
        ),
        Some(TerminalClipboardContent {
            text: "$ pwd".to_string(),
            was_cleaned: false,
        })
    );
}
