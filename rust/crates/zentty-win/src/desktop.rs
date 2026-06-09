use std::collections::{BTreeMap, HashSet, VecDeque};
use std::env;
use std::error::Error;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use zentty_core::agent::{
    AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse, AgentIpcResponseResult,
    AgentPidSignalEvent, AgentSignalKind, AgentSignalPayload, PaneListEntry, ServerListEntry,
    ServerListResult,
};
use zentty_core::bookmarks::{
    BookmarkNameSuggester, BookmarkStore, BookmarksPopoverModel, WorkspaceTemplate,
    WorkspaceTemplateCapture, WorkspaceTemplateCaptureColumn, WorkspaceTemplateCaptureInput,
    WorkspaceTemplateCapturePane, WorkspaceTemplateColumn, WorkspaceTemplateExporter,
    WorkspaceTemplateKind, template_safe_environment_overrides,
};
use zentty_core::command_palette::{
    CommandPaletteItemId, DetectedServer, DetectedServerConfidence, DetectedServerSource,
    OpenWithResolvedTarget, SettingsSection, TaskRunnerAction, WorklaneColor,
};
use zentty_core::commands::AppCommandId;
use zentty_core::config::{
    AppConfig, AppConfigStore, AppUpdateChannel, AppearanceThemeMode, FocusFollowsMouseDelay,
    NewWorklanePlacement, PaneLayoutConfig, PaneSplitBehaviorMode, PanesConfig,
    ServerDetectionConfig, ShortcutBindingOverride, ShortcutsConfig, SidebarVisibility,
};
use zentty_core::focus_history::{PaneFocusHistory, PaneReference};
use zentty_core::layout::{PaneId, TerminalSessionRequest};
use zentty_core::restore::ClosedPaneStack;
use zentty_core::server_detection::{
    ServerOutputUrlDetector, ServerUrlCandidate, ServerUrlNormalizer,
};
use zentty_core::servers::{
    RankedServer, ServerPortRule, ServerRegistry, ServerRelevance, ServerRelevanceContext,
    ServerRelevanceReason, ServerRelevanceTier,
};
use zentty_core::session_restore::SessionRestoreEnvelope;
use zentty_core::task_manager::TaskManagerPaneSource;
use zentty_core::task_runner::{
    TaskRunnerExecutionPlan, TaskRunnerExecutionPlanner, TaskRunnerFocusedPaneState,
    TaskRunnerShellActivityState,
};
use zentty_pty::native::NativePtyOutputStream;
use zentty_pty::{PtyError, TerminalSize};
use zentty_terminal::clipboard::{TerminalClipboardPaste, TerminalCopyMode, TerminalCopyPlanner};
use zentty_terminal::global_search::{
    GlobalSearchAction, GlobalSearchCoordinator, GlobalSearchTarget,
};
use zentty_terminal::input::{TerminalInputPlanner, TerminalPasteMode};
use zentty_terminal::screen::{
    TerminalMouseMode, TerminalScreen, TerminalSearchMatch, TerminalTextPoint, TerminalTextRange,
};
use zentty_terminal::search::TerminalSearchSession;
use zentty_terminal::selection::TerminalSelection;

use crate::app::{
    AgentIpcPaneEnvironment, AgentIpcPaneSelectors, AgentIpcPaneTarget, AgentIpcRequestRejection,
    AgentIpcRuntimeEnvironment, AppCommandExecutionResult, AppLaunchError, AppLaunchPlan,
    CommandPaletteItemExecutionResult, PaneIpcGridDestination, PaneIpcGridFocus,
    PaneIpcSplitDirection, PaneIpcSplitLayout, PaneIpcThemeCommand, PaneLaunchSpec,
    PaneNotification, WindowLaunchPlan, WorklaneLaunchPlan, agent_ipc_error_response_if_expected,
    agent_ipc_pane_list_success_response_if_expected,
    agent_ipc_stdout_success_response_if_expected, agent_ipc_success_response_if_expected,
    agent_signal_payload_for_authenticated_ipc_request, grid_cell_count, normalized_worklane_title,
    pane_ipc_grid_options, pane_ipc_notification_options, pane_ipc_theme_mode_token,
    pane_ipc_worklane_color, pane_ipc_worklane_id_override, pane_ipc_worklane_rename,
    parse_agent_ipc_pane_selectors, percentage_fraction,
};
use crate::ipc::{
    AgentIpcTransportError, agent_ipc_pipe_path_for_instance, generate_agent_ipc_instance_id,
    generate_agent_ipc_pane_token,
};
use crate::open_with::{resolve_available_open_with_targets, resolve_open_with_targets};
use crate::server_browser::{
    ServerBrowserOpenTarget, resolve_available_server_browser_targets,
    server_browser_target_for_open,
};
use crate::task_manager::{
    DesktopTaskManagerState, DesktopTaskManagerTextSnapshot, WindowsTaskManagerProcessProbe,
};

pub const DEFAULT_WINDOW_TITLE: &str = "Zentty";
const DESKTOP_TEXT_LEFT: i32 = 8;
const DESKTOP_TEXT_TOP: i32 = 8;
const DESKTOP_CELL_WIDTH: i32 = 8;
const DESKTOP_LINE_HEIGHT: i32 = 18;
const DESKTOP_DEFAULT_COLUMN_WIDTH: f64 = 640.0;

pub fn desktop_terminal_size_for_client_area(
    width_pixels: i32,
    height_pixels: i32,
) -> TerminalSize {
    let usable_width = width_pixels.saturating_sub(DESKTOP_TEXT_LEFT * 2);
    let usable_height = height_pixels.saturating_sub(DESKTOP_TEXT_TOP * 2);
    let cols = (usable_width / DESKTOP_CELL_WIDTH).max(1) as u16;
    let rows = (usable_height / DESKTOP_LINE_HEIGHT).max(1) as u16;
    TerminalSize::new(cols, rows)
        .with_cell_pixels(DESKTOP_CELL_WIDTH as u16, DESKTOP_LINE_HEIGHT as u16)
}

pub fn desktop_render_cell_for_client_point(
    x_pixels: i32,
    y_pixels: i32,
) -> Option<(usize, usize)> {
    if x_pixels < DESKTOP_TEXT_LEFT || y_pixels < DESKTOP_TEXT_TOP {
        return None;
    }
    let column = (x_pixels - DESKTOP_TEXT_LEFT) / DESKTOP_CELL_WIDTH;
    let row = (y_pixels - DESKTOP_TEXT_TOP) / DESKTOP_LINE_HEIGHT;
    Some((row as usize, column as usize))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopEnvironment {
    pub app_data: Option<PathBuf>,
    pub user_profile: Option<PathBuf>,
}

impl DesktopEnvironment {
    pub fn current() -> Self {
        Self {
            app_data: std::env::var_os("APPDATA").map(PathBuf::from),
            user_profile: std::env::var_os("USERPROFILE").map(PathBuf::from),
        }
    }

    pub fn empty() -> Self {
        Self {
            app_data: None,
            user_profile: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopShellConfig {
    pub config_path: PathBuf,
    pub workspace_path: Option<PathBuf>,
    pub window_title: String,
    pub size: TerminalSize,
}

impl DesktopShellConfig {
    pub fn parse<I, S>(args: I) -> Result<Self, DesktopShellConfigError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self::parse_with_environment(args, DesktopEnvironment::current())
    }

    pub fn parse_with_environment<I, S>(
        args: I,
        environment: DesktopEnvironment,
    ) -> Result<Self, DesktopShellConfigError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut args = args.into_iter().map(Into::into).peekable();
        let mut config_path = None;
        let mut workspace_path = None;
        let mut window_title = DEFAULT_WINDOW_TITLE.to_string();
        let mut cols = TerminalSize::default().cols;
        let mut rows = TerminalSize::default().rows;

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => return Err(DesktopShellConfigError::HelpRequested),
                "--config" => {
                    config_path = Some(PathBuf::from(next_value(&mut args, "--config")?));
                }
                "--workspace" => {
                    workspace_path = Some(PathBuf::from(next_value(&mut args, "--workspace")?));
                }
                "--cols" => {
                    let value = next_value(&mut args, "--cols")?;
                    cols = parse_dimension("--cols", &value)?;
                }
                "--rows" => {
                    let value = next_value(&mut args, "--rows")?;
                    rows = parse_dimension("--rows", &value)?;
                }
                "--title" => {
                    let value = next_value(&mut args, "--title")?;
                    if value.trim().is_empty() {
                        return Err(DesktopShellConfigError::EmptyTitle);
                    }
                    window_title = value;
                }
                value if value.starts_with("--") => {
                    return Err(DesktopShellConfigError::UnknownOption(value.to_string()));
                }
                value => {
                    return Err(DesktopShellConfigError::UnexpectedCommand(
                        value.to_string(),
                    ));
                }
            }
        }

        let config_path = match config_path {
            Some(path) => path,
            None => default_config_path(&environment)
                .ok_or(DesktopShellConfigError::ConfigPathUnavailable)?,
        };

        Ok(Self {
            config_path,
            workspace_path,
            window_title,
            size: TerminalSize::new(cols, rows),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopShellConfigError {
    MissingValue(String),
    InvalidNumber { option: String, value: String },
    UnknownOption(String),
    UnexpectedCommand(String),
    EmptyTitle,
    ConfigPathUnavailable,
    HelpRequested,
}

impl fmt::Display for DesktopShellConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingValue(option) => write!(formatter, "missing value for {option}"),
            Self::InvalidNumber { option, value } => {
                write!(formatter, "invalid numeric value for {option}: {value:?}")
            }
            Self::UnknownOption(option) => write!(formatter, "unknown option: {option}"),
            Self::UnexpectedCommand(command) => {
                write!(
                    formatter,
                    "desktop mode does not accept trailing commands: {command}"
                )
            }
            Self::EmptyTitle => write!(formatter, "--title cannot be empty"),
            Self::ConfigPathUnavailable => {
                write!(
                    formatter,
                    "unable to resolve config path from APPDATA or USERPROFILE"
                )
            }
            Self::HelpRequested => write!(formatter, "help requested"),
        }
    }
}

impl Error for DesktopShellConfigError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopLaunchSource {
    NewWorkspace,
    WorkspaceRestore(PathBuf),
}

#[derive(Clone, Debug, PartialEq)]
pub struct DesktopLaunchPlan {
    pub shell: DesktopShellConfig,
    pub config: AppConfig,
    pub source: DesktopLaunchSource,
    pub app: AppLaunchPlan,
}

pub struct DesktopTerminalState {
    screen: TerminalScreen,
}

impl DesktopTerminalState {
    pub fn new(size: TerminalSize) -> Self {
        Self {
            screen: TerminalScreen::new(usize::from(size.cols), usize::from(size.rows)),
        }
    }

    pub fn feed_output(&mut self, bytes: &[u8]) -> Vec<u8> {
        self.screen.feed(bytes);
        self.screen.take_pending_responses()
    }

    pub fn resize(&mut self, size: TerminalSize) {
        self.screen
            .resize(usize::from(size.cols), usize::from(size.rows));
    }

    pub fn visible_lines(&self) -> Vec<String> {
        self.screen.visible_lines()
    }

    /// Borrow the terminal screen for styled cell-grid rendering.
    pub fn screen(&self) -> &TerminalScreen {
        &self.screen
    }

    pub fn plain_text(&self) -> String {
        self.screen.plain_text()
    }

    pub fn title(&self) -> Option<&str> {
        self.screen.title()
    }

    pub fn terminal_progress_indicates_activity(&self) -> bool {
        self.screen.terminal_progress_indicates_activity()
    }

    pub fn cursor_visible(&self) -> bool {
        self.screen.cursor_visible()
    }

    /// Take and clear this pane's pending-bell flag.
    pub fn take_bell(&mut self) -> bool {
        self.screen.take_bell()
    }

    pub fn paste_mode_for_request(&self, requested: TerminalPasteMode) -> TerminalPasteMode {
        match requested {
            TerminalPasteMode::Plain if self.screen.bracketed_paste_enabled() => {
                TerminalPasteMode::Bracketed
            }
            mode => mode,
        }
    }

    pub fn pty_bytes_for_char(ch: char) -> Vec<u8> {
        match ch {
            '\r' | '\n' => b"\r".to_vec(),
            '\u{8}' => b"\x7f".to_vec(),
            _ => {
                let mut bytes = Vec::with_capacity(ch.len_utf8());
                let mut buffer = [0_u8; 4];
                bytes.extend_from_slice(ch.encode_utf8(&mut buffer).as_bytes());
                bytes
            }
        }
    }

    pub fn pty_bytes_for_key_event(event: DesktopKeyEvent) -> Option<Vec<u8>> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        let bytes = match event.key {
            DesktopKey::UpArrow => b"\x1b[A".as_slice(),
            DesktopKey::DownArrow => b"\x1b[B".as_slice(),
            DesktopKey::RightArrow => b"\x1b[C".as_slice(),
            DesktopKey::LeftArrow => b"\x1b[D".as_slice(),
            DesktopKey::Delete => b"\x1b[3~".as_slice(),
            DesktopKey::Tab => b"\t".as_slice(),
            DesktopKey::Home => b"\x1b[H".as_slice(),
            DesktopKey::End => b"\x1b[F".as_slice(),
            DesktopKey::PageUp => b"\x1b[5~".as_slice(),
            DesktopKey::PageDown => b"\x1b[6~".as_slice(),
            DesktopKey::Function(n) => return function_key_bytes(n),
            DesktopKey::Character(_) => return None,
        };
        Some(bytes.to_vec())
    }

    pub fn pty_bytes_for_mouse_event(&self, event: DesktopMouseEvent) -> Option<Vec<u8>> {
        if !self.screen.sgr_mouse_enabled() {
            return None;
        }

        let mouse_mode = self.screen.mouse_mode();
        if mouse_mode == TerminalMouseMode::Disabled {
            return None;
        }

        let is_drag = event.kind == DesktopMouseEventKind::Drag;
        if is_drag && mouse_mode == TerminalMouseMode::Normal {
            return None;
        }

        let mut button_code = match event.button {
            DesktopMouseButton::Left => 0,
            DesktopMouseButton::Middle => 1,
            DesktopMouseButton::Right => 2,
        };
        if is_drag {
            button_code += 32;
        }

        let column = event.column.checked_add(1)?;
        let row = event.row.checked_add(1)?;
        let terminator = if event.kind == DesktopMouseEventKind::Release {
            'm'
        } else {
            'M'
        };
        Some(format!("\x1b[<{button_code};{column};{row}{terminator}").into_bytes())
    }

    pub fn pty_bytes_for_terminal_key_event(&self, event: DesktopKeyEvent) -> Option<Vec<u8>> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        if self.screen.application_cursor_keys_enabled() {
            // DECCKM: cursor + Home/End switch to SS3 (ESC O x) form.
            let bytes = match event.key {
                DesktopKey::UpArrow => b"\x1bOA".as_slice(),
                DesktopKey::DownArrow => b"\x1bOB".as_slice(),
                DesktopKey::RightArrow => b"\x1bOC".as_slice(),
                DesktopKey::LeftArrow => b"\x1bOD".as_slice(),
                DesktopKey::Home => b"\x1bOH".as_slice(),
                DesktopKey::End => b"\x1bOF".as_slice(),
                _ => return Self::pty_bytes_for_key_event(event),
            };
            return Some(bytes.to_vec());
        }

        Self::pty_bytes_for_key_event(event)
    }
}

/// xterm byte sequence for function key `n` (1–12); `None` outside that range.
fn function_key_bytes(n: u8) -> Option<Vec<u8>> {
    let bytes: &[u8] = match n {
        1 => b"\x1bOP",
        2 => b"\x1bOQ",
        3 => b"\x1bOR",
        4 => b"\x1bOS",
        5 => b"\x1b[15~",
        6 => b"\x1b[17~",
        7 => b"\x1b[18~",
        8 => b"\x1b[19~",
        9 => b"\x1b[20~",
        10 => b"\x1b[21~",
        11 => b"\x1b[23~",
        12 => b"\x1b[24~",
        _ => return None,
    };
    Some(bytes.to_vec())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopMouseButton {
    Left,
    Middle,
    Right,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopMouseEventKind {
    Press,
    Release,
    Drag,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopMouseEvent {
    pub button: DesktopMouseButton,
    pub kind: DesktopMouseEventKind,
    pub row: usize,
    pub column: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopKey {
    Character(char),
    LeftArrow,
    RightArrow,
    UpArrow,
    DownArrow,
    Delete,
    Tab,
    Home,
    End,
    PageUp,
    PageDown,
    /// Function key F1–F12 (1-based).
    Function(u8),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DesktopKeyModifiers {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
}

impl DesktopKeyModifiers {
    pub fn control() -> Self {
        Self {
            control: true,
            alt: false,
            shift: false,
        }
    }

    pub fn control_alt() -> Self {
        Self {
            control: true,
            alt: true,
            shift: false,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DesktopKeyEvent {
    pub key: DesktopKey,
    pub modifiers: DesktopKeyModifiers,
}

impl DesktopKeyEvent {
    pub fn new(key: DesktopKey, modifiers: DesktopKeyModifiers) -> Self {
        Self { key, modifiers }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopCommandEffect {
    Ignored,
    Repaint,
    CopyText {
        text: String,
        was_cleaned: bool,
    },
    PasteFromClipboard {
        mode: TerminalPasteMode,
    },
    OpenPathWithTarget {
        path: String,
        target_id: String,
        target_name: String,
        app_path: Option<String>,
    },
    OpenUrl {
        url: String,
    },
    OpenUrlWithBrowser {
        url: String,
        browser_id: String,
        browser_name: String,
        app_path: String,
    },
    PaneNotification {
        notification: PaneNotification,
    },
    ConfirmClosePane {
        pane_id: String,
        pane_title: String,
    },
    ConfirmCloseWindow {
        window_id: String,
    },
    CloseWindow {
        window_id: String,
    },
    NewWindow {
        working_directory: Option<String>,
    },
    MovePaneToNewWindow {
        pane_id: String,
    },
    Status {
        message: String,
    },
}

pub struct DesktopShortcutResolver;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DesktopShortcutPreset {
    LeftHand,
    RightHand,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DesktopShortcutPresetEntry {
    command_id: AppCommandId,
    shortcut: &'static str,
}

impl DesktopShortcutPreset {
    fn entries(self) -> &'static [DesktopShortcutPresetEntry] {
        match self {
            Self::LeftHand => LEFT_HAND_SHORTCUT_PRESET,
            Self::RightHand => RIGHT_HAND_SHORTCUT_PRESET,
        }
    }
}

const WINDOWS_DEFAULT_SHORTCUT_COMMANDS: [AppCommandId; 12] = [
    AppCommandId::FocusPreviousPane,
    AppCommandId::FocusNextPane,
    AppCommandId::CopyRaw,
    AppCommandId::SplitVertically,
    AppCommandId::Find,
    AppCommandId::ShowCommandPalette,
    AppCommandId::SplitHorizontally,
    AppCommandId::CloseFocusedPane,
    AppCommandId::FocusLeftPane,
    AppCommandId::FocusRightPane,
    AppCommandId::FocusUpInColumn,
    AppCommandId::FocusDownInColumn,
];

const LEFT_HAND_SHORTCUT_PRESET: &[DesktopShortcutPresetEntry] = &[
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusUpInColumn,
        shortcut: "command+w",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusLeftPane,
        shortcut: "command+a",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusDownInColumn,
        shortcut: "command+s",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusRightPane,
        shortcut: "command+d",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneUp,
        shortcut: "command+shift+w",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneLeft,
        shortcut: "command+shift+a",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneDown,
        shortcut: "command+shift+s",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneRight,
        shortcut: "command+shift+d",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::UseSelectionForFind,
        shortcut: "command+e",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::Find,
        shortcut: "command+f",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FindNext,
        shortcut: "command+g",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FindPrevious,
        shortcut: "command+shift+g",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::SplitHorizontally,
        shortcut: "command+r",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::SplitVertically,
        shortcut: "command+shift+r",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::CloseFocusedPane,
        shortcut: "command+c",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::CopyFocusedPanePath,
        shortcut: "command+shift+c",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthFull,
        shortcut: "command+1",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthHalves,
        shortcut: "command+2",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthThirds,
        shortcut: "command+3",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthQuarters,
        shortcut: "command+4",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightFull,
        shortcut: "command+option+1",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightTwoPerColumn,
        shortcut: "command+option+2",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightThreePerColumn,
        shortcut: "command+option+3",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightFourPerColumn,
        shortcut: "command+option+4",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NewWorklane,
        shortcut: "command+n",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NextWorklane,
        shortcut: "control+tab",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::PreviousWorklane,
        shortcut: "control+shift+tab",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NewWindow,
        shortcut: "command+shift+n",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ShowCommandPalette,
        shortcut: "command+x",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ToggleSidebar,
        shortcut: "command+b",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NavigateBack,
        shortcut: "command+[",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NavigateForward,
        shortcut: "command+]",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::JumpToLatestNotification,
        shortcut: "command+j",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::OpenSettings,
        shortcut: "command+,",
    },
];

const RIGHT_HAND_SHORTCUT_PRESET: &[DesktopShortcutPresetEntry] = &[
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusUpInColumn,
        shortcut: "command+up",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusLeftPane,
        shortcut: "command+left",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusDownInColumn,
        shortcut: "command+down",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FocusRightPane,
        shortcut: "command+right",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneUp,
        shortcut: "command+shift+up",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneLeft,
        shortcut: "command+shift+left",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneDown,
        shortcut: "command+shift+down",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ResizePaneRight,
        shortcut: "command+shift+right",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::SplitHorizontally,
        shortcut: "command+j",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::SplitVertically,
        shortcut: "command+k",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::CloseFocusedPane,
        shortcut: "command+l",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthFull,
        shortcut: "command+1",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthHalves,
        shortcut: "command+2",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthThirds,
        shortcut: "command+3",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeWidthQuarters,
        shortcut: "command+4",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightFull,
        shortcut: "command+option+1",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightTwoPerColumn,
        shortcut: "command+option+2",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightThreePerColumn,
        shortcut: "command+option+3",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ArrangeHeightFourPerColumn,
        shortcut: "command+option+4",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NewWorklane,
        shortcut: "command+n",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NextWorklane,
        shortcut: "command+]",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::PreviousWorklane,
        shortcut: "command+[",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NewWindow,
        shortcut: "command+shift+n",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::UseSelectionForFind,
        shortcut: "command+e",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::Find,
        shortcut: "command+f",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FindNext,
        shortcut: "command+g",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::FindPrevious,
        shortcut: "command+shift+g",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ShowCommandPalette,
        shortcut: "command+;",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::ToggleSidebar,
        shortcut: "command+h",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NavigateBack,
        shortcut: "command+,",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::NavigateForward,
        shortcut: "command+.",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::CopyFocusedPanePath,
        shortcut: "command+shift+l",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::JumpToLatestNotification,
        shortcut: "command+shift+;",
    },
    DesktopShortcutPresetEntry {
        command_id: AppCommandId::OpenSettings,
        shortcut: "command+o",
    },
];

fn shortcut_preset_bindings(preset: DesktopShortcutPreset) -> Vec<ShortcutBindingOverride> {
    let entries = preset.entries();
    let preset_command_ids: HashSet<AppCommandId> =
        entries.iter().map(|entry| entry.command_id).collect();
    let mut bindings = entries
        .iter()
        .map(|entry| ShortcutBindingOverride {
            command_id: entry.command_id.raw_value().to_string(),
            shortcut: Some(entry.shortcut.to_string()),
        })
        .collect::<Vec<_>>();

    for command_id in WINDOWS_DEFAULT_SHORTCUT_COMMANDS {
        if !preset_command_ids.contains(&command_id) {
            bindings.push(ShortcutBindingOverride {
                command_id: command_id.raw_value().to_string(),
                shortcut: None,
            });
        }
    }

    ShortcutsConfig { bindings }.normalized().bindings
}

impl DesktopShortcutResolver {
    pub fn command_for_key_event_with_shortcuts(
        event: DesktopKeyEvent,
        shortcuts: &ShortcutsConfig,
    ) -> Option<AppCommandId> {
        let mut overridden_commands = HashSet::new();
        for binding in &shortcuts.bindings {
            let Some(command_id) = AppCommandId::from_raw_value(&binding.command_id) else {
                continue;
            };
            overridden_commands.insert(command_id);
            if binding
                .shortcut
                .as_deref()
                .and_then(desktop_key_event_for_shortcut)
                == Some(event)
            {
                return Some(command_id);
            }
        }

        Self::command_for_key_event(event)
            .filter(|command_id| !overridden_commands.contains(command_id))
    }

    pub fn command_for_key_event(event: DesktopKeyEvent) -> Option<AppCommandId> {
        if event.modifiers.control && event.modifiers.alt && !event.modifiers.shift {
            return match event.key {
                DesktopKey::UpArrow => Some(AppCommandId::FocusPreviousPane),
                DesktopKey::DownArrow => Some(AppCommandId::FocusNextPane),
                _ => None,
            };
        }

        if event.modifiers.control && !event.modifiers.alt && event.modifiers.shift {
            return match event.key {
                DesktopKey::Character('c') | DesktopKey::Character('C') => {
                    Some(AppCommandId::CopyRaw)
                }
                DesktopKey::Character('d') | DesktopKey::Character('D') => {
                    Some(AppCommandId::SplitVertically)
                }
                DesktopKey::Character('f') | DesktopKey::Character('F') => Some(AppCommandId::Find),
                DesktopKey::Character('p') | DesktopKey::Character('P') => {
                    Some(AppCommandId::ShowCommandPalette)
                }
                _ => None,
            };
        }

        if event.modifiers.control && !event.modifiers.alt && !event.modifiers.shift {
            return match event.key {
                DesktopKey::Character('d') | DesktopKey::Character('D') => {
                    Some(AppCommandId::SplitHorizontally)
                }
                DesktopKey::Character('w') | DesktopKey::Character('W') => {
                    Some(AppCommandId::CloseFocusedPane)
                }
                DesktopKey::LeftArrow => Some(AppCommandId::FocusLeftPane),
                DesktopKey::RightArrow => Some(AppCommandId::FocusRightPane),
                DesktopKey::UpArrow => Some(AppCommandId::FocusUpInColumn),
                DesktopKey::DownArrow => Some(AppCommandId::FocusDownInColumn),
                _ => None,
            };
        }

        None
    }
}

fn is_default_windows_copy_shortcut(event: DesktopKeyEvent) -> bool {
    event.modifiers.control
        && event.modifiers.shift
        && !event.modifiers.alt
        && matches!(
            event.key,
            DesktopKey::Character('c') | DesktopKey::Character('C')
        )
}

fn shortcut_overrides_command(shortcuts: &ShortcutsConfig, command_id: AppCommandId) -> bool {
    shortcuts
        .bindings
        .iter()
        .any(|binding| binding.command_id == command_id.raw_value())
}

fn desktop_key_event_for_shortcut(shortcut: &str) -> Option<DesktopKeyEvent> {
    let mut control = false;
    let mut alt = false;
    let mut shift = false;
    let mut key = None;

    for component in shortcut.split('+') {
        let component = component
            .trim()
            .to_ascii_lowercase()
            .replace([' ', '_'], "");
        match component.as_str() {
            "" => return None,
            "command" | "cmd" | "meta" | "windows" | "win" | "control" | "ctrl" => control = true,
            "option" | "alt" => alt = true,
            "shift" => shift = true,
            value => {
                if key.is_some() {
                    return None;
                }
                key = desktop_key_for_shortcut(value);
            }
        }
    }

    Some(DesktopKeyEvent::new(
        key?,
        DesktopKeyModifiers {
            control,
            alt,
            shift,
        },
    ))
}

fn desktop_key_for_shortcut(key: &str) -> Option<DesktopKey> {
    match key {
        "left" | "leftarrow" | "arrowleft" => Some(DesktopKey::LeftArrow),
        "right" | "rightarrow" | "arrowright" => Some(DesktopKey::RightArrow),
        "up" | "uparrow" | "arrowup" => Some(DesktopKey::UpArrow),
        "down" | "downarrow" | "arrowdown" => Some(DesktopKey::DownArrow),
        "delete" | "del" => Some(DesktopKey::Delete),
        "tab" => Some(DesktopKey::Tab),
        "home" => Some(DesktopKey::Home),
        "end" => Some(DesktopKey::End),
        "pageup" | "pgup" => Some(DesktopKey::PageUp),
        "pagedown" | "pgdn" => Some(DesktopKey::PageDown),
        value => {
            let mut chars = value.chars();
            let key = chars.next()?;
            if chars.next().is_none() && !key.is_control() {
                Some(DesktopKey::Character(key.to_ascii_lowercase()))
            } else {
                None
            }
        }
    }
}

pub fn desktop_key_event_from_windows_virtual_key(
    virtual_key: u16,
    modifiers: DesktopKeyModifiers,
) -> Option<DesktopKeyEvent> {
    let key = match virtual_key {
        0x09 => DesktopKey::Tab,
        0x30..=0x39 => DesktopKey::Character((b'0' + (virtual_key as u8 - 0x30)) as char),
        0x41..=0x5a => DesktopKey::Character((b'a' + (virtual_key as u8 - 0x41)) as char),
        0x25 => DesktopKey::LeftArrow,
        0x26 => DesktopKey::UpArrow,
        0x27 => DesktopKey::RightArrow,
        0x28 => DesktopKey::DownArrow,
        0x2e => DesktopKey::Delete,
        0x24 => DesktopKey::Home,
        0x23 => DesktopKey::End,
        0x21 => DesktopKey::PageUp,
        0x22 => DesktopKey::PageDown,
        0x70..=0x7b => DesktopKey::Function(virtual_key as u8 - 0x6f), // VK_F1..VK_F12
        0xba => DesktopKey::Character(';'),
        0xbc => DesktopKey::Character(','),
        0xbe => DesktopKey::Character('.'),
        0xdb => DesktopKey::Character('['),
        0xdd => DesktopKey::Character(']'),
        _ => return None,
    };

    Some(DesktopKeyEvent::new(key, modifiers))
}

pub struct DesktopWindowSession {
    title: String,
    window_id: String,
    next_window_index: usize,
    worklane_id: String,
    worklane_order: Vec<String>,
    focused_pane_id_by_worklane_id: BTreeMap<String, String>,
    default_size: TerminalSize,
    focused_pane_id: Option<String>,
    focus_history: PaneFocusHistory,
    panes: Vec<DesktopPaneSession>,
    command_palette: Option<DesktopCommandPaletteState>,
    global_search: Option<DesktopGlobalSearchState>,
    pane_search: Option<DesktopPaneSearchState>,
    worklane_rename: Option<DesktopWorklaneRenameState>,
    sidebar: DesktopSidebarState,
    mouse_selection_pane_id: Option<String>,
    open_with_targets: Vec<OpenWithResolvedTarget>,
    available_open_with_targets: Vec<OpenWithResolvedTarget>,
    detected_servers: Vec<DetectedServer>,
    available_server_browser_targets: Vec<ServerBrowserOpenTarget>,
    task_runner_actions: Vec<TaskRunnerAction>,
    branch_urls_by_pane_id: BTreeMap<String, String>,
    worklane_colors_by_id: BTreeMap<String, String>,
    worklane_titles_by_id: BTreeMap<String, String>,
    pane_notifications: Vec<PaneNotification>,
    config_path: PathBuf,
    config: AppConfig,
    bookmarks_path: PathBuf,
    bookmarks: Option<DesktopBookmarksState>,
    task_manager: DesktopTaskManagerState<WindowsTaskManagerProcessProbe>,
    task_manager_snapshot: Option<DesktopTaskManagerTextSnapshot>,
    settings: Option<DesktopSettingsState>,
    theme_mode: AppearanceThemeMode,
    pane_layout: PaneLayoutConfig,
    shortcuts: ShortcutsConfig,
    server_detection_config: ServerDetectionConfig,
    server_ignored_port_rules: Vec<ServerPortRule>,
    closed_pane_specs: Vec<PaneLaunchSpec>,
    agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
    agent_ipc_aliases: Vec<DesktopAgentIpcAlias>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopCommandPaletteSnapshot {
    pub query: String,
    pub selected_index: Option<usize>,
    pub items: Vec<DesktopCommandPaletteItemSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopCommandPaletteItemSnapshot {
    pub title: String,
    pub subtitle: String,
    pub category: String,
    pub is_selected: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopPaneSearchSnapshot {
    pub pane_id: String,
    pub query: String,
    pub selected_index: Option<usize>,
    pub total: usize,
    pub current_match: Option<TerminalSearchMatch>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopGlobalSearchSnapshot {
    pub query: String,
    pub selected_index: Option<usize>,
    pub total: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DesktopSidebarSnapshot {
    pub width: f64,
    pub visibility: String,
    pub is_visible: bool,
    pub worklanes: Vec<DesktopSidebarWorklaneSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopSidebarWorklaneSnapshot {
    pub worklane_id: String,
    pub title: String,
    pub is_active: bool,
    pub pane_count: usize,
    pub focused_pane_id: Option<String>,
    pub color: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopSettingsSnapshot {
    pub section: String,
    pub title: String,
    pub selected_index: usize,
    pub lines: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopWorklaneRenameSnapshot {
    pub worklane_id: String,
    pub draft: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopBookmarksSnapshot {
    pub lines: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
struct DesktopBookmarksState {
    templates: Vec<WorkspaceTemplate>,
    query: String,
    selected_index: usize,
    rename: Option<DesktopBookmarkRenameState>,
    save: Option<DesktopBookmarkSaveState>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DesktopBookmarkRenameState {
    template_id: String,
    draft: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DesktopBookmarkSaveState {
    kind: WorkspaceTemplateKind,
    draft: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DesktopWorklaneRenameState {
    worklane_id: String,
    draft: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DesktopSettingsState {
    section: String,
    selected_index: usize,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct DesktopSidebarState {
    width: f64,
    visibility: SidebarVisibility,
}

impl DesktopSidebarState {
    const MINIMUM_WIDTH: f64 = 180.0;
    const MAXIMUM_WIDTH: f64 = 420.0;

    fn from_config(config: &AppConfig) -> Self {
        Self {
            width: config
                .sidebar
                .width
                .clamp(Self::MINIMUM_WIDTH, Self::MAXIMUM_WIDTH),
            visibility: config.sidebar.visibility,
        }
    }

    fn is_visible(self) -> bool {
        self.visibility.is_visible()
    }
}

impl DesktopBookmarksState {
    fn new(templates: Vec<WorkspaceTemplate>) -> Self {
        let mut state = Self {
            templates,
            query: String::new(),
            selected_index: 0,
            rename: None,
            save: None,
        };
        state.clamp_selection();
        state
    }

    fn model(&self) -> BookmarksPopoverModel {
        BookmarksPopoverModel::build(&self.templates, &self.query)
    }

    fn visible_templates(&self) -> Vec<WorkspaceTemplate> {
        let model = self.model();
        model.bookmarks.into_iter().chain(model.presets).collect()
    }

    fn selected_template(&self) -> Option<WorkspaceTemplate> {
        self.visible_templates().get(self.selected_index).cloned()
    }

    fn replace_templates(
        &mut self,
        templates: Vec<WorkspaceTemplate>,
        preferred_selected_id: Option<&str>,
    ) {
        self.templates = templates;
        if let Some(id) = preferred_selected_id
            && let Some(index) = self
                .visible_templates()
                .iter()
                .position(|template| template.id == id)
        {
            self.selected_index = index;
            return;
        }
        self.clamp_selection();
    }

    fn begin_rename_selected(&mut self) -> Option<String> {
        let template = self.selected_template()?;
        self.save = None;
        self.rename = Some(DesktopBookmarkRenameState {
            template_id: template.id.clone(),
            draft: template.name,
        });
        Some(template.id)
    }

    fn begin_save(&mut self, kind: WorkspaceTemplateKind, draft: String) {
        self.query.clear();
        self.rename = None;
        self.save = Some(DesktopBookmarkSaveState { kind, draft });
        self.clamp_selection();
    }

    fn cancel_rename(&mut self) {
        self.rename = None;
    }

    fn cancel_save(&mut self) {
        self.save = None;
    }

    fn take_rename_request(&mut self) -> Option<(String, String)> {
        self.rename
            .take()
            .map(|rename| (rename.template_id, rename.draft))
    }

    fn take_save_request(&mut self) -> Option<(WorkspaceTemplateKind, String)> {
        self.save.take().map(|save| (save.kind, save.draft))
    }

    fn push_rename_char(&mut self, ch: char) {
        if let Some(rename) = self.rename.as_mut() {
            rename.draft.push(ch);
        }
    }

    fn push_save_char(&mut self, ch: char) {
        if let Some(save) = self.save.as_mut() {
            save.draft.push(ch);
        }
    }

    fn pop_rename_char(&mut self) {
        if let Some(rename) = self.rename.as_mut() {
            rename.draft.pop();
        }
    }

    fn pop_save_char(&mut self) {
        if let Some(save) = self.save.as_mut() {
            save.draft.pop();
        }
    }

    fn rename_draft(&self) -> Option<&str> {
        self.rename.as_ref().map(|rename| rename.draft.as_str())
    }

    fn save_draft(&self) -> Option<(WorkspaceTemplateKind, &str)> {
        self.save
            .as_ref()
            .map(|save| (save.kind, save.draft.as_str()))
    }

    fn is_renaming(&self) -> bool {
        self.rename.is_some()
    }

    fn is_saving(&self) -> bool {
        self.save.is_some()
    }

    fn is_editing_name(&self) -> bool {
        self.is_renaming() || self.is_saving()
    }

    fn selectable_count(&self) -> usize {
        let model = self.model();
        model.bookmarks.len() + model.presets.len()
    }

    fn move_selection(&mut self, delta: isize) -> bool {
        let count = self.selectable_count();
        if count == 0 {
            return false;
        }
        let current = self.selected_index.min(count.saturating_sub(1));
        self.selected_index = (current as isize + delta).rem_euclid(count as isize) as usize;
        true
    }

    fn push_query_char(&mut self, ch: char) {
        self.query.push(ch);
        self.selected_index = 0;
        self.clamp_selection();
    }

    fn pop_query_char(&mut self) {
        self.query.pop();
        self.selected_index = 0;
        self.clamp_selection();
    }

    fn clamp_selection(&mut self) {
        let count = self.selectable_count();
        if count == 0 {
            self.selected_index = 0;
        } else {
            self.selected_index = self.selected_index.min(count - 1);
        }
    }
}

impl DesktopBookmarksSnapshot {
    fn from_state(state: &DesktopBookmarksState) -> Self {
        let model = state.model();
        let title = state
            .rename_draft()
            .map(|draft| format!("Rename Bookmark: {draft}"))
            .or_else(|| {
                state.save_draft().map(|(kind, draft)| match kind {
                    WorkspaceTemplateKind::Bookmark => format!("Save Bookmark: {draft}"),
                    WorkspaceTemplateKind::Preset => format!("Save Preset: {draft}"),
                })
            })
            .or_else(|| {
                trimmed_non_empty(&state.query).map(|query| format!("Bookmarks & Presets: {query}"))
            })
            .unwrap_or_else(|| "Bookmarks & Presets".to_string());
        let mut lines = vec![title];
        if !model.has_any_templates {
            lines.push("No bookmarks or presets".to_string());
            return Self { lines };
        }
        if model.is_empty_after_filtering() {
            lines.push("No matching bookmarks or presets".to_string());
            return Self { lines };
        }

        let mut template_index = 0;
        append_bookmark_section(
            &mut lines,
            "Bookmarks",
            &model.bookmarks,
            state.selected_index,
            &mut template_index,
        );
        append_bookmark_section(
            &mut lines,
            "Presets",
            &model.presets,
            state.selected_index,
            &mut template_index,
        );
        Self { lines }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DesktopPaneSnapshot {
    pub pane_id: String,
    pub worklane_id: String,
    pub column_id: String,
    pub column_index: usize,
    pub pane_index: usize,
    pub column_width: f64,
    pub pane_height: Option<f64>,
    pub title: String,
    pub is_focused: bool,
    pub visible_lines: Vec<String>,
    pub plain_text: String,
}

struct DesktopPaneSession {
    pane_id: String,
    worklane_id: String,
    column_id: String,
    title: String,
    column_index: usize,
    pane_index: usize,
    column_width: f64,
    pane_height: Option<f64>,
    terminal_request: TerminalSessionRequest,
    restored_rerunnable_command: Option<String>,
    shell_activity_state: TaskRunnerShellActivityState,
    root_pid: Option<i32>,
    terminal: DesktopTerminalState,
    selection: TerminalSelection,
    stream: NativePtyOutputStream,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DesktopAgentIpcAlias {
    legacy_window_id: Option<String>,
    legacy_worklane_id: String,
    legacy_pane_id: String,
    pane_token: String,
    current_worklane_id: String,
    current_pane_id: String,
}

impl DesktopAgentIpcAlias {
    fn legacy_runtime_environment(&self) -> AgentIpcRuntimeEnvironment {
        AgentIpcRuntimeEnvironment::new("", "", "").with_pane_token(
            self.legacy_window_id.as_deref(),
            &self.legacy_worklane_id,
            &self.legacy_pane_id,
            self.pane_token.clone(),
        )
    }

    fn retarget_payload(&self, payload: &mut AgentSignalPayload, window_id: &str) {
        payload.window_id = Some(window_id.to_string());
        payload.worklane_id = self.current_worklane_id.clone();
        payload.pane_id = self.current_pane_id.clone();
    }

    fn current_target(&self, window_id: &str) -> AgentIpcPaneTarget {
        AgentIpcPaneTarget {
            window_id: Some(window_id.to_string()),
            worklane_id: self.current_worklane_id.clone(),
            pane_id: self.current_pane_id.clone(),
        }
    }

    fn matches_pane_ipc_request(
        &self,
        selectors: &AgentIpcPaneSelectors,
        environment: &BTreeMap<String, String>,
    ) -> Result<bool, AgentIpcRequestRejection> {
        let target_window_id = selectors
            .window_id
            .as_deref()
            .or_else(|| environment.get("ZENTTY_WINDOW_ID").map(String::as_str))
            .and_then(trimmed_non_empty);
        let target_worklane_id = selectors
            .worklane_id
            .as_deref()
            .or_else(|| environment.get("ZENTTY_WORKLANE_ID").map(String::as_str))
            .and_then(trimmed_non_empty);
        let target_pane_id = selectors
            .pane_id
            .as_deref()
            .or_else(|| environment.get("ZENTTY_PANE_ID").map(String::as_str))
            .and_then(trimmed_non_empty);
        let target_pane_index = selectors.pane_index;
        if target_pane_index.is_some() {
            return Ok(false);
        }

        let Some(token) = selectors.pane_token(environment) else {
            return Err(AgentIpcRequestRejection::new(
                "invalid_pane_token",
                "Invalid pane token.",
            ));
        };

        Ok(target_window_id == self.legacy_window_id.as_deref()
            && target_worklane_id == Some(self.legacy_worklane_id.as_str())
            && target_pane_id == Some(self.legacy_pane_id.as_str())
            && token == self.pane_token)
    }
}

pub(crate) enum DesktopAgentIpcAppliedRequest {
    Empty,
    PaneList(Vec<PaneListEntry>),
    PaneNotification(PaneNotification),
    ServerState(ServerListResult),
    OpenServer {
        url: String,
        browser: Option<ServerBrowserOpenTarget>,
        server_state: ServerListResult,
    },
    Stdout(String),
    NewWindow(Box<DesktopWindowSession>),
}

impl DesktopAgentIpcAppliedRequest {
    fn response_if_expected(&self, request: &AgentIpcRequest) -> Option<AgentIpcResponse> {
        match self {
            Self::Empty => agent_ipc_success_response_if_expected(request),
            Self::PaneList(panes) => {
                agent_ipc_pane_list_success_response_if_expected(request, panes.clone())
            }
            Self::PaneNotification(_) => agent_ipc_success_response_if_expected(request),
            Self::ServerState(server_state) => {
                agent_ipc_server_state_success_response_if_expected(request, server_state.clone())
            }
            Self::OpenServer { server_state, .. } => {
                agent_ipc_server_state_success_response_if_expected(request, server_state.clone())
            }
            Self::Stdout(stdout) => {
                agent_ipc_stdout_success_response_if_expected(request, stdout.clone())
            }
            Self::NewWindow(_) => agent_ipc_success_response_if_expected(request),
        }
    }

    fn into_new_window_session(self) -> Option<DesktopWindowSession> {
        match self {
            Self::NewWindow(session) => Some(*session),
            _ => None,
        }
    }

    fn desktop_effect(&self) -> Option<DesktopCommandEffect> {
        match self {
            Self::PaneNotification(notification) => Some(DesktopCommandEffect::PaneNotification {
                notification: notification.clone(),
            }),
            Self::OpenServer { url, browser, .. } => Some(open_server_url_effect(url, browser)),
            _ => None,
        }
    }
}

fn agent_ipc_server_state_success_response_if_expected(
    request: &AgentIpcRequest,
    server_state: ServerListResult,
) -> Option<AgentIpcResponse> {
    request.expects_response.then(|| AgentIpcResponse {
        version: 1,
        id: request.id.clone(),
        ok: true,
        result: Some(AgentIpcResponseResult {
            server_state: Some(server_state),
            ..AgentIpcResponseResult::default()
        }),
        error: None,
    })
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct DesktopCommandPaletteState {
    query: String,
    selected_index: usize,
}

struct DesktopPaneSearchState {
    pane_id: String,
    session: TerminalSearchSession,
}

struct DesktopGlobalSearchState {
    coordinator: GlobalSearchCoordinator,
    pane_searches: BTreeMap<String, TerminalSearchSession>,
}

const DESKTOP_COMMAND_PALETTE_VISIBLE_ITEM_LIMIT: usize = 8;

impl DesktopWindowSession {
    pub fn spawn(launch: DesktopLaunchPlan) -> Result<Self, DesktopRunError> {
        Self::spawn_internal(launch, None)
    }

    pub fn spawn_with_agent_ipc(
        launch: DesktopLaunchPlan,
        agent_ipc_environment: AgentIpcRuntimeEnvironment,
    ) -> Result<Self, DesktopRunError> {
        Self::spawn_internal(launch, Some(agent_ipc_environment))
    }

    fn spawn_internal(
        launch: DesktopLaunchPlan,
        agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
    ) -> Result<Self, DesktopRunError> {
        let active = active_desktop_window(&launch.app).ok_or(DesktopRunError::NoFocusedPane)?;
        let mut panes = Vec::new();
        let window_id = active.window_id.clone();
        let bookmarks_path = bookmarks_path_for_config_path(&launch.shell.config_path);
        let sidebar = DesktopSidebarState::from_config(&launch.config);
        for pane in active.panes {
            let pane_environment = agent_ipc_environment
                .as_ref()
                .and_then(|environment| environment.pane_environment(Some(&window_id), pane));
            let stream = pane
                .spawn_pty_with_agent_ipc(
                    launch.shell.size,
                    Some(&window_id),
                    pane_environment.as_ref(),
                )?
                .into_output_stream()
                .map_err(DesktopRunError::from)?;
            panes.push(DesktopPaneSession {
                pane_id: pane.pane_id.clone(),
                worklane_id: pane.worklane_id.clone(),
                column_id: pane.column_id.clone(),
                title: pane.title.clone(),
                column_index: pane.column_index,
                pane_index: pane.pane_index,
                column_width: pane.column_width,
                pane_height: pane.pane_height,
                terminal_request: pane.terminal_request.clone(),
                restored_rerunnable_command: pane.restored_rerunnable_command.clone(),
                shell_activity_state: TaskRunnerShellActivityState::Unknown,
                root_pid: None,
                terminal: DesktopTerminalState::new(launch.shell.size),
                selection: TerminalSelection::new(),
                stream,
            });
        }
        if panes.is_empty() {
            return Err(DesktopRunError::NoFocusedPane);
        }
        let focused_pane_id = active
            .focused_pane_id_by_worklane_id
            .get(&active.active_worklane_id)
            .cloned()
            .or_else(|| {
                panes
                    .iter()
                    .find(|pane| pane.worklane_id == active.active_worklane_id)
                    .map(|pane| pane.pane_id.clone())
            });
        let next_window_index = next_desktop_window_index(&active.window_id);

        Ok(Self {
            title: launch.shell.window_title,
            window_id: active.window_id,
            next_window_index,
            worklane_id: active.active_worklane_id,
            worklane_order: active.worklane_order,
            focused_pane_id_by_worklane_id: active.focused_pane_id_by_worklane_id,
            default_size: launch.shell.size,
            focused_pane_id,
            focus_history: PaneFocusHistory::default(),
            panes,
            command_palette: None,
            global_search: None,
            pane_search: None,
            worklane_rename: None,
            sidebar,
            mouse_selection_pane_id: None,
            open_with_targets: active.open_with_targets.to_vec(),
            available_open_with_targets: resolve_available_open_with_targets(
                &launch.config.open_with,
            ),
            detected_servers: active.detected_servers.to_vec(),
            available_server_browser_targets: resolve_available_server_browser_targets(
                &launch.config.server_detection,
            ),
            task_runner_actions: active.task_runner_actions.to_vec(),
            branch_urls_by_pane_id: active.branch_urls_by_pane_id.clone(),
            worklane_colors_by_id: active.worklane_colors_by_id.clone(),
            worklane_titles_by_id: active.worklane_titles_by_id,
            pane_notifications: Vec::new(),
            config_path: launch.shell.config_path.clone(),
            config: launch.config.clone(),
            bookmarks_path,
            bookmarks: None,
            task_manager: DesktopTaskManagerState::new(WindowsTaskManagerProcessProbe::new()),
            task_manager_snapshot: None,
            settings: None,
            theme_mode: launch.config.appearance.theme_mode,
            pane_layout: launch.config.pane_layout.clone(),
            shortcuts: launch.config.shortcuts.clone(),
            server_detection_config: launch.config.server_detection.clone(),
            server_ignored_port_rules: ServerPortRule::normalize(
                &launch.config.server_detection.ignored_port_rules,
            ),
            closed_pane_specs: Vec::new(),
            agent_ipc_environment,
            agent_ipc_aliases: Vec::new(),
        })
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn pane_ids(&self) -> Vec<&str> {
        let mut ids = Vec::new();
        for worklane_id in &self.worklane_order {
            ids.extend(
                self.panes
                    .iter()
                    .filter(|pane| &pane.worklane_id == worklane_id)
                    .map(|pane| pane.pane_id.as_str()),
            );
        }
        ids.extend(
            self.panes
                .iter()
                .filter(|pane| {
                    !self
                        .worklane_order
                        .iter()
                        .any(|worklane_id| worklane_id == &pane.worklane_id)
                })
                .map(|pane| pane.pane_id.as_str()),
        );
        ids
    }

    pub fn focused_pane_id(&self) -> Option<&str> {
        self.focused_pane_id.as_deref()
    }

    pub fn active_worklane_color(&self) -> Option<&str> {
        self.worklane_colors_by_id
            .get(&self.worklane_id)
            .map(String::as_str)
    }

    pub fn active_worklane_title(&self) -> Option<&str> {
        self.worklane_titles_by_id
            .get(&self.worklane_id)
            .map(String::as_str)
    }

    pub fn worklane_title(&self, worklane_id: &str) -> Option<&str> {
        self.worklane_titles_by_id
            .get(worklane_id)
            .map(String::as_str)
    }

    fn default_worklane_title(&self, worklane_id: &str) -> String {
        self.worklane_order
            .iter()
            .position(|candidate| candidate == worklane_id)
            .map(|index| format!("Worklane {}", index + 1))
            .unwrap_or_else(|| worklane_id.to_string())
    }

    pub fn suggested_active_worklane_template_name(
        &self,
        kind: WorkspaceTemplateKind,
    ) -> Option<String> {
        let panes = self.active_worklane_panes();
        if panes.is_empty() {
            return None;
        }
        let working_directories = panes
            .iter()
            .filter_map(|pane| pane.terminal_request.working_directory.clone())
            .collect::<Vec<_>>();
        let focused_command = self
            .focused_pane()
            .and_then(|pane| pane.terminal_request.command.as_deref())
            .and_then(desktop_command_first_token);
        Some(BookmarkNameSuggester::suggest(
            kind,
            self.active_worklane_title(),
            &working_directories,
            focused_command.as_deref(),
            panes.len(),
        ))
    }

    pub fn capture_active_worklane_template(
        &self,
        kind: WorkspaceTemplateKind,
        name: impl Into<String>,
    ) -> Option<WorkspaceTemplate> {
        self.active_worklane_capture_input(kind, name.into())
            .map(WorkspaceTemplateCapture::capture)
    }

    pub fn save_active_worklane_template(
        &self,
        kind: WorkspaceTemplateKind,
        name: impl Into<String>,
    ) -> io::Result<Option<WorkspaceTemplate>> {
        let Some(template) = self.capture_active_worklane_template(kind, name) else {
            return Ok(None);
        };
        let mut store = BookmarkStore::load(self.bookmarks_path.clone())?;
        store.upsert(template.clone())?;
        Ok(Some(template))
    }

    pub fn export_bookmark_template_to_path(
        &self,
        template_id: &str,
        path: impl AsRef<Path>,
    ) -> io::Result<bool> {
        let store = BookmarkStore::load(self.bookmarks_path.clone())?;
        let Some(template) = store.template(template_id) else {
            return Ok(false);
        };
        WorkspaceTemplateExporter::write(template, path.as_ref())?;
        Ok(true)
    }

    pub fn import_bookmark_template_from_path(
        &self,
        path: impl AsRef<Path>,
    ) -> io::Result<WorkspaceTemplate> {
        let template = WorkspaceTemplateExporter::read(path.as_ref())?;
        let mut store = BookmarkStore::load(self.bookmarks_path.clone())?;
        store.upsert(template.clone())?;
        Ok(template)
    }

    pub fn pane_notifications(&self) -> &[PaneNotification] {
        &self.pane_notifications
    }

    pub fn inbox_pane_notifications(&self) -> Vec<&PaneNotification> {
        self.pane_notifications
            .iter()
            .filter(|notification| notification.include_inbox)
            .collect()
    }

    pub fn theme_mode(&self) -> AppearanceThemeMode {
        self.theme_mode
    }

    fn reload_configuration_from_disk(&mut self) -> DesktopCommandEffect {
        let store = match AppConfigStore::load(self.config_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Failed to reload configuration: {error}"),
                };
            }
        };

        if !store.did_load_from_valid_file() {
            return DesktopCommandEffect::Status {
                message: format!(
                    "Ignoring invalid configuration at {}",
                    self.config_path.display()
                ),
            };
        }

        let config = store.current();
        self.apply_reloaded_config(config);
        DesktopCommandEffect::Status {
            message: "Configuration reloaded".to_string(),
        }
    }

    fn apply_reloaded_config(&mut self, config: &AppConfig) {
        self.config = config.clone();
        self.open_with_targets = resolve_open_with_targets(&config.open_with);
        self.available_open_with_targets = resolve_available_open_with_targets(&config.open_with);
        self.sidebar = DesktopSidebarState::from_config(config);
        self.theme_mode = config.appearance.theme_mode;
        self.pane_layout = config.pane_layout.clone();
        self.shortcuts = config.shortcuts.clone();
        self.server_detection_config = config.server_detection.clone();
        self.available_server_browser_targets =
            resolve_available_server_browser_targets(&config.server_detection);
        self.server_ignored_port_rules =
            ServerPortRule::normalize(&config.server_detection.ignored_port_rules);
    }

    fn persist_live_config_update<F>(&mut self, updater: F) -> Result<(), String>
    where
        F: FnOnce(&mut AppConfig),
    {
        let mut updated = self.config.clone();
        updater(&mut updated);
        updated = updated.normalized();

        let mut store = AppConfigStore::load(self.config_path.clone())
            .map_err(|error| format!("Failed to save configuration: {error}"))?;
        let persisted = updated.clone();
        store
            .update(|config| *config = persisted)
            .map_err(|error| format!("Failed to save configuration: {error}"))?;

        self.apply_reloaded_config(&updated);
        self.clamp_settings_selection();
        Ok(())
    }

    fn persist_live_config_effect<F>(&mut self, updater: F) -> DesktopCommandEffect
    where
        F: FnOnce(&mut AppConfig),
    {
        match self.persist_live_config_update(updater) {
            Ok(()) => DesktopCommandEffect::Repaint,
            Err(message) => DesktopCommandEffect::Status { message },
        }
    }

    fn set_theme_mode_from_command(&mut self, mode: &str) -> DesktopCommandEffect {
        let command = if mode == "toggleLightDark" {
            Some(PaneIpcThemeCommand::Toggle)
        } else {
            PaneIpcThemeCommand::parse(mode)
        };
        let Some(command) = command else {
            return DesktopCommandEffect::Status {
                message: format!("Unsupported theme mode: {mode}"),
            };
        };
        let theme_mode = command.resolve(self.theme_mode);
        self.persist_live_config_effect(|config| {
            config.appearance.theme_mode = theme_mode;
        })
    }

    fn toggle_sidebar(&mut self) -> DesktopCommandEffect {
        let visibility = self.sidebar.visibility.toggle();
        let width = self.sidebar.width;
        self.persist_live_config_effect(|config| {
            config.sidebar.visibility = visibility;
            config.sidebar.width = width;
        })
    }

    fn remember_open_with_primary_target(&mut self, target_id: &str) {
        if self.config.open_with.primary_target_id == target_id
            || !self
                .open_with_targets
                .iter()
                .any(|target| target.stable_id == target_id)
        {
            return;
        }
        let target_id = target_id.to_string();
        let _ = self.persist_live_config_update(|config| {
            config.open_with.primary_target_id = target_id;
        });
    }

    fn jump_to_latest_pane_notification(&mut self) -> AppCommandExecutionResult {
        let target = self
            .pane_notifications
            .iter()
            .filter(|notification| {
                notification.include_inbox && notification.window_id == self.window_id
            })
            .find_map(|notification| {
                self.panes
                    .iter()
                    .any(|pane| {
                        pane.worklane_id == notification.worklane_id
                            && pane.pane_id == notification.pane_id
                    })
                    .then(|| {
                        PaneReference::new(
                            notification.worklane_id.clone(),
                            PaneId::from(notification.pane_id.clone()),
                        )
                    })
            });
        target
            .map(|reference| self.focus_pane_reference(reference, true))
            .unwrap_or(AppCommandExecutionResult::JumpToLatestNotification)
    }

    pub fn agent_ipc_socket_path(&self) -> Option<&str> {
        self.agent_ipc_environment
            .as_ref()
            .map(AgentIpcRuntimeEnvironment::socket_path)
    }

    pub fn spawn_new_window_session(
        &mut self,
        working_directory: Option<String>,
    ) -> Result<Self, DesktopRunError> {
        let window_id = self.next_window_id();
        let worklane_id = next_desktop_worklane_id(&self.worklane_order);
        let pane_id = next_desktop_pane_id(&self.panes);
        let terminal_request = TerminalSessionRequest {
            working_directory,
            ..Default::default()
        };
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: worklane_id.clone(),
            column_id: format!("column-{pane_id}"),
            column_index: 0,
            pane_index: 0,
            title: "pane 1".to_string(),
            column_width: DESKTOP_DEFAULT_COLUMN_WIDTH,
            pane_height: Some(1.0),
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let agent_ipc_environment = if self.agent_ipc_environment.is_some() {
            Some(desktop_agent_ipc_environment_for_panes(
                &window_id,
                [(worklane_id.as_str(), pane_id.as_str())],
            )?)
        } else {
            None
        };
        let pane_environment = agent_ipc_environment
            .as_ref()
            .and_then(|environment| environment.pane_environment(Some(&window_id), &spec));
        let pane = DesktopPaneSession::spawn_with_agent_ipc(
            &spec,
            self.default_size,
            Some(&window_id),
            pane_environment.as_ref(),
        )?;
        Ok(self.single_pane_window_session(
            window_id,
            worklane_id,
            pane_id,
            pane,
            agent_ipc_environment,
            Vec::new(),
            Vec::new(),
            None,
        ))
    }

    pub fn detach_focused_pane_to_new_window_session(&mut self) -> Option<Self> {
        if self.panes.len() <= 1 {
            return None;
        }
        let source_index = self.focused_index()?;
        let removed_spec = self.panes[source_index].clone_spec();
        let source_worklane_id = removed_spec.worklane_id.clone();
        let source_worklane_pane_count = self
            .panes
            .iter()
            .filter(|pane| pane.worklane_id == source_worklane_id)
            .count();
        let destination_window_id = self.next_window_id();
        let destination_worklane_id = if source_worklane_pane_count == 1 {
            source_worklane_id.clone()
        } else {
            next_desktop_worklane_id(&self.worklane_order)
        };
        let destination_worklane_title = if source_worklane_pane_count == 1 {
            self.worklane_titles_by_id.get(&source_worklane_id).cloned()
        } else {
            None
        };
        let agent_ipc_aliases = self
            .agent_ipc_environment
            .as_ref()
            .and_then(|environment| {
                environment.pane_environment(Some(&self.window_id), &removed_spec)
            })
            .map(|environment| {
                vec![DesktopAgentIpcAlias {
                    legacy_window_id: environment.window_id,
                    legacy_worklane_id: environment.worklane_id,
                    legacy_pane_id: environment.pane_id,
                    pane_token: environment.pane_token,
                    current_worklane_id: destination_worklane_id.clone(),
                    current_pane_id: removed_spec.pane_id.clone(),
                }]
            })
            .unwrap_or_default();

        let mut moved_pane = self.panes.remove(source_index);
        if source_worklane_pane_count == 1 {
            self.remove_empty_worklane(&source_worklane_id);
        } else {
            retarget_desktop_pane_for_split_out(&mut moved_pane, &destination_worklane_id);
            normalize_pane_positions(
                &mut self.panes,
                &removed_spec.worklane_id,
                removed_spec.column_index,
                removed_spec.pane_index,
            );
            if !self.panes.is_empty() {
                let next_index = source_index
                    .saturating_sub(1)
                    .min(self.panes.len().saturating_sub(1));
                let _ = self.focus_index(next_index);
            }
        }

        let pane_id = moved_pane.pane_id.clone();
        Some(self.single_pane_window_session(
            destination_window_id,
            destination_worklane_id,
            pane_id,
            moved_pane,
            None,
            agent_ipc_aliases,
            self.task_runner_actions.clone(),
            destination_worklane_title,
        ))
    }

    pub fn run_task_runner_with_shell_state(
        &mut self,
        id: &str,
        shell_activity_state: TaskRunnerShellActivityState,
        terminal_progress_indicates_activity: bool,
    ) -> CommandPaletteItemExecutionResult {
        let Some(action) = self
            .task_runner_actions
            .iter()
            .find(|action| action.id == id)
            .cloned()
        else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let focused_pane = self.focused_task_runner_pane_state(
            shell_activity_state,
            terminal_progress_indicates_activity,
        );
        self.run_task_runner_action(&action, focused_pane.as_ref())
    }

    pub fn record_pane_shell_activity_state(
        &mut self,
        pane_id: &str,
        shell_activity_state: TaskRunnerShellActivityState,
    ) -> bool {
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return false;
        };
        pane.shell_activity_state = shell_activity_state;
        true
    }

    pub fn apply_agent_signal(&mut self, payload: &AgentSignalPayload) -> bool {
        if payload
            .window_id
            .as_deref()
            .is_some_and(|window_id| self.window_id != window_id)
        {
            return false;
        }
        let Some(pane) = self.panes.iter_mut().find(|pane| {
            pane.worklane_id == payload.worklane_id && pane.pane_id == payload.pane_id
        }) else {
            return false;
        };
        match payload.signal_kind {
            AgentSignalKind::ShellState => {
                let Some(shell_activity_state) = payload.shell_activity_state else {
                    return false;
                };
                pane.shell_activity_state = shell_activity_state;
                true
            }
            AgentSignalKind::PaneRootPid => {
                let Some(pid_event) = payload.pid_event else {
                    return false;
                };
                match pid_event {
                    AgentPidSignalEvent::Attach => {
                        let Some(pid) = payload.pid.filter(|pid| *pid > 0) else {
                            return false;
                        };
                        pane.root_pid = Some(pid);
                    }
                    AgentPidSignalEvent::Clear => {
                        pane.root_pid = None;
                    }
                }
                true
            }
            _ => false,
        }
    }

    pub fn handle_agent_ipc_request(
        &mut self,
        request: AgentIpcRequest,
    ) -> Option<AgentIpcResponse> {
        self.handle_agent_ipc_request_with_new_window_session(request)
            .0
    }

    pub fn handle_agent_ipc_request_with_new_window_session(
        &mut self,
        request: AgentIpcRequest,
    ) -> (Option<AgentIpcResponse>, Option<Self>) {
        match self.apply_agent_ipc_request(&request) {
            Ok(result) => {
                let response = result.response_if_expected(&request);
                (response, result.into_new_window_session())
            }
            Err(error) => {
                let response =
                    agent_ipc_error_response_if_expected(&request, error.code, &error.message);
                (response, None)
            }
        }
    }

    pub fn handle_agent_ipc_request_with_effect(
        &mut self,
        request: AgentIpcRequest,
    ) -> (Option<AgentIpcResponse>, Option<DesktopCommandEffect>) {
        match self.apply_agent_ipc_request(&request) {
            Ok(result) => {
                let response = result.response_if_expected(&request);
                let effect = result.desktop_effect();
                (response, effect)
            }
            Err(error) => {
                let response =
                    agent_ipc_error_response_if_expected(&request, error.code, &error.message);
                (response, None)
            }
        }
    }

    pub fn handle_agent_ipc_request_for_sessions(
        sessions: &mut [&mut DesktopWindowSession],
        request: AgentIpcRequest,
    ) -> Option<AgentIpcResponse> {
        let mut deferred_error = None;
        for session in sessions {
            match session.apply_agent_ipc_request(&request) {
                Ok(result) => return result.response_if_expected(&request),
                Err(error) if agent_ipc_error_is_routable(&error) => {
                    if deferred_error.is_none() {
                        deferred_error = Some(error);
                    }
                }
                Err(error) => {
                    return agent_ipc_error_response_if_expected(
                        &request,
                        error.code,
                        &error.message,
                    );
                }
            }
        }

        let error = deferred_error.unwrap_or_else(agent_ipc_pane_not_found_rejection);
        agent_ipc_error_response_if_expected(&request, error.code, &error.message)
    }

    pub(crate) fn apply_agent_ipc_request(
        &mut self,
        request: &AgentIpcRequest,
    ) -> Result<DesktopAgentIpcAppliedRequest, AgentIpcRequestRejection> {
        if request.version != 1 {
            return Err(AgentIpcRequestRejection::new(
                "invalid_message",
                "Invalid IPC protocol version.",
            ));
        }

        if request.kind == AgentIpcRequestKind::Pane {
            return self.apply_pane_ipc_request(request);
        }
        if request.kind == AgentIpcRequestKind::Server {
            return self.apply_server_ipc_request(request);
        }

        let payload = match agent_signal_payload_for_authenticated_ipc_request(
            request,
            self.agent_ipc_environment.as_ref(),
        ) {
            Ok(payload) => payload,
            Err(error) => match self.agent_signal_payload_for_legacy_ipc_alias(request) {
                Ok(Some(payload)) => payload,
                Ok(None) => return Err(error),
                Err(alias_error) => return Err(alias_error),
            },
        };

        if !self.apply_agent_signal(&payload) {
            return Err(agent_ipc_pane_not_found_rejection());
        }

        Ok(DesktopAgentIpcAppliedRequest::Empty)
    }

    fn apply_pane_ipc_request(
        &mut self,
        request: &AgentIpcRequest,
    ) -> Result<DesktopAgentIpcAppliedRequest, AgentIpcRequestRejection> {
        let Some(subcommand) = request.subcommand.as_deref() else {
            return Err(AgentIpcRequestRejection::new(
                "unsupported_subcommand",
                "Unsupported pane IPC subcommand: <nil>",
            ));
        };

        let target = self.authenticated_pane_ipc_target(request)?;
        match subcommand {
            "split" => {
                self.apply_pane_split_ipc_command(&target, &request.arguments);
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "list" => Ok(DesktopAgentIpcAppliedRequest::PaneList(
                self.pane_list_entries_for_worklane(&target.worklane_id),
            )),
            "focus" => {
                self.apply_pane_focus_ipc_command(&target, &request.arguments);
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "close" => {
                self.apply_pane_close_ipc_command(&target, &request.arguments);
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "resize" => {
                self.apply_pane_resize_ipc_command(&target, &request.arguments);
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "layout" => {
                self.apply_pane_layout_ipc_command(&target, &request.arguments);
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "grid" => self.apply_pane_grid_ipc_command(&target, &request.arguments),
            "notify" => {
                let notification =
                    self.apply_pane_notify_ipc_command(&target, &request.arguments)?;
                Ok(DesktopAgentIpcAppliedRequest::PaneNotification(
                    notification,
                ))
            }
            "worklane-color" => {
                self.apply_pane_worklane_color_ipc_command(&target, &request.arguments)?;
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "worklane-rename" => {
                self.apply_pane_worklane_rename_ipc_command(&target, &request.arguments)?;
                Ok(DesktopAgentIpcAppliedRequest::Empty)
            }
            "theme" => {
                let mode = self.apply_pane_theme_ipc_command(&request.arguments)?;
                Ok(DesktopAgentIpcAppliedRequest::Stdout(format!(
                    "{}\n",
                    pane_ipc_theme_mode_token(mode)
                )))
            }
            _ => Err(AgentIpcRequestRejection::new(
                "unsupported_subcommand",
                format!("Unsupported pane IPC subcommand: {subcommand}"),
            )),
        }
    }

    fn apply_server_ipc_request(
        &mut self,
        request: &AgentIpcRequest,
    ) -> Result<DesktopAgentIpcAppliedRequest, AgentIpcRequestRejection> {
        let Some(subcommand) = request.subcommand.as_deref() else {
            return Err(AgentIpcRequestRejection::new(
                "unsupported_subcommand",
                "Unsupported server IPC subcommand: <nil>",
            ));
        };

        let target = self.authenticated_pane_ipc_target(request)?;
        let arguments = parse_agent_ipc_pane_selectors(&request.arguments)?.arguments;
        match subcommand {
            "server-set" => {
                let command = parse_server_set_arguments(&arguments)?;
                self.apply_server_set_ipc_command(&target, command, DetectedServerSource::Manual)?;
                Ok(DesktopAgentIpcAppliedRequest::ServerState(
                    self.server_list_result_for_worklane(&target.worklane_id),
                ))
            }
            "server-watch-set" => {
                let command = parse_server_set_arguments(&arguments)?;
                self.apply_server_set_ipc_command(&target, command, DetectedServerSource::Watch)?;
                Ok(DesktopAgentIpcAppliedRequest::ServerState(
                    self.server_list_result_for_worklane(&target.worklane_id),
                ))
            }
            "server-clear" => {
                parse_server_no_argument_command(&arguments)?;
                self.clear_server_ipc_records(&target, None);
                Ok(DesktopAgentIpcAppliedRequest::ServerState(
                    self.server_list_result_for_worklane(&target.worklane_id),
                ))
            }
            "server-watch-clear" => {
                parse_server_no_argument_command(&arguments)?;
                self.clear_server_ipc_records(&target, Some("watch"));
                Ok(DesktopAgentIpcAppliedRequest::ServerState(
                    self.server_list_result_for_worklane(&target.worklane_id),
                ))
            }
            "server-list" => {
                parse_server_no_argument_command(&arguments)?;
                Ok(DesktopAgentIpcAppliedRequest::ServerState(
                    self.server_list_result_for_worklane(&target.worklane_id),
                ))
            }
            "server-open" => {
                let command = parse_server_open_arguments(&arguments)?;
                let server =
                    self.server_for_open(&target.worklane_id, command.raw_url.as_deref())?;
                let server_state = self.server_list_result_for_worklane(&target.worklane_id);
                if let Some(server) = server {
                    let browser =
                        self.server_browser_target_for_open(command.browser_id.as_deref());
                    Ok(DesktopAgentIpcAppliedRequest::OpenServer {
                        url: server.url,
                        browser,
                        server_state,
                    })
                } else {
                    Ok(DesktopAgentIpcAppliedRequest::ServerState(server_state))
                }
            }
            _ => Err(AgentIpcRequestRejection::new(
                "unsupported_subcommand",
                format!("Unsupported server IPC subcommand: {subcommand}"),
            )),
        }
    }

    fn server_for_open(
        &self,
        worklane_id: &str,
        raw_url: Option<&str>,
    ) -> Result<Option<DetectedServer>, AgentIpcRequestRejection> {
        let origin = raw_url.map(server_origin_from_raw_url).transpose()?;
        let ranked = self.ranked_servers_for_worklane(worklane_id);
        let server = match origin.as_deref() {
            Some(origin) => ranked.into_iter().find(|entry| {
                entry.server.origin == origin && entry.tier != ServerRelevanceTier::Hidden
            }),
            None => ranked
                .into_iter()
                .find(|entry| entry.tier == ServerRelevanceTier::Primary),
        };
        Ok(server.map(|entry| entry.server))
    }

    fn server_browser_target_for_open(
        &self,
        requested_browser_id: Option<&str>,
    ) -> Option<ServerBrowserOpenTarget> {
        server_browser_target_for_open(&self.server_detection_config, requested_browser_id)
    }

    fn apply_server_set_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        command: ServerSetIpcCommand,
        source: DetectedServerSource,
    ) -> Result<(), AgentIpcRequestRejection> {
        let candidate = ServerUrlNormalizer::normalize(&command.raw_url)
            .map_err(server_url_normalize_rejection)?;
        let confidence = if command.pid.is_some() {
            DetectedServerConfidence::Pid
        } else {
            DetectedServerConfidence::Explicit
        };
        let id = server_record_id(
            &target.worklane_id,
            &target.pane_id,
            source.raw_value(),
            &candidate.origin,
        );
        let server = DetectedServer::new(id, candidate.origin, candidate.url, candidate.display)
            .with_metadata(
                &target.worklane_id,
                Some(target.pane_id.clone()),
                source,
                confidence,
                OffsetDateTime::now_utc(),
            );
        upsert_server(&mut self.detected_servers, server);
        Ok(())
    }

    fn clear_server_ipc_records(&mut self, target: &AgentIpcPaneTarget, source: Option<&str>) {
        let mut registry = ServerRegistry::from_records(std::mem::take(&mut self.detected_servers));
        if let Some(source) = source.and_then(|source| source.parse::<DetectedServerSource>().ok())
        {
            registry.clear_source(source, &target.worklane_id, Some(&target.pane_id));
        } else {
            registry.clear_worklane_pane(&target.worklane_id, &target.pane_id);
        }
        self.detected_servers = registry.into_records();
    }

    fn server_list_result_for_worklane(&self, worklane_id: &str) -> ServerListResult {
        let ranked = self.ranked_servers_for_worklane(worklane_id);
        let servers = ranked
            .iter()
            .map(|entry| server_list_entry(entry, worklane_id))
            .collect::<Vec<_>>();
        let primary_server_id = ranked
            .iter()
            .find(|entry| entry.tier == ServerRelevanceTier::Primary)
            .map(|entry| entry.server.id.clone());
        ServerListResult {
            version: 2,
            primary_server_id,
            servers,
        }
    }

    fn ranked_servers_for_worklane(&self, worklane_id: &str) -> Vec<RankedServer> {
        let registry = ServerRegistry::from_records(self.detected_servers.clone());
        let servers = registry.servers_in(worklane_id);
        ServerRelevance::rank(&servers, &self.server_relevance_context(worklane_id))
    }

    fn server_relevance_context(&self, worklane_id: &str) -> ServerRelevanceContext {
        let focused_pane_id = self.focused_pane_id.as_ref().and_then(|pane_id| {
            self.panes
                .iter()
                .any(|pane| pane.pane_id == *pane_id && pane.worklane_id == worklane_id)
                .then(|| pane_id.clone())
        });
        let running_pane_ids = self
            .panes
            .iter()
            .filter(|pane| {
                pane.worklane_id == worklane_id
                    && pane.shell_activity_state == TaskRunnerShellActivityState::CommandRunning
            })
            .map(|pane| pane.pane_id.clone())
            .collect::<HashSet<_>>();
        ServerRelevanceContext {
            focused_pane_id,
            running_pane_ids,
            ignored_port_rules: self.server_ignored_port_rules.clone(),
            session_selected_origin: None,
            now: OffsetDateTime::now_utc(),
        }
    }

    fn authenticated_pane_ipc_target(
        &self,
        request: &AgentIpcRequest,
    ) -> Result<AgentIpcPaneTarget, AgentIpcRequestRejection> {
        let selectors = parse_agent_ipc_pane_selectors(&request.arguments)?;
        let normal_result = self.authenticated_normal_pane_ipc_target(request, &selectors);
        match normal_result {
            Ok(target) => Ok(target),
            Err(error) => match self.authenticated_legacy_pane_ipc_target(request, &selectors) {
                Ok(Some(target)) => Ok(target),
                Ok(None) => Err(error),
                Err(alias_error) => Err(alias_error),
            },
        }
    }

    fn authenticated_normal_pane_ipc_target(
        &self,
        request: &AgentIpcRequest,
        selectors: &AgentIpcPaneSelectors,
    ) -> Result<AgentIpcPaneTarget, AgentIpcRequestRejection> {
        let target = self.resolve_pane_ipc_target(selectors, &request.environment)?;
        let token = selectors.pane_token(&request.environment).ok_or_else(|| {
            AgentIpcRequestRejection::new("invalid_pane_token", "Invalid pane token.")
        })?;
        let token_is_valid = self
            .agent_ipc_environment
            .as_ref()
            .is_some_and(|environment| {
                environment.is_valid_pane_token(
                    target.window_id.as_deref(),
                    &target.worklane_id,
                    &target.pane_id,
                    token,
                )
            });
        if !token_is_valid {
            return Err(AgentIpcRequestRejection::new(
                "invalid_pane_token",
                "Invalid pane token.",
            ));
        }
        Ok(target)
    }

    fn authenticated_legacy_pane_ipc_target(
        &self,
        request: &AgentIpcRequest,
        selectors: &AgentIpcPaneSelectors,
    ) -> Result<Option<AgentIpcPaneTarget>, AgentIpcRequestRejection> {
        for alias in &self.agent_ipc_aliases {
            if alias.matches_pane_ipc_request(selectors, &request.environment)? {
                return Ok(Some(alias.current_target(&self.window_id)));
            }
        }
        Ok(None)
    }

    fn resolve_pane_ipc_target(
        &self,
        selectors: &AgentIpcPaneSelectors,
        environment: &BTreeMap<String, String>,
    ) -> Result<AgentIpcPaneTarget, AgentIpcRequestRejection> {
        let env_window_id = environment
            .get("ZENTTY_WINDOW_ID")
            .and_then(|value| trimmed_non_empty(value))
            .map(str::to_string);
        let env_worklane_id = environment
            .get("ZENTTY_WORKLANE_ID")
            .and_then(|value| trimmed_non_empty(value))
            .map(str::to_string);
        let env_pane_id = environment
            .get("ZENTTY_PANE_ID")
            .and_then(|value| trimmed_non_empty(value))
            .map(str::to_string);

        if let Some(pane_id) = selectors.pane_id.as_deref() {
            let window_id = selectors.window_id.as_deref().or(env_window_id.as_deref());
            let matches = self.pane_ipc_candidates(
                window_id,
                selectors.worklane_id.as_deref(),
                Some(pane_id),
            );
            return resolve_single_pane_ipc_candidate(matches);
        }

        if let Some(pane_index) = selectors.pane_index {
            let worklane_id = selectors
                .worklane_id
                .as_deref()
                .or(env_worklane_id.as_deref())
                .ok_or_else(agent_ipc_missing_target_context_rejection)?;
            let window_id = selectors.window_id.as_deref().or(env_window_id.as_deref());
            let pane = self
                .panes
                .iter()
                .filter(|pane| {
                    pane.worklane_id == worklane_id && self.agent_ipc_window_matches(window_id)
                })
                .nth(pane_index - 1)
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: Some(self.window_id.clone()),
                worklane_id: pane.worklane_id.clone(),
                pane_id: pane.pane_id.clone(),
            });
        }

        if let Some(worklane_id) = selectors.worklane_id.as_deref() {
            let window_id = selectors.window_id.as_deref().or(env_window_id.as_deref());
            if !self.agent_ipc_window_matches(window_id) {
                return Err(agent_ipc_pane_not_found_rejection());
            }
            let pane_id = self
                .focused_pane_id_by_worklane_id
                .get(worklane_id)
                .filter(|pane_id| {
                    self.panes
                        .iter()
                        .any(|pane| pane.worklane_id == worklane_id && pane.pane_id == **pane_id)
                })
                .cloned()
                .or_else(|| {
                    self.panes
                        .iter()
                        .find(|pane| pane.worklane_id == worklane_id)
                        .map(|pane| pane.pane_id.clone())
                })
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: Some(self.window_id.clone()),
                worklane_id: worklane_id.to_string(),
                pane_id,
            });
        }

        if let Some(window_id) = selectors.window_id.as_deref() {
            if !self.agent_ipc_window_matches(Some(window_id)) {
                return Err(agent_ipc_pane_not_found_rejection());
            }
            let pane_id = self
                .focused_pane_id
                .clone()
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: Some(self.window_id.clone()),
                worklane_id: self.worklane_id.clone(),
                pane_id,
            });
        }

        if let (Some(worklane_id), Some(pane_id)) = (env_worklane_id, env_pane_id) {
            let matches = self.pane_ipc_candidates(
                env_window_id.as_deref(),
                Some(&worklane_id),
                Some(&pane_id),
            );
            if matches.is_empty() {
                let retargeted_matches =
                    self.pane_ipc_candidates(env_window_id.as_deref(), None, Some(&pane_id));
                if !retargeted_matches.is_empty() {
                    return resolve_single_pane_ipc_candidate(retargeted_matches);
                }
            }
            return resolve_single_pane_ipc_candidate(matches);
        }

        Err(agent_ipc_missing_target_context_rejection())
    }

    fn pane_ipc_candidates(
        &self,
        window_id: Option<&str>,
        worklane_id: Option<&str>,
        pane_id: Option<&str>,
    ) -> Vec<AgentIpcPaneTarget> {
        if !self.agent_ipc_window_matches(window_id) {
            return Vec::new();
        }
        self.panes
            .iter()
            .filter(|pane| worklane_id.is_none_or(|id| pane.worklane_id == id))
            .filter(|pane| pane_id.is_none_or(|id| pane.pane_id == id))
            .map(|pane| AgentIpcPaneTarget {
                window_id: Some(self.window_id.clone()),
                worklane_id: pane.worklane_id.clone(),
                pane_id: pane.pane_id.clone(),
            })
            .collect()
    }

    fn agent_ipc_window_matches(&self, window_id: Option<&str>) -> bool {
        window_id.is_none_or(|window_id| self.window_id == window_id)
    }

    fn pane_list_entries_for_worklane(&self, worklane_id: &str) -> Vec<PaneListEntry> {
        self.panes
            .iter()
            .filter(|pane| pane.worklane_id == worklane_id)
            .enumerate()
            .map(|(index, pane)| PaneListEntry {
                index: (index + 1) as i32,
                id: pane.pane_id.clone(),
                column: (pane.column_index + 1) as i32,
                title: pane.title.clone(),
                working_directory: pane.terminal_request.working_directory.clone(),
                is_focused: self
                    .focused_pane_id_by_worklane_id
                    .get(worklane_id)
                    .is_some_and(|focused| focused == &pane.pane_id),
                agent_tool: None,
                agent_status: None,
            })
            .collect()
    }

    fn apply_pane_split_ipc_command(&mut self, target: &AgentIpcPaneTarget, arguments: &[String]) {
        let _ = self.focus_agent_ipc_target(target);
        let Some(direction) = PaneIpcSplitDirection::parse(arguments) else {
            return;
        };
        let result = match direction {
            PaneIpcSplitDirection::Right => self.split_focused_pane_right(),
            PaneIpcSplitDirection::Left => self.split_focused_pane_left(),
            PaneIpcSplitDirection::Down => self.split_focused_pane_below(),
            PaneIpcSplitDirection::Up => self.split_focused_pane_above(),
        };
        if result == AppCommandExecutionResult::Applied {
            self.apply_pane_split_layout_ipc_command(direction, arguments);
        }
    }

    fn apply_pane_split_layout_ipc_command(
        &mut self,
        direction: PaneIpcSplitDirection,
        arguments: &[String],
    ) {
        match PaneIpcSplitLayout::parse(arguments) {
            PaneIpcSplitLayout::None => {}
            PaneIpcSplitLayout::Equal if direction.is_horizontal() => {
                let _ = self.apply_layout_command(AppCommandId::ArrangeWidthHalves);
            }
            PaneIpcSplitLayout::Equal => {
                let _ = self.equalize_focused_column_heights();
            }
            PaneIpcSplitLayout::Golden if direction.is_horizontal() => {
                let _ = self.apply_layout_command(AppCommandId::ArrangeWidthGoldenFocusWide);
            }
            PaneIpcSplitLayout::Golden => {
                let _ = self.apply_layout_command(AppCommandId::ArrangeHeightGoldenFocusTall);
            }
            PaneIpcSplitLayout::Ratio(fraction) if direction.is_horizontal() => {
                let _ = self.resize_focused_column_to_fraction(fraction);
            }
            PaneIpcSplitLayout::Ratio(fraction) => {
                let _ = self.resize_focused_pane_height_to_fraction(fraction);
            }
        }
    }

    fn apply_pane_focus_ipc_command(&mut self, target: &AgentIpcPaneTarget, arguments: &[String]) {
        let _ = self.focus_agent_ipc_target(target);
        let Some(focus_target) = arguments.first().map(String::as_str) else {
            return;
        };
        match focus_target {
            "left" => {
                let _ = self.move_focus_horizontally(-1);
            }
            "right" => {
                let _ = self.move_focus_horizontally(1);
            }
            "up" => {
                let _ = self.move_focus_vertically(-1);
            }
            "down" => {
                let _ = self.move_focus_vertically(1);
            }
            _ => {
                if let Some(pane_id) =
                    self.resolve_pane_ipc_argument(focus_target, &target.worklane_id)
                {
                    let _ = self.focus_agent_ipc_target(&AgentIpcPaneTarget {
                        window_id: target.window_id.clone(),
                        worklane_id: target.worklane_id.clone(),
                        pane_id,
                    });
                }
            }
        }
    }

    fn apply_pane_close_ipc_command(&mut self, target: &AgentIpcPaneTarget, arguments: &[String]) {
        let close_target = arguments
            .first()
            .and_then(|argument| self.resolve_pane_ipc_argument(argument, &target.worklane_id))
            .unwrap_or_else(|| target.pane_id.clone());
        let _ = self.focus_agent_ipc_target(&AgentIpcPaneTarget {
            window_id: target.window_id.clone(),
            worklane_id: target.worklane_id.clone(),
            pane_id: close_target,
        });
        let _ = self.close_focused_pane();
    }

    fn apply_pane_resize_ipc_command(&mut self, target: &AgentIpcPaneTarget, arguments: &[String]) {
        let _ = self.focus_agent_ipc_target(target);
        let Some(resize_target) = arguments.first().map(String::as_str) else {
            return;
        };
        let command_id = match resize_target {
            "left" => Some(AppCommandId::ResizePaneLeft),
            "right" => Some(AppCommandId::ResizePaneRight),
            "up" => Some(AppCommandId::ResizePaneUp),
            "down" => Some(AppCommandId::ResizePaneDown),
            _ => None,
        };
        if let Some(command_id) = command_id {
            let _ = self.apply_layout_command(command_id);
        } else if let Some(fraction) = percentage_fraction(resize_target) {
            let _ = self.resize_focused_column_to_fraction(fraction);
        }
    }

    fn apply_pane_layout_ipc_command(&mut self, target: &AgentIpcPaneTarget, arguments: &[String]) {
        let _ = self.focus_agent_ipc_target(target);
        let Some(preset) = arguments.first().map(String::as_str) else {
            return;
        };
        let is_vertical = arguments
            .iter()
            .any(|argument| argument == "--vertical" || argument == "-v");
        let command_id = match (preset, is_vertical) {
            ("halves", false) => Some(AppCommandId::ArrangeWidthHalves),
            ("halves", true) => Some(AppCommandId::ArrangeHeightTwoPerColumn),
            ("thirds", false) => Some(AppCommandId::ArrangeWidthThirds),
            ("thirds", true) => Some(AppCommandId::ArrangeHeightThreePerColumn),
            ("quarters", false) => Some(AppCommandId::ArrangeWidthQuarters),
            ("quarters", true) => Some(AppCommandId::ArrangeHeightFourPerColumn),
            ("full", false) => Some(AppCommandId::ArrangeWidthFull),
            ("full", true) => Some(AppCommandId::ArrangeHeightFull),
            ("golden-wide", _) => Some(AppCommandId::ArrangeWidthGoldenFocusWide),
            ("golden-narrow", _) => Some(AppCommandId::ArrangeWidthGoldenFocusNarrow),
            ("golden-tall", _) => Some(AppCommandId::ArrangeHeightGoldenFocusTall),
            ("golden-short", _) => Some(AppCommandId::ArrangeHeightGoldenFocusShort),
            ("reset", _) => Some(AppCommandId::ResetPaneLayout),
            _ => None,
        };
        if let Some(command_id) = command_id {
            let _ = self.apply_layout_command(command_id);
        }
    }

    fn apply_pane_grid_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<DesktopAgentIpcAppliedRequest, AgentIpcRequestRejection> {
        let options = pane_ipc_grid_options(arguments)?;
        if options.destination == PaneIpcGridDestination::NewWindow {
            return self
                .spawn_grid_window_session(target, &options)
                .map(|session| DesktopAgentIpcAppliedRequest::NewWindow(Box::new(session)));
        }

        let _ = self.focus_agent_ipc_target(target);
        let source_pane_id = match options.destination {
            PaneIpcGridDestination::Current => target.pane_id.clone(),
            PaneIpcGridDestination::NewWorklane => self.create_desktop_grid_worklane_source()?,
            PaneIpcGridDestination::NewWindow => unreachable!(),
        };
        let apply_command_to_source_spec =
            options.destination == PaneIpcGridDestination::NewWorklane && options.include_source;
        let source_pane_id = self.apply_grid_to_desktop_source(
            &source_pane_id,
            options.rows,
            options.columns,
            options.command.as_deref(),
            apply_command_to_source_spec,
            options.focus,
        )?;
        if options.include_source
            && let Some(command) = options.command.as_deref() {
                self.submit_grid_command_to_pane(&source_pane_id, command)?;
            }
        Ok(DesktopAgentIpcAppliedRequest::Empty)
    }

    fn spawn_grid_window_session(
        &mut self,
        target: &AgentIpcPaneTarget,
        options: &crate::app::PaneIpcGridOptions,
    ) -> Result<Self, AgentIpcRequestRejection> {
        let source_spec = self
            .panes
            .iter()
            .find(|pane| pane.worklane_id == target.worklane_id && pane.pane_id == target.pane_id)
            .map(DesktopPaneSession::clone_spec)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let window_id = self.next_window_id();
        let worklane_id = next_desktop_worklane_id(&self.worklane_order);
        let pane_id = next_desktop_pane_id(&self.panes);
        let mut terminal_request = TerminalSessionRequest::default();
        terminal_request.working_directory = source_spec.terminal_request.working_directory.clone();
        terminal_request.environment_variables =
            source_spec.terminal_request.environment_variables.clone();
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: worklane_id.clone(),
            column_id: format!("column-{pane_id}"),
            column_index: 0,
            pane_index: 0,
            title: "pane 1".to_string(),
            column_width: DESKTOP_DEFAULT_COLUMN_WIDTH,
            pane_height: Some(1.0),
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let agent_ipc_environment = if self.agent_ipc_environment.is_some() {
            Some(
                desktop_agent_ipc_environment_for_panes(
                    &window_id,
                    [(worklane_id.as_str(), pane_id.as_str())],
                )
                .map_err(|error| {
                    AgentIpcRequestRejection::new("grid_window_spawn_failed", error.to_string())
                })?,
            )
        } else {
            None
        };
        let pane_environment = agent_ipc_environment
            .as_ref()
            .and_then(|environment| environment.pane_environment(Some(&window_id), &spec));
        let pane = DesktopPaneSession::spawn_with_agent_ipc(
            &spec,
            self.default_size,
            Some(&window_id),
            pane_environment.as_ref(),
        )
        .map_err(|error| {
            AgentIpcRequestRejection::new("grid_window_spawn_failed", error.to_string())
        })?;
        let mut session = self.single_pane_window_session(
            window_id,
            worklane_id,
            pane_id.clone(),
            pane,
            agent_ipc_environment,
            Vec::new(),
            self.task_runner_actions.clone(),
            None,
        );
        session.apply_grid_to_desktop_source(
            &pane_id,
            options.rows,
            options.columns,
            options.command.as_deref(),
            options.include_source,
            options.focus,
        )?;
        if options.include_source
            && let Some(command) = options.command.as_deref() {
                session.submit_grid_command_to_pane(&pane_id, command)?;
            }
        Ok(session)
    }

    fn create_desktop_grid_worklane_source(&mut self) -> Result<String, AgentIpcRequestRejection> {
        match self.create_new_worklane() {
            AppCommandExecutionResult::Applied => self
                .focused_pane_id
                .clone()
                .ok_or_else(agent_ipc_pane_not_found_rejection),
            _ => Err(agent_ipc_pane_not_found_rejection()),
        }
    }

    fn apply_grid_to_desktop_source(
        &mut self,
        source_pane_id: &str,
        rows: usize,
        columns: usize,
        command: Option<&str>,
        include_source_command: bool,
        focus: PaneIpcGridFocus,
    ) -> Result<String, AgentIpcRequestRejection> {
        let cell_count = grid_cell_count(rows, columns)?;
        let source_index = self
            .panes
            .iter()
            .position(|pane| pane.pane_id == source_pane_id)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let source_worklane_id = self.panes[source_index].worklane_id.clone();
        if self.worklane_id != source_worklane_id {
            return Err(AgentIpcRequestRejection::new(
                "grid_source_pane_not_found",
                "Source pane is not in the active worklane.",
            ));
        }

        let worklane_pane_count = self
            .panes
            .iter()
            .filter(|pane| pane.worklane_id == source_worklane_id)
            .count();
        let grid_worklane_id = if worklane_pane_count > 1 {
            self.isolate_desktop_grid_source(source_pane_id)?
        } else {
            source_worklane_id
        };

        let source_spec = self
            .panes
            .iter()
            .find(|pane| pane.worklane_id == grid_worklane_id && pane.pane_id == source_pane_id)
            .map(DesktopPaneSession::clone_spec)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let mut pane_ids = vec![source_pane_id.to_string()];
        let mut reserved_pane_ids = self
            .panes
            .iter()
            .map(|pane| pane.pane_id.clone())
            .collect::<HashSet<_>>();
        while pane_ids.len() < cell_count {
            let pane_id = next_desktop_pane_id_with_reserved(&self.panes, &reserved_pane_ids);
            reserved_pane_ids.insert(pane_id.clone());
            let mut terminal_request = TerminalSessionRequest::default();
            terminal_request.working_directory =
                source_spec.terminal_request.working_directory.clone();
            terminal_request.environment_variables =
                source_spec.terminal_request.environment_variables.clone();
            if let Some(command) = command {
                terminal_request.command = Some(command.to_string());
            }
            let spec = PaneLaunchSpec {
                pane_id: pane_id.clone(),
                worklane_id: grid_worklane_id.clone(),
                column_id: format!("column-{pane_id}"),
                column_index: 0,
                pane_index: 0,
                title: pane_id.replace('-', " "),
                column_width: DESKTOP_DEFAULT_COLUMN_WIDTH,
                pane_height: Some(1.0),
                terminal_request,
                restored_rerunnable_command: None,
                status_text: None,
                applied_restore_draft_tool: None,
            };
            let session = self.spawn_pane_session(&spec).map_err(|error| {
                AgentIpcRequestRejection::new("grid_pane_spawn_failed", error.to_string())
            })?;
            self.panes.push(session);
            pane_ids.push(pane_id);
        }

        self.apply_desktop_grid_layout(
            &grid_worklane_id,
            &pane_ids,
            rows,
            columns,
            command,
            include_source_command,
            focus,
        )?;
        Ok(source_pane_id.to_string())
    }

    fn isolate_desktop_grid_source(
        &mut self,
        source_pane_id: &str,
    ) -> Result<String, AgentIpcRequestRejection> {
        let source_index = self
            .panes
            .iter()
            .position(|pane| pane.pane_id == source_pane_id)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let removed_spec = self.panes[source_index].clone_spec();
        let source_worklane_id = removed_spec.worklane_id.clone();
        let destination_worklane_id = next_desktop_worklane_id(&self.worklane_order);
        self.mirror_desktop_grid_source_ipc_token(&removed_spec, &destination_worklane_id);
        let mut moved_pane = self.panes.remove(source_index);
        retarget_desktop_pane_for_split_out(&mut moved_pane, &destination_worklane_id);
        normalize_pane_positions(
            &mut self.panes,
            &removed_spec.worklane_id,
            removed_spec.column_index,
            removed_spec.pane_index,
        );
        self.ensure_worklane(&destination_worklane_id);
        self.focused_pane_id_by_worklane_id
            .insert(destination_worklane_id.clone(), source_pane_id.to_string());
        self.worklane_id = destination_worklane_id.clone();
        self.focused_pane_id = Some(source_pane_id.to_string());
        self.panes.push(moved_pane);
        sort_panes(&mut self.panes);
        if !self
            .panes
            .iter()
            .any(|pane| pane.worklane_id == source_worklane_id)
        {
            self.remove_empty_worklane(&source_worklane_id);
        }
        Ok(destination_worklane_id)
    }

    fn mirror_desktop_grid_source_ipc_token(
        &mut self,
        source_spec: &PaneLaunchSpec,
        destination_worklane_id: &str,
    ) {
        let pane_token = self
            .agent_ipc_environment
            .as_ref()
            .and_then(|environment| {
                environment.pane_environment(Some(&self.window_id), source_spec)
            })
            .map(|environment| environment.pane_token);
        if let (Some(environment), Some(pane_token)) =
            (self.agent_ipc_environment.as_mut(), pane_token)
        {
            environment.set_pane_token(
                Some(&self.window_id),
                destination_worklane_id,
                &source_spec.pane_id,
                pane_token,
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn apply_desktop_grid_layout(
        &mut self,
        worklane_id: &str,
        pane_ids: &[String],
        rows: usize,
        columns: usize,
        command: Option<&str>,
        include_source_command: bool,
        focus: PaneIpcGridFocus,
    ) -> Result<(), AgentIpcRequestRejection> {
        let source_column_id = self
            .panes
            .iter()
            .find(|pane| pane.pane_id == pane_ids[0])
            .map(|pane| pane.column_id.clone())
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let column_ids = (0..columns)
            .map(|column_index| {
                if column_index == 0 {
                    source_column_id.clone()
                } else {
                    let pane_id = &pane_ids[column_index * rows];
                    format!("column-{pane_id}")
                }
            })
            .collect::<Vec<_>>();

        for (cell_index, pane_id) in pane_ids.iter().enumerate() {
            let column_index = cell_index / rows;
            let pane_index = cell_index % rows;
            let pane = self
                .panes
                .iter_mut()
                .find(|pane| pane.worklane_id == worklane_id && pane.pane_id == *pane_id)
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            pane.column_id = column_ids[column_index].clone();
            pane.column_index = column_index;
            pane.pane_index = pane_index;
            pane.column_width = DESKTOP_DEFAULT_COLUMN_WIDTH;
            pane.pane_height = Some(1.0);
            if cell_index == 0 && include_source_command {
                pane.terminal_request.command = command.map(str::to_string);
            }
        }

        sort_panes(&mut self.panes);
        let focus_pane_id = match focus {
            PaneIpcGridFocus::Source | PaneIpcGridFocus::First => pane_ids[0].clone(),
            PaneIpcGridFocus::Last => pane_ids[pane_ids.len() - 1].clone(),
        };
        let _ = self.focus_pane_reference(
            PaneReference::new(worklane_id.to_string(), PaneId::from(focus_pane_id)),
            true,
        );
        Ok(())
    }

    fn submit_grid_command_to_pane(
        &mut self,
        pane_id: &str,
        command: &str,
    ) -> Result<(), AgentIpcRequestRejection> {
        let pane = self
            .panes
            .iter_mut()
            .find(|pane| pane.pane_id == pane_id)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let bytes = TerminalInputPlanner::submit_command(command, TerminalPasteMode::Plain)
            .into_pty_bytes();
        pane.stream.write_all(&bytes).map_err(|error| {
            AgentIpcRequestRejection::new("grid_command_submission_failed", error.to_string())
        })
    }

    fn apply_pane_worklane_color_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<(), AgentIpcRequestRejection> {
        let Some(color) = pane_ipc_worklane_color(arguments) else {
            return Ok(());
        };
        let worklane_id = pane_ipc_worklane_id_override(arguments)
            .unwrap_or(target.worklane_id.as_str())
            .to_string();
        if !self.has_worklane(&worklane_id) {
            return Err(AgentIpcRequestRejection::new(
                "worklane_not_found",
                format!("No worklane with id '{worklane_id}'."),
            ));
        }
        if let Some(color) = color {
            self.worklane_colors_by_id.insert(worklane_id, color);
        } else {
            self.worklane_colors_by_id.remove(&worklane_id);
        }
        Ok(())
    }

    fn apply_pane_notify_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<PaneNotification, AgentIpcRequestRejection> {
        let options = pane_ipc_notification_options(arguments)?;
        let Some(window_id) = target.window_id.as_deref() else {
            return Err(agent_ipc_pane_not_found_rejection());
        };
        let notification = PaneNotification {
            title: options.title,
            subtitle: options.subtitle,
            body: options.body,
            include_inbox: options.include_inbox,
            is_silent: options.is_silent,
            window_id: window_id.to_string(),
            worklane_id: target.worklane_id.clone(),
            pane_id: target.pane_id.clone(),
        };
        self.pane_notifications.insert(0, notification.clone());
        if self.pane_notifications.len() > 50 {
            self.pane_notifications.truncate(50);
        }
        Ok(notification)
    }

    fn apply_pane_worklane_rename_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<(), AgentIpcRequestRejection> {
        let Some(rename) = pane_ipc_worklane_rename(arguments) else {
            return Ok(());
        };
        let worklane_id = rename
            .worklane_id_override
            .as_deref()
            .unwrap_or(target.worklane_id.as_str())
            .to_string();
        if !self.has_worklane(&worklane_id) {
            return Err(AgentIpcRequestRejection::new(
                "worklane_not_found",
                format!("No worklane with id '{worklane_id}'."),
            ));
        }
        if let Some(title) = normalized_worklane_title(rename.title.as_deref()) {
            self.worklane_titles_by_id.insert(worklane_id, title);
        } else {
            self.worklane_titles_by_id.remove(&worklane_id);
        }
        Ok(())
    }

    fn apply_pane_theme_ipc_command(
        &mut self,
        arguments: &[String],
    ) -> Result<AppearanceThemeMode, AgentIpcRequestRejection> {
        let raw_command = arguments.first().and_then(|value| trimmed_non_empty(value));
        let Some(raw_command) = raw_command else {
            return Err(AgentIpcRequestRejection::new(
                "missing_command",
                "Missing theme command.",
            ));
        };
        let Some(command) = PaneIpcThemeCommand::parse(raw_command) else {
            return Err(AgentIpcRequestRejection::new(
                "unsupported_command",
                format!("Unsupported theme command: {raw_command}"),
            ));
        };
        let theme_mode = command.resolve(self.theme_mode);
        self.persist_live_config_update(|config| {
            config.appearance.theme_mode = theme_mode;
        })
        .map_err(|message| AgentIpcRequestRejection::new("config_update_failed", message))?;
        Ok(theme_mode)
    }

    fn focus_agent_ipc_target(&mut self, target: &AgentIpcPaneTarget) -> AppCommandExecutionResult {
        self.focus_pane_reference(
            PaneReference::new(
                target.worklane_id.clone(),
                PaneId::from(target.pane_id.clone()),
            ),
            true,
        )
    }

    fn resolve_pane_ipc_argument(&self, target: &str, worklane_id: &str) -> Option<String> {
        if let Some(pane) = self
            .panes
            .iter()
            .find(|pane| pane.worklane_id == worklane_id && pane.pane_id == target)
        {
            return Some(pane.pane_id.clone());
        }
        let display_index = target.parse::<usize>().ok().filter(|index| *index > 0)?;
        self.panes
            .iter()
            .filter(|pane| pane.worklane_id == worklane_id)
            .nth(display_index - 1)
            .map(|pane| pane.pane_id.clone())
    }

    fn has_worklane(&self, worklane_id: &str) -> bool {
        self.worklane_order
            .iter()
            .any(|candidate| candidate == worklane_id)
            || self
                .panes
                .iter()
                .any(|pane| pane.worklane_id == worklane_id)
    }

    fn agent_signal_payload_for_legacy_ipc_alias(
        &self,
        request: &AgentIpcRequest,
    ) -> Result<Option<AgentSignalPayload>, AgentIpcRequestRejection> {
        for alias in &self.agent_ipc_aliases {
            let environment = alias.legacy_runtime_environment();
            match agent_signal_payload_for_authenticated_ipc_request(request, Some(&environment)) {
                Ok(mut payload) => {
                    alias.retarget_payload(&mut payload, &self.window_id);
                    return Ok(Some(payload));
                }
                Err(error)
                    if matches!(error.code, "invalid_pane_token" | "missing_target_context") =>
                {
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(None)
    }

    fn spawn_pane_session(
        &mut self,
        spec: &PaneLaunchSpec,
    ) -> Result<DesktopPaneSession, PtyError> {
        let pane_environment = self.agent_ipc_pane_environment_for_spec(spec);
        DesktopPaneSession::spawn_with_agent_ipc(
            spec,
            self.default_size,
            Some(&self.window_id),
            pane_environment.as_ref(),
        )
    }

    fn agent_ipc_pane_environment_for_spec(
        &mut self,
        spec: &PaneLaunchSpec,
    ) -> Option<AgentIpcPaneEnvironment> {
        let environment = self.agent_ipc_environment.as_mut()?;
        let window_id = Some(self.window_id.as_str());
        if environment.pane_environment(window_id, spec).is_none() {
            let pane_token = generate_agent_ipc_pane_token().ok()?;
            environment.set_pane_token(window_id, &spec.worklane_id, &spec.pane_id, pane_token);
        }
        environment.pane_environment(window_id, spec)
    }

    fn next_window_id(&mut self) -> String {
        let window_id = format!("window-{}", self.next_window_index);
        self.next_window_index += 1;
        window_id
    }

    #[allow(clippy::too_many_arguments)]
    fn single_pane_window_session(
        &self,
        window_id: String,
        worklane_id: String,
        pane_id: String,
        pane: DesktopPaneSession,
        agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
        agent_ipc_aliases: Vec<DesktopAgentIpcAlias>,
        task_runner_actions: Vec<TaskRunnerAction>,
        worklane_title: Option<String>,
    ) -> Self {
        let mut focused_pane_id_by_worklane_id = BTreeMap::new();
        focused_pane_id_by_worklane_id.insert(worklane_id.clone(), pane_id.clone());
        let mut worklane_titles_by_id = BTreeMap::new();
        if let Some(title) = normalized_worklane_title(worklane_title.as_deref()) {
            worklane_titles_by_id.insert(worklane_id.clone(), title);
        }
        Self {
            title: self.title.clone(),
            window_id: window_id.clone(),
            next_window_index: next_desktop_window_index(&window_id),
            worklane_id: worklane_id.clone(),
            worklane_order: vec![worklane_id],
            focused_pane_id_by_worklane_id,
            default_size: self.default_size,
            focused_pane_id: Some(pane_id),
            focus_history: PaneFocusHistory::default(),
            panes: vec![pane],
            command_palette: None,
            global_search: None,
            pane_search: None,
            worklane_rename: None,
            sidebar: self.sidebar,
            mouse_selection_pane_id: None,
            open_with_targets: Vec::new(),
            available_open_with_targets: self.available_open_with_targets.clone(),
            detected_servers: Vec::new(),
            available_server_browser_targets: self.available_server_browser_targets.clone(),
            task_runner_actions,
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklane_titles_by_id,
            pane_notifications: Vec::new(),
            config_path: self.config_path.clone(),
            config: self.config.clone(),
            bookmarks_path: self.bookmarks_path.clone(),
            bookmarks: None,
            task_manager: DesktopTaskManagerState::new(WindowsTaskManagerProcessProbe::new()),
            task_manager_snapshot: None,
            settings: None,
            theme_mode: self.theme_mode,
            pane_layout: self.pane_layout.clone(),
            shortcuts: self.shortcuts.clone(),
            server_detection_config: self.server_detection_config.clone(),
            server_ignored_port_rules: self.server_ignored_port_rules.clone(),
            closed_pane_specs: Vec::new(),
            agent_ipc_environment,
            agent_ipc_aliases,
        }
    }

    pub fn pane_snapshots(&self) -> Vec<DesktopPaneSnapshot> {
        self.panes
            .iter()
            .filter(|pane| pane.worklane_id == self.worklane_id)
            .map(|pane| DesktopPaneSnapshot {
                pane_id: pane.pane_id.clone(),
                worklane_id: pane.worklane_id.clone(),
                column_id: pane.column_id.clone(),
                column_index: pane.column_index,
                pane_index: pane.pane_index,
                column_width: pane.column_width,
                pane_height: pane.pane_height,
                title: pane.title.clone(),
                is_focused: self.focused_pane_id.as_deref() == Some(pane.pane_id.as_str()),
                visible_lines: pane.terminal.visible_lines(),
                plain_text: pane.terminal.plain_text(),
            })
            .collect()
    }

    pub fn task_manager_pane_sources(&self) -> Vec<TaskManagerPaneSource> {
        self.worklane_order
            .iter()
            .enumerate()
            .flat_map(|(worklane_index, worklane_id)| {
                let worklane_title = self
                    .worklane_titles_by_id
                    .get(worklane_id)
                    .cloned()
                    .unwrap_or_else(|| format!("Worklane {}", worklane_index + 1));
                self.panes
                    .iter()
                    .filter(move |pane| pane.worklane_id == *worklane_id)
                    .map({
                        let window_id = self.window_id.clone();
                        move |pane| TaskManagerPaneSource {
                            window_id: window_id.clone(),
                            window_title: "Window 1".to_string(),
                            worklane_id: pane.worklane_id.clone(),
                            worklane_title: worklane_title.clone(),
                            pane_id: pane.pane_id.clone(),
                            pane_title: trimmed_non_empty(&pane.title)
                                .unwrap_or(pane.pane_id.as_str())
                                .to_string(),
                            status_text: task_manager_status_text(pane.shell_activity_state),
                            root_pid: pane.root_pid,
                            is_remote: false,
                            current_working_directory: pane
                                .terminal_request
                                .working_directory
                                .clone(),
                        }
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    pub fn task_manager_text_snapshot(&self) -> Option<&DesktopTaskManagerTextSnapshot> {
        self.task_manager_snapshot.as_ref()
    }

    pub fn detected_servers(&self) -> &[DetectedServer] {
        &self.detected_servers
    }

    pub fn bookmarks_snapshot(&self) -> Option<DesktopBookmarksSnapshot> {
        self.bookmarks
            .as_ref()
            .map(DesktopBookmarksSnapshot::from_state)
    }

    pub fn command_palette_snapshot(&self) -> Option<DesktopCommandPaletteSnapshot> {
        let state = self.command_palette.as_ref()?;
        let results = self
            .desktop_window_snapshot()
            .resolve_command_palette(&state.query);
        let selected_index = (!results.items.is_empty()).then_some(
            state
                .selected_index
                .min(results.items.len().saturating_sub(1)),
        );
        let items = results
            .items
            .into_iter()
            .take(DESKTOP_COMMAND_PALETTE_VISIBLE_ITEM_LIMIT)
            .enumerate()
            .map(|(index, resolved)| DesktopCommandPaletteItemSnapshot {
                title: resolved.item.title,
                subtitle: resolved.item.subtitle,
                category: resolved.item.category,
                is_selected: Some(index) == selected_index,
            })
            .collect();

        Some(DesktopCommandPaletteSnapshot {
            query: state.query.clone(),
            selected_index,
            items,
        })
    }

    pub fn pane_search_snapshot(&self) -> Option<DesktopPaneSearchSnapshot> {
        let state = self.pane_search.as_ref()?;
        let search = state.session.state();
        if !search.is_hud_visible {
            return None;
        }

        Some(DesktopPaneSearchSnapshot {
            pane_id: state.pane_id.clone(),
            query: search.needle.clone(),
            selected_index: search.selected,
            total: search.total,
            current_match: state.session.current_match().copied(),
        })
    }

    pub fn global_search_snapshot(&self) -> Option<DesktopGlobalSearchSnapshot> {
        let state = self.global_search.as_ref()?.coordinator.state();
        if !state.is_hud_visible {
            return None;
        }

        Some(DesktopGlobalSearchSnapshot {
            query: state.needle.clone(),
            selected_index: state.selected,
            total: state.total,
        })
    }

    pub fn sidebar_snapshot(&self) -> DesktopSidebarSnapshot {
        let mut worklane_ids = self.worklane_order.clone();
        for pane in &self.panes {
            if !worklane_ids.contains(&pane.worklane_id) {
                worklane_ids.push(pane.worklane_id.clone());
            }
        }

        let worklanes = worklane_ids
            .into_iter()
            .filter_map(|worklane_id| {
                let panes = self
                    .panes
                    .iter()
                    .filter(|pane| pane.worklane_id == worklane_id)
                    .collect::<Vec<_>>();
                if panes.is_empty() {
                    return None;
                }
                let focused_pane_id = self
                    .focused_pane_id_by_worklane_id
                    .get(&worklane_id)
                    .cloned()
                    .or_else(|| panes.first().map(|pane| pane.pane_id.clone()));
                Some(DesktopSidebarWorklaneSnapshot {
                    title: self
                        .worklane_title(&worklane_id)
                        .map(str::to_string)
                        .unwrap_or_else(|| self.default_worklane_title(&worklane_id)),
                    color: self.worklane_colors_by_id.get(&worklane_id).cloned(),
                    is_active: worklane_id == self.worklane_id,
                    pane_count: panes.len(),
                    focused_pane_id,
                    worklane_id,
                })
            })
            .collect();

        DesktopSidebarSnapshot {
            width: self.sidebar.width,
            visibility: self.sidebar.visibility.raw_value().to_string(),
            is_visible: self.sidebar.is_visible(),
            worklanes,
        }
    }

    pub fn settings_snapshot(&self) -> Option<DesktopSettingsSnapshot> {
        let state = self.settings.as_ref()?;
        let section =
            settings_section_from_raw_value(&state.section).unwrap_or(SettingsSection::General);
        let lines = self.settings_lines(section);
        Some(DesktopSettingsSnapshot {
            section: section.raw_value().to_string(),
            title: format!("{} Settings", section.title()),
            selected_index: state.selected_index.min(lines.len().saturating_sub(1)),
            lines,
        })
    }

    fn settings_lines(&self, section: SettingsSection) -> Vec<String> {
        match section {
            SettingsSection::General => vec![
                format!(
                    "Sidebar: {} ({:.0}px)",
                    self.sidebar.visibility.raw_value(),
                    self.sidebar.width
                ),
                format!(
                    "Restore workspace on launch: {}",
                    enabled_label(self.config.restore.restore_workspace_on_launch)
                ),
                format!(
                    "Confirm before closing pane: {}",
                    enabled_label(self.config.confirmations.confirm_before_closing_pane)
                ),
                format!(
                    "Confirm before closing window: {}",
                    enabled_label(self.config.confirmations.confirm_before_closing_window)
                ),
                format!(
                    "Confirm before quitting: {}",
                    enabled_label(self.config.confirmations.confirm_before_quitting)
                ),
                format!(
                    "Always clean copied content: {}",
                    enabled_label(self.config.clipboard.always_clean_copies)
                ),
            ],
            SettingsSection::Appearance => vec![
                format!(
                    "Theme mode: {}",
                    appearance_theme_mode_token(self.theme_mode)
                ),
                format!(
                    "Local theme: {}",
                    optional_setting(self.config.appearance.local_theme_name.as_deref())
                ),
                format!(
                    "Dark theme: {}",
                    optional_setting(self.config.appearance.preferred_dark_theme_name.as_deref())
                ),
                format!(
                    "Light theme: {}",
                    optional_setting(self.config.appearance.preferred_light_theme_name.as_deref())
                ),
                format!(
                    "Sync OpenCode theme: {}",
                    enabled_label(self.config.appearance.sync_opencode_theme_with_terminal)
                ),
            ],
            SettingsSection::Shortcuts => vec![
                format!(
                    "Shortcut overrides: {}",
                    self.config.shortcuts.bindings.len()
                ),
                "Reset all shortcuts".to_string(),
                "Apply Left-Hand Preset".to_string(),
                "Apply Right-Hand Preset".to_string(),
                "Use config [shortcuts] bindings to override or unbind commands.".to_string(),
            ],
            SettingsSection::Notifications => vec![
                format!(
                    "Sound: {}",
                    notification_sound_label(
                        &self.config.notifications.sound_name,
                        self.config
                            .notifications
                            .custom_sound_display_name
                            .as_deref()
                    )
                ),
                format!(
                    "Custom sound display: {}",
                    optional_setting(
                        self.config
                            .notifications
                            .custom_sound_display_name
                            .as_deref()
                    )
                ),
                "Open Notification Settings".to_string(),
                "Send Test Notification".to_string(),
            ],
            SettingsSection::OpenWith => {
                let enabled_ids: HashSet<&str> = self
                    .config
                    .open_with
                    .enabled_target_ids
                    .iter()
                    .map(String::as_str)
                    .collect();
                let mut lines = vec![format!(
                    "Primary target: {}",
                    open_with_target_label(
                        &self.config.open_with.primary_target_id,
                        &self.available_open_with_targets
                    )
                )];
                lines.extend(self.available_open_with_targets.iter().map(|target| {
                    format!(
                        "{}: {}",
                        target.display_name,
                        enabled_label(enabled_ids.contains(target.stable_id.as_str()))
                    )
                }));
                lines
            }
            SettingsSection::DevServers => {
                let enabled_ids = server_browser_enabled_ids(
                    &self.config.server_detection.enabled_browser_target_ids,
                    &self.available_server_browser_targets,
                );
                let mut lines = vec![
                    format!(
                        "Passive detection: {}",
                        enabled_label(self.config.server_detection.passive_detection_enabled)
                    ),
                    format!(
                        "Preferred browser: {}",
                        server_browser_target_label(
                            &self.config.server_detection.preferred_browser_id,
                            &self.available_server_browser_targets
                        )
                    ),
                ];
                lines.extend(self.available_server_browser_targets.iter().map(|target| {
                    format!(
                        "{}: {}",
                        target.display_name,
                        enabled_label(enabled_ids.contains(target.stable_id.as_str()))
                    )
                }));
                lines.push(format!(
                    "Ignored ports: {}",
                    joined_or_none(&self.config.server_detection.ignored_port_rules)
                ));
                lines
            }
            SettingsSection::PaneLayout => vec![
                format!(
                    "Right split behavior: {}",
                    pane_split_behavior_token(self.pane_layout.right_split_behavior)
                ),
                format!(
                    "Visible split width: {}",
                    self.pane_layout.visible_split_window_width
                ),
                format!(
                    "New worklane placement: {}",
                    new_worklane_placement_token(self.config.worklanes.new_worklane_placement)
                ),
                format!(
                    "Show pane labels: {}",
                    enabled_label(self.config.panes.show_labels)
                ),
                format!(
                    "Show project icons: {}",
                    enabled_label(self.config.panes.show_project_icons)
                ),
                format!(
                    "Smooth terminal scrolling: {}",
                    enabled_label(self.config.panes.smooth_scrolling_enabled)
                ),
                format!(
                    "Focus follows mouse: {}",
                    enabled_label(self.config.panes.focus_follows_mouse)
                ),
                format!(
                    "Focus follows mouse delay: {}",
                    focus_follows_mouse_delay_token(self.config.panes.focus_follows_mouse_delay)
                ),
                format!(
                    "Inactive pane opacity: {}",
                    inactive_pane_opacity_token(self.config.panes.inactive_opacity)
                ),
            ],
            SettingsSection::UpdatesPrivacy => vec![
                format!(
                    "Update channel: {}",
                    update_channel_token(self.config.updates.channel)
                ),
                format!(
                    "Error reporting: {}",
                    enabled_label(self.config.error_reporting.enabled)
                ),
                format!(
                    "Menu bar status item: {}",
                    enabled_label(self.config.menu_bar.show_status_item)
                ),
            ],
            SettingsSection::Agents => vec![
                format!(
                    "Agent caffeination: {}",
                    enabled_label(self.config.agent_caffeination.enabled)
                ),
                format!(
                    "Agent teams: {}",
                    enabled_label(self.config.agent_teams.enabled)
                ),
                format!(
                    "Known integrations: {}",
                    self.config.agent_integrations.states.len()
                ),
            ],
        }
    }

    pub fn worklane_rename_snapshot(&self) -> Option<DesktopWorklaneRenameSnapshot> {
        self.worklane_rename
            .as_ref()
            .map(|state| DesktopWorklaneRenameSnapshot {
                worklane_id: state.worklane_id.clone(),
                draft: state.draft.clone(),
            })
    }

    pub fn render_lines(&self, status: Option<&str>) -> Vec<String> {
        let mut lines = Vec::new();
        if let Some(status) = status.and_then(trimmed_non_empty) {
            lines.push(format!("Zentty: {status}"));
            lines.push(String::new());
        }

        if let Some(snapshot) = self.bookmarks_snapshot() {
            lines.extend(snapshot.lines.iter().cloned());
            lines.push(String::new());
        }

        if let Some(snapshot) = self.task_manager_snapshot.as_ref() {
            lines.extend(snapshot.lines.iter().cloned());
            lines.push(String::new());
        }

        if let Some(settings) = self.settings_snapshot() {
            lines.push(settings.title);
            for (index, line) in settings.lines.into_iter().enumerate() {
                let marker = if index == settings.selected_index {
                    ">"
                } else {
                    "-"
                };
                lines.push(format!("{marker} {line}"));
            }
            lines.push(String::new());
        }

        if let Some(search) = self.global_search_snapshot() {
            lines.push(format!(
                "Global Find: {} ({})",
                search.query,
                search_match_count_label(search.total)
            ));
            if let Some(selected) = search.selected_index {
                lines.push(format!("Global Match {}/{}", selected + 1, search.total));
            }
            lines.push(String::new());
        }

        if let Some(search) = self.pane_search_snapshot() {
            lines.push(format!(
                "Find {}: {} ({})",
                search.pane_id,
                search.query,
                search_match_count_label(search.total)
            ));
            if let Some(selected) = search.selected_index {
                lines.push(format!("Match {}/{}", selected + 1, search.total));
            }
            lines.push(String::new());
        }

        if let Some(rename) = self.worklane_rename_snapshot() {
            lines.push(format!(
                "Rename Worklane {}: {}",
                rename.worklane_id, rename.draft
            ));
            lines.push(String::new());
        }

        if let Some(palette) = self.command_palette_snapshot() {
            lines.push(format!("Command Palette: {}", palette.query));
            for item in palette.items {
                let marker = if item.is_selected { ">" } else { " " };
                if item.subtitle.trim().is_empty() {
                    lines.push(format!("{marker} {}", item.title));
                } else {
                    lines.push(format!("{marker} {} - {}", item.title, item.subtitle));
                }
            }
            lines.push(String::new());
        }

        for pane in self.pane_snapshots() {
            let marker = if pane.is_focused { "*" } else { " " };
            let title = if pane.title.trim().is_empty() {
                pane.pane_id.clone()
            } else {
                pane.title.clone()
            };
            lines.push(format!("{marker} {title}"));
            lines.extend(pane.visible_lines);
            lines.push(String::new());
        }

        let sidebar = self.sidebar_snapshot();
        if sidebar.is_visible {
            lines.push(format!(
                "Sidebar: {} ({:.0}px)",
                sidebar.visibility, sidebar.width
            ));
            for worklane in sidebar.worklanes {
                let marker = if worklane.is_active { ">" } else { " " };
                let color = worklane
                    .color
                    .as_deref()
                    .map(|color| format!(" [{color}]"))
                    .unwrap_or_default();
                let pane_label = if worklane.pane_count == 1 {
                    "1 pane".to_string()
                } else {
                    format!("{} panes", worklane.pane_count)
                };
                lines.push(format!(
                    "{marker} {}{} ({pane_label})",
                    worklane.title, color
                ));
            }
            lines.push(String::new());
        }

        lines
    }

    pub fn visible_lines(&self) -> Vec<String> {
        self.focused_pane()
            .map(|pane| pane.terminal.visible_lines())
            .unwrap_or_default()
    }

    pub fn plain_text(&self) -> String {
        self.focused_pane()
            .map(|pane| pane.terminal.plain_text())
            .unwrap_or_default()
    }

    pub fn plain_text_for_pane(&self, pane_id: &str) -> Option<String> {
        self.panes
            .iter()
            .find(|pane| pane.pane_id == pane_id)
            .map(|pane| pane.terminal.plain_text())
    }

    pub fn select_focused_pane_range(
        &mut self,
        start: TerminalTextPoint,
        end: TerminalTextPoint,
    ) -> bool {
        let Some(pane) = self.focused_pane_mut() else {
            return false;
        };

        let mut selection = TerminalSelection::new();
        selection.begin(start);
        selection.extend(end);
        if selection.selected_text(&pane.terminal.screen).is_none() {
            return false;
        }
        pane.selection = selection;
        true
    }

    pub fn selected_text_for_focused_pane(&self) -> Option<String> {
        self.focused_pane()
            .and_then(|pane| pane.selection.selected_text(&pane.terminal.screen))
    }

    pub fn terminal_point_for_render_cell(
        &self,
        row: usize,
        column: usize,
    ) -> Option<(String, TerminalTextPoint)> {
        let (pane_index, visible_row, line_width) = self.pane_visible_row_for_render_row(row)?;
        let pane = &self.panes[pane_index];
        let line_index = pane.terminal.screen.scrollback_lines().len() + visible_row;
        Some((
            pane.pane_id.clone(),
            TerminalTextPoint {
                line_index,
                column: column.min(line_width),
            },
        ))
    }

    /// Map a viewport `(row, column)` of the focused pane's grid to a
    /// `TerminalTextPoint`, accounting for the scroll-back view offset. Used by
    /// the Direct2D grid renderer's mouse hit-testing (the focused pane fills
    /// the window), unlike [`terminal_point_for_render_cell`] which walks the
    /// legacy multi-line layout.
    fn terminal_point_for_focused_cell(
        &self,
        row: usize,
        column: usize,
    ) -> Option<(String, TerminalTextPoint)> {
        let pane = self.focused_pane()?;
        let screen = &pane.terminal.screen;
        let scrollback_len = screen.scrollback_len();
        let top_line = scrollback_len - screen.view_scroll().min(scrollback_len);
        Some((
            pane.pane_id.clone(),
            TerminalTextPoint {
                line_index: top_line + row,
                column: column.min(screen.width()),
            },
        ))
    }

    /// The focused pane's active selection range (combined-buffer coordinates),
    /// for the renderer to highlight.
    pub fn focused_selection_range(&self) -> Option<TerminalTextRange> {
        self.focused_pane()?.selection.range()
    }

    /// Begin a mouse selection at the focused pane's viewport `(row, column)`.
    pub fn begin_mouse_selection_at_focused_cell(&mut self, row: usize, column: usize) -> bool {
        let Some((pane_id, point)) = self.terminal_point_for_focused_cell(row, column) else {
            self.mouse_selection_pane_id = None;
            return false;
        };
        for pane in &mut self.panes {
            pane.selection.clear();
        }
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            self.mouse_selection_pane_id = None;
            return false;
        };
        pane.selection.begin(point);
        self.mouse_selection_pane_id = Some(pane_id);
        true
    }

    /// Extend the active mouse selection to the focused pane's `(row, column)`.
    pub fn extend_mouse_selection_at_focused_cell(&mut self, row: usize, column: usize) -> bool {
        let Some(active_pane_id) = self.mouse_selection_pane_id.clone() else {
            return false;
        };
        let Some((pane_id, point)) = self.terminal_point_for_focused_cell(row, column) else {
            return false;
        };
        if pane_id != active_pane_id {
            return false;
        }
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return false;
        };
        pane.selection.extend(point);
        true
    }

    /// Select the word at the focused pane's viewport `(row, column)`.
    pub fn select_word_at_focused_cell(&mut self, row: usize, column: usize) -> bool {
        let Some((pane_id, point)) = self.terminal_point_for_focused_cell(row, column) else {
            return false;
        };
        for pane in &mut self.panes {
            pane.selection.clear();
        }
        self.mouse_selection_pane_id = None;
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return false;
        };
        pane.selection.select_word_at(&pane.terminal.screen, point)
    }

    /// Scroll the focused pane's viewport by `delta_rows` (positive = into
    /// history). Returns true if the offset changed.
    pub fn scroll_focused_view(&mut self, delta_rows: i32) -> bool {
        let Some(pane) = self.focused_pane_mut() else {
            return false;
        };
        let before = pane.terminal.screen.view_scroll();
        if delta_rows > 0 {
            pane.terminal.screen.scroll_view_up(delta_rows as usize);
        } else if delta_rows < 0 {
            pane.terminal.screen.scroll_view_down((-delta_rows) as usize);
        }
        pane.terminal.screen.view_scroll() != before
    }

    pub fn pty_bytes_for_mouse_event_at_render_cell(
        &self,
        button: DesktopMouseButton,
        kind: DesktopMouseEventKind,
        row: usize,
        column: usize,
    ) -> Option<(String, Vec<u8>)> {
        let (pane_index, visible_row, line_width) = self.pane_visible_row_for_render_row(row)?;
        let pane = &self.panes[pane_index];
        let event = DesktopMouseEvent {
            button,
            kind,
            row: visible_row,
            column: column.min(line_width.saturating_sub(1)),
        };
        let bytes = pane.terminal.pty_bytes_for_mouse_event(event)?;
        Some((pane.pane_id.clone(), bytes))
    }

    pub fn execute_mouse_event_at_render_cell(
        &mut self,
        button: DesktopMouseButton,
        kind: DesktopMouseEventKind,
        row: usize,
        column: usize,
    ) -> DesktopCommandEffect {
        let Some((pane_id, bytes)) =
            self.pty_bytes_for_mouse_event_at_render_cell(button, kind, row, column)
        else {
            return DesktopCommandEffect::Ignored;
        };

        self.focus_pane_id(&pane_id, true);
        match self.write_bytes_to_focused(&bytes) {
            Ok(()) => DesktopCommandEffect::Repaint,
            Err(error) => DesktopCommandEffect::Status {
                message: error.to_string(),
            },
        }
    }

    fn pane_visible_row_for_render_row(&self, row: usize) -> Option<(usize, usize, usize)> {
        let mut current_row = self.overlay_render_row_count();
        for (pane_index, pane) in self.panes.iter().enumerate() {
            if pane.worklane_id != self.worklane_id {
                continue;
            }
            if row == current_row {
                return None;
            }
            current_row += 1;

            let visible_lines = pane.terminal.visible_lines();
            if row < current_row {
                return None;
            }
            if row < current_row + visible_lines.len() {
                let visible_row = row - current_row;
                let line_width = visible_lines[visible_row].chars().count();
                return Some((pane_index, visible_row, line_width));
            }

            current_row += visible_lines.len() + 1;
        }
        None
    }

    pub fn begin_mouse_selection_at_render_cell(&mut self, row: usize, column: usize) -> bool {
        let Some((pane_id, point)) = self.terminal_point_for_render_cell(row, column) else {
            self.mouse_selection_pane_id = None;
            return false;
        };

        for pane in &mut self.panes {
            pane.selection.clear();
        }
        let Some(index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            self.mouse_selection_pane_id = None;
            return false;
        };

        self.panes[index].selection.begin(point);
        self.focus_pane_id(&pane_id, true);
        self.mouse_selection_pane_id = Some(pane_id);
        true
    }

    pub fn extend_mouse_selection_at_render_cell(&mut self, row: usize, column: usize) -> bool {
        let Some(active_pane_id) = self.mouse_selection_pane_id.clone() else {
            return false;
        };
        let Some((pane_id, point)) = self.terminal_point_for_render_cell(row, column) else {
            return false;
        };
        if pane_id != active_pane_id {
            return false;
        }

        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return false;
        };
        pane.selection.extend(point);
        true
    }

    pub fn select_word_at_render_cell(&mut self, row: usize, column: usize) -> bool {
        let Some((pane_id, point)) = self.terminal_point_for_render_cell(row, column) else {
            self.mouse_selection_pane_id = None;
            return false;
        };

        for pane in &mut self.panes {
            pane.selection.clear();
        }
        let Some(index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            self.mouse_selection_pane_id = None;
            return false;
        };

        self.mouse_selection_pane_id = None;
        let pane = &mut self.panes[index];
        let selected = pane.selection.select_word_at(&pane.terminal.screen, point);
        self.focus_pane_id(&pane_id, true);
        selected
    }

    pub fn finish_mouse_selection(&mut self) -> bool {
        self.mouse_selection_pane_id.take().is_some()
    }

    pub fn clear_focused_pane_selection(&mut self) -> bool {
        let Some(pane) = self.focused_pane_mut() else {
            return false;
        };
        pane.selection.clear();
        true
    }

    pub fn poll_output(&mut self) -> Result<bool, PtyError> {
        let mut changed = false;
        for pane in &mut self.panes {
            let bytes = pane.stream.read_available_bytes()?;
            if !bytes.is_empty() {
                let worklane_id = pane.worklane_id.clone();
                let pane_id = pane.pane_id.clone();
                let responses = pane.terminal.feed_output(&bytes);
                if !responses.is_empty() {
                    pane.stream.write_all(&responses)?;
                }
                if let Some(title) = pane.terminal.title() {
                    pane.title = title.to_string();
                }
                let detected_servers =
                    ServerOutputUrlDetector::detect(&String::from_utf8_lossy(&bytes));
                for candidate in detected_servers {
                    upsert_detected_server(
                        &mut self.detected_servers,
                        &worklane_id,
                        &pane_id,
                        candidate,
                    );
                }
                changed = true;
            }
        }
        if changed {
            self.refresh_active_pane_search_matches();
            self.refresh_global_search_matches();
        }
        Ok(changed)
    }

    pub fn feed_output_for_pane(&mut self, pane_id: &str, bytes: &[u8]) -> Result<bool, PtyError> {
        if bytes.is_empty() {
            return Ok(false);
        }

        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return Ok(false);
        };

        let responses = pane.terminal.feed_output(bytes);
        if !responses.is_empty() {
            pane.stream.write_all(&responses)?;
        }
        if let Some(title) = pane.terminal.title() {
            pane.title = title.to_string();
        }
        let worklane_id = pane.worklane_id.clone();
        let pane_id = pane.pane_id.clone();
        let detected_servers = ServerOutputUrlDetector::detect(&String::from_utf8_lossy(bytes));
        for candidate in detected_servers {
            upsert_detected_server(
                &mut self.detected_servers,
                &worklane_id,
                &pane_id,
                candidate,
            );
        }
        self.refresh_active_pane_search_matches();
        self.refresh_global_search_matches();
        Ok(true)
    }

    pub fn resize(&mut self, size: TerminalSize) -> Result<(), PtyError> {
        for pane in &mut self.panes {
            pane.resize(size)?;
        }
        self.default_size = size;
        self.refresh_active_pane_search_matches();
        self.refresh_global_search_matches();
        Ok(())
    }

    pub fn write_char(&mut self, ch: char) -> Result<(), PtyError> {
        let bytes = DesktopTerminalState::pty_bytes_for_char(ch);
        self.write_bytes_to_focused(&bytes)
    }

    pub fn paste_to_focused(
        &mut self,
        paste: &TerminalClipboardPaste,
        mode: TerminalPasteMode,
    ) -> Result<(), PtyError> {
        let mode = self
            .focused_pane()
            .map(|pane| pane.terminal.paste_mode_for_request(mode))
            .unwrap_or(mode);
        let bytes = TerminalInputPlanner::paste_payload(paste, mode).into_pty_bytes();
        self.write_bytes_to_focused(&bytes)
    }

    fn write_bytes_to_focused(&mut self, bytes: &[u8]) -> Result<(), PtyError> {
        self.focused_pane_mut()
            .ok_or_else(|| PtyError::Backend("desktop session has no focused pane".to_string()))?
            .stream
            .write_all(bytes)
    }

    fn submit_command_to_pane(&mut self, pane_id: &str, command: &str) -> DesktopCommandEffect {
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return DesktopCommandEffect::Status {
                message: format!("Restored command target missing: {pane_id}"),
            };
        };
        let bytes = TerminalInputPlanner::submit_command(command, TerminalPasteMode::Plain)
            .into_pty_bytes();
        match pane.stream.write_all(&bytes) {
            Ok(()) => DesktopCommandEffect::Repaint,
            Err(error) => DesktopCommandEffect::Status {
                message: error.to_string(),
            },
        }
    }

    pub fn write_char_event(&mut self, ch: char) -> Result<DesktopCommandEffect, PtyError> {
        if self.command_palette.is_some() {
            return Ok(self.handle_command_palette_char(ch));
        }
        if self.settings.is_some() {
            return Ok(self.handle_settings_char(ch));
        }
        if self.worklane_rename.is_some() {
            return Ok(self.handle_worklane_rename_char(ch));
        }
        if self.global_search.is_some() {
            return Ok(self.handle_global_search_char(ch));
        }
        if self.pane_search.is_some() {
            return Ok(self.handle_pane_search_char(ch));
        }
        if self.bookmarks.is_some() {
            return Ok(self.handle_bookmarks_char(ch));
        }
        self.write_char(ch)?;
        Ok(DesktopCommandEffect::Ignored)
    }

    pub fn execute_key_event(&mut self, event: DesktopKeyEvent) -> DesktopCommandEffect {
        if self.command_palette.is_some()
            && let Some(effect) = self.handle_command_palette_key_event(event)
        {
            return effect;
        }

        if self.settings.is_some()
            && let Some(effect) = self.handle_settings_key_event(event)
        {
            return effect;
        }

        if self.global_search.is_some()
            && let Some(effect) = self.handle_global_search_key_event(event)
        {
            return effect;
        }

        if self.pane_search.is_some()
            && let Some(effect) = self.handle_pane_search_key_event(event)
        {
            return effect;
        }

        if self.bookmarks.is_some()
            && let Some(effect) = self.handle_bookmarks_key_event(event)
        {
            return effect;
        }

        if let Some(mode) = desktop_paste_mode_for_key_event(event) {
            return DesktopCommandEffect::PasteFromClipboard { mode };
        }

        if let Some(command_id) =
            DesktopShortcutResolver::command_for_key_event_with_shortcuts(event, &self.shortcuts)
        {
            let command_id = self.preference_adjusted_shortcut_command(event, command_id);
            if command_id == AppCommandId::ShowCommandPalette {
                self.show_command_palette();
                return DesktopCommandEffect::Repaint;
            }
            return self.execute_app_command(command_id);
        }

        let terminal_bytes = self
            .focused_pane()
            .and_then(|pane| pane.terminal.pty_bytes_for_terminal_key_event(event));
        if let Some(bytes) = terminal_bytes {
            return match self.write_bytes_to_focused(&bytes) {
                Ok(()) => DesktopCommandEffect::Repaint,
                Err(error) => DesktopCommandEffect::Status {
                    message: error.to_string(),
                },
            };
        }

        DesktopCommandEffect::Ignored
    }

    fn preference_adjusted_shortcut_command(
        &self,
        event: DesktopKeyEvent,
        command_id: AppCommandId,
    ) -> AppCommandId {
        if command_id == AppCommandId::CopyRaw
            && self.config.clipboard.always_clean_copies
            && is_default_windows_copy_shortcut(event)
            && !shortcut_overrides_command(&self.shortcuts, AppCommandId::CopyRaw)
        {
            AppCommandId::CleanCopy
        } else {
            command_id
        }
    }

    pub fn execute_command(&mut self, command_id: AppCommandId) -> AppCommandExecutionResult {
        match command_id {
            AppCommandId::FocusLeftPane => self.move_focus_horizontally(-1),
            AppCommandId::FocusRightPane => self.move_focus_horizontally(1),
            AppCommandId::FocusUpInColumn => self.move_focus_vertically(-1),
            AppCommandId::FocusDownInColumn => self.move_focus_vertically(1),
            AppCommandId::FocusPreviousPane => self.move_focus_by_order(-1),
            AppCommandId::FocusNextPane => self.move_focus_by_order(1),
            AppCommandId::NavigateBack => self.navigate_focus_history(true),
            AppCommandId::NavigateForward => self.navigate_focus_history(false),
            AppCommandId::NewWorklane => self.create_new_worklane(),
            AppCommandId::NextWorklane => self.cycle_worklane(1),
            AppCommandId::PreviousWorklane => self.cycle_worklane(-1),
            AppCommandId::WorklaneMoveUp => self.move_active_worklane_by(-1),
            AppCommandId::WorklaneMoveDown => self.move_active_worklane_by(1),
            AppCommandId::CloseFocusedPane => self.close_focused_pane(),
            AppCommandId::RestoreClosedPane => self.restore_closed_pane(),
            AppCommandId::DuplicateFocusedPane => self.duplicate_focused_pane(),
            AppCommandId::SplitHorizontally => self.split_focused_pane_right(),
            AppCommandId::ForceSplitRight => self.split_focused_pane_right_visibly(),
            AppCommandId::ForceAddPaneRight => self.add_focused_pane_right_without_resizing(),
            AppCommandId::SplitVertically => self.split_focused_pane_below(),
            AppCommandId::CloseWindow => self.request_close_window(),
            AppCommandId::NewWindow => self.request_new_window(),
            AppCommandId::MovePaneToNewWindow => self.request_move_pane_to_new_window(),
            AppCommandId::Find => self.focused_pane_result(|pane_id| {
                AppCommandExecutionResult::ShowPaneSearch { pane_id }
            }),
            AppCommandId::GlobalFind => AppCommandExecutionResult::ShowGlobalSearch,
            AppCommandId::UseSelectionForFind => self.focused_pane_result(|pane_id| {
                AppCommandExecutionResult::UseSelectionForFind { pane_id }
            }),
            AppCommandId::FindNext => {
                self.focused_pane_result(|pane_id| AppCommandExecutionResult::FindNext { pane_id })
            }
            AppCommandId::FindPrevious => self
                .focused_pane_result(|pane_id| AppCommandExecutionResult::FindPrevious { pane_id }),
            AppCommandId::CopyFocusedPanePath => self.copy_focused_pane_path(),
            AppCommandId::CleanCopy => AppCommandExecutionResult::CopySelection { mode: "clean" },
            AppCommandId::CopyRaw => AppCommandExecutionResult::CopySelection { mode: "raw" },
            AppCommandId::RenameCurrentWorklane => AppCommandExecutionResult::BeginRenameWorklane {
                worklane_id: self.worklane_id.clone(),
            },
            AppCommandId::JumpToLatestNotification => self.jump_to_latest_pane_notification(),
            AppCommandId::ToggleSidebar => AppCommandExecutionResult::ToggleSidebar,
            AppCommandId::ShowCommandPalette => AppCommandExecutionResult::ShowCommandPalette,
            AppCommandId::ShowTaskManager => AppCommandExecutionResult::ShowTaskManager,
            AppCommandId::OpenSettings => {
                AppCommandExecutionResult::ShowSettings { section: "general" }
            }
            AppCommandId::ReloadConfig => AppCommandExecutionResult::ReloadConfiguration,
            AppCommandId::OpenBookmarksPopover => AppCommandExecutionResult::OpenBookmarksPopover,
            AppCommandId::ToggleLightDarkTheme => AppCommandExecutionResult::SetThemeMode {
                mode: "toggleLightDark",
            },
            AppCommandId::UseDarkTheme => AppCommandExecutionResult::SetThemeMode { mode: "dark" },
            AppCommandId::UseLightTheme => {
                AppCommandExecutionResult::SetThemeMode { mode: "light" }
            }
            AppCommandId::UseAutoTheme => AppCommandExecutionResult::SetThemeMode { mode: "auto" },
            AppCommandId::ArrangeWidthFull
            | AppCommandId::ArrangeWidthHalves
            | AppCommandId::ArrangeWidthThirds
            | AppCommandId::ArrangeWidthQuarters
            | AppCommandId::ArrangeHeightFull
            | AppCommandId::ArrangeHeightTwoPerColumn
            | AppCommandId::ArrangeHeightThreePerColumn
            | AppCommandId::ArrangeHeightFourPerColumn
            | AppCommandId::ArrangeWidthGoldenFocusWide
            | AppCommandId::ArrangeWidthGoldenFocusNarrow
            | AppCommandId::ArrangeHeightGoldenFocusTall
            | AppCommandId::ArrangeHeightGoldenFocusShort
            | AppCommandId::ResizePaneLeft
            | AppCommandId::ResizePaneRight
            | AppCommandId::ResizePaneUp
            | AppCommandId::ResizePaneDown
            | AppCommandId::ResetPaneLayout => self.apply_layout_command(command_id),
            AppCommandId::OpenWithSelectedApp
            | AppCommandId::OpenSelectedServer
            | AppCommandId::OpenBranchOnRemote => {
                let mut window = self.desktop_window_snapshot();
                window.execute_command(command_id)
            }
        }
    }

    pub fn execute_app_command(&mut self, command_id: AppCommandId) -> DesktopCommandEffect {
        if let Some(effect) = self.confirmation_effect_for_command(command_id) {
            return effect;
        }
        let result = self.execute_command(command_id);
        self.apply_app_command_result(result)
    }

    pub fn execute_confirmed_app_command(
        &mut self,
        command_id: AppCommandId,
    ) -> DesktopCommandEffect {
        let result = self.execute_command(command_id);
        self.apply_app_command_result(result)
    }

    fn confirmation_effect_for_command(
        &self,
        command_id: AppCommandId,
    ) -> Option<DesktopCommandEffect> {
        match command_id {
            AppCommandId::CloseFocusedPane => self.close_focused_pane_confirmation_effect(),
            AppCommandId::CloseWindow => self.close_window_confirmation_effect(),
            _ => None,
        }
    }

    fn close_focused_pane_confirmation_effect(&self) -> Option<DesktopCommandEffect> {
        let pane = self.focused_pane()?;
        if self.panes.len() <= 1 {
            return self.close_window_confirmation_effect();
        }
        if !self.config.confirmations.confirm_before_closing_pane {
            return None;
        }
        Some(DesktopCommandEffect::ConfirmClosePane {
            pane_id: pane.pane_id.clone(),
            pane_title: pane.title.clone(),
        })
    }

    fn close_window_confirmation_effect(&self) -> Option<DesktopCommandEffect> {
        self.config
            .confirmations
            .confirm_before_closing_window
            .then(|| DesktopCommandEffect::ConfirmCloseWindow {
                window_id: self.window_id.clone(),
            })
    }

    pub fn terminate(&mut self) -> Result<(), PtyError> {
        for pane in &mut self.panes {
            pane.stream.terminate()?;
        }
        Ok(())
    }

    fn focused_pane(&self) -> Option<&DesktopPaneSession> {
        let focused_pane_id = self.focused_pane_id.as_deref()?;
        self.panes
            .iter()
            .find(|pane| pane.worklane_id == self.worklane_id && pane.pane_id == focused_pane_id)
    }

    /// Borrow the focused pane's terminal screen for styled grid rendering.
    pub fn focused_screen(&self) -> Option<&TerminalScreen> {
        Some(self.focused_pane()?.terminal.screen())
    }

    /// Render inputs for every pane in the current worklane (sorted by column
    /// then row), borrowing each pane's terminal screen + selection.
    pub fn worklane_pane_frames(&self) -> Vec<crate::render::PaneFrame<'_>> {
        self.panes
            .iter()
            .filter(|pane| pane.worklane_id == self.worklane_id)
            .map(|pane| crate::render::PaneFrame {
                layout: crate::render::layout::PaneLayoutInput {
                    column_index: pane.column_index,
                    pane_index: pane.pane_index,
                    column_width: pane.column_width,
                    pane_height: pane.pane_height.unwrap_or(1.0),
                },
                title: if pane.title.trim().is_empty() {
                    pane.pane_id.as_str()
                } else {
                    pane.title.as_str()
                },
                focused: self.focused_pane_id.as_deref() == Some(pane.pane_id.as_str()),
                screen: pane.terminal.screen(),
                selection: pane.selection.range(),
            })
            .collect()
    }

    /// Owned sidebar model for the renderer: worklane groups (active highlight +
    /// color dot) with indented pane rows and per-pane status pills. `None` when
    /// the sidebar is hidden.
    pub fn sidebar_render_model(&self) -> Option<crate::render::SidebarModel> {
        let snapshot = self.sidebar_snapshot();
        if !snapshot.is_visible {
            return None;
        }
        let worklanes = snapshot
            .worklanes
            .iter()
            .map(|worklane| {
                let panes = self
                    .panes
                    .iter()
                    .filter(|pane| pane.worklane_id == worklane.worklane_id)
                    .map(|pane| crate::render::SidebarPaneRow {
                        title: if pane.title.trim().is_empty() {
                            pane.pane_id.clone()
                        } else {
                            pane.title.clone()
                        },
                        focused: worklane.focused_pane_id.as_deref()
                            == Some(pane.pane_id.as_str()),
                        status: pane_status_kind(pane.shell_activity_state),
                    })
                    .collect();
                crate::render::SidebarWorklane {
                    title: worklane.title.clone(),
                    is_active: worklane.is_active,
                    color: worklane.color.as_deref().and_then(parse_hex_color),
                    panes,
                }
            })
            .collect();
        Some(crate::render::SidebarModel {
            width: snapshot.width as f32,
            worklanes,
        })
    }

    /// Owned overlay model for the renderer: the command palette if open, else
    /// the global-search HUD if open, else `None`.
    pub fn overlay_render_model(&self) -> Option<crate::render::Overlay> {
        if let Some(palette) = self.command_palette_snapshot() {
            let items = palette
                .items
                .into_iter()
                .map(|item| crate::render::PaletteItem {
                    title: item.title,
                    subtitle: item.subtitle,
                    category: item.category,
                    selected: item.is_selected,
                })
                .collect();
            return Some(crate::render::Overlay::Palette(crate::render::PaletteModel {
                query: palette.query,
                items,
            }));
        }
        if let Some(search) = self.global_search_snapshot() {
            return Some(crate::render::Overlay::GlobalSearch(crate::render::SearchModel {
                query: search.query,
                selected: search.selected_index,
                total: search.total,
            }));
        }
        None
    }

    /// Take and clear a pending bell across all panes (any pane's BEL flashes
    /// the window). Returns true if any pane rang the bell.
    pub fn take_any_bell(&mut self) -> bool {
        let mut bell = false;
        for pane in &mut self.panes {
            if pane.terminal.take_bell() {
                bell = true;
            }
        }
        bell
    }

    /// The window caption: the focused pane's (shell-set) title if non-empty,
    /// else the session window title.
    pub fn window_title(&self) -> String {
        self.focused_pane()
            .map(|pane| pane.title.trim().to_string())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| self.title.clone())
    }

    /// Screenshot tooling: set the sidebar hidden/visible WITHOUT persisting to
    /// config (the real `toggle_sidebar` writes the user's config file).
    #[doc(hidden)]
    pub fn set_sidebar_visible_for_screenshot(&mut self, visible: bool) {
        self.sidebar.visibility = if visible {
            SidebarVisibility::PinnedOpen
        } else {
            SidebarVisibility::Hidden
        };
    }

    /// Screenshot tooling: assign representative agent statuses so the sidebar
    /// shows distinct pills (first pane Working, the rest Ready).
    #[doc(hidden)]
    pub fn inject_screenshot_statuses(&mut self) {
        for (index, pane) in self.panes.iter_mut().enumerate() {
            pane.shell_activity_state = if index == 0 {
                TaskRunnerShellActivityState::CommandRunning
            } else {
                TaskRunnerShellActivityState::PromptIdle
            };
        }
    }


    fn focused_pane_mut(&mut self) -> Option<&mut DesktopPaneSession> {
        let focused_pane_id = self.focused_pane_id.as_deref()?;
        let focused_index = self.panes.iter().position(|pane| {
            pane.worklane_id == self.worklane_id && pane.pane_id == focused_pane_id
        })?;
        self.panes.get_mut(focused_index)
    }

    fn focused_index(&self) -> Option<usize> {
        let focused_pane_id = self.focused_pane_id.as_deref()?;
        self.panes.iter().position(|pane| {
            pane.worklane_id == self.worklane_id && pane.pane_id == focused_pane_id
        })
    }

    fn active_pane_indices(&self) -> Vec<usize> {
        self.panes
            .iter()
            .enumerate()
            .filter_map(|(index, pane)| (pane.worklane_id == self.worklane_id).then_some(index))
            .collect()
    }

    fn active_worklane_panes(&self) -> Vec<&DesktopPaneSession> {
        self.panes
            .iter()
            .filter(|pane| pane.worklane_id == self.worklane_id)
            .collect()
    }

    fn active_worklane_capture_input(
        &self,
        kind: WorkspaceTemplateKind,
        name: String,
    ) -> Option<WorkspaceTemplateCaptureInput> {
        let active_panes = self.active_worklane_panes();
        if active_panes.is_empty() {
            return None;
        }

        let mut panes_by_column: BTreeMap<usize, Vec<&DesktopPaneSession>> = BTreeMap::new();
        for pane in active_panes {
            panes_by_column
                .entry(pane.column_index)
                .or_default()
                .push(pane);
        }

        let focused_column_id = self
            .focused_pane()
            .map(|pane| pane.column_id.clone())
            .or_else(|| {
                panes_by_column
                    .values()
                    .next()
                    .and_then(|panes| panes.first())
                    .map(|pane| pane.column_id.clone())
            });
        let columns = panes_by_column
            .into_values()
            .map(|mut panes| {
                panes.sort_by_key(|pane| pane.pane_index);
                let focused_pane_id = panes
                    .iter()
                    .find(|pane| self.focused_pane_id.as_deref() == Some(pane.pane_id.as_str()))
                    .or_else(|| panes.first())
                    .map(|pane| pane.pane_id.clone());
                let pane_count = panes.len().max(1);
                WorkspaceTemplateCaptureColumn {
                    id: panes
                        .first()
                        .map(|pane| pane.column_id.clone())
                        .unwrap_or_else(|| "column-1".to_string()),
                    width: panes
                        .first()
                        .map(|pane| pane.column_width)
                        .unwrap_or(DESKTOP_DEFAULT_COLUMN_WIDTH),
                    focused_pane_id: focused_pane_id.clone(),
                    last_focused_pane_id: focused_pane_id,
                    pane_heights: panes
                        .iter()
                        .map(|pane| pane.pane_height.unwrap_or(1.0 / pane_count as f64))
                        .collect(),
                    panes: panes
                        .into_iter()
                        .map(|pane| WorkspaceTemplateCapturePane {
                            id: pane.pane_id.clone(),
                            title_seed: Some(pane.title.clone()),
                            working_directory: pane.terminal_request.working_directory.clone(),
                            command: pane
                                .terminal_request
                                .command
                                .clone()
                                .or_else(|| pane.restored_rerunnable_command.clone()),
                            environment: pane
                                .terminal_request
                                .environment_variables
                                .iter()
                                .cloned()
                                .collect(),
                        })
                        .collect(),
                }
            })
            .collect();

        Some(WorkspaceTemplateCaptureInput {
            name,
            kind,
            title: self.active_worklane_title().map(str::to_string),
            color: self.active_worklane_color().map(str::to_string),
            next_pane_number: next_pane_number_for_template_capture(&self.panes, &self.worklane_id),
            focused_column_id,
            columns,
        })
    }

    fn focused_pane_result(
        &self,
        result: fn(String) -> AppCommandExecutionResult,
    ) -> AppCommandExecutionResult {
        self.focused_pane()
            .map(|pane| result(pane.pane_id.clone()))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn show_command_palette(&mut self) {
        self.bookmarks = None;
        self.task_manager_snapshot = None;
        self.worklane_rename = None;
        self.settings = None;
        self.command_palette = Some(DesktopCommandPaletteState::default());
    }

    fn overlay_render_row_count(&self) -> usize {
        let mut rows = 0;
        if let Some(snapshot) = self.bookmarks_snapshot() {
            rows += snapshot.lines.len() + 1;
        }
        if let Some(snapshot) = self.task_manager_snapshot.as_ref() {
            rows += snapshot.lines.len() + 1;
        }
        if let Some(settings) = self.settings_snapshot() {
            rows += 1 + settings.lines.len() + 1;
        }
        if let Some(search) = self.global_search_snapshot() {
            rows += 2;
            if search.selected_index.is_some() {
                rows += 1;
            }
        }
        if let Some(search) = self.pane_search_snapshot() {
            rows += 2;
            if search.selected_index.is_some() {
                rows += 1;
            }
        }
        if self.worklane_rename.is_some() {
            rows += 2;
        }
        if let Some(palette) = self.command_palette_snapshot() {
            rows += 1 + palette.items.len() + 1;
        }
        rows
    }

    fn handle_command_palette_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => self.execute_selected_command_palette_item(),
            '\u{1b}' => {
                self.command_palette = None;
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                if let Some(state) = self.command_palette.as_mut() {
                    state.query.pop();
                    state.selected_index = 0;
                }
                DesktopCommandEffect::Repaint
            }
            ch if !ch.is_control() => {
                if let Some(state) = self.command_palette.as_mut() {
                    state.query.push(ch);
                    state.selected_index = 0;
                }
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_command_palette_key_event(
        &mut self,
        event: DesktopKeyEvent,
    ) -> Option<DesktopCommandEffect> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        match event.key {
            DesktopKey::DownArrow => Some(self.move_command_palette_selection(1)),
            DesktopKey::UpArrow => Some(self.move_command_palette_selection(-1)),
            _ => None,
        }
    }

    fn move_command_palette_selection(&mut self, delta: isize) -> DesktopCommandEffect {
        let item_count = self.command_palette_item_count();
        if item_count == 0 {
            return DesktopCommandEffect::Ignored;
        }
        if let Some(state) = self.command_palette.as_mut() {
            let current = state.selected_index.min(item_count.saturating_sub(1));
            state.selected_index =
                (current as isize + delta).rem_euclid(item_count as isize) as usize;
        }
        DesktopCommandEffect::Repaint
    }

    fn command_palette_item_count(&self) -> usize {
        let Some(state) = self.command_palette.as_ref() else {
            return 0;
        };
        self.desktop_window_snapshot()
            .resolve_command_palette(&state.query)
            .items
            .len()
    }

    fn execute_selected_command_palette_item(&mut self) -> DesktopCommandEffect {
        let Some(item_id) = self.selected_command_palette_item_id() else {
            self.command_palette = None;
            return DesktopCommandEffect::Status {
                message: "Command palette has no selectable item".to_string(),
            };
        };
        let confirmation_effect = self.confirmation_effect_for_palette_item(&item_id);
        self.command_palette = None;
        if let Some(effect) = confirmation_effect {
            return effect;
        }
        let result = self.execute_palette_item(&item_id);
        self.apply_palette_item_result(result)
    }

    fn confirmation_effect_for_palette_item(
        &self,
        item_id: &CommandPaletteItemId,
    ) -> Option<DesktopCommandEffect> {
        let CommandPaletteItemId::Command(command_id) = item_id else {
            return None;
        };
        AppCommandId::from_raw_value(command_id)
            .and_then(|command_id| self.confirmation_effect_for_command(command_id))
    }

    fn begin_worklane_rename(&mut self, worklane_id: String) -> DesktopCommandEffect {
        if !self.has_worklane(&worklane_id) {
            return DesktopCommandEffect::Status {
                message: format!("Rename worklane target missing: {worklane_id}"),
            };
        }
        let draft = self
            .worklane_title(&worklane_id)
            .map(str::to_string)
            .unwrap_or_else(|| self.default_worklane_title(&worklane_id));
        self.command_palette = None;
        self.global_search = None;
        self.pane_search = None;
        self.bookmarks = None;
        self.task_manager_snapshot = None;
        self.worklane_rename = Some(DesktopWorklaneRenameState { worklane_id, draft });
        DesktopCommandEffect::Repaint
    }

    fn handle_worklane_rename_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => self.finish_worklane_rename(),
            '\u{1b}' => {
                self.worklane_rename = None;
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                if let Some(state) = self.worklane_rename.as_mut() {
                    state.draft.pop();
                }
                DesktopCommandEffect::Repaint
            }
            ch if !ch.is_control() => {
                if let Some(state) = self.worklane_rename.as_mut() {
                    state.draft.push(ch);
                }
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn finish_worklane_rename(&mut self) -> DesktopCommandEffect {
        let Some(state) = self.worklane_rename.take() else {
            return DesktopCommandEffect::Ignored;
        };
        if !self.has_worklane(&state.worklane_id) {
            return DesktopCommandEffect::Status {
                message: format!("Rename worklane target missing: {}", state.worklane_id),
            };
        }
        if let Some(title) = normalized_worklane_title(Some(&state.draft)) {
            self.worklane_titles_by_id.insert(state.worklane_id, title);
        } else {
            self.worklane_titles_by_id.remove(&state.worklane_id);
        }
        DesktopCommandEffect::Repaint
    }

    fn selected_command_palette_item_id(&self) -> Option<CommandPaletteItemId> {
        let state = self.command_palette.as_ref()?;
        let results = self
            .desktop_window_snapshot()
            .resolve_command_palette(&state.query);
        let index = state
            .selected_index
            .min(results.items.len().saturating_sub(1));
        results.items.get(index).map(|item| item.item.id.clone())
    }

    fn execute_palette_item(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> CommandPaletteItemExecutionResult {
        if let CommandPaletteItemId::Command(command_id) = item_id {
            return AppCommandId::from_raw_value(command_id)
                .map(|command_id| self.execute_command(command_id).into())
                .unwrap_or(CommandPaletteItemExecutionResult::Unsupported);
        }
        if let CommandPaletteItemId::TaskRunner(id) = item_id {
            return self.run_task_runner(id);
        }

        let mut window = self.desktop_window_snapshot();
        let result = window.execute_palette_item(item_id);
        if matches!(
            result,
            CommandPaletteItemExecutionResult::Applied
                | CommandPaletteItemExecutionResult::SetWorklaneColor { .. }
        ) {
            self.apply_desktop_window_snapshot(window);
        }
        result
    }

    fn apply_app_command_result(
        &mut self,
        result: AppCommandExecutionResult,
    ) -> DesktopCommandEffect {
        match result {
            AppCommandExecutionResult::OpenBookmarksPopover => self.show_bookmarks_popover(),
            AppCommandExecutionResult::ShowTaskManager => self.show_task_manager(),
            AppCommandExecutionResult::ShowPaneSearch { pane_id } => self.show_pane_search(pane_id),
            AppCommandExecutionResult::ShowGlobalSearch => self.show_global_search(),
            AppCommandExecutionResult::UseSelectionForFind { pane_id } => {
                self.use_selection_for_find(pane_id)
            }
            AppCommandExecutionResult::FindNext { pane_id } => {
                if self.global_search.is_some() {
                    self.find_next_in_global_search()
                } else {
                    self.find_next_in_pane_search(&pane_id)
                }
            }
            AppCommandExecutionResult::FindPrevious { pane_id } => {
                if self.global_search.is_some() {
                    self.find_previous_in_global_search()
                } else {
                    self.find_previous_in_pane_search(&pane_id)
                }
            }
            AppCommandExecutionResult::ToggleSidebar => self.toggle_sidebar(),
            AppCommandExecutionResult::ShowCommandPalette => {
                self.show_command_palette();
                DesktopCommandEffect::Repaint
            }
            AppCommandExecutionResult::ShowSettings { section } => self.show_settings(section),
            AppCommandExecutionResult::BeginRenameWorklane { worklane_id } => {
                self.begin_worklane_rename(worklane_id)
            }
            AppCommandExecutionResult::ReloadConfiguration => self.reload_configuration_from_disk(),
            AppCommandExecutionResult::CopyText { text } => DesktopCommandEffect::CopyText {
                text,
                was_cleaned: false,
            },
            AppCommandExecutionResult::CopySelection { mode } => self.copy_focused_selection(mode),
            AppCommandExecutionResult::OpenPathWithTarget {
                path,
                target_id,
                target_name,
                app_path,
            } => {
                self.remember_open_with_primary_target(&target_id);
                DesktopCommandEffect::OpenPathWithTarget {
                    path,
                    target_id,
                    target_name,
                    app_path,
                }
            }
            AppCommandExecutionResult::OpenServer { url, .. } => self.server_open_effect(url, None),
            AppCommandExecutionResult::SetThemeMode { mode } => {
                self.set_theme_mode_from_command(mode)
            }
            AppCommandExecutionResult::SetWorklaneColor { .. } => DesktopCommandEffect::Repaint,
            other => desktop_command_effect(other),
        }
    }

    fn apply_palette_item_result(
        &mut self,
        result: CommandPaletteItemExecutionResult,
    ) -> DesktopCommandEffect {
        match result {
            CommandPaletteItemExecutionResult::OpenBookmarksPopover => {
                self.show_bookmarks_popover()
            }
            CommandPaletteItemExecutionResult::ShowTaskManager => self.show_task_manager(),
            CommandPaletteItemExecutionResult::ShowPaneSearch { pane_id } => {
                self.show_pane_search(pane_id)
            }
            CommandPaletteItemExecutionResult::ShowGlobalSearch => self.show_global_search(),
            CommandPaletteItemExecutionResult::UseSelectionForFind { pane_id } => {
                self.use_selection_for_find(pane_id)
            }
            CommandPaletteItemExecutionResult::FindNext { pane_id } => {
                if self.global_search.is_some() {
                    self.find_next_in_global_search()
                } else {
                    self.find_next_in_pane_search(&pane_id)
                }
            }
            CommandPaletteItemExecutionResult::FindPrevious { pane_id } => {
                if self.global_search.is_some() {
                    self.find_previous_in_global_search()
                } else {
                    self.find_previous_in_pane_search(&pane_id)
                }
            }
            CommandPaletteItemExecutionResult::ToggleSidebar => self.toggle_sidebar(),
            CommandPaletteItemExecutionResult::ShowCommandPalette => {
                self.show_command_palette();
                DesktopCommandEffect::Repaint
            }
            CommandPaletteItemExecutionResult::ShowSettings { section } => {
                self.show_settings(&section)
            }
            CommandPaletteItemExecutionResult::BeginRenameWorklane { worklane_id } => {
                self.begin_worklane_rename(worklane_id)
            }
            CommandPaletteItemExecutionResult::ReloadConfiguration => {
                self.reload_configuration_from_disk()
            }
            CommandPaletteItemExecutionResult::CopyText { text } => {
                DesktopCommandEffect::CopyText {
                    text,
                    was_cleaned: false,
                }
            }
            CommandPaletteItemExecutionResult::CopySelection { mode } => {
                self.copy_focused_selection(mode)
            }
            CommandPaletteItemExecutionResult::OpenTaskRunnerSource { source_path } => {
                DesktopCommandEffect::OpenPathWithTarget {
                    path: source_path,
                    target_id: "default".to_string(),
                    target_name: "Default App".to_string(),
                    app_path: None,
                }
            }
            CommandPaletteItemExecutionResult::OpenPathWithTarget {
                path,
                target_id,
                target_name,
                app_path,
            } => {
                self.remember_open_with_primary_target(&target_id);
                DesktopCommandEffect::OpenPathWithTarget {
                    path,
                    target_id,
                    target_name,
                    app_path,
                }
            }
            CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane { .. }
            | CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane { .. } => {
                DesktopCommandEffect::Repaint
            }
            CommandPaletteItemExecutionResult::RunRestoredCommand { pane_id, command } => {
                self.submit_command_to_pane(&pane_id, &command)
            }
            CommandPaletteItemExecutionResult::OpenServer { url, .. } => {
                self.server_open_effect(url, None)
            }
            CommandPaletteItemExecutionResult::SetThemeMode { mode } => {
                self.set_theme_mode_from_command(mode)
            }
            CommandPaletteItemExecutionResult::SetWorklaneColor { .. } => {
                DesktopCommandEffect::Repaint
            }
            other => desktop_palette_effect(other),
        }
    }

    fn server_open_effect(
        &self,
        url: String,
        requested_browser_id: Option<&str>,
    ) -> DesktopCommandEffect {
        let browser = self.server_browser_target_for_open(requested_browser_id);
        open_server_url_effect(&url, &browser)
    }

    fn show_pane_search(&mut self, pane_id: String) -> DesktopCommandEffect {
        self.bookmarks = None;
        self.task_manager_snapshot = None;
        self.global_search = None;
        self.worklane_rename = None;
        self.settings = None;
        if !self.panes.iter().any(|pane| pane.pane_id == pane_id) {
            return DesktopCommandEffect::Status {
                message: format!("Find requested for missing pane {pane_id}"),
            };
        }

        let replace_search = self
            .pane_search
            .as_ref()
            .is_none_or(|search| search.pane_id != pane_id);
        if replace_search {
            self.pane_search = Some(DesktopPaneSearchState {
                pane_id,
                session: TerminalSearchSession::new(),
            });
        }
        if let Some(search) = self.pane_search.as_mut() {
            search.session.show_search();
        }
        self.refresh_active_pane_search_matches();
        DesktopCommandEffect::Repaint
    }

    fn use_selection_for_find(&mut self, pane_id: String) -> DesktopCommandEffect {
        let Some(seed) = self
            .panes
            .iter()
            .find(|pane| pane.pane_id == pane_id)
            .and_then(|pane| pane.selection.search_seed(&pane.terminal.screen))
        else {
            return DesktopCommandEffect::Status {
                message: format!("No single-line selection for find in pane {pane_id}"),
            };
        };

        let effect = self.show_pane_search(pane_id);
        if !matches!(effect, DesktopCommandEffect::Repaint) {
            return effect;
        }
        self.update_pane_search_query(&seed)
    }

    fn copy_focused_selection(&self, mode: &'static str) -> DesktopCommandEffect {
        let Some(pane) = self.focused_pane() else {
            return DesktopCommandEffect::Status {
                message: "No focused pane selection to copy".to_string(),
            };
        };
        let copy_mode = match mode {
            "clean" => TerminalCopyMode::Clean,
            "raw" => TerminalCopyMode::Raw,
            _ => {
                return DesktopCommandEffect::Status {
                    message: format!("Unsupported copy mode: {mode}"),
                };
            }
        };
        let Some(content) =
            TerminalCopyPlanner::copy_selection(&pane.terminal.screen, &pane.selection, copy_mode)
        else {
            return DesktopCommandEffect::Status {
                message: "No focused pane selection to copy".to_string(),
            };
        };

        DesktopCommandEffect::CopyText {
            text: content.text,
            was_cleaned: content.was_cleaned,
        }
    }

    fn show_global_search(&mut self) -> DesktopCommandEffect {
        self.bookmarks = None;
        self.task_manager_snapshot = None;
        self.settings = None;
        let targets = self.global_search_targets();
        if targets.is_empty() {
            return DesktopCommandEffect::Status {
                message: "Global find unavailable".to_string(),
            };
        }

        self.pane_search = None;
        self.worklane_rename = None;
        self.global_search = Some(DesktopGlobalSearchState {
            coordinator: GlobalSearchCoordinator::new(targets),
            pane_searches: BTreeMap::new(),
        });
        let actions = self
            .global_search
            .as_mut()
            .map(|search| search.coordinator.update_query(""))
            .unwrap_or_default();
        self.apply_global_search_actions(actions);
        DesktopCommandEffect::Repaint
    }

    fn show_task_manager(&mut self) -> DesktopCommandEffect {
        self.command_palette = None;
        self.global_search = None;
        self.pane_search = None;
        self.bookmarks = None;
        self.worklane_rename = None;
        self.settings = None;
        let sources = self.task_manager_pane_sources();
        let snapshot = self.task_manager.snapshot(&sources, current_time_seconds());
        self.task_manager_snapshot = Some(DesktopTaskManagerTextSnapshot::from_snapshot(&snapshot));
        DesktopCommandEffect::Repaint
    }

    fn show_settings(&mut self, section: &str) -> DesktopCommandEffect {
        let section = settings_section_from_raw_value(section).unwrap_or(SettingsSection::General);
        self.command_palette = None;
        self.global_search = None;
        self.pane_search = None;
        self.bookmarks = None;
        self.worklane_rename = None;
        self.task_manager_snapshot = None;
        self.settings = Some(DesktopSettingsState {
            section: section.raw_value().to_string(),
            selected_index: 0,
        });
        DesktopCommandEffect::Repaint
    }

    fn handle_settings_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' | ' ' => self.activate_selected_settings_row(),
            '\u{1b}' => {
                self.settings = None;
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_settings_key_event(
        &mut self,
        event: DesktopKeyEvent,
    ) -> Option<DesktopCommandEffect> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        match event.key {
            DesktopKey::DownArrow => Some(self.move_settings_row(1)),
            DesktopKey::UpArrow => Some(self.move_settings_row(-1)),
            DesktopKey::RightArrow | DesktopKey::PageDown => Some(self.move_settings_section(1)),
            DesktopKey::LeftArrow | DesktopKey::PageUp => Some(self.move_settings_section(-1)),
            DesktopKey::Home => Some(self.move_settings_to_edge(false)),
            DesktopKey::End => Some(self.move_settings_to_edge(true)),
            _ => None,
        }
    }

    fn current_settings_section(&self) -> Option<SettingsSection> {
        self.settings
            .as_ref()
            .and_then(|state| settings_section_from_raw_value(&state.section))
    }

    fn clamp_settings_selection(&mut self) {
        let Some(section) = self.current_settings_section() else {
            return;
        };
        let row_count = self.settings_lines(section).len();
        if let Some(state) = self.settings.as_mut() {
            state.selected_index = state.selected_index.min(row_count.saturating_sub(1));
        }
    }

    fn move_settings_row(&mut self, delta: isize) -> DesktopCommandEffect {
        let Some(section) = self.current_settings_section() else {
            return DesktopCommandEffect::Ignored;
        };
        let row_count = self.settings_lines(section).len();
        if row_count == 0 {
            return DesktopCommandEffect::Ignored;
        }
        let Some(state) = self.settings.as_mut() else {
            return DesktopCommandEffect::Ignored;
        };
        let current = state.selected_index.min(row_count - 1);
        let next = current
            .saturating_add_signed(delta)
            .min(row_count.saturating_sub(1));
        if next == state.selected_index {
            return DesktopCommandEffect::Ignored;
        }
        state.selected_index = next;
        DesktopCommandEffect::Repaint
    }

    fn move_settings_section(&mut self, delta: isize) -> DesktopCommandEffect {
        let Some(section) = self.current_settings_section() else {
            return DesktopCommandEffect::Ignored;
        };
        let Some(current_index) = SettingsSection::ALL
            .iter()
            .position(|candidate| *candidate == section)
        else {
            return DesktopCommandEffect::Ignored;
        };
        let next_index = current_index
            .saturating_add_signed(delta)
            .min(SettingsSection::ALL.len().saturating_sub(1));
        if next_index == current_index {
            return DesktopCommandEffect::Ignored;
        }
        if let Some(state) = self.settings.as_mut() {
            state.section = SettingsSection::ALL[next_index].raw_value().to_string();
            state.selected_index = 0;
        }
        DesktopCommandEffect::Repaint
    }

    fn move_settings_to_edge(&mut self, end: bool) -> DesktopCommandEffect {
        let Some(section) = self.current_settings_section() else {
            return DesktopCommandEffect::Ignored;
        };
        let row_count = self.settings_lines(section).len();
        if row_count == 0 {
            return DesktopCommandEffect::Ignored;
        }
        let target = if end { row_count - 1 } else { 0 };
        let Some(state) = self.settings.as_mut() else {
            return DesktopCommandEffect::Ignored;
        };
        if state.selected_index == target {
            return DesktopCommandEffect::Ignored;
        }
        state.selected_index = target;
        DesktopCommandEffect::Repaint
    }

    fn activate_selected_settings_row(&mut self) -> DesktopCommandEffect {
        let Some(section) = self.current_settings_section() else {
            return DesktopCommandEffect::Ignored;
        };
        let selected_index = self
            .settings
            .as_ref()
            .map(|state| state.selected_index)
            .unwrap_or_default();

        match (section, selected_index) {
            (SettingsSection::General, 0) => self.persist_settings_config_update(|config| {
                config.sidebar.visibility = config.sidebar.visibility.toggle();
            }),
            (SettingsSection::General, 1) => self.persist_settings_config_update(|config| {
                config.restore.restore_workspace_on_launch =
                    !config.restore.restore_workspace_on_launch;
            }),
            (SettingsSection::General, 2) => self.persist_settings_config_update(|config| {
                config.confirmations.confirm_before_closing_pane =
                    !config.confirmations.confirm_before_closing_pane;
            }),
            (SettingsSection::General, 3) => self.persist_settings_config_update(|config| {
                config.confirmations.confirm_before_closing_window =
                    !config.confirmations.confirm_before_closing_window;
            }),
            (SettingsSection::General, 4) => self.persist_settings_config_update(|config| {
                config.confirmations.confirm_before_quitting =
                    !config.confirmations.confirm_before_quitting;
            }),
            (SettingsSection::General, 5) => self.persist_settings_config_update(|config| {
                config.clipboard.always_clean_copies = !config.clipboard.always_clean_copies;
            }),
            (SettingsSection::Appearance, 0) => self.persist_settings_config_update(|config| {
                config.appearance.theme_mode = next_theme_mode(config.appearance.theme_mode);
            }),
            (SettingsSection::Appearance, 4) => self.persist_settings_config_update(|config| {
                config.appearance.sync_opencode_theme_with_terminal =
                    !config.appearance.sync_opencode_theme_with_terminal;
            }),
            (SettingsSection::Shortcuts, 1) => {
                if self.config.shortcuts.bindings.is_empty() {
                    DesktopCommandEffect::Ignored
                } else {
                    self.persist_settings_config_update(|config| {
                        config.shortcuts.bindings.clear();
                    })
                }
            }
            (SettingsSection::Shortcuts, 2) => {
                self.apply_shortcut_preset(DesktopShortcutPreset::LeftHand)
            }
            (SettingsSection::Shortcuts, 3) => {
                self.apply_shortcut_preset(DesktopShortcutPreset::RightHand)
            }
            (SettingsSection::Notifications, 0) => self.persist_settings_config_update(|config| {
                config.notifications.sound_name =
                    next_notification_sound_name(&config.notifications.sound_name);
                if !is_custom_notification_sound_name(&config.notifications.sound_name) {
                    config.notifications.custom_sound_display_name = None;
                }
            }),
            (SettingsSection::Notifications, 1) => {
                if !is_custom_notification_sound_name(&self.config.notifications.sound_name)
                    && self
                        .config
                        .notifications
                        .custom_sound_display_name
                        .is_none()
                {
                    DesktopCommandEffect::Ignored
                } else {
                    self.persist_settings_config_update(|config| {
                        config.notifications.sound_name = String::new();
                        config.notifications.custom_sound_display_name = None;
                    })
                }
            }
            (SettingsSection::Notifications, 2) => DesktopCommandEffect::OpenUrl {
                url: WINDOWS_NOTIFICATION_SETTINGS_URL.to_string(),
            },
            (SettingsSection::Notifications, 3) => self.send_test_notification(),
            (SettingsSection::OpenWith, 0) => {
                let next_target_id = next_open_with_primary_target_id(
                    &self.config.open_with.primary_target_id,
                    &self.config.open_with.enabled_target_ids,
                    &self.available_open_with_targets,
                );
                if let Some(target_id) = next_target_id {
                    self.persist_settings_config_update(|config| {
                        config.open_with.primary_target_id = target_id;
                    })
                } else {
                    DesktopCommandEffect::Ignored
                }
            }
            (SettingsSection::OpenWith, index) => {
                let Some(target) = self.available_open_with_targets.get(index - 1) else {
                    return DesktopCommandEffect::Ignored;
                };
                let target_id = target.stable_id.clone();
                let available_order = self
                    .available_open_with_targets
                    .iter()
                    .map(|target| target.stable_id.clone())
                    .collect::<Vec<_>>();
                self.persist_settings_config_update(|config| {
                    toggle_open_with_target(config, &target_id, &available_order);
                })
            }
            (SettingsSection::DevServers, 0) => self.persist_settings_config_update(|config| {
                config.server_detection.passive_detection_enabled =
                    !config.server_detection.passive_detection_enabled;
            }),
            (SettingsSection::DevServers, 1) => {
                let target_id = next_server_browser_preferred_target_id(
                    &self.config.server_detection.preferred_browser_id,
                    &self.config.server_detection.enabled_browser_target_ids,
                    &self.available_server_browser_targets,
                );
                self.persist_settings_config_update(|config| {
                    config.server_detection.preferred_browser_id = target_id;
                })
            }
            (SettingsSection::DevServers, index)
                if index >= 2 && index < self.available_server_browser_targets.len() + 2 =>
            {
                let Some(target) = self.available_server_browser_targets.get(index - 2) else {
                    return DesktopCommandEffect::Ignored;
                };
                let target_id = target.stable_id.clone();
                let available_order = self
                    .available_server_browser_targets
                    .iter()
                    .map(|target| target.stable_id.clone())
                    .collect::<Vec<_>>();
                self.persist_settings_config_update(|config| {
                    toggle_server_browser_target(config, &target_id, &available_order);
                })
            }
            (SettingsSection::PaneLayout, 0) => self.persist_settings_config_update(|config| {
                config.pane_layout.right_split_behavior =
                    next_pane_split_behavior(config.pane_layout.right_split_behavior);
            }),
            (SettingsSection::PaneLayout, 1) => self.persist_settings_config_update(|config| {
                config.pane_layout.visible_split_window_width =
                    next_visible_split_window_width(config.pane_layout.visible_split_window_width);
            }),
            (SettingsSection::PaneLayout, 2) => self.persist_settings_config_update(|config| {
                config.worklanes.new_worklane_placement =
                    next_worklane_placement(config.worklanes.new_worklane_placement);
            }),
            (SettingsSection::PaneLayout, 3) => self.persist_settings_config_update(|config| {
                config.panes.show_labels = !config.panes.show_labels;
            }),
            (SettingsSection::PaneLayout, 4) => self.persist_settings_config_update(|config| {
                config.panes.show_project_icons = !config.panes.show_project_icons;
            }),
            (SettingsSection::PaneLayout, 5) => self.persist_settings_config_update(|config| {
                config.panes.smooth_scrolling_enabled = !config.panes.smooth_scrolling_enabled;
            }),
            (SettingsSection::PaneLayout, 6) => self.persist_settings_config_update(|config| {
                config.panes.focus_follows_mouse = !config.panes.focus_follows_mouse;
            }),
            (SettingsSection::PaneLayout, 7) => self.persist_settings_config_update(|config| {
                config.panes.focus_follows_mouse_delay =
                    next_focus_follows_mouse_delay(config.panes.focus_follows_mouse_delay);
            }),
            (SettingsSection::PaneLayout, 8) => self.persist_settings_config_update(|config| {
                config.panes.inactive_opacity =
                    next_inactive_pane_opacity(config.panes.inactive_opacity);
            }),
            (SettingsSection::UpdatesPrivacy, 0) => self.persist_settings_config_update(|config| {
                config.updates.channel = next_update_channel(config.updates.channel);
            }),
            (SettingsSection::UpdatesPrivacy, 1) => self.persist_settings_config_update(|config| {
                config.error_reporting.enabled = !config.error_reporting.enabled;
            }),
            (SettingsSection::UpdatesPrivacy, 2) => self.persist_settings_config_update(|config| {
                config.menu_bar.show_status_item = !config.menu_bar.show_status_item;
            }),
            (SettingsSection::Agents, 0) => self.persist_settings_config_update(|config| {
                config.agent_caffeination.enabled = !config.agent_caffeination.enabled;
            }),
            (SettingsSection::Agents, 1) => self.persist_settings_config_update(|config| {
                config.agent_teams.enabled = !config.agent_teams.enabled;
            }),
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn persist_settings_config_update<F>(&mut self, updater: F) -> DesktopCommandEffect
    where
        F: FnOnce(&mut AppConfig),
    {
        self.persist_live_config_effect(updater)
    }

    fn apply_shortcut_preset(&mut self, preset: DesktopShortcutPreset) -> DesktopCommandEffect {
        let bindings = shortcut_preset_bindings(preset);
        self.persist_settings_config_update(move |config| {
            config.shortcuts.bindings = bindings;
        })
    }

    fn send_test_notification(&self) -> DesktopCommandEffect {
        let Some(pane) = self.focused_pane() else {
            return DesktopCommandEffect::Status {
                message: "No focused pane for test notification".to_string(),
            };
        };

        DesktopCommandEffect::PaneNotification {
            notification: PaneNotification {
                title: "Zentty".to_string(),
                subtitle: Some("Settings".to_string()),
                body: Some("This is a test notification.".to_string()),
                include_inbox: false,
                is_silent: false,
                window_id: self.window_id.clone(),
                worklane_id: pane.worklane_id.clone(),
                pane_id: pane.pane_id.clone(),
            },
        }
    }

    fn show_bookmarks_popover(&mut self) -> DesktopCommandEffect {
        self.command_palette = None;
        self.global_search = None;
        self.pane_search = None;
        self.task_manager_snapshot = None;
        self.worklane_rename = None;
        self.settings = None;
        self.bookmarks = None;
        let store = match BookmarkStore::load(self.bookmarks_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmarks unavailable: {error}"),
                };
            }
        };
        self.bookmarks = Some(DesktopBookmarksState::new(store.templates().to_vec()));
        DesktopCommandEffect::Repaint
    }

    fn handle_bookmarks_char(&mut self, ch: char) -> DesktopCommandEffect {
        if self
            .bookmarks
            .as_ref()
            .is_some_and(DesktopBookmarksState::is_renaming)
        {
            return self.handle_bookmark_rename_char(ch);
        }
        if self
            .bookmarks
            .as_ref()
            .is_some_and(DesktopBookmarksState::is_saving)
        {
            return self.handle_bookmark_save_char(ch);
        }

        match ch {
            '\r' | '\n' => self.activate_selected_bookmark_template(),
            '\u{1b}' => {
                self.bookmarks = None;
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.pop_query_char();
                }
                DesktopCommandEffect::Repaint
            }
            ch if !ch.is_control() => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.push_query_char(ch);
                }
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_bookmark_save_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => self.finish_bookmark_save(),
            '\u{1b}' => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.cancel_save();
                }
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.pop_save_char();
                }
                DesktopCommandEffect::Repaint
            }
            ch if !ch.is_control() => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.push_save_char(ch);
                }
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_bookmark_rename_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => self.finish_bookmark_rename(),
            '\u{1b}' => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.cancel_rename();
                }
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.pop_rename_char();
                }
                DesktopCommandEffect::Repaint
            }
            ch if !ch.is_control() => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.push_rename_char(ch);
                }
                DesktopCommandEffect::Repaint
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_bookmarks_key_event(
        &mut self,
        event: DesktopKeyEvent,
    ) -> Option<DesktopCommandEffect> {
        if self
            .bookmarks
            .as_ref()
            .is_some_and(DesktopBookmarksState::is_editing_name)
        {
            return Some(DesktopCommandEffect::Ignored);
        }

        if event.modifiers.control && !event.modifiers.alt && !event.modifiers.shift {
            return match event.key {
                DesktopKey::Character('p') | DesktopKey::Character('P') => {
                    Some(self.toggle_selected_bookmark_pin())
                }
                DesktopKey::Character('d') | DesktopKey::Character('D') => {
                    Some(self.duplicate_selected_bookmark_template())
                }
                DesktopKey::Character('t') | DesktopKey::Character('T') => {
                    Some(self.convert_selected_bookmark_template())
                }
                DesktopKey::Character('o') | DesktopKey::Character('O') => {
                    Some(self.reveal_selected_bookmark_template())
                }
                DesktopKey::Character('r') | DesktopKey::Character('R') => {
                    Some(self.begin_rename_selected_bookmark_template())
                }
                DesktopKey::Character('e') | DesktopKey::Character('E') => {
                    Some(self.export_selected_bookmark_template())
                }
                DesktopKey::Character('b') | DesktopKey::Character('B') => {
                    Some(self.begin_save_active_worklane_bookmark())
                }
                DesktopKey::Character('s') | DesktopKey::Character('S') => {
                    Some(self.begin_save_active_worklane_preset())
                }
                _ => None,
            };
        }

        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        match event.key {
            DesktopKey::DownArrow => Some(self.move_bookmark_selection(1)),
            DesktopKey::UpArrow => Some(self.move_bookmark_selection(-1)),
            DesktopKey::Delete => Some(self.delete_selected_bookmark_template()),
            _ => None,
        }
    }

    fn move_bookmark_selection(&mut self, delta: isize) -> DesktopCommandEffect {
        let Some(state) = self.bookmarks.as_mut() else {
            return DesktopCommandEffect::Ignored;
        };
        if state.move_selection(delta) {
            DesktopCommandEffect::Repaint
        } else {
            DesktopCommandEffect::Ignored
        }
    }

    fn begin_save_active_worklane_bookmark(&mut self) -> DesktopCommandEffect {
        self.begin_save_active_worklane_template(WorkspaceTemplateKind::Bookmark)
    }

    fn begin_save_active_worklane_preset(&mut self) -> DesktopCommandEffect {
        self.begin_save_active_worklane_template(WorkspaceTemplateKind::Preset)
    }

    fn begin_save_active_worklane_template(
        &mut self,
        kind: WorkspaceTemplateKind,
    ) -> DesktopCommandEffect {
        let Some(name) = self.suggested_active_worklane_template_name(kind) else {
            return DesktopCommandEffect::Status {
                message: "No active worklane to save".to_string(),
            };
        };
        let Some(state) = self.bookmarks.as_mut() else {
            return DesktopCommandEffect::Ignored;
        };
        state.begin_save(kind, name);
        DesktopCommandEffect::Repaint
    }

    fn finish_bookmark_save(&mut self) -> DesktopCommandEffect {
        let Some((kind, draft)) = self
            .bookmarks
            .as_mut()
            .and_then(DesktopBookmarksState::take_save_request)
        else {
            return DesktopCommandEffect::Ignored;
        };
        if trimmed_non_empty(&draft).is_none() {
            return DesktopCommandEffect::Repaint;
        }
        let template = match self.save_active_worklane_template(kind, draft) {
            Ok(Some(template)) => template,
            Ok(None) => {
                return DesktopCommandEffect::Status {
                    message: "No active worklane to save".to_string(),
                };
            }
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmark save failed: {error}"),
                };
            }
        };
        match BookmarkStore::load(self.bookmarks_path.clone()) {
            Ok(store) => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.replace_templates(store.templates().to_vec(), Some(&template.id));
                }
                DesktopCommandEffect::Repaint
            }
            Err(error) => DesktopCommandEffect::Status {
                message: format!("Bookmarks unavailable: {error}"),
            },
        }
    }

    fn begin_rename_selected_bookmark_template(&mut self) -> DesktopCommandEffect {
        let Some(state) = self.bookmarks.as_mut() else {
            return DesktopCommandEffect::Ignored;
        };
        if state.begin_rename_selected().is_some() {
            DesktopCommandEffect::Repaint
        } else {
            DesktopCommandEffect::Status {
                message: "No bookmark or preset selected to rename".to_string(),
            }
        }
    }

    fn finish_bookmark_rename(&mut self) -> DesktopCommandEffect {
        let Some((template_id, draft)) = self
            .bookmarks
            .as_mut()
            .and_then(DesktopBookmarksState::take_rename_request)
        else {
            return DesktopCommandEffect::Ignored;
        };
        let mut store = match BookmarkStore::load(self.bookmarks_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmarks unavailable: {error}"),
                };
            }
        };
        match store.rename(&template_id, &draft) {
            Ok(_) => {
                if let Some(state) = self.bookmarks.as_mut() {
                    state.replace_templates(store.templates().to_vec(), Some(&template_id));
                }
                DesktopCommandEffect::Repaint
            }
            Err(error) => DesktopCommandEffect::Status {
                message: format!("Bookmark rename failed: {error}"),
            },
        }
    }

    fn toggle_selected_bookmark_pin(&mut self) -> DesktopCommandEffect {
        self.mutate_selected_bookmark_template("toggle pin", |store, template| {
            store.set_pinned(&template.id, !template.pinned)?;
            Ok(Some(template.id.clone()))
        })
    }

    fn duplicate_selected_bookmark_template(&mut self) -> DesktopCommandEffect {
        self.mutate_selected_bookmark_template("duplicate", |store, template| {
            let copy = store.duplicate(&template.id)?;
            Ok(copy.map(|template| template.id))
        })
    }

    fn delete_selected_bookmark_template(&mut self) -> DesktopCommandEffect {
        self.mutate_selected_bookmark_template("delete", |store, template| {
            store.delete(&template.id)?;
            Ok(None)
        })
    }

    fn convert_selected_bookmark_template(&mut self) -> DesktopCommandEffect {
        let Some(template) = self
            .bookmarks
            .as_ref()
            .and_then(DesktopBookmarksState::selected_template)
        else {
            return DesktopCommandEffect::Status {
                message: "No bookmark or preset selected to convert".to_string(),
            };
        };

        match template.kind {
            WorkspaceTemplateKind::Bookmark => {
                self.mutate_selected_bookmark_template("convert", |store, template| {
                    let converted =
                        template.fresh_preset_copy(converted_preset_name(&template.name));
                    let converted_id = converted.id.clone();
                    store.upsert(converted)?;
                    Ok(Some(converted_id))
                })
            }
            WorkspaceTemplateKind::Preset => self.convert_selected_preset_to_bookmark(&template),
        }
    }

    fn convert_selected_preset_to_bookmark(
        &mut self,
        template: &WorkspaceTemplate,
    ) -> DesktopCommandEffect {
        let Some(mut converted) = self.capture_active_worklane_template(
            WorkspaceTemplateKind::Bookmark,
            converted_bookmark_name(&template.name),
        ) else {
            return DesktopCommandEffect::Status {
                message: "No active worklane to bookmark".to_string(),
            };
        };
        converted.color = template.color.clone();
        let converted_id = converted.id.clone();
        let mut store = match BookmarkStore::load(self.bookmarks_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmarks unavailable: {error}"),
                };
            }
        };
        if let Err(error) = store.upsert(converted) {
            return DesktopCommandEffect::Status {
                message: format!("Bookmark convert failed: {error}"),
            };
        }
        if let Some(state) = self.bookmarks.as_mut() {
            state.replace_templates(store.templates().to_vec(), Some(&converted_id));
        }
        DesktopCommandEffect::Repaint
    }

    fn reveal_selected_bookmark_template(&self) -> DesktopCommandEffect {
        let Some(template) = self
            .bookmarks
            .as_ref()
            .and_then(DesktopBookmarksState::selected_template)
        else {
            return DesktopCommandEffect::Status {
                message: "No bookmark or preset selected to reveal".to_string(),
            };
        };
        let Some(path) = bookmark_reveal_path(&template) else {
            return DesktopCommandEffect::Status {
                message: format!("Bookmark has no path to reveal: {}", template.name),
            };
        };
        DesktopCommandEffect::OpenPathWithTarget {
            path,
            target_id: "default".to_string(),
            target_name: "Default App".to_string(),
            app_path: None,
        }
    }

    fn export_selected_bookmark_template(&self) -> DesktopCommandEffect {
        let Some(template) = self
            .bookmarks
            .as_ref()
            .and_then(DesktopBookmarksState::selected_template)
        else {
            return DesktopCommandEffect::Status {
                message: "No bookmark or preset selected to export".to_string(),
            };
        };
        let path = default_bookmark_export_path(&self.bookmarks_path, &template.name);
        match WorkspaceTemplateExporter::write(&template, &path) {
            Ok(()) => DesktopCommandEffect::Status {
                message: format!("Exported preset: {}", path.display()),
            },
            Err(error) => DesktopCommandEffect::Status {
                message: format!("Bookmark export failed: {error}"),
            },
        }
    }

    fn mutate_selected_bookmark_template<F>(
        &mut self,
        action: &str,
        mutate: F,
    ) -> DesktopCommandEffect
    where
        F: FnOnce(&mut BookmarkStore, &WorkspaceTemplate) -> io::Result<Option<String>>,
    {
        let Some(template) = self
            .bookmarks
            .as_ref()
            .and_then(DesktopBookmarksState::selected_template)
        else {
            return DesktopCommandEffect::Status {
                message: format!("No bookmark or preset selected to {action}"),
            };
        };
        let mut store = match BookmarkStore::load(self.bookmarks_path.clone()) {
            Ok(store) => store,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmarks unavailable: {error}"),
                };
            }
        };
        let preferred_selected_id = match mutate(&mut store, &template) {
            Ok(preferred) => preferred,
            Err(error) => {
                return DesktopCommandEffect::Status {
                    message: format!("Bookmark {action} failed: {error}"),
                };
            }
        };
        if let Some(state) = self.bookmarks.as_mut() {
            state.replace_templates(store.templates().to_vec(), preferred_selected_id.as_deref());
        }
        DesktopCommandEffect::Repaint
    }

    fn activate_selected_bookmark_template(&mut self) -> DesktopCommandEffect {
        let Some(template) = self
            .bookmarks
            .as_ref()
            .and_then(DesktopBookmarksState::selected_template)
        else {
            return DesktopCommandEffect::Status {
                message: "No bookmark or preset selected".to_string(),
            };
        };

        match self.restore_bookmark_template_as_worklane(&template) {
            Ok(()) => {
                self.bookmarks = None;
                match self.record_bookmark_use(&template.id) {
                    Ok(()) => DesktopCommandEffect::Repaint,
                    Err(error) => DesktopCommandEffect::Status {
                        message: format!("Bookmark restored but recency was not saved: {error}"),
                    },
                }
            }
            Err(message) => DesktopCommandEffect::Status { message },
        }
    }

    fn record_bookmark_use(&self, template_id: &str) -> io::Result<()> {
        let mut store = BookmarkStore::load(self.bookmarks_path.clone())?;
        store.record_use(template_id)?;
        Ok(())
    }

    fn restore_bookmark_template_as_worklane(
        &mut self,
        template: &WorkspaceTemplate,
    ) -> Result<(), String> {
        let worklane_id = next_desktop_worklane_id(&self.worklane_order);
        let fallback_working_directory = (template.kind == WorkspaceTemplateKind::Preset)
            .then(|| self.focused_pane_path().map(str::to_string))
            .flatten();
        let (specs, focused_pane_id) = self.bookmark_template_launch_specs(
            template,
            &worklane_id,
            fallback_working_directory.as_deref(),
        );
        if specs.is_empty() {
            return Err(format!("Bookmark has no panes: {}", template.name));
        }

        let mut sessions = Vec::with_capacity(specs.len());
        for spec in &specs {
            match self.spawn_pane_session(spec) {
                Ok(session) => sessions.push(session),
                Err(error) => {
                    for session in &mut sessions {
                        let _ = session.stream.terminate();
                    }
                    return Err(format!("Bookmark restore failed: {error}"));
                }
            }
        }

        let insertion_index = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == &self.worklane_id)
            .map(|index| index + 1)
            .unwrap_or(self.worklane_order.len());
        self.worklane_order
            .insert(insertion_index, worklane_id.clone());
        self.focused_pane_id_by_worklane_id
            .insert(worklane_id.clone(), focused_pane_id.clone());
        if let Some(title) = normalized_worklane_title(template.title.as_deref()) {
            self.worklane_titles_by_id
                .insert(worklane_id.clone(), title);
        }
        if let Some(color) = template
            .color
            .as_deref()
            .and_then(WorklaneColor::from_raw_value)
        {
            self.worklane_colors_by_id
                .insert(worklane_id, color.raw_value().to_string());
        }

        self.panes.extend(sessions);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&focused_pane_id, true);
        Ok(())
    }

    fn bookmark_template_launch_specs(
        &self,
        template: &WorkspaceTemplate,
        worklane_id: &str,
        fallback_working_directory: Option<&str>,
    ) -> (Vec<PaneLaunchSpec>, String) {
        let mut specs = Vec::new();
        let mut reserved_pane_ids = HashSet::new();
        let focused_coordinates = template_focused_pane_coordinates(template);

        if template.pane_count() == 0 {
            let pane_id = next_desktop_pane_id_with_reserved(&self.panes, &reserved_pane_ids);
            reserved_pane_ids.insert(pane_id.clone());
            let title = trimmed_non_empty(template.title.as_deref().unwrap_or(""))
                .or_else(|| trimmed_non_empty(&template.name))
                .unwrap_or("shell")
                .to_string();
            let spec = self.bookmark_template_pane_launch_spec(
                worklane_id,
                &pane_id,
                &format!("{worklane_id}-column-1"),
                0,
                0,
                DESKTOP_DEFAULT_COLUMN_WIDTH,
                None,
                &title,
                template
                    .project_root
                    .as_deref()
                    .or(fallback_working_directory),
                None,
                &BTreeMap::new(),
            );
            return (vec![spec], pane_id);
        }

        let mut focused_pane_id = None;
        for (column_index, column) in template.columns.iter().enumerate() {
            let column_id = format!("{worklane_id}-column-{}", column_index + 1);
            for (pane_index, pane) in column.panes.iter().enumerate() {
                let pane_id = next_desktop_pane_id_with_reserved(&self.panes, &reserved_pane_ids);
                reserved_pane_ids.insert(pane_id.clone());
                if focused_coordinates == Some((column_index, pane_index)) {
                    focused_pane_id = Some(pane_id.clone());
                }
                specs.push(
                    self.bookmark_template_pane_launch_spec(
                        worklane_id,
                        &pane_id,
                        &column_id,
                        column_index,
                        pane_index,
                        template_column_width(column),
                        column.pane_heights.get(pane_index).copied(),
                        trimmed_non_empty(pane.title_seed.as_deref().unwrap_or(""))
                            .unwrap_or("shell"),
                        pane.working_directory
                            .as_deref()
                            .and_then(trimmed_non_empty)
                            .or(fallback_working_directory),
                        pane.command.as_deref().and_then(trimmed_non_empty),
                        &pane.environment,
                    ),
                );
            }
        }

        let focused = focused_pane_id
            .or_else(|| specs.first().map(|spec| spec.pane_id.clone()))
            .unwrap_or_default();
        (specs, focused)
    }

    #[allow(clippy::too_many_arguments)]
    fn bookmark_template_pane_launch_spec(
        &self,
        worklane_id: &str,
        pane_id: &str,
        column_id: &str,
        column_index: usize,
        pane_index: usize,
        column_width: f64,
        pane_height: Option<f64>,
        title: &str,
        requested_working_directory: Option<&str>,
        saved_command: Option<&str>,
        environment: &BTreeMap<String, String>,
    ) -> PaneLaunchSpec {
        let (working_directory, did_fall_back_for_working_directory) =
            resolved_template_working_directory(requested_working_directory);
        let command_on_path = saved_command
            .map(desktop_template_command_is_available)
            .unwrap_or(false);
        let mut terminal_request = TerminalSessionRequest {
            working_directory,
            ..Default::default()
        };
        if command_on_path {
            terminal_request.command = saved_command.map(str::to_string);
        } else {
            terminal_request.prefill_text = saved_command.map(str::to_string);
        }
        terminal_request.environment_variables = template_safe_environment_overrides(environment)
            .into_iter()
            .collect();

        PaneLaunchSpec {
            pane_id: pane_id.to_string(),
            worklane_id: worklane_id.to_string(),
            column_id: column_id.to_string(),
            column_index,
            pane_index,
            title: title.to_string(),
            column_width,
            pane_height,
            terminal_request,
            restored_rerunnable_command: None,
            status_text: did_fall_back_for_working_directory
                .then(|| "Original path unavailable".to_string()),
            applied_restore_draft_tool: None,
        }
    }

    fn handle_global_search_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => self.find_next_in_global_search(),
            '\u{1b}' => {
                let actions = self
                    .global_search
                    .as_mut()
                    .map(|search| search.coordinator.end())
                    .unwrap_or_default();
                self.apply_global_search_actions(actions);
                self.global_search = None;
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                let Some(mut query) = self
                    .global_search
                    .as_ref()
                    .map(|search| search.coordinator.state().needle.clone())
                else {
                    return DesktopCommandEffect::Ignored;
                };
                query.pop();
                self.update_global_search_query(&query)
            }
            ch if !ch.is_control() => {
                let Some(mut query) = self
                    .global_search
                    .as_ref()
                    .map(|search| search.coordinator.state().needle.clone())
                else {
                    return DesktopCommandEffect::Ignored;
                };
                query.push(ch);
                self.update_global_search_query(&query)
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_global_search_key_event(
        &mut self,
        event: DesktopKeyEvent,
    ) -> Option<DesktopCommandEffect> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        match event.key {
            DesktopKey::DownArrow => Some(self.find_next_in_global_search()),
            DesktopKey::UpArrow => Some(self.find_previous_in_global_search()),
            _ => None,
        }
    }

    fn update_global_search_query(&mut self, query: &str) -> DesktopCommandEffect {
        let actions = self
            .global_search
            .as_mut()
            .map(|search| search.coordinator.update_query(query))
            .unwrap_or_default();
        self.apply_global_search_actions(actions);
        DesktopCommandEffect::Repaint
    }

    fn find_next_in_global_search(&mut self) -> DesktopCommandEffect {
        let actions = self
            .global_search
            .as_mut()
            .map(|search| search.coordinator.find_next())
            .unwrap_or_default();
        if actions.is_empty() {
            DesktopCommandEffect::Ignored
        } else {
            self.apply_global_search_actions(actions);
            DesktopCommandEffect::Repaint
        }
    }

    fn find_previous_in_global_search(&mut self) -> DesktopCommandEffect {
        let actions = self
            .global_search
            .as_mut()
            .map(|search| search.coordinator.find_previous())
            .unwrap_or_default();
        if actions.is_empty() {
            DesktopCommandEffect::Ignored
        } else {
            self.apply_global_search_actions(actions);
            DesktopCommandEffect::Repaint
        }
    }

    fn apply_global_search_actions(&mut self, actions: Vec<GlobalSearchAction>) {
        let mut queue = VecDeque::from(actions);
        while let Some(action) = queue.pop_front() {
            queue.extend(self.apply_global_search_action(action));
        }
    }

    fn apply_global_search_action(
        &mut self,
        action: GlobalSearchAction,
    ) -> Vec<GlobalSearchAction> {
        match action {
            GlobalSearchAction::EndAllLocalSearches => {
                self.pane_search = None;
                if let Some(search) = self.global_search.as_mut() {
                    search.pane_searches.clear();
                }
                Vec::new()
            }
            GlobalSearchAction::BeginPaneSearch { pane_id } => {
                let events = self
                    .global_search
                    .as_mut()
                    .map(|search| {
                        search
                            .pane_searches
                            .entry(pane_id.clone())
                            .or_insert_with(TerminalSearchSession::new)
                            .show_search()
                    })
                    .unwrap_or_default();
                self.handle_global_search_events(&pane_id, events)
            }
            GlobalSearchAction::UpdatePaneSearch { pane_id, needle } => {
                self.update_global_pane_search_query(&pane_id, &needle)
            }
            GlobalSearchAction::EndPaneSearch { pane_id } => {
                if let Some(search) = self.global_search.as_mut() {
                    search.pane_searches.remove(&pane_id);
                }
                Vec::new()
            }
            GlobalSearchAction::ResetPaneSelection { pane_id } => {
                self.reset_global_pane_search_selection(&pane_id)
            }
            GlobalSearchAction::NavigateToTarget(target) => {
                if let Some(index) = self
                    .panes
                    .iter()
                    .position(|pane| pane.pane_id == target.pane_id)
                {
                    self.focus_index(index);
                }
                Vec::new()
            }
            GlobalSearchAction::PaneFindNext { pane_id } => {
                let events = self
                    .global_search
                    .as_mut()
                    .and_then(|search| search.pane_searches.get_mut(&pane_id))
                    .map(TerminalSearchSession::find_next)
                    .unwrap_or_default();
                self.handle_global_search_events(&pane_id, events)
            }
            GlobalSearchAction::PaneFindPrevious { pane_id } => {
                let events = self
                    .global_search
                    .as_mut()
                    .and_then(|search| search.pane_searches.get_mut(&pane_id))
                    .map(TerminalSearchSession::find_previous)
                    .unwrap_or_default();
                self.handle_global_search_events(&pane_id, events)
            }
        }
    }

    fn update_global_pane_search_query(
        &mut self,
        pane_id: &str,
        needle: &str,
    ) -> Vec<GlobalSearchAction> {
        let Some(pane_index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            return Vec::new();
        };
        let events = self
            .global_search
            .as_mut()
            .map(|search| {
                search
                    .pane_searches
                    .entry(pane_id.to_string())
                    .or_insert_with(TerminalSearchSession::new)
                    .update_query(&self.panes[pane_index].terminal.screen, needle)
            })
            .unwrap_or_default();
        self.handle_global_search_events(pane_id, events)
    }

    fn reset_global_pane_search_selection(&mut self, pane_id: &str) -> Vec<GlobalSearchAction> {
        let Some(pane_index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            return Vec::new();
        };
        let events = self
            .global_search
            .as_mut()
            .and_then(|search| {
                let query = search
                    .pane_searches
                    .get(pane_id)
                    .map(|session| session.state().needle.clone())?;
                let session = search.pane_searches.get_mut(pane_id)?;
                Some(session.update_query(&self.panes[pane_index].terminal.screen, &query))
            })
            .unwrap_or_default();
        self.handle_global_search_events(pane_id, events)
    }

    fn handle_global_search_events(
        &mut self,
        pane_id: &str,
        events: Vec<zentty_terminal::search::TerminalSearchEvent>,
    ) -> Vec<GlobalSearchAction> {
        let mut actions = Vec::new();
        if let Some(search) = self.global_search.as_mut() {
            for event in events {
                actions.extend(search.coordinator.handle_search_event(pane_id, event));
            }
        }
        actions
    }

    fn refresh_global_search_matches(&mut self) {
        let pane_ids = self
            .global_search
            .as_ref()
            .map(|search| search.pane_searches.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        let mut actions = Vec::new();
        for pane_id in pane_ids {
            let Some(pane_index) = self.panes.iter().position(|pane| pane.pane_id == pane_id)
            else {
                continue;
            };
            let events = self
                .global_search
                .as_mut()
                .and_then(|search| search.pane_searches.get_mut(&pane_id))
                .map(|session| session.refresh_matches(&self.panes[pane_index].terminal.screen))
                .unwrap_or_default();
            actions.extend(self.handle_global_search_events(&pane_id, events));
        }
        self.apply_global_search_actions(actions);
    }

    fn global_search_targets(&self) -> Vec<GlobalSearchTarget> {
        self.panes
            .iter()
            .map(|pane| GlobalSearchTarget {
                worklane_id: pane.worklane_id.clone(),
                pane_id: pane.pane_id.clone(),
            })
            .collect()
    }

    fn handle_pane_search_char(&mut self, ch: char) -> DesktopCommandEffect {
        match ch {
            '\r' | '\n' => {
                let Some(pane_id) = self
                    .pane_search
                    .as_ref()
                    .map(|search| search.pane_id.clone())
                else {
                    return DesktopCommandEffect::Ignored;
                };
                self.find_next_in_pane_search(&pane_id)
            }
            '\u{1b}' => {
                self.pane_search = None;
                DesktopCommandEffect::Repaint
            }
            '\u{8}' => {
                let Some(mut query) = self
                    .pane_search
                    .as_ref()
                    .map(|search| search.session.state().needle.clone())
                else {
                    return DesktopCommandEffect::Ignored;
                };
                query.pop();
                self.update_pane_search_query(&query)
            }
            ch if !ch.is_control() => {
                let Some(mut query) = self
                    .pane_search
                    .as_ref()
                    .map(|search| search.session.state().needle.clone())
                else {
                    return DesktopCommandEffect::Ignored;
                };
                query.push(ch);
                self.update_pane_search_query(&query)
            }
            _ => DesktopCommandEffect::Ignored,
        }
    }

    fn handle_pane_search_key_event(
        &mut self,
        event: DesktopKeyEvent,
    ) -> Option<DesktopCommandEffect> {
        if event.modifiers != DesktopKeyModifiers::default() {
            return None;
        }

        let pane_id = self
            .pane_search
            .as_ref()
            .map(|search| search.pane_id.clone())?;
        match event.key {
            DesktopKey::DownArrow => Some(self.find_next_in_pane_search(&pane_id)),
            DesktopKey::UpArrow => Some(self.find_previous_in_pane_search(&pane_id)),
            _ => None,
        }
    }

    fn update_pane_search_query(&mut self, query: &str) -> DesktopCommandEffect {
        let Some(pane_id) = self
            .pane_search
            .as_ref()
            .map(|search| search.pane_id.clone())
        else {
            return DesktopCommandEffect::Ignored;
        };
        let Some(pane_index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            self.pane_search = None;
            return DesktopCommandEffect::Status {
                message: format!("Find requested for missing pane {pane_id}"),
            };
        };
        if let Some(search) = self.pane_search.as_mut() {
            search
                .session
                .update_query(&self.panes[pane_index].terminal.screen, query);
        }
        DesktopCommandEffect::Repaint
    }

    fn refresh_active_pane_search_matches(&mut self) {
        let Some(pane_id) = self
            .pane_search
            .as_ref()
            .map(|search| search.pane_id.clone())
        else {
            return;
        };
        let Some(pane_index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            self.pane_search = None;
            return;
        };
        if let Some(search) = self.pane_search.as_mut() {
            search
                .session
                .refresh_matches(&self.panes[pane_index].terminal.screen);
        }
    }

    fn find_next_in_pane_search(&mut self, pane_id: &str) -> DesktopCommandEffect {
        if self
            .pane_search
            .as_ref()
            .is_none_or(|search| search.pane_id != pane_id)
        {
            return self.show_pane_search(pane_id.to_string());
        }
        let events = self
            .pane_search
            .as_mut()
            .map(|search| search.session.find_next())
            .unwrap_or_default();
        if events.is_empty() {
            DesktopCommandEffect::Ignored
        } else {
            DesktopCommandEffect::Repaint
        }
    }

    fn find_previous_in_pane_search(&mut self, pane_id: &str) -> DesktopCommandEffect {
        if self
            .pane_search
            .as_ref()
            .is_none_or(|search| search.pane_id != pane_id)
        {
            return self.show_pane_search(pane_id.to_string());
        }
        let events = self
            .pane_search
            .as_mut()
            .map(|search| search.session.find_previous())
            .unwrap_or_default();
        if events.is_empty() {
            DesktopCommandEffect::Ignored
        } else {
            DesktopCommandEffect::Repaint
        }
    }

    fn focus_index(&mut self, index: usize) -> AppCommandExecutionResult {
        let Some(reference) = self.panes.get(index).map(|pane| {
            PaneReference::new(pane.worklane_id.clone(), PaneId::from(pane.pane_id.clone()))
        }) else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_reference(reference, true)
    }

    fn focus_pane_id(&mut self, pane_id: &str, record_history: bool) -> AppCommandExecutionResult {
        let Some(reference) = self
            .panes
            .iter()
            .find(|pane| pane.pane_id == pane_id)
            .map(|pane| {
                PaneReference::new(pane.worklane_id.clone(), PaneId::from(pane.pane_id.clone()))
            })
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_reference(reference, record_history)
    }

    fn focus_pane_reference(
        &mut self,
        reference: PaneReference,
        record_history: bool,
    ) -> AppCommandExecutionResult {
        if !self.panes.iter().any(|pane| {
            pane.worklane_id == reference.worklane_id && pane.pane_id == reference.pane_id.as_str()
        }) {
            return AppCommandExecutionResult::Unavailable;
        }
        if record_history
            && let Some(current) = self.current_pane_reference()
                && current != reference {
                    self.focus_history.record(current);
                }
        self.worklane_id = reference.worklane_id.clone();
        self.focused_pane_id = Some(reference.pane_id.as_str().to_string());
        self.focused_pane_id_by_worklane_id.insert(
            reference.worklane_id,
            reference.pane_id.as_str().to_string(),
        );
        AppCommandExecutionResult::Applied
    }

    fn navigate_focus_history(&mut self, backward: bool) -> AppCommandExecutionResult {
        let Some(current) = self.current_pane_reference() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let all_pane_ids = self.all_pane_references();
        let target = if backward {
            self.focus_history.navigate_back(current, &all_pane_ids)
        } else {
            self.focus_history.navigate_forward(current, &all_pane_ids)
        };
        target
            .map(|reference| self.focus_pane_reference(reference, false))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn current_pane_reference(&self) -> Option<PaneReference> {
        let pane_id = self.focused_pane_id.as_ref()?;
        self.panes.iter().find_map(|pane| {
            (pane.worklane_id == self.worklane_id && pane.pane_id == *pane_id).then(|| {
                PaneReference::new(pane.worklane_id.clone(), PaneId::from(pane.pane_id.clone()))
            })
        })
    }

    fn all_pane_references(&self) -> HashSet<PaneReference> {
        self.panes
            .iter()
            .map(|pane| {
                PaneReference::new(pane.worklane_id.clone(), PaneId::from(pane.pane_id.clone()))
            })
            .collect()
    }

    fn move_focus_by_order(&mut self, delta: isize) -> AppCommandExecutionResult {
        let active_indices = self.active_pane_indices();
        if active_indices.is_empty() {
            return AppCommandExecutionResult::Unavailable;
        }
        let current_index = self.focused_index().unwrap_or(active_indices[0]);
        let current_position = active_indices
            .iter()
            .position(|index| *index == current_index)
            .unwrap_or(0);
        let target_position =
            (current_position as isize + delta).rem_euclid(active_indices.len() as isize) as usize;
        self.focus_index(active_indices[target_position])
    }

    fn move_focus_horizontally(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(current_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let current = &self.panes[current_index];
        let target = self
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| {
                pane.worklane_id == self.worklane_id
                    && if delta < 0 {
                        pane.column_index < current.column_index
                    } else {
                        pane.column_index > current.column_index
                    }
            })
            .min_by_key(|(_, pane)| {
                (
                    pane.column_index.abs_diff(current.column_index),
                    pane.pane_index.abs_diff(current.pane_index),
                )
            })
            .map(|(index, _)| index);
        target
            .map(|index| self.focus_index(index))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn move_focus_vertically(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(current_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let current = &self.panes[current_index];
        let target = self
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| {
                pane.worklane_id == self.worklane_id
                    && pane.column_index == current.column_index
                    && if delta < 0 {
                        pane.pane_index < current.pane_index
                    } else {
                        pane.pane_index > current.pane_index
                    }
            })
            .min_by_key(|(_, pane)| pane.pane_index.abs_diff(current.pane_index))
            .map(|(index, _)| index);
        target
            .map(|index| self.focus_index(index))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn duplicate_focused_pane(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let source_worklane_id = source.worklane_id.clone();
        let pane_id = next_desktop_pane_id(&self.panes);
        let new_column_index = source.column_index + 1;

        let mut terminal_request = TerminalSessionRequest::default();
        terminal_request.working_directory = source.terminal_request.working_directory.clone();
        terminal_request.environment_variables =
            source.terminal_request.environment_variables.clone();
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: source_worklane_id.clone(),
            column_id: format!("column-{pane_id}"),
            column_index: new_column_index,
            pane_index: 0,
            title: pane_id.replace('-', " "),
            column_width: source.column_width,
            pane_height: source.pane_height,
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let Ok(session) = self.spawn_pane_session(&spec) else {
            return AppCommandExecutionResult::Unavailable;
        };

        for pane in &mut self.panes {
            if pane.worklane_id == source_worklane_id && pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }
        self.panes.push(session);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&pane_id, true);
        AppCommandExecutionResult::Applied
    }

    fn create_new_worklane(&mut self) -> AppCommandExecutionResult {
        let worklane_id = next_desktop_worklane_id(&self.worklane_order);
        let pane_id = next_desktop_pane_id(&self.panes);
        let source = self.focused_pane().map(DesktopPaneSession::clone_spec);
        let mut terminal_request = TerminalSessionRequest::default();
        if let Some(source) = &source {
            terminal_request.working_directory = source.terminal_request.working_directory.clone();
            terminal_request.environment_variables =
                source.terminal_request.environment_variables.clone();
        }
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: worklane_id.clone(),
            column_id: format!("column-{pane_id}"),
            column_index: 0,
            pane_index: 0,
            title: "pane 1".to_string(),
            column_width: source
                .as_ref()
                .map(|source| source.column_width)
                .unwrap_or(640.0),
            pane_height: source.as_ref().and_then(|source| source.pane_height),
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let Ok(session) = self.spawn_pane_session(&spec) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let insertion_index = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == &self.worklane_id)
            .map(|index| index + 1)
            .unwrap_or(self.worklane_order.len());
        self.worklane_order
            .insert(insertion_index, worklane_id.clone());
        self.focused_pane_id_by_worklane_id
            .insert(worklane_id.clone(), pane_id.clone());
        self.panes.push(session);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&pane_id, true);
        AppCommandExecutionResult::Applied
    }

    fn cycle_worklane(&mut self, delta: isize) -> AppCommandExecutionResult {
        let available_worklanes = self
            .worklane_order
            .iter()
            .filter(|worklane_id| {
                self.panes
                    .iter()
                    .any(|pane| pane.worklane_id == **worklane_id)
            })
            .cloned()
            .collect::<Vec<_>>();
        if available_worklanes.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }
        let current_index = available_worklanes
            .iter()
            .position(|candidate| candidate == &self.worklane_id)
            .unwrap_or(0);
        let target_index = (current_index as isize + delta)
            .rem_euclid(available_worklanes.len() as isize) as usize;
        self.focus_worklane(&available_worklanes[target_index])
    }

    fn move_active_worklane_by(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(current_index) = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == &self.worklane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let target_index = current_index as isize + delta;
        if !(0..self.worklane_order.len() as isize).contains(&target_index) {
            return AppCommandExecutionResult::Unavailable;
        }
        self.worklane_order
            .swap(current_index, target_index as usize);
        AppCommandExecutionResult::Applied
    }

    fn focus_worklane(&mut self, worklane_id: &str) -> AppCommandExecutionResult {
        let pane_id = self
            .focused_pane_id_by_worklane_id
            .get(worklane_id)
            .cloned()
            .or_else(|| {
                self.panes
                    .iter()
                    .find(|pane| pane.worklane_id == worklane_id)
                    .map(|pane| pane.pane_id.clone())
            });
        pane_id
            .map(|pane_id| self.focus_pane_id(&pane_id, true))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn close_focused_pane(&mut self) -> AppCommandExecutionResult {
        if self.panes.len() <= 1 {
            return self.request_close_window();
        }
        let Some(index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let removed_spec = self.panes[index].clone_spec();
        if let Some(mut pane) = (index < self.panes.len()).then(|| self.panes.remove(index)) {
            let _ = pane.stream.terminate();
            normalize_pane_positions(
                &mut self.panes,
                &pane.worklane_id,
                pane.column_index,
                pane.pane_index,
            );
            self.remove_empty_worklane(&pane.worklane_id);
            self.closed_pane_specs.push(removed_spec);
        }
        let next_index = index
            .saturating_sub(1)
            .min(self.panes.len().saturating_sub(1));
        self.focus_index(next_index)
    }

    /// Auto-close any panes whose shell process has exited (standard terminal
    /// behavior: a finished shell closes its pane). Returns `true` if the
    /// window now has no panes left, so the timer can request a window close —
    /// mirroring the last-pane behavior of `close_focused_pane`.
    ///
    /// Pane ids are collected before closing so the pane list is not mutated
    /// while it is being iterated.
    pub fn close_exited_panes(&mut self) -> bool {
        let exited: Vec<String> = self
            .panes
            .iter_mut()
            .filter_map(|pane| {
                pane.stream
                    .has_exited()
                    .then(|| pane.pane_id.clone())
            })
            .collect();
        if exited.is_empty() {
            return false;
        }
        for pane_id in exited {
            self.close_pane_by_id(&pane_id);
        }
        self.panes.is_empty()
    }

    /// Remove a specific pane (by id) using the same teardown path as
    /// `close_focused_pane`: terminate its PTY, normalize sibling positions,
    /// prune an emptied worklane, and record the spec for restore. Re-focuses
    /// to a neighbor when the closed pane was the focused one.
    fn close_pane_by_id(&mut self, pane_id: &str) {
        let Some(index) = self.panes.iter().position(|pane| pane.pane_id == pane_id) else {
            return;
        };
        let was_focused = self.focused_pane_id.as_deref() == Some(pane_id);
        let removed_spec = self.panes[index].clone_spec();
        let mut pane = self.panes.remove(index);
        let _ = pane.stream.terminate();
        normalize_pane_positions(
            &mut self.panes,
            &pane.worklane_id,
            pane.column_index,
            pane.pane_index,
        );
        self.remove_empty_worklane(&pane.worklane_id);
        self.closed_pane_specs.push(removed_spec);
        if was_focused {
            let next_index = index
                .saturating_sub(1)
                .min(self.panes.len().saturating_sub(1));
            let _ = self.focus_index(next_index);
        }
    }

    /// Whether the focused pane's shell process has exited. Used to suppress the
    /// window-global `last_error` banner when a write fails only because the
    /// pane is already dead (it is about to be auto-closed).
    pub fn focused_pane_has_exited(&mut self) -> bool {
        let Some(index) = self.focused_index() else {
            return false;
        };
        self.panes[index].stream.has_exited()
    }

    /// Whether any pane's shell process has exited. Used to suppress the
    /// window-global `last_error` banner when a resize fails: the per-pane
    /// resize loop aborts on the first dead pane (which may not be the focused
    /// one), and that pane is about to be auto-closed.
    pub fn any_pane_has_exited(&mut self) -> bool {
        self.panes.iter_mut().any(|pane| pane.stream.has_exited())
    }

    fn restore_closed_pane(&mut self) -> AppCommandExecutionResult {
        let Some(mut spec) = self.closed_pane_specs.pop() else {
            return AppCommandExecutionResult::Unavailable;
        };
        if self.panes.iter().any(|pane| pane.pane_id == spec.pane_id) {
            spec.pane_id = next_desktop_pane_id(&self.panes);
            spec.column_id = format!("column-{}", spec.pane_id);
        }

        let pane_id = spec.pane_id.clone();
        let worklane_id = spec.worklane_id.clone();
        let title = spec.title.clone();
        let Ok(session) = self.spawn_pane_session(&spec) else {
            self.closed_pane_specs.push(spec);
            return AppCommandExecutionResult::Unavailable;
        };
        self.ensure_worklane(&worklane_id);

        let column_exists = self
            .panes
            .iter()
            .any(|pane| pane.worklane_id == spec.worklane_id && pane.column_id == spec.column_id);
        if column_exists {
            for pane in &mut self.panes {
                if pane.worklane_id == spec.worklane_id
                    && pane.column_id == spec.column_id
                    && pane.pane_index >= spec.pane_index
                {
                    pane.pane_index += 1;
                }
            }
        } else {
            for pane in &mut self.panes {
                if pane.worklane_id == spec.worklane_id && pane.column_index >= spec.column_index {
                    pane.column_index += 1;
                }
            }
        }
        self.panes.push(session);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&pane_id, true);

        AppCommandExecutionResult::RestoredClosedPane {
            pane_id,
            worklane_id,
            toast_message: format!("Restored \"{title}\""),
        }
    }

    fn remove_empty_worklane(&mut self, worklane_id: &str) {
        if self
            .panes
            .iter()
            .any(|pane| pane.worklane_id == worklane_id)
        {
            return;
        }
        let removed_index = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == worklane_id);
        self.worklane_order
            .retain(|candidate| candidate != worklane_id);
        self.focused_pane_id_by_worklane_id.remove(worklane_id);
        self.worklane_titles_by_id.remove(worklane_id);
        if self.worklane_id != worklane_id {
            return;
        }
        let fallback_worklane_id = removed_index
            .and_then(|index| {
                self.worklane_order.get(
                    index
                        .saturating_sub(1)
                        .min(self.worklane_order.len().saturating_sub(1)),
                )
            })
            .cloned()
            .or_else(|| self.worklane_order.first().cloned());
        if let Some(fallback_worklane_id) = fallback_worklane_id {
            let _ = self.focus_worklane(&fallback_worklane_id);
        } else {
            self.focused_pane_id = None;
        }
    }

    fn ensure_worklane(&mut self, worklane_id: &str) {
        if self
            .worklane_order
            .iter()
            .any(|candidate| candidate == worklane_id)
        {
            return;
        }
        let insertion_index = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == &self.worklane_id)
            .map(|index| index + 1)
            .unwrap_or(self.worklane_order.len());
        self.worklane_order
            .insert(insertion_index, worklane_id.to_string());
    }

    fn request_close_window(&self) -> AppCommandExecutionResult {
        AppCommandExecutionResult::RequestCloseWindow {
            window_id: self.window_id.clone(),
        }
    }

    fn request_new_window(&self) -> AppCommandExecutionResult {
        AppCommandExecutionResult::RequestNewWindow {
            working_directory: self.focused_pane_path().map(ToOwned::to_owned),
        }
    }

    fn request_move_pane_to_new_window(&self) -> AppCommandExecutionResult {
        if self.panes.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }
        self.focused_pane()
            .map(
                |pane| AppCommandExecutionResult::RequestMovePaneToNewWindow {
                    pane_id: pane.pane_id.clone(),
                },
            )
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn copy_focused_pane_path(&self) -> AppCommandExecutionResult {
        self.focused_pane_path()
            .map(|path| AppCommandExecutionResult::CopyText {
                text: path.to_string(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn focused_pane_path(&self) -> Option<&str> {
        self.focused_pane()
            .and_then(|pane| pane.terminal_request.working_directory.as_deref())
            .and_then(trimmed_non_empty)
    }

    fn apply_layout_command(&mut self, command_id: AppCommandId) -> AppCommandExecutionResult {
        let mut window = self.desktop_window_snapshot();
        let result = window.execute_command(command_id);
        if result == AppCommandExecutionResult::Applied {
            self.apply_desktop_window_snapshot(window);
        }
        result
    }

    fn desktop_window_snapshot(&self) -> WindowLaunchPlan {
        let mut seen_worklanes = HashSet::new();
        let mut worklanes = Vec::new();
        for worklane_id in &self.worklane_order {
            let panes = self
                .panes
                .iter()
                .filter(|pane| &pane.worklane_id == worklane_id)
                .map(DesktopPaneSession::clone_spec)
                .collect::<Vec<_>>();
            if panes.is_empty() {
                continue;
            }
            seen_worklanes.insert(worklane_id.clone());
            let focused_pane_id = self
                .focused_pane_id_by_worklane_id
                .get(worklane_id)
                .cloned()
                .or_else(|| panes.first().map(|pane| pane.pane_id.clone()));
            worklanes.push(WorklaneLaunchPlan {
                worklane_id: worklane_id.clone(),
                title: self.worklane_titles_by_id.get(worklane_id).cloned(),
                panes,
                focused_pane_id,
            });
        }
        for pane in &self.panes {
            if seen_worklanes.contains(&pane.worklane_id) {
                continue;
            }
            seen_worklanes.insert(pane.worklane_id.clone());
            let panes = self
                .panes
                .iter()
                .filter(|candidate| candidate.worklane_id == pane.worklane_id)
                .map(DesktopPaneSession::clone_spec)
                .collect::<Vec<_>>();
            let focused_pane_id = panes.first().map(|pane| pane.pane_id.clone());
            worklanes.push(WorklaneLaunchPlan {
                worklane_id: pane.worklane_id.clone(),
                title: self.worklane_titles_by_id.get(&pane.worklane_id).cloned(),
                panes,
                focused_pane_id,
            });
        }
        WindowLaunchPlan {
            window_id: self.window_id.clone(),
            active_worklane_id: Some(self.worklane_id.clone()),
            worklanes,
            focus_history: self.focus_history.clone(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: self.open_with_targets.clone(),
            detected_servers: self.detected_servers.clone(),
            task_runner_actions: self.task_runner_actions.clone(),
            branch_urls_by_pane_id: self.branch_urls_by_pane_id.clone(),
            worklane_colors_by_id: self.worklane_colors_by_id.clone(),
        }
    }

    fn apply_desktop_window_snapshot(&mut self, window: WindowLaunchPlan) {
        let active_worklane_id = window.active_worklane_id.clone().or_else(|| {
            window
                .worklanes
                .first()
                .map(|worklane| worklane.worklane_id.clone())
        });
        self.worklane_order = window
            .worklanes
            .iter()
            .map(|worklane| worklane.worklane_id.clone())
            .collect();
        self.focused_pane_id_by_worklane_id = window
            .worklanes
            .iter()
            .filter_map(|worklane| {
                let focused = worklane
                    .focused_pane_id
                    .as_ref()
                    .or_else(|| worklane.panes.first().map(|pane| &pane.pane_id))?;
                Some((worklane.worklane_id.clone(), focused.clone()))
            })
            .collect();
        if let Some(active_worklane_id) = active_worklane_id {
            self.worklane_id = active_worklane_id;
            self.focused_pane_id = self
                .focused_pane_id_by_worklane_id
                .get(&self.worklane_id)
                .cloned();
        }
        self.focus_history = window.focus_history;
        self.worklane_colors_by_id = window
            .worklane_colors_by_id
            .into_iter()
            .filter(|(_, color)| WorklaneColor::from_raw_value(color).is_some())
            .collect();
        self.worklane_titles_by_id = window
            .worklanes
            .iter()
            .filter_map(|worklane| {
                normalized_worklane_title(worklane.title.as_deref())
                    .map(|title| (worklane.worklane_id.clone(), title))
            })
            .collect();
        for worklane in window.worklanes {
            for spec in worklane.panes {
                if let Some(pane) = self
                    .panes
                    .iter_mut()
                    .find(|pane| pane.pane_id == spec.pane_id)
                {
                    pane.apply_layout_spec(&spec);
                }
            }
        }
        sort_panes(&mut self.panes);
    }

    fn split_focused_pane_right(&mut self) -> AppCommandExecutionResult {
        if self
            .pane_layout
            .should_split_right_visibly(self.layout_viewport_width())
        {
            self.split_focused_pane_right_visibly()
        } else {
            self.add_focused_pane_right_without_resizing()
        }
    }

    fn split_focused_pane_right_visibly(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let split_width = self.visible_split_column_width();
        self.panes[source_index].column_width = split_width;
        let new_column_index = source.column_index + 1;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id
                && pane.pane_id != source.pane_id
                && pane.column_index >= new_column_index
            {
                pane.column_index += 1;
            }
        }
        self.spawn_new_pane(None, new_column_index, 0, split_width, source.pane_height)
    }

    fn add_focused_pane_right_without_resizing(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let new_column_index = source.column_index + 1;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id && pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }
        self.spawn_new_pane(
            None,
            new_column_index,
            0,
            source.column_width,
            source.pane_height,
        )
    }

    fn layout_viewport_width(&self) -> f64 {
        if self.default_size.pixel_width > 0 {
            f64::from(self.default_size.pixel_width)
        } else {
            f64::from(self.default_size.cols) * f64::from(DESKTOP_CELL_WIDTH)
        }
    }

    fn visible_split_column_width(&self) -> f64 {
        (self.layout_viewport_width() / 2.0).max(1.0)
    }

    fn split_focused_pane_left(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let new_column_index = source.column_index;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id && pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }
        self.spawn_new_pane(
            None,
            new_column_index,
            0,
            source.column_width,
            source.pane_height,
        )
    }

    fn split_focused_pane_below(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let new_pane_index = source.pane_index + 1;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id
                && pane.column_index == source.column_index
                && pane.pane_index >= new_pane_index
            {
                pane.pane_index += 1;
            }
        }
        self.spawn_new_pane(
            Some(source.column_id),
            source.column_index,
            new_pane_index,
            source.column_width,
            source.pane_height,
        )
    }

    fn split_focused_pane_above(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let new_pane_index = source.pane_index;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id
                && pane.column_index == source.column_index
                && pane.pane_index >= new_pane_index
            {
                pane.pane_index += 1;
            }
        }
        self.spawn_new_pane(
            Some(source.column_id),
            source.column_index,
            new_pane_index,
            source.column_width,
            source.pane_height,
        )
    }

    fn equalize_focused_column_heights(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let mut did_change = false;
        let mut pane_count = 0;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id && pane.column_index == source.column_index {
                pane_count += 1;
                if pane.pane_height != Some(1.0) {
                    did_change = true;
                }
                pane.pane_height = Some(1.0);
            }
        }
        if pane_count >= 2 && did_change {
            AppCommandExecutionResult::Applied
        } else {
            AppCommandExecutionResult::Unavailable
        }
    }

    fn resize_focused_column_to_fraction(&mut self, fraction: f64) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let columns = desktop_column_snapshots(&self.panes, &source.worklane_id);
        if columns.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(focused_position) = columns
            .iter()
            .position(|column| column.column_index == source.column_index)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let neighbor_position = if focused_position + 1 < columns.len() {
            focused_position + 1
        } else {
            focused_position - 1
        };
        let focused_column = &columns[focused_position];
        let neighbor_column = &columns[neighbor_position];
        let total_width = columns
            .iter()
            .map(|column| column.width.max(1.0))
            .sum::<f64>()
            .max(1.0);
        let pair_width = (focused_column.width.max(1.0) + neighbor_column.width.max(1.0)).max(2.0);
        let target_width = (total_width * fraction.clamp(0.05, 0.95)).clamp(1.0, pair_width - 1.0);
        let neighbor_width = pair_width - target_width;
        if (focused_column.width - target_width).abs() <= 0.001
            && (neighbor_column.width - neighbor_width).abs() <= 0.001
        {
            return AppCommandExecutionResult::Unavailable;
        }
        for pane in &mut self.panes {
            if pane.worklane_id != source.worklane_id {
                continue;
            }
            if pane.column_index == focused_column.column_index {
                pane.column_width = target_width;
            } else if pane.column_index == neighbor_column.column_index {
                pane.column_width = neighbor_width;
            }
        }
        AppCommandExecutionResult::Applied
    }

    fn resize_focused_pane_height_to_fraction(
        &mut self,
        fraction: f64,
    ) -> AppCommandExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let mut column_indices = self
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| {
                pane.worklane_id == source.worklane_id && pane.column_index == source.column_index
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        column_indices.sort_by_key(|index| {
            (
                self.panes[*index].pane_index,
                self.panes[*index].pane_id.clone(),
            )
        });
        if column_indices.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }
        let total_weight = column_indices
            .iter()
            .map(|index| self.panes[*index].pane_height.unwrap_or(1.0).max(1.0))
            .sum::<f64>();
        let focused_weight = self.panes[source_index].pane_height.unwrap_or(1.0).max(1.0);
        let other_weight = total_weight - focused_weight;
        if other_weight <= 0.0 {
            return AppCommandExecutionResult::Unavailable;
        }
        let clamped_fraction = fraction.clamp(0.05, 0.95);
        let target_weight = ((clamped_fraction / (1.0 - clamped_fraction)) * other_weight).max(1.0);
        if (focused_weight - target_weight).abs() <= 0.001 {
            return AppCommandExecutionResult::Unavailable;
        }
        self.panes[source_index].pane_height = Some(target_weight);
        AppCommandExecutionResult::Applied
    }

    fn spawn_new_pane(
        &mut self,
        column_id: Option<String>,
        column_index: usize,
        pane_index: usize,
        column_width: f64,
        pane_height: Option<f64>,
    ) -> AppCommandExecutionResult {
        let pane_id = next_desktop_pane_id(&self.panes);
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: self.worklane_id.clone(),
            column_id: column_id.unwrap_or_else(|| format!("column-{pane_id}")),
            column_index,
            pane_index,
            title: pane_id.replace('-', " "),
            column_width,
            pane_height,
            terminal_request: TerminalSessionRequest::default(),
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let Ok(session) = self.spawn_pane_session(&spec) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let pane_id = session.pane_id.clone();
        self.panes.push(session);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&pane_id, true);
        AppCommandExecutionResult::Applied
    }

    fn run_task_runner(&mut self, id: &str) -> CommandPaletteItemExecutionResult {
        let Some(action) = self
            .task_runner_actions
            .iter()
            .find(|action| action.id == id)
            .cloned()
        else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };

        let focused_pane = self.focused_task_runner_pane_state_from_recorded_runtime();
        self.run_task_runner_action(&action, focused_pane.as_ref())
    }

    fn run_task_runner_action(
        &mut self,
        action: &TaskRunnerAction,
        focused_pane: Option<&TaskRunnerFocusedPaneState>,
    ) -> CommandPaletteItemExecutionResult {
        match TaskRunnerExecutionPlanner::plan(action, focused_pane) {
            TaskRunnerExecutionPlan::OpenSource { source_path } => {
                CommandPaletteItemExecutionResult::OpenTaskRunnerSource { source_path }
            }
            TaskRunnerExecutionPlan::FocusedPane { pane_id, command } => {
                if self.submit_task_runner_command_to_pane(&pane_id, &command) {
                    CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
                        pane_id,
                        command,
                    }
                } else {
                    CommandPaletteItemExecutionResult::Unavailable
                }
            }
            TaskRunnerExecutionPlan::NewPane {
                command,
                working_directory,
                environment,
            } => self.run_task_runner_in_new_pane(
                action,
                command,
                working_directory,
                environment.into_iter().collect(),
            ),
        }
    }

    fn focused_task_runner_pane_state(
        &self,
        shell_activity_state: TaskRunnerShellActivityState,
        terminal_progress_indicates_activity: bool,
    ) -> Option<TaskRunnerFocusedPaneState> {
        self.focused_pane().map(|pane| TaskRunnerFocusedPaneState {
            pane_id: pane.pane_id.clone(),
            runtime_available: true,
            shell_activity_state,
            terminal_progress_indicates_activity,
        })
    }

    fn focused_task_runner_pane_state_from_recorded_runtime(
        &self,
    ) -> Option<TaskRunnerFocusedPaneState> {
        self.focused_pane().map(|pane| TaskRunnerFocusedPaneState {
            pane_id: pane.pane_id.clone(),
            runtime_available: true,
            shell_activity_state: pane.shell_activity_state,
            terminal_progress_indicates_activity: pane
                .terminal
                .terminal_progress_indicates_activity(),
        })
    }

    fn submit_task_runner_command_to_pane(&mut self, pane_id: &str, command: &str) -> bool {
        let Some(pane) = self.panes.iter_mut().find(|pane| pane.pane_id == pane_id) else {
            return false;
        };
        let bytes = TerminalInputPlanner::submit_command(command, TerminalPasteMode::Plain)
            .into_pty_bytes();
        pane.stream.write_all(&bytes).is_ok()
    }

    fn run_task_runner_in_new_pane(
        &mut self,
        action: &TaskRunnerAction,
        command: String,
        working_directory: String,
        environment_variables: Vec<(String, String)>,
    ) -> CommandPaletteItemExecutionResult {
        let Some(source_index) = self.focused_index() else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let source = self.panes[source_index].clone_spec();
        let pane_id = next_desktop_pane_id(&self.panes);
        let new_column_index = source.column_index + 1;
        for pane in &mut self.panes {
            if pane.worklane_id == source.worklane_id && pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }

        let mut terminal_request = source.terminal_request;
        terminal_request.working_directory = trimmed_non_empty(&working_directory)
            .map(str::to_string)
            .or(terminal_request.working_directory);
        terminal_request.command = Some(command.clone());
        terminal_request.native_command = None;
        terminal_request.wait_after_native_command = false;
        terminal_request.is_launch_deferred = false;
        terminal_request.prefill_text = None;
        terminal_request.environment_variables = environment_variables;

        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: source.worklane_id,
            column_id: format!("column-{pane_id}"),
            column_index: new_column_index,
            pane_index: 0,
            title: action.title.clone(),
            column_width: source.column_width,
            pane_height: source.pane_height,
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let Ok(session) = self.spawn_pane_session(&spec) else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let pane_id = session.pane_id.clone();
        self.panes.push(session);
        sort_panes(&mut self.panes);
        self.focus_pane_id(&pane_id, true);

        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane { pane_id, command }
    }
}

fn agent_ipc_error_is_routable(error: &AgentIpcRequestRejection) -> bool {
    matches!(error.code, "invalid_pane_token" | "pane_not_found")
}

fn agent_ipc_pane_not_found_rejection() -> AgentIpcRequestRejection {
    AgentIpcRequestRejection::new("pane_not_found", "Target pane was not found.")
}

fn agent_ipc_missing_target_context_rejection() -> AgentIpcRequestRejection {
    AgentIpcRequestRejection::new("missing_target_context", "Missing pane target context.")
}

fn resolve_single_pane_ipc_candidate(
    matches: Vec<AgentIpcPaneTarget>,
) -> Result<AgentIpcPaneTarget, AgentIpcRequestRejection> {
    match matches.len() {
        0 => Err(agent_ipc_pane_not_found_rejection()),
        1 => Ok(matches
            .into_iter()
            .next()
            .expect("one candidate should exist")),
        _ => Err(AgentIpcRequestRejection::new(
            "pane_target_ambiguous",
            "The requested target matches multiple panes.",
        )),
    }
}

impl DesktopPaneSession {
    fn spawn_with_agent_ipc(
        spec: &PaneLaunchSpec,
        size: TerminalSize,
        window_id: Option<&str>,
        agent_ipc_environment: Option<&AgentIpcPaneEnvironment>,
    ) -> Result<Self, PtyError> {
        let stream = spec
            .spawn_pty_with_agent_ipc(size, window_id, agent_ipc_environment)?
            .into_output_stream()?;
        Ok(Self {
            pane_id: spec.pane_id.clone(),
            worklane_id: spec.worklane_id.clone(),
            column_id: spec.column_id.clone(),
            title: spec.title.clone(),
            column_index: spec.column_index,
            pane_index: spec.pane_index,
            column_width: spec.column_width,
            pane_height: spec.pane_height,
            terminal_request: spec.terminal_request.clone(),
            restored_rerunnable_command: spec.restored_rerunnable_command.clone(),
            shell_activity_state: TaskRunnerShellActivityState::Unknown,
            root_pid: None,
            terminal: DesktopTerminalState::new(size),
            selection: TerminalSelection::new(),
            stream,
        })
    }

    fn clone_spec(&self) -> PaneLaunchSpec {
        PaneLaunchSpec {
            pane_id: self.pane_id.clone(),
            worklane_id: self.worklane_id.clone(),
            column_id: self.column_id.clone(),
            column_index: self.column_index,
            pane_index: self.pane_index,
            title: self.title.clone(),
            column_width: self.column_width,
            pane_height: self.pane_height,
            terminal_request: self.terminal_request.clone(),
            restored_rerunnable_command: self.restored_rerunnable_command.clone(),
            status_text: None,
            applied_restore_draft_tool: None,
        }
    }

    fn apply_layout_spec(&mut self, spec: &PaneLaunchSpec) {
        self.worklane_id = spec.worklane_id.clone();
        self.column_id = spec.column_id.clone();
        self.column_index = spec.column_index;
        self.pane_index = spec.pane_index;
        self.column_width = spec.column_width;
        self.pane_height = spec.pane_height;
        self.restored_rerunnable_command = spec.restored_rerunnable_command.clone();
    }

    fn resize(&mut self, size: TerminalSize) -> Result<(), PtyError> {
        // Skip the PTY resize when the grid dimensions are unchanged: a ConPTY
        // resize clears an idle shell (conhost does not repaint it), so a
        // spurious same-size WM_SIZE would otherwise blank the pane.
        let screen = self.terminal.screen();
        if screen.width() == usize::from(size.cols) && screen.height() == usize::from(size.rows) {
            return Ok(());
        }
        self.stream.resize(size)?;
        self.terminal.resize(size);
        Ok(())
    }
}

impl DesktopLaunchPlan {
    pub fn load(shell: DesktopShellConfig) -> Result<Self, DesktopLaunchError> {
        let config_store = AppConfigStore::load(shell.config_path.clone()).map_err(|source| {
            DesktopLaunchError::ConfigLoad {
                path: shell.config_path.clone(),
                source,
            }
        })?;
        let config = config_store.current().clone();

        let (source, mut app) = if let Some(path) = shell.workspace_path.clone() {
            let json =
                fs::read_to_string(&path).map_err(|source| DesktopLaunchError::WorkspaceRead {
                    path: path.clone(),
                    source,
                })?;
            let envelope: SessionRestoreEnvelope =
                serde_json::from_str(&json).map_err(|source| {
                    DesktopLaunchError::WorkspaceDecode {
                        path: path.clone(),
                        source,
                    }
                })?;
            (
                DesktopLaunchSource::WorkspaceRestore(path),
                AppLaunchPlan::from_envelope(&envelope),
            )
        } else {
            (DesktopLaunchSource::NewWorkspace, default_app_launch_plan())
        };
        let open_with_targets = resolve_open_with_targets(&config.open_with);
        for window in &mut app.windows {
            if window.open_with_targets.is_empty() {
                window.open_with_targets = open_with_targets.clone();
            }
        }

        Ok(Self {
            shell,
            config,
            source,
            app,
        })
    }
}

#[derive(Debug)]
pub enum DesktopLaunchError {
    ConfigLoad {
        path: PathBuf,
        source: io::Error,
    },
    WorkspaceRead {
        path: PathBuf,
        source: io::Error,
    },
    WorkspaceDecode {
        path: PathBuf,
        source: serde_json::Error,
    },
}

impl fmt::Display for DesktopLaunchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ConfigLoad { path, source } => {
                write!(
                    formatter,
                    "failed to load config {}: {source}",
                    path.display()
                )
            }
            Self::WorkspaceRead { path, source } => {
                write!(
                    formatter,
                    "failed to read workspace restore file {}: {source}",
                    path.display()
                )
            }
            Self::WorkspaceDecode { path, source } => {
                write!(
                    formatter,
                    "failed to decode workspace restore file {}: {source}",
                    path.display()
                )
            }
        }
    }
}

impl Error for DesktopLaunchError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::ConfigLoad { source, .. } => Some(source),
            Self::WorkspaceRead { source, .. } => Some(source),
            Self::WorkspaceDecode { source, .. } => Some(source),
        }
    }
}

#[derive(Debug)]
pub enum DesktopRunError {
    Launch(DesktopLaunchError),
    AppLaunch(AppLaunchError),
    AgentIpc(AgentIpcTransportError),
    NoFocusedPane,
    Pty(PtyError),
    Window(DesktopWindowError),
}

impl fmt::Display for DesktopRunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Launch(error) => write!(formatter, "{error}"),
            Self::AppLaunch(error) => write!(formatter, "{error:?}"),
            Self::AgentIpc(error) => write!(formatter, "{error}"),
            Self::NoFocusedPane => write!(formatter, "desktop launch has no focused pane"),
            Self::Pty(error) => write!(formatter, "{error}"),
            Self::Window(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for DesktopRunError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Launch(error) => Some(error),
            Self::AppLaunch(_) => None,
            Self::AgentIpc(error) => Some(error),
            Self::NoFocusedPane => None,
            Self::Pty(error) => Some(error),
            Self::Window(error) => Some(error),
        }
    }
}

impl From<DesktopLaunchError> for DesktopRunError {
    fn from(error: DesktopLaunchError) -> Self {
        Self::Launch(error)
    }
}

impl From<AppLaunchError> for DesktopRunError {
    fn from(error: AppLaunchError) -> Self {
        Self::AppLaunch(error)
    }
}

impl From<AgentIpcTransportError> for DesktopRunError {
    fn from(error: AgentIpcTransportError) -> Self {
        Self::AgentIpc(error)
    }
}

impl From<PtyError> for DesktopRunError {
    fn from(error: PtyError) -> Self {
        Self::Pty(error)
    }
}

impl From<DesktopWindowError> for DesktopRunError {
    fn from(error: DesktopWindowError) -> Self {
        Self::Window(error)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopWindowError {
    UnsupportedPlatform,
    Native(String),
}

impl fmt::Display for DesktopWindowError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedPlatform => {
                write!(formatter, "desktop mode is only supported on Windows")
            }
            Self::Native(message) => write!(formatter, "{message}"),
        }
    }
}

impl Error for DesktopWindowError {}

pub fn run_desktop(shell: DesktopShellConfig) -> Result<i32, DesktopRunError> {
    let launch = DesktopLaunchPlan::load(shell)?;
    let agent_ipc_environment = desktop_agent_ipc_environment(&launch)?;
    let session = DesktopWindowSession::spawn_with_agent_ipc(launch, agent_ipc_environment)?;
    native_window::run_message_loop(session).map_err(DesktopRunError::from)
}

fn desktop_agent_ipc_environment(
    launch: &DesktopLaunchPlan,
) -> Result<AgentIpcRuntimeEnvironment, DesktopRunError> {
    let active = active_desktop_window(&launch.app).ok_or(DesktopRunError::NoFocusedPane)?;
    desktop_agent_ipc_environment_for_panes(
        &active.window_id,
        active
            .panes
            .iter()
            .map(|pane| (pane.worklane_id.as_str(), pane.pane_id.as_str())),
    )
}

fn desktop_agent_ipc_environment_for_panes<'a, I>(
    window_id: &str,
    panes: I,
) -> Result<AgentIpcRuntimeEnvironment, DesktopRunError>
where
    I: IntoIterator<Item = (&'a str, &'a str)>,
{
    let instance_id = generate_agent_ipc_instance_id()?;
    let socket_path = agent_ipc_pipe_path_for_instance(&instance_id);
    let cli_bin = default_agent_ipc_cli_bin();
    let mut environment =
        AgentIpcRuntimeEnvironment::new(socket_path, cli_bin, instance_id.clone());
    for (worklane_id, pane_id) in panes {
        environment = environment.with_pane_token(
            Some(window_id),
            worklane_id,
            pane_id,
            generate_agent_ipc_pane_token()?,
        );
    }
    Ok(environment)
}

fn default_agent_ipc_cli_bin() -> String {
    std::env::current_exe()
        .ok()
        .map(|mut path| {
            path.set_file_name(if cfg!(windows) {
                "zentty-win.exe"
            } else {
                "zentty-win"
            });
            path.to_string_lossy().into_owned()
        })
        .unwrap_or_else(|| {
            if cfg!(windows) {
                "zentty-win.exe"
            } else {
                "zentty-win"
            }
            .to_string()
        })
}

pub fn usage() -> &'static str {
    "Usage: zentty-win-desktop [--config PATH] [--workspace RESTORE_JSON] [--cols N] [--rows N] [--title TITLE]"
}

pub fn default_config_path(environment: &DesktopEnvironment) -> Option<PathBuf> {
    environment
        .app_data
        .as_ref()
        .map(|path| path.join("Zentty").join("config.toml"))
        .or_else(|| {
            environment.user_profile.as_ref().map(|path| {
                path.join("AppData")
                    .join("Roaming")
                    .join("Zentty")
                    .join("config.toml")
            })
        })
}

pub fn default_app_launch_plan() -> AppLaunchPlan {
    AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![WindowLaunchPlan {
            window_id: "window-main".to_string(),
            worklanes: vec![WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: Some("Main".to_string()),
                panes: vec![PaneLaunchSpec {
                    pane_id: "pane-main".to_string(),
                    worklane_id: "main".to_string(),
                    column_id: "column-main".to_string(),
                    column_index: 0,
                    pane_index: 0,
                    title: "shell".to_string(),
                    column_width: 640.0,
                    pane_height: Some(1.0),
                    terminal_request: TerminalSessionRequest::default(),
                    restored_rerunnable_command: None,
                    status_text: None,
                    applied_restore_draft_tool: None,
                }],
                focused_pane_id: Some("pane-main".to_string()),
            }],
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::<OpenWithResolvedTarget>::new(),
            detected_servers: Vec::<DetectedServer>::new(),
            task_runner_actions: Vec::<TaskRunnerAction>::new(),
            branch_urls_by_pane_id: Default::default(),
            worklane_colors_by_id: Default::default(),
        }],
    }
}

struct ActiveDesktopWindow<'a> {
    window_id: String,
    active_worklane_id: String,
    worklane_order: Vec<String>,
    focused_pane_id_by_worklane_id: BTreeMap<String, String>,
    panes: Vec<&'a PaneLaunchSpec>,
    open_with_targets: &'a [OpenWithResolvedTarget],
    detected_servers: &'a [DetectedServer],
    task_runner_actions: &'a [TaskRunnerAction],
    branch_urls_by_pane_id: &'a BTreeMap<String, String>,
    worklane_colors_by_id: &'a BTreeMap<String, String>,
    worklane_titles_by_id: BTreeMap<String, String>,
}

fn active_desktop_window(plan: &AppLaunchPlan) -> Option<ActiveDesktopWindow<'_>> {
    let active_window_id = plan
        .active_window_id
        .as_deref()
        .or_else(|| plan.windows.first().map(|window| window.window_id.as_str()))?;
    let window = plan
        .windows
        .iter()
        .find(|window| window.window_id == active_window_id)
        .or_else(|| plan.windows.first())?;
    let active_worklane_id = window.active_worklane_id.as_deref().or_else(|| {
        window
            .worklanes
            .first()
            .map(|worklane| worklane.worklane_id.as_str())
    })?;
    let panes = window
        .worklanes
        .iter()
        .flat_map(|worklane| worklane.panes.iter())
        .collect::<Vec<_>>();
    let focused_pane_id_by_worklane_id = window
        .worklanes
        .iter()
        .filter_map(|worklane| {
            let focused = worklane
                .focused_pane_id
                .as_deref()
                .or_else(|| worklane.panes.first().map(|pane| pane.pane_id.as_str()))?;
            Some((worklane.worklane_id.clone(), focused.to_string()))
        })
        .collect::<BTreeMap<_, _>>();

    Some(ActiveDesktopWindow {
        window_id: window.window_id.clone(),
        active_worklane_id: active_worklane_id.to_string(),
        worklane_order: window
            .worklanes
            .iter()
            .map(|worklane| worklane.worklane_id.clone())
            .collect(),
        focused_pane_id_by_worklane_id,
        panes,
        open_with_targets: &window.open_with_targets,
        detected_servers: &window.detected_servers,
        task_runner_actions: &window.task_runner_actions,
        branch_urls_by_pane_id: &window.branch_urls_by_pane_id,
        worklane_colors_by_id: &window.worklane_colors_by_id,
        worklane_titles_by_id: window
            .worklanes
            .iter()
            .filter_map(|worklane| {
                normalized_worklane_title(worklane.title.as_deref())
                    .map(|title| (worklane.worklane_id.clone(), title))
            })
            .collect(),
    })
}

fn upsert_detected_server(
    servers: &mut Vec<DetectedServer>,
    worklane_id: &str,
    pane_id: &str,
    candidate: ServerUrlCandidate,
) {
    let server = DetectedServer::new(
        server_record_id(worklane_id, pane_id, "watch", &candidate.origin),
        candidate.origin,
        candidate.url,
        candidate.display,
    )
    .with_metadata(
        worklane_id,
        Some(pane_id.to_string()),
        DetectedServerSource::Watch,
        DetectedServerConfidence::Explicit,
        OffsetDateTime::now_utc(),
    );
    upsert_server(servers, server);
}

fn upsert_server(servers: &mut Vec<DetectedServer>, server: DetectedServer) {
    let mut registry = ServerRegistry::from_records(std::mem::take(servers));
    registry.upsert(server);
    *servers = registry.into_records();
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ServerSetIpcCommand {
    raw_url: String,
    pid: Option<i32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ServerOpenIpcCommand {
    raw_url: Option<String>,
    browser_id: Option<String>,
}

fn parse_server_set_arguments(
    arguments: &[String],
) -> Result<ServerSetIpcCommand, AgentIpcRequestRejection> {
    let mut raw_url = None;
    let mut pid = None;
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        match argument.as_str() {
            "--pid" => {
                let value = arguments.get(index + 1).ok_or_else(|| {
                    AgentIpcRequestRejection::new("missing_value", "Missing value for --pid.")
                })?;
                let parsed = value.parse::<i32>().ok().filter(|pid| *pid > 0);
                let Some(parsed) = parsed else {
                    return Err(AgentIpcRequestRejection::new(
                        "invalid_pid",
                        format!("Invalid PID '{value}'."),
                    ));
                };
                pid = Some(parsed);
                index += 2;
            }
            "--json" => {
                index += 1;
            }
            _ => {
                if raw_url.is_some() {
                    return Err(AgentIpcRequestRejection::new(
                        "unexpected_argument",
                        format!("Unexpected argument '{argument}'."),
                    ));
                }
                raw_url = Some(argument.clone());
                index += 1;
            }
        }
    }

    let raw_url = raw_url
        .ok_or_else(|| AgentIpcRequestRejection::new("missing_url", "Missing server URL."))?;
    Ok(ServerSetIpcCommand { raw_url, pid })
}

fn parse_server_no_argument_command(arguments: &[String]) -> Result<(), AgentIpcRequestRejection> {
    for argument in arguments {
        if argument != "--json" {
            return Err(AgentIpcRequestRejection::new(
                "unexpected_argument",
                format!("Unexpected argument '{argument}'."),
            ));
        }
    }
    Ok(())
}

fn parse_server_open_arguments(
    arguments: &[String],
) -> Result<ServerOpenIpcCommand, AgentIpcRequestRejection> {
    let mut raw_url = None;
    let mut browser_id = None;
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        match argument.as_str() {
            "--browser" => {
                let value = arguments.get(index + 1).ok_or_else(|| {
                    AgentIpcRequestRejection::new("missing_value", "Missing value for --browser.")
                })?;
                browser_id = Some(value.clone());
                index += 2;
            }
            "--json" => {
                index += 1;
            }
            _ => {
                if raw_url.is_some() {
                    return Err(AgentIpcRequestRejection::new(
                        "unexpected_argument",
                        format!("Unexpected argument '{argument}'."),
                    ));
                }
                raw_url = Some(argument.clone());
                index += 1;
            }
        }
    }

    Ok(ServerOpenIpcCommand {
        raw_url,
        browser_id,
    })
}

fn server_url_normalize_rejection(
    error: zentty_core::server_detection::ServerUrlNormalizeError,
) -> AgentIpcRequestRejection {
    AgentIpcRequestRejection::new("invalid_url", format!("Invalid server URL: {error:?}."))
}

fn server_origin_from_raw_url(raw_url: &str) -> Result<String, AgentIpcRequestRejection> {
    ServerUrlNormalizer::normalize(raw_url)
        .map(|candidate| candidate.origin)
        .map_err(server_url_normalize_rejection)
}

fn server_record_id(worklane_id: &str, pane_id: &str, source: &str, origin: &str) -> String {
    [worklane_id, pane_id, source, origin].join("|")
}

fn server_record_worklane_id(server: &DetectedServer) -> Option<&str> {
    if !server.worklane_id.is_empty() {
        return Some(&server.worklane_id);
    }

    let mut parts = server.id.split('|');
    let worklane_id = parts.next()?;
    let pane_id = parts.next()?;
    let source = parts.next()?;
    let _origin = parts.next()?;
    (parts.next().is_none() && !worklane_id.is_empty() && !pane_id.is_empty() && !source.is_empty())
        .then_some(worklane_id)
}

fn server_record_pane_id(server: &DetectedServer) -> Option<String> {
    if server.pane_id.is_some() {
        return server.pane_id.clone();
    }

    let parts = server.id.split('|').collect::<Vec<_>>();
    (parts.len() == 4 && parts[1] != "worklane").then(|| parts[1].to_string())
}

fn server_list_entry(entry: &RankedServer, worklane_id: &str) -> ServerListEntry {
    let server = &entry.server;
    let source = server.source.raw_value().to_string();
    ServerListEntry {
        id: server.id.clone(),
        origin: server.origin.clone(),
        url: server.url.clone(),
        display: server.display.clone(),
        worklane_id: server_record_worklane_id(server)
            .unwrap_or(worklane_id)
            .to_string(),
        pane_id: server_record_pane_id(server),
        source: source.clone(),
        ports: server.ports.iter().map(|port| i32::from(*port)).collect(),
        confidence: server.confidence.raw_value().to_string(),
        updated_at: format_server_timestamp(server.updated_at),
        tier: Some(server_relevance_tier_text(entry.tier).to_string()),
        reasons: Some(server_relevance_reason_texts(&entry.reasons)),
    }
}

fn format_server_timestamp(timestamp: OffsetDateTime) -> String {
    timestamp
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn server_relevance_tier_text(tier: ServerRelevanceTier) -> &'static str {
    match tier {
        ServerRelevanceTier::Primary => "primary",
        ServerRelevanceTier::Shown => "shown",
        ServerRelevanceTier::Hidden => "hidden",
    }
}

fn server_relevance_reason_texts(reasons: &HashSet<ServerRelevanceReason>) -> Vec<String> {
    let mut texts = reasons
        .iter()
        .map(server_relevance_reason_text)
        .collect::<Vec<_>>();
    texts.sort();
    texts
}

fn server_relevance_reason_text(reason: &ServerRelevanceReason) -> String {
    match reason {
        ServerRelevanceReason::SessionSelected => "session-selected".to_string(),
        ServerRelevanceReason::IgnoredPort(port) => format!("ignored-port:{port}"),
        ServerRelevanceReason::Manual => "manual".to_string(),
        ServerRelevanceReason::RunningPane => "running-pane".to_string(),
        ServerRelevanceReason::FocusedPane => "focused-pane".to_string(),
        ServerRelevanceReason::Source(source) => format!("source:{}", source.raw_value()),
        ServerRelevanceReason::Confidence(confidence) => {
            format!("confidence:{}", confidence.raw_value())
        }
        ServerRelevanceReason::Fresh => "fresh".to_string(),
    }
}

fn next_desktop_pane_id(panes: &[DesktopPaneSession]) -> String {
    let mut index = panes.len() + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !panes.iter().any(|pane| pane.pane_id == candidate) {
            return candidate;
        }
        index += 1;
    }
}

fn next_desktop_pane_id_with_reserved(
    panes: &[DesktopPaneSession],
    reserved_pane_ids: &HashSet<String>,
) -> String {
    let mut index = panes
        .iter()
        .map(|pane| pane.pane_id.as_str())
        .chain(reserved_pane_ids.iter().map(String::as_str))
        .filter_map(pane_id_numeric_suffix)
        .max()
        .unwrap_or(panes.len().max(reserved_pane_ids.len()))
        + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !reserved_pane_ids.contains(&candidate)
            && !panes.iter().any(|pane| pane.pane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn next_pane_number_for_template_capture(panes: &[DesktopPaneSession], worklane_id: &str) -> i32 {
    panes
        .iter()
        .filter(|pane| pane.worklane_id == worklane_id)
        .filter_map(|pane| pane_id_numeric_suffix(&pane.pane_id))
        .max()
        .unwrap_or_else(|| {
            panes
                .iter()
                .filter(|pane| pane.worklane_id == worklane_id)
                .count()
        })
        .saturating_add(1)
        .try_into()
        .unwrap_or(i32::MAX)
}

fn pane_id_numeric_suffix(pane_id: &str) -> Option<usize> {
    pane_id.strip_prefix("pane-")?.parse().ok()
}

fn next_desktop_window_index(window_id: &str) -> usize {
    window_id
        .strip_prefix("window-")
        .and_then(|suffix| suffix.parse::<usize>().ok())
        .map(|index| index + 1)
        .unwrap_or(2)
}

fn next_desktop_worklane_id(worklane_order: &[String]) -> String {
    let mut index = worklane_order.len() + 1;
    loop {
        let candidate = format!("worklane-{index}");
        if !worklane_order
            .iter()
            .any(|worklane_id| worklane_id == &candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

#[derive(Clone, Debug, PartialEq)]
struct DesktopColumnSnapshot {
    column_index: usize,
    width: f64,
}

fn desktop_column_snapshots(
    panes: &[DesktopPaneSession],
    worklane_id: &str,
) -> Vec<DesktopColumnSnapshot> {
    let mut pane_indices = panes
        .iter()
        .enumerate()
        .filter_map(|(index, pane)| (pane.worklane_id == worklane_id).then_some(index))
        .collect::<Vec<_>>();
    pane_indices.sort_by_key(|index| {
        (
            panes[*index].column_index,
            panes[*index].pane_index,
            panes[*index].pane_id.clone(),
        )
    });

    let mut seen_column_indices = HashSet::new();
    let mut snapshots = Vec::new();
    for index in pane_indices {
        let pane = &panes[index];
        if seen_column_indices.insert(pane.column_index) {
            snapshots.push(DesktopColumnSnapshot {
                column_index: pane.column_index,
                width: pane.column_width,
            });
        }
    }
    snapshots
}

fn sort_panes(panes: &mut [DesktopPaneSession]) {
    panes.sort_by(|lhs, rhs| {
        lhs.column_index
            .cmp(&rhs.column_index)
            .then(lhs.pane_index.cmp(&rhs.pane_index))
            .then(lhs.pane_id.cmp(&rhs.pane_id))
    });
}

/// Map a pane's shell-activity state to a sidebar status pill kind.
fn pane_status_kind(state: TaskRunnerShellActivityState) -> crate::render::PaneStatusKind {
    match state {
        TaskRunnerShellActivityState::CommandRunning => crate::render::PaneStatusKind::Working,
        TaskRunnerShellActivityState::PromptIdle => crate::render::PaneStatusKind::Ready,
        TaskRunnerShellActivityState::Unknown => crate::render::PaneStatusKind::Idle,
    }
}

/// Parse a `#rrggbb` (or `rrggbb`) hex color into RGB bytes.
fn parse_hex_color(value: &str) -> Option<(u8, u8, u8)> {
    let hex = value.trim().trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    Some((
        u8::from_str_radix(&hex[0..2], 16).ok()?,
        u8::from_str_radix(&hex[2..4], 16).ok()?,
        u8::from_str_radix(&hex[4..6], 16).ok()?,
    ))
}

fn normalize_pane_positions(
    panes: &mut [DesktopPaneSession],
    worklane_id: &str,
    removed_column_index: usize,
    removed_pane_index: usize,
) {
    let removed_column_still_exists = panes
        .iter()
        .any(|pane| pane.worklane_id == worklane_id && pane.column_index == removed_column_index);
    for pane in panes.iter_mut() {
        if pane.worklane_id != worklane_id {
            continue;
        }
        if pane.column_index == removed_column_index && pane.pane_index > removed_pane_index {
            pane.pane_index -= 1;
        }
        if pane.column_index > removed_column_index && !removed_column_still_exists {
            pane.column_index -= 1;
        }
    }
    sort_panes(panes);
}

fn retarget_desktop_pane_for_split_out(
    pane: &mut DesktopPaneSession,
    destination_worklane_id: &str,
) {
    pane.worklane_id = destination_worklane_id.to_string();
    pane.column_id = format!("column-{}", pane.pane_id);
    pane.column_index = 0;
    pane.pane_index = 0;
    pane.column_width = DESKTOP_DEFAULT_COLUMN_WIDTH;
    pane.pane_height = Some(1.0);
}

fn trimmed_non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn task_manager_status_text(state: TaskRunnerShellActivityState) -> Option<String> {
    match state {
        TaskRunnerShellActivityState::CommandRunning => Some("Running".to_string()),
        TaskRunnerShellActivityState::PromptIdle => Some("Idle".to_string()),
        TaskRunnerShellActivityState::Unknown => None,
    }
}

fn current_time_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}

fn bookmarks_path_for_config_path(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .map(|parent| parent.join("bookmarks.json"))
        .unwrap_or_else(|| PathBuf::from("bookmarks.json"))
}

fn template_focused_pane_coordinates(template: &WorkspaceTemplate) -> Option<(usize, usize)> {
    let column_index = template
        .focused_column_id
        .as_deref()
        .and_then(|column_id| {
            template
                .columns
                .iter()
                .position(|column| column.id == column_id)
        })
        .filter(|index| !template.columns[*index].panes.is_empty())
        .or_else(|| {
            template
                .columns
                .iter()
                .position(|column| !column.panes.is_empty())
        })?;
    let column = &template.columns[column_index];
    let pane_index = column
        .focused_pane_id
        .as_deref()
        .and_then(|pane_id| template_pane_index(column, pane_id))
        .or_else(|| {
            column
                .last_focused_pane_id
                .as_deref()
                .and_then(|pane_id| template_pane_index(column, pane_id))
        })
        .unwrap_or(0);
    Some((column_index, pane_index))
}

fn template_pane_index(column: &WorkspaceTemplateColumn, pane_id: &str) -> Option<usize> {
    column.panes.iter().position(|pane| pane.id == pane_id)
}

fn template_column_width(column: &WorkspaceTemplateColumn) -> f64 {
    if column.width.is_finite() && column.width > 0.0 {
        column.width
    } else {
        DESKTOP_DEFAULT_COLUMN_WIDTH
    }
}

fn resolved_template_working_directory(requested: Option<&str>) -> (Option<String>, bool) {
    let fallback = desktop_default_working_directory();
    match requested.and_then(trimmed_non_empty) {
        Some(path) if Path::new(path).is_dir() => (Some(path.to_string()), false),
        Some(_) => (fallback, true),
        None => (fallback, false),
    }
}

fn desktop_default_working_directory() -> Option<String> {
    env_var_trimmed("USERPROFILE")
        .or_else(|| {
            let drive = env_var_trimmed("HOMEDRIVE")?;
            let path = env_var_trimmed("HOMEPATH")?;
            Some(format!("{drive}{path}"))
        })
        .or_else(|| env_var_trimmed("HOME"))
        .or_else(|| {
            env::current_dir()
                .ok()
                .map(|path| path.to_string_lossy().to_string())
        })
}

fn env_var_trimmed(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .and_then(|value| trimmed_non_empty(&value).map(str::to_string))
}

fn desktop_template_command_is_available(command: &str) -> bool {
    let Some(token) = desktop_command_first_token(command) else {
        return false;
    };
    if desktop_command_token_is_path_like(&token) {
        return desktop_command_candidates(&token)
            .iter()
            .any(|candidate| Path::new(candidate).is_file());
    }

    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    let candidates = desktop_command_candidates(&token);
    env::split_paths(&path).any(|directory| {
        candidates
            .iter()
            .any(|candidate| directory.join(candidate).is_file())
    })
}

fn desktop_command_first_token(command: &str) -> Option<String> {
    let trimmed = trimmed_non_empty(command)?;
    if let Some(rest) = trimmed.strip_prefix('"') {
        let token = rest.split('"').next()?;
        return trimmed_non_empty(token).map(str::to_string);
    }
    trimmed.split_whitespace().next().map(str::to_string)
}

fn desktop_command_token_is_path_like(token: &str) -> bool {
    token.contains('/') || token.contains('\\')
}

fn desktop_command_candidates(token: &str) -> Vec<String> {
    if Path::new(token).extension().is_some() {
        return vec![token.to_string()];
    }

    let mut candidates = vec![token.to_string()];
    let pathext = env::var("PATHEXT").unwrap_or_else(|_| {
        if cfg!(windows) {
            ".COM;.EXE;.BAT;.CMD".to_string()
        } else {
            String::new()
        }
    });
    candidates.extend(
        pathext
            .split(';')
            .filter_map(trimmed_non_empty)
            .map(|extension| {
                if extension.starts_with('.') {
                    format!("{token}{extension}")
                } else {
                    format!("{token}.{extension}")
                }
            }),
    );
    candidates
}

fn append_bookmark_section(
    lines: &mut Vec<String>,
    title: &str,
    templates: &[WorkspaceTemplate],
    selected_index: usize,
    template_index: &mut usize,
) {
    if templates.is_empty() {
        return;
    }

    lines.push(title.to_string());
    for template in templates {
        let marker = if *template_index == selected_index {
            ">"
        } else {
            " "
        };
        lines.push(format!("{marker} {}", render_bookmark_template(template)));
        *template_index += 1;
    }
}

fn render_bookmark_template(template: &WorkspaceTemplate) -> String {
    let marker = if template.pinned { "*" } else { "-" };
    let kind = match template.kind {
        WorkspaceTemplateKind::Bookmark => "bookmark",
        WorkspaceTemplateKind::Preset => "preset",
    };
    let location = template
        .project_root
        .as_deref()
        .or(template.title.as_deref())
        .unwrap_or("");
    let pane_count = template.pane_count();
    let pane_label = if pane_count == 1 { "pane" } else { "panes" };
    if location.trim().is_empty() {
        format!(
            "{marker} {} ({kind}, {pane_count} {pane_label})",
            template.name
        )
    } else {
        format!(
            "{marker} {} - {} ({kind}, {pane_count} {pane_label})",
            template.name, location
        )
    }
}

fn bookmark_reveal_path(template: &WorkspaceTemplate) -> Option<String> {
    template
        .project_root
        .as_deref()
        .and_then(trimmed_non_empty)
        .map(str::to_string)
        .or_else(|| {
            template
                .all_panes()
                .into_iter()
                .find_map(|pane| {
                    pane.working_directory
                        .as_deref()
                        .and_then(trimmed_non_empty)
                })
                .map(str::to_string)
        })
}

fn default_bookmark_export_path(bookmarks_path: &Path, template_name: &str) -> PathBuf {
    let directory = bookmarks_path.parent().unwrap_or_else(|| Path::new(""));
    directory.join(format!(
        "{}.{}",
        bookmark_export_file_stem(template_name),
        WorkspaceTemplateExporter::FILE_EXTENSION
    ))
}

fn bookmark_export_file_stem(template_name: &str) -> String {
    let stem = template_name
        .trim()
        .chars()
        .map(|ch| {
            if matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || ch.is_control()
            {
                '_'
            } else {
                ch
            }
        })
        .collect::<String>();
    let stem = stem.trim_matches([' ', '.']);
    if stem.is_empty() {
        "Untitled preset".to_string()
    } else {
        stem.to_string()
    }
}

fn converted_preset_name(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        "Untitled preset".to_string()
    } else {
        format!("{trimmed} (preset)")
    }
}

fn converted_bookmark_name(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        "Untitled bookmark".to_string()
    } else {
        format!("{trimmed} (bookmark)")
    }
}

fn search_match_count_label(total: usize) -> String {
    if total == 1 {
        "1 match".to_string()
    } else {
        format!("{total} matches")
    }
}

fn desktop_paste_mode_for_key_event(event: DesktopKeyEvent) -> Option<TerminalPasteMode> {
    if event.modifiers.control && !event.modifiers.alt && event.modifiers.shift {
        return match event.key {
            DesktopKey::Character('v') | DesktopKey::Character('V') => {
                Some(TerminalPasteMode::Plain)
            }
            _ => None,
        };
    }

    None
}

fn desktop_command_effect(result: AppCommandExecutionResult) -> DesktopCommandEffect {
    match result {
        AppCommandExecutionResult::Applied => DesktopCommandEffect::Repaint,
        AppCommandExecutionResult::OpenPathWithTarget {
            path,
            target_id,
            target_name,
            app_path,
        } => DesktopCommandEffect::OpenPathWithTarget {
            path,
            target_id,
            target_name,
            app_path,
        },
        AppCommandExecutionResult::OpenServer { url, .. }
        | AppCommandExecutionResult::OpenUrl { url } => DesktopCommandEffect::OpenUrl { url },
        AppCommandExecutionResult::RequestCloseWindow { window_id } => {
            DesktopCommandEffect::CloseWindow { window_id }
        }
        AppCommandExecutionResult::RequestNewWindow { working_directory } => {
            DesktopCommandEffect::NewWindow { working_directory }
        }
        AppCommandExecutionResult::RequestMovePaneToNewWindow { pane_id } => {
            DesktopCommandEffect::MovePaneToNewWindow { pane_id }
        }
        other => DesktopCommandEffect::Status {
            message: desktop_command_status_message(&other),
        },
    }
}

fn open_server_url_effect(
    url: &str,
    browser: &Option<ServerBrowserOpenTarget>,
) -> DesktopCommandEffect {
    if let Some(browser) = browser {
        DesktopCommandEffect::OpenUrlWithBrowser {
            url: url.to_string(),
            browser_id: browser.stable_id.clone(),
            browser_name: browser.display_name.clone(),
            app_path: browser.app_path.clone(),
        }
    } else {
        DesktopCommandEffect::OpenUrl {
            url: url.to_string(),
        }
    }
}

fn desktop_palette_effect(result: CommandPaletteItemExecutionResult) -> DesktopCommandEffect {
    match result {
        CommandPaletteItemExecutionResult::Applied => DesktopCommandEffect::Repaint,
        CommandPaletteItemExecutionResult::OpenPathWithTarget {
            path,
            target_id,
            target_name,
            app_path,
        } => DesktopCommandEffect::OpenPathWithTarget {
            path,
            target_id,
            target_name,
            app_path,
        },
        CommandPaletteItemExecutionResult::OpenServer { url, .. }
        | CommandPaletteItemExecutionResult::OpenUrl { url } => {
            DesktopCommandEffect::OpenUrl { url }
        }
        CommandPaletteItemExecutionResult::RequestCloseWindow { window_id } => {
            DesktopCommandEffect::CloseWindow { window_id }
        }
        CommandPaletteItemExecutionResult::RequestNewWindow { working_directory } => {
            DesktopCommandEffect::NewWindow { working_directory }
        }
        CommandPaletteItemExecutionResult::RequestMovePaneToNewWindow { pane_id } => {
            DesktopCommandEffect::MovePaneToNewWindow { pane_id }
        }
        other => DesktopCommandEffect::Status {
            message: desktop_palette_status_message(&other),
        },
    }
}

fn settings_section_from_raw_value(raw_value: &str) -> Option<SettingsSection> {
    SettingsSection::ALL
        .into_iter()
        .find(|section| section.raw_value() == raw_value)
}

fn enabled_label(value: bool) -> &'static str {
    if value { "enabled" } else { "disabled" }
}

fn optional_setting(value: Option<&str>) -> String {
    value
        .and_then(trimmed_non_empty)
        .unwrap_or("default")
        .to_string()
}

fn joined_or_none(values: &[String]) -> String {
    if values.is_empty() {
        "none".to_string()
    } else {
        values.join(", ")
    }
}

fn appearance_theme_mode_token(mode: AppearanceThemeMode) -> &'static str {
    match mode {
        AppearanceThemeMode::FollowMacOS => "followMacOS",
        AppearanceThemeMode::AlwaysDark => "alwaysDark",
        AppearanceThemeMode::AlwaysLight => "alwaysLight",
    }
}

fn pane_split_behavior_token(mode: PaneSplitBehaviorMode) -> &'static str {
    match mode {
        PaneSplitBehaviorMode::Adaptive => "adaptive",
        PaneSplitBehaviorMode::AlwaysSplit => "alwaysSplit",
        PaneSplitBehaviorMode::AlwaysAdd => "alwaysAdd",
    }
}

fn new_worklane_placement_token(placement: NewWorklanePlacement) -> &'static str {
    match placement {
        NewWorklanePlacement::Top => "top",
        NewWorklanePlacement::AfterCurrent => "after_current",
        NewWorklanePlacement::End => "end",
    }
}

fn focus_follows_mouse_delay_token(delay: FocusFollowsMouseDelay) -> &'static str {
    match delay {
        FocusFollowsMouseDelay::Immediate => "immediate",
        FocusFollowsMouseDelay::Short => "short",
    }
}

fn open_with_target_label(target_id: &str, targets: &[OpenWithResolvedTarget]) -> String {
    targets
        .iter()
        .find(|target| target.stable_id == target_id)
        .map(|target| format!("{} ({})", target.display_name, target.stable_id))
        .unwrap_or_else(|| target_id.to_string())
}

fn next_open_with_primary_target_id(
    current_target_id: &str,
    enabled_target_ids: &[String],
    targets: &[OpenWithResolvedTarget],
) -> Option<String> {
    let enabled_ids: HashSet<&str> = enabled_target_ids.iter().map(String::as_str).collect();
    let candidates = targets
        .iter()
        .filter(|target| enabled_ids.contains(target.stable_id.as_str()))
        .map(|target| target.stable_id.as_str())
        .collect::<Vec<_>>();
    if candidates.is_empty() {
        return None;
    }
    let next_index = candidates
        .iter()
        .position(|target_id| *target_id == current_target_id)
        .map(|index| (index + 1) % candidates.len())
        .unwrap_or(0);
    Some(candidates[next_index].to_string())
}

fn toggle_open_with_target(config: &mut AppConfig, target_id: &str, available_order: &[String]) {
    let mut enabled_ids = config
        .open_with
        .enabled_target_ids
        .iter()
        .cloned()
        .collect::<HashSet<_>>();
    if !enabled_ids.insert(target_id.to_string()) {
        enabled_ids.remove(target_id);
    }

    let mut ordered_enabled_ids = Vec::new();
    for candidate in available_order {
        if enabled_ids.remove(candidate) {
            ordered_enabled_ids.push(candidate.clone());
        }
    }
    for candidate in &config.open_with.enabled_target_ids {
        if enabled_ids.remove(candidate) {
            ordered_enabled_ids.push(candidate.clone());
        }
    }

    config.open_with.enabled_target_ids = ordered_enabled_ids;
    if !config
        .open_with
        .enabled_target_ids
        .iter()
        .any(|enabled_id| enabled_id == &config.open_with.primary_target_id)
    {
        config.open_with.primary_target_id = fallback_open_with_primary_target_id(
            &config.open_with.enabled_target_ids,
            available_order,
        );
    }
}

fn fallback_open_with_primary_target_id(
    enabled_target_ids: &[String],
    available_order: &[String],
) -> String {
    available_order
        .iter()
        .find(|target_id| enabled_target_ids.contains(target_id))
        .cloned()
        .or_else(|| enabled_target_ids.first().cloned())
        .unwrap_or_else(|| "finder".to_string())
}

fn server_browser_target_label(target_id: &str, targets: &[ServerBrowserOpenTarget]) -> String {
    if target_id == "system-default" {
        return "System Default (system-default)".to_string();
    }
    targets
        .iter()
        .find(|target| target.stable_id == target_id)
        .map(|target| format!("{} ({})", target.display_name, target.stable_id))
        .unwrap_or_else(|| target_id.to_string())
}

fn server_browser_enabled_ids<'a>(
    configured_enabled_ids: &'a [String],
    targets: &'a [ServerBrowserOpenTarget],
) -> HashSet<&'a str> {
    if configured_enabled_ids.is_empty() {
        return targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect();
    }
    configured_enabled_ids.iter().map(String::as_str).collect()
}

fn next_server_browser_preferred_target_id(
    current_target_id: &str,
    enabled_target_ids: &[String],
    targets: &[ServerBrowserOpenTarget],
) -> String {
    let enabled_ids = server_browser_enabled_ids(enabled_target_ids, targets);
    let mut candidates = vec!["system-default"];
    candidates.extend(
        targets
            .iter()
            .filter(|target| enabled_ids.contains(target.stable_id.as_str()))
            .map(|target| target.stable_id.as_str()),
    );
    let next_index = candidates
        .iter()
        .position(|target_id| *target_id == current_target_id)
        .map(|index| (index + 1) % candidates.len())
        .unwrap_or(0);
    candidates[next_index].to_string()
}

fn toggle_server_browser_target(
    config: &mut AppConfig,
    target_id: &str,
    available_order: &[String],
) {
    let mut enabled_ids = if config
        .server_detection
        .enabled_browser_target_ids
        .is_empty()
    {
        available_order.iter().cloned().collect::<HashSet<_>>()
    } else {
        config
            .server_detection
            .enabled_browser_target_ids
            .iter()
            .cloned()
            .collect::<HashSet<_>>()
    };
    if !enabled_ids.insert(target_id.to_string()) {
        enabled_ids.remove(target_id);
    }

    let mut ordered_enabled_ids = Vec::new();
    for candidate in available_order {
        if enabled_ids.remove(candidate) {
            ordered_enabled_ids.push(candidate.clone());
        }
    }
    for candidate in &config.server_detection.enabled_browser_target_ids {
        if enabled_ids.remove(candidate) {
            ordered_enabled_ids.push(candidate.clone());
        }
    }

    config.server_detection.enabled_browser_target_ids = ordered_enabled_ids;
    if config.server_detection.preferred_browser_id != "system-default"
        && !config
            .server_detection
            .enabled_browser_target_ids
            .iter()
            .any(|enabled_id| enabled_id == &config.server_detection.preferred_browser_id)
    {
        config.server_detection.preferred_browser_id = fallback_server_browser_preferred_target_id(
            &config.server_detection.enabled_browser_target_ids,
            available_order,
        );
    }
}

fn fallback_server_browser_preferred_target_id(
    enabled_target_ids: &[String],
    available_order: &[String],
) -> String {
    available_order
        .iter()
        .find(|target_id| enabled_target_ids.contains(target_id))
        .cloned()
        .or_else(|| enabled_target_ids.first().cloned())
        .unwrap_or_else(|| "system-default".to_string())
}

fn inactive_pane_opacity_token(opacity: f64) -> String {
    format!(
        "{:.0}%",
        opacity.clamp(
            PanesConfig::MINIMUM_INACTIVE_OPACITY,
            PanesConfig::MAXIMUM_INACTIVE_OPACITY,
        ) * 100.0
    )
}

fn next_focus_follows_mouse_delay(delay: FocusFollowsMouseDelay) -> FocusFollowsMouseDelay {
    match delay {
        FocusFollowsMouseDelay::Immediate => FocusFollowsMouseDelay::Short,
        FocusFollowsMouseDelay::Short => FocusFollowsMouseDelay::Immediate,
    }
}

fn next_inactive_pane_opacity(opacity: f64) -> f64 {
    const STEPS: [f64; 5] = [0.6, 0.7, 0.8, 0.9, 1.0];
    let opacity = opacity.clamp(
        PanesConfig::MINIMUM_INACTIVE_OPACITY,
        PanesConfig::MAXIMUM_INACTIVE_OPACITY,
    );
    STEPS
        .iter()
        .copied()
        .find(|candidate| *candidate > opacity + f64::EPSILON)
        .unwrap_or(STEPS[0])
}

const NOTIFICATION_SYSTEM_SOUNDS: [&str; 14] = [
    "Basso",
    "Blow",
    "Bottle",
    "Frog",
    "Funk",
    "Glass",
    "Hero",
    "Morse",
    "Ping",
    "Pop",
    "Purr",
    "Sosumi",
    "Submarine",
    "Tink",
];

const WINDOWS_NOTIFICATION_SETTINGS_URL: &str = "ms-settings:notifications";

fn notification_sound_label(sound_name: &str, custom_display_name: Option<&str>) -> String {
    if sound_name.is_empty() {
        "Default".to_string()
    } else if is_custom_notification_sound_name(sound_name) {
        format!(
            "Custom: {}",
            custom_display_name
                .and_then(trimmed_non_empty)
                .unwrap_or("Custom Sound")
        )
    } else {
        sound_name.to_string()
    }
}

fn next_notification_sound_name(current: &str) -> String {
    if current.is_empty() {
        return NOTIFICATION_SYSTEM_SOUNDS[0].to_string();
    }
    NOTIFICATION_SYSTEM_SOUNDS
        .iter()
        .position(|candidate| *candidate == current)
        .and_then(|index| NOTIFICATION_SYSTEM_SOUNDS.get(index + 1))
        .map(|sound| (*sound).to_string())
        .unwrap_or_default()
}

fn is_custom_notification_sound_name(name: &str) -> bool {
    name.starts_with("zentty-custom-") && name.ends_with(".caf")
}

fn update_channel_token(channel: AppUpdateChannel) -> &'static str {
    match channel {
        AppUpdateChannel::Stable => "stable",
        AppUpdateChannel::Beta => "beta",
    }
}

fn next_theme_mode(mode: AppearanceThemeMode) -> AppearanceThemeMode {
    match mode {
        AppearanceThemeMode::FollowMacOS => AppearanceThemeMode::AlwaysDark,
        AppearanceThemeMode::AlwaysDark => AppearanceThemeMode::AlwaysLight,
        AppearanceThemeMode::AlwaysLight => AppearanceThemeMode::FollowMacOS,
    }
}

fn next_pane_split_behavior(mode: PaneSplitBehaviorMode) -> PaneSplitBehaviorMode {
    match mode {
        PaneSplitBehaviorMode::Adaptive => PaneSplitBehaviorMode::AlwaysSplit,
        PaneSplitBehaviorMode::AlwaysSplit => PaneSplitBehaviorMode::AlwaysAdd,
        PaneSplitBehaviorMode::AlwaysAdd => PaneSplitBehaviorMode::Adaptive,
    }
}

fn next_visible_split_window_width(width: u32) -> u32 {
    const WIDTHS: [u32; 5] = [1200, 1440, 1680, 1920, 2560];
    WIDTHS
        .iter()
        .position(|candidate| *candidate == width)
        .map(|index| WIDTHS[(index + 1) % WIDTHS.len()])
        .unwrap_or(1920)
}

fn next_worklane_placement(placement: NewWorklanePlacement) -> NewWorklanePlacement {
    match placement {
        NewWorklanePlacement::Top => NewWorklanePlacement::AfterCurrent,
        NewWorklanePlacement::AfterCurrent => NewWorklanePlacement::End,
        NewWorklanePlacement::End => NewWorklanePlacement::Top,
    }
}

fn next_update_channel(channel: AppUpdateChannel) -> AppUpdateChannel {
    match channel {
        AppUpdateChannel::Stable => AppUpdateChannel::Beta,
        AppUpdateChannel::Beta => AppUpdateChannel::Stable,
    }
}

fn desktop_command_status_message(result: &AppCommandExecutionResult) -> String {
    match result {
        AppCommandExecutionResult::Unavailable => "Command unavailable".to_string(),
        AppCommandExecutionResult::Unsupported => "Command unsupported in desktop mode".to_string(),
        AppCommandExecutionResult::ShowPaneSearch { pane_id } => {
            format!("Find requested for pane {pane_id}")
        }
        AppCommandExecutionResult::ShowGlobalSearch => "Global find requested".to_string(),
        AppCommandExecutionResult::UseSelectionForFind { pane_id } => {
            format!("Use selection for find requested for pane {pane_id}")
        }
        AppCommandExecutionResult::FindNext { pane_id } => {
            format!("Find next requested for pane {pane_id}")
        }
        AppCommandExecutionResult::FindPrevious { pane_id } => {
            format!("Find previous requested for pane {pane_id}")
        }
        AppCommandExecutionResult::CopyText { text } => {
            format!("Copy text requested: {text}")
        }
        AppCommandExecutionResult::CopySelection { mode } => {
            format!("Copy selection requested: {mode}")
        }
        AppCommandExecutionResult::BeginRenameWorklane { worklane_id } => {
            format!("Rename worklane requested: {worklane_id}")
        }
        AppCommandExecutionResult::JumpToLatestNotification => {
            "Jump to latest notification requested".to_string()
        }
        AppCommandExecutionResult::RequestNewWindow { working_directory } => {
            if let Some(path) = working_directory {
                format!("New window requested: {path}")
            } else {
                "New window requested".to_string()
            }
        }
        AppCommandExecutionResult::RequestMovePaneToNewWindow { pane_id } => {
            format!("Move pane to new window requested: {pane_id}")
        }
        AppCommandExecutionResult::OpenPathWithTarget {
            path, target_name, ..
        } => {
            format!("Open {path} with {target_name} requested")
        }
        AppCommandExecutionResult::OpenServer { url, .. } => {
            format!("Open server requested: {url}")
        }
        AppCommandExecutionResult::OpenUrl { url } => format!("Open URL requested: {url}"),
        AppCommandExecutionResult::RestoredClosedPane { pane_id, .. } => {
            format!("Restored closed pane {pane_id}")
        }
        AppCommandExecutionResult::ToggleSidebar => "Toggle sidebar requested".to_string(),
        AppCommandExecutionResult::ShowCommandPalette => "Command palette requested".to_string(),
        AppCommandExecutionResult::ShowSettings { section } => {
            format!("Settings requested: {section}")
        }
        AppCommandExecutionResult::ShowTaskManager => "Task manager requested".to_string(),
        AppCommandExecutionResult::ReloadConfiguration => {
            "Reload configuration requested".to_string()
        }
        AppCommandExecutionResult::OpenBookmarksPopover => "Bookmarks requested".to_string(),
        AppCommandExecutionResult::SetThemeMode { mode } => {
            format!("Theme mode requested: {mode}")
        }
        AppCommandExecutionResult::SetWorklaneColor { worklane_id, color } => {
            format!("Set worklane color requested: {worklane_id} -> {color:?}")
        }
        AppCommandExecutionResult::RequestCloseWindow { window_id } => {
            format!("Close window requested: {window_id}")
        }
        AppCommandExecutionResult::Applied => "Command applied".to_string(),
    }
}

fn desktop_palette_status_message(result: &CommandPaletteItemExecutionResult) -> String {
    match result {
        CommandPaletteItemExecutionResult::Unavailable => "Command unavailable".to_string(),
        CommandPaletteItemExecutionResult::Unsupported => {
            "Command unsupported in desktop mode".to_string()
        }
        CommandPaletteItemExecutionResult::RunRestoredCommand { pane_id, command } => {
            format!("Run restored command requested for {pane_id}: {command}")
        }
        CommandPaletteItemExecutionResult::ShowPaneSearch { pane_id } => {
            format!("Find requested for pane {pane_id}")
        }
        CommandPaletteItemExecutionResult::ShowGlobalSearch => "Global find requested".to_string(),
        CommandPaletteItemExecutionResult::UseSelectionForFind { pane_id } => {
            format!("Use selection for find requested for pane {pane_id}")
        }
        CommandPaletteItemExecutionResult::FindNext { pane_id } => {
            format!("Find next requested for pane {pane_id}")
        }
        CommandPaletteItemExecutionResult::FindPrevious { pane_id } => {
            format!("Find previous requested for pane {pane_id}")
        }
        CommandPaletteItemExecutionResult::CopyText { text } => {
            format!("Copy text requested: {text}")
        }
        CommandPaletteItemExecutionResult::CopySelection { mode } => {
            format!("Copy selection requested: {mode}")
        }
        CommandPaletteItemExecutionResult::BeginRenameWorklane { worklane_id } => {
            format!("Rename worklane requested: {worklane_id}")
        }
        CommandPaletteItemExecutionResult::JumpToLatestNotification => {
            "Jump to latest notification requested".to_string()
        }
        CommandPaletteItemExecutionResult::RequestNewWindow { working_directory } => {
            if let Some(path) = working_directory {
                format!("New window requested: {path}")
            } else {
                "New window requested".to_string()
            }
        }
        CommandPaletteItemExecutionResult::RequestMovePaneToNewWindow { pane_id } => {
            format!("Move pane to new window requested: {pane_id}")
        }
        CommandPaletteItemExecutionResult::OpenPathWithTarget {
            path, target_name, ..
        } => {
            format!("Open {path} with {target_name} requested")
        }
        CommandPaletteItemExecutionResult::OpenServer { url, .. } => {
            format!("Open server requested: {url}")
        }
        CommandPaletteItemExecutionResult::OpenUrl { url } => {
            format!("Open URL requested: {url}")
        }
        CommandPaletteItemExecutionResult::RestoredClosedPane { pane_id, .. } => {
            format!("Restored closed pane {pane_id}")
        }
        CommandPaletteItemExecutionResult::ShowSettings { section } => {
            format!("Settings requested: {section}")
        }
        CommandPaletteItemExecutionResult::ToggleSidebar => "Toggle sidebar requested".to_string(),
        CommandPaletteItemExecutionResult::ShowCommandPalette => {
            "Command palette requested".to_string()
        }
        CommandPaletteItemExecutionResult::ShowTaskManager => "Task manager requested".to_string(),
        CommandPaletteItemExecutionResult::ReloadConfiguration => {
            "Reload configuration requested".to_string()
        }
        CommandPaletteItemExecutionResult::OpenBookmarksPopover => {
            "Bookmarks requested".to_string()
        }
        CommandPaletteItemExecutionResult::SetThemeMode { mode } => {
            format!("Theme mode requested: {mode}")
        }
        CommandPaletteItemExecutionResult::SetWorklaneColor { worklane_id, color } => {
            format!("Set worklane color requested: {worklane_id} -> {color:?}")
        }
        CommandPaletteItemExecutionResult::OpenTaskRunnerSource { source_path } => {
            format!("Open task source requested: {source_path}")
        }
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane { pane_id, command } => {
            format!("Run task in new pane requested for {pane_id}: {command}")
        }
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane { pane_id, command } => {
            format!("Run task in focused pane requested for {pane_id}: {command}")
        }
        CommandPaletteItemExecutionResult::RequestCloseWindow { window_id } => {
            format!("Close window requested: {window_id}")
        }
        CommandPaletteItemExecutionResult::Applied => "Command applied".to_string(),
    }
}

fn next_value<I>(args: &mut I, option: &str) -> Result<String, DesktopShellConfigError>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| DesktopShellConfigError::MissingValue(option.to_string()))
}

fn parse_dimension(option: &str, value: &str) -> Result<u16, DesktopShellConfigError> {
    value
        .parse()
        .map_err(|_| DesktopShellConfigError::InvalidNumber {
            option: option.to_string(),
            value: value.to_string(),
        })
}

#[cfg(windows)]
mod native_window {
    use std::cell::RefCell;
    use std::iter;
    use std::ptr::null_mut;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use zentty_core::agent::{AgentIpcRequest, AgentIpcResponse};
    use zentty_terminal::clipboard::TerminalClipboardPaste;

    use windows::Win32::Foundation::{HANDLE, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::Graphics::Dwm::{DWMWA_USE_IMMERSIVE_DARK_MODE, DwmSetWindowAttribute};
    use windows::Win32::Graphics::Gdi::{InvalidateRect, ValidateRect};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, GetClipboardData, IsClipboardFormatAvailable,
        OpenClipboard, SetClipboardData,
    };
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::HiDpi::{
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
    };
    use windows::Win32::System::Memory::{
        GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
    };
    use windows::Win32::System::Ole::CF_UNICODETEXT;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetKeyState, ReleaseCapture, SetCapture, VIRTUAL_KEY, VK_CONTROL, VK_MENU, VK_SHIFT,
    };
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::{
        CS_DBLCLKS, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CreateWindowExW, DefWindowProcW,
        DestroyWindow, DispatchMessageW, FlashWindow, GWLP_USERDATA, GetCaretBlinkTime, GetMessageW,
        GetWindowLongPtrW, IDC_ARROW, IDYES, KillTimer, LoadCursorW, MB_ICONWARNING, MB_YESNO, MSG,
        LoadIconW, MessageBoxW, PostQuitMessage, RegisterClassW, SW_SHOW, SW_SHOWNA, SW_SHOWNORMAL,
        SetTimer,
        SetWindowTextW,
        SetWindowLongPtrW, ShowWindow, TranslateMessage, WINDOW_EX_STYLE, WM_CHAR, WM_CLOSE,
        WM_DESTROY, WM_KEYDOWN, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
        WM_MOUSEWHEEL, WM_PAINT, WM_SIZE, WM_TIMER, WNDCLASSW, WS_OVERLAPPEDWINDOW, WS_VISIBLE,
    };
    use windows::core::{BOOL, PCWSTR};

    use crate::ipc::AgentIpcNamedPipeListener;

    use super::{
        AppCommandId, DEFAULT_WINDOW_TITLE, DESKTOP_TEXT_LEFT, DESKTOP_TEXT_TOP,
        DesktopAgentIpcAppliedRequest, DesktopCommandEffect, DesktopKeyEvent,
        DesktopKeyModifiers, DesktopMouseButton, DesktopMouseEventKind, DesktopWindowError,
        DesktopWindowSession, PaneNotification, agent_ipc_error_is_routable,
        agent_ipc_error_response_if_expected, agent_ipc_pane_not_found_rejection,
        agent_ipc_server_state_success_response_if_expected,
        agent_ipc_success_response_if_expected, desktop_key_event_from_windows_virtual_key,
        desktop_terminal_size_for_client_area,
    };
    use zentty_pty::TerminalSize;

    const OUTPUT_TIMER_ID: usize = 1;
    const OUTPUT_TIMER_MS: u32 = 30;

    /// Cursor-blink interval in output-timer ticks, from the system caret rate.
    /// `None` when blinking is disabled (rate 0 or INFINITE) — respects the
    /// user's reduced-motion / accessibility preference.
    fn caret_blink_interval_ticks() -> Option<u32> {
        let ms = unsafe { GetCaretBlinkTime() };
        if ms == 0 || ms == u32::MAX {
            None
        } else {
            Some((ms / OUTPUT_TIMER_MS).max(1))
        }
    }
    const MK_LBUTTON_MASK: usize = 0x0001;
    static OPEN_WINDOW_COUNT: AtomicUsize = AtomicUsize::new(0);
    thread_local! {
        static OPEN_WINDOW_HANDLES: RefCell<Vec<HWND>> = const { RefCell::new(Vec::new()) };
    }

    pub fn run_message_loop(session: DesktopWindowSession) -> Result<i32, DesktopWindowError> {
        unsafe {
            // Per-monitor-v2 DPI awareness so DirectWrite renders at native
            // resolution (crisp glyphs instead of bitmap-stretched). Full DPI
            // layout correctness is hardened in Phase 9. Best-effort: failure
            // (e.g. already set) is non-fatal.
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            let instance = GetModuleHandleW(None)
                .map_err(|error| DesktopWindowError::Native(error.to_string()))?;
            let hinstance = HINSTANCE(instance.0);
            let class_name = wide_null("ZenttyDesktopWindow");
            let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
            // The exe's embedded icon (winresource id 1) for the title bar,
            // taskbar, and Alt-Tab; falls back to the system default icon.
            let icon = LoadIconW(Some(hinstance), PCWSTR(std::ptr::without_provenance(1)))
                .unwrap_or_default();
            let class = WNDCLASSW {
                style: CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
                lpfnWndProc: Some(window_proc),
                hInstance: hinstance,
                hIcon: icon,
                hCursor: cursor,
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };

            let atom = RegisterClassW(&class);
            if atom == 0 {
                return Err(DesktopWindowError::Native(
                    "failed to register desktop window class".to_string(),
                ));
            }

            create_native_window(session, hinstance)?;

            let mut message = MSG::default();
            loop {
                let result = GetMessageW(&mut message, None, 0, 0);
                if result.0 == -1 {
                    return Err(DesktopWindowError::Native(
                        "failed to read desktop window message".to_string(),
                    ));
                }
                if result.0 == 0 {
                    return Ok(message.wParam.0 as i32);
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }

    unsafe fn create_native_window(
        session: DesktopWindowSession,
        hinstance: HINSTANCE,
    ) -> Result<HWND, DesktopWindowError> {
        let class_name = wide_null("ZenttyDesktopWindow");
        let title = wide_null(if session.title().trim().is_empty() {
            DEFAULT_WINDOW_TITLE
        } else {
            session.title()
        });
        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                PCWSTR(class_name.as_ptr()),
                PCWSTR(title.as_ptr()),
                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                1024,
                720,
                None,
                None,
                Some(hinstance),
                Some(null_mut()),
            )
        }
        .map_err(|error| DesktopWindowError::Native(error.to_string()))?;
        // Match the dark UI with a dark Win32 caption bar. Best-effort: older
        // Windows builds don't support this attribute, so ignore the HRESULT.
        let dark_mode = BOOL::from(true);
        let _ = unsafe {
            DwmSetWindowAttribute(
                hwnd,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                std::ptr::from_ref(&dark_mode).cast(),
                std::mem::size_of::<BOOL>() as u32,
            )
        };
        let agent_ipc_listener = session
            .agent_ipc_socket_path()
            .map(|path| AgentIpcNamedPipeListener::start(path.to_string()))
            .transpose()
            .map_err(|error| DesktopWindowError::Native(error.to_string()))?;

        let renderer = match crate::render::Renderer::new(hwnd) {
            Ok(renderer) => Some(renderer),
            Err(error) => {
                eprintln!("zentty: failed to initialize Direct2D renderer: {error}");
                None
            }
        };

        let state = Box::new(NativeWindowState {
            hinstance,
            session,
            agent_ipc_listener,
            last_error: None,
            last_status: None,
            renderer,
            // ~20 timer ticks (~600ms) so the first pane's shell banner settles
            // before the screenshot split fires.
            shot_split_countdown: std::env::var_os("ZENTTY_SHOT_SPLIT").map(|_| 20),
            shot_status: std::env::var_os("ZENTTY_SHOT_STATUS").is_some(),
            shot_search_countdown: None,
            // ~20 ticks so the first pane settles, then force the empty-state
            // render (the empty state is otherwise defensively unreachable).
            shot_empty_countdown: std::env::var_os("ZENTTY_SHOT_EMPTY").map(|_| 20),
            shot_force_empty: false,
            last_window_title: String::new(),
            cursor_on: true,
            blink_tick: 0,
        });
        let state_ptr = Box::into_raw(state);
        unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, state_ptr as isize) };

        if unsafe { SetTimer(Some(hwnd), OUTPUT_TIMER_ID, OUTPUT_TIMER_MS, None) } == 0 {
            unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) };
            drop(unsafe { Box::from_raw(state_ptr) });
            return Err(DesktopWindowError::Native(
                "failed to start desktop output timer".to_string(),
            ));
        }

        OPEN_WINDOW_COUNT.fetch_add(1, Ordering::SeqCst);
        register_native_window(hwnd);
        // Screenshot tooling sets ZENTTY_SHOT_NOACTIVATE so the window appears
        // without stealing keyboard focus (SW_SHOWNA); normal launches activate.
        let show_command = if std::env::var_os("ZENTTY_SHOT_NOACTIVATE").is_some() {
            SW_SHOWNA
        } else {
            SW_SHOW
        };
        let _ = unsafe { ShowWindow(hwnd, show_command) };

        // Size the terminal grid (and renderer) to the initial client area; the
        // creation-time WM_SIZE arrives before the state pointer is set and is
        // therefore ignored.
        if let Some(state) = unsafe { state_mut(hwnd) } {
            let mut rect = windows::Win32::Foundation::RECT::default();
            if unsafe {
                windows::Win32::UI::WindowsAndMessaging::GetClientRect(hwnd, &mut rect)
            }
            .is_ok()
            {
                let width = rect.right - rect.left;
                let height = rect.bottom - rect.top;
                if width > 0 && height > 0 {
                    state.resize_renderer(width as u32, height as u32);
                    let _ = state.resize(width, height);
                }
            }
            // Screenshot tooling: collapse the sidebar (non-persisting) to show
            // the layout shifting to full width.
            if std::env::var_os("ZENTTY_SHOT_HIDE_SIDEBAR").is_some() {
                state.session.set_sidebar_visible_for_screenshot(false);
            }
            // Apply a named theme (demonstrates runtime theme switching).
            if let Ok(name) = std::env::var("ZENTTY_SHOT_THEME")
                && let Some(theme) = zentty_core::theme::theme_by_name(&name)
                && let Some(renderer) = state.renderer.as_mut()
            {
                renderer.set_theme(theme);
            }
            // Screenshot tooling: open the command palette with a filter query.
            if std::env::var_os("ZENTTY_SHOT_PALETTE").is_some() {
                let _ = state
                    .session
                    .execute_app_command(AppCommandId::ShowCommandPalette);
                for ch in "split".chars() {
                    let _ = state.session.write_char_event(ch);
                }
            }
            // Screenshot tooling: open global search with a query (deferred so
            // the shell banner is present to match against).
            if std::env::var_os("ZENTTY_SHOT_SEARCH").is_some() {
                state.shot_search_countdown = Some(20);
            }
        }
        Ok(hwnd)
    }

    struct NativeWindowState {
        hinstance: HINSTANCE,
        session: DesktopWindowSession,
        agent_ipc_listener: Option<AgentIpcNamedPipeListener>,
        last_error: Option<String>,
        last_status: Option<String>,
        /// Direct2D/DirectWrite render surface. `None` if D2D init failed; the
        /// window then shows nothing rather than crashing the message loop.
        renderer: Option<crate::render::Renderer>,
        /// Screenshot tooling: timer ticks remaining before a one-shot
        /// horizontal split (so the first pane's content settles first).
        shot_split_countdown: Option<u32>,
        /// Screenshot tooling: keep injecting representative agent statuses so
        /// the sidebar shows distinct pills.
        shot_status: bool,
        /// Screenshot tooling: ticks remaining before opening global search.
        shot_search_countdown: Option<u32>,
        /// Screenshot tooling: ticks remaining before forcing the empty-state
        /// render so its placeholder can be captured.
        shot_empty_countdown: Option<u32>,
        /// Screenshot tooling: when set, `render` takes the empty-state path
        /// regardless of how many panes exist.
        shot_force_empty: bool,
        /// Last window caption set, to avoid redundant SetWindowTextW calls.
        last_window_title: String,
        /// Cursor blink phase (true = block shown) and tick accumulator.
        cursor_on: bool,
        blink_tick: u32,
    }

    impl NativeWindowState {
        fn poll_output(&mut self) -> bool {
            match self.session.poll_output() {
                Ok(changed) => changed,
                Err(error) => {
                    self.last_error = Some(error.to_string());
                    true
                }
            }
        }

        /// Screenshot tooling: count down and fire a one-shot horizontal split
        /// once the first pane's content has settled. Returns true on the tick
        /// that performs the split (so the caller repaints).
        fn tick_shot_split(&mut self, hwnd: HWND) -> bool {
            let Some(remaining) = self.shot_split_countdown else {
                return false;
            };
            if remaining > 0 {
                self.shot_split_countdown = Some(remaining - 1);
                return false;
            }
            self.shot_split_countdown = None;
            // Split only — no PTY resize. The window size is unchanged, and
            // resizing the source pane's ConPTY would clear its idle shell.
            let _ = self
                .session
                .execute_app_command(AppCommandId::SplitHorizontally);
            let _ = hwnd;
            true
        }

        /// Screenshot tooling: open global search with a query once the shell
        /// banner is present to match against.
        fn tick_shot_search(&mut self) -> bool {
            let Some(remaining) = self.shot_search_countdown else {
                return false;
            };
            if remaining > 0 {
                self.shot_search_countdown = Some(remaining - 1);
                return false;
            }
            self.shot_search_countdown = None;
            let _ = self.session.execute_app_command(AppCommandId::GlobalFind);
            for ch in "Windows".chars() {
                let _ = self.session.write_char_event(ch);
            }
            true
        }

        /// Screenshot tooling: once the first pane has settled, force the
        /// empty-state render so its placeholder can be captured (the empty
        /// state is otherwise defensively unreachable). Returns true on the
        /// tick that flips the flag (so the caller repaints).
        fn tick_shot_empty(&mut self) -> bool {
            let Some(remaining) = self.shot_empty_countdown else {
                return false;
            };
            if remaining > 0 {
                self.shot_empty_countdown = Some(remaining - 1);
                return false;
            }
            self.shot_empty_countdown = None;
            self.shot_force_empty = true;
            true
        }

        /// Update the OS window caption from the focused pane's (shell-set)
        /// title; skips the SetWindowTextW call when unchanged.
        fn update_window_title(&mut self, hwnd: HWND) {
            let title = self.session.window_title();
            if title != self.last_window_title {
                let wide = wide_null(&title);
                let _ = unsafe { SetWindowTextW(hwnd, PCWSTR(wide.as_ptr())) };
                self.last_window_title = title;
            }
        }

        fn poll_agent_ipc(&mut self, hwnd: HWND) -> bool {
            let mut changed = false;
            loop {
                let Some(request) = self
                    .agent_ipc_listener
                    .as_ref()
                    .and_then(AgentIpcNamedPipeListener::try_recv)
                else {
                    break;
                };
                let response = self
                    .handle_agent_ipc_request_across_native_windows(hwnd, request.request.clone());
                request.respond(response);
                changed = true;
            }
            changed
        }

        fn handle_agent_ipc_request_across_native_windows(
            &mut self,
            hwnd: HWND,
            request: AgentIpcRequest,
        ) -> Option<AgentIpcResponse> {
            let mut deferred_error = match self.session.apply_agent_ipc_request(&request) {
                Ok(result) => {
                    return self.agent_ipc_response_for_applied_request(hwnd, &request, result);
                }
                Err(error) if agent_ipc_error_is_routable(&error) => Some(error),
                Err(error) => {
                    return agent_ipc_error_response_if_expected(
                        &request,
                        error.code,
                        &error.message,
                    );
                }
            };

            for other_hwnd in other_native_window_handles(hwnd) {
                let Some(other_state) = (unsafe { state_mut(other_hwnd) }) else {
                    continue;
                };
                match other_state.session.apply_agent_ipc_request(&request) {
                    Ok(result) => {
                        return other_state
                            .agent_ipc_response_for_applied_request(other_hwnd, &request, result);
                    }
                    Err(error) if agent_ipc_error_is_routable(&error) => {
                        if deferred_error.is_none() {
                            deferred_error = Some(error);
                        }
                    }
                    Err(error) => {
                        return agent_ipc_error_response_if_expected(
                            &request,
                            error.code,
                            &error.message,
                        );
                    }
                }
            }

            let error = deferred_error.unwrap_or_else(agent_ipc_pane_not_found_rejection);
            agent_ipc_error_response_if_expected(&request, error.code, &error.message)
        }

        fn agent_ipc_response_for_applied_request(
            &mut self,
            hwnd: HWND,
            request: &AgentIpcRequest,
            result: DesktopAgentIpcAppliedRequest,
        ) -> Option<AgentIpcResponse> {
            match result {
                DesktopAgentIpcAppliedRequest::NewWindow(session) => {
                    match unsafe { create_native_window(*session, self.hinstance) } {
                        Ok(_) => agent_ipc_success_response_if_expected(request),
                        Err(error) => agent_ipc_error_response_if_expected(
                            request,
                            "grid_window_spawn_failed",
                            &format!("Grid window failed: {error}"),
                        ),
                    }
                }
                DesktopAgentIpcAppliedRequest::OpenServer {
                    url,
                    browser,
                    server_state,
                } => {
                    self.record_effect(&super::open_server_url_effect(&url, &browser));
                    agent_ipc_server_state_success_response_if_expected(request, server_state)
                }
                DesktopAgentIpcAppliedRequest::PaneNotification(notification) => {
                    let effect = DesktopCommandEffect::PaneNotification {
                        notification: notification.clone(),
                    };
                    self.record_effect(&effect);
                    unsafe { cue_native_notification(hwnd, &notification) };
                    agent_ipc_success_response_if_expected(request)
                }
                other => other.response_if_expected(request),
            }
        }

        fn write_char(&mut self, ch: char) -> DesktopCommandEffect {
            match self.session.write_char_event(ch) {
                Ok(effect) => {
                    self.record_effect(&effect);
                    effect
                }
                Err(error) => {
                    // A write to a pane whose shell already exited fails; that
                    // pane is about to be auto-closed, so don't raise the
                    // window-global error banner for it.
                    if !self.session.focused_pane_has_exited() {
                        self.last_error = Some(error.to_string());
                    }
                    DesktopCommandEffect::Repaint
                }
            }
        }

        fn execute_key_event(&mut self, event: DesktopKeyEvent) -> DesktopCommandEffect {
            let effect = self.session.execute_key_event(event);
            self.record_effect(&effect);
            effect
        }

        fn request_close_window(&mut self) -> DesktopCommandEffect {
            let effect = self.session.execute_app_command(AppCommandId::CloseWindow);
            self.record_effect(&effect);
            effect
        }

        fn execute_confirmed_app_command(
            &mut self,
            command_id: AppCommandId,
        ) -> DesktopCommandEffect {
            let effect = self.session.execute_confirmed_app_command(command_id);
            self.record_effect(&effect);
            effect
        }

        fn resize(&mut self, width_pixels: i32, height_pixels: i32) -> DesktopCommandEffect {
            // All panes share the window-sized PTY; the renderer clips each
            // pane's grid to its layout rect. Per-pane PTY sizing is deferred
            // until ConPTY resize repaint is handled (resizing an idle pane's
            // ConPTY currently clears it — see the worklane notes).
            let size = self.terminal_size_for_client(width_pixels, height_pixels);
            match self.session.resize(size) {
                Ok(()) => {
                    self.last_status = None;
                    DesktopCommandEffect::Repaint
                }
                Err(error) => {
                    // The per-pane resize loop aborts on a pane whose shell
                    // already exited; that pane is about to be auto-closed, so
                    // don't raise the window-global error banner for it.
                    if !self.session.any_pane_has_exited() {
                        self.last_error = Some(error.to_string());
                    }
                    DesktopCommandEffect::Repaint
                }
            }
        }

        fn execute_mouse_event(
            &mut self,
            kind: DesktopMouseEventKind,
            x_pixels: i32,
            y_pixels: i32,
        ) -> DesktopCommandEffect {
            let Some((row, column)) = self.session_render_cell_for_client_point(x_pixels, y_pixels)
            else {
                return DesktopCommandEffect::Ignored;
            };
            let effect = self.session.execute_mouse_event_at_render_cell(
                DesktopMouseButton::Left,
                kind,
                row,
                column,
            );
            self.record_effect(&effect);
            effect
        }

        fn record_effect(&mut self, effect: &DesktopCommandEffect) {
            match &effect {
                DesktopCommandEffect::Ignored => {}
                DesktopCommandEffect::Repaint | DesktopCommandEffect::CloseWindow { .. } => {
                    self.last_status = None;
                }
                DesktopCommandEffect::CopyText { text, was_cleaned } => {
                    self.last_status = match unsafe { copy_text_to_windows_clipboard(text) } {
                        Ok(()) if *was_cleaned => Some("Copied (cleaned)".to_string()),
                        Ok(()) => Some("Copied".to_string()),
                        Err(error) => Some(format!("Copy failed: {error}")),
                    };
                }
                DesktopCommandEffect::PasteFromClipboard { mode } => {
                    self.last_status = match unsafe { read_text_from_windows_clipboard() } {
                        Ok(Some(text)) => {
                            let paste = TerminalClipboardPaste::Text(text);
                            match self.session.paste_to_focused(&paste, *mode) {
                                Ok(()) => None,
                                Err(error) => Some(format!("Paste failed: {error}")),
                            }
                        }
                        Ok(None) => Some("Clipboard does not contain text".to_string()),
                        Err(error) => Some(format!("Paste failed: {error}")),
                    };
                }
                DesktopCommandEffect::OpenPathWithTarget {
                    path,
                    target_name,
                    app_path,
                    ..
                } => {
                    self.last_status =
                        match unsafe { open_path_with_windows_shell(path, app_path.as_deref()) } {
                            Ok(()) => None,
                            Err(error) => {
                                Some(format!("Open {path} with {target_name} failed: {error}"))
                            }
                        };
                }
                DesktopCommandEffect::OpenUrl { url } => {
                    self.last_status = match unsafe { open_url_with_windows_shell(url) } {
                        Ok(()) => None,
                        Err(error) => Some(format!("Open URL failed: {error}")),
                    };
                }
                DesktopCommandEffect::OpenUrlWithBrowser {
                    url,
                    browser_name,
                    app_path,
                    ..
                } => {
                    self.last_status = match unsafe {
                        open_url_with_browser_windows_shell(url, app_path)
                    } {
                        Ok(()) => None,
                        Err(error) => Some(format!("Open URL with {browser_name} failed: {error}")),
                    };
                }
                DesktopCommandEffect::PaneNotification { notification } => {
                    self.last_status = Some(format!(
                        "Notification: {} - {}",
                        notification.title,
                        notification.primary_text()
                    ));
                }
                DesktopCommandEffect::NewWindow { working_directory } => {
                    self.last_status = match self
                        .session
                        .spawn_new_window_session(working_directory.clone())
                    {
                        Ok(session) => {
                            match unsafe { create_native_window(session, self.hinstance) } {
                                Ok(_) => None,
                                Err(error) => Some(format!("New window failed: {error}")),
                            }
                        }
                        Err(error) => Some(format!("New window failed: {error}")),
                    };
                }
                DesktopCommandEffect::MovePaneToNewWindow { pane_id } => {
                    self.last_status =
                        match self.session.detach_focused_pane_to_new_window_session() {
                            Some(session) => {
                                match unsafe { create_native_window(session, self.hinstance) } {
                                    Ok(_) => None,
                                    Err(error) => Some(format!(
                                        "Move pane {pane_id} to new window failed: {error}"
                                    )),
                                }
                            }
                            None => Some(format!("Move pane {pane_id} to new window unavailable")),
                        };
                }
                DesktopCommandEffect::ConfirmClosePane { .. }
                | DesktopCommandEffect::ConfirmCloseWindow { .. } => {
                    self.last_status = None;
                }
                DesktopCommandEffect::Status { message } => {
                    self.last_status = Some(message.clone());
                }
            }
        }

        fn begin_mouse_selection(&mut self, x_pixels: i32, y_pixels: i32) -> bool {
            let Some((row, column)) = self.session_render_cell_for_client_point(x_pixels, y_pixels)
            else {
                return false;
            };
            self.session
                .begin_mouse_selection_at_focused_cell(row, column)
        }

        fn extend_mouse_selection(&mut self, x_pixels: i32, y_pixels: i32) -> bool {
            let Some((row, column)) = self.session_render_cell_for_client_point(x_pixels, y_pixels)
            else {
                return false;
            };
            self.session
                .extend_mouse_selection_at_focused_cell(row, column)
        }

        fn select_word(&mut self, x_pixels: i32, y_pixels: i32) -> bool {
            let Some((row, column)) = self.session_render_cell_for_client_point(x_pixels, y_pixels)
            else {
                return false;
            };
            self.session.select_word_at_focused_cell(row, column)
        }

        fn finish_mouse_selection(&mut self) -> bool {
            self.session.finish_mouse_selection()
        }

        /// Map a client pixel to the focused grid `(row, column)` using the
        /// renderer's measured cell metrics and the focused pane's grid origin
        /// from the last paint (which accounts for the sidebar offset and the
        /// pane title bar). Clamped to the grid bounds so a drag past the edge
        /// still extends to the last cell.
        fn session_render_cell_for_client_point(
            &self,
            x_pixels: i32,
            y_pixels: i32,
        ) -> Option<(usize, usize)> {
            if self.last_error.is_some() {
                return None;
            }
            let renderer = self.renderer.as_ref()?;
            let (cell_w, cell_h) = renderer.cell_size();
            let (origin_x, origin_y) = renderer
                .focused_grid_origin()
                .unwrap_or((DESKTOP_TEXT_LEFT as f32, DESKTOP_TEXT_TOP as f32));
            let (row, column) = crate::render::metrics::cell_at_pixel(
                x_pixels,
                y_pixels,
                origin_x,
                origin_y,
                cell_w,
                cell_h,
            )?;
            let screen = self.session.focused_screen()?;
            Some((
                row.min(screen.height().saturating_sub(1)),
                column.min(screen.width().saturating_sub(1)),
            ))
        }

        /// Paint the window through the Direct2D renderer. The focused pane's
        /// terminal renders as a styled cell grid (per-cell fg/bg/bold +
        /// cursor); a runtime error renders as a text line instead. The
        /// renderer is moved out for the call so the session can be borrowed for
        /// the screen at the same time (split borrow).
        fn render(&mut self) {
            let Some(mut renderer) = self.renderer.take() else {
                return;
            };
            let cursor_on = self.cursor_on;
            let result = if let Some(error) = self.last_error.as_ref() {
                renderer.render(&[format!("Zentty runtime error: {error}")])
            } else {
                let sidebar = self.session.sidebar_render_model();
                let overlay = self.session.overlay_render_model();
                let frames = self.session.worklane_pane_frames();
                // `shot_force_empty` is set by the ZENTTY_SHOT_EMPTY tooling
                // hook so the otherwise-unreachable empty state can be captured.
                if frames.is_empty() || self.shot_force_empty {
                    renderer
                        .render_empty_state(&["No panes open", "Press Ctrl+D to split a pane"])
                } else {
                    renderer.render_window(sidebar, &frames, overlay, cursor_on)
                }
            };
            if let Err(error) = result {
                eprintln!("zentty: Direct2D render failed: {error}");
            }
            self.renderer = Some(renderer);
        }

        /// Terminal grid size for a client area, using the renderer's measured
        /// cell metrics (falling back to the fixed legacy metrics if the
        /// renderer failed to initialize).
        fn terminal_size_for_client(&self, width_pixels: i32, height_pixels: i32) -> TerminalSize {
            match self.renderer.as_ref() {
                Some(renderer) => {
                    let (cell_w, cell_h) = renderer.cell_size();
                    let (cols, rows) = crate::render::metrics::grid_dimensions(
                        width_pixels,
                        height_pixels,
                        DESKTOP_TEXT_LEFT as f32,
                        DESKTOP_TEXT_TOP as f32,
                        cell_w,
                        cell_h,
                    );
                    TerminalSize::new(cols, rows)
                        .with_cell_pixels(cell_w.round() as u16, cell_h.round() as u16)
                }
                None => desktop_terminal_size_for_client_area(width_pixels, height_pixels),
            }
        }

        fn resize_renderer(&mut self, width: u32, height: u32) {
            if let Some(renderer) = self.renderer.as_mut() {
                renderer.resize(width, height);
            }
        }

        fn terminate(&mut self) {
            let _ = self.session.terminate();
        }
    }

    unsafe fn resolve_confirmation_effect(
        hwnd: HWND,
        state: &mut NativeWindowState,
        effect: DesktopCommandEffect,
    ) -> DesktopCommandEffect {
        match effect {
            DesktopCommandEffect::ConfirmClosePane {
                pane_id: _,
                pane_title,
            } => {
                let display_title = if pane_title.trim().is_empty() {
                    "this pane".to_string()
                } else {
                    format!("\"{pane_title}\"")
                };
                if unsafe {
                    confirm_native_action(
                        hwnd,
                        "Close pane?",
                        &format!("Close pane {display_title}?"),
                    )
                } {
                    state.execute_confirmed_app_command(AppCommandId::CloseFocusedPane)
                } else {
                    DesktopCommandEffect::Repaint
                }
            }
            DesktopCommandEffect::ConfirmCloseWindow { .. } => {
                if unsafe {
                    confirm_native_action(hwnd, "Close window?", "Close this Zentty window?")
                } {
                    state.execute_confirmed_app_command(AppCommandId::CloseWindow)
                } else {
                    DesktopCommandEffect::Repaint
                }
            }
            other => other,
        }
    }

    unsafe fn confirm_native_action(hwnd: HWND, title: &str, message: &str) -> bool {
        let title = wide_null(title);
        let message = wide_null(message);
        let result = unsafe {
            MessageBoxW(
                Some(hwnd),
                PCWSTR(message.as_ptr()),
                PCWSTR(title.as_ptr()),
                MB_YESNO | MB_ICONWARNING,
            )
        };
        result == IDYES
    }

    unsafe fn cue_native_notification(hwnd: HWND, notification: &PaneNotification) {
        if notification.is_silent {
            return;
        }
        let _ = unsafe { FlashWindow(hwnd, true) };
    }

    unsafe extern "system" fn window_proc(
        hwnd: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match message {
            WM_KEYDOWN => {
                if let Some(event) = unsafe { key_event_from_win32(wparam) }
                    && let Some(state) = unsafe { state_mut(hwnd) }
                {
                    let effect = state.execute_key_event(event);
                    let effect = unsafe { resolve_confirmation_effect(hwnd, state, effect) };
                    match effect {
                        DesktopCommandEffect::Ignored => {}
                        DesktopCommandEffect::Repaint => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Status { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::CopyText { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::PasteFromClipboard { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::PaneNotification { notification } => {
                            unsafe { cue_native_notification(hwnd, &notification) };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { DestroyWindow(hwnd) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                    }
                }
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
            WM_CHAR => {
                if let Some(ch) = char::from_u32(wparam.0 as u32)
                    && let Some(state) = unsafe { state_mut(hwnd) }
                {
                    let effect = state.write_char(ch);
                    let effect = unsafe { resolve_confirmation_effect(hwnd, state, effect) };
                    match effect {
                        DesktopCommandEffect::Ignored => {}
                        DesktopCommandEffect::Repaint => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                        }
                        DesktopCommandEffect::Status { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::CopyText { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::PasteFromClipboard { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::PaneNotification { notification } => {
                            unsafe { cue_native_notification(hwnd, &notification) };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { DestroyWindow(hwnd) };
                        }
                        DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                    }
                }
                LRESULT(0)
            }
            WM_CLOSE => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let effect = state.request_close_window();
                    let effect = unsafe { resolve_confirmation_effect(hwnd, state, effect) };
                    match effect {
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { DestroyWindow(hwnd) };
                        }
                        DesktopCommandEffect::Repaint
                        | DesktopCommandEffect::Status { .. }
                        | DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::PaneNotification { notification } => {
                            unsafe { cue_native_notification(hwnd, &notification) };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                        }
                        DesktopCommandEffect::Ignored
                        | DesktopCommandEffect::CopyText { .. }
                        | DesktopCommandEffect::PasteFromClipboard { .. }
                        | DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. } => {}
                    }
                    return LRESULT(0);
                }
                let _ = unsafe { DestroyWindow(hwnd) };
                LRESULT(0)
            }
            WM_TIMER if wparam.0 == OUTPUT_TIMER_ID => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let output_changed = state.poll_output();
                    // Auto-close panes whose shell exited; if that empties the
                    // window, destroy it (last-pane behavior). The shell already
                    // ended, so skip any close-confirmation prompt.
                    if state.session.close_exited_panes() {
                        let _ = unsafe { DestroyWindow(hwnd) };
                        return LRESULT(0);
                    }
                    let ipc_changed = state.poll_agent_ipc(hwnd);
                    let split_fired = state.tick_shot_split(hwnd);
                    let search_fired = state.tick_shot_search();
                    let empty_fired = state.tick_shot_empty();
                    if state.shot_status {
                        state.session.inject_screenshot_statuses();
                    }
                    // A BEL from any pane flashes the window (visual bell).
                    if state.session.take_any_bell() {
                        let _ = unsafe { FlashWindow(hwnd, true) };
                    }
                    if output_changed {
                        state.update_window_title(hwnd);
                    }
                    // Cursor blink, honoring the system caret rate (activity
                    // shows the cursor immediately; 0/INFINITE rate = no blink).
                    let mut blink_repaint = false;
                    match caret_blink_interval_ticks() {
                        Some(interval) if !(output_changed || ipc_changed) => {
                            state.blink_tick += 1;
                            if state.blink_tick >= interval {
                                state.blink_tick = 0;
                                state.cursor_on = !state.cursor_on;
                                blink_repaint = true;
                            }
                        }
                        _ => {
                            state.blink_tick = 0;
                            if !state.cursor_on {
                                state.cursor_on = true;
                                blink_repaint = true;
                            }
                        }
                    }
                    if output_changed
                        || ipc_changed
                        || split_fired
                        || search_fired
                        || empty_fired
                        || state.shot_status
                        || blink_repaint
                    {
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                    }
                }
                LRESULT(0)
            }
            WM_SIZE => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let (width, height) = client_area_size_from_lparam(lparam);
                    if width > 0 && height > 0 {
                        // Resize the Direct2D target to match the new client area
                        // before reflowing the PTY grid.
                        state.resize_renderer(width as u32, height as u32);
                        match state.resize(width, height) {
                            DesktopCommandEffect::Repaint => {
                                let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            }
                            DesktopCommandEffect::Ignored
                            | DesktopCommandEffect::Status { .. }
                            | DesktopCommandEffect::CopyText { .. }
                            | DesktopCommandEffect::PasteFromClipboard { .. }
                            | DesktopCommandEffect::OpenPathWithTarget { .. }
                            | DesktopCommandEffect::OpenUrl { .. }
                            | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                            | DesktopCommandEffect::PaneNotification { .. }
                            | DesktopCommandEffect::NewWindow { .. }
                            | DesktopCommandEffect::MovePaneToNewWindow { .. }
                            | DesktopCommandEffect::ConfirmClosePane { .. }
                            | DesktopCommandEffect::ConfirmCloseWindow { .. }
                            | DesktopCommandEffect::CloseWindow { .. } => {}
                        }
                    }
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let (x, y) = client_point_from_lparam(lparam);
                    match state.execute_mouse_event(DesktopMouseEventKind::Press, x, y) {
                        DesktopCommandEffect::Repaint => {
                            let _ = unsafe { SetCapture(hwnd) };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Status { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Ignored
                        | DesktopCommandEffect::CopyText { .. }
                        | DesktopCommandEffect::PasteFromClipboard { .. }
                        | DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::PaneNotification { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. }
                        | DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {}
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { DestroyWindow(hwnd) };
                            return LRESULT(0);
                        }
                    }
                    if state.begin_mouse_selection(x, y) {
                        let _ = unsafe { SetCapture(hwnd) };
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                        return LRESULT(0);
                    }
                }
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
            WM_MOUSEMOVE => {
                if (wparam.0 & MK_LBUTTON_MASK) != 0
                    && let Some(state) = unsafe { state_mut(hwnd) }
                {
                    let (x, y) = client_point_from_lparam(lparam);
                    match state.execute_mouse_event(DesktopMouseEventKind::Drag, x, y) {
                        DesktopCommandEffect::Repaint => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Status { .. } => {
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Ignored
                        | DesktopCommandEffect::CopyText { .. }
                        | DesktopCommandEffect::PasteFromClipboard { .. }
                        | DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::PaneNotification { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. }
                        | DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {}
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { DestroyWindow(hwnd) };
                            return LRESULT(0);
                        }
                    }
                    if state.extend_mouse_selection(x, y) {
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                        return LRESULT(0);
                    }
                }
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
            WM_LBUTTONDBLCLK => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let (x, y) = client_point_from_lparam(lparam);
                    if state.select_word(x, y) {
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                        return LRESULT(0);
                    }
                }
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
            WM_LBUTTONUP => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    let (x, y) = client_point_from_lparam(lparam);
                    match state.execute_mouse_event(DesktopMouseEventKind::Release, x, y) {
                        DesktopCommandEffect::Repaint => {
                            let _ = unsafe { ReleaseCapture() };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Status { .. } => {
                            let _ = unsafe { ReleaseCapture() };
                            let _ = unsafe { InvalidateRect(Some(hwnd), None, true) };
                            return LRESULT(0);
                        }
                        DesktopCommandEffect::Ignored
                        | DesktopCommandEffect::CopyText { .. }
                        | DesktopCommandEffect::PasteFromClipboard { .. }
                        | DesktopCommandEffect::OpenPathWithTarget { .. }
                        | DesktopCommandEffect::OpenUrl { .. }
                        | DesktopCommandEffect::OpenUrlWithBrowser { .. }
                        | DesktopCommandEffect::PaneNotification { .. }
                        | DesktopCommandEffect::NewWindow { .. }
                        | DesktopCommandEffect::MovePaneToNewWindow { .. }
                        | DesktopCommandEffect::ConfirmClosePane { .. }
                        | DesktopCommandEffect::ConfirmCloseWindow { .. } => {}
                        DesktopCommandEffect::CloseWindow { .. } => {
                            let _ = unsafe { ReleaseCapture() };
                            let _ = unsafe { DestroyWindow(hwnd) };
                            return LRESULT(0);
                        }
                    }
                    if state.finish_mouse_selection() {
                        let _ = unsafe { ReleaseCapture() };
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                        return LRESULT(0);
                    }
                }
                let _ = unsafe { ReleaseCapture() };
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
            WM_MOUSEWHEEL => {
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    // High word of wParam is the signed wheel delta (±WHEEL_DELTA
                    // per notch). Positive = scroll up into scrollback history.
                    let delta = ((wparam.0 >> 16) & 0xffff) as u16 as i16;
                    let notches = delta as i32 / 120;
                    if notches != 0 && state.session.scroll_focused_view(notches * 3) {
                        let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
                    }
                }
                LRESULT(0)
            }
            WM_PAINT => {
                // Direct2D presents the window itself; we only need to validate
                // the update region so Windows stops re-posting WM_PAINT. Using
                // ValidateRect (not BeginPaint/EndPaint) avoids the GDI paint-DC
                // cycle interfering with the D2D present.
                if let Some(state) = unsafe { state_mut(hwnd) } {
                    state.render();
                }
                let _ = unsafe { ValidateRect(Some(hwnd), None) };
                LRESULT(0)
            }
            WM_DESTROY => {
                let _ = unsafe { KillTimer(Some(hwnd), OUTPUT_TIMER_ID) };
                unregister_native_window(hwnd);
                if let Some(state) = unsafe { take_state(hwnd) } {
                    drop(state);
                }
                if OPEN_WINDOW_COUNT.fetch_sub(1, Ordering::SeqCst) <= 1 {
                    unsafe { PostQuitMessage(0) };
                }
                LRESULT(0)
            }
            _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
        }
    }

    fn register_native_window(hwnd: HWND) {
        OPEN_WINDOW_HANDLES.with(|handles| handles.borrow_mut().push(hwnd));
    }

    fn unregister_native_window(hwnd: HWND) {
        OPEN_WINDOW_HANDLES.with(|handles| {
            handles
                .borrow_mut()
                .retain(|registered| registered.0 != hwnd.0);
        });
    }

    fn other_native_window_handles(hwnd: HWND) -> Vec<HWND> {
        OPEN_WINDOW_HANDLES.with(|handles| {
            handles
                .borrow()
                .iter()
                .copied()
                .filter(|registered| registered.0 != hwnd.0)
                .collect()
        })
    }

    unsafe fn state_mut(hwnd: HWND) -> Option<&'static mut NativeWindowState> {
        let state_ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
        let state_ptr = state_ptr as *mut NativeWindowState;
        (!state_ptr.is_null()).then(|| unsafe { &mut *state_ptr })
    }

    unsafe fn take_state(hwnd: HWND) -> Option<Box<NativeWindowState>> {
        let state_ptr = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
        unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) };
        let state_ptr = state_ptr as *mut NativeWindowState;
        (!state_ptr.is_null()).then(|| {
            let mut state = unsafe { Box::from_raw(state_ptr) };
            state.terminate();
            state
        })
    }

    unsafe fn key_event_from_win32(wparam: WPARAM) -> Option<DesktopKeyEvent> {
        desktop_key_event_from_windows_virtual_key(
            wparam.0 as u16,
            DesktopKeyModifiers {
                control: unsafe { virtual_key_is_down(VK_CONTROL) },
                alt: unsafe { virtual_key_is_down(VK_MENU) },
                shift: unsafe { virtual_key_is_down(VK_SHIFT) },
            },
        )
    }

    fn client_area_size_from_lparam(lparam: LPARAM) -> (i32, i32) {
        let raw = lparam.0 as u32;
        let width = (raw & 0xffff) as u16 as i32;
        let height = ((raw >> 16) & 0xffff) as u16 as i32;
        (width, height)
    }

    fn client_point_from_lparam(lparam: LPARAM) -> (i32, i32) {
        let raw = lparam.0 as u32;
        let x = (raw & 0xffff) as u16 as i16 as i32;
        let y = ((raw >> 16) & 0xffff) as u16 as i16 as i32;
        (x, y)
    }

    unsafe fn virtual_key_is_down(key: VIRTUAL_KEY) -> bool {
        (unsafe { GetKeyState(i32::from(key.0)) }) < 0
    }

    fn wide_null(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(iter::once(0)).collect()
    }

    unsafe fn open_path_with_windows_shell(
        path: &str,
        app_path: Option<&str>,
    ) -> Result<(), String> {
        if let Some(app_path) = app_path.and_then(super::trimmed_non_empty) {
            let parameters = quote_windows_argument(path);
            return unsafe { shell_execute_open(app_path, Some(&parameters)) };
        }

        unsafe { shell_execute_open(path, None) }
    }

    unsafe fn open_url_with_windows_shell(url: &str) -> Result<(), String> {
        unsafe { shell_execute_open(url, None) }
    }

    unsafe fn open_url_with_browser_windows_shell(url: &str, app_path: &str) -> Result<(), String> {
        let parameters = quote_windows_argument(url);
        unsafe { shell_execute_open(app_path, Some(&parameters)) }
    }

    unsafe fn shell_execute_open(file: &str, parameters: Option<&str>) -> Result<(), String> {
        let operation = wide_null("open");
        let file = wide_null(file);
        let parameters = parameters.map(wide_null);
        let parameters = parameters
            .as_ref()
            .map_or(PCWSTR::null(), |value| PCWSTR(value.as_ptr()));

        let result = unsafe {
            ShellExecuteW(
                None,
                PCWSTR(operation.as_ptr()),
                PCWSTR(file.as_ptr()),
                parameters,
                PCWSTR::null(),
                SW_SHOWNORMAL,
            )
        };
        let code = result.0 as isize;
        if code <= 32 {
            return Err(format!("ShellExecuteW returned {code}"));
        }
        Ok(())
    }

    fn quote_windows_argument(value: &str) -> String {
        let mut quoted = String::with_capacity(value.len() + 2);
        quoted.push('"');
        let mut backslashes = 0;
        for ch in value.chars() {
            match ch {
                '\\' => backslashes += 1,
                '"' => {
                    for _ in 0..(backslashes * 2 + 1) {
                        quoted.push('\\');
                    }
                    quoted.push('"');
                    backslashes = 0;
                }
                _ => {
                    for _ in 0..backslashes {
                        quoted.push('\\');
                    }
                    backslashes = 0;
                    quoted.push(ch);
                }
            }
        }
        for _ in 0..(backslashes * 2) {
            quoted.push('\\');
        }
        quoted.push('"');
        quoted
    }

    unsafe fn copy_text_to_windows_clipboard(text: &str) -> Result<(), String> {
        unsafe { OpenClipboard(None) }.map_err(|error| error.to_string())?;
        let _guard = ClipboardCloseGuard;

        unsafe { EmptyClipboard() }.map_err(|error| error.to_string())?;
        let wide = text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<_>>();
        let byte_len = wide.len() * std::mem::size_of::<u16>();
        let memory =
            unsafe { GlobalAlloc(GMEM_MOVEABLE, byte_len) }.map_err(|error| error.to_string())?;
        let locked = unsafe { GlobalLock(memory) };
        if locked.is_null() {
            return Err("GlobalLock failed".to_string());
        }

        unsafe {
            std::ptr::copy_nonoverlapping(wide.as_ptr(), locked.cast::<u16>(), wide.len());
        }
        unsafe { GlobalUnlock(memory) }.map_err(|error| error.to_string())?;
        unsafe { SetClipboardData(CF_UNICODETEXT.0.into(), Some(HANDLE(memory.0))) }
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    unsafe fn read_text_from_windows_clipboard() -> Result<Option<String>, String> {
        if unsafe { IsClipboardFormatAvailable(CF_UNICODETEXT.0.into()) }.is_err() {
            return Ok(None);
        }

        unsafe { OpenClipboard(None) }.map_err(|error| error.to_string())?;
        let _guard = ClipboardCloseGuard;
        let handle = unsafe { GetClipboardData(CF_UNICODETEXT.0.into()) }
            .map_err(|error| error.to_string())?;
        let memory = HGLOBAL(handle.0);
        let locked = unsafe { GlobalLock(memory) };
        if locked.is_null() {
            return Err("GlobalLock failed".to_string());
        }

        let byte_len = unsafe { GlobalSize(memory) };
        let unit_len = byte_len / std::mem::size_of::<u16>();
        let slice = unsafe { std::slice::from_raw_parts(locked.cast::<u16>(), unit_len) };
        let text_len = slice.iter().position(|unit| *unit == 0).unwrap_or(unit_len);
        let text = String::from_utf16_lossy(&slice[..text_len]);
        let _ = unsafe { GlobalUnlock(memory) };
        Ok(Some(text))
    }

    struct ClipboardCloseGuard;

    impl Drop for ClipboardCloseGuard {
        fn drop(&mut self) {
            let _ = unsafe { CloseClipboard() };
        }
    }
}

#[cfg(not(windows))]
mod native_window {
    use super::{DesktopWindowError, DesktopWindowSession};

    pub fn run_message_loop(_session: DesktopWindowSession) -> Result<i32, DesktopWindowError> {
        Err(DesktopWindowError::UnsupportedPlatform)
    }
}
