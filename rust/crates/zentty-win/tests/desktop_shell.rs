use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use zentty_core::agent::{
    AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse, AgentIpcResponseError,
    AgentIpcResponseResult, AgentSignalCommand, PaneListEntry, ServerListEntry, ServerListResult,
};
use zentty_core::bookmarks::{
    BookmarkStore, WorkspaceTemplate, WorkspaceTemplateColumn, WorkspaceTemplateExporter,
    WorkspaceTemplateKind, WorkspaceTemplatePane,
};
use zentty_core::command_palette::{
    DetectedServer, DetectedServerConfidence, DetectedServerSource, OpenWithBuiltInTargetId,
    OpenWithResolvedTarget, OpenWithTargetKind, TaskRunnerAction, TaskRunnerDisabledReason,
    TaskRunnerSourceKind, WorklaneColor,
};
use zentty_core::commands::AppCommandId;
use zentty_core::config::{
    AppConfig, AppConfigToml, AppearanceThemeMode, FocusFollowsMouseDelay, OpenWithCustomApp,
    PaneSplitBehaviorMode, ServerBrowserCustomApp, ShortcutBindingOverride, ShortcutsConfig,
    SidebarVisibility,
};
use zentty_core::session_restore::{
    SaveReason, SessionRestoreEnvelope, WorkspaceRecipe, WorkspaceRecipeColumn,
    WorkspaceRecipePane, WorkspaceRecipeWindow, WorkspaceRecipeWorklane,
};
use zentty_core::task_runner::TaskRunnerShellActivityState;
use zentty_pty::TerminalSize;
use zentty_terminal::{
    clipboard::TerminalClipboardPaste, input::TerminalPasteMode, screen::TerminalTextPoint,
};
use zentty_win::app::{
    AgentIpcRuntimeEnvironment, AppCommandExecutionResult, CommandPaletteItemExecutionResult,
    PaneNotification,
};
use zentty_win::desktop::{
    DEFAULT_WINDOW_TITLE, DesktopCommandEffect, DesktopEnvironment, DesktopKey, DesktopKeyEvent,
    DesktopKeyModifiers, DesktopLaunchPlan, DesktopLaunchSource, DesktopMouseButton,
    DesktopMouseEvent, DesktopMouseEventKind, DesktopShellConfig, DesktopShellConfigError,
    DesktopShortcutResolver, DesktopTerminalState, DesktopWindowSession, default_app_launch_plan,
    desktop_key_event_from_windows_virtual_key, desktop_render_cell_for_client_point,
    desktop_terminal_size_for_client_area,
};

#[test]
fn desktop_config_defaults_to_app_data_config_path() {
    let app_data = test_directory("app-data-default");
    let config = DesktopShellConfig::parse_with_environment(
        Vec::<String>::new(),
        DesktopEnvironment {
            app_data: Some(app_data.clone()),
            user_profile: None,
        },
    )
    .expect("desktop config should parse");

    assert_eq!(
        config.config_path,
        app_data.join("Zentty").join("config.toml")
    );
    assert_eq!(config.window_title, DEFAULT_WINDOW_TITLE);
    assert_eq!(config.size, TerminalSize::default());
    assert_eq!(config.workspace_path, None);

    fs::remove_dir_all(app_data).ok();
}

#[test]
fn desktop_client_area_maps_to_terminal_cell_size() {
    assert_eq!(
        desktop_terminal_size_for_client_area(1024, 720),
        TerminalSize::new(126, 39).with_cell_pixels(8, 18)
    );
    assert_eq!(
        desktop_terminal_size_for_client_area(4, 4),
        TerminalSize::new(1, 1).with_cell_pixels(8, 18)
    );
}

#[test]
fn desktop_client_point_maps_to_render_cell() {
    assert_eq!(desktop_render_cell_for_client_point(8, 8), Some((0, 0)));
    assert_eq!(desktop_render_cell_for_client_point(23, 25), Some((0, 1)));
    assert_eq!(desktop_render_cell_for_client_point(24, 26), Some((1, 2)));
    assert_eq!(desktop_render_cell_for_client_point(7, 8), None);
    assert_eq!(desktop_render_cell_for_client_point(8, 7), None);
}

#[test]
fn desktop_config_parses_config_workspace_size_and_title() {
    let config = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            "C:\\Projects\\zentty\\config.toml",
            "--workspace",
            "C:\\Projects\\zentty\\restore.json",
            "--cols",
            "132",
            "--rows",
            "40",
            "--title",
            "Zentty Preview",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse explicit arguments");

    assert_eq!(
        config.config_path,
        PathBuf::from("C:\\Projects\\zentty\\config.toml")
    );
    assert_eq!(
        config.workspace_path.as_deref(),
        Some(std::path::Path::new("C:\\Projects\\zentty\\restore.json"))
    );
    assert_eq!(config.size, TerminalSize::new(132, 40));
    assert_eq!(config.window_title, "Zentty Preview");
}

#[test]
fn desktop_config_rejects_unknown_options_and_trailing_commands() {
    assert_eq!(
        DesktopShellConfig::parse_with_environment(["--bogus"], DesktopEnvironment::empty())
            .unwrap_err(),
        DesktopShellConfigError::UnknownOption("--bogus".to_string())
    );
    assert_eq!(
        DesktopShellConfig::parse_with_environment(["cmd.exe"], DesktopEnvironment::empty())
            .unwrap_err(),
        DesktopShellConfigError::UnexpectedCommand("cmd.exe".to_string())
    );
}

#[test]
fn desktop_launch_uses_default_config_and_new_workspace_without_files() {
    let dir = test_directory("new-workspace");
    let config_path = dir.join("missing.toml");
    let config = DesktopShellConfig::parse_with_environment(
        ["--config", config_path.to_string_lossy().as_ref()],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");

    let launch = DesktopLaunchPlan::load(config).expect("desktop launch should load");

    assert_eq!(launch.config, AppConfig::default().normalized());
    assert!(config_path.exists());
    assert_eq!(launch.source, DesktopLaunchSource::NewWorkspace);
    assert_eq!(launch.app.active_window_id.as_deref(), Some("window-main"));
    assert_eq!(launch.app.windows.len(), 1);
    assert_eq!(launch.app.windows[0].worklanes.len(), 1);
    assert_eq!(launch.app.windows[0].worklanes[0].panes.len(), 1);
    assert_eq!(
        launch.app.windows[0].worklanes[0]
            .focused_pane_id
            .as_deref(),
        Some("pane-main")
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
fn desktop_launch_uses_default_config_when_config_file_is_invalid() {
    let dir = test_directory("invalid-config");
    let config_path = dir.join("config.toml");
    let invalid_source = "[updates]\nchannel = \"nightly\"\n";
    fs::write(&config_path, invalid_source).expect("invalid config should be written");
    let config = DesktopShellConfig::parse_with_environment(
        ["--config", config_path.to_string_lossy().as_ref()],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");

    let launch = DesktopLaunchPlan::load(config).expect("invalid config should not block launch");

    assert_eq!(launch.config, AppConfig::default().normalized());
    assert_eq!(
        fs::read_to_string(&config_path).expect("invalid config should remain on disk"),
        invalid_source
    );
    assert_eq!(launch.source, DesktopLaunchSource::NewWorkspace);

    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_launch_applies_open_with_targets_from_config() {
    let dir = test_directory("desktop-open-with-config");
    let config_path = dir.join("config.toml");
    let custom_editor = dir.join("Editors").join("CustomEditor.exe");
    fs::create_dir_all(
        custom_editor
            .parent()
            .expect("custom editor should have parent"),
    )
    .expect("custom editor parent should be created");
    fs::write(&custom_editor, "fake exe").expect("custom editor should be written");
    let mut config = AppConfig::default();
    config.open_with.primary_target_id = "custom:editor".to_string();
    config.open_with.enabled_target_ids = vec!["finder".to_string(), "custom:editor".to_string()];
    config.open_with.custom_apps = vec![OpenWithCustomApp {
        id: "custom:editor".to_string(),
        name: "Custom Editor".to_string(),
        path: custom_editor.to_string_lossy().to_string(),
    }];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("config should be written");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");

    let mut launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");

    assert_eq!(
        launch.app.windows[0]
            .open_with_targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["custom:editor", "finder"]
    );
    launch.app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(dir.to_string_lossy().to_string());
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::OpenWithSelectedApp),
        AppCommandExecutionResult::OpenPathWithTarget {
            path: dir.to_string_lossy().to_string(),
            target_id: "custom:editor".to_string(),
            target_name: "Custom Editor".to_string(),
            app_path: Some(custom_editor.to_string_lossy().to_string()),
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
fn desktop_launch_restores_explicit_workspace_envelope() {
    let dir = test_directory("explicit-workspace");
    let config_path = dir.join("config.toml");
    let workspace_path = dir.join("restore.json");
    fs::write(&config_path, "[panes]\ninactive_opacity = 0.2\n").expect("config should be written");
    fs::write(
        &workspace_path,
        serde_json::to_string(&workspace_envelope(&dir)).expect("workspace should encode"),
    )
    .expect("workspace should be written");

    let config = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--workspace",
            workspace_path.to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");

    let launch = DesktopLaunchPlan::load(config).expect("desktop launch should load workspace");

    assert_eq!(
        launch.source,
        DesktopLaunchSource::WorkspaceRestore(workspace_path)
    );
    assert_eq!(launch.config.panes.inactive_opacity, 0.6);
    assert_eq!(
        launch.app.active_window_id.as_deref(),
        Some("window-restored")
    );
    assert_eq!(launch.app.windows[0].window_id, "window-restored");
    assert_eq!(
        launch.app.windows[0].worklanes[0]
            .focused_pane_id
            .as_deref(),
        Some("pane-restored")
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
fn desktop_terminal_state_feeds_output_into_visible_text() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 3));

    terminal.feed_output(b"hello\r\nworld");

    assert_eq!(terminal.visible_lines()[0].trim_end(), "hello");
    assert_eq!(terminal.visible_lines()[1].trim_end(), "world");
    assert_eq!(terminal.plain_text(), "hello\nworld");
}

#[test]
fn desktop_terminal_state_returns_terminal_response_bytes_for_output_queries() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 3));

    let response = terminal.feed_output(b"abc\x1b[2;4H\x1b[6n");

    assert_eq!(terminal.visible_lines()[0].trim_end(), "abc");
    assert_eq!(response, b"\x1b[2;4R".to_vec());
    assert_eq!(terminal.feed_output(b"\x1b[c"), b"\x1b[?1;2c".to_vec());
    assert_eq!(terminal.feed_output(b""), Vec::<u8>::new());
}

#[test]
fn desktop_terminal_state_maps_win32_char_input_to_pty_bytes() {
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('a'), b"a");
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\r'), b"\r");
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\n'), b"\r");
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\t'), b"\t");
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\u{8}'), b"\x7f");
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_char('λ'),
        "λ".as_bytes()
    );
}

#[test]
fn desktop_terminal_state_uses_negotiated_bracketed_paste_mode() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 2));

    assert_eq!(
        terminal.paste_mode_for_request(TerminalPasteMode::Plain),
        TerminalPasteMode::Plain
    );

    terminal.feed_output(b"\x1b[?2004h");

    assert_eq!(
        terminal.paste_mode_for_request(TerminalPasteMode::Plain),
        TerminalPasteMode::Bracketed
    );
    assert_eq!(
        terminal.paste_mode_for_request(TerminalPasteMode::Bracketed),
        TerminalPasteMode::Bracketed
    );

    terminal.feed_output(b"\x1b[?2004l");

    assert_eq!(
        terminal.paste_mode_for_request(TerminalPasteMode::Plain),
        TerminalPasteMode::Plain
    );
}

#[test]
fn desktop_terminal_state_tracks_negotiated_cursor_visibility() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 2));

    assert!(terminal.cursor_visible());

    terminal.feed_output(b"\x1b[?25l");
    assert!(!terminal.cursor_visible());

    terminal.feed_output(b"\x1b[?25h");
    assert!(terminal.cursor_visible());
}

#[test]
fn desktop_terminal_state_encodes_sgr_mouse_events_when_negotiated() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 3));
    let press = DesktopMouseEvent {
        button: DesktopMouseButton::Left,
        kind: DesktopMouseEventKind::Press,
        row: 2,
        column: 3,
    };

    assert_eq!(terminal.pty_bytes_for_mouse_event(press), None);

    terminal.feed_output(b"\x1b[?1000h\x1b[?1006h");

    assert_eq!(
        terminal.pty_bytes_for_mouse_event(press),
        Some(b"\x1b[<0;4;3M".to_vec())
    );
    assert_eq!(
        terminal.pty_bytes_for_mouse_event(DesktopMouseEvent {
            kind: DesktopMouseEventKind::Release,
            ..press
        }),
        Some(b"\x1b[<0;4;3m".to_vec())
    );
    assert_eq!(
        terminal.pty_bytes_for_mouse_event(DesktopMouseEvent {
            kind: DesktopMouseEventKind::Drag,
            ..press
        }),
        None
    );

    terminal.feed_output(b"\x1b[?1002h");

    assert_eq!(
        terminal.pty_bytes_for_mouse_event(DesktopMouseEvent {
            kind: DesktopMouseEventKind::Drag,
            ..press
        }),
        Some(b"\x1b[<32;4;3M".to_vec())
    );
}

#[test]
fn desktop_terminal_state_resize_updates_visible_grid() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(5, 2));

    terminal.feed_output(b"abcdefg");
    terminal.resize(TerminalSize::new(3, 3));

    assert_eq!(terminal.visible_lines(), vec!["abc", "fg ", "   "]);
}

#[test]
fn desktop_terminal_state_maps_plain_arrow_keys_to_pty_escape_sequences() {
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[A".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[B".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::RightArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[C".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[D".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::control(),
        )),
        None
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('a'),
            DesktopKeyModifiers::default(),
        )),
        None
    );
}

#[test]
fn desktop_terminal_state_maps_function_keys_to_pty_escape_sequences() {
    let f = |n: u8| {
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Function(n),
            DesktopKeyModifiers::default(),
        ))
    };
    // F1–F4 use SS3; F5–F12 use CSI ~ sequences (xterm).
    assert_eq!(f(1), Some(b"\x1bOP".to_vec()));
    assert_eq!(f(2), Some(b"\x1bOQ".to_vec()));
    assert_eq!(f(3), Some(b"\x1bOR".to_vec()));
    assert_eq!(f(4), Some(b"\x1bOS".to_vec()));
    assert_eq!(f(5), Some(b"\x1b[15~".to_vec()));
    assert_eq!(f(10), Some(b"\x1b[21~".to_vec()));
    assert_eq!(f(12), Some(b"\x1b[24~".to_vec()));
    assert_eq!(f(13), None);
}

#[test]
fn desktop_virtual_key_maps_function_keys() {
    // VK_F1 = 0x70 … VK_F12 = 0x7B.
    let event = desktop_key_event_from_windows_virtual_key(0x70, DesktopKeyModifiers::default());
    assert_eq!(event.map(|e| e.key), Some(DesktopKey::Function(1)));
    let event = desktop_key_event_from_windows_virtual_key(0x7b, DesktopKeyModifiers::default());
    assert_eq!(event.map(|e| e.key), Some(DesktopKey::Function(12)));
}

#[test]
fn desktop_terminal_state_encodes_control_chars_and_unicode() {
    // Ctrl-letter control bytes arrive as WM_CHAR control characters.
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\u{3}'), b"\x03"); // Ctrl-C
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\u{4}'), b"\x04"); // Ctrl-D
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('\u{1b}'), b"\x1b"); // Esc
    // Multibyte Unicode encodes as UTF-8.
    assert_eq!(DesktopTerminalState::pty_bytes_for_char('é'), "é".as_bytes());
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_char('🚀'),
        &[0xf0, 0x9f, 0x9a, 0x80]
    );
}

#[test]
fn desktop_terminal_state_decckm_home_end_use_ss3() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 3));
    terminal.feed_output(b"\x1b[?1h"); // enable application cursor keys
    let home = terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
        DesktopKey::Home,
        DesktopKeyModifiers::default(),
    ));
    let end = terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
        DesktopKey::End,
        DesktopKeyModifiers::default(),
    ));
    assert_eq!(home, Some(b"\x1bOH".to_vec()));
    assert_eq!(end, Some(b"\x1bOF".to_vec()));
}

#[test]
fn desktop_terminal_state_maps_application_cursor_keys_to_ss3_escape_sequences() {
    let mut terminal = DesktopTerminalState::new(TerminalSize::new(12, 3));
    terminal.feed_output(b"\x1b[?1h");

    assert_eq!(
        terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1bOA".to_vec())
    );
    assert_eq!(
        terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1bOB".to_vec())
    );
    assert_eq!(
        terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
            DesktopKey::RightArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1bOC".to_vec())
    );
    assert_eq!(
        terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1bOD".to_vec())
    );

    terminal.feed_output(b"\x1b[?1l");

    assert_eq!(
        terminal.pty_bytes_for_terminal_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[A".to_vec())
    );
}

#[test]
fn desktop_terminal_state_maps_plain_navigation_keys_to_pty_escape_sequences() {
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Delete,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[3~".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Home,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[H".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::End,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[F".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::PageUp,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[5~".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::PageDown,
            DesktopKeyModifiers::default(),
        )),
        Some(b"\x1b[6~".to_vec())
    );
    assert_eq!(
        DesktopTerminalState::pty_bytes_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Delete,
            DesktopKeyModifiers::control(),
        )),
        None
    );
}

#[test]
fn desktop_shortcut_resolver_maps_windows_command_equivalents_to_focus_commands() {
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::FocusLeftPane)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::RightArrow,
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::FocusRightPane)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::FocusUpInColumn)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::FocusDownInColumn)
    );
}

#[test]
fn desktop_shortcut_resolver_maps_windows_option_equivalents_to_next_previous_pane() {
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::control_alt(),
        )),
        Some(AppCommandId::FocusPreviousPane)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::control_alt(),
        )),
        Some(AppCommandId::FocusNextPane)
    );
}

#[test]
fn desktop_shortcut_resolver_maps_windows_command_equivalents_to_pane_lifecycle_commands() {
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('w'),
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::CloseFocusedPane)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('d'),
            DesktopKeyModifiers::control(),
        )),
        Some(AppCommandId::SplitHorizontally)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('d'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        Some(AppCommandId::SplitVertically)
    );
}

#[test]
fn desktop_shortcut_resolver_leaves_plain_keys_for_terminal_input() {
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('a'),
            DesktopKeyModifiers::default(),
        )),
        None
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::default(),
        )),
        None
    );
}

#[test]
fn desktop_shortcut_resolver_honors_configured_overrides() {
    let shortcuts = ShortcutsConfig {
        bindings: vec![ShortcutBindingOverride {
            command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
            shortcut: Some("command+b".to_string()),
        }],
    }
    .normalized();

    assert_eq!(
        DesktopShortcutResolver::command_for_key_event_with_shortcuts(
            DesktopKeyEvent::new(DesktopKey::Character('b'), DesktopKeyModifiers::control()),
            &shortcuts
        ),
        Some(AppCommandId::ShowCommandPalette)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event_with_shortcuts(
            DesktopKeyEvent::new(
                DesktopKey::Character('p'),
                DesktopKeyModifiers {
                    control: true,
                    alt: false,
                    shift: true,
                },
            ),
            &shortcuts
        ),
        None
    );
}

#[test]
fn desktop_shortcut_resolver_honors_configured_unbindings() {
    let shortcuts = ShortcutsConfig {
        bindings: vec![ShortcutBindingOverride {
            command_id: AppCommandId::CopyRaw.raw_value().to_string(),
            shortcut: None,
        }],
    }
    .normalized();

    assert_eq!(
        DesktopShortcutResolver::command_for_key_event_with_shortcuts(
            DesktopKeyEvent::new(
                DesktopKey::Character('c'),
                DesktopKeyModifiers {
                    control: true,
                    alt: false,
                    shift: true,
                },
            ),
            &shortcuts
        ),
        None
    );
}

#[test]
fn desktop_windows_virtual_key_translation_includes_palette_shortcut_key() {
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x42, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(
            0x50,
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        ),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        ))
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(
            desktop_key_event_from_windows_virtual_key(
                0x50,
                DesktopKeyModifiers {
                    control: true,
                    alt: false,
                    shift: true,
                },
            )
            .expect("P virtual key should translate")
        ),
        Some(AppCommandId::ShowCommandPalette)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(
            desktop_key_event_from_windows_virtual_key(
                0x46,
                DesktopKeyModifiers {
                    control: true,
                    alt: false,
                    shift: true,
                },
            )
            .expect("F virtual key should translate")
        ),
        Some(AppCommandId::Find)
    );
    assert_eq!(
        DesktopShortcutResolver::command_for_key_event(
            desktop_key_event_from_windows_virtual_key(
                0x43,
                DesktopKeyModifiers {
                    control: true,
                    alt: false,
                    shift: true,
                },
            )
            .expect("C virtual key should translate")
        ),
        Some(AppCommandId::CopyRaw)
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(
            0x56,
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        ),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('v'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x09, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Tab,
            DesktopKeyModifiers::default(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x31, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('1'),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0xba, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character(';'),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0xdb, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('['),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0xdd, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character(']'),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0xbc, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character(','),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0xbe, DesktopKeyModifiers::control()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Character('.'),
            DesktopKeyModifiers::control(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x2e, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Delete,
            DesktopKeyModifiers::default(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x24, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::Home,
            DesktopKeyModifiers::default(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x23, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::End,
            DesktopKeyModifiers::default(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x21, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::PageUp,
            DesktopKeyModifiers::default(),
        ))
    );
    assert_eq!(
        desktop_key_event_from_windows_virtual_key(0x22, DesktopKeyModifiers::default()),
        Some(DesktopKeyEvent::new(
            DesktopKey::PageDown,
            DesktopKeyModifiers::default(),
        ))
    );
}

#[test]
#[cfg(windows)]
fn desktop_window_session_spawns_focused_pane_and_streams_output() {
    let dir = test_directory("window-session");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo ZENTTY_DESKTOP_SESSION_READY & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !session
        .plain_text()
        .contains("ZENTTY_DESKTOP_SESSION_READY")
        && std::time::Instant::now() < deadline
    {
        session
            .poll_output()
            .expect("desktop session should poll PTY output");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    assert!(
        session
            .plain_text()
            .contains("ZENTTY_DESKTOP_SESSION_READY"),
        "screen text: {}",
        session.plain_text()
    );
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_applies_configured_sidebar_visibility_and_width() {
    let dir = test_directory("window-session-sidebar-config");
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.sidebar.visibility = SidebarVisibility::Hidden;
    config.sidebar.width = 900.0;
    let launch = DesktopLaunchPlan {
        shell,
        config: config.normalized(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    let hidden = session.sidebar_snapshot();
    assert_eq!(hidden.visibility, "hidden");
    assert!(!hidden.is_visible);
    assert_eq!(hidden.width, 420.0);
    assert!(
        !session
            .render_lines(None)
            .iter()
            .any(|line| line == "Sidebar: hidden (420px)")
    );

    assert_eq!(
        session.execute_app_command(AppCommandId::ToggleSidebar),
        DesktopCommandEffect::Repaint
    );
    let visible = session.sidebar_snapshot();
    assert_eq!(visible.visibility, "pinnedOpen");
    assert!(visible.is_visible);
    assert_eq!(visible.width, 420.0);
    assert_eq!(visible.worklanes.len(), 1);
    assert_eq!(visible.worklanes[0].title, "Main");
    let rendered = session.render_lines(None);
    assert!(
        rendered
            .iter()
            .any(|line| line == "Sidebar: pinnedOpen (420px)")
    );
    assert!(rendered.iter().any(|line| line == "> Main (1 pane)"));
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("sidebar command should persist config"),
    )
    .expect("persisted sidebar command config should decode");
    assert_eq!(persisted.sidebar.visibility, SidebarVisibility::PinnedOpen);
    assert_eq!(persisted.sidebar.width, 420.0);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_applies_configured_shortcut_overrides() {
    let dir = test_directory("window-session-shortcut-overrides");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
        shortcut: Some("command+b".to_string()),
    }];
    let launch = DesktopLaunchPlan {
        shell,
        config: config.normalized(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Ignored
    );
    assert!(session.command_palette_snapshot().is_none());

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(session.command_palette_snapshot().is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_reload_config_applies_shortcut_overrides() {
    let dir = test_directory("window-session-reload-shortcuts");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    let mut config = AppConfig::default();
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
        shortcut: Some("command+b".to_string()),
    }];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("updated config should write");

    assert_eq!(
        session.execute_app_command(AppCommandId::ReloadConfig),
        DesktopCommandEffect::Status {
            message: "Configuration reloaded".to_string(),
        }
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(session.command_palette_snapshot().is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_palette_reload_config_applies_shortcut_overrides() {
    let dir = test_directory("window-session-palette-reload-shortcuts");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    let mut config = AppConfig::default();
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
        shortcut: Some("command+b".to_string()),
    }];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("updated config should write");

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "reload configuration".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    let snapshot = session
        .command_palette_snapshot()
        .expect("command palette should be visible");
    assert_eq!(snapshot.items[0].title, "Reload Configuration");
    assert!(snapshot.items[0].is_selected);
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("reload item should execute"),
        DesktopCommandEffect::Status {
            message: "Configuration reloaded".to_string(),
        }
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(session.command_palette_snapshot().is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_reload_config_applies_sidebar_visibility() {
    let dir = test_directory("window-session-reload-sidebar");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.sidebar_snapshot().visibility, "pinnedOpen");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    let mut config = AppConfig::default();
    config.sidebar.visibility = SidebarVisibility::Hidden;
    config.sidebar.width = 120.0;
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("updated config should write");

    assert_eq!(
        session.execute_app_command(AppCommandId::ReloadConfig),
        DesktopCommandEffect::Status {
            message: "Configuration reloaded".to_string(),
        }
    );
    let sidebar = session.sidebar_snapshot();
    assert_eq!(sidebar.visibility, "hidden");
    assert!(!sidebar.is_visible);
    assert_eq!(sidebar.width, 180.0);
    assert!(
        !session
            .render_lines(None)
            .iter()
            .any(|line| line.starts_with("Sidebar:"))
    );
    let settings = session
        .settings_snapshot()
        .expect("settings should stay visible after reload");
    assert!(
        settings
            .lines
            .iter()
            .any(|line| line == "Sidebar: hidden (180px)")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_reload_config_ignores_invalid_file_without_resetting_live_config() {
    let dir = test_directory("window-session-reload-invalid");
    let config_path = dir.join("config.toml");
    let mut config = AppConfig::default();
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
        shortcut: Some("command+b".to_string()),
    }];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("initial config should write");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    let invalid_source = "[updates]\nchannel = \"nightly\"\n";
    fs::write(&config_path, invalid_source).expect("invalid config should write");

    match session.execute_app_command(AppCommandId::ReloadConfig) {
        DesktopCommandEffect::Status { message } => {
            assert!(message.contains("Ignoring invalid configuration"));
        }
        other => panic!("expected invalid reload status, got {other:?}"),
    }
    assert_eq!(
        fs::read_to_string(&config_path).expect("invalid config should remain"),
        invalid_source
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(session.command_palette_snapshot().is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_updates_pane_title_from_osc_output() {
    let dir = test_directory("window-session-osc-title");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0].terminal_request.command = Some(
        "powershell.exe -NoProfile -EncodedCommand JABlAD0AWwBjAGgAYQByAF0AMgA3ADsAJABiAD0AWwBjAGgAYQByAF0ANwA7AFsAQwBvAG4AcwBvAGwAZQBdADoAOgBPAHUAdAAuAFcAcgBpAHQAZQAoACQAZQArACIAXQAwADsATwBTAEMAXwBEAEUAUwBLAFQATwBQAF8AVABJAFQATABFACIAKwAkAGIAKQA7AFMAdABhAHIAdAAtAFMAbABlAGUAcAAgAC0AUwBlAGMAbwBuAGQAcwAgADUA"
            .to_string(),
    );
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .pane_snapshots()
            .into_iter()
            .any(|snapshot| snapshot.title == "OSC_DESKTOP_TITLE")
    });

    assert_eq!(session.pane_snapshots()[0].title, "OSC_DESKTOP_TITLE");

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_auto_closes_pane_whose_shell_exited() {
    let dir = test_directory("auto-close-exited-pane");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    // pane-left keeps its default interactive shell (stays alive); pane-right
    // runs a one-shot command and then exits.
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo ZENTTY_RIGHT_READY & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    // Drive the poll loop until the exited pane is auto-closed, mirroring the
    // window timer's poll + close_exited_panes cadence.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut window_emptied = false;
    while session.pane_ids().contains(&"pane-right") && std::time::Instant::now() < deadline {
        session
            .poll_output()
            .expect("desktop session should poll PTY output");
        window_emptied = session.close_exited_panes();
        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    assert_eq!(
        session.pane_ids(),
        vec!["pane-left"],
        "exited pane should be auto-closed, leaving the live pane"
    );
    assert!(
        !window_emptied,
        "closing one of two panes should not request a window close"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_spawns_active_worklane_panes_and_streams_each_output() {
    let dir = test_directory("multi-pane-output");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo ZENTTY_LEFT_READY & exit".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo ZENTTY_RIGHT_READY & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("ZENTTY_LEFT_READY"))
            && session
                .plain_text_for_pane("pane-right")
                .is_some_and(|text| text.contains("ZENTTY_RIGHT_READY"))
    });

    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    let snapshots = session.pane_snapshots();
    assert_eq!(snapshots.len(), 2);
    assert_eq!(snapshots[0].pane_id, "pane-left");
    assert!(!snapshots[0].is_focused);
    assert!(snapshots[0].plain_text.contains("ZENTTY_LEFT_READY"));
    assert_eq!(snapshots[1].pane_id, "pane-right");
    assert!(snapshots[1].is_focused);
    assert!(snapshots[1].plain_text.contains("ZENTTY_RIGHT_READY"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_routes_typed_input_to_focused_pane_only() {
    let dir = test_directory("focused-input");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("findstr .".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("findstr .".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    for ch in "ZENTTY_FOCUSED_INPUT\r".chars() {
        session
            .write_char(ch)
            .expect("focused pane should accept character input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_FOCUSED_INPUT"))
    });

    assert!(
        !session
            .plain_text_for_pane("pane-left")
            .unwrap_or_default()
            .contains("ZENTTY_FOCUSED_INPUT"),
        "left pane text: {}",
        session.plain_text_for_pane("pane-left").unwrap_or_default()
    );
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_FOCUSED_INPUT"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_pastes_text_payload_to_focused_pane() {
    let dir = test_directory("focused-paste");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("findstr .".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session
        .paste_to_focused(
            &TerminalClipboardPaste::Text("ZENTTY_DESKTOP_PASTE".to_string()),
            TerminalPasteMode::Plain,
        )
        .expect("focused pane should accept pasted text");
    session
        .write_char('\r')
        .expect("focused pane should accept return after paste");
    poll_until(&mut session, |session| {
        session.plain_text().contains("ZENTTY_DESKTOP_PASTE")
    });

    assert!(
        session.plain_text().contains("ZENTTY_DESKTOP_PASTE"),
        "screen text: {}",
        session.plain_text()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_resize_updates_panes_and_future_splits() {
    let dir = test_directory("native-resize");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "5",
            "--rows",
            "2",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_desktop_snapshot_grid(&session, 5, 2);

    session
        .resize(TerminalSize::new(9, 4))
        .expect("desktop session should resize active panes");
    assert_desktop_snapshot_grid(&session, 9, 4);

    assert_eq!(
        session.execute_command(AppCommandId::SplitHorizontally),
        AppCommandExecutionResult::Applied
    );
    assert_desktop_snapshot_grid(&session, 9, 4);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_hit_tests_render_cells_into_visible_pane_text_points() {
    let dir = test_directory("native-hit-test");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "32",
            "--rows",
            "3",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo LEFT_RENDER_TEXT & exit".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo RIGHT_RENDER_TEXT & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("LEFT_RENDER_TEXT"))
            && session
                .plain_text_for_pane("pane-right")
                .is_some_and(|text| text.contains("RIGHT_RENDER_TEXT"))
    });

    assert_eq!(session.terminal_point_for_render_cell(0, 0), None);
    assert_eq!(
        session.terminal_point_for_render_cell(1, 5),
        Some((
            "pane-left".to_string(),
            TerminalTextPoint {
                line_index: 0,
                column: 5,
            },
        ))
    );
    assert_eq!(session.terminal_point_for_render_cell(5, 0), None);
    assert_eq!(
        session.terminal_point_for_render_cell(6, 6),
        Some((
            "pane-right".to_string(),
            TerminalTextPoint {
                line_index: 0,
                column: 6,
            },
        ))
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_mouse_drag_selection_focuses_hit_pane_and_selects_text() {
    let dir = test_directory("native-mouse-selection");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "32",
            "--rows",
            "3",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo LEFT_MOUSE_SELECT & exit".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo RIGHT_MOUSE_SELECT & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("LEFT_MOUSE_SELECT"))
            && session
                .plain_text_for_pane("pane-right")
                .is_some_and(|text| text.contains("RIGHT_MOUSE_SELECT"))
    });
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert!(session.begin_mouse_selection_at_render_cell(1, 0));
    assert!(session.extend_mouse_selection_at_render_cell(1, 4));

    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.selected_text_for_focused_pane().as_deref(),
        Some("LEFT")
    );

    assert!(session.finish_mouse_selection());
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_maps_negotiated_mouse_reports_from_render_cells() {
    let dir = test_directory("native-mouse-report");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "32",
            "--rows",
            "3",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session
        .feed_output_for_pane("pane-main", b"\x1b[?1000h\x1b[?1006hMOUSE_READY")
        .expect("mouse setup output should feed pane");
    let pane_text = session.plain_text_for_pane("pane-main").unwrap_or_default();
    assert!(
        pane_text.contains("MOUSE_READY"),
        "pane text: {pane_text:?}"
    );

    assert_eq!(
        session.pty_bytes_for_mouse_event_at_render_cell(
            DesktopMouseButton::Left,
            DesktopMouseEventKind::Press,
            1,
            3,
        ),
        Some(("pane-main".to_string(), b"\x1b[<0;4;1M".to_vec()))
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_double_click_selects_word_at_render_cell() {
    let dir = test_directory("native-word-selection");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "32",
            "--rows",
            "3",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo cargo test --all & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-main")
            .is_some_and(|text| text.contains("cargo test --all"))
    });

    assert!(session.select_word_at_render_cell(1, 8));
    assert_eq!(
        session.selected_text_for_focused_pane().as_deref(),
        Some("test")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_ctrl_shift_v_requests_clipboard_paste() {
    let dir = test_directory("native-paste-shortcut");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('v'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::PasteFromClipboard {
            mode: TerminalPasteMode::Plain
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_focus_commands_update_focused_pane_and_input_target() {
    let dir = test_directory("focus-command-input");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("findstr .".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("findstr .".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        session.execute_command(AppCommandId::FocusLeftPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    for ch in "ZENTTY_LEFT_FOCUS\r".chars() {
        session
            .write_char(ch)
            .expect("left focused pane should accept input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("ZENTTY_LEFT_FOCUS"))
    });

    assert!(
        session
            .plain_text_for_pane("pane-left")
            .unwrap_or_default()
            .contains("ZENTTY_LEFT_FOCUS"),
        "left pane text: {}",
        session.plain_text_for_pane("pane-left").unwrap_or_default()
    );
    assert!(
        !session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_LEFT_FOCUS"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    assert_eq!(
        session.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_focus_next_previous_wraps_by_pane_order() {
    let dir = test_directory("focus-next-previous");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        session.execute_command(AppCommandId::FocusNextPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.execute_command(AppCommandId::FocusPreviousPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_navigates_focus_history() {
    let dir = test_directory("focus-history");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let worklane = &mut app.windows[0].worklanes[0];
    worklane.focused_pane_id = Some("pane-left".to_string());
    worklane.panes[0].pane_id = "pane-left".to_string();
    worklane.panes[0].title = "left".to_string();
    worklane.panes[0].column_id = "column-left".to_string();
    worklane.panes[0].column_index = 0;
    worklane.panes[0].terminal_request.command = Some("findstr .".to_string());
    let mut middle = worklane.panes[0].clone();
    middle.pane_id = "pane-middle".to_string();
    middle.title = "middle".to_string();
    middle.column_id = "column-middle".to_string();
    middle.column_index = 1;
    let mut right = worklane.panes[0].clone();
    right.pane_id = "pane-right".to_string();
    right.title = "right".to_string();
    right.column_id = "column-right".to_string();
    right.column_index = 2;
    worklane.panes.extend([middle, right]);
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-middle"));
    assert_eq!(
        session.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert_eq!(
        session.execute_command(AppCommandId::NavigateBack),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-middle"));
    assert_eq!(
        session.execute_command(AppCommandId::NavigateBack),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.execute_command(AppCommandId::NavigateForward),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-middle"));

    for ch in "ZENTTY_NAV_MIDDLE\r".chars() {
        session
            .write_char(ch)
            .expect("navigated focused pane should accept input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-middle")
            .is_some_and(|text| text.contains("ZENTTY_NAV_MIDDLE"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-middle")
            .unwrap_or_default()
            .contains("ZENTTY_NAV_MIDDLE"),
        "middle pane text: {}",
        session
            .plain_text_for_pane("pane-middle")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_cycles_live_worklanes() {
    let dir = test_directory("worklane-cycle");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let mut alpha = app.windows[0].worklanes[0].clone();
    alpha.worklane_id = "alpha".to_string();
    alpha.title = Some("Alpha".to_string());
    alpha.focused_pane_id = Some("pane-alpha".to_string());
    alpha.panes[0].worklane_id = "alpha".to_string();
    alpha.panes[0].pane_id = "pane-alpha".to_string();
    alpha.panes[0].title = "alpha".to_string();
    alpha.panes[0].column_id = "column-alpha".to_string();
    alpha.panes[0].terminal_request.command = Some("findstr .".to_string());
    let mut beta = alpha.clone();
    beta.worklane_id = "beta".to_string();
    beta.title = Some("Beta".to_string());
    beta.focused_pane_id = Some("pane-beta".to_string());
    beta.panes[0].worklane_id = "beta".to_string();
    beta.panes[0].pane_id = "pane-beta".to_string();
    beta.panes[0].title = "beta".to_string();
    beta.panes[0].column_id = "column-beta".to_string();
    app.windows[0].active_worklane_id = Some("alpha".to_string());
    app.windows[0].worklanes = vec![alpha, beta];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.pane_ids(), vec!["pane-alpha", "pane-beta"]);
    assert_eq!(session.focused_pane_id(), Some("pane-alpha"));
    assert_eq!(
        session.execute_command(AppCommandId::NextWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-beta"));
    for ch in "ZENTTY_WORKLANE_BETA\r".chars() {
        session
            .write_char(ch)
            .expect("beta worklane pane should accept focused input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-beta")
            .is_some_and(|text| text.contains("ZENTTY_WORKLANE_BETA"))
    });

    assert_eq!(
        session.execute_command(AppCommandId::PreviousWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-alpha"));
    for ch in "ZENTTY_WORKLANE_ALPHA\r".chars() {
        session
            .write_char(ch)
            .expect("alpha worklane pane should accept focused input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-alpha")
            .is_some_and(|text| text.contains("ZENTTY_WORKLANE_ALPHA"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-alpha")
            .unwrap_or_default()
            .contains("ZENTTY_WORKLANE_ALPHA"),
        "alpha pane text: {}",
        session
            .plain_text_for_pane("pane-alpha")
            .unwrap_or_default()
    );
    assert!(
        session
            .plain_text_for_pane("pane-beta")
            .unwrap_or_default()
            .contains("ZENTTY_WORKLANE_BETA"),
        "beta pane text: {}",
        session.plain_text_for_pane("pane-beta").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_moves_active_worklane_before_cycling() {
    let dir = test_directory("worklane-move");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let mut alpha = app.windows[0].worklanes[0].clone();
    alpha.worklane_id = "alpha".to_string();
    alpha.focused_pane_id = Some("pane-alpha".to_string());
    alpha.panes[0].worklane_id = "alpha".to_string();
    alpha.panes[0].pane_id = "pane-alpha".to_string();
    alpha.panes[0].column_id = "column-alpha".to_string();
    let mut beta = alpha.clone();
    beta.worklane_id = "beta".to_string();
    beta.focused_pane_id = Some("pane-beta".to_string());
    beta.panes[0].worklane_id = "beta".to_string();
    beta.panes[0].pane_id = "pane-beta".to_string();
    beta.panes[0].column_id = "column-beta".to_string();
    let mut gamma = alpha.clone();
    gamma.worklane_id = "gamma".to_string();
    gamma.focused_pane_id = Some("pane-gamma".to_string());
    gamma.panes[0].worklane_id = "gamma".to_string();
    gamma.panes[0].pane_id = "pane-gamma".to_string();
    gamma.panes[0].column_id = "column-gamma".to_string();
    app.windows[0].active_worklane_id = Some("beta".to_string());
    app.windows[0].worklanes = vec![alpha, beta, gamma];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-beta"));
    assert_eq!(
        session.execute_command(AppCommandId::WorklaneMoveUp),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        session.execute_command(AppCommandId::PreviousWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-gamma"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_creates_new_worklane_with_live_pane() {
    let dir = test_directory("worklane-new");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("findstr .".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::NewWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(session.focused_pane_id(), Some("pane-2"));
    for ch in "ZENTTY_NEW_WORKLANE\r".chars() {
        session
            .write_char(ch)
            .expect("new worklane pane should accept focused input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-2")
            .is_some_and(|text| text.contains("ZENTTY_NEW_WORKLANE"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-2")
            .unwrap_or_default()
            .contains("ZENTTY_NEW_WORKLANE"),
        "new worklane pane text: {}",
        session.plain_text_for_pane("pane-2").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_persists_worklane_color_palette_changes() {
    let dir = test_directory("desktop-worklane-color");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.active_worklane_color(), None);
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "worklane color blue".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Blue".to_string())
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "worklane color reset".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Reset to Default".to_string())
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.active_worklane_color(), None);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_key_event_reports_native_close_effect_for_last_pane() {
    let dir = test_directory("native-close-effect");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('w'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::ConfirmCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(
        session.pane_ids(),
        vec!["pane-main"],
        "close-window handoff should not remove the final pane before the host closes"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_close_app_commands_honor_confirmation_preferences() {
    let dir = test_directory("native-close-confirmations");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::ConfirmClosePane {
            pane_id: "pane-right".to_string(),
            pane_title: "right".to_string(),
        }
    );
    assert_eq!(
        session.pane_ids(),
        vec!["pane-left", "pane-right"],
        "confirmation should leave panes untouched until accepted"
    );
    assert_eq!(
        session.execute_confirmed_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(
        session.execute_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::ConfirmCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);

    session.terminate().ok();

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing-again.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.confirmations.confirm_before_closing_pane = false;
    config.confirmations.confirm_before_closing_window = false;
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(
        session.execute_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::CloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_palette_close_pane_requests_confirmation() {
    let dir = test_directory("palette-close-confirmation");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    session.execute_app_command(AppCommandId::ShowCommandPalette);
    for ch in "close pane".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Close Pane".to_string())
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::ConfirmClosePane {
            pane_id: "pane-right".to_string(),
            pane_title: "right".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_key_event_reports_repaint_for_applied_shortcuts_and_ignored_plain_keys() {
    let dir = test_directory("native-key-effects");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('a'),
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Ignored
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Delete,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('w'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::ConfirmClosePane {
            pane_id: "pane-right".to_string(),
            pane_title: "right".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(
        session.execute_confirmed_app_command(AppCommandId::CloseFocusedPane),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(session.focused_pane_id(), Some("pane-left"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_opens_and_filters_shared_results() {
    let dir = test_directory("native-command-palette-filter");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );

    let open = session
        .command_palette_snapshot()
        .expect("palette should be visible");
    assert_eq!(open.query, "");
    assert!(
        open.items.iter().any(|item| item.title == "Open Settings"),
        "empty palette should include settings item: {:?}",
        open.items
            .iter()
            .map(|item| item.title.as_str())
            .collect::<Vec<_>>()
    );

    assert_eq!(
        session.write_char_event('s').expect("query should update"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.write_char_event('e').expect("query should update"),
        DesktopCommandEffect::Repaint
    );

    let filtered = session
        .command_palette_snapshot()
        .expect("palette should stay visible");
    assert_eq!(filtered.query, "se");
    assert!(
        filtered
            .items
            .iter()
            .any(|item| item.title == "General Settings"),
        "filtered palette should include settings item: {:?}",
        filtered
            .items
            .iter()
            .map(|item| item.title.as_str())
            .collect::<Vec<_>>()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_app_command_opens_command_palette() {
    let dir = test_directory("native-command-palette-app-command");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(
        session.execute_app_command(AppCommandId::ShowCommandPalette),
        DesktopCommandEffect::Repaint
    );

    let snapshot = session
        .command_palette_snapshot()
        .expect("palette should be visible");
    assert_eq!(snapshot.query, "");
    assert!(
        snapshot
            .items
            .iter()
            .any(|item| item.title == "Open Settings")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_app_command_opens_settings_view() {
    let dir = test_directory("native-settings-app-command");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    let settings = session
        .settings_snapshot()
        .expect("settings should be visible");
    assert_eq!(settings.section, "general");
    assert_eq!(settings.title, "General Settings");
    assert!(
        settings
            .lines
            .iter()
            .any(|line| line == "Sidebar: pinnedOpen (280px)")
    );
    assert!(
        session
            .render_lines(None)
            .iter()
            .any(|line| line == "General Settings")
    );

    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close settings"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.settings_snapshot(), None);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_keyboard_navigation_and_persistence() {
    let dir = test_directory("native-settings-keyboard-persist");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    let settings = session
        .settings_snapshot()
        .expect("settings should be visible");
    assert_eq!(settings.section, "general");
    assert_eq!(settings.selected_index, 0);
    assert!(
        session
            .render_lines(None)
            .iter()
            .any(|line| line == "> Sidebar: pinnedOpen (280px)")
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .settings_snapshot()
            .expect("settings should remain visible")
            .selected_index,
        1
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::RightArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    let appearance = session
        .settings_snapshot()
        .expect("appearance settings should be visible");
    assert_eq!(appearance.section, "appearance");
    assert_eq!(appearance.title, "Appearance Settings");
    assert_eq!(appearance.selected_index, 0);

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should activate selected setting"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysLight);
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be written"),
    )
    .expect("persisted settings config should decode");
    assert_eq!(
        decoded.appearance.theme_mode,
        AppearanceThemeMode::AlwaysLight
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::LeftArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle selected setting"),
        DesktopCommandEffect::Repaint
    );
    let sidebar = session.sidebar_snapshot();
    assert_eq!(sidebar.visibility, "hidden");
    assert!(!sidebar.is_visible);
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be updated"),
    )
    .expect("updated settings config should decode");
    assert_eq!(decoded.sidebar.visibility, SidebarVisibility::Hidden);

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle restore setting"),
        DesktopCommandEffect::Repaint
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be updated again"),
    )
    .expect("second updated settings config should decode");
    assert!(!decoded.restore.restore_workspace_on_launch);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_reset_all_shortcuts_persists_and_reapplies_defaults() {
    let dir = test_directory("native-settings-shortcuts-reset");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::ShowCommandPalette.raw_value().to_string(),
        shortcut: Some("command+b".to_string()),
    }];
    let launch = DesktopLaunchPlan {
        shell,
        config: config.normalized(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Ignored
    );
    assert!(session.command_palette_snapshot().is_none());

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..2 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let shortcuts = session
        .settings_snapshot()
        .expect("shortcuts settings should be visible");
    assert_eq!(shortcuts.section, "shortcuts");
    assert!(
        shortcuts
            .lines
            .iter()
            .any(|line| line == "Shortcut overrides: 1")
    );
    assert!(
        shortcuts
            .lines
            .iter()
            .any(|line| line == "Reset all shortcuts")
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should reset shortcuts"),
        DesktopCommandEffect::Repaint
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be written"),
    )
    .expect("persisted settings config should decode");
    assert!(decoded.shortcuts.bindings.is_empty());
    assert!(
        session
            .settings_snapshot()
            .expect("shortcuts settings should remain visible")
            .lines
            .iter()
            .any(|line| line == "Shortcut overrides: 0")
    );

    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close settings"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(
        session.command_palette_snapshot().is_some(),
        "reset should immediately restore the default command palette shortcut"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_shortcut_presets_persist_and_reapply_immediately() {
    let dir = test_directory("native-settings-shortcut-presets");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..2 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let shortcuts = session
        .settings_snapshot()
        .expect("shortcuts settings should be visible");
    assert_eq!(shortcuts.section, "shortcuts");
    assert!(
        shortcuts
            .lines
            .iter()
            .any(|line| line == "Apply Left-Hand Preset")
    );
    assert!(
        shortcuts
            .lines
            .iter()
            .any(|line| line == "Apply Right-Hand Preset")
    );

    for _ in 0..2 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should apply left-hand preset"),
        DesktopCommandEffect::Repaint
    );

    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("left preset config should be written"),
    )
    .expect("left preset settings config should decode");
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::ShowCommandPalette)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("command+x")
    );
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::FocusLeftPane)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("command+a")
    );
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::NextWorklane)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("control+tab")
    );
    assert!(
        matches!(
            shortcut_binding(&decoded, AppCommandId::CopyRaw),
            Some(binding) if binding.shortcut.is_none()
        ),
        "left-hand preset should explicitly unbind the default raw-copy shortcut"
    );

    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close settings"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Ignored
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('x'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(
        session.command_palette_snapshot().is_some(),
        "left-hand preset should immediately bind command palette to Ctrl+X"
    );
    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close command palette"),
        DesktopCommandEffect::Repaint
    );

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..2 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    for _ in 0..3 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should apply right-hand preset"),
        DesktopCommandEffect::Repaint
    );

    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("right preset config should be written"),
    )
    .expect("right preset settings config should decode");
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::ShowCommandPalette)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("command+;")
    );
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::FocusLeftPane)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("command+left")
    );
    assert_eq!(
        shortcut_binding(&decoded, AppCommandId::JumpToLatestNotification)
            .and_then(|binding| binding.shortcut.as_deref()),
        Some("command+shift+;")
    );

    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close settings again"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('x'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Ignored
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character(';'),
            DesktopKeyModifiers::control(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert!(
        session.command_palette_snapshot().is_some(),
        "right-hand preset should immediately bind command palette to Ctrl+Semicolon"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

fn shortcut_binding(
    config: &AppConfig,
    command_id: AppCommandId,
) -> Option<&ShortcutBindingOverride> {
    config
        .shortcuts
        .bindings
        .iter()
        .find(|binding| binding.command_id == command_id.raw_value())
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_general_window_and_clipboard_preferences_persist() {
    let dir = test_directory("native-settings-general-extra-persist");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    let general = session
        .settings_snapshot()
        .expect("general settings should be visible");
    assert_eq!(general.section, "general");
    assert!(
        general
            .lines
            .iter()
            .any(|line| line == "Confirm before closing window: enabled")
    );
    assert!(
        general
            .lines
            .iter()
            .any(|line| line == "Always clean copied content: disabled")
    );

    for _ in 0..3 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle close-window confirmation"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle always-clean copies"),
        DesktopCommandEffect::Repaint
    );
    let general = session
        .settings_snapshot()
        .expect("general settings should remain visible");
    assert!(
        general
            .lines
            .iter()
            .any(|line| line == "Confirm before closing window: disabled")
    );
    assert!(
        general
            .lines
            .iter()
            .any(|line| line == "Always clean copied content: enabled")
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("general settings config should be written"),
    )
    .expect("persisted general settings config should decode");
    assert!(!decoded.confirmations.confirm_before_closing_window);
    assert!(decoded.clipboard.always_clean_copies);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_notification_sound_preferences_persist() {
    let dir = test_directory("native-settings-notifications-persist");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..3 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let notifications = session
        .settings_snapshot()
        .expect("notifications settings should be visible");
    assert_eq!(notifications.section, "notifications");
    assert_eq!(notifications.selected_index, 0);
    assert!(
        notifications
            .lines
            .iter()
            .any(|line| line == "Sound: Default")
    );
    assert!(
        notifications
            .lines
            .iter()
            .any(|line| line == "Send Test Notification")
    );
    assert!(
        notifications
            .lines
            .iter()
            .any(|line| line == "Open Notification Settings")
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle notification sound"),
        DesktopCommandEffect::Repaint
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be written"),
    )
    .expect("persisted settings config should decode");
    assert_eq!(decoded.notifications.sound_name, "Basso");
    assert_eq!(decoded.notifications.custom_sound_display_name, None);
    assert!(
        session
            .settings_snapshot()
            .expect("notifications settings should remain visible")
            .lines
            .iter()
            .any(|line| line == "Sound: Basso")
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle notification sound again"),
        DesktopCommandEffect::Repaint
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be updated"),
    )
    .expect("updated settings config should decode");
    assert_eq!(decoded.notifications.sound_name, "Blow");

    for _ in 0..2 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should open notification settings"),
        DesktopCommandEffect::OpenUrl {
            url: "ms-settings:notifications".to_string(),
        }
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should send test notification"),
        DesktopCommandEffect::PaneNotification {
            notification: PaneNotification {
                title: "Zentty".to_string(),
                subtitle: Some("Settings".to_string()),
                body: Some("This is a test notification.".to_string()),
                include_inbox: false,
                is_silent: false,
                window_id: "window-main".to_string(),
                worklane_id: "main".to_string(),
                pane_id: "pane-main".to_string(),
            },
        }
    );
    assert!(
        session.pane_notifications().is_empty(),
        "test notification should not create an inbox item"
    );

    session.terminate().ok();

    let custom_config_path = dir.join("custom-config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            custom_config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.notifications.sound_name = "zentty-custom-old.caf".to_string();
    config.notifications.custom_sound_display_name = Some("Old Chime".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..3 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let notifications = session
        .settings_snapshot()
        .expect("custom notification settings should be visible");
    assert!(
        notifications
            .lines
            .iter()
            .any(|line| line == "Sound: Custom: Old Chime")
    );
    assert!(
        notifications
            .lines
            .iter()
            .any(|line| line == "Custom sound display: Old Chime")
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should clear custom sound to default"),
        DesktopCommandEffect::Repaint
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&custom_config_path).expect("custom settings config should be written"),
    )
    .expect("custom settings config should decode");
    assert_eq!(decoded.notifications.sound_name, "");
    assert_eq!(decoded.notifications.custom_sound_display_name, None);
    assert!(
        session
            .settings_snapshot()
            .expect("notifications settings should remain visible after clearing custom sound")
            .lines
            .iter()
            .any(|line| line == "Sound: Default")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_open_with_preferences_persist() {
    let dir = test_directory("native-settings-open-with-persist");
    let config_path = dir.join("config.toml");
    let custom_editor = dir.join("Editors").join("CustomEditor.exe");
    fs::create_dir_all(
        custom_editor
            .parent()
            .expect("custom editor should have parent"),
    )
    .expect("custom editor parent should be created");
    fs::write(&custom_editor, "fake exe").expect("custom editor should be written");

    let mut config = AppConfig::default();
    config.open_with.primary_target_id = "finder".to_string();
    config.open_with.enabled_target_ids = vec!["finder".to_string(), "custom:editor".to_string()];
    config.open_with.custom_apps = vec![OpenWithCustomApp {
        id: "custom:editor".to_string(),
        name: "Custom Editor".to_string(),
        path: custom_editor.to_string_lossy().to_string(),
    }];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("config should be written");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..4 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let open_with = session
        .settings_snapshot()
        .expect("open with settings should be visible");
    assert_eq!(open_with.section, "openWith");
    assert_eq!(open_with.selected_index, 0);
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Primary target: File Explorer (finder)")
    );
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Custom Editor: enabled")
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle primary open-with target"),
        DesktopCommandEffect::Repaint
    );
    let open_with = session
        .settings_snapshot()
        .expect("open with settings should remain visible");
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Primary target: Custom Editor (custom:editor)")
    );
    let custom_row_index = open_with
        .lines
        .iter()
        .position(|line| line == "Custom Editor: enabled")
        .expect("custom editor row should be visible");
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("open-with config should be written"),
    )
    .expect("persisted open-with config should decode");
    assert_eq!(persisted.open_with.primary_target_id, "custom:editor");

    for _ in 0..custom_row_index {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should disable custom open-with target"),
        DesktopCommandEffect::Repaint
    );
    let open_with = session
        .settings_snapshot()
        .expect("open with settings should remain visible after disable");
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Primary target: File Explorer (finder)")
    );
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Custom Editor: disabled")
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("open-with config should be updated"),
    )
    .expect("updated open-with config should decode");
    assert_eq!(persisted.open_with.primary_target_id, "finder");
    assert!(
        !persisted
            .open_with
            .enabled_target_ids
            .contains(&"custom:editor".to_string())
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should re-enable custom open-with target"),
        DesktopCommandEffect::Repaint
    );
    let open_with = session
        .settings_snapshot()
        .expect("open with settings should remain visible after re-enable");
    assert!(
        open_with
            .lines
            .iter()
            .any(|line| line == "Custom Editor: enabled")
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("open-with config should be updated again"),
    )
    .expect("re-enabled open-with config should decode");
    assert_eq!(persisted.open_with.primary_target_id, "finder");
    assert!(
        persisted
            .open_with
            .enabled_target_ids
            .contains(&"custom:editor".to_string())
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_dev_server_browser_preferences_persist() {
    let dir = test_directory("native-settings-dev-browser-persist");
    let config_path = dir.join("config.toml");
    let custom_browser = dir.join("Browsers").join("Preview.exe");
    let backup_browser = dir.join("Browsers").join("Backup.exe");
    fs::create_dir_all(
        custom_browser
            .parent()
            .expect("custom browser should have parent"),
    )
    .expect("custom browser parent should be created");
    fs::write(&custom_browser, "fake browser").expect("custom browser should be written");
    fs::write(&backup_browser, "fake backup browser").expect("backup browser should be written");

    let mut config = AppConfig::default();
    config.server_detection.preferred_browser_id = "system-default".to_string();
    config.server_detection.enabled_browser_target_ids =
        vec!["custom:preview".to_string(), "custom:backup".to_string()];
    config.server_detection.custom_browsers = vec![
        ServerBrowserCustomApp {
            id: "custom:preview".to_string(),
            name: "Preview Browser".to_string(),
            path: custom_browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        },
        ServerBrowserCustomApp {
            id: "custom:backup".to_string(),
            name: "Backup Browser".to_string(),
            path: backup_browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        },
    ];
    fs::write(&config_path, AppConfigToml::encode(&config)).expect("config should be written");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan::load(shell).expect("desktop launch should load");
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..5 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let dev_servers = session
        .settings_snapshot()
        .expect("dev server settings should be visible");
    assert_eq!(dev_servers.section, "devServers");
    assert_eq!(dev_servers.selected_index, 0);
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preferred browser: System Default (system-default)")
    );
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preview Browser: enabled")
    );
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Backup Browser: enabled")
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle preferred browser"),
        DesktopCommandEffect::Repaint
    );
    let dev_servers = session
        .settings_snapshot()
        .expect("dev server settings should remain visible");
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preferred browser: Preview Browser (custom:preview)")
    );
    let custom_row_index = dev_servers
        .lines
        .iter()
        .position(|line| line == "Preview Browser: enabled")
        .expect("custom browser row should be visible");
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("dev server config should be written"),
    )
    .expect("persisted dev server config should decode");
    assert_eq!(
        persisted.server_detection.preferred_browser_id,
        "custom:preview"
    );

    let selected_index = session
        .settings_snapshot()
        .expect("dev server settings should remain visible")
        .selected_index;
    for _ in selected_index..custom_row_index {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should disable custom browser"),
        DesktopCommandEffect::Repaint
    );
    let dev_servers = session
        .settings_snapshot()
        .expect("dev server settings should remain visible after disable");
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preferred browser: Backup Browser (custom:backup)")
    );
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preview Browser: disabled")
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("dev server config should be updated"),
    )
    .expect("updated dev server config should decode");
    assert_eq!(
        persisted.server_detection.preferred_browser_id,
        "custom:backup"
    );
    assert!(
        !persisted
            .server_detection
            .enabled_browser_target_ids
            .contains(&"custom:preview".to_string())
    );
    assert!(
        persisted
            .server_detection
            .enabled_browser_target_ids
            .contains(&"custom:backup".to_string())
    );

    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should re-enable custom browser"),
        DesktopCommandEffect::Repaint
    );
    let dev_servers = session
        .settings_snapshot()
        .expect("dev server settings should remain visible after re-enable");
    assert!(
        dev_servers
            .lines
            .iter()
            .any(|line| line == "Preview Browser: enabled")
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("dev server config should be updated again"),
    )
    .expect("re-enabled dev server config should decode");
    assert_eq!(
        persisted.server_detection.preferred_browser_id,
        "custom:backup"
    );
    assert!(
        persisted
            .server_detection
            .enabled_browser_target_ids
            .contains(&"custom:preview".to_string())
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_settings_pane_layout_preferences_persist() {
    let dir = test_directory("native-settings-pane-delay-persist");
    let config_path = dir.join("config.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSettings),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..6 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::RightArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    let pane_layout = session
        .settings_snapshot()
        .expect("pane layout settings should be visible");
    assert_eq!(pane_layout.section, "paneLayout");
    assert_eq!(pane_layout.selected_index, 0);
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Show pane labels: enabled")
    );
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Show project icons: enabled")
    );
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Smooth terminal scrolling: disabled")
    );
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Focus follows mouse delay: short")
    );
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Inactive pane opacity: 70%")
    );

    for _ in 0..3 {
        assert_eq!(
            session.execute_key_event(DesktopKeyEvent::new(
                DesktopKey::DownArrow,
                DesktopKeyModifiers::default()
            )),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .settings_snapshot()
            .expect("pane layout settings should remain visible")
            .selected_index,
        3
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle pane labels"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle project icons"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle smooth scrolling"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should toggle focus follows mouse"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle focus follows mouse delay"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session
            .write_char_event(' ')
            .expect("space should cycle inactive pane opacity"),
        DesktopCommandEffect::Repaint
    );
    let pane_layout = session
        .settings_snapshot()
        .expect("pane layout settings should remain visible");
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Focus follows mouse delay: immediate")
    );
    assert!(
        pane_layout
            .lines
            .iter()
            .any(|line| line == "Inactive pane opacity: 80%")
    );
    let decoded = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("settings config should be written"),
    )
    .expect("persisted settings config should decode");
    assert!(!decoded.panes.show_labels);
    assert!(!decoded.panes.show_project_icons);
    assert!(decoded.panes.smooth_scrolling_enabled);
    assert!(decoded.panes.focus_follows_mouse);
    assert_eq!(
        decoded.panes.focus_follows_mouse_delay,
        FocusFollowsMouseDelay::Immediate
    );
    assert!((decoded.panes.inactive_opacity - 0.8).abs() < f64::EPSILON);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_app_command_renames_active_worklane() {
    let dir = test_directory("native-worklane-rename-app-command");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.active_worklane_title(), Some("Main"));
    assert_eq!(
        session.execute_app_command(AppCommandId::RenameCurrentWorklane),
        DesktopCommandEffect::Repaint
    );
    let draft = session
        .worklane_rename_snapshot()
        .expect("rename prompt should be visible")
        .draft;
    assert_eq!(draft, "Main");
    assert!(
        session
            .render_lines(None)
            .iter()
            .any(|line| line == "Rename Worklane main: Main")
    );

    for _ in 0..draft.chars().count() {
        assert_eq!(
            session
                .write_char_event('\u{8}')
                .expect("draft should edit"),
            DesktopCommandEffect::Repaint
        );
    }
    for ch in "Project Alpha".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("draft should edit"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("rename should finish"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.worklane_rename_snapshot(), None);
    assert_eq!(session.active_worklane_title(), Some("Project Alpha"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_enter_executes_selected_command() {
    let dir = test_directory("native-command-palette-execute");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "new pane below".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("New Pane Below".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );

    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(session.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(session.focused_pane_id(), Some("pane-2"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_toggles_sidebar() {
    let dir = test_directory("native-command-palette-sidebar-toggle");
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.sidebar_snapshot().visibility, "pinnedOpen");
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "toggle sidebar".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Toggle Sidebar".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    let sidebar = session.sidebar_snapshot();
    assert_eq!(sidebar.visibility, "hidden");
    assert!(!sidebar.is_visible);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("palette sidebar command should persist config"),
    )
    .expect("persisted palette sidebar command config should decode");
    assert_eq!(persisted.sidebar.visibility, SidebarVisibility::Hidden);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_renames_active_worklane() {
    let dir = test_directory("native-worklane-rename-palette");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "rename worklane".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }
    assert!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone()))
            .is_some_and(|title| title.starts_with("Rename Worklane"))
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    let draft = session
        .worklane_rename_snapshot()
        .expect("rename prompt should be visible")
        .draft;
    for _ in 0..draft.chars().count() {
        assert_eq!(
            session
                .write_char_event('\u{8}')
                .expect("draft should edit"),
            DesktopCommandEffect::Repaint
        );
    }
    for ch in "Palette Lane".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("draft should edit"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("rename should finish"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.active_worklane_title(), Some("Palette Lane"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_theme_command_updates_theme_mode() {
    let dir = test_directory("native-command-palette-theme");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysDark);
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "use light theme".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Use Light Theme".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysLight);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_arrow_keys_move_selection() {
    let dir = test_directory("native-command-palette-selection");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "settings".chars() {
        session.write_char_event(ch).expect("query should update");
    }

    let first = session
        .command_palette_snapshot()
        .expect("palette should be open");
    assert_eq!(first.selected_index, Some(0));
    assert!(first.items[0].is_selected);

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    let second = session
        .command_palette_snapshot()
        .expect("palette should remain open");
    assert_eq!(second.selected_index, Some(1));
    assert!(!second.items[0].is_selected);
    assert!(second.items[1].is_selected);

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    let back_to_first = session
        .command_palette_snapshot()
        .expect("palette should remain open");
    assert_eq!(back_to_first.selected_index, Some(0));
    assert!(back_to_first.items[0].is_selected);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_executes_selected_non_first_item() {
    let dir = test_directory("native-command-palette-non-first");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "settings".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    let selected = session
        .command_palette_snapshot()
        .and_then(|snapshot| snapshot.items.get(1).map(|item| item.title.clone()))
        .expect("second settings item should be visible");
    assert_eq!(selected, "Appearance Settings");

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.command_palette_snapshot(), None);
    let settings = session
        .settings_snapshot()
        .expect("settings view should be visible");
    assert_eq!(settings.section, "appearance");
    assert_eq!(settings.title, "Appearance Settings");
    assert!(
        settings
            .lines
            .iter()
            .any(|line| line == "Theme mode: alwaysDark")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_render_lines_include_command_palette_query_and_results() {
    let dir = test_directory("native-command-palette-render");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "se".chars() {
        session.write_char_event(ch).expect("query should update");
    }

    let lines = session.render_lines(Some("palette active"));

    assert_eq!(
        lines.first().map(String::as_str),
        Some("Zentty: palette active")
    );
    assert!(
        lines.iter().any(|line| line == "Command Palette: se"),
        "rendered lines: {lines:?}"
    );
    assert!(
        lines.iter().any(|line| line.contains("General Settings")),
        "rendered lines: {lines:?}"
    );
    assert!(
        lines.iter().any(|line| line == "* shell"),
        "pane content should still render behind palette: {lines:?}"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_ctrl_shift_f_opens_pane_search_and_counts_matches() {
    let dir = test_directory("native-pane-search");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| session.plain_text().contains('>'));

    for ch in "alpha beta beta\r".chars() {
        session
            .write_char(ch)
            .expect("focused pane should accept input");
    }
    poll_until(&mut session, |session| {
        session.plain_text().contains("alpha beta beta")
    });

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('f'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "beta".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }

    let search = session
        .pane_search_snapshot()
        .expect("pane search should be visible");
    assert_eq!(search.pane_id, "pane-main");
    assert_eq!(search.query, "beta");
    assert_eq!(search.total, 2);
    assert_eq!(search.selected_index, None);

    let lines = session.render_lines(None);
    assert!(
        lines
            .iter()
            .any(|line| line == "Find pane-main: beta (2 matches)"),
        "rendered lines: {lines:?}"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_pane_search_arrow_keys_move_selection() {
    let dir = test_directory("native-pane-search-selection");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| session.plain_text().contains('>'));

    for ch in "alpha delta delta delta\r".chars() {
        session
            .write_char(ch)
            .expect("focused pane should accept input");
    }
    poll_until(&mut session, |session| {
        session.plain_text().contains("alpha delta delta delta")
    });

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('f'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "delta".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(session.pane_search_snapshot().unwrap().total, 3);

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.pane_search_snapshot().unwrap().selected_index,
        Some(0)
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.pane_search_snapshot().unwrap().selected_index,
        Some(1)
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::UpArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.pane_search_snapshot().unwrap().selected_index,
        Some(0)
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_find_opens_pane_search() {
    let dir = test_directory("native-pane-search-palette");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "find".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone()))
            .as_deref(),
        Some("Find")
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(
        session
            .pane_search_snapshot()
            .map(|snapshot| snapshot.pane_id),
        Some("pane-main".to_string())
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_global_find_searches_all_panes() {
    let dir = test_directory("native-global-search");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "100",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo ZENTTY_GLOBAL_LEFT_ONE ZENTTY_GLOBAL_LEFT_TWO & exit".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo ZENTTY_GLOBAL_RIGHT_ONE & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("ZENTTY_GLOBAL_LEFT_TWO"))
            && session
                .plain_text_for_pane("pane-right")
                .is_some_and(|text| text.contains("ZENTTY_GLOBAL_RIGHT_ONE"))
    });

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "global find".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone()))
            .as_deref(),
        Some("Global Find")
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.command_palette_snapshot(), None);
    assert_eq!(session.global_search_snapshot().unwrap().query, "");

    for ch in "ZENTTY_GLOBAL".chars() {
        assert_eq!(
            session.write_char_event(ch).expect("query should update"),
            DesktopCommandEffect::Repaint
        );
    }

    let search = session
        .global_search_snapshot()
        .expect("global search should be visible");
    assert_eq!(search.query, "ZENTTY_GLOBAL");
    assert_eq!(search.total, 3);
    assert_eq!(search.selected_index, None);

    let lines = session.render_lines(None);
    assert!(
        lines
            .iter()
            .any(|line| line == "Global Find: ZENTTY_GLOBAL (3 matches)"),
        "rendered lines: {lines:?}"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_copy_shortcut_and_palette_copy_selected_text() {
    let dir = test_directory("native-selection-copy");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo $ cargo test & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session.plain_text().contains("$ cargo test")
    });
    let (line_index, start_column) = focused_line_and_column(&session, "$ cargo test");
    assert!(session.select_focused_pane_range(
        TerminalTextPoint {
            line_index,
            column: start_column,
        },
        TerminalTextPoint {
            line_index,
            column: start_column + "$ cargo test".len(),
        },
    ));
    assert_eq!(
        session.selected_text_for_focused_pane().as_deref(),
        Some("$ cargo test")
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('c'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::CopyText {
            text: "$ cargo test".to_string(),
            was_cleaned: false,
        }
    );

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "clean copy".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone()))
            .as_deref(),
        Some("Clean Copy")
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::CopyText {
            text: "cargo test".to_string(),
            was_cleaned: true,
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_copy_shortcut_honors_always_clean_preference() {
    let dir = test_directory("native-selection-copy-auto-clean");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.clipboard.always_clean_copies = true;
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo $ cargo test & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session.plain_text().contains("$ cargo test")
    });
    let (line_index, start_column) = focused_line_and_column(&session, "$ cargo test");
    assert!(session.select_focused_pane_range(
        TerminalTextPoint {
            line_index,
            column: start_column,
        },
        TerminalTextPoint {
            line_index,
            column: start_column + "$ cargo test".len(),
        },
    ));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('c'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::CopyText {
            text: "cargo test".to_string(),
            was_cleaned: true,
        }
    );
    assert_eq!(
        session.execute_app_command(AppCommandId::CopyRaw),
        DesktopCommandEffect::CopyText {
            text: "$ cargo test".to_string(),
            was_cleaned: false,
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_copy_raw_shortcut_override_ignores_always_clean_preference() {
    let dir = test_directory("native-selection-copy-auto-clean-override");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.clipboard.always_clean_copies = true;
    config.shortcuts.bindings = vec![ShortcutBindingOverride {
        command_id: AppCommandId::CopyRaw.raw_value().to_string(),
        shortcut: Some("command+shift+c".to_string()),
    }];
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo $ cargo test & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session.plain_text().contains("$ cargo test")
    });
    let (line_index, start_column) = focused_line_and_column(&session, "$ cargo test");
    assert!(session.select_focused_pane_range(
        TerminalTextPoint {
            line_index,
            column: start_column,
        },
        TerminalTextPoint {
            line_index,
            column: start_column + "$ cargo test".len(),
        },
    ));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('c'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::CopyText {
            text: "$ cargo test".to_string(),
            was_cleaned: false,
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_use_selection_for_find_opens_search_with_selected_text() {
    let dir = test_directory("native-selection-find");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo alpha beta beta & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session.plain_text().contains("alpha beta beta")
    });
    let (line_index, start_column) = focused_line_and_column(&session, "beta");
    assert!(session.select_focused_pane_range(
        TerminalTextPoint {
            line_index,
            column: start_column,
        },
        TerminalTextPoint {
            line_index,
            column: start_column + "beta".len(),
        },
    ));

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "use selection for find".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone()))
            .as_deref(),
        Some("Use Selection for Find")
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );

    let search = session
        .pane_search_snapshot()
        .expect("pane search should be visible");
    assert_eq!(search.pane_id, "pane-main");
    assert_eq!(search.query, "beta");
    assert_eq!(search.total, 2);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_global_search_navigation_moves_between_matching_panes() {
    let dir = test_directory("native-global-search-navigation");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "100",
            "--rows",
            "8",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("echo ZENTTY_NAV_LEFT_ONE ZENTTY_NAV_LEFT_TWO & exit".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("echo ZENTTY_NAV_RIGHT_ONE & exit".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("ZENTTY_NAV_LEFT_TWO"))
            && session
                .plain_text_for_pane("pane-right")
                .is_some_and(|text| text.contains("ZENTTY_NAV_RIGHT_ONE"))
    });

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "global find".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    session
        .write_char_event('\r')
        .expect("enter should execute selected item");
    for ch in "ZENTTY_NAV".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(session.global_search_snapshot().unwrap().total, 3);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.global_search_snapshot().unwrap().selected_index,
        Some(0)
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.global_search_snapshot().unwrap().selected_index,
        Some(1)
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default(),
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        session.global_search_snapshot().unwrap().selected_index,
        Some(2)
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_close_focused_pane_updates_focus_and_rejects_last_pane() {
    let dir = test_directory("close-focused");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        session.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::RequestCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_restores_last_closed_pane_as_live_pty() {
    let dir = test_directory("restore-closed");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .environment_variables
        .push((
            "ZENTTY_DESKTOP_RESTORE_ENV".to_string(),
            "restored".to_string(),
        ));
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(
        session.execute_command(AppCommandId::RestoreClosedPane),
        AppCommandExecutionResult::RestoredClosedPane {
            pane_id: "pane-right".to_string(),
            worklane_id: "main".to_string(),
            toast_message: "Restored \"right\"".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    for ch in "echo ZENTTY_DESKTOP_RESTORED %ZENTTY_DESKTOP_RESTORE_ENV%\r".chars() {
        session
            .write_char(ch)
            .expect("restored pane should accept input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_RESTORED restored"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_RESTORED restored"),
        "restored pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_restores_closed_pane_from_emptied_worklane() {
    let dir = test_directory("restore-closed-worklane");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let mut alpha = app.windows[0].worklanes[0].clone();
    alpha.worklane_id = "alpha".to_string();
    alpha.focused_pane_id = Some("pane-alpha".to_string());
    alpha.panes[0].worklane_id = "alpha".to_string();
    alpha.panes[0].pane_id = "pane-alpha".to_string();
    alpha.panes[0].title = "alpha".to_string();
    alpha.panes[0].column_id = "column-alpha".to_string();
    let mut beta = alpha.clone();
    beta.worklane_id = "beta".to_string();
    beta.focused_pane_id = Some("pane-beta".to_string());
    beta.panes[0].worklane_id = "beta".to_string();
    beta.panes[0].pane_id = "pane-beta".to_string();
    beta.panes[0].title = "beta".to_string();
    beta.panes[0].column_id = "column-beta".to_string();
    beta.panes[0].terminal_request.command = Some("findstr .".to_string());
    app.windows[0].active_worklane_id = Some("alpha".to_string());
    app.windows[0].worklanes = vec![alpha, beta];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::NextWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-beta"));
    assert_eq!(
        session.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-alpha"));
    assert_eq!(session.pane_ids(), vec!["pane-alpha"]);

    assert_eq!(
        session.execute_command(AppCommandId::RestoreClosedPane),
        AppCommandExecutionResult::RestoredClosedPane {
            pane_id: "pane-beta".to_string(),
            worklane_id: "beta".to_string(),
            toast_message: "Restored \"beta\"".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-alpha", "pane-beta"]);
    assert_eq!(session.focused_pane_id(), Some("pane-beta"));

    for ch in "ZENTTY_RESTORED_WORKLANE\r".chars() {
        session
            .write_char(ch)
            .expect("restored worklane pane should accept focused input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-beta")
            .is_some_and(|text| text.contains("ZENTTY_RESTORED_WORKLANE"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-beta")
            .unwrap_or_default()
            .contains("ZENTTY_RESTORED_WORKLANE"),
        "restored pane text: {}",
        session.plain_text_for_pane("pane-beta").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_split_commands_spawn_live_focused_panes() {
    let dir = test_directory("split-focused");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::SplitHorizontally),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(session.focused_pane_id(), Some("pane-2"));
    assert_eq!(session.pane_snapshots()[1].title, "pane 2");
    assert_eq!(
        session
            .pane_snapshots()
            .iter()
            .map(|snapshot| snapshot.column_width)
            .collect::<Vec<_>>(),
        vec![640.0, 640.0]
    );

    for ch in "ZENTTY_SPLIT_INPUT\r".chars() {
        session
            .write_char(ch)
            .expect("split focused pane should accept input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-2")
            .is_some_and(|text| text.contains("ZENTTY_SPLIT_INPUT"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-2")
            .unwrap_or_default()
            .contains("ZENTTY_SPLIT_INPUT"),
        "split pane text: {}",
        session.plain_text_for_pane("pane-2").unwrap_or_default()
    );

    assert_eq!(
        session.execute_command(AppCommandId::SplitVertically),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.pane_ids(), vec!["pane-main", "pane-2", "pane-3"]);
    assert_eq!(session.focused_pane_id(), Some("pane-3"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_applies_configured_visible_right_split_behavior() {
    let dir = test_directory("split-right-visible-config");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.pane_layout.right_split_behavior = PaneSplitBehaviorMode::AlwaysSplit;
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::SplitHorizontally),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        session
            .pane_snapshots()
            .iter()
            .map(|snapshot| snapshot.column_width)
            .collect::<Vec<_>>(),
        vec![320.0, 320.0]
    );
    assert_eq!(session.focused_pane_id(), Some("pane-2"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_force_add_bypasses_visible_split_behavior() {
    let dir = test_directory("split-right-force-add");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.pane_layout.right_split_behavior = PaneSplitBehaviorMode::AlwaysSplit;
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::ForceAddPaneRight),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        session
            .pane_snapshots()
            .iter()
            .map(|snapshot| snapshot.column_width)
            .collect::<Vec<_>>(),
        vec![640.0, 640.0]
    );
    assert_eq!(session.focused_pane_id(), Some("pane-2"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_window_commands_return_handoff_results() {
    let dir = test_directory("window-command-handoffs");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(dir.to_string_lossy().to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::CloseWindow),
        AppCommandExecutionResult::RequestCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(
        session.execute_command(AppCommandId::NewWindow),
        AppCommandExecutionResult::RequestNewWindow {
            working_directory: Some(dir.to_string_lossy().to_string()),
        }
    );
    assert_eq!(
        session.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::Unavailable,
        "desktop should not detach the only pane"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_palette_window_commands_return_native_effects() {
    let dir = test_directory("window-command-effects");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(dir.to_string_lossy().to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "new window".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::NewWindow {
            working_directory: Some(dir.to_string_lossy().to_string()),
        }
    );
    session.terminate().ok();

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing-again.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "move pane to new window".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::MovePaneToNewWindow {
            pane_id: "pane-right".to_string(),
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_spawns_new_window_session_from_requested_context() {
    let dir = test_directory("desktop-native-new-window-session");
    let path = dir.to_string_lossy().to_string();
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    let mut new_window = session
        .spawn_new_window_session(Some(path.clone()))
        .expect("new desktop window session should spawn");

    assert_eq!(
        new_window.execute_command(AppCommandId::CopyFocusedPanePath),
        AppCommandExecutionResult::CopyText { text: path }
    );
    for ch in "echo ZENTTY_NATIVE_NEW_WINDOW_SESSION\r".chars() {
        new_window
            .write_char(ch)
            .expect("new window pane should accept input");
    }
    poll_until(&mut new_window, |session| {
        session
            .plain_text_for_pane("pane-2")
            .is_some_and(|text| text.contains("ZENTTY_NATIVE_NEW_WINDOW_SESSION"))
    });
    assert!(
        new_window
            .plain_text_for_pane("pane-2")
            .unwrap_or_default()
            .contains("ZENTTY_NATIVE_NEW_WINDOW_SESSION"),
        "new window text: {}",
        new_window.plain_text_for_pane("pane-2").unwrap_or_default()
    );

    new_window.terminate().ok();
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_new_window_gets_independent_agent_ipc_environment() {
    let dir = test_directory("desktop-native-new-window-agent-ipc");
    let path = dir.to_string_lossy().to_string();
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "96",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };
    let parent_ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-parent-window-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "parent-window-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-main", "parent-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, parent_ipc_environment)
        .expect("desktop session should spawn");
    let parent_socket = session
        .agent_ipc_socket_path()
        .expect("parent should have ipc")
        .to_string();
    let mut new_window = session
        .spawn_new_window_session(Some(path))
        .expect("new desktop window session should spawn");
    let child_socket = new_window
        .agent_ipc_socket_path()
        .expect("child window should have ipc")
        .to_string();

    assert_ne!(child_socket, parent_socket);

    for ch in "echo ZENTTY_NEW_WINDOW_IPC %ZENTTY_INSTANCE_SOCKET% %ZENTTY_PANE_TOKEN% %ZENTTY_CLI_BIN% %ZENTTY_INSTANCE_ID%\r".chars() {
        new_window
            .write_char(ch)
            .expect("new window pane should accept input");
    }
    poll_until(&mut new_window, |session| {
        session
            .plain_text_for_pane("pane-2")
            .is_some_and(|text| text.contains(&child_socket))
    });
    let pane_text = new_window.plain_text_for_pane("pane-2").unwrap_or_default();
    let compact_pane_text = pane_text.replace('\n', "");
    assert!(
        compact_pane_text.contains(&child_socket),
        "new window text: {pane_text}"
    );
    assert!(
        compact_pane_text.contains("zentty-win.exe"),
        "new window text: {pane_text}"
    );
    assert!(
        !compact_pane_text.contains("parent-token")
            && !compact_pane_text.contains("parent-window-instance"),
        "new window text: {pane_text}"
    );

    new_window.terminate().ok();
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_detaches_focused_live_pane_to_new_window_session() {
    let dir = test_directory("desktop-native-detach-pane");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    let mut moved = session
        .detach_focused_pane_to_new_window_session()
        .expect("focused pane should detach into a new desktop window session");

    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(moved.pane_ids(), vec!["pane-right"]);
    assert_eq!(moved.focused_pane_id(), Some("pane-right"));

    for ch in "ZENTTY_MOVED_NATIVE_WINDOW\r".chars() {
        moved.write_char(ch).expect("moved pane should remain live");
    }
    poll_until(&mut moved, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_MOVED_NATIVE_WINDOW"))
    });
    assert!(
        moved
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_MOVED_NATIVE_WINDOW"),
        "moved pane text: {}",
        moved.plain_text_for_pane("pane-right").unwrap_or_default()
    );

    for ch in "ZENTTY_SOURCE_NATIVE_WINDOW\r".chars() {
        session
            .write_char(ch)
            .expect("source pane should remain live");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-left")
            .is_some_and(|text| text.contains("ZENTTY_SOURCE_NATIVE_WINDOW"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-left")
            .unwrap_or_default()
            .contains("ZENTTY_SOURCE_NATIVE_WINDOW"),
        "source pane text: {}",
        session.plain_text_for_pane("pane-left").unwrap_or_default()
    );

    moved.terminate().ok();
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_preserves_open_context_for_commands() {
    let dir = test_directory("desktop-open-context");
    let path = dir.to_string_lossy().to_string();
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        ["--config", config_path.to_string_lossy().as_ref()],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(path.clone());
    app.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "vscode",
        OpenWithTargetKind::Editor,
        "Visual Studio Code",
        Some(OpenWithBuiltInTargetId::VsCode),
        Some("C:\\Program Files\\Microsoft VS Code\\Code.exe"),
    )];
    app.windows[0].detected_servers = vec![DetectedServer::new(
        "server-5173",
        "http://localhost:5173",
        "http://localhost:5173/",
        "localhost:5173",
    )];
    app.windows[0].branch_urls_by_pane_id.insert(
        "pane-main".to_string(),
        "https://github.com/ucsandman/zentty/tree/feature/windows".to_string(),
    );
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::OpenWithSelectedApp),
        AppCommandExecutionResult::OpenPathWithTarget {
            path,
            target_id: "vscode".to_string(),
            target_name: "Visual Studio Code".to_string(),
            app_path: Some("C:\\Program Files\\Microsoft VS Code\\Code.exe".to_string()),
        }
    );
    assert_eq!(
        session.execute_command(AppCommandId::OpenSelectedServer),
        AppCommandExecutionResult::OpenServer {
            server_id: "server-5173".to_string(),
            origin: "http://localhost:5173".to_string(),
            url: "http://localhost:5173/".to_string(),
        }
    );
    assert_eq!(
        session.execute_command(AppCommandId::OpenBranchOnRemote),
        AppCommandExecutionResult::OpenUrl {
            url: "https://github.com/ucsandman/zentty/tree/feature/windows".to_string(),
        }
    );
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenWithSelectedApp),
        DesktopCommandEffect::OpenPathWithTarget {
            path: dir.to_string_lossy().to_string(),
            target_id: "vscode".to_string(),
            target_name: "Visual Studio Code".to_string(),
            app_path: Some("C:\\Program Files\\Microsoft VS Code\\Code.exe".to_string()),
        }
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("open-with command should persist config"),
    )
    .expect("persisted open-with command config should decode");
    assert_eq!(persisted.open_with.primary_target_id, "vscode");

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_detects_server_urls_from_pane_output() {
    let dir = test_directory("desktop-detect-server-output");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let app = default_app_launch_plan();
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.detected_servers(), &[]);

    session
        .feed_output_for_pane(
            "pane-main",
            b"Docs: https://example.com:443 Local: http://127.0.0.1:5173/docs?q=1#top\r\n",
        )
        .expect("pane output should feed");

    let detected = session.detected_servers();
    assert_eq!(detected.len(), 1);
    assert_eq!(detected[0].id, "main|pane-main|watch|http://localhost:5173");
    assert_eq!(detected[0].origin, "http://localhost:5173");
    assert_eq!(detected[0].url, "http://localhost:5173/docs?q=1#top");
    assert_eq!(detected[0].display, "localhost:5173");
    assert_eq!(detected[0].worklane_id, "main");
    assert_eq!(detected[0].pane_id.as_deref(), Some("pane-main"));
    assert_eq!(detected[0].source, DetectedServerSource::Watch);
    assert_eq!(detected[0].confidence, DetectedServerConfidence::Explicit);
    assert_eq!(
        session.execute_command(AppCommandId::OpenSelectedServer),
        AppCommandExecutionResult::OpenServer {
            server_id: "main|pane-main|watch|http://localhost:5173".to_string(),
            origin: "http://localhost:5173".to_string(),
            url: "http://localhost:5173/docs?q=1#top".to_string(),
        }
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers {
                control: true,
                alt: false,
                shift: true,
            },
        )),
        DesktopCommandEffect::Repaint
    );
    for ch in "localhost 5173".chars() {
        assert_eq!(
            session
                .write_char_event(ch)
                .expect("command palette query should update"),
            DesktopCommandEffect::Repaint
        );
    }
    let snapshot = session
        .command_palette_snapshot()
        .expect("command palette should be visible");
    assert!(
        snapshot
            .items
            .iter()
            .any(|item| item.title == "Open localhost:5173"
                && item.subtitle == "http://localhost:5173/docs?q=1#top")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_open_items_return_external_open_effects() {
    let dir = test_directory("desktop-open-effects");
    let path = dir.to_string_lossy().to_string();
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        ["--config", config_path.to_string_lossy().as_ref()],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(path.clone());
    app.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "vscode",
        OpenWithTargetKind::Editor,
        "Visual Studio Code",
        Some(OpenWithBuiltInTargetId::VsCode),
        Some("C:\\Program Files\\Microsoft VS Code\\Code.exe"),
    )];
    app.windows[0].detected_servers = vec![DetectedServer::new(
        "server-5173",
        "http://localhost:5173",
        "http://localhost:5173/",
        "localhost:5173",
    )];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "visual studio code".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Visual Studio Code".to_string())
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::OpenPathWithTarget {
            path,
            target_id: "vscode".to_string(),
            target_name: "Visual Studio Code".to_string(),
            app_path: Some("C:\\Program Files\\Microsoft VS Code\\Code.exe".to_string()),
        }
    );
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("open-with target should persist config"),
    )
    .expect("persisted open-with config should decode");
    assert_eq!(persisted.open_with.primary_target_id, "vscode");

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "localhost:5173".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Open localhost:5173".to_string())
    );
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::OpenUrl {
            url: "http://localhost:5173/".to_string(),
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_task_runner_launches_new_pane() {
    let dir = test_directory("desktop-task-runner");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].task_runner_actions = vec![
        TaskRunnerAction::new(
            "package|package.json|dev",
            "dev",
            None,
            TaskRunnerSourceKind::PackageScript,
            dir.join("package.json").to_string_lossy(),
            "echo ZENTTY_DESKTOP_TASK_%ZENTTY_TASK_ENV% & exit",
            None,
        )
        .with_working_directory(dir.to_string_lossy())
        .with_environment("ZENTTY_TASK_ENV", "OK"),
    ];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task dev".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Run task: dev".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(session.focused_pane_id(), Some("pane-2"));
    assert_eq!(session.pane_snapshots()[1].title, "dev");

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-2")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_OK"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-2")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_OK"),
        "task pane text: {}",
        session.plain_text_for_pane("pane-2").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_uses_recorded_idle_shell_state_for_task_runner() {
    let dir = test_directory("desktop-task-runner-recorded-idle");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|recorded-idle",
        "recorded idle",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DESKTOP_TASK_RECORDED_IDLE",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert!(
        session.record_pane_shell_activity_state(
            "pane-right",
            TaskRunnerShellActivityState::PromptIdle
        )
    );

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task recorded idle".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Run task: recorded idle".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_RECORDED_IDLE"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_RECORDED_IDLE"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );
    assert!(
        !session
            .plain_text_for_pane("pane-left")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_RECORDED_IDLE"),
        "left pane text: {}",
        session.plain_text_for_pane("pane-left").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_applies_agent_shell_state_signal_to_task_runner_policy() {
    let dir = test_directory("desktop-task-runner-agent-signal");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|agent-signal",
        "agent signal",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DESKTOP_TASK_AGENT_SIGNAL",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    let signal = AgentSignalCommand::parse(
        &[
            "ipc".to_string(),
            "agent-signal".to_string(),
            "shell-state".to_string(),
            "prompt".to_string(),
        ],
        &BTreeMap::from([
            ("ZENTTY_WINDOW_ID".to_string(), "window-main".to_string()),
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-right".to_string()),
        ]),
    )
    .expect("shell-state signal should parse");
    assert!(session.apply_agent_signal(&signal.payload));

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task agent signal".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_AGENT_SIGNAL"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_AGENT_SIGNAL"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_agent_signal_ipc_request() {
    let dir = test_directory("desktop-task-runner-agent-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|agent-ipc",
        "agent ipc",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DESKTOP_TASK_AGENT_IPC",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-right", "valid-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");
    assert_eq!(
        session.handle_agent_ipc_request(desktop_agent_signal_request(
            "desktop-ipc-auth",
            "valid-token",
            true
        )),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-ipc-auth".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = session.task_manager_pane_sources();
    let right_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-right")
        .expect("right pane task manager source should exist");
    assert_eq!(right_source.status_text.as_deref(), Some("Idle"));
    assert_eq!(right_source.root_pid, None);

    let mut root_pid_request =
        desktop_agent_signal_request("desktop-ipc-root-pid", "valid-token", true);
    root_pid_request.arguments = vec![
        "pane-root-pid".to_string(),
        "attach".to_string(),
        "4242".to_string(),
    ];
    assert_eq!(
        session.handle_agent_ipc_request(root_pid_request),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-ipc-root-pid".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = session.task_manager_pane_sources();
    let right_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-right")
        .expect("right pane task manager source should exist");
    assert_eq!(right_source.root_pid, Some(4242));

    let mut clear_root_pid_request =
        desktop_agent_signal_request("desktop-ipc-root-pid-clear", "valid-token", true);
    clear_root_pid_request.arguments = vec!["pane-root-pid".to_string(), "clear".to_string()];
    assert_eq!(
        session.handle_agent_ipc_request(clear_root_pid_request),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-ipc-root-pid-clear".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = session.task_manager_pane_sources();
    let right_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-right")
        .expect("right pane task manager source should exist");
    assert_eq!(right_source.root_pid, None);

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task agent ipc".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_AGENT_IPC"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_AGENT_IPC"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_open_bookmarks_popover_renders_stored_templates() {
    let dir = test_directory("desktop-bookmarks-popover");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.pinned = true;
    bookmark.project_root = Some(r"C:\Projects\api".to_string());
    let mut preset = WorkspaceTemplate::new("Two pane", WorkspaceTemplateKind::Preset);
    preset.title = Some("Preset title".to_string());
    store.upsert(bookmark).expect("bookmark should persist");
    store.upsert(preset).expect("preset should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.bookmarks_snapshot(), None);

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    let snapshot = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored");
    let rendered_snapshot = snapshot.lines.join("\n");
    assert!(rendered_snapshot.contains("Bookmarks & Presets"));
    assert!(rendered_snapshot.contains("Bookmarks"));
    assert!(rendered_snapshot.contains("* API - C:\\Projects\\api (bookmark, 0 panes)"));
    assert!(rendered_snapshot.contains("Presets"));
    assert!(rendered_snapshot.contains("- Two pane - Preset title (preset, 0 panes)"));

    let rendered_session = session.render_lines(None).join("\n");
    assert!(rendered_session.contains("Bookmarks & Presets"));
    assert!(!rendered_session.contains("Bookmarks requested"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_filters_and_moves_selection() {
    let dir = test_directory("desktop-bookmarks-popover-filter");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.pinned = true;
    bookmark.project_root = Some(r"C:\Projects\api".to_string());
    let mut preset = WorkspaceTemplate::new("Two pane", WorkspaceTemplateKind::Preset);
    preset.title = Some("Preset title".to_string());
    store.upsert(bookmark).expect("bookmark should persist");
    store.upsert(preset).expect("preset should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("> * API - C:\\Projects\\api (bookmark, 0 panes)"));
    assert!(rendered.contains("  - Two pane - Preset title (preset, 0 panes)"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("  * API - C:\\Projects\\api (bookmark, 0 panes)"));
    assert!(rendered.contains("> - Two pane - Preset title (preset, 0 panes)"));

    for ch in "two".chars() {
        assert_eq!(
            session
                .write_char_event(ch)
                .expect("bookmark query character should be handled"),
            DesktopCommandEffect::Repaint
        );
    }
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("Bookmarks & Presets: two"));
    assert!(!rendered.contains("API - C:\\Projects\\api"));
    assert!(rendered.contains("> - Two pane - Preset title (preset, 0 panes)"));

    assert_eq!(
        session
            .write_char_event('\u{1b}')
            .expect("escape should close bookmarks"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.bookmarks_snapshot(), None);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_mutates_selected_template() {
    let dir = test_directory("desktop-bookmarks-popover-mutate");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.project_root = Some(r"C:\Projects\api".to_string());
    let mut preset = WorkspaceTemplate::new("Two pane", WorkspaceTemplateKind::Preset);
    preset.title = Some("Preset title".to_string());
    store.upsert(bookmark).expect("bookmark should persist");
    store.upsert(preset).expect("preset should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("> - API - C:\\Projects\\api (bookmark, 0 panes)"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('p'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert!(
        reloaded
            .templates()
            .iter()
            .find(|template| template.name == "API")
            .expect("API bookmark should remain")
            .pinned
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("> * API - C:\\Projects\\api (bookmark, 0 panes)"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('d'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert!(
        reloaded
            .templates()
            .iter()
            .any(|template| template.name == "API copy")
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("> - API copy - C:\\Projects\\api (bookmark, 0 panes)"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Delete,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert!(
        !reloaded
            .templates()
            .iter()
            .any(|template| template.name == "API copy")
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(!rendered.contains("API copy"));
    assert!(rendered.contains("* API - C:\\Projects\\api (bookmark, 0 panes)"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_renames_selected_template() {
    let dir = test_directory("desktop-bookmarks-popover-rename");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.project_root = Some(r"C:\Projects\api".to_string());
    store.upsert(bookmark).expect("bookmark should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('r'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("Rename Bookmark: API"));

    for _ in 0..3 {
        assert_eq!(
            session
                .write_char_event('\u{8}')
                .expect("backspace should edit rename draft"),
            DesktopCommandEffect::Repaint
        );
    }
    for ch in "Docs".chars() {
        assert_eq!(
            session
                .write_char_event(ch)
                .expect("rename character should edit draft"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should persist rename"),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert_eq!(reloaded.templates()[0].name, "Docs");
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("> - Docs - C:\\Projects\\api (bookmark, 0 panes)"));
    assert!(!rendered.contains("Rename Bookmark"));

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('r'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    for _ in 0..4 {
        assert_eq!(
            session
                .write_char_event('\u{8}')
                .expect("backspace should edit rename draft"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("empty rename should close rename mode"),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert_eq!(reloaded.templates()[0].name, "Docs");

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_saves_active_worklane_templates() {
    let dir = test_directory("desktop-bookmarks-popover-save-active");
    let project = dir.join("project");
    let api = project.join("api");
    let worker = project.join("worker");
    fs::create_dir_all(&api).expect("api dir should be created");
    fs::create_dir_all(&worker).expect("worker dir should be created");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].title = Some("Project API".to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(api.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("cmd.exe /C echo LEFT".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .working_directory = Some(worker.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("npm run dev".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('b'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("Save Bookmark: Project API"));
    for ch in " v2".chars() {
        assert_eq!(
            session
                .write_char_event(ch)
                .expect("save draft character should be handled"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should save bookmark"),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    let saved_bookmark = reloaded
        .templates()
        .iter()
        .find(|template| template.name == "Project API v2")
        .expect("bookmark should be saved");
    assert_eq!(saved_bookmark.kind, WorkspaceTemplateKind::Bookmark);
    assert_eq!(
        saved_bookmark.project_root,
        Some(project.to_string_lossy().to_string())
    );
    assert_eq!(
        saved_bookmark.columns[0].panes[0].working_directory,
        Some(api.to_string_lossy().to_string())
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('s'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should be stored")
        .lines
        .join("\n");
    assert!(rendered.contains("Save Preset: 2 panes: npm"));
    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should save preset"),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    let saved_preset = reloaded
        .templates()
        .iter()
        .find(|template| template.name == "2 panes: npm")
        .expect("preset should be saved");
    assert_eq!(saved_preset.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(saved_preset.project_root, None);
    assert_eq!(saved_preset.columns[0].panes[0].working_directory, None);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_converts_selected_template() {
    let dir = test_directory("desktop-bookmarks-popover-convert");
    let project = dir.join("project");
    let saved = project.join("saved");
    let live_left = project.join("live-left");
    let live_right = project.join("live-right");
    fs::create_dir_all(&saved).expect("saved dir should be created");
    fs::create_dir_all(&live_left).expect("live left dir should be created");
    fs::create_dir_all(&live_right).expect("live right dir should be created");

    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.project_root = Some(saved.to_string_lossy().to_string());
    bookmark.columns = vec![WorkspaceTemplateColumn {
        id: "saved-column".to_string(),
        width: 640.0,
        focused_pane_id: Some("saved-pane".to_string()),
        last_focused_pane_id: Some("saved-pane".to_string()),
        pane_heights: vec![1.0],
        panes: vec![WorkspaceTemplatePane {
            id: "saved-pane".to_string(),
            title_seed: Some("server".to_string()),
            working_directory: Some(saved.to_string_lossy().to_string()),
            command: Some("cargo test".to_string()),
            environment: BTreeMap::from([
                ("CUSTOM".to_string(), "kept".to_string()),
                ("ZENTTY_PANE_ID".to_string(), "unsafe".to_string()),
            ]),
            was_user_edited: false,
        }],
    }];
    let original_bookmark_id = bookmark.id.clone();
    let mut preset = WorkspaceTemplate::new("Two pane", WorkspaceTemplateKind::Preset);
    preset.color = Some("pink".to_string());
    preset.title = Some("Saved layout".to_string());
    store.upsert(bookmark).expect("bookmark should persist");
    store.upsert(preset).expect("preset should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].title = Some("Live Project".to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(live_left.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("cmd.exe /C echo LEFT".to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .working_directory = Some(live_right.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("npm run dev".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('t'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    let converted_preset = reloaded
        .templates()
        .iter()
        .find(|template| template.name == "API (preset)")
        .expect("bookmark should convert to preset copy");
    assert_ne!(converted_preset.id, original_bookmark_id);
    assert_eq!(converted_preset.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(converted_preset.project_root, None);
    assert_eq!(converted_preset.columns[0].panes[0].working_directory, None);
    assert_eq!(
        converted_preset.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );
    let rendered = session
        .bookmarks_snapshot()
        .expect("bookmarks snapshot should remain open")
        .lines
        .join("\n");
    assert!(rendered.contains("> - API (preset) (preset, 1 pane)"));

    for ch in "two".chars() {
        assert_eq!(
            session
                .write_char_event(ch)
                .expect("bookmark query should be handled"),
            DesktopCommandEffect::Repaint
        );
    }
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('t'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Repaint
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    let converted_bookmark = reloaded
        .templates()
        .iter()
        .find(|template| template.name == "Two pane (bookmark)")
        .expect("preset should convert to active-worklane bookmark");
    assert_eq!(converted_bookmark.kind, WorkspaceTemplateKind::Bookmark);
    assert_eq!(converted_bookmark.title, Some("Live Project".to_string()));
    assert_eq!(converted_bookmark.color, Some("pink".to_string()));
    assert_eq!(
        converted_bookmark.project_root,
        Some(project.to_string_lossy().to_string())
    );
    assert_eq!(converted_bookmark.columns.len(), 2);
    assert_eq!(
        converted_bookmark.columns[0].panes[0].working_directory,
        Some(live_left.to_string_lossy().to_string())
    );
    assert_eq!(
        converted_bookmark.columns[1].panes[0].working_directory,
        Some(live_right.to_string_lossy().to_string())
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmarks_popover_reveals_selected_template_path() {
    let dir = test_directory("desktop-bookmarks-popover-reveal");
    let bookmark_root = dir.join("bookmark-root");
    let preset_root = dir.join("preset-root");
    fs::create_dir_all(&bookmark_root).expect("bookmark root should be created");
    fs::create_dir_all(&preset_root).expect("preset root should be created");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API", WorkspaceTemplateKind::Bookmark);
    bookmark.project_root = Some(bookmark_root.to_string_lossy().to_string());
    let mut preset = WorkspaceTemplate::new("Two pane", WorkspaceTemplateKind::Preset);
    preset.columns = vec![WorkspaceTemplateColumn {
        id: "preset-column".to_string(),
        width: 640.0,
        focused_pane_id: Some("preset-pane".to_string()),
        last_focused_pane_id: Some("preset-pane".to_string()),
        pane_heights: vec![1.0],
        panes: vec![WorkspaceTemplatePane {
            id: "preset-pane".to_string(),
            title_seed: Some("shell".to_string()),
            working_directory: Some(preset_root.to_string_lossy().to_string()),
            command: None,
            environment: BTreeMap::new(),
            was_user_edited: false,
        }],
    }];
    store.upsert(bookmark).expect("bookmark should persist");
    store.upsert(preset).expect("preset should persist");
    store
        .upsert(WorkspaceTemplate::new(
            "No path",
            WorkspaceTemplateKind::Bookmark,
        ))
        .expect("pathless bookmark should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('o'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::OpenPathWithTarget {
            path: bookmark_root.to_string_lossy().to_string(),
            target_id: "default".to_string(),
            target_name: "Default App".to_string(),
            app_path: None,
        }
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('o'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Status {
            message: "Bookmark has no path to reveal: No path".to_string(),
        }
    );

    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::DownArrow,
            DesktopKeyModifiers::default()
        )),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('o'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::OpenPathWithTarget {
            path: preset_root.to_string_lossy().to_string(),
            target_id: "default".to_string(),
            target_name: "Default App".to_string(),
            app_path: None,
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_exports_and_imports_bookmark_template_files() {
    let dir = test_directory("desktop-bookmarks-import-export");
    let project = dir.join("project");
    fs::create_dir_all(&project).expect("project dir should be created");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut bookmark = WorkspaceTemplate::new("API: Server", WorkspaceTemplateKind::Bookmark);
    bookmark.project_root = Some(project.to_string_lossy().to_string());
    bookmark.columns = vec![WorkspaceTemplateColumn {
        id: "column-main".to_string(),
        width: 640.0,
        focused_pane_id: Some("pane-main".to_string()),
        last_focused_pane_id: Some("pane-main".to_string()),
        pane_heights: vec![1.0],
        panes: vec![WorkspaceTemplatePane {
            id: "pane-main".to_string(),
            title_seed: Some("server".to_string()),
            working_directory: Some(project.to_string_lossy().to_string()),
            command: Some("cargo test".to_string()),
            environment: BTreeMap::from([
                ("CUSTOM".to_string(), "kept".to_string()),
                ("ZENTTY_PANE_ID".to_string(), "unsafe".to_string()),
            ]),
            was_user_edited: false,
        }],
    }];
    let bookmark_id = bookmark.id.clone();
    store.upsert(bookmark).expect("bookmark should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );
    let default_export_path = dir.join(format!(
        "API_ Server.{}",
        WorkspaceTemplateExporter::FILE_EXTENSION
    ));
    assert_eq!(
        session.execute_key_event(DesktopKeyEvent::new(
            DesktopKey::Character('e'),
            DesktopKeyModifiers::control()
        )),
        DesktopCommandEffect::Status {
            message: format!("Exported preset: {}", default_export_path.display()),
        }
    );
    assert!(default_export_path.exists());

    let explicit_export_path = dir.join(format!(
        "explicit.{}",
        WorkspaceTemplateExporter::FILE_EXTENSION
    ));
    assert!(
        session
            .export_bookmark_template_to_path(&bookmark_id, &explicit_export_path)
            .expect("explicit export should write")
    );
    assert!(explicit_export_path.exists());
    assert!(
        !session
            .export_bookmark_template_to_path("missing-template", dir.join("missing.zenttypreset"))
            .expect("missing template export should not fail")
    );

    let imported = session
        .import_bookmark_template_from_path(&explicit_export_path)
        .expect("import should upsert fresh preset");
    assert_ne!(imported.id, bookmark_id);
    assert_eq!(imported.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(imported.project_root, None);
    assert_eq!(imported.columns[0].panes[0].working_directory, None);
    assert_eq!(
        imported.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM".to_string(), "kept".to_string())])
    );
    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert_eq!(reloaded.templates().len(), 2);
    assert!(reloaded.template(&imported.id).is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_bookmark_popover_enter_restores_selected_template_as_worklane() {
    let dir = test_directory("desktop-bookmarks-popover-restore");
    let mut store =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should load");
    let mut template = WorkspaceTemplate::new("Restore API", WorkspaceTemplateKind::Bookmark);
    template.title = Some("Restored Project".to_string());
    template.color = Some("teal".to_string());
    template.project_root = Some(dir.to_string_lossy().to_string());
    template.focused_column_id = Some("col-worker".to_string());
    template.columns = vec![
        WorkspaceTemplateColumn {
            id: "col-server".to_string(),
            width: 520.0,
            focused_pane_id: Some("pane-server".to_string()),
            last_focused_pane_id: Some("pane-server".to_string()),
            pane_heights: vec![0.60],
            panes: vec![WorkspaceTemplatePane {
                id: "pane-server".to_string(),
                title_seed: Some("server".to_string()),
                working_directory: Some(dir.to_string_lossy().to_string()),
                command: Some("cmd.exe /C echo ZENTTY_BOOKMARK_%CUSTOM%".to_string()),
                environment: BTreeMap::from([
                    ("CUSTOM".to_string(), "RESTORED".to_string()),
                    ("ZENTTY_PANE_ID".to_string(), "unsafe".to_string()),
                ]),
                was_user_edited: false,
            }],
        },
        WorkspaceTemplateColumn {
            id: "col-worker".to_string(),
            width: 480.0,
            focused_pane_id: Some("pane-worker".to_string()),
            last_focused_pane_id: Some("pane-worker".to_string()),
            pane_heights: vec![1.0],
            panes: vec![WorkspaceTemplatePane {
                id: "pane-worker".to_string(),
                title_seed: Some("worker".to_string()),
                working_directory: Some(dir.join("missing").to_string_lossy().to_string()),
                command: Some("definitely-missing-zentty-command --flag".to_string()),
                environment: BTreeMap::from([("WORKER".to_string(), "1".to_string())]),
                was_user_edited: true,
            }],
        },
    ];
    store.upsert(template).expect("bookmark should persist");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.execute_app_command(AppCommandId::OpenBookmarksPopover),
        DesktopCommandEffect::Repaint
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should activate bookmark"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.bookmarks_snapshot(), None);
    assert_eq!(
        session.pane_ids(),
        vec!["pane-left", "pane-right", "pane-3", "pane-4"]
    );
    assert_eq!(session.focused_pane_id(), Some("pane-4"));
    assert_eq!(session.active_worklane_title(), Some("Restored Project"));
    assert_eq!(session.active_worklane_color(), Some("teal"));
    let snapshots = session.pane_snapshots();
    assert_eq!(snapshots.len(), 2);
    assert_eq!(snapshots[0].title, "server");
    assert_eq!(snapshots[0].column_width, 520.0);
    assert_eq!(snapshots[0].pane_height, Some(0.60));
    assert_eq!(snapshots[1].title, "worker");
    assert_eq!(snapshots[1].column_width, 480.0);
    assert_eq!(snapshots[1].pane_height, Some(1.0));

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-3")
            .is_some_and(|text| text.contains("ZENTTY_BOOKMARK_RESTORED"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-3")
            .unwrap_or_default()
            .contains("ZENTTY_BOOKMARK_RESTORED"),
        "server pane text: {}",
        session.plain_text_for_pane("pane-3").unwrap_or_default()
    );

    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert!(reloaded.templates()[0].last_used_at.is_some());

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_save_active_worklane_bookmark_captures_live_layout() {
    let dir = test_directory("desktop-bookmarks-save-active");
    let project = dir.join("project");
    let api = project.join("api");
    let worker = project.join("worker");
    fs::create_dir_all(&api).expect("api dir should be created");
    fs::create_dir_all(&worker).expect("worker dir should be created");

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "12",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].title = Some("Project API".to_string());
    app.windows[0]
        .worklane_colors_by_id
        .insert("main".to_string(), "blue".to_string());
    app.windows[0].worklanes[0].panes[0].column_width = 520.0;
    app.windows[0].worklanes[0].panes[0].pane_height = Some(0.75);
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(api.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("cmd.exe /C echo LEFT".to_string());
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .environment_variables = vec![
        ("CUSTOM_LEFT".to_string(), "kept".to_string()),
        ("ZENTTY_PANE_ID".to_string(), "unsafe".to_string()),
    ];
    app.windows[0].worklanes[0].panes[1].column_width = 480.0;
    app.windows[0].worklanes[0].panes[1].pane_height = Some(1.0);
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .working_directory = Some(worker.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .command = Some("npm run dev".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(
        session.suggested_active_worklane_template_name(WorkspaceTemplateKind::Bookmark),
        Some("Project API".to_string())
    );
    assert_eq!(
        session.suggested_active_worklane_template_name(WorkspaceTemplateKind::Preset),
        Some("2 panes: npm".to_string())
    );

    let template = session
        .save_active_worklane_template(WorkspaceTemplateKind::Bookmark, " Saved API ")
        .expect("bookmark should save")
        .expect("active worklane should capture");
    assert_eq!(template.name, "Saved API");
    assert_eq!(template.kind, WorkspaceTemplateKind::Bookmark);
    assert_eq!(template.title, Some("Project API".to_string()));
    assert_eq!(template.color, Some("blue".to_string()));
    assert_eq!(
        template.project_root,
        Some(project.to_string_lossy().to_string())
    );
    assert_eq!(template.next_pane_number, 3);
    assert_eq!(template.focused_column_id, Some("column-right".to_string()));
    assert_eq!(template.columns.len(), 2);
    assert_eq!(template.columns[0].width, 520.0);
    assert_eq!(template.columns[0].pane_heights, vec![0.75]);
    assert_eq!(
        template.columns[0].panes[0].working_directory,
        Some(api.to_string_lossy().to_string())
    );
    assert_eq!(
        template.columns[0].panes[0].command,
        Some("cmd.exe /C echo LEFT".to_string())
    );
    assert_eq!(
        template.columns[0].panes[0].environment,
        BTreeMap::from([("CUSTOM_LEFT".to_string(), "kept".to_string())])
    );
    assert_eq!(template.columns[1].width, 480.0);
    assert_eq!(
        template.columns[1].panes[0].working_directory,
        Some(worker.to_string_lossy().to_string())
    );
    assert_eq!(
        template.columns[1].panes[0].command,
        Some("npm run dev".to_string())
    );

    let preset = session
        .capture_active_worklane_template(WorkspaceTemplateKind::Preset, "Layout")
        .expect("active worklane should capture as preset");
    assert_eq!(preset.kind, WorkspaceTemplateKind::Preset);
    assert_eq!(preset.project_root, None);
    assert_eq!(preset.columns[0].panes[0].working_directory, None);
    assert_eq!(preset.columns[1].panes[0].working_directory, None);

    let reloaded =
        BookmarkStore::load(dir.join("bookmarks.json")).expect("bookmark store should reload");
    assert_eq!(reloaded.templates().len(), 1);
    assert_eq!(reloaded.templates()[0].name, "Saved API");

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_show_task_manager_renders_task_manager_snapshot() {
    let dir = test_directory("desktop-task-manager-command");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.task_manager_text_snapshot(), None);

    assert_eq!(
        session.execute_app_command(AppCommandId::ShowTaskManager),
        DesktopCommandEffect::Repaint
    );
    let snapshot = session
        .task_manager_text_snapshot()
        .expect("task manager snapshot should be stored");
    let rendered_snapshot = snapshot.lines.join("\n");
    assert!(rendered_snapshot.contains("Task Manager"));
    assert!(rendered_snapshot.contains("Pane | CPU | Memory"));
    assert!(rendered_snapshot.contains("left"));
    assert!(rendered_snapshot.contains("right"));
    assert!(rendered_snapshot.contains("Waiting for shell PID"));

    let rendered_session = session.render_lines(None).join("\n");
    assert!(rendered_session.contains("Task Manager"));
    assert!(rendered_session.contains("Waiting for shell PID"));
    assert!(!rendered_session.contains("Task manager requested"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_server_ipc_requests() {
    let dir = test_directory("desktop-server-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-server-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-server-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    let set_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-set",
            "server-set",
            "right-token",
            true,
            ["http://127.0.0.1:5173/docs?q=1#top", "--json"],
        ))
        .expect("server set should respond");
    assert!(set_response.ok);
    let state = set_response
        .result
        .and_then(|result| result.server_state)
        .expect("server set should return server state");
    assert_eq!(state.version, 2);
    assert_eq!(
        state.primary_server_id.as_deref(),
        Some("main|http://localhost:5173")
    );
    assert_eq!(state.servers.len(), 1);
    let server = &state.servers[0];
    assert_eq!(server.id, "main|http://localhost:5173");
    assert_eq!(server.origin, "http://localhost:5173");
    assert_eq!(server.url, "http://localhost:5173/docs?q=1#top");
    assert_eq!(server.display, "localhost:5173");
    assert_eq!(server.worklane_id, "main");
    assert_eq!(server.pane_id.as_deref(), Some("pane-right"));
    assert_eq!(server.source, "manual");
    assert_eq!(server.ports, vec![5173]);
    assert_eq!(server.confidence, "explicit");
    assert_eq!(server.tier.as_deref(), Some("primary"));
    let reasons = server
        .reasons
        .as_ref()
        .expect("server list entry should include relevance reasons");
    assert!(reasons.contains(&"source:manual".to_string()));
    assert!(reasons.contains(&"manual".to_string()));
    assert!(reasons.contains(&"confidence:explicit".to_string()));
    assert!(!server.updated_at.is_empty());
    let detected = session.detected_servers();
    assert_eq!(detected.len(), 1);
    assert_eq!(
        detected[0].id,
        "main|pane-right|manual|http://localhost:5173"
    );
    assert_eq!(detected[0].origin, "http://localhost:5173");
    assert_eq!(detected[0].url, "http://localhost:5173/docs?q=1#top");
    assert_eq!(detected[0].display, "localhost:5173");
    assert_eq!(detected[0].worklane_id, "main");
    assert_eq!(detected[0].pane_id.as_deref(), Some("pane-right"));
    assert_eq!(detected[0].source, DetectedServerSource::Manual);
    assert_eq!(detected[0].ports, vec![5173]);
    assert_eq!(detected[0].confidence, DetectedServerConfidence::Explicit);

    let watch_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-watch-set",
            "server-watch-set",
            "right-token",
            true,
            ["http://localhost:5173/watch", "--json"],
        ))
        .expect("server watch set should respond");
    let watch_state = watch_response
        .result
        .and_then(|result| result.server_state)
        .expect("server watch set should return server state");
    assert_eq!(watch_state.servers.len(), 1);
    assert_eq!(watch_state.servers[0].source, "manual");
    assert_eq!(
        watch_state.servers[0].url,
        "http://localhost:5173/docs?q=1#top"
    );
    assert_eq!(session.detected_servers().len(), 2);

    let watch_clear_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-watch-clear",
            "server-watch-clear",
            "right-token",
            true,
            ["--json"],
        ))
        .expect("server watch clear should respond");
    let watch_cleared = watch_clear_response
        .result
        .and_then(|result| result.server_state)
        .expect("server watch clear should return server state");
    assert_eq!(watch_cleared.servers.len(), 1);
    assert_eq!(watch_cleared.servers[0].source, "manual");
    assert_eq!(session.detected_servers().len(), 1);

    let list_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-list",
            "server-list",
            "right-token",
            true,
            ["--json"],
        ))
        .expect("server list should respond");
    let listed = list_response
        .result
        .and_then(|result| result.server_state)
        .expect("server list should return server state");
    assert_eq!(
        listed.primary_server_id.as_deref(),
        Some("main|http://localhost:5173")
    );
    assert_eq!(listed.servers[0].origin, "http://localhost:5173");

    let (open_response, open_effect) =
        session.handle_agent_ipc_request_with_effect(desktop_server_request(
            "desktop-server-open",
            "server-open",
            "right-token",
            true,
            ["localhost:5173", "--json"],
        ));
    assert_eq!(
        open_effect,
        Some(DesktopCommandEffect::OpenUrl {
            url: "http://localhost:5173/docs?q=1#top".to_string(),
        })
    );
    let opened = open_response
        .and_then(|response| response.result)
        .and_then(|result| result.server_state)
        .expect("server open should return server state");
    assert_eq!(
        opened.primary_server_id.as_deref(),
        Some("main|http://localhost:5173")
    );

    let (_primary_open_response, primary_open_effect) = session
        .handle_agent_ipc_request_with_effect(desktop_server_request(
            "desktop-server-open-primary",
            "server-open",
            "right-token",
            true,
            ["--json"],
        ));
    assert_eq!(
        primary_open_effect,
        Some(DesktopCommandEffect::OpenUrl {
            url: "http://localhost:5173/docs?q=1#top".to_string(),
        })
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_server_request(
            "desktop-server-invalid-token",
            "server-list",
            "bad-token",
            true,
            ["--json"],
        )),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-server-invalid-token".to_string(),
            ok: false,
            result: None,
            error: Some(AgentIpcResponseError {
                code: "invalid_pane_token".to_string(),
                message: "Invalid pane token.".to_string(),
            }),
        })
    );

    let clear_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-clear",
            "server-clear",
            "right-token",
            true,
            ["--json"],
        ))
        .expect("server clear should respond");
    let cleared = clear_response
        .result
        .and_then(|result| result.server_state)
        .expect("server clear should return server state");
    assert_eq!(
        cleared,
        ServerListResult {
            version: 2,
            primary_server_id: None,
            servers: Vec::<ServerListEntry>::new(),
        }
    );
    assert_eq!(session.detected_servers(), &[]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_opens_servers_with_configured_and_explicit_browser() {
    let dir = test_directory("desktop-server-browser-open");
    let preferred_browser = dir.join("Browsers").join("Preferred.exe");
    let explicit_browser = dir.join("Browsers").join("Explicit.exe");
    fs::create_dir_all(
        preferred_browser
            .parent()
            .expect("preferred browser should have parent"),
    )
    .expect("browser parent should be created");
    fs::write(&preferred_browser, "fake preferred browser")
        .expect("preferred browser should be written");
    fs::write(&explicit_browser, "fake explicit browser")
        .expect("explicit browser should be written");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut config = AppConfig::default();
    config.server_detection.preferred_browser_id = "custom:preferred".to_string();
    config.server_detection.enabled_browser_target_ids = vec![
        "custom:preferred".to_string(),
        "custom:explicit".to_string(),
    ];
    config.server_detection.custom_browsers = vec![
        ServerBrowserCustomApp {
            id: "custom:preferred".to_string(),
            name: "Preferred Browser".to_string(),
            path: preferred_browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        },
        ServerBrowserCustomApp {
            id: "custom:explicit".to_string(),
            name: "Explicit Browser".to_string(),
            path: explicit_browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        },
    ];
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-server-browser-open-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-server-browser-open-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-browser-set",
            "server-set",
            "right-token",
            true,
            ["http://localhost:4173/preview", "--json"],
        ))
        .expect("server set should respond");

    let (_preferred_response, preferred_effect) =
        session.handle_agent_ipc_request_with_effect(desktop_server_request(
            "desktop-server-browser-open-preferred",
            "server-open",
            "right-token",
            true,
            ["localhost:4173", "--json"],
        ));
    assert_eq!(
        preferred_effect,
        Some(DesktopCommandEffect::OpenUrlWithBrowser {
            url: "http://localhost:4173/preview".to_string(),
            browser_id: "custom:preferred".to_string(),
            browser_name: "Preferred Browser".to_string(),
            app_path: preferred_browser.to_string_lossy().to_string(),
        })
    );

    let (_explicit_response, explicit_effect) =
        session.handle_agent_ipc_request_with_effect(desktop_server_request(
            "desktop-server-browser-open-explicit",
            "server-open",
            "right-token",
            true,
            ["localhost:4173", "--browser", "custom:explicit", "--json"],
        ));
    assert_eq!(
        explicit_effect,
        Some(DesktopCommandEffect::OpenUrlWithBrowser {
            url: "http://localhost:4173/preview".to_string(),
            browser_id: "custom:explicit".to_string(),
            browser_name: "Explicit Browser".to_string(),
            app_path: explicit_browser.to_string_lossy().to_string(),
        })
    );

    assert_eq!(
        session.execute_app_command(AppCommandId::OpenSelectedServer),
        DesktopCommandEffect::OpenUrlWithBrowser {
            url: "http://localhost:4173/preview".to_string(),
            browser_id: "custom:preferred".to_string(),
            browser_name: "Preferred Browser".to_string(),
            app_path: preferred_browser.to_string_lossy().to_string(),
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_applies_ignored_server_ports_from_config() {
    let dir = test_directory("desktop-server-ignored-ports");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let mut config = AppConfig::default();
    config.server_detection.ignored_port_rules = vec!["5173".to_string()];
    let launch = DesktopLaunchPlan {
        shell,
        config,
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-server-ignored-ports-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-server-ignored-ports-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    let watch_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-ignored-watch",
            "server-watch-set",
            "right-token",
            true,
            ["http://localhost:5173/", "--json"],
        ))
        .expect("server watch set should respond");
    let watch_state = watch_response
        .result
        .and_then(|result| result.server_state)
        .expect("server watch set should return state");
    assert_eq!(watch_state.primary_server_id, None);
    assert_eq!(watch_state.servers.len(), 1);
    assert_eq!(watch_state.servers[0].tier.as_deref(), Some("hidden"));
    assert_eq!(watch_state.servers[0].source, "watch");
    assert!(
        watch_state.servers[0]
            .reasons
            .as_ref()
            .is_some_and(|reasons| reasons.contains(&"ignored-port:5173".to_string()))
    );

    let (_open_response, open_effect) =
        session.handle_agent_ipc_request_with_effect(desktop_server_request(
            "desktop-server-ignored-open-primary",
            "server-open",
            "right-token",
            true,
            ["--json"],
        ));
    assert_eq!(open_effect, None);

    let manual_response = session
        .handle_agent_ipc_request(desktop_server_request(
            "desktop-server-ignored-manual",
            "server-set",
            "right-token",
            true,
            ["http://localhost:5173/manual", "--json"],
        ))
        .expect("manual server set should respond");
    let manual_state = manual_response
        .result
        .and_then(|result| result.server_state)
        .expect("manual server set should return state");
    assert_eq!(
        manual_state.primary_server_id.as_deref(),
        Some("main|http://localhost:5173")
    );
    assert_eq!(manual_state.servers[0].tier.as_deref(), Some("primary"));
    assert_eq!(manual_state.servers[0].source, "manual");

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_pane_list_ipc_request() {
    let dir = test_directory("desktop-pane-list-ipc");
    let left_dir = dir.join("left");
    let right_dir = dir.join("right");
    fs::create_dir_all(&left_dir).expect("left dir should be created");
    fs::create_dir_all(&right_dir).expect("right dir should be created");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(left_dir.to_string_lossy().to_string());
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .working_directory = Some(right_dir.to_string_lossy().to_string());
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-list-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-list-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_list_request(
            "desktop-pane-list",
            "right-token",
            true,
            []
        )),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-pane-list".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult {
                pane_list: Some(vec![
                    PaneListEntry {
                        index: 1,
                        id: "pane-left".to_string(),
                        column: 1,
                        title: "left".to_string(),
                        working_directory: Some(left_dir.to_string_lossy().to_string()),
                        is_focused: false,
                        agent_tool: None,
                        agent_status: None,
                    },
                    PaneListEntry {
                        index: 2,
                        id: "pane-right".to_string(),
                        column: 2,
                        title: "right".to_string(),
                        working_directory: Some(right_dir.to_string_lossy().to_string()),
                        is_focused: true,
                        agent_tool: None,
                        agent_status: None,
                    },
                ]),
                ..AgentIpcResponseResult::default()
            }),
            error: None,
        })
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_list_request(
            "desktop-pane-list-explicit-left",
            "right-token",
            true,
            ["--pane-id", "pane-left", "--pane-token", "left-token",]
        )),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-pane-list-explicit-left".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult {
                pane_list: Some(vec![
                    PaneListEntry {
                        index: 1,
                        id: "pane-left".to_string(),
                        column: 1,
                        title: "left".to_string(),
                        working_directory: Some(left_dir.to_string_lossy().to_string()),
                        is_focused: false,
                        agent_tool: None,
                        agent_status: None,
                    },
                    PaneListEntry {
                        index: 2,
                        id: "pane-right".to_string(),
                        column: 2,
                        title: "right".to_string(),
                        working_directory: Some(right_dir.to_string_lossy().to_string()),
                        is_focused: true,
                        agent_tool: None,
                        agent_status: None,
                    },
                ]),
                ..AgentIpcResponseResult::default()
            }),
            error: None,
        })
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_list_request(
            "desktop-pane-list-invalid-token",
            "right-token",
            true,
            ["--pane-id", "pane-left"]
        )),
        Some(AgentIpcResponse {
            version: 1,
            id: "desktop-pane-list-invalid-token".to_string(),
            ok: false,
            result: None,
            error: Some(AgentIpcResponseError {
                code: "invalid_pane_token".to_string(),
                message: "Invalid pane token.".to_string(),
            }),
        })
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_mutating_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-mutating-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    let worklane = &mut app.windows[0].worklanes[0];
    worklane.panes[0].column_width = 300.0;
    worklane.panes[1].column_width = 500.0;
    let mut third = worklane.panes[1].clone();
    third.pane_id = "pane-third".to_string();
    third.title = "third".to_string();
    third.column_id = "column-third".to_string();
    third.column_index = 2;
    third.column_width = 700.0;
    worklane.panes.push(third);
    for pane in &mut worklane.panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-mutating-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-mutating-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token")
    .with_pane_token(Some("window-main"), "main", "pane-third", "third-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-focus-left",
            "focus",
            "right-token",
            true,
            ["left"]
        )),
        desktop_ipc_success_response("desktop-pane-focus-left")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-focus-index",
            "focus",
            "right-token",
            true,
            ["3"]
        )),
        desktop_ipc_success_response("desktop-pane-focus-index")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-third"));

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-layout-thirds",
            "layout",
            "right-token",
            true,
            ["thirds"]
        )),
        desktop_ipc_success_response("desktop-pane-layout-thirds")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_desktop_widths(&session, &[500.0, 500.0, 500.0]);

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-resize-right",
            "resize",
            "right-token",
            true,
            ["right"]
        )),
        desktop_ipc_success_response("desktop-pane-resize-right")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_desktop_widths(&session, &[500.0, 524.0, 500.0]);

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-close-third",
            "close",
            "right-token",
            true,
            ["3"]
        )),
        desktop_ipc_success_response("desktop-pane-close-third")
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_desktop_widths(&session, &[500.0, 524.0]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_grid_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-grid-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-grid-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-grid-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    let response = session
        .handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-grid-too-many",
            "grid",
            "right-token",
            true,
            ["--rows", "7", "--columns", "6"],
        ))
        .expect("too-large grid request should produce response");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("grid_too_many_cells")
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-grid-current",
            "grid",
            "right-token",
            true,
            [
                "--rows",
                "2",
                "--columns",
                "2",
                "--command-json",
                r#"["findstr","."]"#,
                "--focus",
                "last",
            ]
        )),
        desktop_ipc_success_response("desktop-pane-grid-current")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-5"));
    assert_eq!(
        desktop_snapshot_layout(&session),
        vec![
            (
                "pane-right".to_string(),
                "column-pane-right".to_string(),
                0,
                0
            ),
            ("pane-3".to_string(), "column-pane-right".to_string(), 0, 1),
            ("pane-4".to_string(), "column-pane-4".to_string(), 1, 0),
            ("pane-5".to_string(), "column-pane-4".to_string(), 1, 1),
        ]
    );
    assert_desktop_widths(&session, &[640.0, 640.0, 640.0, 640.0]);
    assert_desktop_heights(&session, &[Some(1.0), Some(1.0), Some(1.0), Some(1.0)]);

    let response = session
        .handle_agent_ipc_request(desktop_pane_list_request(
            "desktop-pane-grid-rerouted-list",
            "right-token",
            true,
            [],
        ))
        .expect("retargeted grid source env should still route");
    assert!(response.ok);
    assert_eq!(
        response
            .result
            .as_ref()
            .and_then(|result| result.pane_list.as_ref())
            .map(Vec::len),
        Some(4)
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_grid_new_window_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-grid-new-window-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-grid-new-window-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-grid-new-window-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    let (response, new_session) =
        session.handle_agent_ipc_request_with_new_window_session(desktop_pane_request(
            "desktop-pane-grid-new-window",
            "grid",
            "right-token",
            true,
            [
                "--rows",
                "2",
                "--columns",
                "2",
                "--command-json",
                r#"["findstr","."]"#,
                "--include-source",
                "--new-window",
                "--focus",
                "last",
            ],
        ));
    assert_eq!(
        response,
        desktop_ipc_success_response("desktop-pane-grid-new-window")
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);

    let mut new_session = new_session.expect("grid new-window should return a session");
    assert_eq!(new_session.focused_pane_id(), Some("pane-6"));
    assert!(new_session.agent_ipc_socket_path().is_some());
    assert_ne!(
        new_session.agent_ipc_socket_path(),
        session.agent_ipc_socket_path()
    );
    assert_eq!(
        desktop_snapshot_layout(&new_session),
        vec![
            ("pane-3".to_string(), "column-pane-3".to_string(), 0, 0),
            ("pane-4".to_string(), "column-pane-3".to_string(), 0, 1),
            ("pane-5".to_string(), "column-pane-5".to_string(), 1, 0),
            ("pane-6".to_string(), "column-pane-5".to_string(), 1, 1),
        ]
    );
    assert_desktop_widths(&new_session, &[640.0, 640.0, 640.0, 640.0]);
    assert_desktop_heights(&new_session, &[Some(1.0), Some(1.0), Some(1.0), Some(1.0)]);

    new_session.terminate().ok();
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_notify_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-notify-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-notify-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-notify-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert!(session.pane_notifications().is_empty());
    let (notify_response, notify_effect) =
        session.handle_agent_ipc_request_with_effect(desktop_pane_request(
            "desktop-pane-notify-inbox",
            "notify",
            "right-token",
            true,
            [
                "--title",
                " Build Ready ",
                "--subtitle",
                " Agent ",
                "--body",
                " Done ",
                "--silent",
            ],
        ));
    assert_eq!(
        notify_response,
        desktop_ipc_success_response("desktop-pane-notify-inbox")
    );
    assert_eq!(
        notify_effect,
        Some(DesktopCommandEffect::PaneNotification {
            notification: PaneNotification {
                title: "Build Ready".to_string(),
                subtitle: Some("Agent".to_string()),
                body: Some("Done".to_string()),
                include_inbox: true,
                is_silent: true,
                window_id: "window-main".to_string(),
                worklane_id: "main".to_string(),
                pane_id: "pane-right".to_string(),
            },
        })
    );
    let notification = &session.pane_notifications()[0];
    assert_eq!(notification.title, "Build Ready");
    assert_eq!(notification.subtitle.as_deref(), Some("Agent"));
    assert_eq!(notification.body.as_deref(), Some("Done"));
    assert_eq!(notification.primary_text(), "Done");
    assert!(notification.include_inbox);
    assert!(notification.is_silent);
    assert_eq!(notification.window_id, "window-main");
    assert_eq!(notification.worklane_id, "main");
    assert_eq!(notification.pane_id, "pane-right");
    assert_eq!(session.inbox_pane_notifications().len(), 1);

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-notify-no-inbox",
            "notify",
            "right-token",
            true,
            ["--title", "No Inbox", "--no-inbox"]
        )),
        desktop_ipc_success_response("desktop-pane-notify-no-inbox")
    );
    assert_eq!(session.pane_notifications().len(), 2);
    assert_eq!(session.pane_notifications()[0].title, "No Inbox");
    assert!(!session.pane_notifications()[0].include_inbox);
    assert_eq!(session.inbox_pane_notifications().len(), 1);

    assert_eq!(
        session.execute_command(AppCommandId::FocusLeftPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        session.execute_command(AppCommandId::JumpToLatestNotification),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    let response = session
        .handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-notify-unexpected",
            "notify",
            "right-token",
            true,
            ["--title", "Build Ready", "--bogus"],
        ))
        .expect("unexpected notify argument should produce response");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("unexpected_argument")
    );
    assert_eq!(session.pane_notifications().len(), 2);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_worklane_color_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-worklane-color-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-worklane-color-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-worklane-color-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(session.active_worklane_color(), None);
    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-color-blue",
            "worklane-color",
            "right-token",
            true,
            ["--color", "blue"]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-color-blue")
    );
    assert_eq!(
        session.active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-color-invalid",
            "worklane-color",
            "right-token",
            true,
            ["--color", "ultraviolet"]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-color-invalid")
    );
    assert_eq!(
        session.active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-color-reset",
            "worklane-color",
            "right-token",
            true,
            ["--color", "reset"]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-color-reset")
    );
    assert_eq!(session.active_worklane_color(), None);

    let response = session
        .handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-color-missing-worklane",
            "worklane-color",
            "right-token",
            true,
            ["--id", "missing", "--color", "blue"],
        ))
        .expect("missing worklane should produce response");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("worklane_not_found")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_worklane_rename_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-worklane-rename-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-worklane-rename-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-worklane-rename-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(session.active_worklane_title(), Some("Main"));
    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-rename-title",
            "worklane-rename",
            "right-token",
            true,
            ["--title", " Agent Lane "]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-rename-title")
    );
    assert_eq!(session.active_worklane_title(), Some("Agent Lane"));

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-rename-flag-title",
            "worklane-rename",
            "right-token",
            true,
            ["--title", "--clear"]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-rename-flag-title")
    );
    assert_eq!(session.active_worklane_title(), Some("--clear"));

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-rename-clear",
            "worklane-rename",
            "right-token",
            true,
            ["--clear"]
        )),
        desktop_ipc_success_response("desktop-pane-worklane-rename-clear")
    );
    assert_eq!(session.active_worklane_title(), None);

    let response = session
        .handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-worklane-rename-missing-worklane",
            "worklane-rename",
            "right-token",
            true,
            ["--id", "missing", "--title", "Agent Lane"],
        ))
        .expect("missing worklane should produce response");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("worklane_not_found")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_app_theme_commands_update_theme_mode() {
    let dir = test_directory("desktop-app-theme-commands");
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysDark);
    assert_eq!(
        session.execute_app_command(AppCommandId::UseLightTheme),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysLight);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("theme command should persist config"),
    )
    .expect("persisted theme command config should decode");
    assert_eq!(
        persisted.appearance.theme_mode,
        AppearanceThemeMode::AlwaysLight
    );

    assert_eq!(
        session.execute_app_command(AppCommandId::UseAutoTheme),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::FollowMacOS);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("auto theme command should persist config"),
    )
    .expect("persisted auto theme command config should decode");
    assert_eq!(
        persisted.appearance.theme_mode,
        AppearanceThemeMode::FollowMacOS
    );

    assert_eq!(
        session.execute_app_command(AppCommandId::ToggleLightDarkTheme),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysLight);

    assert_eq!(
        session.execute_app_command(AppCommandId::UseDarkTheme),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysDark);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("dark theme command should persist config"),
    )
    .expect("persisted dark theme command config should decode");
    assert_eq!(
        persisted.appearance.theme_mode,
        AppearanceThemeMode::AlwaysDark
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_theme_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-theme-ipc");
    let config_path = dir.join("missing.toml");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            config_path.to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-theme-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-theme-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysDark);
    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-theme-toggle",
            "theme",
            "right-token",
            true,
            ["toggle"]
        )),
        desktop_ipc_stdout_response("desktop-pane-theme-toggle", "light\n")
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::AlwaysLight);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("pane theme command should persist config"),
    )
    .expect("persisted pane theme command config should decode");
    assert_eq!(
        persisted.appearance.theme_mode,
        AppearanceThemeMode::AlwaysLight
    );

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-theme-auto",
            "theme",
            "right-token",
            true,
            ["auto"]
        )),
        desktop_ipc_stdout_response("desktop-pane-theme-auto", "auto\n")
    );
    assert_eq!(session.theme_mode(), AppearanceThemeMode::FollowMacOS);
    let persisted = AppConfigToml::decode(
        &fs::read_to_string(&config_path).expect("pane auto theme command should persist config"),
    )
    .expect("persisted pane auto theme command config should decode");
    assert_eq!(
        persisted.appearance.theme_mode,
        AppearanceThemeMode::FollowMacOS
    );

    let response = session
        .handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-theme-unsupported",
            "theme",
            "right-token",
            true,
            ["sepia"],
        ))
        .expect("unsupported theme should produce response");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("unsupported_command")
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_handles_authenticated_split_pane_ipc_requests() {
    let dir = test_directory("desktop-pane-split-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    let worklane = &mut app.windows[0].worklanes[0];
    worklane.panes[0].column_width = 300.0;
    worklane.panes[1].column_width = 500.0;
    for pane in &mut worklane.panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-desktop-pane-split-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "desktop-pane-split-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-left", "left-token")
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");
    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-resize-percent",
            "resize",
            "right-token",
            true,
            ["75%"]
        )),
        desktop_ipc_success_response("desktop-pane-resize-percent")
    );
    assert_desktop_widths(&session, &[200.0, 600.0]);

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-split-left-ratio",
            "split",
            "right-token",
            true,
            ["left", "--ratio", "50"]
        )),
        desktop_ipc_success_response("desktop-pane-split-left-ratio")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-3"));
    assert_eq!(
        desktop_snapshot_layout(&session),
        vec![
            ("pane-left".to_string(), "column-left".to_string(), 0, 0),
            ("pane-3".to_string(), "column-pane-3".to_string(), 1, 0),
            ("pane-right".to_string(), "column-right".to_string(), 2, 0),
        ]
    );
    assert_desktop_widths(&session, &[200.0, 700.0, 500.0]);

    assert_eq!(
        session.handle_agent_ipc_request(desktop_pane_request(
            "desktop-pane-split-up-equal",
            "split",
            "right-token",
            true,
            ["up", "--equal"]
        )),
        desktop_ipc_success_response("desktop-pane-split-up-equal")
    );
    assert_eq!(session.focused_pane_id(), Some("pane-4"));
    assert_eq!(
        desktop_snapshot_layout(&session),
        vec![
            ("pane-left".to_string(), "column-left".to_string(), 0, 0),
            ("pane-3".to_string(), "column-pane-3".to_string(), 1, 0),
            ("pane-4".to_string(), "column-right".to_string(), 2, 0),
            ("pane-right".to_string(), "column-right".to_string(), 2, 1),
        ]
    );
    assert_desktop_widths(&session, &[200.0, 700.0, 500.0, 500.0]);
    assert_desktop_heights(&session, &[Some(1.0), Some(1.0), Some(1.0), Some(1.0)]);

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_detached_live_pane_accepts_original_agent_ipc_environment() {
    let dir = test_directory("desktop-detached-pane-agent-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|detached-agent-ipc",
        "detached agent ipc",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DETACHED_AGENT_IPC_TASK",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-detached-pane-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "detached-pane-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-right", "detached-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");
    let mut moved = session
        .detach_focused_pane_to_new_window_session()
        .expect("focused pane should detach into a new desktop window session");

    assert_eq!(session.pane_ids(), vec!["pane-left"]);
    assert_eq!(moved.pane_ids(), vec!["pane-right"]);
    {
        let mut sessions: [&mut DesktopWindowSession; 2] = [&mut session, &mut moved];
        assert_eq!(
            DesktopWindowSession::handle_agent_ipc_request_for_sessions(
                &mut sessions,
                desktop_agent_signal_request("detached-pane-ipc-auth", "detached-token", true)
            ),
            Some(AgentIpcResponse {
                version: 1,
                id: "detached-pane-ipc-auth".to_string(),
                ok: true,
                result: Some(AgentIpcResponseResult::default()),
                error: None,
            })
        );
    }
    {
        let mut sessions: [&mut DesktopWindowSession; 2] = [&mut session, &mut moved];
        assert_eq!(
            DesktopWindowSession::handle_agent_ipc_request_for_sessions(
                &mut sessions,
                desktop_pane_list_request("detached-pane-list", "detached-token", true, [])
            ),
            Some(AgentIpcResponse {
                version: 1,
                id: "detached-pane-list".to_string(),
                ok: true,
                result: Some(AgentIpcResponseResult {
                    pane_list: Some(vec![PaneListEntry {
                        index: 1,
                        id: "pane-right".to_string(),
                        column: 1,
                        title: "right".to_string(),
                        working_directory: None,
                        is_focused: true,
                        agent_tool: None,
                        agent_status: None,
                    }]),
                    ..AgentIpcResponseResult::default()
                }),
                error: None,
            })
        );
    }

    moved.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task detached agent ipc".chars() {
        moved.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        moved
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(moved.pane_ids(), vec!["pane-right"]);

    poll_until(&mut moved, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DETACHED_AGENT_IPC_TASK"))
    });
    assert!(
        moved
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DETACHED_AGENT_IPC_TASK"),
        "moved pane text: {}",
        moved.plain_text_for_pane("pane-right").unwrap_or_default()
    );

    moved.terminate().ok();
    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_opens_new_task_pane_when_terminal_progress_is_active() {
    let dir = test_directory("desktop-task-runner-active-progress");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|active-progress",
        "active progress",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DESKTOP_TASK_ACTIVE_PROGRESS & exit",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert!(
        session.record_pane_shell_activity_state(
            "pane-right",
            TaskRunnerShellActivityState::PromptIdle
        )
    );
    session
        .feed_output_for_pane("pane-right", b"\x1b]9;4;3\x07")
        .expect("progress report should feed");

    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task active progress".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Run task: active progress".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );
    assert_eq!(
        session.pane_ids(),
        vec!["pane-left", "pane-right", "pane-3"]
    );
    assert_eq!(session.focused_pane_id(), Some("pane-3"));
    assert_eq!(session.pane_snapshots()[2].title, "active progress");

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-3")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_ACTIVE_PROGRESS"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-3")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_ACTIVE_PROGRESS"),
        "task pane text: {}",
        session.plain_text_for_pane("pane-3").unwrap_or_default()
    );
    assert!(
        !session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_ACTIVE_PROGRESS"),
        "right pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_task_runner_new_pane_gets_agent_ipc_environment() {
    let dir = test_directory("desktop-task-runner-dynamic-agent-ipc");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let command = r"echo ZENTTY_DYNAMIC_IPC %ZENTTY_INSTANCE_SOCKET% %ZENTTY_PANE_TOKEN% %ZENTTY_CLI_BIN% %ZENTTY_INSTANCE_ID%";
    let task = TaskRunnerAction::new(
        "package|package.json|dynamic-agent-ipc",
        "dynamic agent ipc",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        command,
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-dynamic-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "dynamic-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-right", "right-token");

    let mut session = DesktopWindowSession::spawn_with_agent_ipc(launch, ipc_environment)
        .expect("desktop session should spawn");
    assert_eq!(
        session.run_task_runner_with_shell_state(
            &task.id,
            TaskRunnerShellActivityState::CommandRunning,
            true
        ),
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: "pane-3".to_string(),
            command: command.to_string(),
        }
    );

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-3")
            .is_some_and(|text| text.contains("ZENTTY_DYNAMIC_IPC"))
    });
    let pane_text = session.plain_text_for_pane("pane-3").unwrap_or_default();
    let compact_pane_text = pane_text.replace('\n', "");
    assert!(
        compact_pane_text.contains(r"\\.\pipe\zentty-dynamic-ipc-test"),
        "pane text: {pane_text}"
    );
    assert!(
        compact_pane_text.contains(r"C:\Zentty\zentty-win.exe"),
        "pane text: {pane_text}"
    );
    assert!(
        compact_pane_text.contains("dynamic-ipc-instance"),
        "pane text: {pane_text}"
    );
    assert!(
        !compact_pane_text.contains("%ZENTTY_PANE_TOKEN%"),
        "pane text: {pane_text}"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_task_runner_at_idle_prompt_submits_in_focused_pane() {
    let dir = test_directory("desktop-task-runner-focused");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    for pane in &mut app.windows[0].worklanes[0].panes {
        pane.terminal_request.command = Some("findstr .".to_string());
    }
    let task = TaskRunnerAction::new(
        "package|package.json|dev",
        "dev",
        None,
        TaskRunnerSourceKind::PackageScript,
        dir.join("package.json").to_string_lossy(),
        "echo ZENTTY_DESKTOP_TASK_FOCUSED",
        None,
    )
    .with_working_directory(dir.to_string_lossy());
    app.windows[0].task_runner_actions = vec![task.clone()];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.run_task_runner_with_shell_state(
            &task.id,
            TaskRunnerShellActivityState::PromptIdle,
            false
        ),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-right".to_string(),
            command: "echo ZENTTY_DESKTOP_TASK_FOCUSED".to_string(),
        }
    );
    assert_eq!(session.pane_ids(), vec!["pane-left", "pane-right"]);
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-right")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_TASK_FOCUSED"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_FOCUSED"),
        "focused task pane text: {}",
        session
            .plain_text_for_pane("pane-right")
            .unwrap_or_default()
    );
    assert!(
        !session
            .plain_text_for_pane("pane-left")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_TASK_FOCUSED"),
        "left pane text: {}",
        session.plain_text_for_pane("pane-left").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_command_palette_runs_restored_command_in_target_pane() {
    let dir = test_directory("desktop-restored-command");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .command = Some("findstr .".to_string());
    app.windows[0].worklanes[0].panes[0].restored_rerunnable_command =
        Some("echo ZENTTY_RESTORED_COMMAND".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "ZENTTY_RESTORED_COMMAND".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Run Last Command Again".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::Repaint
    );

    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-main")
            .is_some_and(|text| text.contains("ZENTTY_RESTORED_COMMAND"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-main")
            .unwrap_or_default()
            .contains("ZENTTY_RESTORED_COMMAND"),
        "pane text: {}",
        session.plain_text_for_pane("pane-main").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_disabled_task_runner_opens_source() {
    let dir = test_directory("desktop-task-runner-source");
    let source_path = dir.join("Taskfile.yml").to_string_lossy().to_string();
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].task_runner_actions = vec![TaskRunnerAction::new(
        "taskfile|Taskfile.yml|deploy",
        "deploy",
        None,
        TaskRunnerSourceKind::Taskfile,
        source_path.clone(),
        "task deploy",
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: TARGET",
        )),
    )];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    session.execute_key_event(DesktopKeyEvent::new(
        DesktopKey::Character('p'),
        DesktopKeyModifiers {
            control: true,
            alt: false,
            shift: true,
        },
    ));
    for ch in "run task deploy".chars() {
        session.write_char_event(ch).expect("query should update");
    }
    assert_eq!(
        session
            .command_palette_snapshot()
            .and_then(|snapshot| snapshot.items.first().map(|item| item.title.clone())),
        Some("Run task: deploy".to_string())
    );

    assert_eq!(
        session
            .write_char_event('\r')
            .expect("enter should execute selected item"),
        DesktopCommandEffect::OpenPathWithTarget {
            path: source_path,
            target_id: "default".to_string(),
            target_name: "Default App".to_string(),
            app_path: None,
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_move_pane_to_new_window_targets_focused_pane() {
    let dir = test_directory("move-pane-handoff");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(session.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        session.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::RequestMovePaneToNewWindow {
            pane_id: "pane-right".to_string(),
        }
    );
    assert_eq!(
        session.execute_command(AppCommandId::FocusLeftPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        session.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::RequestMovePaneToNewWindow {
            pane_id: "pane-left".to_string(),
        }
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_ui_search_and_copy_commands_return_handoff_results() {
    let dir = test_directory("desktop-ui-handoffs");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some(dir.to_string_lossy().to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    let cases = [
        (
            AppCommandId::Find,
            AppCommandExecutionResult::ShowPaneSearch {
                pane_id: "pane-main".to_string(),
            },
        ),
        (
            AppCommandId::GlobalFind,
            AppCommandExecutionResult::ShowGlobalSearch,
        ),
        (
            AppCommandId::UseSelectionForFind,
            AppCommandExecutionResult::UseSelectionForFind {
                pane_id: "pane-main".to_string(),
            },
        ),
        (
            AppCommandId::FindNext,
            AppCommandExecutionResult::FindNext {
                pane_id: "pane-main".to_string(),
            },
        ),
        (
            AppCommandId::FindPrevious,
            AppCommandExecutionResult::FindPrevious {
                pane_id: "pane-main".to_string(),
            },
        ),
        (
            AppCommandId::CleanCopy,
            AppCommandExecutionResult::CopySelection { mode: "clean" },
        ),
        (
            AppCommandId::CopyRaw,
            AppCommandExecutionResult::CopySelection { mode: "raw" },
        ),
        (
            AppCommandId::CopyFocusedPanePath,
            AppCommandExecutionResult::CopyText {
                text: dir.to_string_lossy().to_string(),
            },
        ),
        (
            AppCommandId::RenameCurrentWorklane,
            AppCommandExecutionResult::BeginRenameWorklane {
                worklane_id: "main".to_string(),
            },
        ),
        (
            AppCommandId::ShowCommandPalette,
            AppCommandExecutionResult::ShowCommandPalette,
        ),
        (
            AppCommandId::OpenSettings,
            AppCommandExecutionResult::ShowSettings { section: "general" },
        ),
    ];

    for (command_id, expected) in cases {
        assert_eq!(
            session.execute_command(command_id),
            expected,
            "{command_id:?} should return the shared handoff result"
        );
    }

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_copy_path_rejects_missing_or_blank_focused_cwd() {
    let dir = test_directory("desktop-copy-path-missing");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: default_app_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::CopyFocusedPanePath),
        AppCommandExecutionResult::Unavailable
    );
    session.terminate().ok();

    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing-again.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].panes[0]
        .terminal_request
        .working_directory = Some("   ".to_string());
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };
    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::CopyFocusedPanePath),
        AppCommandExecutionResult::Unavailable
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_duplicate_focused_pane_spawns_inherited_live_pane() {
    let dir = test_directory("duplicate-focused");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
            "--cols",
            "80",
            "--rows",
            "10",
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = two_pane_launch_plan();
    app.windows[0].worklanes[0].panes[1]
        .terminal_request
        .environment_variables
        .push((
            "ZENTTY_DESKTOP_DUP_ENV".to_string(),
            "duplicated".to_string(),
        ));
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::DuplicateFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        session.pane_ids(),
        vec!["pane-left", "pane-right", "pane-3"]
    );
    assert_eq!(session.focused_pane_id(), Some("pane-3"));
    let snapshots = session.pane_snapshots();
    assert_eq!(snapshots[2].column_index, 2);
    assert_eq!(snapshots[2].pane_index, 0);

    for ch in "echo ZENTTY_DESKTOP_DUPLICATED %ZENTTY_DESKTOP_DUP_ENV%\r".chars() {
        session
            .write_char(ch)
            .expect("duplicated pane should accept input");
    }
    poll_until(&mut session, |session| {
        session
            .plain_text_for_pane("pane-3")
            .is_some_and(|text| text.contains("ZENTTY_DESKTOP_DUPLICATED duplicated"))
    });
    assert!(
        session
            .plain_text_for_pane("pane-3")
            .unwrap_or_default()
            .contains("ZENTTY_DESKTOP_DUPLICATED duplicated"),
        "duplicated pane text: {}",
        session.plain_text_for_pane("pane-3").unwrap_or_default()
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_layout_commands_apply_shared_width_and_reset_rules() {
    let dir = test_directory("desktop-layout-widths");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let worklane = &mut app.windows[0].worklanes[0];
    worklane.focused_pane_id = Some("pane-middle".to_string());
    worklane.panes[0].pane_id = "pane-left".to_string();
    worklane.panes[0].title = "left".to_string();
    worklane.panes[0].column_id = "column-left".to_string();
    worklane.panes[0].column_width = 300.0;
    let mut middle = worklane.panes[0].clone();
    middle.pane_id = "pane-middle".to_string();
    middle.title = "middle".to_string();
    middle.column_id = "column-middle".to_string();
    middle.column_index = 1;
    middle.column_width = 500.0;
    let mut right = worklane.panes[0].clone();
    right.pane_id = "pane-right".to_string();
    right.title = "right".to_string();
    right.column_id = "column-right".to_string();
    right.column_index = 2;
    right.column_width = 700.0;
    worklane.panes.push(middle);
    worklane.panes.push(right);
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::ArrangeWidthThirds),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        desktop_snapshot_layout(&session),
        vec![
            ("pane-left".to_string(), "column-left".to_string(), 0, 0),
            ("pane-middle".to_string(), "column-middle".to_string(), 1, 0,),
            ("pane-right".to_string(), "column-right".to_string(), 2, 0),
        ]
    );
    assert_desktop_widths(&session, &[500.0, 500.0, 500.0]);

    assert_eq!(
        session.execute_command(AppCommandId::ArrangeWidthQuarters),
        AppCommandExecutionResult::Unavailable
    );
    assert_desktop_widths(&session, &[500.0, 500.0, 500.0]);

    assert_eq!(
        session.execute_command(AppCommandId::ResetPaneLayout),
        AppCommandExecutionResult::Applied
    );
    assert_desktop_widths(&session, &[640.0, 640.0, 640.0]);
    assert_eq!(
        session.execute_command(AppCommandId::ResetPaneLayout),
        AppCommandExecutionResult::Unavailable
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn desktop_window_session_layout_commands_reflow_vertical_panes_in_reading_order() {
    let dir = test_directory("desktop-layout-heights");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let worklane = &mut app.windows[0].worklanes[0];
    worklane.focused_pane_id = Some("pane-d".to_string());
    worklane.panes[0].pane_id = "pane-a".to_string();
    worklane.panes[0].title = "a".to_string();
    worklane.panes[0].column_id = "column-left".to_string();
    worklane.panes[0].column_width = 320.0;
    worklane.panes[0].pane_height = Some(2.0);
    let mut b = worklane.panes[0].clone();
    b.pane_id = "pane-b".to_string();
    b.title = "b".to_string();
    b.pane_index = 1;
    b.pane_height = Some(4.0);
    let mut c = worklane.panes[0].clone();
    c.pane_id = "pane-c".to_string();
    c.title = "c".to_string();
    c.column_id = "column-right".to_string();
    c.column_index = 1;
    c.pane_index = 0;
    c.column_width = 520.0;
    c.pane_height = Some(8.0);
    let mut d = c.clone();
    d.pane_id = "pane-d".to_string();
    d.title = "d".to_string();
    d.pane_index = 1;
    d.pane_height = Some(16.0);
    worklane.panes.extend([b, c, d]);
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");

    assert_eq!(
        session.execute_command(AppCommandId::ArrangeHeightThreePerColumn),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        desktop_snapshot_layout(&session),
        vec![
            ("pane-a".to_string(), "column-left".to_string(), 0, 0),
            ("pane-b".to_string(), "column-left".to_string(), 0, 1),
            ("pane-c".to_string(), "column-left".to_string(), 0, 2),
            ("pane-d".to_string(), "column-right".to_string(), 1, 0),
        ]
    );
    assert_desktop_heights(&session, &[Some(1.0), Some(1.0), Some(1.0), Some(1.0)]);
    assert_eq!(session.focused_pane_id(), Some("pane-d"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn focus_pane_by_id_switches_focus_within_active_worklane() {
    let dir = test_directory("focus-pane-by-id-same-worklane");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert!(
        session.focus_pane_by_id("pane-left"),
        "clicking a different pane in the active worklane should change focus"
    );
    assert_eq!(session.focused_pane_id(), Some("pane-left"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn focus_pane_by_id_activates_owning_worklane() {
    let dir = test_directory("focus-pane-by-id-cross-worklane");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let mut app = default_app_launch_plan();
    let mut alpha = app.windows[0].worklanes[0].clone();
    alpha.worklane_id = "alpha".to_string();
    alpha.focused_pane_id = Some("pane-alpha".to_string());
    alpha.panes[0].worklane_id = "alpha".to_string();
    alpha.panes[0].pane_id = "pane-alpha".to_string();
    alpha.panes[0].column_id = "column-alpha".to_string();
    let mut beta = alpha.clone();
    beta.worklane_id = "beta".to_string();
    beta.focused_pane_id = Some("pane-beta".to_string());
    beta.panes[0].worklane_id = "beta".to_string();
    beta.panes[0].pane_id = "pane-beta".to_string();
    beta.panes[0].column_id = "column-beta".to_string();
    app.windows[0].active_worklane_id = Some("alpha".to_string());
    app.windows[0].worklanes = vec![alpha, beta];
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app,
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.focused_pane_id(), Some("pane-alpha"));
    assert_eq!(session.worklane_id(), "alpha");

    assert!(
        session.focus_pane_by_id("pane-beta"),
        "clicking a pane in another worklane should change focus"
    );
    assert_eq!(session.focused_pane_id(), Some("pane-beta"));
    assert_eq!(
        session.worklane_id(),
        "beta",
        "focusing a cross-worklane pane should activate its worklane"
    );

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn focus_pane_by_id_already_focused_is_no_op() {
    let dir = test_directory("focus-pane-by-id-already-focused");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert!(
        !session.focus_pane_by_id("pane-right"),
        "re-focusing the already-focused pane should be a no-op"
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn focus_pane_by_id_unknown_is_safe_no_op() {
    let dir = test_directory("focus-pane-by-id-unknown");
    let shell = DesktopShellConfig::parse_with_environment(
        [
            "--config",
            dir.join("missing.toml").to_string_lossy().as_ref(),
        ],
        DesktopEnvironment::empty(),
    )
    .expect("desktop config should parse");
    let launch = DesktopLaunchPlan {
        shell,
        config: AppConfig::default(),
        source: DesktopLaunchSource::NewWorkspace,
        app: two_pane_launch_plan(),
    };

    let mut session = DesktopWindowSession::spawn(launch).expect("desktop session should spawn");
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    assert!(
        !session.focus_pane_by_id("pane-does-not-exist"),
        "an unknown pane id should be a safe no-op"
    );
    assert_eq!(session.focused_pane_id(), Some("pane-right"));

    session.terminate().ok();
    fs::remove_dir_all(dir).ok();
}

fn workspace_envelope(cwd: &std::path::Path) -> SessionRestoreEnvelope {
    SessionRestoreEnvelope {
        reason: SaveReason::LiveSnapshot,
        workspace: WorkspaceRecipe {
            active_window_id: Some("window-restored".to_string()),
            windows: vec![WorkspaceRecipeWindow {
                id: "window-restored".to_string(),
                active_worklane_id: Some("main".to_string()),
                worklanes: vec![WorkspaceRecipeWorklane {
                    id: "main".to_string(),
                    title: Some("Restored".to_string()),
                    next_pane_number: 2,
                    focused_column_id: Some("column-main".to_string()),
                    columns: vec![WorkspaceRecipeColumn {
                        id: "column-main".to_string(),
                        width: 640.0,
                        focused_pane_id: Some("pane-restored".to_string()),
                        last_focused_pane_id: Some("pane-restored".to_string()),
                        pane_heights: vec![360.0],
                        panes: vec![WorkspaceRecipePane {
                            id: "pane-restored".to_string(),
                            title_seed: Some("restored".to_string()),
                            working_directory: Some(cwd.to_string_lossy().into_owned()),
                            last_activity_title: None,
                            last_run_command: None,
                        }],
                    }],
                    color: None,
                    bookmark_origin_id: None,
                }],
            }],
            ..WorkspaceRecipe::default()
        },
        ..SessionRestoreEnvelope::default()
    }
}

fn two_pane_launch_plan() -> zentty_win::app::AppLaunchPlan {
    let mut app = default_app_launch_plan();
    app.windows[0].worklanes[0].focused_pane_id = Some("pane-right".to_string());
    app.windows[0].worklanes[0].panes[0].pane_id = "pane-left".to_string();
    app.windows[0].worklanes[0].panes[0].title = "left".to_string();
    app.windows[0].worklanes[0].panes[0].column_id = "column-left".to_string();
    let mut right = app.windows[0].worklanes[0].panes[0].clone();
    right.pane_id = "pane-right".to_string();
    right.title = "right".to_string();
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    app.windows[0].worklanes[0].panes.push(right);
    app
}

fn desktop_agent_signal_request(
    id: &str,
    pane_token: &str,
    expects_response: bool,
) -> AgentIpcRequest {
    AgentIpcRequest {
        version: 1,
        id: id.to_string(),
        kind: AgentIpcRequestKind::Ipc,
        arguments: vec!["shell-state".to_string(), "prompt".to_string()],
        standard_input: None,
        environment: BTreeMap::from([
            ("ZENTTY_WINDOW_ID".to_string(), "window-main".to_string()),
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-right".to_string()),
            ("ZENTTY_PANE_TOKEN".to_string(), pane_token.to_string()),
        ]),
        expects_response,
        subcommand: Some("agent-signal".to_string()),
        tool: None,
    }
}

fn desktop_pane_list_request<'a, I>(
    id: &str,
    pane_token: &str,
    expects_response: bool,
    arguments: I,
) -> AgentIpcRequest
where
    I: IntoIterator<Item = &'a str>,
{
    desktop_pane_request(id, "list", pane_token, expects_response, arguments)
}

fn desktop_pane_request<'a, I>(
    id: &str,
    subcommand: &str,
    pane_token: &str,
    expects_response: bool,
    arguments: I,
) -> AgentIpcRequest
where
    I: IntoIterator<Item = &'a str>,
{
    AgentIpcRequest {
        version: 1,
        id: id.to_string(),
        kind: AgentIpcRequestKind::Pane,
        arguments: arguments.into_iter().map(str::to_string).collect(),
        standard_input: None,
        environment: BTreeMap::from([
            ("ZENTTY_WINDOW_ID".to_string(), "window-main".to_string()),
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-right".to_string()),
            ("ZENTTY_PANE_TOKEN".to_string(), pane_token.to_string()),
        ]),
        expects_response,
        subcommand: Some(subcommand.to_string()),
        tool: None,
    }
}

fn desktop_server_request<'a, I>(
    id: &str,
    subcommand: &str,
    pane_token: &str,
    expects_response: bool,
    arguments: I,
) -> AgentIpcRequest
where
    I: IntoIterator<Item = &'a str>,
{
    AgentIpcRequest {
        version: 1,
        id: id.to_string(),
        kind: AgentIpcRequestKind::Server,
        arguments: arguments.into_iter().map(str::to_string).collect(),
        standard_input: None,
        environment: BTreeMap::from([
            ("ZENTTY_WINDOW_ID".to_string(), "window-main".to_string()),
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-right".to_string()),
            ("ZENTTY_PANE_TOKEN".to_string(), pane_token.to_string()),
        ]),
        expects_response,
        subcommand: Some(subcommand.to_string()),
        tool: None,
    }
}

fn desktop_ipc_success_response(id: &str) -> Option<AgentIpcResponse> {
    Some(AgentIpcResponse {
        version: 1,
        id: id.to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    })
}

fn desktop_ipc_stdout_response(id: &str, stdout: &str) -> Option<AgentIpcResponse> {
    Some(AgentIpcResponse {
        version: 1,
        id: id.to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult {
            stdout: Some(stdout.to_string()),
            ..AgentIpcResponseResult::default()
        }),
        error: None,
    })
}

#[cfg(windows)]
fn focused_line_and_column(session: &DesktopWindowSession, needle: &str) -> (usize, usize) {
    let snapshots = session.pane_snapshots();
    let focused = snapshots
        .iter()
        .find(|snapshot| snapshot.is_focused)
        .expect("session should have a focused pane snapshot");
    focused
        .visible_lines
        .iter()
        .enumerate()
        .find_map(|(line_index, line)| {
            line.find(needle)
                .map(|column| (line_index, line[..column].chars().count()))
        })
        .unwrap_or_else(|| panic!("focused pane should contain {needle:?}: {focused:?}"))
}

#[cfg(windows)]
fn desktop_snapshot_layout(session: &DesktopWindowSession) -> Vec<(String, String, usize, usize)> {
    session
        .pane_snapshots()
        .into_iter()
        .map(|snapshot| {
            (
                snapshot.pane_id,
                snapshot.column_id,
                snapshot.column_index,
                snapshot.pane_index,
            )
        })
        .collect()
}

#[cfg(windows)]
fn assert_desktop_widths(session: &DesktopWindowSession, expected: &[f64]) {
    let observed = session
        .pane_snapshots()
        .into_iter()
        .map(|snapshot| snapshot.column_width)
        .collect::<Vec<_>>();
    assert_eq!(observed.len(), expected.len());
    for (observed, expected) in observed.iter().zip(expected) {
        assert!(
            (observed - expected).abs() < 0.0001,
            "expected width {expected}, observed {observed}"
        );
    }
}

#[cfg(windows)]
fn assert_desktop_heights(session: &DesktopWindowSession, expected: &[Option<f64>]) {
    let observed = session
        .pane_snapshots()
        .into_iter()
        .map(|snapshot| snapshot.pane_height)
        .collect::<Vec<_>>();
    assert_eq!(observed.len(), expected.len());
    for (observed, expected) in observed.iter().zip(expected) {
        match (observed, expected) {
            (Some(observed), Some(expected)) => assert!(
                (observed - expected).abs() < 0.0001,
                "expected height {expected}, observed {observed}"
            ),
            _ => assert_eq!(observed, expected),
        }
    }
}

#[cfg(windows)]
fn assert_desktop_snapshot_grid(session: &DesktopWindowSession, cols: usize, rows: usize) {
    for snapshot in session.pane_snapshots() {
        assert_eq!(
            snapshot.visible_lines.len(),
            rows,
            "pane {} should have {rows} visible rows: {:?}",
            snapshot.pane_id,
            snapshot.visible_lines
        );
        for line in &snapshot.visible_lines {
            assert_eq!(
                line.chars().count(),
                cols,
                "pane {} line should have {cols} columns: {line:?}",
                snapshot.pane_id
            );
        }
    }
}

#[cfg(windows)]
fn poll_until<F>(session: &mut DesktopWindowSession, predicate: F)
where
    F: Fn(&DesktopWindowSession) -> bool,
{
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !predicate(session) && std::time::Instant::now() < deadline {
        session
            .poll_output()
            .expect("desktop session should poll PTY output");
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

fn test_directory(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("zentty-desktop-{name}-{}", std::process::id()));
    fs::remove_dir_all(&dir).ok();
    fs::create_dir_all(&dir).expect("test directory should be created");
    dir
}
