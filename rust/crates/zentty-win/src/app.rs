use std::collections::{BTreeMap, BTreeSet, HashSet};

use zentty_core::agent::{
    AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse, AgentIpcResponseError,
    AgentIpcResponseResult, AgentPidSignalEvent, AgentSignalCommand, AgentSignalKind,
    AgentSignalPayload, PaneListEntry,
};
use zentty_core::command_palette::{
    CommandPaletteItem, CommandPaletteItemBuilder, CommandPaletteItemGroup, CommandPaletteItemId,
    CommandPaletteResolvedResults, CommandPaletteResultsResolver, DetectedServer,
    OpenWithResolvedTarget, TaskRunnerAction, WorklaneColor,
};
use zentty_core::commands::{
    AppCommandId, CommandAvailabilityContext, CommandAvailabilityResolver,
    CommandPaletteCommandBuildContext,
};
use zentty_core::config::AppearanceThemeMode;
use zentty_core::focus_history::{PaneFocusHistory, PaneReference};
use zentty_core::layout::{PaneColumnId, PaneId, TerminalSessionRequest};
use zentty_core::restore::{
    AgentResumeCommandBuilder, ClosedPaneCwdResolver, ClosedPaneEntry, ClosedPaneRestoreCommand,
    ClosedPaneRestoreCommandResolver, ClosedPaneStack, PaneRestoreDraft,
};
use zentty_core::session_restore::{
    SessionRestoreDraftWindow, SessionRestoreEnvelope, WorkspaceRecipeImporter,
    WorkspaceRecipeWindow,
};
use zentty_core::task_manager::TaskManagerPaneSource;
use zentty_core::task_runner::{
    TaskRunnerDiscoveryService, TaskRunnerExecutionPlan, TaskRunnerExecutionPlanner,
    TaskRunnerFocusedPaneState, TaskRunnerShellActivityState,
};
use zentty_core::worklane::WorklaneState;
use zentty_pty::native::NativePtyOutputStream;
use zentty_pty::native::NativePtySession;
use zentty_pty::{PtyError, PtyProcessOutput, PtySessionRequest, TerminalSize};
use zentty_terminal::clipboard::TerminalClipboardPaste;
use zentty_terminal::input::{TerminalInputPayload, TerminalInputPlanner, TerminalPasteMode};
use zentty_terminal::screen::TerminalScreen;

use crate::host::default_shell;
use crate::ipc::generate_agent_ipc_pane_token;

#[derive(Clone, Debug, PartialEq)]
pub struct AppLaunchPlan {
    pub windows: Vec<WindowLaunchPlan>,
    pub active_window_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AppCommandExecutionResult {
    Applied,
    Unavailable,
    Unsupported,
    ShowPaneSearch {
        pane_id: String,
    },
    ShowGlobalSearch,
    UseSelectionForFind {
        pane_id: String,
    },
    FindNext {
        pane_id: String,
    },
    FindPrevious {
        pane_id: String,
    },
    CopyText {
        text: String,
    },
    CopySelection {
        mode: &'static str,
    },
    BeginRenameWorklane {
        worklane_id: String,
    },
    JumpToLatestNotification,
    RequestCloseWindow {
        window_id: String,
    },
    RequestNewWindow {
        working_directory: Option<String>,
    },
    RequestMovePaneToNewWindow {
        pane_id: String,
    },
    OpenPathWithTarget {
        path: String,
        target_id: String,
        target_name: String,
        app_path: Option<String>,
    },
    OpenServer {
        server_id: String,
        origin: String,
        url: String,
    },
    OpenUrl {
        url: String,
    },
    RestoredClosedPane {
        pane_id: String,
        worklane_id: String,
        toast_message: String,
    },
    ToggleSidebar,
    ShowCommandPalette,
    ShowSettings {
        section: &'static str,
    },
    ShowTaskManager,
    ReloadConfiguration,
    OpenBookmarksPopover,
    SetThemeMode {
        mode: &'static str,
    },
    SetWorklaneColor {
        worklane_id: String,
        color: Option<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandPaletteItemExecutionResult {
    Applied,
    Unavailable,
    Unsupported,
    RunRestoredCommand {
        pane_id: String,
        command: String,
    },
    ShowPaneSearch {
        pane_id: String,
    },
    ShowGlobalSearch,
    UseSelectionForFind {
        pane_id: String,
    },
    FindNext {
        pane_id: String,
    },
    FindPrevious {
        pane_id: String,
    },
    CopyText {
        text: String,
    },
    CopySelection {
        mode: &'static str,
    },
    BeginRenameWorklane {
        worklane_id: String,
    },
    JumpToLatestNotification,
    RequestCloseWindow {
        window_id: String,
    },
    RequestNewWindow {
        working_directory: Option<String>,
    },
    RequestMovePaneToNewWindow {
        pane_id: String,
    },
    OpenPathWithTarget {
        path: String,
        target_id: String,
        target_name: String,
        app_path: Option<String>,
    },
    OpenServer {
        server_id: String,
        origin: String,
        url: String,
    },
    OpenUrl {
        url: String,
    },
    RestoredClosedPane {
        pane_id: String,
        worklane_id: String,
        toast_message: String,
    },
    ShowSettings {
        section: String,
    },
    ToggleSidebar,
    ShowCommandPalette,
    ShowTaskManager,
    ReloadConfiguration,
    OpenBookmarksPopover,
    SetThemeMode {
        mode: &'static str,
    },
    SetWorklaneColor {
        worklane_id: String,
        color: Option<String>,
    },
    OpenTaskRunnerSource {
        source_path: String,
    },
    RunTaskRunnerInNewPane {
        pane_id: String,
        command: String,
    },
    RunTaskRunnerInFocusedPane {
        pane_id: String,
        command: String,
    },
}

impl From<AppCommandExecutionResult> for CommandPaletteItemExecutionResult {
    fn from(result: AppCommandExecutionResult) -> Self {
        match result {
            AppCommandExecutionResult::Applied => Self::Applied,
            AppCommandExecutionResult::Unavailable => Self::Unavailable,
            AppCommandExecutionResult::Unsupported => Self::Unsupported,
            AppCommandExecutionResult::ShowPaneSearch { pane_id } => {
                Self::ShowPaneSearch { pane_id }
            }
            AppCommandExecutionResult::ShowGlobalSearch => Self::ShowGlobalSearch,
            AppCommandExecutionResult::UseSelectionForFind { pane_id } => {
                Self::UseSelectionForFind { pane_id }
            }
            AppCommandExecutionResult::FindNext { pane_id } => Self::FindNext { pane_id },
            AppCommandExecutionResult::FindPrevious { pane_id } => Self::FindPrevious { pane_id },
            AppCommandExecutionResult::CopyText { text } => Self::CopyText { text },
            AppCommandExecutionResult::CopySelection { mode } => Self::CopySelection { mode },
            AppCommandExecutionResult::BeginRenameWorklane { worklane_id } => {
                Self::BeginRenameWorklane { worklane_id }
            }
            AppCommandExecutionResult::JumpToLatestNotification => Self::JumpToLatestNotification,
            AppCommandExecutionResult::RequestCloseWindow { window_id } => {
                Self::RequestCloseWindow { window_id }
            }
            AppCommandExecutionResult::RequestNewWindow { working_directory } => {
                Self::RequestNewWindow { working_directory }
            }
            AppCommandExecutionResult::RequestMovePaneToNewWindow { pane_id } => {
                Self::RequestMovePaneToNewWindow { pane_id }
            }
            AppCommandExecutionResult::OpenPathWithTarget {
                path,
                target_id,
                target_name,
                app_path,
            } => Self::OpenPathWithTarget {
                path,
                target_id,
                target_name,
                app_path,
            },
            AppCommandExecutionResult::OpenServer {
                server_id,
                origin,
                url,
            } => Self::OpenServer {
                server_id,
                origin,
                url,
            },
            AppCommandExecutionResult::OpenUrl { url } => Self::OpenUrl { url },
            AppCommandExecutionResult::RestoredClosedPane {
                pane_id,
                worklane_id,
                toast_message,
            } => Self::RestoredClosedPane {
                pane_id,
                worklane_id,
                toast_message,
            },
            AppCommandExecutionResult::ToggleSidebar => Self::ToggleSidebar,
            AppCommandExecutionResult::ShowCommandPalette => Self::ShowCommandPalette,
            AppCommandExecutionResult::ShowSettings { section } => Self::ShowSettings {
                section: section.to_string(),
            },
            AppCommandExecutionResult::ShowTaskManager => Self::ShowTaskManager,
            AppCommandExecutionResult::ReloadConfiguration => Self::ReloadConfiguration,
            AppCommandExecutionResult::OpenBookmarksPopover => Self::OpenBookmarksPopover,
            AppCommandExecutionResult::SetThemeMode { mode } => Self::SetThemeMode { mode },
            AppCommandExecutionResult::SetWorklaneColor { worklane_id, color } => {
                Self::SetWorklaneColor { worklane_id, color }
            }
        }
    }
}

impl AppLaunchPlan {
    pub fn execute_command(&mut self, command_id: AppCommandId) -> AppCommandExecutionResult {
        match command_id {
            AppCommandId::MovePaneToNewWindow => self.move_focused_pane_to_new_window(),
            AppCommandId::NewWindow => self.create_new_window(),
            AppCommandId::CloseWindow => self.close_active_window(),
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
            AppCommandId::RenameCurrentWorklane => self.rename_active_worklane(),
            AppCommandId::JumpToLatestNotification => {
                AppCommandExecutionResult::JumpToLatestNotification
            }
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
            _ => self
                .active_window_mut()
                .map(|window| window.execute_command(command_id))
                .unwrap_or(AppCommandExecutionResult::Unavailable),
        }
    }

    pub fn execute_palette_item(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> CommandPaletteItemExecutionResult {
        match item_id {
            CommandPaletteItemId::Command(command_id) => AppCommandId::from_raw_value(command_id)
                .map(|command_id| self.execute_command(command_id).into())
                .unwrap_or(CommandPaletteItemExecutionResult::Unsupported),
            CommandPaletteItemId::Settings(section) => {
                CommandPaletteItemExecutionResult::ShowSettings {
                    section: section.clone(),
                }
            }
            _ => self
                .active_window_mut()
                .map(|window| window.execute_palette_item(item_id))
                .unwrap_or(CommandPaletteItemExecutionResult::Unavailable),
        }
    }

    pub fn resolve_command_palette(&self, search_text: &str) -> CommandPaletteResolvedResults {
        self.active_window()
            .map(|window| window.resolve_command_palette(search_text))
            .unwrap_or_else(|| {
                CommandPaletteResultsResolver::resolve(
                    search_text,
                    Vec::new(),
                    Vec::new(),
                    Vec::new(),
                    None,
                    Vec::new(),
                )
            })
    }

    pub fn command_palette_items(&self) -> Vec<CommandPaletteItem> {
        self.active_window()
            .map(WindowLaunchPlan::command_palette_items)
            .unwrap_or_default()
    }

    pub fn command_palette_command_items(&self) -> Vec<CommandPaletteItem> {
        self.active_window()
            .map(WindowLaunchPlan::command_palette_command_items)
            .unwrap_or_default()
    }

    fn active_window(&self) -> Option<&WindowLaunchPlan> {
        self.active_window_id
            .as_ref()
            .and_then(|id| self.windows.iter().find(|window| &window.window_id == id))
            .or_else(|| self.windows.first())
    }

    fn active_window_index(&self) -> Option<usize> {
        self.active_window_id
            .as_ref()
            .and_then(|id| {
                self.windows
                    .iter()
                    .position(|window| &window.window_id == id)
            })
            .or((!self.windows.is_empty()).then_some(0))
    }

    fn active_window_mut(&mut self) -> Option<&mut WindowLaunchPlan> {
        if let Some(active_window_id) = self.active_window_id.as_deref()
            && let Some(index) = self
                .windows
                .iter()
                .position(|window| window.window_id == active_window_id)
            {
                return self.windows.get_mut(index);
            }
        self.windows.first_mut()
    }

    fn focused_pane_id(&self) -> Option<String> {
        let active_window = self.active_window()?;
        active_window.focused_pane_id()
    }

    fn pane_specs(&self) -> impl Iterator<Item = &PaneLaunchSpec> {
        self.windows
            .iter()
            .flat_map(|window| &window.worklanes)
            .flat_map(|worklane| &worklane.panes)
    }

    fn focused_pane_result(
        &self,
        result: fn(String) -> AppCommandExecutionResult,
    ) -> AppCommandExecutionResult {
        self.focused_pane_id()
            .map(result)
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn copy_focused_pane_path(&self) -> AppCommandExecutionResult {
        self.active_window()
            .and_then(WindowLaunchPlan::focused_pane)
            .and_then(|pane| pane.terminal_request.working_directory.as_deref())
            .and_then(trimmed_non_empty)
            .map(|path| AppCommandExecutionResult::CopyText {
                text: path.to_string(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn rename_active_worklane(&self) -> AppCommandExecutionResult {
        self.active_window()
            .and_then(WindowLaunchPlan::active_worklane)
            .map(|worklane| AppCommandExecutionResult::BeginRenameWorklane {
                worklane_id: worklane.worklane_id.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn move_focused_pane_to_new_window(&mut self) -> AppCommandExecutionResult {
        let Some(source_window_index) = self.active_window_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(source_worklane_index) = self.windows[source_window_index].active_worklane_index()
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused_pane_id) = self.windows[source_window_index].worklanes
            [source_worklane_index]
            .focused_pane_id
            .clone()
        else {
            return AppCommandExecutionResult::Unavailable;
        };

        let source_window_worklane_count = self.windows[source_window_index].worklanes.len();
        let source_worklane_pane_count = self.windows[source_window_index].worklanes
            [source_worklane_index]
            .panes
            .len();
        if source_window_worklane_count == 1 && source_worklane_pane_count == 1 {
            return AppCommandExecutionResult::Unavailable;
        }

        let destination_window_id = next_window_id(&self.windows);
        let destination_window = if source_worklane_pane_count == 1 {
            let mut moved_worklane = self.windows[source_window_index]
                .worklanes
                .remove(source_worklane_index);
            retarget_worklane_for_split_out(&mut moved_worklane);
            if self.windows[source_window_index]
                .active_worklane_id
                .as_deref()
                == Some(moved_worklane.worklane_id.as_str())
            {
                self.windows[source_window_index].active_worklane_id = self.windows
                    [source_window_index]
                    .worklanes
                    .get(
                        source_worklane_index.saturating_sub(1).min(
                            self.windows[source_window_index]
                                .worklanes
                                .len()
                                .saturating_sub(1),
                        ),
                    )
                    .map(|worklane| worklane.worklane_id.clone());
            }

            WindowLaunchPlan {
                window_id: destination_window_id.clone(),
                active_worklane_id: Some(moved_worklane.worklane_id.clone()),
                worklanes: vec![moved_worklane],
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
            }
        } else {
            let Some(focused_position) = self.windows[source_window_index].worklanes
                [source_worklane_index]
                .panes
                .iter()
                .position(|pane| pane.pane_id == focused_pane_id)
            else {
                return AppCommandExecutionResult::Unavailable;
            };

            let mut moved_pane = self.windows[source_window_index].worklanes[source_worklane_index]
                .panes
                .remove(focused_position);
            normalize_after_remove(
                &mut self.windows[source_window_index].worklanes[source_worklane_index].panes,
                &moved_pane,
            );
            self.windows[source_window_index].worklanes[source_worklane_index].focused_pane_id =
                next_focus_after_removal(
                    &self.windows[source_window_index].worklanes[source_worklane_index],
                    &moved_pane,
                );

            let destination_worklane_id = next_global_worklane_id(&self.windows);
            retarget_pane_for_split_out(&mut moved_pane, &destination_worklane_id);
            let source_title = self.windows[source_window_index].worklanes[source_worklane_index]
                .title
                .clone();

            WindowLaunchPlan {
                window_id: destination_window_id.clone(),
                active_worklane_id: Some(destination_worklane_id.clone()),
                worklanes: vec![WorklaneLaunchPlan {
                    worklane_id: destination_worklane_id,
                    title: source_title,
                    panes: vec![moved_pane],
                    focused_pane_id: Some(focused_pane_id),
                }],
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
            }
        };

        self.windows.push(destination_window);
        self.active_window_id = Some(destination_window_id);
        AppCommandExecutionResult::Applied
    }

    fn create_new_window(&mut self) -> AppCommandExecutionResult {
        let window_id = next_window_id(&self.windows);
        let worklane_id = next_global_worklane_id(&self.windows);
        let pane_id = next_global_pane_id_for_windows(&self.windows);
        let focused_cwd = self
            .active_window()
            .and_then(WindowLaunchPlan::focused_pane)
            .and_then(|pane| pane.terminal_request.working_directory.clone());

        let mut pane = base_new_pane(&pane_id, 0, 0);
        pane.worklane_id = worklane_id.clone();
        pane.column_id = format!("column-{pane_id}");
        pane.title = "pane 1".to_string();
        pane.column_width = DEFAULT_COLUMN_WIDTH;
        pane.terminal_request.working_directory = focused_cwd;

        self.windows.push(WindowLaunchPlan {
            window_id: window_id.clone(),
            active_worklane_id: Some(worklane_id.clone()),
            worklanes: vec![WorklaneLaunchPlan {
                worklane_id,
                title: None,
                panes: vec![pane],
                focused_pane_id: Some(pane_id),
            }],
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
        });
        self.active_window_id = Some(window_id);
        AppCommandExecutionResult::Applied
    }

    fn close_active_window(&mut self) -> AppCommandExecutionResult {
        if self.windows.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(active_window_index) = self.active_window_index() else {
            return AppCommandExecutionResult::Unavailable;
        };

        self.windows.remove(active_window_index);
        self.active_window_id = self
            .windows
            .get(
                active_window_index
                    .saturating_sub(1)
                    .min(self.windows.len().saturating_sub(1)),
            )
            .map(|window| window.window_id.clone());
        AppCommandExecutionResult::Applied
    }
}

impl AppLaunchPlan {
    pub fn from_envelope(envelope: &SessionRestoreEnvelope) -> Self {
        let windows: Vec<_> = envelope
            .workspace
            .windows
            .iter()
            .map(|window| {
                WindowLaunchPlan::from_recipe(window, envelope.restore_draft_window(&window.id))
            })
            .collect();
        let active_window_id = envelope
            .workspace
            .active_window_id
            .as_ref()
            .filter(|candidate| windows.iter().any(|window| &window.window_id == *candidate))
            .cloned()
            .or_else(|| windows.first().map(|window| window.window_id.clone()));

        Self {
            windows,
            active_window_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowLaunchPlan {
    pub window_id: String,
    pub worklanes: Vec<WorklaneLaunchPlan>,
    pub active_worklane_id: Option<String>,
    pub focus_history: PaneFocusHistory,
    pub closed_pane_stack: ClosedPaneStack,
    pub open_with_targets: Vec<OpenWithResolvedTarget>,
    pub detected_servers: Vec<DetectedServer>,
    pub task_runner_actions: Vec<TaskRunnerAction>,
    pub branch_urls_by_pane_id: BTreeMap<String, String>,
    pub worklane_colors_by_id: BTreeMap<String, String>,
}

impl WindowLaunchPlan {
    pub fn execute_command(&mut self, command_id: AppCommandId) -> AppCommandExecutionResult {
        match command_id {
            AppCommandId::FocusLeftPane => self.move_focus_horizontally(-1),
            AppCommandId::FocusRightPane => self.move_focus_horizontally(1),
            AppCommandId::FocusUpInColumn => self.move_focus_vertically(-1),
            AppCommandId::FocusDownInColumn => self.move_focus_vertically(1),
            AppCommandId::FocusPreviousPane => self.move_focus_by_sidebar_order(-1),
            AppCommandId::FocusNextPane => self.move_focus_by_sidebar_order(1),
            AppCommandId::SplitHorizontally
            | AppCommandId::ForceSplitRight
            | AppCommandId::ForceAddPaneRight => self.split_focused_pane_right(),
            AppCommandId::SplitVertically => self.split_focused_pane_below(),
            AppCommandId::DuplicateFocusedPane => self.duplicate_focused_pane(),
            AppCommandId::CloseFocusedPane => self.close_focused_pane(),
            AppCommandId::RestoreClosedPane => self.restore_closed_pane(),
            AppCommandId::ArrangeWidthFull => self.arrange_widths(1),
            AppCommandId::ArrangeWidthHalves => self.arrange_widths(2),
            AppCommandId::ArrangeWidthThirds => self.arrange_widths(3),
            AppCommandId::ArrangeWidthQuarters => self.arrange_widths(4),
            AppCommandId::ArrangeHeightFull => self.arrange_vertically(1),
            AppCommandId::ArrangeHeightTwoPerColumn => self.arrange_vertically(2),
            AppCommandId::ArrangeHeightThreePerColumn => self.arrange_vertically(3),
            AppCommandId::ArrangeHeightFourPerColumn => self.arrange_vertically(4),
            AppCommandId::ArrangeWidthGoldenFocusWide => self.arrange_golden_width(true),
            AppCommandId::ArrangeWidthGoldenFocusNarrow => self.arrange_golden_width(false),
            AppCommandId::ArrangeHeightGoldenFocusTall => self.arrange_golden_height(true),
            AppCommandId::ArrangeHeightGoldenFocusShort => self.arrange_golden_height(false),
            AppCommandId::ResizePaneLeft => self.resize_focused_column(-1),
            AppCommandId::ResizePaneRight => self.resize_focused_column(1),
            AppCommandId::ResizePaneUp => self.resize_focused_pane_height(-1),
            AppCommandId::ResizePaneDown => self.resize_focused_pane_height(1),
            AppCommandId::ResetPaneLayout => self.reset_active_worklane_layout(),
            AppCommandId::NewWorklane => self.create_new_worklane(),
            AppCommandId::NextWorklane => self.cycle_worklane(1),
            AppCommandId::PreviousWorklane => self.cycle_worklane(-1),
            AppCommandId::NavigateBack => self.navigate_focus_history(true),
            AppCommandId::NavigateForward => self.navigate_focus_history(false),
            AppCommandId::OpenWithSelectedApp => self.open_with_primary_target(),
            AppCommandId::OpenSelectedServer => self.open_primary_server(),
            AppCommandId::OpenBranchOnRemote => self.open_focused_branch_url(),
            AppCommandId::WorklaneMoveUp => self.move_active_worklane_by(-1),
            AppCommandId::WorklaneMoveDown => self.move_active_worklane_by(1),
            _ => AppCommandExecutionResult::Unsupported,
        }
    }

    pub fn execute_palette_item(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> CommandPaletteItemExecutionResult {
        match item_id {
            CommandPaletteItemId::Command(command_id) => AppCommandId::from_raw_value(command_id)
                .map(|command_id| self.execute_command(command_id).into())
                .unwrap_or(CommandPaletteItemExecutionResult::Unsupported),
            CommandPaletteItemId::Pane {
                worklane_id,
                pane_id,
            } => self.focus_pane_item(worklane_id, pane_id),
            CommandPaletteItemId::RestoredCommand { pane_id } => self
                .restored_command_for_pane(pane_id)
                .map(
                    |command| CommandPaletteItemExecutionResult::RunRestoredCommand {
                        pane_id: pane_id.clone(),
                        command,
                    },
                )
                .unwrap_or(CommandPaletteItemExecutionResult::Unavailable),
            CommandPaletteItemId::OpenWith { stable_id } => self.open_with_target(stable_id).into(),
            CommandPaletteItemId::Server { id } => self.open_server(id).into(),
            CommandPaletteItemId::TaskRunner(id) => self.run_task_runner(id),
            CommandPaletteItemId::WorklaneColor(color) => self.set_active_worklane_color(color),
            CommandPaletteItemId::Settings(section) => {
                CommandPaletteItemExecutionResult::ShowSettings {
                    section: section.clone(),
                }
            }
        }
    }

    pub fn resolve_command_palette(&self, search_text: &str) -> CommandPaletteResolvedResults {
        CommandPaletteResultsResolver::resolve(
            search_text,
            self.command_palette_items(),
            Vec::new(),
            Vec::new(),
            self.current_pane_item_id(),
            self.empty_action_ids(),
        )
    }

    pub fn command_palette_items(&self) -> Vec<CommandPaletteItem> {
        let mut items = self.command_palette_command_items();
        items.extend(CommandPaletteItemBuilder::build_settings_items());
        if let Some(item) = self.focused_restored_command_item() {
            items.push(item);
        }
        items.extend(CommandPaletteItemBuilder::build_open_with_items(
            &self.open_with_targets,
            self.focused_pane_path(),
        ));
        items.extend(CommandPaletteItemBuilder::build_server_items(
            &self.detected_servers,
        ));
        items.extend(CommandPaletteItemBuilder::build_task_runner_items(
            &self.task_runner_actions,
        ));
        items.extend(CommandPaletteItemBuilder::build_worklane_color_items());
        items.extend(self.pane_items());
        items
    }

    pub fn refresh_task_runner_actions(&mut self) -> usize {
        let actions = self
            .focused_pane_path()
            .map(|path| TaskRunnerDiscoveryService::new().discover(path))
            .unwrap_or_default();
        let count = actions.len();
        self.task_runner_actions = actions;
        count
    }

    pub fn command_palette_command_items(&self) -> Vec<CommandPaletteItem> {
        let command_ids = CommandAvailabilityResolver::available_command_ids_in_registry_order(
            self.command_availability_context(),
        );
        let command_context = self.command_palette_command_build_context();
        CommandPaletteItemBuilder::build_command_items(&command_ids, &command_context)
    }

    fn from_recipe(
        recipe: &WorkspaceRecipeWindow,
        restore_draft_window: Option<&SessionRestoreDraftWindow>,
    ) -> Self {
        let restored = WorkspaceRecipeImporter::make_worklanes(recipe);
        let restore_drafts = restore_drafts_by_pane_id(restore_draft_window);
        let worklanes: Vec<_> = restored
            .worklanes
            .iter()
            .map(|worklane| WorklaneLaunchPlan::from_state(worklane, &restore_drafts))
            .collect();
        let worklane_colors_by_id = recipe
            .worklanes
            .iter()
            .filter_map(|worklane| {
                worklane
                    .color
                    .as_deref()
                    .and_then(WorklaneColor::from_raw_value)
                    .map(|color| (worklane.id.clone(), color.raw_value().to_string()))
            })
            .collect();

        Self {
            window_id: recipe.id.clone(),
            worklanes,
            active_worklane_id: restored.active_worklane_id,
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id,
        }
    }

    fn focused_pane_id(&self) -> Option<String> {
        self.focused_pane().map(|pane| pane.pane_id.clone())
    }

    fn active_worklane(&self) -> Option<&WorklaneLaunchPlan> {
        self.active_worklane_id
            .as_ref()
            .and_then(|id| {
                self.worklanes
                    .iter()
                    .find(|worklane| &worklane.worklane_id == id)
            })
            .or_else(|| self.worklanes.first())
    }

    pub fn active_worklane_color(&self) -> Option<&str> {
        let worklane = self.active_worklane()?;
        self.worklane_colors_by_id
            .get(&worklane.worklane_id)
            .map(String::as_str)
    }

    fn active_worklane_index(&self) -> Option<usize> {
        self.active_worklane_id
            .as_ref()
            .and_then(|id| {
                self.worklanes
                    .iter()
                    .position(|worklane| &worklane.worklane_id == id)
            })
            .or((!self.worklanes.is_empty()).then_some(0))
    }

    fn focused_pane(&self) -> Option<&PaneLaunchSpec> {
        focused_pane_in_worklane(self.active_worklane()?)
    }

    fn focused_pane_path(&self) -> Option<&str> {
        self.focused_pane()
            .and_then(|pane| pane.terminal_request.working_directory.as_deref())
            .and_then(trimmed_non_empty)
    }

    fn focused_branch_url(&self) -> Option<&str> {
        let pane_id = self.focused_pane()?.pane_id.as_str();
        self.branch_urls_by_pane_id
            .get(pane_id)
            .map(String::as_str)
            .and_then(trimmed_non_empty)
    }

    fn open_with_primary_target(&self) -> AppCommandExecutionResult {
        let Some(target) = self.open_with_targets.first() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_with_target(&target.stable_id)
    }

    fn open_with_target(&self, stable_id: &str) -> AppCommandExecutionResult {
        let Some(path) = self.focused_pane_path() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_with_targets
            .iter()
            .find(|target| target.stable_id == stable_id)
            .map(|target| AppCommandExecutionResult::OpenPathWithTarget {
                path: path.to_string(),
                target_id: target.stable_id.clone(),
                target_name: target.display_name.clone(),
                app_path: target.app_path.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn open_primary_server(&self) -> AppCommandExecutionResult {
        let Some(server) = self.detected_servers.first() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_server(&server.id)
    }

    fn open_server(&self, id: &str) -> AppCommandExecutionResult {
        self.detected_servers
            .iter()
            .find(|server| server.id == id)
            .map(|server| AppCommandExecutionResult::OpenServer {
                server_id: server.id.clone(),
                origin: server.origin.clone(),
                url: server.url.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn open_focused_branch_url(&self) -> AppCommandExecutionResult {
        self.focused_branch_url()
            .map(|url| AppCommandExecutionResult::OpenUrl {
                url: url.to_string(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn set_active_worklane_color(
        &mut self,
        color: &Option<String>,
    ) -> CommandPaletteItemExecutionResult {
        let Some(worklane_id) = self
            .active_worklane()
            .map(|worklane| worklane.worklane_id.clone())
        else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let color = match color.as_deref() {
            Some(raw) => match WorklaneColor::from_raw_value(raw) {
                Some(color) => Some(color.raw_value().to_string()),
                None => return CommandPaletteItemExecutionResult::Unsupported,
            },
            None => None,
        };

        if let Some(color) = &color {
            self.worklane_colors_by_id
                .insert(worklane_id.clone(), color.clone());
        } else {
            self.worklane_colors_by_id.remove(&worklane_id);
        }

        CommandPaletteItemExecutionResult::SetWorklaneColor { worklane_id, color }
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
        match TaskRunnerExecutionPlanner::plan(&action, None) {
            TaskRunnerExecutionPlan::OpenSource { source_path } => {
                CommandPaletteItemExecutionResult::OpenTaskRunnerSource { source_path }
            }
            TaskRunnerExecutionPlan::NewPane { .. } => self.run_task_runner_in_new_pane(&action),
            TaskRunnerExecutionPlan::FocusedPane { .. } => {
                CommandPaletteItemExecutionResult::Unavailable
            }
        }
    }

    fn run_task_runner_in_new_pane(
        &mut self,
        action: &TaskRunnerAction,
    ) -> CommandPaletteItemExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]).cloned()
        else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };

        let new_pane_id = next_pane_id(&self.worklanes[worklane_index]);
        let new_column_index = focused.column_index + 1;
        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }

        let mut new_pane = new_inherited_pane(&new_pane_id, &focused, new_column_index, 0);
        new_pane.title = action.title.clone();
        new_pane.terminal_request.command = Some(action.execution_command.clone());
        if !action.working_directory.trim().is_empty() {
            new_pane.terminal_request.working_directory = Some(action.working_directory.clone());
        }
        new_pane.terminal_request.environment_variables = action
            .environment
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        self.worklanes[worklane_index].panes.push(new_pane);
        normalize_pane_order(&mut self.worklanes[worklane_index].panes);
        let worklane_id = focused.worklane_id;
        if self.focus_pane_by_id(worklane_id, new_pane_id.clone(), true)
            != AppCommandExecutionResult::Applied
        {
            return CommandPaletteItemExecutionResult::Unavailable;
        }

        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: new_pane_id,
            command: action.execution_command.clone(),
        }
    }

    fn current_pane_reference(&self) -> Option<PaneReference> {
        let worklane = self.active_worklane()?;
        let pane = focused_pane_in_worklane(worklane)?;
        Some(PaneReference::new(
            worklane.worklane_id.clone(),
            PaneId::from(pane.pane_id.clone()),
        ))
    }

    fn all_pane_references(&self) -> HashSet<PaneReference> {
        self.worklanes
            .iter()
            .flat_map(|worklane| {
                worklane.panes.iter().map(|pane| {
                    PaneReference::new(
                        worklane.worklane_id.clone(),
                        PaneId::from(pane.pane_id.clone()),
                    )
                })
            })
            .collect()
    }

    fn focus_pane_reference(
        &mut self,
        reference: PaneReference,
        record_history: bool,
    ) -> AppCommandExecutionResult {
        let Some(worklane_index) = self
            .worklanes
            .iter()
            .position(|worklane| worklane.worklane_id == reference.worklane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        if !self.worklanes[worklane_index]
            .panes
            .iter()
            .any(|pane| pane.pane_id == reference.pane_id.as_str())
        {
            return AppCommandExecutionResult::Unavailable;
        }

        if record_history
            && let Some(current) = self.current_pane_reference()
                && current != reference {
                    self.focus_history.record(current);
                }

        self.active_worklane_id = Some(reference.worklane_id);
        self.worklanes[worklane_index].focused_pane_id =
            Some(reference.pane_id.as_str().to_string());
        AppCommandExecutionResult::Applied
    }

    fn focus_pane_by_id(
        &mut self,
        worklane_id: impl Into<String>,
        pane_id: impl Into<String>,
        record_history: bool,
    ) -> AppCommandExecutionResult {
        self.focus_pane_reference(
            PaneReference::new(worklane_id, PaneId::from(pane_id.into())),
            record_history,
        )
    }

    fn command_availability_context(&self) -> CommandAvailabilityContext {
        let worklane_count = self.worklanes.len();
        let active_worklane = self.active_worklane();
        let active_pane_count = active_worklane
            .map(|worklane| worklane.panes.len())
            .unwrap_or_default();
        let total_pane_count = self
            .worklanes
            .iter()
            .map(|worklane| worklane.panes.len())
            .sum();
        let active_column_count = active_worklane
            .map(|worklane| {
                worklane
                    .panes
                    .iter()
                    .map(|pane| pane.column_id.as_str())
                    .collect::<BTreeSet<_>>()
                    .len()
            })
            .unwrap_or_default();
        let focused_column_pane_count = active_worklane
            .zip(self.focused_pane())
            .map(|(worklane, focused_pane)| {
                worklane
                    .panes
                    .iter()
                    .filter(|pane| pane.column_id == focused_pane.column_id)
                    .count()
            })
            .unwrap_or_default();

        CommandAvailabilityContext::new(worklane_count, active_pane_count, total_pane_count)
            .with_layout_counts(active_column_count, focused_column_pane_count)
            .with_focused_pane_can_open_with_primary(
                self.focused_pane_path().is_some() && !self.open_with_targets.is_empty(),
            )
            .with_active_worklane_primary_server(!self.detected_servers.is_empty())
            .with_active_worklane_branch_url(self.focused_branch_url().is_some())
    }

    fn command_palette_command_build_context(&self) -> CommandPaletteCommandBuildContext {
        let mut context = CommandPaletteCommandBuildContext::default();
        if let Some(path) = self
            .focused_pane()
            .and_then(|pane| pane.terminal_request.working_directory.as_deref())
        {
            context = context.with_focused_pane_path(path);
        }
        context
    }

    fn focused_restored_command_item(&self) -> Option<CommandPaletteItem> {
        let pane = self.focused_pane()?;
        let command = pane
            .restored_rerunnable_command
            .as_deref()
            .and_then(trimmed_non_empty)?;
        Some(CommandPaletteItemBuilder::build_restored_command_item(
            pane.pane_id.clone(),
            command,
        ))
    }

    fn empty_action_ids(&self) -> Vec<CommandPaletteItemId> {
        let mut ids = Vec::new();
        if let Some(pane) = self.focused_pane()
            && pane
                .restored_rerunnable_command
                .as_deref()
                .and_then(trimmed_non_empty)
                .is_some()
            {
                ids.push(CommandPaletteItemId::restored_command(pane.pane_id.clone()));
            }
        ids.extend([
            CommandPaletteItemId::command(AppCommandId::NewWorklane.raw_value()),
            CommandPaletteItemId::command(AppCommandId::SplitHorizontally.raw_value()),
            CommandPaletteItemId::command(AppCommandId::SplitVertically.raw_value()),
            CommandPaletteItemId::command(AppCommandId::OpenSettings.raw_value()),
        ]);
        ids
    }

    fn current_pane_item_id(&self) -> Option<CommandPaletteItemId> {
        let worklane = self.active_worklane()?;
        let pane = self.focused_pane()?;
        Some(CommandPaletteItemId::pane(
            worklane.worklane_id.clone(),
            pane.pane_id.clone(),
        ))
    }

    fn focus_pane_item(
        &mut self,
        worklane_id: &str,
        pane_id: &str,
    ) -> CommandPaletteItemExecutionResult {
        self.focus_pane_by_id(worklane_id, pane_id, true).into()
    }

    fn restored_command_for_pane(&self, pane_id: &str) -> Option<String> {
        self.worklanes
            .iter()
            .flat_map(|worklane| &worklane.panes)
            .find(|pane| pane.pane_id == pane_id)
            .and_then(|pane| pane.restored_rerunnable_command.as_deref())
            .and_then(trimmed_non_empty)
            .map(ToOwned::to_owned)
    }

    fn pane_items(&self) -> Vec<CommandPaletteItem> {
        let active_worklane_id = self.active_worklane_id.as_deref();
        let current_pane = self.focused_pane().map(|pane| pane.pane_id.as_str());
        self.worklanes
            .iter()
            .flat_map(|worklane| {
                worklane.panes.iter().map(move |pane| {
                    let worklane_title = worklane.title.as_deref().unwrap_or("Main");
                    let location = pane.terminal_request.working_directory.as_deref();
                    let status = pane.status_text.as_deref().and_then(trimmed_non_empty);
                    let subtitle = [Some(worklane_title), location, status]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join(" \u{2022} ");
                    let is_current = active_worklane_id == Some(worklane.worklane_id.as_str())
                        && current_pane == Some(pane.pane_id.as_str());
                    let secondary_search_text = [
                        subtitle.as_str(),
                        worklane.title.as_deref().unwrap_or_default(),
                        worklane_title,
                        pane.title.as_str(),
                        location.unwrap_or_default(),
                        status.unwrap_or_default(),
                    ]
                    .into_iter()
                    .filter(|part| !part.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");

                    CommandPaletteItem::new(
                        CommandPaletteItemId::pane(
                            worklane.worklane_id.clone(),
                            pane.pane_id.clone(),
                        ),
                        pane.title.clone(),
                        subtitle,
                        if is_current { "Current Pane" } else { "Pane" },
                        format!("{} {}", pane.title, secondary_search_text),
                    )
                    .with_primary_search_text(&pane.title)
                    .with_secondary_search_text(secondary_search_text)
                    .with_group(CommandPaletteItemGroup::Pane)
                    .with_icon_system_name("arrow.right.square")
                    .with_ranking_boost(if is_current { 0.02 } else { 0.08 })
                })
            })
            .collect()
    }

    fn move_focus_vertically(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let worklane_id = self.worklanes[worklane_index].worklane_id.clone();
        let Some(target_pane_id) = target_vertical_pane_id(&self.worklanes[worklane_index], delta)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_by_id(worklane_id, target_pane_id, true)
    }

    fn move_focus_horizontally(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let worklane_id = self.worklanes[worklane_index].worklane_id.clone();
        let Some(target_pane_id) =
            target_horizontal_pane_id(&self.worklanes[worklane_index], delta)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_by_id(worklane_id, target_pane_id, true)
    }

    fn split_focused_pane_right(&mut self) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]).cloned()
        else {
            return AppCommandExecutionResult::Unavailable;
        };

        let new_pane_id = next_pane_id(&self.worklanes[worklane_index]);
        let new_column_index = focused.column_index + 1;
        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }

        let new_pane = new_inherited_pane(&new_pane_id, &focused, new_column_index, 0);
        self.worklanes[worklane_index].panes.push(new_pane);
        normalize_pane_order(&mut self.worklanes[worklane_index].panes);
        self.focus_pane_by_id(focused.worklane_id, new_pane_id, true)
    }

    fn split_focused_pane_below(&mut self) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]).cloned()
        else {
            return AppCommandExecutionResult::Unavailable;
        };

        let new_pane_id = next_pane_id(&self.worklanes[worklane_index]);
        let new_pane_index = focused.pane_index + 1;
        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index == focused.column_index && pane.pane_index >= new_pane_index {
                pane.pane_index += 1;
            }
        }

        let new_pane =
            new_inherited_pane(&new_pane_id, &focused, focused.column_index, new_pane_index);
        self.worklanes[worklane_index].panes.push(new_pane);
        normalize_pane_order(&mut self.worklanes[worklane_index].panes);
        self.focus_pane_by_id(focused.worklane_id, new_pane_id, true)
    }

    fn duplicate_focused_pane(&mut self) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]).cloned()
        else {
            return AppCommandExecutionResult::Unavailable;
        };

        let new_pane_id = next_pane_id(&self.worklanes[worklane_index]);
        let new_column_index = focused.column_index + 1;
        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index >= new_column_index {
                pane.column_index += 1;
            }
        }

        let mut new_pane = base_new_pane(&new_pane_id, new_column_index, 0);
        new_pane.worklane_id = focused.worklane_id.clone();
        new_pane.terminal_request.working_directory =
            focused.terminal_request.working_directory.clone();
        new_pane.terminal_request.environment_variables =
            focused.terminal_request.environment_variables.clone();
        self.worklanes[worklane_index].panes.push(new_pane);
        normalize_pane_order(&mut self.worklanes[worklane_index].panes);
        self.focus_pane_by_id(focused.worklane_id, new_pane_id, true)
    }

    fn close_focused_pane(&mut self) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused_pane_id) = self.worklanes[worklane_index].focused_pane_id.clone() else {
            return AppCommandExecutionResult::Unavailable;
        };

        let total_pane_count = self
            .worklanes
            .iter()
            .map(|worklane| worklane.panes.len())
            .sum::<usize>();
        if total_pane_count <= 1 {
            return AppCommandExecutionResult::RequestCloseWindow {
                window_id: self.window_id.clone(),
            };
        }

        let Some(focused_position) = self.worklanes[worklane_index]
            .panes
            .iter()
            .position(|pane| pane.pane_id == focused_pane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let captured = closed_pane_entry_for(
            &self.worklanes[worklane_index],
            &self.worklanes[worklane_index].panes[focused_position],
        );
        let removed = self.worklanes[worklane_index]
            .panes
            .remove(focused_position);
        if let Some(entry) = captured {
            self.closed_pane_stack.push(entry, LAUNCH_PLAN_TIME);
        }

        if self.worklanes[worklane_index].panes.is_empty() {
            self.worklanes.remove(worklane_index);
            self.active_worklane_id = self
                .worklanes
                .get(
                    worklane_index
                        .saturating_sub(1)
                        .min(self.worklanes.len().saturating_sub(1)),
                )
                .map(|worklane| worklane.worklane_id.clone());
            return AppCommandExecutionResult::Applied;
        }

        normalize_after_remove(&mut self.worklanes[worklane_index].panes, &removed);
        let next_focus = next_focus_after_removal(&self.worklanes[worklane_index], &removed);
        self.worklanes[worklane_index].focused_pane_id = next_focus;
        AppCommandExecutionResult::Applied
    }

    fn restore_closed_pane(&mut self) -> AppCommandExecutionResult {
        let Some(entry) = self.closed_pane_stack.peek(LAUNCH_PLAN_TIME).cloned() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(target) = self.resolve_restore_target(&entry) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(worklane_index) = self
            .worklanes
            .iter()
            .position(|worklane| worklane.worklane_id == target.worklane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let _ = self.closed_pane_stack.pop_latest(LAUNCH_PLAN_TIME);

        let cwd_resolution = ClosedPaneCwdResolver::resolve(
            entry.working_directory.as_deref(),
            &home_directory_for_restore(),
        );
        let pane_id = next_restored_pane_id(&self.worklanes);
        let mut restored = base_new_pane(&pane_id, target.column_index, target.pane_index);
        restored.worklane_id = target.worklane_id.clone();
        restored.column_id = target
            .column_id
            .clone()
            .unwrap_or_else(|| entry.original_column_id.as_str().to_string());
        restored.title = entry.title.clone();
        restored.column_width = entry.original_column_width;
        restored.pane_height = entry.original_height_in_column;
        restored.terminal_request = TerminalSessionRequest {
            working_directory: Some(cwd_resolution.path.clone()),
            prefill_text: restore_prefill_text(&entry),
            ..TerminalSessionRequest::default()
        };

        insert_restored_pane(
            &mut self.worklanes[worklane_index],
            restored,
            &target,
            entry.original_column_width,
        );
        self.active_worklane_id = Some(target.worklane_id.clone());
        let _ = self.focus_pane_by_id(target.worklane_id.clone(), pane_id.clone(), true);

        let mut toast_message = match ClosedPaneRestoreCommandResolver::resolve(&entry) {
            ClosedPaneRestoreCommand::AgentResume { tool, .. } => format!(
                "Restored \"{}\" - {} resuming at {}",
                entry.title,
                tool_display_name(&tool),
                cwd_resolution.path
            ),
            ClosedPaneRestoreCommand::ReplayCommand(_) | ClosedPaneRestoreCommand::PlainShell => {
                format!("Restored \"{}\" at {}", entry.title, cwd_resolution.path)
            }
        };
        if cwd_resolution.original_missing {
            toast_message.push_str(" - original directory missing");
        }

        AppCommandExecutionResult::RestoredClosedPane {
            pane_id,
            worklane_id: target.worklane_id,
            toast_message,
        }
    }

    fn resolve_restore_target(&self, entry: &ClosedPaneEntry) -> Option<LaunchRestoreTarget> {
        if let Some(worklane) = self
            .worklanes
            .iter()
            .find(|worklane| worklane.worklane_id == entry.original_worklane_id)
        {
            if let Some(column) = column_snapshot_by_id(worklane, entry.original_column_id.as_str())
            {
                let pane_count = worklane
                    .panes
                    .iter()
                    .filter(|pane| pane.column_id == column.column_id)
                    .count();
                return Some(LaunchRestoreTarget {
                    worklane_id: worklane.worklane_id.clone(),
                    column_id: Some(column.column_id),
                    column_index: column.column_index,
                    pane_index: entry.original_pane_index.min(pane_count),
                });
            }
            return Some(LaunchRestoreTarget {
                worklane_id: worklane.worklane_id.clone(),
                column_id: None,
                column_index: entry
                    .original_column_index
                    .min(column_snapshots(worklane).len()),
                pane_index: 0,
            });
        }

        let active = self.active_worklane()?;
        let focused_column_id = self.focused_pane().map(|pane| pane.column_id.clone());
        Some(LaunchRestoreTarget {
            worklane_id: active.worklane_id.clone(),
            column_id: focused_column_id,
            column_index: column_snapshots(active).len(),
            pane_index: 0,
        })
    }

    fn arrange_widths(&mut self, visible_column_count: usize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        if self.worklanes[worklane_index].panes.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let columns = column_snapshots(&self.worklanes[worklane_index]);
        let visible_column_count = visible_column_count.max(1);
        if columns.len() < visible_column_count {
            return AppCommandExecutionResult::Unavailable;
        }

        let total_width = columns
            .iter()
            .map(|column| column.width.max(1.0))
            .sum::<f64>()
            .max(1.0);
        let target_width = (total_width / visible_column_count as f64).max(1.0);
        let mut did_change = false;
        for pane in &mut self.worklanes[worklane_index].panes {
            if !nearly_equal(pane.column_width, target_width) {
                did_change = true;
            }
            pane.column_width = target_width;
        }

        if did_change {
            AppCommandExecutionResult::Applied
        } else {
            AppCommandExecutionResult::Unavailable
        }
    }

    fn arrange_vertically(&mut self, panes_per_column: usize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let panes_per_column = panes_per_column.max(1);
        let worklane = &mut self.worklanes[worklane_index];
        if worklane.panes.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let previous_columns = column_snapshots(worklane);
        let fallback_width = previous_columns
            .last()
            .map(|column| column.width)
            .unwrap_or(640.0);
        let mut panes = worklane.panes.clone();
        normalize_pane_order(&mut panes);

        let mut rebuilt = Vec::with_capacity(panes.len());
        let mut used_column_ids = BTreeSet::new();
        for (column_index, pane_chunk) in panes.chunks(panes_per_column).enumerate() {
            let Some(first_pane) = pane_chunk.first() else {
                continue;
            };
            let preferred_column_id = previous_columns
                .get(column_index)
                .map(|column| column.column_id.clone())
                .unwrap_or_else(|| format!("column-{}", first_pane.pane_id));
            let column_id = unique_column_id(preferred_column_id, &mut used_column_ids);
            let column_width = previous_columns
                .get(column_index)
                .map(|column| column.width)
                .unwrap_or(fallback_width);

            for (pane_index, pane) in pane_chunk.iter().cloned().enumerate() {
                let mut pane = pane;
                pane.column_id = column_id.clone();
                pane.column_index = column_index;
                pane.pane_index = pane_index;
                pane.column_width = column_width;
                pane.pane_height = Some(1.0);
                rebuilt.push(pane);
            }
        }

        if rebuilt == worklane.panes {
            return AppCommandExecutionResult::Unavailable;
        }

        worklane.panes = rebuilt;
        normalize_pane_order(&mut worklane.panes);
        if !focused_pane_id_exists(worklane) {
            worklane.focused_pane_id = worklane.panes.first().map(|pane| pane.pane_id.clone());
        }
        AppCommandExecutionResult::Applied
    }

    fn arrange_golden_width(&mut self, focus_wide: bool) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let columns = column_snapshots(&self.worklanes[worklane_index]);
        if columns.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let Some(focused_column_position) = columns
            .iter()
            .position(|column| column.column_index == focused.column_index)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let neighbor_column_position = if focused_column_position + 1 < columns.len() {
            focused_column_position + 1
        } else {
            focused_column_position - 1
        };
        let focused_column = &columns[focused_column_position];
        let neighbor_column = &columns[neighbor_column_position];
        let pair_width = (focused_column.width.max(1.0) + neighbor_column.width.max(1.0)).max(1.0);
        let focused_ratio = if focus_wide {
            golden_major_ratio()
        } else {
            1.0 - golden_major_ratio()
        };
        let focused_width = pair_width * focused_ratio;
        let neighbor_width = pair_width - focused_width;
        let mut did_change = false;

        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index == focused_column.column_index {
                if !nearly_equal(pane.column_width, focused_width) {
                    did_change = true;
                }
                pane.column_width = focused_width;
            } else if pane.column_index == neighbor_column.column_index {
                if !nearly_equal(pane.column_width, neighbor_width) {
                    did_change = true;
                }
                pane.column_width = neighbor_width;
            }
        }

        if did_change {
            AppCommandExecutionResult::Applied
        } else {
            AppCommandExecutionResult::Unavailable
        }
    }

    fn arrange_golden_height(&mut self, focus_tall: bool) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let focused_column_index = focused.column_index;
        let focused_pane_id = focused.pane_id.clone();
        let mut column_pane_indices = self.worklanes[worklane_index]
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| pane.column_index == focused_column_index)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        column_pane_indices.sort_by_key(|index| {
            (
                self.worklanes[worklane_index].panes[*index].pane_index,
                self.worklanes[worklane_index].panes[*index].pane_id.clone(),
            )
        });
        if column_pane_indices.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let Some(focused_position) = column_pane_indices.iter().position(|index| {
            self.worklanes[worklane_index].panes[*index].pane_id == focused_pane_id
        }) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let neighbor_position = if focused_position + 1 < column_pane_indices.len() {
            focused_position + 1
        } else {
            focused_position - 1
        };
        let focused_index = column_pane_indices[focused_position];
        let neighbor_index = column_pane_indices[neighbor_position];
        let focused_height = self.worklanes[worklane_index].panes[focused_index]
            .pane_height
            .unwrap_or(1.0)
            .max(1.0);
        let neighbor_height = self.worklanes[worklane_index].panes[neighbor_index]
            .pane_height
            .unwrap_or(1.0)
            .max(1.0);
        let combined_height = focused_height + neighbor_height;
        let focused_ratio = if focus_tall {
            golden_major_ratio()
        } else {
            1.0 - golden_major_ratio()
        };
        let target_focused_height = combined_height * focused_ratio;
        let target_neighbor_height = combined_height - target_focused_height;

        if nearly_equal(focused_height, target_focused_height)
            && nearly_equal(neighbor_height, target_neighbor_height)
        {
            return AppCommandExecutionResult::Unavailable;
        }

        self.worklanes[worklane_index].panes[focused_index].pane_height =
            Some(target_focused_height);
        self.worklanes[worklane_index].panes[neighbor_index].pane_height =
            Some(target_neighbor_height);
        AppCommandExecutionResult::Applied
    }

    fn resize_focused_column(&mut self, direction: isize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let columns = column_snapshots(&self.worklanes[worklane_index]);
        if columns.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let focused_column_index = focused.column_index;
        let current_width = focused.column_width.max(MIN_LAYOUT_WEIGHT);
        let width_delta = RESIZE_STEP * direction.signum() as f64;
        let target_width = (current_width + width_delta).max(MIN_LAYOUT_WEIGHT);
        if nearly_equal(target_width, current_width) {
            return AppCommandExecutionResult::Unavailable;
        }

        for pane in &mut self.worklanes[worklane_index].panes {
            if pane.column_index == focused_column_index {
                pane.column_width = target_width;
            }
        }
        AppCommandExecutionResult::Applied
    }

    fn resize_focused_pane_height(&mut self, direction: isize) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(focused) = focused_pane_in_worklane(&self.worklanes[worklane_index]) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let focused_column_index = focused.column_index;
        let focused_pane_id = focused.pane_id.clone();
        let mut column_pane_indices = self.worklanes[worklane_index]
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| pane.column_index == focused_column_index)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        column_pane_indices.sort_by_key(|index| {
            (
                self.worklanes[worklane_index].panes[*index].pane_index,
                self.worklanes[worklane_index].panes[*index].pane_id.clone(),
            )
        });
        if column_pane_indices.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }

        let Some(focused_position) = column_pane_indices.iter().position(|index| {
            self.worklanes[worklane_index].panes[*index].pane_id == focused_pane_id
        }) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let neighbor_position = if focused_position + 1 < column_pane_indices.len() {
            focused_position + 1
        } else {
            focused_position.saturating_sub(1)
        };
        if neighbor_position == focused_position || neighbor_position >= column_pane_indices.len() {
            return AppCommandExecutionResult::Unavailable;
        }

        let focused_index = column_pane_indices[focused_position];
        let neighbor_index = column_pane_indices[neighbor_position];
        let focused_height = self.worklanes[worklane_index].panes[focused_index]
            .pane_height
            .unwrap_or(1.0)
            .max(MIN_LAYOUT_WEIGHT);
        let neighbor_height = self.worklanes[worklane_index].panes[neighbor_index]
            .pane_height
            .unwrap_or(1.0)
            .max(MIN_LAYOUT_WEIGHT);
        let grow_step = if direction > 0 {
            RESIZE_STEP.min((neighbor_height - MIN_LAYOUT_WEIGHT).max(0.0))
        } else {
            -RESIZE_STEP.min((focused_height - MIN_LAYOUT_WEIGHT).max(0.0))
        };
        if nearly_equal(grow_step, 0.0) {
            return AppCommandExecutionResult::Unavailable;
        }

        self.worklanes[worklane_index].panes[focused_index].pane_height =
            Some(focused_height + grow_step);
        self.worklanes[worklane_index].panes[neighbor_index].pane_height =
            Some(neighbor_height - grow_step);
        AppCommandExecutionResult::Applied
    }

    fn reset_active_worklane_layout(&mut self) -> AppCommandExecutionResult {
        let Some(worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let worklane = &mut self.worklanes[worklane_index];
        if worklane.panes.is_empty() {
            return AppCommandExecutionResult::Unavailable;
        }

        let mut did_change = false;
        for pane in &mut worklane.panes {
            if !nearly_equal(pane.column_width, DEFAULT_COLUMN_WIDTH) {
                did_change = true;
            }
            pane.column_width = DEFAULT_COLUMN_WIDTH;
            if pane.pane_height != Some(MIN_LAYOUT_WEIGHT) {
                did_change = true;
            }
            pane.pane_height = Some(MIN_LAYOUT_WEIGHT);
        }

        if did_change {
            AppCommandExecutionResult::Applied
        } else {
            AppCommandExecutionResult::Unavailable
        }
    }

    fn create_new_worklane(&mut self) -> AppCommandExecutionResult {
        let insertion_index = self
            .active_worklane_index()
            .map(|index| index + 1)
            .unwrap_or(self.worklanes.len());
        let worklane_id = next_worklane_id(&self.worklanes);
        let pane_id = next_global_pane_id(&self.worklanes);
        let focused_cwd = self
            .focused_pane()
            .and_then(|pane| pane.terminal_request.working_directory.clone());
        let mut pane = base_new_pane(&pane_id, 0, 0);
        pane.worklane_id = worklane_id.clone();
        pane.column_id = format!("column-{pane_id}");
        pane.title = "pane 1".to_string();
        pane.column_width = DEFAULT_COLUMN_WIDTH;
        pane.terminal_request.working_directory = focused_cwd;

        self.worklanes.insert(
            insertion_index,
            WorklaneLaunchPlan {
                worklane_id: worklane_id.clone(),
                title: None,
                panes: vec![pane],
                focused_pane_id: Some(pane_id.clone()),
            },
        );
        self.focus_pane_by_id(worklane_id, pane_id, true)
    }

    fn cycle_worklane(&mut self, delta: isize) -> AppCommandExecutionResult {
        if self.worklanes.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(current_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let len = self.worklanes.len() as isize;
        let next_index = (current_index as isize + delta).rem_euclid(len) as usize;
        let target_worklane_id = self.worklanes[next_index].worklane_id.clone();
        let Some(target_pane_id) =
            focused_pane_in_worklane(&self.worklanes[next_index]).map(|pane| pane.pane_id.clone())
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_by_id(target_worklane_id, target_pane_id, true)
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

    fn move_active_worklane_by(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(current_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let target_index = current_index as isize + delta;
        if !(0..self.worklanes.len() as isize).contains(&target_index) {
            return AppCommandExecutionResult::Unavailable;
        }
        self.worklanes.swap(current_index, target_index as usize);
        AppCommandExecutionResult::Applied
    }

    fn move_focus_by_sidebar_order(&mut self, delta: isize) -> AppCommandExecutionResult {
        let mut pane_refs = Vec::new();
        for (worklane_index, worklane) in self.worklanes.iter().enumerate() {
            let mut pane_indices = (0..worklane.panes.len()).collect::<Vec<_>>();
            pane_indices.sort_by_key(|index| {
                (
                    worklane.panes[*index].column_index,
                    worklane.panes[*index].pane_index,
                    worklane.panes[*index].pane_id.clone(),
                )
            });
            pane_refs.extend(
                pane_indices
                    .into_iter()
                    .map(|pane_index| (worklane_index, pane_index)),
            );
        }
        if pane_refs.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }

        let Some(active_worklane_index) = self.active_worklane_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let focused_pane_id = self.worklanes[active_worklane_index]
            .focused_pane_id
            .as_deref();
        let current_index = pane_refs
            .iter()
            .position(|(worklane_index, pane_index)| {
                *worklane_index == active_worklane_index
                    && focused_pane_id
                        == Some(
                            self.worklanes[*worklane_index].panes[*pane_index]
                                .pane_id
                                .as_str(),
                        )
            })
            .unwrap_or(0);
        let next_index =
            (current_index as isize + delta).rem_euclid(pane_refs.len() as isize) as usize;
        let (target_worklane_index, target_pane_index) = pane_refs[next_index];
        let target_worklane_id = self.worklanes[target_worklane_index].worklane_id.clone();
        let target_pane_id = self.worklanes[target_worklane_index].panes[target_pane_index]
            .pane_id
            .clone();
        self.focus_pane_by_id(target_worklane_id, target_pane_id, true)
    }
}

const DEFAULT_COLUMN_WIDTH: f64 = 640.0;
const LAUNCH_PLAN_TIME: f64 = 0.0;
const MIN_LAYOUT_WEIGHT: f64 = 1.0;
const RESIZE_STEP: f64 = 24.0;

#[derive(Clone, Debug, Eq, PartialEq)]
struct LaunchRestoreTarget {
    worklane_id: String,
    column_id: Option<String>,
    column_index: usize,
    pane_index: usize,
}

#[derive(Clone, Debug, PartialEq)]
struct ColumnLaunchSnapshot {
    column_id: String,
    column_index: usize,
    width: f64,
}

fn column_snapshots(worklane: &WorklaneLaunchPlan) -> Vec<ColumnLaunchSnapshot> {
    let mut panes = worklane.panes.iter().collect::<Vec<_>>();
    panes.sort_by(|lhs, rhs| {
        lhs.column_index
            .cmp(&rhs.column_index)
            .then(lhs.pane_index.cmp(&rhs.pane_index))
            .then(lhs.pane_id.cmp(&rhs.pane_id))
    });

    let mut seen_column_indices = BTreeSet::new();
    let mut snapshots = Vec::new();
    for pane in panes {
        if seen_column_indices.insert(pane.column_index) {
            snapshots.push(ColumnLaunchSnapshot {
                column_id: pane.column_id.clone(),
                column_index: pane.column_index,
                width: pane.column_width,
            });
        }
    }
    snapshots
}

fn column_snapshot_by_id(
    worklane: &WorklaneLaunchPlan,
    column_id: &str,
) -> Option<ColumnLaunchSnapshot> {
    column_snapshots(worklane)
        .into_iter()
        .find(|column| column.column_id == column_id)
}

fn closed_pane_entry_for(
    worklane: &WorklaneLaunchPlan,
    pane: &PaneLaunchSpec,
) -> Option<ClosedPaneEntry> {
    if !worklane
        .panes
        .iter()
        .any(|candidate| candidate.pane_id == pane.pane_id)
    {
        return None;
    }
    let column_pane_count = worklane
        .panes
        .iter()
        .filter(|candidate| candidate.column_id == pane.column_id)
        .count();
    Some(ClosedPaneEntry {
        id: format!("closed-{}", pane.pane_id),
        closed_at: LAUNCH_PLAN_TIME,
        original_pane_id: PaneId::from(pane.pane_id.clone()),
        original_worklane_id: worklane.worklane_id.clone(),
        original_column_id: PaneColumnId::from(pane.column_id.clone()),
        original_column_index: pane.column_index,
        original_pane_index: pane.pane_index,
        original_column_width: pane.column_width,
        original_height_in_column: (column_pane_count > 1)
            .then_some(pane.pane_height)
            .flatten(),
        title: pane.title.clone(),
        working_directory: pane.terminal_request.working_directory.clone(),
        original_native_command: pane.terminal_request.native_command.clone(),
        original_command: pane.terminal_request.command.clone(),
        agent_snapshot: None,
        scrollback_text: None,
    })
}

fn insert_restored_pane(
    worklane: &mut WorklaneLaunchPlan,
    mut pane: PaneLaunchSpec,
    target: &LaunchRestoreTarget,
    original_column_width: f64,
) {
    if let Some(column_id) = &target.column_id
        && let Some(column) = column_snapshot_by_id(worklane, column_id)
    {
        for existing in &mut worklane.panes {
            if existing.column_id == *column_id && existing.pane_index >= target.pane_index {
                existing.pane_index += 1;
            }
        }
        pane.column_id = column.column_id;
        pane.column_index = column.column_index;
        pane.column_width = column.width;
        pane.pane_index = target.pane_index;
        worklane.panes.push(pane);
        normalize_pane_order(&mut worklane.panes);
        return;
    }

    for existing in &mut worklane.panes {
        if existing.column_index >= target.column_index {
            existing.column_index += 1;
        }
    }
    pane.column_index = target.column_index;
    pane.pane_index = 0;
    pane.column_width = original_column_width;
    worklane.panes.push(pane);
    normalize_pane_order(&mut worklane.panes);
}

fn restore_prefill_text(entry: &ClosedPaneEntry) -> Option<String> {
    let command = match ClosedPaneRestoreCommandResolver::resolve(entry) {
        ClosedPaneRestoreCommand::AgentResume { command, .. }
        | ClosedPaneRestoreCommand::ReplayCommand(command) => Some(command),
        ClosedPaneRestoreCommand::PlainShell => None,
    }?;
    let trimmed = command.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(format!("{trimmed}\n"))
    }
}

fn next_restored_pane_id(worklanes: &[WorklaneLaunchPlan]) -> String {
    let next = worklanes
        .iter()
        .flat_map(|worklane| &worklane.panes)
        .filter_map(|pane| pane.pane_id.strip_prefix("restored-"))
        .filter_map(|suffix| suffix.parse::<u32>().ok())
        .max()
        .unwrap_or(0)
        + 1;
    format!("restored-{next}")
}

fn home_directory_for_restore() -> String {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| ".".to_string())
}

fn tool_display_name(tool: &zentty_core::agent::AgentTool) -> &'static str {
    match tool {
        zentty_core::agent::AgentTool::ClaudeCode => "Claude Code",
        zentty_core::agent::AgentTool::OpenCode => "OpenCode",
        zentty_core::agent::AgentTool::Agy => "Antigravity",
        zentty_core::agent::AgentTool::Copilot => "GitHub Copilot",
        zentty_core::agent::AgentTool::Custom(_) => "Agent",
        zentty_core::agent::AgentTool::Zentty => "Zentty",
        zentty_core::agent::AgentTool::Amp => "Amp",
        zentty_core::agent::AgentTool::Codex => "Codex",
        zentty_core::agent::AgentTool::Cursor => "Cursor",
        zentty_core::agent::AgentTool::Droid => "Droid",
        zentty_core::agent::AgentTool::Gemini => "Gemini",
        zentty_core::agent::AgentTool::Kimi => "Kimi",
        zentty_core::agent::AgentTool::Pi => "Pi",
        zentty_core::agent::AgentTool::Grok => "Grok",
        zentty_core::agent::AgentTool::Hermes => "Hermes",
    }
}

fn unique_column_id(preferred_column_id: String, used_column_ids: &mut BTreeSet<String>) -> String {
    if used_column_ids.insert(preferred_column_id.clone()) {
        return preferred_column_id;
    }

    let mut index = 2;
    loop {
        let candidate = format!("{preferred_column_id}-{index}");
        if used_column_ids.insert(candidate.clone()) {
            return candidate;
        }
        index += 1;
    }
}

fn focused_pane_id_exists(worklane: &WorklaneLaunchPlan) -> bool {
    worklane
        .focused_pane_id
        .as_deref()
        .map(|focused_pane_id| {
            worklane
                .panes
                .iter()
                .any(|pane| pane.pane_id == focused_pane_id)
        })
        .unwrap_or(false)
}

fn golden_major_ratio() -> f64 {
    let phi = (1.0 + 5.0_f64.sqrt()) / 2.0;
    phi / (1.0 + phi)
}

fn nearly_equal(lhs: f64, rhs: f64) -> bool {
    (lhs - rhs).abs() <= 0.001
}

fn focused_pane_in_worklane(worklane: &WorklaneLaunchPlan) -> Option<&PaneLaunchSpec> {
    worklane
        .focused_pane_id
        .as_ref()
        .and_then(|pane_id| worklane.panes.iter().find(|pane| &pane.pane_id == pane_id))
        .or_else(|| worklane.panes.first())
}

fn target_vertical_pane_id(worklane: &WorklaneLaunchPlan, delta: isize) -> Option<String> {
    let current = focused_pane_in_worklane(worklane)?;
    let mut column_panes = worklane
        .panes
        .iter()
        .filter(|pane| pane.column_id == current.column_id)
        .collect::<Vec<_>>();
    column_panes.sort_by_key(|pane| pane.pane_index);
    let current_index = column_panes
        .iter()
        .position(|pane| pane.pane_id == current.pane_id)?;
    let target_index =
        (current_index as isize + delta).clamp(0, column_panes.len() as isize - 1) as usize;
    let target = column_panes[target_index];
    (target.pane_id != current.pane_id).then(|| target.pane_id.clone())
}

fn target_horizontal_pane_id(worklane: &WorklaneLaunchPlan, delta: isize) -> Option<String> {
    let current = focused_pane_in_worklane(worklane)?;
    let mut column_indices = worklane
        .panes
        .iter()
        .map(|pane| pane.column_index)
        .collect::<Vec<_>>();
    column_indices.sort_unstable();
    column_indices.dedup();
    let current_column_position = column_indices
        .iter()
        .position(|column_index| *column_index == current.column_index)?;
    let target_column_position = (current_column_position as isize + delta)
        .clamp(0, column_indices.len() as isize - 1) as usize;
    let target_column_index = column_indices[target_column_position];
    let target = worklane
        .panes
        .iter()
        .filter(|pane| pane.column_index == target_column_index)
        .min_by_key(|pane| pane.pane_index.abs_diff(current.pane_index))?;
    (target.pane_id != current.pane_id).then(|| target.pane_id.clone())
}

fn next_pane_id(worklane: &WorklaneLaunchPlan) -> String {
    let mut index = worklane.panes.len() + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !worklane.panes.iter().any(|pane| pane.pane_id == candidate) {
            return candidate;
        }
        index += 1;
    }
}

fn next_worklane_id(worklanes: &[WorklaneLaunchPlan]) -> String {
    let mut index = worklanes.len() + 1;
    loop {
        let candidate = format!("worklane-{index}");
        if !worklanes
            .iter()
            .any(|worklane| worklane.worklane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn next_global_worklane_id(windows: &[WindowLaunchPlan]) -> String {
    let mut index = windows
        .iter()
        .map(|window| window.worklanes.len())
        .sum::<usize>()
        + 1;
    loop {
        let candidate = format!("worklane-{index}");
        if !windows
            .iter()
            .flat_map(|window| &window.worklanes)
            .any(|worklane| worklane.worklane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn next_window_id(windows: &[WindowLaunchPlan]) -> String {
    let mut index = windows.len() + 1;
    loop {
        let candidate = format!("window-{index}");
        if !windows.iter().any(|window| window.window_id == candidate) {
            return candidate;
        }
        index += 1;
    }
}

fn next_global_pane_id(worklanes: &[WorklaneLaunchPlan]) -> String {
    let mut index = worklanes
        .iter()
        .map(|worklane| worklane.panes.len())
        .sum::<usize>()
        + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !worklanes
            .iter()
            .flat_map(|worklane| &worklane.panes)
            .any(|pane| pane.pane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn next_global_pane_id_for_windows(windows: &[WindowLaunchPlan]) -> String {
    let mut index = windows
        .iter()
        .flat_map(|window| &window.worklanes)
        .map(|worklane| worklane.panes.len())
        .sum::<usize>()
        + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !windows
            .iter()
            .flat_map(|window| &window.worklanes)
            .flat_map(|worklane| &worklane.panes)
            .any(|pane| pane.pane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn retarget_worklane_for_split_out(worklane: &mut WorklaneLaunchPlan) {
    for pane in &mut worklane.panes {
        pane.worklane_id = worklane.worklane_id.clone();
    }
    normalize_pane_order(&mut worklane.panes);
    if !focused_pane_id_exists(worklane) {
        worklane.focused_pane_id = worklane.panes.first().map(|pane| pane.pane_id.clone());
    }
}

fn retarget_pane_for_split_out(pane: &mut PaneLaunchSpec, destination_worklane_id: &str) {
    pane.worklane_id = destination_worklane_id.to_string();
    pane.column_id = format!("column-{}", pane.pane_id);
    pane.column_index = 0;
    pane.pane_index = 0;
    pane.column_width = 640.0;
    pane.pane_height = Some(1.0);
}

fn base_new_pane(pane_id: &str, column_index: usize, pane_index: usize) -> PaneLaunchSpec {
    PaneLaunchSpec {
        pane_id: pane_id.to_string(),
        worklane_id: String::new(),
        column_id: format!("column-{pane_id}"),
        column_index,
        pane_index,
        title: pane_id.replace('-', " "),
        column_width: 640.0,
        pane_height: None,
        terminal_request: TerminalSessionRequest::default(),
        restored_rerunnable_command: None,
        status_text: None,
        applied_restore_draft_tool: None,
    }
}

fn new_inherited_pane(
    pane_id: &str,
    source: &PaneLaunchSpec,
    column_index: usize,
    pane_index: usize,
) -> PaneLaunchSpec {
    let mut pane = base_new_pane(pane_id, column_index, pane_index);
    pane.worklane_id = source.worklane_id.clone();
    if column_index == source.column_index {
        pane.column_id = source.column_id.clone();
    }
    pane.column_width = source.column_width;
    pane.pane_height = source.pane_height;
    pane.terminal_request.inherit_from_pane_id = Some(PaneId::from(source.pane_id.clone()));
    pane.terminal_request.config_inheritance_source_pane_id =
        Some(PaneId::from(source.pane_id.clone()));
    pane
}

fn apply_runtime_terminal_inheritance(pane: &mut PaneLaunchSpec, source: &PaneLaunchSpec) {
    pane.terminal_request.working_directory = source.terminal_request.working_directory.clone();
    pane.terminal_request.environment_variables =
        source.terminal_request.environment_variables.clone();
}

fn normalize_pane_order(panes: &mut [PaneLaunchSpec]) {
    panes.sort_by(|lhs, rhs| {
        lhs.column_index
            .cmp(&rhs.column_index)
            .then(lhs.pane_index.cmp(&rhs.pane_index))
            .then(lhs.pane_id.cmp(&rhs.pane_id))
    });
}

fn normalize_after_remove(panes: &mut [PaneLaunchSpec], removed: &PaneLaunchSpec) {
    let removed_column_still_exists = panes
        .iter()
        .any(|candidate| candidate.column_index == removed.column_index);
    for pane in panes.iter_mut() {
        if pane.column_index == removed.column_index && pane.pane_index > removed.pane_index {
            pane.pane_index -= 1;
        }
        if pane.column_index > removed.column_index && !removed_column_still_exists {
            pane.column_index -= 1;
        }
    }
    normalize_pane_order(panes);
}

fn next_focus_after_removal(
    worklane: &WorklaneLaunchPlan,
    removed: &PaneLaunchSpec,
) -> Option<String> {
    worklane
        .panes
        .iter()
        .filter(|pane| pane.column_index == removed.column_index)
        .min_by_key(|pane| pane.pane_index.abs_diff(removed.pane_index))
        .or_else(|| {
            worklane
                .panes
                .iter()
                .min_by_key(|pane| pane.column_index.abs_diff(removed.column_index))
        })
        .map(|pane| pane.pane_id.clone())
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorklaneLaunchPlan {
    pub worklane_id: String,
    pub title: Option<String>,
    pub panes: Vec<PaneLaunchSpec>,
    pub focused_pane_id: Option<String>,
}

impl WorklaneLaunchPlan {
    fn from_state(
        worklane: &WorklaneState,
        restore_drafts: &BTreeMap<String, PaneRestoreDraft>,
    ) -> Self {
        let panes = worklane
            .pane_strip_state
            .columns()
            .iter()
            .enumerate()
            .flat_map(|(column_index, column)| {
                column
                    .panes()
                    .iter()
                    .enumerate()
                    .map(move |(pane_index, pane)| {
                        let auxiliary = worklane.auxiliary_state_by_pane_id.get(pane.id().as_str());
                        let restore_draft = restore_drafts.get(pane.id().as_str());
                        let mut terminal_request = pane.session_request.clone();
                        let applied_restore_draft_tool = restore_draft.and_then(|draft| {
                            AgentResumeCommandBuilder::command(draft.clone()).map(|command| {
                                terminal_request.command = Some(command);
                                draft.tool_name.clone()
                            })
                        });

                        PaneLaunchSpec {
                            pane_id: pane.id().as_str().to_string(),
                            worklane_id: worklane.id.clone(),
                            column_id: column.id().as_str().to_string(),
                            column_index,
                            pane_index,
                            title: pane.title().to_string(),
                            column_width: column.width,
                            pane_height: column.pane_heights().get(pane_index).copied(),
                            terminal_request,
                            restored_rerunnable_command: auxiliary
                                .and_then(|state| state.raw.restored_rerunnable_command.clone()),
                            status_text: auxiliary
                                .and_then(|state| state.presentation.status_text.clone()),
                            applied_restore_draft_tool,
                        }
                    })
            })
            .collect();

        Self {
            worklane_id: worklane.id.clone(),
            title: worklane.title.clone(),
            panes,
            focused_pane_id: worklane
                .pane_strip_state
                .focused_pane_id()
                .map(|id| id.as_str().to_string()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PaneLaunchSpec {
    pub pane_id: String,
    pub worklane_id: String,
    pub column_id: String,
    pub column_index: usize,
    pub pane_index: usize,
    pub title: String,
    pub column_width: f64,
    pub pane_height: Option<f64>,
    pub terminal_request: TerminalSessionRequest,
    pub restored_rerunnable_command: Option<String>,
    pub status_text: Option<String>,
    pub applied_restore_draft_tool: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct AgentIpcPaneKey {
    pub window_id: Option<String>,
    pub worklane_id: String,
    pub pane_id: String,
}

impl AgentIpcPaneKey {
    pub fn new(window_id: Option<&str>, worklane_id: &str, pane_id: &str) -> Self {
        Self {
            window_id: window_id.map(str::to_string),
            worklane_id: worklane_id.to_string(),
            pane_id: pane_id.to_string(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentIpcPaneEnvironment {
    pub window_id: Option<String>,
    pub worklane_id: String,
    pub pane_id: String,
    pub socket_path: String,
    pub pane_token: String,
    pub cli_bin: String,
    pub instance_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentIpcRuntimeEnvironment {
    socket_path: String,
    cli_bin: String,
    instance_id: String,
    pane_tokens: BTreeMap<AgentIpcPaneKey, String>,
}

impl AgentIpcRuntimeEnvironment {
    pub fn new(
        socket_path: impl Into<String>,
        cli_bin: impl Into<String>,
        instance_id: impl Into<String>,
    ) -> Self {
        Self {
            socket_path: socket_path.into(),
            cli_bin: cli_bin.into(),
            instance_id: instance_id.into(),
            pane_tokens: BTreeMap::new(),
        }
    }

    pub fn with_pane_token(
        mut self,
        window_id: Option<&str>,
        worklane_id: &str,
        pane_id: &str,
        pane_token: impl Into<String>,
    ) -> Self {
        self.pane_tokens.insert(
            AgentIpcPaneKey::new(window_id, worklane_id, pane_id),
            pane_token.into(),
        );
        self
    }

    pub fn socket_path(&self) -> &str {
        &self.socket_path
    }

    pub fn pane_environment(
        &self,
        window_id: Option<&str>,
        pane: &PaneLaunchSpec,
    ) -> Option<AgentIpcPaneEnvironment> {
        let key = AgentIpcPaneKey::new(window_id, &pane.worklane_id, &pane.pane_id);
        let pane_token = self.pane_tokens.get(&key)?.clone();
        Some(AgentIpcPaneEnvironment {
            window_id: window_id.map(str::to_string),
            worklane_id: pane.worklane_id.clone(),
            pane_id: pane.pane_id.clone(),
            socket_path: self.socket_path.clone(),
            pane_token,
            cli_bin: self.cli_bin.clone(),
            instance_id: self.instance_id.clone(),
        })
    }

    pub fn is_valid_pane_token(
        &self,
        window_id: Option<&str>,
        worklane_id: &str,
        pane_id: &str,
        pane_token: &str,
    ) -> bool {
        trimmed_non_empty(pane_token).is_some()
            && self
                .pane_tokens
                .get(&AgentIpcPaneKey::new(window_id, worklane_id, pane_id))
                .is_some_and(|expected| expected == pane_token)
    }

    pub fn set_pane_token(
        &mut self,
        window_id: Option<&str>,
        worklane_id: &str,
        pane_id: &str,
        pane_token: impl Into<String>,
    ) {
        self.pane_tokens.insert(
            AgentIpcPaneKey::new(window_id, worklane_id, pane_id),
            pane_token.into(),
        );
    }
}

struct AgentIpcAuthenticatedTarget {
    window_id: Option<String>,
    worklane_id: String,
    pane_id: String,
    pane_token: String,
}

impl AgentIpcAuthenticatedTarget {
    fn from_request(request: &AgentIpcRequest) -> Option<Self> {
        let environment = &request.environment;
        Some(Self {
            window_id: environment
                .get("ZENTTY_WINDOW_ID")
                .and_then(|value| trimmed_non_empty(value))
                .map(str::to_string),
            worklane_id: environment
                .get("ZENTTY_WORKLANE_ID")
                .and_then(|value| trimmed_non_empty(value))
                .map(str::to_string)?,
            pane_id: environment
                .get("ZENTTY_PANE_ID")
                .and_then(|value| trimmed_non_empty(value))
                .map(str::to_string)?,
            pane_token: environment
                .get("ZENTTY_PANE_TOKEN")
                .and_then(|value| trimmed_non_empty(value))
                .map(str::to_string)?,
        })
    }
}

pub(crate) struct AgentIpcRequestRejection {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

impl AgentIpcRequestRejection {
    pub(crate) fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AgentIpcPaneTarget {
    pub(crate) window_id: Option<String>,
    pub(crate) worklane_id: String,
    pub(crate) pane_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AgentIpcPaneSelectors {
    pub(crate) window_id: Option<String>,
    pub(crate) worklane_id: Option<String>,
    pub(crate) pane_id: Option<String>,
    pub(crate) pane_index: Option<usize>,
    pub(crate) pane_token: Option<String>,
    pub(crate) arguments: Vec<String>,
}

impl AgentIpcPaneSelectors {
    pub(crate) fn pane_token<'a>(
        &'a self,
        environment: &'a BTreeMap<String, String>,
    ) -> Option<&'a str> {
        self.pane_token
            .as_deref()
            .or_else(|| environment.get("ZENTTY_PANE_TOKEN").map(String::as_str))
            .and_then(trimmed_non_empty)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PaneIpcSplitDirection {
    Right,
    Left,
    Down,
    Up,
}

impl PaneIpcSplitDirection {
    pub(crate) fn parse(arguments: &[String]) -> Option<Self> {
        match arguments.first().map(String::as_str).unwrap_or("right") {
            "right" => Some(Self::Right),
            "left" => Some(Self::Left),
            "down" => Some(Self::Down),
            "up" => Some(Self::Up),
            _ => None,
        }
    }

    pub(crate) fn is_horizontal(self) -> bool {
        matches!(self, Self::Right | Self::Left)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum PaneIpcSplitLayout {
    None,
    Equal,
    Golden,
    Ratio(f64),
}

impl PaneIpcSplitLayout {
    pub(crate) fn parse(arguments: &[String]) -> Self {
        if arguments.iter().any(|argument| argument == "--equal") {
            return Self::Equal;
        }
        if arguments.iter().any(|argument| argument == "--golden") {
            return Self::Golden;
        }
        arguments
            .iter()
            .position(|argument| argument == "--ratio")
            .and_then(|index| arguments.get(index + 1))
            .and_then(|value| value.parse::<f64>().ok())
            .filter(|value| *value > 0.0 && *value <= 100.0)
            .map(|value| Self::Ratio(value / 100.0))
            .unwrap_or(Self::None)
    }
}

pub(crate) fn percentage_fraction(argument: &str) -> Option<f64> {
    let value = argument
        .strip_suffix('%')?
        .parse::<f64>()
        .ok()
        .filter(|value| *value > 0.0 && *value <= 100.0)?;
    Some(value / 100.0)
}

pub(crate) fn pane_ipc_worklane_id_override(arguments: &[String]) -> Option<&str> {
    arguments
        .iter()
        .position(|argument| argument == "--id")
        .and_then(|index| arguments.get(index + 1))
        .and_then(|value| trimmed_non_empty(value))
}

pub(crate) fn pane_ipc_worklane_color(arguments: &[String]) -> Option<Option<String>> {
    let raw_color = arguments
        .iter()
        .position(|argument| argument == "--color")
        .and_then(|index| arguments.get(index + 1))
        .and_then(|value| trimmed_non_empty(value))?;
    if matches!(raw_color, "reset" | "default") {
        return Some(None);
    }
    WorklaneColor::from_raw_value(raw_color).map(|color| Some(color.raw_value().to_string()))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PaneIpcWorklaneRename {
    pub(crate) title: Option<String>,
    pub(crate) worklane_id_override: Option<String>,
}

pub(crate) fn pane_ipc_worklane_rename(arguments: &[String]) -> Option<PaneIpcWorklaneRename> {
    let mut title = None;
    let mut saw_title = false;
    let mut saw_clear = false;
    let mut worklane_id_override = None;
    let mut index = 0;

    while index < arguments.len() {
        match arguments[index].as_str() {
            "--clear" => {
                saw_clear = true;
                index += 1;
            }
            "--title" => {
                let value = arguments.get(index + 1)?;
                title = Some(value.clone());
                saw_title = true;
                index += 2;
            }
            "--id" => {
                let value = arguments.get(index + 1)?;
                worklane_id_override = Some(value.clone());
                index += 2;
            }
            _ => {
                index += 1;
            }
        }
    }

    if saw_clear {
        return Some(PaneIpcWorklaneRename {
            title: None,
            worklane_id_override,
        });
    }
    saw_title.then_some(PaneIpcWorklaneRename {
        title,
        worklane_id_override,
    })
}

pub(crate) fn normalized_worklane_title(title: Option<&str>) -> Option<String> {
    title.and_then(trimmed_non_empty).map(ToOwned::to_owned)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PaneIpcGridDestination {
    Current,
    NewWorklane,
    NewWindow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PaneIpcGridFocus {
    Source,
    First,
    Last,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PaneIpcGridOptions {
    pub(crate) rows: usize,
    pub(crate) columns: usize,
    pub(crate) command: Option<String>,
    pub(crate) include_source: bool,
    pub(crate) focus: PaneIpcGridFocus,
    pub(crate) destination: PaneIpcGridDestination,
}

pub(crate) fn pane_ipc_grid_options(
    arguments: &[String],
) -> Result<PaneIpcGridOptions, AgentIpcRequestRejection> {
    let mut rows = None;
    let mut columns = None;
    let mut command_tokens = None;
    let mut include_source = false;
    let mut focus = PaneIpcGridFocus::Source;
    let mut destination = PaneIpcGridDestination::Current;
    let mut index = 0;

    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--rows" => {
                let raw = pane_grid_option_value(arguments, index, argument)?;
                rows = Some(parse_positive_grid_dimension("--rows", raw)?);
                index += 2;
            }
            "--columns" => {
                let raw = pane_grid_option_value(arguments, index, argument)?;
                columns = Some(parse_positive_grid_dimension("--columns", raw)?);
                index += 2;
            }
            "--command-json" => {
                let raw = pane_grid_option_value(arguments, index, argument)?;
                let tokens = serde_json::from_str::<Vec<String>>(raw).map_err(|_| {
                    AgentIpcRequestRejection::new(
                        "invalid_grid_command_json",
                        "Invalid grid command payload.",
                    )
                })?;
                command_tokens = Some(tokens);
                index += 2;
            }
            "--include-source" => {
                include_source = true;
                index += 1;
            }
            "--new-only" => {
                include_source = false;
                index += 1;
            }
            "--new-worklane" => {
                if destination != PaneIpcGridDestination::NewWindow {
                    destination = PaneIpcGridDestination::NewWorklane;
                }
                index += 1;
            }
            "--new-window" => {
                destination = PaneIpcGridDestination::NewWindow;
                index += 1;
            }
            "--focus" => {
                let raw = pane_grid_option_value(arguments, index, argument)?;
                focus = match raw {
                    "source" => PaneIpcGridFocus::Source,
                    "first" => PaneIpcGridFocus::First,
                    "last" => PaneIpcGridFocus::Last,
                    _ => {
                        return Err(AgentIpcRequestRejection::new(
                            "invalid_value",
                            format!("Invalid value for --focus: {raw}."),
                        ));
                    }
                };
                index += 2;
            }
            _ => {
                return Err(AgentIpcRequestRejection::new(
                    "unexpected_argument",
                    format!("Unexpected grid argument: {argument}."),
                ));
            }
        }
    }

    let rows = rows.ok_or_else(|| {
        AgentIpcRequestRejection::new("missing_value", "Missing value for --rows.")
    })?;
    let columns = columns.ok_or_else(|| {
        AgentIpcRequestRejection::new("missing_value", "Missing value for --columns.")
    })?;
    let command = command_tokens
        .as_deref()
        .map(grid_launch_command_from_tokens)
        .transpose()?;

    Ok(PaneIpcGridOptions {
        rows,
        columns,
        command,
        include_source,
        focus,
        destination,
    })
}

fn pane_grid_option_value<'a>(
    arguments: &'a [String],
    index: usize,
    option: &str,
) -> Result<&'a str, AgentIpcRequestRejection> {
    arguments.get(index + 1).map(String::as_str).ok_or_else(|| {
        AgentIpcRequestRejection::new("missing_value", format!("Missing value for {option}."))
    })
}

fn parse_positive_grid_dimension(
    option: &str,
    raw: &str,
) -> Result<usize, AgentIpcRequestRejection> {
    raw.parse::<usize>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| {
            AgentIpcRequestRejection::new(
                "invalid_value",
                format!("Invalid value for {option}: {raw}."),
            )
        })
}

fn grid_launch_command_from_tokens(tokens: &[String]) -> Result<String, AgentIpcRequestRejection> {
    if !tokens.iter().any(|token| !token.trim().is_empty()) {
        return Err(AgentIpcRequestRejection::new(
            "missing_grid_command",
            "Missing grid launch command.",
        ));
    }
    if tokens
        .iter()
        .any(|token| token.contains('\n') || token.contains('\r'))
    {
        return Err(AgentIpcRequestRejection::new(
            "unsupported_grid_command_token",
            "Grid launch command tokens may not contain newlines.",
        ));
    }
    Ok(tokens
        .iter()
        .map(|token| shell_quote_grid_token(token))
        .collect::<Vec<_>>()
        .join(" "))
}

fn shell_quote_grid_token(token: &str) -> String {
    let is_bare = !token.is_empty()
        && token.chars().all(|ch| {
            ch.is_ascii_alphanumeric()
                || matches!(
                    ch,
                    '_' | '@' | '%' | '+' | '=' | ':' | ',' | '.' | '/' | '-'
                )
        });
    if is_bare {
        token.to_string()
    } else {
        format!("'{}'", token.replace('\'', "'\"'\"'"))
    }
}

pub(crate) fn grid_cell_count(
    rows: usize,
    columns: usize,
) -> Result<usize, AgentIpcRequestRejection> {
    let Some(cell_count) = rows.checked_mul(columns) else {
        return Err(AgentIpcRequestRejection::new(
            "grid_too_many_cells",
            "Grid dimensions may create at most 36 panes.",
        ));
    };
    if rows == 0 || columns == 0 {
        return Err(AgentIpcRequestRejection::new(
            "invalid_grid_dimensions",
            "Grid dimensions must be positive.",
        ));
    }
    if cell_count > 36 {
        return Err(AgentIpcRequestRejection::new(
            "grid_too_many_cells",
            "Grid dimensions may create at most 36 panes.",
        ));
    }
    Ok(cell_count)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaneNotification {
    pub title: String,
    pub subtitle: Option<String>,
    pub body: Option<String>,
    pub include_inbox: bool,
    pub is_silent: bool,
    pub window_id: String,
    pub worklane_id: String,
    pub pane_id: String,
}

impl PaneNotification {
    pub fn primary_text(&self) -> &str {
        self.body
            .as_deref()
            .or(self.subtitle.as_deref())
            .unwrap_or("Notification from pane.")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PaneIpcNotificationOptions {
    pub(crate) title: String,
    pub(crate) subtitle: Option<String>,
    pub(crate) body: Option<String>,
    pub(crate) include_inbox: bool,
    pub(crate) is_silent: bool,
}

pub(crate) fn pane_ipc_notification_options(
    arguments: &[String],
) -> Result<PaneIpcNotificationOptions, AgentIpcRequestRejection> {
    let mut title = None;
    let mut subtitle = None;
    let mut body = None;
    let mut include_inbox = true;
    let mut is_silent = false;
    let mut index = 0;

    while index < arguments.len() {
        match arguments[index].as_str() {
            "--title" => {
                let value = arguments.get(index + 1).ok_or_else(|| {
                    AgentIpcRequestRejection::new("missing_value", "Missing value for --title.")
                })?;
                title = normalized_worklane_title(Some(value));
                index += 2;
            }
            "--subtitle" => {
                let value = arguments.get(index + 1).ok_or_else(|| {
                    AgentIpcRequestRejection::new("missing_value", "Missing value for --subtitle.")
                })?;
                subtitle = normalized_worklane_title(Some(value));
                index += 2;
            }
            "--body" => {
                let value = arguments.get(index + 1).ok_or_else(|| {
                    AgentIpcRequestRejection::new("missing_value", "Missing value for --body.")
                })?;
                body = normalized_worklane_title(Some(value));
                index += 2;
            }
            "--no-inbox" => {
                include_inbox = false;
                index += 1;
            }
            "--silent" => {
                is_silent = true;
                index += 1;
            }
            argument => {
                return Err(AgentIpcRequestRejection::new(
                    "unexpected_argument",
                    format!("Unexpected notification argument: {argument}."),
                ));
            }
        }
    }

    let Some(title) = title else {
        return Err(AgentIpcRequestRejection::new(
            "missing_title",
            "Missing notification title.",
        ));
    };

    Ok(PaneIpcNotificationOptions {
        title,
        subtitle,
        body,
        include_inbox,
        is_silent,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PaneIpcThemeCommand {
    Toggle,
    Dark,
    Light,
    Auto,
}

impl PaneIpcThemeCommand {
    pub(crate) fn parse(raw_command: &str) -> Option<Self> {
        match raw_command {
            "toggle" => Some(Self::Toggle),
            "dark" => Some(Self::Dark),
            "light" => Some(Self::Light),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }

    pub(crate) fn resolve(self, current_mode: AppearanceThemeMode) -> AppearanceThemeMode {
        match self {
            Self::Dark => AppearanceThemeMode::AlwaysDark,
            Self::Light => AppearanceThemeMode::AlwaysLight,
            Self::Auto => AppearanceThemeMode::FollowMacOS,
            Self::Toggle => match current_mode {
                AppearanceThemeMode::AlwaysDark => AppearanceThemeMode::AlwaysLight,
                AppearanceThemeMode::AlwaysLight => AppearanceThemeMode::AlwaysDark,
                AppearanceThemeMode::FollowMacOS => AppearanceThemeMode::AlwaysLight,
            },
        }
    }
}

pub(crate) fn pane_ipc_theme_mode_token(mode: AppearanceThemeMode) -> &'static str {
    match mode {
        AppearanceThemeMode::FollowMacOS => "auto",
        AppearanceThemeMode::AlwaysDark => "dark",
        AppearanceThemeMode::AlwaysLight => "light",
    }
}

pub(crate) fn parse_agent_ipc_pane_selectors(
    arguments: &[String],
) -> Result<AgentIpcPaneSelectors, AgentIpcRequestRejection> {
    let mut sanitized_arguments = Vec::new();
    let mut window_id = None;
    let mut worklane_id = None;
    let mut pane_id = None;
    let mut pane_index = None;
    let mut pane_token = None;
    let mut index = 0;

    while index < arguments.len() {
        let argument = &arguments[index];
        match argument.as_str() {
            "--window-id" => {
                window_id = Some(agent_ipc_selector_value(arguments, index, argument)?);
                index += 2;
            }
            "--worklane-id" => {
                worklane_id = Some(agent_ipc_selector_value(arguments, index, argument)?);
                index += 2;
            }
            "--pane-id" => {
                pane_id = Some(agent_ipc_selector_value(arguments, index, argument)?);
                index += 2;
            }
            "--pane-index" => {
                let raw_value = agent_ipc_selector_value(arguments, index, argument)?;
                let parsed = raw_value.parse::<usize>().ok().filter(|value| *value > 0);
                let Some(parsed) = parsed else {
                    return Err(AgentIpcRequestRejection::new(
                        "invalid_pane_index",
                        format!("Invalid pane index '{raw_value}'."),
                    ));
                };
                pane_index = Some(parsed);
                index += 2;
            }
            "--pane-token" => {
                pane_token = Some(agent_ipc_selector_value(arguments, index, argument)?);
                index += 2;
            }
            _ => {
                sanitized_arguments.push(argument.clone());
                index += 1;
            }
        }
    }

    if pane_id.is_some() && pane_index.is_some() {
        return Err(AgentIpcRequestRejection::new(
            "conflicting_pane_selectors",
            "Specify only one of --pane-id or --pane-index.",
        ));
    }

    Ok(AgentIpcPaneSelectors {
        window_id,
        worklane_id,
        pane_id,
        pane_index,
        pane_token,
        arguments: sanitized_arguments,
    })
}

fn agent_ipc_selector_value(
    arguments: &[String],
    index: usize,
    option: &str,
) -> Result<String, AgentIpcRequestRejection> {
    let value_index = index + 1;
    arguments
        .get(value_index)
        .and_then(|value| trimmed_non_empty(value))
        .map(str::to_string)
        .ok_or_else(|| {
            AgentIpcRequestRejection::new("missing_value", format!("Missing value for {option}."))
        })
}

pub(crate) fn agent_ipc_pane_list_success_response_if_expected(
    request: &AgentIpcRequest,
    pane_list: Vec<PaneListEntry>,
) -> Option<AgentIpcResponse> {
    request.expects_response.then(|| AgentIpcResponse {
        version: 1,
        id: request.id.clone(),
        ok: true,
        result: Some(AgentIpcResponseResult {
            pane_list: Some(pane_list),
            ..AgentIpcResponseResult::default()
        }),
        error: None,
    })
}

fn agent_ipc_pane_not_found_rejection() -> AgentIpcRequestRejection {
    AgentIpcRequestRejection::new("pane_not_found", "Target pane was not found.")
}

fn agent_ipc_error_is_routable(error: &AgentIpcRequestRejection) -> bool {
    matches!(error.code, "invalid_pane_token" | "pane_not_found")
}

fn agent_ipc_missing_target_context_rejection() -> AgentIpcRequestRejection {
    AgentIpcRequestRejection::new("missing_target_context", "Missing pane target context.")
}

fn resolve_single_agent_ipc_pane_candidate(
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

pub(crate) fn agent_signal_payload_for_authenticated_ipc_request(
    request: &AgentIpcRequest,
    agent_ipc_environment: Option<&AgentIpcRuntimeEnvironment>,
) -> Result<AgentSignalPayload, AgentIpcRequestRejection> {
    if request.version != 1 {
        return Err(AgentIpcRequestRejection::new(
            "invalid_message",
            "Invalid IPC protocol version.",
        ));
    }
    if request.kind != AgentIpcRequestKind::Ipc {
        return Err(AgentIpcRequestRejection::new(
            "unsupported_subcommand",
            "Unsupported IPC request kind.",
        ));
    }
    if request.subcommand.as_deref() != Some("agent-signal") {
        return Err(AgentIpcRequestRejection::new(
            "unsupported_subcommand",
            "Unsupported IPC subcommand.",
        ));
    }

    let target = AgentIpcAuthenticatedTarget::from_request(request).ok_or_else(|| {
        AgentIpcRequestRejection::new("missing_target_context", "Missing IPC target context.")
    })?;
    let token_is_valid = agent_ipc_environment.is_some_and(|environment| {
        environment.is_valid_pane_token(
            target.window_id.as_deref(),
            &target.worklane_id,
            &target.pane_id,
            &target.pane_token,
        )
    });
    if !token_is_valid {
        return Err(AgentIpcRequestRejection::new(
            "invalid_pane_token",
            "Invalid pane token.",
        ));
    }

    let arguments = canonical_agent_signal_arguments(&request.arguments, &target);
    let environment = canonical_agent_ipc_environment(&request.environment, &target);
    AgentSignalCommand::parse(&arguments, &environment)
        .map(|command| command.payload)
        .map_err(|error| AgentIpcRequestRejection::new("invalid_message", error.to_string()))
}

fn canonical_agent_signal_arguments(
    arguments: &[String],
    target: &AgentIpcAuthenticatedTarget,
) -> Vec<String> {
    let mut sanitized_arguments = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if matches!(
            argument.as_str(),
            "--window-id" | "--worklane-id" | "--pane-id"
        ) {
            index += (arguments.len() - index).min(2);
            continue;
        }
        sanitized_arguments.push(argument.clone());
        index += 1;
    }

    if let Some(window_id) = target.window_id.as_deref() {
        sanitized_arguments.extend(["--window-id".to_string(), window_id.to_string()]);
    }
    sanitized_arguments.extend([
        "--worklane-id".to_string(),
        target.worklane_id.clone(),
        "--pane-id".to_string(),
        target.pane_id.clone(),
    ]);
    sanitized_arguments
}

fn canonical_agent_ipc_environment(
    environment: &BTreeMap<String, String>,
    target: &AgentIpcAuthenticatedTarget,
) -> BTreeMap<String, String> {
    let mut canonical_environment = environment.clone();
    if let Some(window_id) = target.window_id.as_deref() {
        canonical_environment.insert("ZENTTY_WINDOW_ID".to_string(), window_id.to_string());
    } else {
        canonical_environment.remove("ZENTTY_WINDOW_ID");
    }
    canonical_environment.insert("ZENTTY_WORKLANE_ID".to_string(), target.worklane_id.clone());
    canonical_environment.insert("ZENTTY_PANE_ID".to_string(), target.pane_id.clone());
    canonical_environment
}

pub(crate) fn agent_ipc_success_response_if_expected(
    request: &AgentIpcRequest,
) -> Option<AgentIpcResponse> {
    request.expects_response.then(|| AgentIpcResponse {
        version: 1,
        id: request.id.clone(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    })
}

pub(crate) fn agent_ipc_stdout_success_response_if_expected(
    request: &AgentIpcRequest,
    stdout: String,
) -> Option<AgentIpcResponse> {
    request.expects_response.then(|| AgentIpcResponse {
        version: 1,
        id: request.id.clone(),
        ok: true,
        result: Some(AgentIpcResponseResult {
            stdout: Some(stdout),
            ..AgentIpcResponseResult::default()
        }),
        error: None,
    })
}

pub(crate) fn agent_ipc_error_response_if_expected(
    request: &AgentIpcRequest,
    code: &str,
    message: &str,
) -> Option<AgentIpcResponse> {
    request.expects_response.then(|| AgentIpcResponse {
        version: 1,
        id: request.id.clone(),
        ok: false,
        result: None,
        error: Some(AgentIpcResponseError {
            code: code.to_string(),
            message: message.to_string(),
        }),
    })
}

pub struct RunningApp {
    window_id: Option<String>,
    default_size: TerminalSize,
    active_worklane_id: Option<String>,
    worklane_order: Vec<String>,
    focused_pane_id_by_worklane_id: BTreeMap<String, String>,
    focus_history: PaneFocusHistory,
    open_with_targets: Vec<OpenWithResolvedTarget>,
    detected_servers: Vec<DetectedServer>,
    task_runner_actions: Vec<TaskRunnerAction>,
    branch_urls_by_pane_id: BTreeMap<String, String>,
    worklane_colors_by_id: BTreeMap<String, String>,
    worklane_titles_by_id: BTreeMap<String, String>,
    pane_notifications: Vec<PaneNotification>,
    theme_mode: AppearanceThemeMode,
    closed_pane_specs: Vec<PaneLaunchSpec>,
    panes: Vec<RunningPane>,
    focused_pane_id: Option<String>,
    agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
}

pub struct RunningAppSet {
    active_window_id: Option<String>,
    default_size: TerminalSize,
    windows: Vec<RunningApp>,
}

impl RunningAppSet {
    pub fn spawn(plan: AppLaunchPlan, size: TerminalSize) -> Result<Self, AppLaunchError> {
        Self::spawn_internal(plan, size, None)
    }

    pub fn spawn_with_agent_ipc(
        plan: AppLaunchPlan,
        size: TerminalSize,
        agent_ipc_environment: AgentIpcRuntimeEnvironment,
    ) -> Result<Self, AppLaunchError> {
        Self::spawn_internal(plan, size, Some(agent_ipc_environment))
    }

    fn spawn_internal(
        plan: AppLaunchPlan,
        size: TerminalSize,
        agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
    ) -> Result<Self, AppLaunchError> {
        let active_window_id = plan
            .active_window_id
            .clone()
            .or_else(|| plan.windows.first().map(|window| window.window_id.clone()));
        let mut windows = Vec::new();
        for window in plan.windows {
            let window_id = window.window_id.clone();
            let window_plan = AppLaunchPlan {
                active_window_id: Some(window_id),
                windows: vec![window],
            };
            let running = match agent_ipc_environment.clone() {
                Some(environment) => {
                    RunningApp::spawn_with_agent_ipc(window_plan, size, environment)?
                }
                None => RunningApp::spawn(window_plan, size)?,
            };
            windows.push(running);
        }

        Ok(Self {
            active_window_id,
            default_size: size,
            windows,
        })
    }

    pub fn handle_agent_ipc_request(
        &mut self,
        request: AgentIpcRequest,
    ) -> Result<Option<AgentIpcResponse>, AppRuntimeError> {
        if request.version != 1 {
            return Ok(agent_ipc_error_response_if_expected(
                &request,
                "invalid_message",
                "Invalid IPC protocol version.",
            ));
        }

        if request.kind == AgentIpcRequestKind::Pane {
            let (window_index, target) = match self.authenticated_pane_ipc_target(&request) {
                Ok(target) => target,
                Err(error) => {
                    return Ok(agent_ipc_error_response_if_expected(
                        &request,
                        error.code,
                        &error.message,
                    ));
                }
            };

            if request.subcommand.as_deref() == Some("grid") {
                match pane_ipc_grid_options(&request.arguments) {
                    Ok(options) if options.destination == PaneIpcGridDestination::NewWindow => {
                        return match self.spawn_grid_window_from_source(
                            window_index,
                            &target,
                            &options,
                        ) {
                            Ok(()) => Ok(agent_ipc_success_response_if_expected(&request)),
                            Err(error) => Ok(agent_ipc_error_response_if_expected(
                                &request,
                                error.code,
                                &error.message,
                            )),
                        };
                    }
                    Ok(_) => {}
                    Err(error) => {
                        return Ok(agent_ipc_error_response_if_expected(
                            &request,
                            error.code,
                            &error.message,
                        ));
                    }
                }
            }

            return self.windows[window_index].handle_agent_ipc_request(request);
        }

        let Some(active) = self.active_window_mut() else {
            return Ok(agent_ipc_error_response_if_expected(
                &request,
                "pane_not_found",
                "Target pane was not found.",
            ));
        };
        active.handle_agent_ipc_request(request)
    }

    pub fn active_window_id(&self) -> Option<&str> {
        self.active_window_id.as_deref()
    }

    pub fn window_ids(&self) -> Vec<&str> {
        self.windows
            .iter()
            .filter_map(|window| window.window_id())
            .collect()
    }

    pub fn focused_pane_id(&self) -> Option<&str> {
        self.active_window().and_then(RunningApp::focused_pane_id)
    }

    pub fn active_pane_ids(&self) -> Vec<&str> {
        self.active_window()
            .map(RunningApp::pane_ids)
            .unwrap_or_default()
    }

    pub fn resolve_command_palette(&self, search_text: &str) -> CommandPaletteResolvedResults {
        self.active_window()
            .map(|window| window.resolve_command_palette(search_text))
            .unwrap_or_else(|| {
                CommandPaletteResultsResolver::resolve(
                    search_text,
                    Vec::new(),
                    Vec::new(),
                    Vec::new(),
                    None,
                    Vec::new(),
                )
            })
    }

    pub fn command_palette_items(&self) -> Vec<CommandPaletteItem> {
        self.active_window()
            .map(RunningApp::command_palette_items)
            .unwrap_or_default()
    }

    pub fn task_manager_pane_sources(&self) -> Vec<TaskManagerPaneSource> {
        self.windows
            .iter()
            .enumerate()
            .flat_map(|(index, window)| {
                let window_title = format!("Window {}", index + 1);
                window.task_manager_pane_sources_with_window_title(window_title)
            })
            .collect()
    }

    pub fn active_window_mut(&mut self) -> Option<&mut RunningApp> {
        let active_window_id = self.active_window_id.as_deref()?;
        self.windows
            .iter_mut()
            .find(|window| window.window_id() == Some(active_window_id))
    }

    pub fn take_window(&mut self, window_id: &str) -> Option<RunningApp> {
        let index = self
            .windows
            .iter()
            .position(|window| window.window_id() == Some(window_id))?;
        Some(self.windows.remove(index))
    }

    pub fn take_active_focused_pane(&mut self) -> Option<RunningPane> {
        let active = self.active_window_mut()?;
        let pane_id = active.focused_pane_id()?.to_string();
        active.take_pane(&pane_id)
    }

    pub fn terminate_all_panes(&mut self) -> Result<(), AppRuntimeError> {
        let window_ids = self
            .window_ids()
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        for window_id in window_ids {
            if let Some(mut window) = self.take_window(&window_id) {
                window.terminate_all_panes()?;
            }
        }
        self.active_window_id = None;
        Ok(())
    }

    pub fn write_to_focused(&mut self, bytes: &[u8]) -> Result<(), AppRuntimeError> {
        self.active_window_mut()
            .ok_or(AppRuntimeError::NoFocusedPane)?
            .write_to_focused(bytes)
    }

    pub fn write_to_pane(&mut self, pane_id: &str, bytes: &[u8]) -> Result<(), AppRuntimeError> {
        self.window_containing_pane_mut(pane_id)
            .ok_or_else(|| AppRuntimeError::PaneNotFound(pane_id.to_string()))?
            .write_to_pane(pane_id, bytes)
    }

    pub fn paste_to_focused(
        &mut self,
        paste: &TerminalClipboardPaste,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        self.active_window_mut()
            .ok_or(AppRuntimeError::NoFocusedPane)?
            .paste_to_focused(paste, mode)
    }

    pub fn submit_command_to_focused(
        &mut self,
        command: &str,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        self.active_window_mut()
            .ok_or(AppRuntimeError::NoFocusedPane)?
            .submit_command_to_focused(command, mode)
    }

    pub fn resize_focused(&mut self, size: TerminalSize) -> Result<(), AppRuntimeError> {
        self.active_window_mut()
            .ok_or(AppRuntimeError::NoFocusedPane)?
            .resize_focused(size)
    }

    pub fn resize_pane(
        &mut self,
        pane_id: &str,
        size: TerminalSize,
    ) -> Result<(), AppRuntimeError> {
        self.window_containing_pane_mut(pane_id)
            .ok_or_else(|| AppRuntimeError::PaneNotFound(pane_id.to_string()))?
            .resize_pane(pane_id, size)
    }

    pub fn execute_command(
        &mut self,
        command_id: AppCommandId,
    ) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        match command_id {
            AppCommandId::NewWindow => self.create_new_window(),
            AppCommandId::CloseWindow => self.close_active_window(),
            AppCommandId::MovePaneToNewWindow => Ok(self.move_focused_pane_to_new_window()),
            _ => self
                .active_window_mut()
                .map(|window| window.execute_command(command_id))
                .unwrap_or(Ok(AppCommandExecutionResult::Unavailable)),
        }
    }

    pub fn execute_palette_item(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let result = match self.active_window_mut() {
            Some(window) => window.execute_palette_item(item_id)?,
            None => CommandPaletteItemExecutionResult::Unavailable,
        };
        self.apply_palette_handoff(result)
    }

    pub fn execute_palette_item_with_shell_state(
        &mut self,
        item_id: &CommandPaletteItemId,
        shell_activity_state: TaskRunnerShellActivityState,
        terminal_progress_indicates_activity: bool,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let result = match self.active_window_mut() {
            Some(window) => window.execute_palette_item_with_shell_state(
                item_id,
                shell_activity_state,
                terminal_progress_indicates_activity,
            )?,
            None => CommandPaletteItemExecutionResult::Unavailable,
        };
        self.apply_palette_handoff(result)
    }

    fn apply_palette_handoff(
        &mut self,
        result: CommandPaletteItemExecutionResult,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        Ok(match result {
            CommandPaletteItemExecutionResult::RequestCloseWindow { .. } => {
                self.close_active_window()?.into()
            }
            CommandPaletteItemExecutionResult::RequestNewWindow { working_directory } => self
                .create_new_window_with_working_directory(working_directory)?
                .into(),
            CommandPaletteItemExecutionResult::RequestMovePaneToNewWindow { .. } => {
                self.move_focused_pane_to_new_window().into()
            }
            other => other,
        })
    }

    fn move_focused_pane_to_new_window(&mut self) -> AppCommandExecutionResult {
        let Some(source_index) = self.active_window_index() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let destination_window_id = self.next_window_id();
        let Some(mut destination_window) =
            self.windows[source_index].detach_focused_pane_to_new_window()
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        destination_window.set_window_id(destination_window_id.clone());
        self.windows.push(destination_window);
        self.active_window_id = Some(destination_window_id);
        AppCommandExecutionResult::Applied
    }

    fn create_new_window(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let focused_cwd = self
            .active_window()
            .and_then(RunningApp::focused_pane_path)
            .map(ToOwned::to_owned);
        self.create_new_window_with_working_directory(focused_cwd)
    }

    fn create_new_window_with_working_directory(
        &mut self,
        working_directory: Option<String>,
    ) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let window_id = self.next_window_id();
        let worklane_id = self.next_worklane_id();
        let pane_id = self.next_pane_id();

        let mut pane = base_new_pane(&pane_id, 0, 0);
        pane.worklane_id = worklane_id.clone();
        pane.column_id = format!("column-{pane_id}");
        pane.title = "pane 1".to_string();
        pane.column_width = DEFAULT_COLUMN_WIDTH;
        pane.terminal_request.working_directory = working_directory;

        let window = WindowLaunchPlan {
            window_id: window_id.clone(),
            active_worklane_id: Some(worklane_id.clone()),
            worklanes: vec![WorklaneLaunchPlan {
                worklane_id,
                title: None,
                panes: vec![pane],
                focused_pane_id: Some(pane_id),
            }],
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
        };
        let running = RunningApp::spawn(
            AppLaunchPlan {
                active_window_id: Some(window_id.clone()),
                windows: vec![window],
            },
            self.default_size,
        )
        .map_err(|error| match error {
            AppLaunchError::PaneSpawn { source, .. } => AppRuntimeError::Pty(source),
        })?;

        self.windows.push(running);
        self.active_window_id = Some(window_id);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn close_active_window(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        if self.windows.len() <= 1 {
            return Ok(AppCommandExecutionResult::Unavailable);
        }
        let Some(active_index) = self.active_window_index() else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let mut removed = self.windows.remove(active_index);
        removed.terminate_all_panes()?;

        let fallback_index = active_index
            .saturating_sub(1)
            .min(self.windows.len().saturating_sub(1));
        self.active_window_id = self
            .windows
            .get(fallback_index)
            .and_then(|window| window.window_id().map(ToOwned::to_owned));
        Ok(AppCommandExecutionResult::Applied)
    }

    fn active_window(&self) -> Option<&RunningApp> {
        let active_window_id = self.active_window_id.as_deref()?;
        self.windows
            .iter()
            .find(|window| window.window_id() == Some(active_window_id))
    }

    fn window_containing_pane_mut(&mut self, pane_id: &str) -> Option<&mut RunningApp> {
        self.windows
            .iter_mut()
            .find(|window| window.pane_ids().into_iter().any(|id| id == pane_id))
    }

    fn active_window_index(&self) -> Option<usize> {
        let active_window_id = self.active_window_id.as_deref()?;
        self.windows
            .iter()
            .position(|window| window.window_id() == Some(active_window_id))
    }

    fn authenticated_pane_ipc_target(
        &self,
        request: &AgentIpcRequest,
    ) -> Result<(usize, AgentIpcPaneTarget), AgentIpcRequestRejection> {
        let mut deferred_error = None;
        for (index, window) in self.windows.iter().enumerate() {
            match window.authenticated_pane_ipc_target(request) {
                Ok(target) => return Ok((index, target)),
                Err(error) if agent_ipc_error_is_routable(&error) => {
                    if deferred_error.is_none() {
                        deferred_error = Some(error);
                    }
                }
                Err(error) => return Err(error),
            }
        }

        Err(deferred_error.unwrap_or_else(agent_ipc_pane_not_found_rejection))
    }

    fn spawn_grid_window_from_source(
        &mut self,
        source_window_index: usize,
        target: &AgentIpcPaneTarget,
        options: &PaneIpcGridOptions,
    ) -> Result<(), AgentIpcRequestRejection> {
        let source = self.windows[source_window_index]
            .panes
            .iter()
            .find(|pane| {
                pane.spec.worklane_id == target.worklane_id && pane.spec.pane_id == target.pane_id
            })
            .map(|pane| pane.spec.clone())
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let source_window = &self.windows[source_window_index];
        let source_environment = source_window.agent_ipc_environment.clone();
        let theme_mode = source_window.theme_mode;
        let task_runner_actions = source_window.task_runner_actions.clone();

        let window_id = self.next_window_id();
        let worklane_id = self.next_worklane_id();
        let pane_id = self.next_pane_id();
        let mut terminal_request = TerminalSessionRequest::default();
        terminal_request.working_directory = source.terminal_request.working_directory.clone();
        terminal_request.environment_variables = source.terminal_request.environment_variables;
        let spec = PaneLaunchSpec {
            pane_id: pane_id.clone(),
            worklane_id: worklane_id.clone(),
            column_id: format!("column-{pane_id}"),
            column_index: 0,
            pane_index: 0,
            title: "pane 1".to_string(),
            column_width: DEFAULT_COLUMN_WIDTH,
            pane_height: Some(MIN_LAYOUT_WEIGHT),
            terminal_request,
            restored_rerunnable_command: None,
            status_text: None,
            applied_restore_draft_tool: None,
        };
        let mut focused_pane_id_by_worklane_id = BTreeMap::new();
        focused_pane_id_by_worklane_id.insert(worklane_id.clone(), pane_id.clone());
        let mut window = RunningApp {
            window_id: Some(window_id.clone()),
            default_size: self.default_size,
            active_worklane_id: Some(worklane_id.clone()),
            worklane_order: vec![worklane_id],
            focused_pane_id_by_worklane_id,
            focus_history: PaneFocusHistory::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions,
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklane_titles_by_id: BTreeMap::new(),
            pane_notifications: Vec::new(),
            theme_mode,
            closed_pane_specs: Vec::new(),
            panes: Vec::new(),
            focused_pane_id: Some(pane_id.clone()),
            agent_ipc_environment: source_environment,
        };
        let session = window.spawn_running_pane(&spec).map_err(|error| {
            AgentIpcRequestRejection::new("grid_window_spawn_failed", error.to_string())
        })?;
        window.panes.push(RunningPane {
            spec,
            session,
            shell_activity_state: TaskRunnerShellActivityState::Unknown,
            root_pid: None,
        });
        window.apply_grid_to_running_source(
            &pane_id,
            options.rows,
            options.columns,
            options.command.as_deref(),
            options.include_source,
            options.focus,
        )?;
        if options.include_source
            && let Some(command) = options.command.as_deref() {
                window
                    .submit_command_to_pane(&pane_id, command, TerminalPasteMode::Plain)
                    .map_err(|error| {
                        AgentIpcRequestRejection::new(
                            "grid_command_submission_failed",
                            format!("{error:?}"),
                        )
                    })?;
            }

        self.windows.push(window);
        self.active_window_id = Some(window_id);
        Ok(())
    }

    fn next_window_id(&self) -> String {
        let mut index = self.windows.len() + 1;
        loop {
            let candidate = format!("window-{index}");
            if !self
                .windows
                .iter()
                .any(|window| window.window_id() == Some(candidate.as_str()))
            {
                return candidate;
            }
            index += 1;
        }
    }

    fn next_worklane_id(&self) -> String {
        let mut index = self
            .windows
            .iter()
            .map(|window| window.worklane_order.len())
            .sum::<usize>()
            + 1;
        loop {
            let candidate = format!("worklane-{index}");
            if !self
                .windows
                .iter()
                .any(|window| window.has_worklane_id(&candidate))
            {
                return candidate;
            }
            index += 1;
        }
    }

    fn next_pane_id(&self) -> String {
        let mut index = self
            .windows
            .iter()
            .flat_map(|window| window.panes.iter())
            .filter_map(|pane| pane_id_numeric_suffix(&pane.spec.pane_id))
            .max()
            .unwrap_or_else(|| {
                self.windows
                    .iter()
                    .map(|window| window.panes.len())
                    .sum::<usize>()
            })
            + 1;
        loop {
            let candidate = format!("pane-{index}");
            if !self
                .windows
                .iter()
                .flat_map(|window| &window.panes)
                .any(|pane| pane.spec.pane_id == candidate)
            {
                return candidate;
            }
            index += 1;
        }
    }
}

impl RunningApp {
    pub fn spawn(plan: AppLaunchPlan, size: TerminalSize) -> Result<Self, AppLaunchError> {
        Self::spawn_internal(plan, size, None)
    }

    pub fn spawn_with_agent_ipc(
        plan: AppLaunchPlan,
        size: TerminalSize,
        agent_ipc_environment: AgentIpcRuntimeEnvironment,
    ) -> Result<Self, AppLaunchError> {
        Self::spawn_internal(plan, size, Some(agent_ipc_environment))
    }

    fn spawn_internal(
        plan: AppLaunchPlan,
        size: TerminalSize,
        agent_ipc_environment: Option<AgentIpcRuntimeEnvironment>,
    ) -> Result<Self, AppLaunchError> {
        let window_id = plan
            .active_window_id
            .clone()
            .or_else(|| plan.windows.first().map(|window| window.window_id.clone()));
        let active_window = plan.active_window();
        let active_worklane_id = active_window
            .and_then(|window| window.active_worklane_id.clone())
            .or_else(|| {
                active_window
                    .and_then(|window| window.worklanes.first())
                    .map(|worklane| worklane.worklane_id.clone())
            });
        let worklane_order = active_window
            .map(|window| {
                window
                    .worklanes
                    .iter()
                    .map(|worklane| worklane.worklane_id.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let focused_pane_id_by_worklane_id = active_window
            .map(|window| {
                window
                    .worklanes
                    .iter()
                    .filter_map(|worklane| {
                        worklane
                            .focused_pane_id
                            .as_ref()
                            .map(|pane_id| (worklane.worklane_id.clone(), pane_id.clone()))
                    })
                    .collect::<BTreeMap<_, _>>()
            })
            .unwrap_or_default();
        let focus_history = active_window
            .map(|window| window.focus_history.clone())
            .unwrap_or_default();
        let open_with_targets = active_window
            .map(|window| window.open_with_targets.clone())
            .unwrap_or_default();
        let detected_servers = active_window
            .map(|window| window.detected_servers.clone())
            .unwrap_or_default();
        let task_runner_actions = active_window
            .map(|window| window.task_runner_actions.clone())
            .unwrap_or_default();
        let branch_urls_by_pane_id = active_window
            .map(|window| window.branch_urls_by_pane_id.clone())
            .unwrap_or_default();
        let worklane_colors_by_id = active_window
            .map(|window| window.worklane_colors_by_id.clone())
            .unwrap_or_default();
        let worklane_titles_by_id = active_window
            .map(|window| {
                window
                    .worklanes
                    .iter()
                    .filter_map(|worklane| {
                        normalized_worklane_title(worklane.title.as_deref())
                            .map(|title| (worklane.worklane_id.clone(), title))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let focused_pane_id = plan.focused_pane_id();
        let mut panes = Vec::new();
        for spec in plan.pane_specs() {
            let pane_environment = agent_ipc_environment
                .as_ref()
                .and_then(|environment| environment.pane_environment(window_id.as_deref(), spec));
            let session = spec
                .spawn_pty_with_agent_ipc(size, window_id.as_deref(), pane_environment.as_ref())
                .map_err(|source| AppLaunchError::PaneSpawn {
                    pane_id: spec.pane_id.clone(),
                    source,
                })?;
            panes.push(RunningPane {
                spec: spec.clone(),
                session,
                shell_activity_state: TaskRunnerShellActivityState::Unknown,
                root_pid: None,
            });
        }

        Ok(Self {
            window_id,
            default_size: size,
            active_worklane_id,
            worklane_order,
            focused_pane_id_by_worklane_id,
            focus_history,
            open_with_targets,
            detected_servers,
            task_runner_actions,
            branch_urls_by_pane_id,
            worklane_colors_by_id,
            worklane_titles_by_id,
            pane_notifications: Vec::new(),
            theme_mode: AppearanceThemeMode::default(),
            closed_pane_specs: Vec::new(),
            panes,
            focused_pane_id,
            agent_ipc_environment,
        })
    }

    pub fn pane_ids(&self) -> Vec<&str> {
        self.panes
            .iter()
            .map(|pane| pane.spec.pane_id.as_str())
            .collect()
    }

    pub fn focused_pane_id(&self) -> Option<&str> {
        self.focused_pane_id.as_deref()
    }

    pub fn active_worklane_color(&self) -> Option<&str> {
        self.active_worklane_id
            .as_ref()
            .and_then(|worklane_id| self.worklane_colors_by_id.get(worklane_id))
            .map(String::as_str)
    }

    pub fn active_worklane_title(&self) -> Option<&str> {
        self.active_worklane_id
            .as_ref()
            .and_then(|worklane_id| self.worklane_titles_by_id.get(worklane_id))
            .map(String::as_str)
    }

    pub fn worklane_title(&self, worklane_id: &str) -> Option<&str> {
        self.worklane_titles_by_id
            .get(worklane_id)
            .map(String::as_str)
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

    fn jump_to_latest_pane_notification(&mut self) -> AppCommandExecutionResult {
        let target = self
            .pane_notifications
            .iter()
            .filter(|notification| notification.include_inbox)
            .find_map(|notification| {
                self.panes
                    .iter()
                    .any(|pane| {
                        pane.spec.worklane_id == notification.worklane_id
                            && pane.spec.pane_id == notification.pane_id
                    })
                    .then(|| {
                        PaneReference::new(
                            notification.worklane_id.clone(),
                            PaneId::from(notification.pane_id.clone()),
                        )
                    })
            });
        target
            .map(|reference| self.focus_pane_reference(reference, true, true))
            .unwrap_or(AppCommandExecutionResult::JumpToLatestNotification)
    }

    pub fn window_id(&self) -> Option<&str> {
        self.window_id.as_deref()
    }

    pub fn resolve_command_palette(&self, search_text: &str) -> CommandPaletteResolvedResults {
        self.running_window_snapshot()
            .resolve_command_palette(search_text)
    }

    pub fn command_palette_items(&self) -> Vec<CommandPaletteItem> {
        self.running_window_snapshot().command_palette_items()
    }

    pub fn task_manager_pane_sources(&self) -> Vec<TaskManagerPaneSource> {
        self.task_manager_pane_sources_with_window_title("Window 1".to_string())
    }

    fn task_manager_pane_sources_with_window_title(
        &self,
        window_title: String,
    ) -> Vec<TaskManagerPaneSource> {
        let window_id = self
            .window_id
            .clone()
            .unwrap_or_else(|| "window-main".to_string());
        self.running_worklane_ids()
            .into_iter()
            .enumerate()
            .flat_map(|(worklane_index, worklane_id)| {
                let worklane_title = self
                    .worklane_titles_by_id
                    .get(&worklane_id)
                    .cloned()
                    .unwrap_or_else(|| format!("Worklane {}", worklane_index + 1));
                self.panes
                    .iter()
                    .filter(move |pane| pane.spec.worklane_id == worklane_id)
                    .map({
                        let window_id = window_id.clone();
                        let window_title = window_title.clone();
                        move |pane| TaskManagerPaneSource {
                            window_id: window_id.clone(),
                            window_title: window_title.clone(),
                            worklane_id: pane.spec.worklane_id.clone(),
                            worklane_title: worklane_title.clone(),
                            pane_id: pane.spec.pane_id.clone(),
                            pane_title: trimmed_non_empty(&pane.spec.title)
                                .unwrap_or(pane.spec.pane_id.as_str())
                                .to_string(),
                            status_text: pane
                                .spec
                                .status_text
                                .clone()
                                .or_else(|| task_manager_status_text(pane.shell_activity_state)),
                            root_pid: pane.root_pid,
                            is_remote: false,
                            current_working_directory: pane
                                .spec
                                .terminal_request
                                .working_directory
                                .clone(),
                        }
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    pub fn execute_command(
        &mut self,
        command_id: AppCommandId,
    ) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        Ok(match command_id {
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
            AppCommandId::OpenWithSelectedApp => self.open_with_primary_target(),
            AppCommandId::OpenSelectedServer => self.open_primary_server(),
            AppCommandId::OpenBranchOnRemote => self.open_focused_branch_url(),
            AppCommandId::RenameCurrentWorklane => self.rename_active_worklane(),
            AppCommandId::JumpToLatestNotification => self.jump_to_latest_pane_notification(),
            AppCommandId::ToggleSidebar => AppCommandExecutionResult::ToggleSidebar,
            AppCommandId::ShowCommandPalette => AppCommandExecutionResult::ShowCommandPalette,
            AppCommandId::ShowTaskManager => AppCommandExecutionResult::ShowTaskManager,
            AppCommandId::OpenSettings => {
                AppCommandExecutionResult::ShowSettings { section: "general" }
            }
            AppCommandId::ReloadConfig => AppCommandExecutionResult::ReloadConfiguration,
            AppCommandId::OpenBookmarksPopover => AppCommandExecutionResult::OpenBookmarksPopover,
            AppCommandId::CloseWindow => self.request_close_window(),
            AppCommandId::NewWindow => self.request_new_window(),
            AppCommandId::MovePaneToNewWindow => self.request_move_pane_to_new_window(),
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
            AppCommandId::FocusLeftPane => self.move_focus_horizontally(-1),
            AppCommandId::FocusRightPane => self.move_focus_horizontally(1),
            AppCommandId::FocusUpInColumn => self.move_focus_vertically(-1),
            AppCommandId::FocusDownInColumn => self.move_focus_vertically(1),
            AppCommandId::FocusPreviousPane => self.move_focus_by_running_order(-1),
            AppCommandId::FocusNextPane => self.move_focus_by_running_order(1),
            AppCommandId::NavigateBack => self.navigate_focus_history(true),
            AppCommandId::NavigateForward => self.navigate_focus_history(false),
            AppCommandId::CloseFocusedPane => return self.close_focused_pane(),
            AppCommandId::RestoreClosedPane => return self.restore_closed_pane(),
            AppCommandId::SplitHorizontally
            | AppCommandId::ForceSplitRight
            | AppCommandId::ForceAddPaneRight => return self.split_focused_pane_right(),
            AppCommandId::SplitVertically => return self.split_focused_pane_below(),
            AppCommandId::DuplicateFocusedPane => return self.duplicate_focused_pane(),
            AppCommandId::NewWorklane => return self.create_new_worklane(),
            AppCommandId::NextWorklane => self.cycle_worklane(1),
            AppCommandId::PreviousWorklane => self.cycle_worklane(-1),
            AppCommandId::WorklaneMoveUp => self.move_active_worklane_by(-1),
            AppCommandId::WorklaneMoveDown => self.move_active_worklane_by(1),
        })
    }

    pub fn execute_palette_item(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        Ok(match item_id {
            CommandPaletteItemId::Command(command_id) => {
                match AppCommandId::from_raw_value(command_id) {
                    Some(command_id) => self.execute_command(command_id)?.into(),
                    None => CommandPaletteItemExecutionResult::Unsupported,
                }
            }
            CommandPaletteItemId::Pane {
                worklane_id,
                pane_id,
            } => self.focus_pane_item(worklane_id, pane_id),
            CommandPaletteItemId::RestoredCommand { pane_id } => self
                .restored_command_for_pane(pane_id)
                .map(
                    |command| CommandPaletteItemExecutionResult::RunRestoredCommand {
                        pane_id: pane_id.clone(),
                        command,
                    },
                )
                .unwrap_or(CommandPaletteItemExecutionResult::Unavailable),
            CommandPaletteItemId::OpenWith { stable_id } => self.open_with_target(stable_id).into(),
            CommandPaletteItemId::Server { id } => self.open_server(id).into(),
            CommandPaletteItemId::TaskRunner(_) => CommandPaletteItemExecutionResult::Unavailable,
            CommandPaletteItemId::WorklaneColor(color) => self.set_active_worklane_color(color),
            CommandPaletteItemId::Settings(section) => {
                CommandPaletteItemExecutionResult::ShowSettings {
                    section: section.clone(),
                }
            }
        })
    }

    pub fn execute_palette_item_with_shell_state(
        &mut self,
        item_id: &CommandPaletteItemId,
        shell_activity_state: TaskRunnerShellActivityState,
        terminal_progress_indicates_activity: bool,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let CommandPaletteItemId::TaskRunner(id) = item_id else {
            return self.execute_palette_item(item_id);
        };
        let Some(action) = self
            .task_runner_actions
            .iter()
            .find(|action| action.id == *id)
            .cloned()
        else {
            return Ok(CommandPaletteItemExecutionResult::Unavailable);
        };
        self.run_task_runner(
            &action,
            shell_activity_state,
            terminal_progress_indicates_activity,
        )
    }

    pub fn execute_palette_item_with_recorded_shell_state(
        &mut self,
        item_id: &CommandPaletteItemId,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let CommandPaletteItemId::TaskRunner(id) = item_id else {
            return self.execute_palette_item(item_id);
        };
        let Some(action) = self
            .task_runner_actions
            .iter()
            .find(|action| action.id == *id)
            .cloned()
        else {
            return Ok(CommandPaletteItemExecutionResult::Unavailable);
        };
        let focused_pane = self.focused_recorded_task_runner_pane_state();
        self.run_task_runner_action(&action, focused_pane.as_ref())
    }

    pub fn apply_agent_signal(&mut self, payload: &AgentSignalPayload) -> bool {
        if payload.window_id.as_deref().is_some_and(|window_id| {
            self.window_id
                .as_deref()
                .is_some_and(|own_id| own_id != window_id)
        }) {
            return false;
        }
        let Some(pane) = self.panes.iter_mut().find(|pane| {
            pane.spec.worklane_id == payload.worklane_id && pane.spec.pane_id == payload.pane_id
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
    ) -> Result<Option<AgentIpcResponse>, AppRuntimeError> {
        if request.version != 1 {
            return Ok(agent_ipc_error_response_if_expected(
                &request,
                "invalid_message",
                "Invalid IPC protocol version.",
            ));
        }

        if request.kind == AgentIpcRequestKind::Pane {
            return self.handle_pane_ipc_request(request);
        }

        let payload = match agent_signal_payload_for_authenticated_ipc_request(
            &request,
            self.agent_ipc_environment.as_ref(),
        ) {
            Ok(payload) => payload,
            Err(error) => {
                return Ok(agent_ipc_error_response_if_expected(
                    &request,
                    error.code,
                    &error.message,
                ));
            }
        };

        if !self.apply_agent_signal(&payload) {
            return Ok(agent_ipc_error_response_if_expected(
                &request,
                "pane_not_found",
                "Target pane was not found.",
            ));
        }

        Ok(agent_ipc_success_response_if_expected(&request))
    }

    fn handle_pane_ipc_request(
        &mut self,
        request: AgentIpcRequest,
    ) -> Result<Option<AgentIpcResponse>, AppRuntimeError> {
        let Some(subcommand) = request.subcommand.as_deref() else {
            return Ok(agent_ipc_error_response_if_expected(
                &request,
                "unsupported_subcommand",
                "Unsupported pane IPC subcommand: <nil>",
            ));
        };

        let target = match self.authenticated_pane_ipc_target(&request) {
            Ok(target) => target,
            Err(error) => {
                return Ok(agent_ipc_error_response_if_expected(
                    &request,
                    error.code,
                    &error.message,
                ));
            }
        };

        match subcommand {
            "split" => {
                self.apply_pane_split_ipc_command(&target, &request.arguments)?;
                Ok(agent_ipc_success_response_if_expected(&request))
            }
            "list" => Ok(agent_ipc_pane_list_success_response_if_expected(
                &request,
                self.pane_list_entries_for_worklane(&target.worklane_id),
            )),
            "focus" => {
                self.apply_pane_focus_ipc_command(&target, &request.arguments);
                Ok(agent_ipc_success_response_if_expected(&request))
            }
            "close" => {
                self.apply_pane_close_ipc_command(&target, &request.arguments)?;
                Ok(agent_ipc_success_response_if_expected(&request))
            }
            "resize" => {
                self.apply_pane_resize_ipc_command(&target, &request.arguments);
                Ok(agent_ipc_success_response_if_expected(&request))
            }
            "layout" => {
                self.apply_pane_layout_ipc_command(&target, &request.arguments);
                Ok(agent_ipc_success_response_if_expected(&request))
            }
            "grid" => match self.apply_pane_grid_ipc_command(&target, &request.arguments) {
                Ok(()) => Ok(agent_ipc_success_response_if_expected(&request)),
                Err(error) => Ok(agent_ipc_error_response_if_expected(
                    &request,
                    error.code,
                    &error.message,
                )),
            },
            "notify" => match self.apply_pane_notify_ipc_command(&target, &request.arguments) {
                Ok(()) => Ok(agent_ipc_success_response_if_expected(&request)),
                Err(error) => Ok(agent_ipc_error_response_if_expected(
                    &request,
                    error.code,
                    &error.message,
                )),
            },
            "worklane-color" => {
                match self.apply_pane_worklane_color_ipc_command(&target, &request.arguments) {
                    Ok(()) => Ok(agent_ipc_success_response_if_expected(&request)),
                    Err(error) => Ok(agent_ipc_error_response_if_expected(
                        &request,
                        error.code,
                        &error.message,
                    )),
                }
            }
            "worklane-rename" => {
                match self.apply_pane_worklane_rename_ipc_command(&target, &request.arguments) {
                    Ok(()) => Ok(agent_ipc_success_response_if_expected(&request)),
                    Err(error) => Ok(agent_ipc_error_response_if_expected(
                        &request,
                        error.code,
                        &error.message,
                    )),
                }
            }
            "theme" => match self.apply_pane_theme_ipc_command(&request.arguments) {
                Ok(mode) => Ok(agent_ipc_stdout_success_response_if_expected(
                    &request,
                    format!("{}\n", pane_ipc_theme_mode_token(mode)),
                )),
                Err(error) => Ok(agent_ipc_error_response_if_expected(
                    &request,
                    error.code,
                    &error.message,
                )),
            },
            _ => Ok(agent_ipc_error_response_if_expected(
                &request,
                "unsupported_subcommand",
                &format!("Unsupported pane IPC subcommand: {subcommand}"),
            )),
        }
    }

    fn authenticated_pane_ipc_target(
        &self,
        request: &AgentIpcRequest,
    ) -> Result<AgentIpcPaneTarget, AgentIpcRequestRejection> {
        let selectors = parse_agent_ipc_pane_selectors(&request.arguments)?;
        let target = self.resolve_pane_ipc_target(&selectors, &request.environment)?;
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
            return resolve_single_agent_ipc_pane_candidate(matches);
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
                    pane.spec.worklane_id == worklane_id && self.agent_ipc_window_matches(window_id)
                })
                .nth(pane_index - 1)
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: self.window_id.clone(),
                worklane_id: pane.spec.worklane_id.clone(),
                pane_id: pane.spec.pane_id.clone(),
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
                    self.panes.iter().any(|pane| {
                        pane.spec.worklane_id == worklane_id && pane.spec.pane_id == **pane_id
                    })
                })
                .cloned()
                .or_else(|| {
                    self.panes
                        .iter()
                        .find(|pane| pane.spec.worklane_id == worklane_id)
                        .map(|pane| pane.spec.pane_id.clone())
                })
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: self.window_id.clone(),
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
            let worklane_id = self
                .active_worklane_id
                .clone()
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            return Ok(AgentIpcPaneTarget {
                window_id: self.window_id.clone(),
                worklane_id,
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
                    return resolve_single_agent_ipc_pane_candidate(retargeted_matches);
                }
            }
            return resolve_single_agent_ipc_pane_candidate(matches);
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
            .filter(|pane| worklane_id.is_none_or(|id| pane.spec.worklane_id == id))
            .filter(|pane| pane_id.is_none_or(|id| pane.spec.pane_id == id))
            .map(|pane| AgentIpcPaneTarget {
                window_id: self.window_id.clone(),
                worklane_id: pane.spec.worklane_id.clone(),
                pane_id: pane.spec.pane_id.clone(),
            })
            .collect()
    }

    fn agent_ipc_window_matches(&self, window_id: Option<&str>) -> bool {
        window_id.is_none_or(|window_id| self.window_id.as_deref() == Some(window_id))
    }

    fn pane_list_entries_for_worklane(&self, worklane_id: &str) -> Vec<PaneListEntry> {
        self.panes
            .iter()
            .filter(|pane| pane.spec.worklane_id == worklane_id)
            .enumerate()
            .map(|(index, pane)| PaneListEntry {
                index: (index + 1) as i32,
                id: pane.spec.pane_id.clone(),
                column: (pane.spec.column_index + 1) as i32,
                title: pane.spec.title.clone(),
                working_directory: pane.spec.terminal_request.working_directory.clone(),
                is_focused: self
                    .focused_pane_id_by_worklane_id
                    .get(worklane_id)
                    .is_some_and(|focused| focused == &pane.spec.pane_id),
                agent_tool: None,
                agent_status: None,
            })
            .collect()
    }

    fn apply_pane_split_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<(), AppRuntimeError> {
        let _ = self.focus_agent_ipc_target(target);
        let Some(direction) = PaneIpcSplitDirection::parse(arguments) else {
            return Ok(());
        };

        let result = match direction {
            PaneIpcSplitDirection::Right => self.split_focused_pane_right()?,
            PaneIpcSplitDirection::Left => self.split_focused_pane_left()?,
            PaneIpcSplitDirection::Down => self.split_focused_pane_below()?,
            PaneIpcSplitDirection::Up => self.split_focused_pane_above()?,
        };
        if result == AppCommandExecutionResult::Applied {
            self.apply_pane_split_layout_ipc_command(direction, arguments);
        }
        Ok(())
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
                let _ = self.equalize_focused_running_column_heights();
            }
            PaneIpcSplitLayout::Golden if direction.is_horizontal() => {
                let _ = self.apply_layout_command(AppCommandId::ArrangeWidthGoldenFocusWide);
            }
            PaneIpcSplitLayout::Golden => {
                let _ = self.apply_layout_command(AppCommandId::ArrangeHeightGoldenFocusTall);
            }
            PaneIpcSplitLayout::Ratio(fraction) if direction.is_horizontal() => {
                let _ = self.resize_focused_running_column_to_fraction(fraction);
            }
            PaneIpcSplitLayout::Ratio(fraction) => {
                let _ = self.resize_focused_running_pane_height_to_fraction(fraction);
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

    fn apply_pane_close_ipc_command(
        &mut self,
        target: &AgentIpcPaneTarget,
        arguments: &[String],
    ) -> Result<(), AppRuntimeError> {
        let close_target = arguments
            .first()
            .and_then(|argument| self.resolve_pane_ipc_argument(argument, &target.worklane_id))
            .unwrap_or_else(|| target.pane_id.clone());
        let _ = self.focus_agent_ipc_target(&AgentIpcPaneTarget {
            window_id: target.window_id.clone(),
            worklane_id: target.worklane_id.clone(),
            pane_id: close_target,
        });
        let _ = self.close_focused_pane()?;
        Ok(())
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
            let _ = self.resize_focused_running_column_to_fraction(fraction);
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
    ) -> Result<(), AgentIpcRequestRejection> {
        let options = pane_ipc_grid_options(arguments)?;
        if options.destination == PaneIpcGridDestination::NewWindow {
            return Err(AgentIpcRequestRejection::new(
                "unsupported_grid_destination",
                "Grid --new-window is not supported by this IPC handler.",
            ));
        }

        let _ = self.focus_agent_ipc_target(target);
        let source_pane_id = match options.destination {
            PaneIpcGridDestination::Current => target.pane_id.clone(),
            PaneIpcGridDestination::NewWorklane => self.create_running_grid_worklane_source()?,
            PaneIpcGridDestination::NewWindow => unreachable!(),
        };
        let apply_command_to_source_spec =
            options.destination == PaneIpcGridDestination::NewWorklane && options.include_source;
        let source_pane_id = self.apply_grid_to_running_source(
            &source_pane_id,
            options.rows,
            options.columns,
            options.command.as_deref(),
            apply_command_to_source_spec,
            options.focus,
        )?;
        if options.include_source
            && let Some(command) = options.command.as_deref() {
                self.submit_command_to_pane(&source_pane_id, command, TerminalPasteMode::Plain)
                    .map_err(|error| {
                        AgentIpcRequestRejection::new(
                            "grid_command_submission_failed",
                            format!("{error:?}"),
                        )
                    })?;
            }
        Ok(())
    }

    fn create_running_grid_worklane_source(&mut self) -> Result<String, AgentIpcRequestRejection> {
        match self.create_new_worklane() {
            Ok(AppCommandExecutionResult::Applied) => self
                .focused_pane_id
                .clone()
                .ok_or_else(agent_ipc_pane_not_found_rejection),
            Ok(_) => Err(agent_ipc_pane_not_found_rejection()),
            Err(error) => Err(AgentIpcRequestRejection::new(
                "grid_pane_spawn_failed",
                format!("{error:?}"),
            )),
        }
    }

    fn apply_grid_to_running_source(
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
            .position(|pane| pane.spec.pane_id == source_pane_id)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let source_worklane_id = self.panes[source_index].spec.worklane_id.clone();
        if self.active_worklane_id.as_deref() != Some(source_worklane_id.as_str()) {
            return Err(AgentIpcRequestRejection::new(
                "grid_source_pane_not_found",
                "Source pane is not in the active worklane.",
            ));
        }

        let worklane_pane_count = self
            .panes
            .iter()
            .filter(|pane| pane.spec.worklane_id == source_worklane_id)
            .count();
        let grid_worklane_id = if worklane_pane_count > 1 {
            self.isolate_running_grid_source(source_pane_id)?
        } else {
            source_worklane_id
        };

        let source_spec = self
            .panes
            .iter()
            .find(|pane| {
                pane.spec.worklane_id == grid_worklane_id && pane.spec.pane_id == source_pane_id
            })
            .map(|pane| pane.spec.clone())
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let mut pane_ids = vec![source_pane_id.to_string()];
        let mut reserved_pane_ids = self
            .panes
            .iter()
            .map(|pane| pane.spec.pane_id.clone())
            .collect::<HashSet<_>>();
        while pane_ids.len() < cell_count {
            let pane_id = next_running_pane_id_with_reserved(&self.panes, &reserved_pane_ids);
            reserved_pane_ids.insert(pane_id.clone());
            let mut spec = base_new_pane(&pane_id, 0, 0);
            spec.worklane_id = grid_worklane_id.clone();
            apply_runtime_terminal_inheritance(&mut spec, &source_spec);
            if let Some(command) = command {
                spec.terminal_request.command = Some(command.to_string());
            }
            let session = self.spawn_running_pane(&spec).map_err(|error| {
                AgentIpcRequestRejection::new("grid_pane_spawn_failed", error.to_string())
            })?;
            self.panes.push(RunningPane {
                spec,
                session,
                shell_activity_state: TaskRunnerShellActivityState::Unknown,
                root_pid: None,
            });
            pane_ids.push(pane_id);
        }

        self.apply_running_grid_layout(
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

    fn isolate_running_grid_source(
        &mut self,
        source_pane_id: &str,
    ) -> Result<String, AgentIpcRequestRejection> {
        let source_index = self
            .panes
            .iter()
            .position(|pane| pane.spec.pane_id == source_pane_id)
            .ok_or_else(agent_ipc_pane_not_found_rejection)?;
        let removed_spec = self.panes[source_index].spec.clone();
        let source_worklane_id = removed_spec.worklane_id.clone();
        let destination_worklane_id = self.next_running_worklane_id();
        self.mirror_running_grid_source_ipc_token(&removed_spec, &destination_worklane_id);
        let mut moved_pane = self.panes.remove(source_index);
        retarget_pane_for_split_out(&mut moved_pane.spec, &destination_worklane_id);
        self.normalize_running_after_remove(&removed_spec);
        self.ensure_running_worklane(&destination_worklane_id);
        self.focused_pane_id_by_worklane_id
            .insert(destination_worklane_id.clone(), source_pane_id.to_string());
        self.active_worklane_id = Some(destination_worklane_id.clone());
        self.focused_pane_id = Some(source_pane_id.to_string());
        self.panes.push(moved_pane);
        self.sort_running_panes();
        if !self
            .panes
            .iter()
            .any(|pane| pane.spec.worklane_id == source_worklane_id)
        {
            self.remove_empty_running_worklane(&source_worklane_id);
        }
        Ok(destination_worklane_id)
    }

    fn mirror_running_grid_source_ipc_token(
        &mut self,
        source_spec: &PaneLaunchSpec,
        destination_worklane_id: &str,
    ) {
        let window_id = self.window_id.clone();
        let pane_token = self
            .agent_ipc_environment
            .as_ref()
            .and_then(|environment| environment.pane_environment(window_id.as_deref(), source_spec))
            .map(|environment| environment.pane_token);
        if let (Some(environment), Some(pane_token)) =
            (self.agent_ipc_environment.as_mut(), pane_token)
        {
            environment.set_pane_token(
                window_id.as_deref(),
                destination_worklane_id,
                &source_spec.pane_id,
                pane_token,
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn apply_running_grid_layout(
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
            .find(|pane| pane.spec.pane_id == pane_ids[0])
            .map(|pane| pane.spec.column_id.clone())
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
                .find(|pane| pane.spec.worklane_id == worklane_id && pane.spec.pane_id == *pane_id)
                .ok_or_else(agent_ipc_pane_not_found_rejection)?;
            pane.spec.column_id = column_ids[column_index].clone();
            pane.spec.column_index = column_index;
            pane.spec.pane_index = pane_index;
            pane.spec.column_width = DEFAULT_COLUMN_WIDTH;
            pane.spec.pane_height = Some(MIN_LAYOUT_WEIGHT);
            if cell_index == 0 && include_source_command {
                pane.spec.terminal_request.command = command.map(str::to_string);
            }
        }

        self.sort_running_panes();
        let focus_pane_id = match focus {
            PaneIpcGridFocus::Source | PaneIpcGridFocus::First => pane_ids[0].clone(),
            PaneIpcGridFocus::Last => pane_ids[pane_ids.len() - 1].clone(),
        };
        let _ = self.focus_pane_reference(
            PaneReference::new(worklane_id.to_string(), PaneId::from(focus_pane_id)),
            true,
            true,
        );
        Ok(())
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
        if !self.has_running_worklane(&worklane_id) {
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
    ) -> Result<(), AgentIpcRequestRejection> {
        let options = pane_ipc_notification_options(arguments)?;
        let Some(window_id) = target.window_id.as_deref() else {
            return Err(agent_ipc_pane_not_found_rejection());
        };
        self.pane_notifications.insert(
            0,
            PaneNotification {
                title: options.title,
                subtitle: options.subtitle,
                body: options.body,
                include_inbox: options.include_inbox,
                is_silent: options.is_silent,
                window_id: window_id.to_string(),
                worklane_id: target.worklane_id.clone(),
                pane_id: target.pane_id.clone(),
            },
        );
        if self.pane_notifications.len() > 50 {
            self.pane_notifications.truncate(50);
        }
        Ok(())
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
        if !self.has_running_worklane(&worklane_id) {
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
        self.theme_mode = command.resolve(self.theme_mode);
        Ok(self.theme_mode)
    }

    fn focus_agent_ipc_target(&mut self, target: &AgentIpcPaneTarget) -> AppCommandExecutionResult {
        self.focus_pane_reference(
            PaneReference::new(
                target.worklane_id.clone(),
                PaneId::from(target.pane_id.clone()),
            ),
            true,
            true,
        )
    }

    fn resolve_pane_ipc_argument(&self, target: &str, worklane_id: &str) -> Option<String> {
        if let Some(pane) = self
            .panes
            .iter()
            .find(|pane| pane.spec.worklane_id == worklane_id && pane.spec.pane_id == target)
        {
            return Some(pane.spec.pane_id.clone());
        }
        let display_index = target.parse::<usize>().ok().filter(|index| *index > 0)?;
        self.panes
            .iter()
            .filter(|pane| pane.spec.worklane_id == worklane_id)
            .nth(display_index - 1)
            .map(|pane| pane.spec.pane_id.clone())
    }

    fn has_running_worklane(&self, worklane_id: &str) -> bool {
        self.worklane_order
            .iter()
            .any(|candidate| candidate == worklane_id)
            || self
                .panes
                .iter()
                .any(|pane| pane.spec.worklane_id == worklane_id)
    }

    pub fn run_task_runner(
        &mut self,
        action: &TaskRunnerAction,
        shell_activity_state: TaskRunnerShellActivityState,
        terminal_progress_indicates_activity: bool,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let focused_pane = self
            .focused_running_pane()
            .map(|pane| TaskRunnerFocusedPaneState {
                pane_id: pane.spec.pane_id.clone(),
                runtime_available: true,
                shell_activity_state,
                terminal_progress_indicates_activity,
            });
        self.run_task_runner_action(action, focused_pane.as_ref())
    }

    fn focused_recorded_task_runner_pane_state(&self) -> Option<TaskRunnerFocusedPaneState> {
        self.focused_running_pane()
            .map(|pane| TaskRunnerFocusedPaneState {
                pane_id: pane.spec.pane_id.clone(),
                runtime_available: true,
                shell_activity_state: pane.shell_activity_state,
                terminal_progress_indicates_activity: false,
            })
    }

    fn run_task_runner_action(
        &mut self,
        action: &TaskRunnerAction,
        focused_pane: Option<&TaskRunnerFocusedPaneState>,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        match TaskRunnerExecutionPlanner::plan(action, focused_pane) {
            TaskRunnerExecutionPlan::OpenSource { source_path } => {
                Ok(CommandPaletteItemExecutionResult::OpenTaskRunnerSource { source_path })
            }
            TaskRunnerExecutionPlan::FocusedPane { pane_id, command } => {
                self.submit_command_to_pane(&pane_id, &command, TerminalPasteMode::Plain)?;
                Ok(
                    CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
                        pane_id,
                        command,
                    },
                )
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

    pub fn write_to_focused(&mut self, bytes: &[u8]) -> Result<(), AppRuntimeError> {
        let pane_id = self
            .focused_pane_id
            .clone()
            .ok_or(AppRuntimeError::NoFocusedPane)?;
        self.write_to_pane(&pane_id, bytes)
    }

    pub fn write_to_pane(&mut self, pane_id: &str, bytes: &[u8]) -> Result<(), AppRuntimeError> {
        self.pane_mut(pane_id)?.write_all(bytes)
    }

    pub fn paste_to_focused(
        &mut self,
        paste: &TerminalClipboardPaste,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        let pane_id = self
            .focused_pane_id
            .clone()
            .ok_or(AppRuntimeError::NoFocusedPane)?;
        self.paste_to_pane(&pane_id, paste, mode)
    }

    pub fn paste_to_pane(
        &mut self,
        pane_id: &str,
        paste: &TerminalClipboardPaste,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        self.write_input_to_pane(pane_id, TerminalInputPlanner::paste_payload(paste, mode))
    }

    pub fn submit_command_to_focused(
        &mut self,
        command: &str,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        let pane_id = self
            .focused_pane_id
            .clone()
            .ok_or(AppRuntimeError::NoFocusedPane)?;
        self.submit_command_to_pane(&pane_id, command, mode)
    }

    pub fn submit_command_to_pane(
        &mut self,
        pane_id: &str,
        command: &str,
        mode: TerminalPasteMode,
    ) -> Result<(), AppRuntimeError> {
        self.write_input_to_pane(pane_id, TerminalInputPlanner::submit_command(command, mode))
    }

    fn run_task_runner_in_new_pane(
        &mut self,
        action: &TaskRunnerAction,
        command: String,
        working_directory: String,
        environment_variables: Vec<(String, String)>,
    ) -> Result<CommandPaletteItemExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(CommandPaletteItemExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_column_index = focused.column_index + 1;
        let mut new_spec = new_inherited_pane(&new_pane_id, &focused, new_column_index, 0);
        new_spec.title = action.title.clone();
        new_spec.terminal_request.command = Some(command.clone());
        new_spec.terminal_request.working_directory = trimmed_non_empty(&working_directory)
            .map(str::to_string)
            .or_else(|| focused.terminal_request.working_directory.clone());
        new_spec.terminal_request.environment_variables = environment_variables;
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index >= new_column_index
            {
                pane.spec.column_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: new_pane_id,
            command,
        })
    }

    pub fn resize_focused(&mut self, size: TerminalSize) -> Result<(), AppRuntimeError> {
        let pane_id = self
            .focused_pane_id
            .clone()
            .ok_or(AppRuntimeError::NoFocusedPane)?;
        self.resize_pane(&pane_id, size)
    }

    pub fn resize_pane(
        &mut self,
        pane_id: &str,
        size: TerminalSize,
    ) -> Result<(), AppRuntimeError> {
        self.pane_mut(pane_id)?.resize(size)
    }

    pub fn take_pane(&mut self, pane_id: &str) -> Option<RunningPane> {
        let index = self
            .panes
            .iter()
            .position(|pane| pane.spec.pane_id == pane_id)?;
        Some(self.panes.remove(index))
    }

    fn terminate_all_panes(&mut self) -> Result<(), AppRuntimeError> {
        let pane_ids = self
            .pane_ids()
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        for pane_id in pane_ids {
            if let Some(mut pane) = self.take_pane(&pane_id) {
                pane.terminate()?;
            }
        }
        Ok(())
    }

    pub fn detach_focused_pane_to_new_window(&mut self) -> Option<Self> {
        if self.panes.len() <= 1 {
            return None;
        }

        let focused_pane_id = self.focused_pane_id.clone()?;
        let source_index = self
            .panes
            .iter()
            .position(|pane| pane.spec.pane_id == focused_pane_id)?;
        let removed_spec = self.panes[source_index].spec.clone();
        let source_worklane_id = removed_spec.worklane_id.clone();
        let source_worklane_pane_count = self
            .panes
            .iter()
            .filter(|pane| pane.spec.worklane_id == source_worklane_id)
            .count();
        let destination_window_id = self.next_detached_window_id();
        let destination_worklane_id = if source_worklane_pane_count == 1 {
            source_worklane_id.clone()
        } else {
            self.next_running_worklane_id()
        };
        let destination_worklane_title = if source_worklane_pane_count == 1 {
            self.worklane_titles_by_id.get(&source_worklane_id).cloned()
        } else {
            None
        };

        let mut moved_pane = self.panes.remove(source_index);
        if source_worklane_pane_count == 1 {
            self.remove_empty_running_worklane(&source_worklane_id);
        } else {
            retarget_pane_for_split_out(&mut moved_pane.spec, &destination_worklane_id);
            self.normalize_running_after_remove(&removed_spec);
            if let Some(next_focus) = self.next_focus_after_running_removal(&removed_spec) {
                let _ = self.focus_running_pane(next_focus);
            }
        }

        let focused_pane_id = moved_pane.spec.pane_id.clone();
        let mut focused_pane_id_by_worklane_id = BTreeMap::new();
        focused_pane_id_by_worklane_id
            .insert(destination_worklane_id.clone(), focused_pane_id.clone());
        let mut worklane_titles_by_id = BTreeMap::new();
        if let Some(title) = destination_worklane_title {
            worklane_titles_by_id.insert(destination_worklane_id.clone(), title);
        }

        Some(Self {
            window_id: Some(destination_window_id),
            default_size: self.default_size,
            active_worklane_id: Some(destination_worklane_id.clone()),
            worklane_order: vec![destination_worklane_id],
            focused_pane_id_by_worklane_id,
            focus_history: PaneFocusHistory::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklane_titles_by_id,
            pane_notifications: Vec::new(),
            theme_mode: self.theme_mode,
            closed_pane_specs: Vec::new(),
            panes: vec![moved_pane],
            focused_pane_id: Some(focused_pane_id),
            agent_ipc_environment: self.agent_ipc_environment.clone(),
        })
    }

    fn write_input_to_pane(
        &mut self,
        pane_id: &str,
        payload: TerminalInputPayload,
    ) -> Result<(), AppRuntimeError> {
        self.write_to_pane(pane_id, &payload.into_pty_bytes())
    }

    fn move_focus_horizontally(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(worklane) = self.focused_worklane_snapshot() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(target_pane_id) = target_horizontal_pane_id(&worklane, delta) else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_running_pane(target_pane_id)
    }

    fn move_focus_vertically(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(worklane) = self.focused_worklane_snapshot() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(target_pane_id) = target_vertical_pane_id(&worklane, delta) else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_running_pane(target_pane_id)
    }

    fn move_focus_by_running_order(&mut self, delta: isize) -> AppCommandExecutionResult {
        if self.panes.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(current_pane_id) = self.focused_pane_id.as_deref() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(current_index) = self
            .panes
            .iter()
            .position(|pane| pane.spec.pane_id == current_pane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let target_index =
            (current_index as isize + delta).rem_euclid(self.panes.len() as isize) as usize;
        self.focus_running_pane(self.panes[target_index].spec.pane_id.clone())
    }

    fn close_focused_pane(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        if self.panes.len() <= 1 {
            return Ok(self.request_close_window());
        }

        let Some(focused_pane_id) = self.focused_pane_id.as_deref() else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let Some(index) = self
            .panes
            .iter()
            .position(|pane| pane.spec.pane_id == focused_pane_id)
        else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };

        let removed_spec = self.panes[index].spec.clone();
        self.panes[index].terminate()?;
        let _ = self.panes.remove(index);
        self.closed_pane_specs.push(removed_spec.clone());
        if !self
            .panes
            .iter()
            .any(|pane| pane.spec.worklane_id == removed_spec.worklane_id)
        {
            self.worklane_order
                .retain(|worklane_id| worklane_id != &removed_spec.worklane_id);
            self.focused_pane_id_by_worklane_id
                .remove(&removed_spec.worklane_id);
        }
        if let Some(next_focus) = self.next_focus_after_running_removal(&removed_spec) {
            let _ = self.focus_running_pane(next_focus);
        } else {
            self.focused_pane_id = None;
            self.active_worklane_id = None;
        }
        Ok(AppCommandExecutionResult::Applied)
    }

    fn restore_closed_pane(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(mut spec) = self.closed_pane_specs.pop() else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        if self
            .panes
            .iter()
            .any(|pane| pane.spec.pane_id == spec.pane_id)
        {
            spec.pane_id = self.next_running_pane_id();
            spec.column_id = format!("column-{}", spec.pane_id);
        }
        let pane_id = spec.pane_id.clone();
        let worklane_id = spec.worklane_id.clone();
        let title = spec.title.clone();
        let session = self
            .spawn_running_pane(&spec)
            .map_err(AppRuntimeError::Pty)?;

        self.ensure_running_worklane(&worklane_id);
        self.focused_pane_id_by_worklane_id
            .insert(worklane_id.clone(), pane_id.clone());
        self.push_and_focus_running_pane(spec, session);
        Ok(AppCommandExecutionResult::RestoredClosedPane {
            pane_id,
            worklane_id,
            toast_message: format!("Restored \"{title}\""),
        })
    }

    fn split_focused_pane_right(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_column_index = focused.column_index + 1;
        let mut new_spec = new_inherited_pane(&new_pane_id, &focused, new_column_index, 0);
        apply_runtime_terminal_inheritance(&mut new_spec, &focused);
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index >= new_column_index
            {
                pane.spec.column_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn split_focused_pane_left(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_column_index = focused.column_index;
        let mut new_spec = new_inherited_pane(&new_pane_id, &focused, new_column_index, 0);
        new_spec.column_id = format!("column-{new_pane_id}");
        apply_runtime_terminal_inheritance(&mut new_spec, &focused);
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index >= new_column_index
            {
                pane.spec.column_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn split_focused_pane_below(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_pane_index = focused.pane_index + 1;
        let mut new_spec =
            new_inherited_pane(&new_pane_id, &focused, focused.column_index, new_pane_index);
        apply_runtime_terminal_inheritance(&mut new_spec, &focused);
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index == focused.column_index
                && pane.spec.pane_index >= new_pane_index
            {
                pane.spec.pane_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn split_focused_pane_above(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_pane_index = focused.pane_index;
        let mut new_spec =
            new_inherited_pane(&new_pane_id, &focused, focused.column_index, new_pane_index);
        apply_runtime_terminal_inheritance(&mut new_spec, &focused);
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index == focused.column_index
                && pane.spec.pane_index >= new_pane_index
            {
                pane.spec.pane_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn equalize_focused_running_column_heights(&mut self) -> AppCommandExecutionResult {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let mut did_change = false;
        let mut pane_count = 0;
        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index == focused.column_index
            {
                pane_count += 1;
                if pane.spec.pane_height != Some(MIN_LAYOUT_WEIGHT) {
                    did_change = true;
                }
                pane.spec.pane_height = Some(MIN_LAYOUT_WEIGHT);
            }
        }
        if pane_count >= 2 && did_change {
            AppCommandExecutionResult::Applied
        } else {
            AppCommandExecutionResult::Unavailable
        }
    }

    fn resize_focused_running_column_to_fraction(
        &mut self,
        fraction: f64,
    ) -> AppCommandExecutionResult {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let columns = running_column_snapshots(&self.panes, &focused.worklane_id);
        if columns.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(focused_position) = columns
            .iter()
            .position(|column| column.column_index == focused.column_index)
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
            .map(|column| column.width.max(MIN_LAYOUT_WEIGHT))
            .sum::<f64>()
            .max(MIN_LAYOUT_WEIGHT);
        let pair_width = (focused_column.width.max(MIN_LAYOUT_WEIGHT)
            + neighbor_column.width.max(MIN_LAYOUT_WEIGHT))
        .max(MIN_LAYOUT_WEIGHT * 2.0);
        let target_width = (total_width * fraction.clamp(0.05, 0.95))
            .clamp(MIN_LAYOUT_WEIGHT, pair_width - MIN_LAYOUT_WEIGHT);
        let neighbor_width = pair_width - target_width;
        if nearly_equal(focused_column.width, target_width)
            && nearly_equal(neighbor_column.width, neighbor_width)
        {
            return AppCommandExecutionResult::Unavailable;
        }
        for pane in &mut self.panes {
            if pane.spec.worklane_id != focused.worklane_id {
                continue;
            }
            if pane.spec.column_index == focused_column.column_index {
                pane.spec.column_width = target_width;
            } else if pane.spec.column_index == neighbor_column.column_index {
                pane.spec.column_width = neighbor_width;
            }
        }
        AppCommandExecutionResult::Applied
    }

    fn resize_focused_running_pane_height_to_fraction(
        &mut self,
        fraction: f64,
    ) -> AppCommandExecutionResult {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return AppCommandExecutionResult::Unavailable;
        };
        let mut column_indices = self
            .panes
            .iter()
            .enumerate()
            .filter(|(_, pane)| {
                pane.spec.worklane_id == focused.worklane_id
                    && pane.spec.column_index == focused.column_index
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        column_indices.sort_by_key(|index| {
            (
                self.panes[*index].spec.pane_index,
                self.panes[*index].spec.pane_id.clone(),
            )
        });
        if column_indices.len() < 2 {
            return AppCommandExecutionResult::Unavailable;
        }
        let Some(focused_index) = column_indices
            .iter()
            .copied()
            .find(|index| self.panes[*index].spec.pane_id == focused.pane_id)
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        let total_weight = column_indices
            .iter()
            .map(|index| {
                self.panes[*index]
                    .spec
                    .pane_height
                    .unwrap_or(MIN_LAYOUT_WEIGHT)
                    .max(MIN_LAYOUT_WEIGHT)
            })
            .sum::<f64>();
        let focused_weight = self.panes[focused_index]
            .spec
            .pane_height
            .unwrap_or(MIN_LAYOUT_WEIGHT)
            .max(MIN_LAYOUT_WEIGHT);
        let other_weight = total_weight - focused_weight;
        if other_weight <= 0.0 {
            return AppCommandExecutionResult::Unavailable;
        }
        let clamped_fraction = fraction.clamp(0.05, 0.95);
        let target_weight = (clamped_fraction / (1.0 - clamped_fraction)) * other_weight;
        if nearly_equal(focused_weight, target_weight) {
            return AppCommandExecutionResult::Unavailable;
        }
        self.panes[focused_index].spec.pane_height = Some(target_weight.max(MIN_LAYOUT_WEIGHT));
        AppCommandExecutionResult::Applied
    }

    fn duplicate_focused_pane(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let Some(focused) = self.focused_running_pane().map(|pane| pane.spec.clone()) else {
            return Ok(AppCommandExecutionResult::Unavailable);
        };
        let worklane = self.running_worklane_snapshot(&focused.worklane_id, None);
        let new_pane_id = next_pane_id(&worklane);
        let new_column_index = focused.column_index + 1;
        let mut new_spec = base_new_pane(&new_pane_id, new_column_index, 0);
        new_spec.worklane_id = focused.worklane_id.clone();
        apply_runtime_terminal_inheritance(&mut new_spec, &focused);
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        for pane in &mut self.panes {
            if pane.spec.worklane_id == focused.worklane_id
                && pane.spec.column_index >= new_column_index
            {
                pane.spec.column_index += 1;
            }
        }
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn create_new_worklane(&mut self) -> Result<AppCommandExecutionResult, AppRuntimeError> {
        let worklane_id = self.next_running_worklane_id();
        let pane_id = self.next_running_pane_id();
        let source = self.focused_running_pane().map(|pane| pane.spec.clone());
        let mut new_spec = base_new_pane(&pane_id, 0, 0);
        new_spec.worklane_id = worklane_id.clone();
        new_spec.column_id = format!("column-{pane_id}");
        new_spec.title = "pane 1".to_string();
        new_spec.column_width = DEFAULT_COLUMN_WIDTH;
        if let Some(source) = &source {
            apply_runtime_terminal_inheritance(&mut new_spec, source);
        }
        let session = self
            .spawn_running_pane(&new_spec)
            .map_err(AppRuntimeError::Pty)?;

        let insertion_index = self
            .active_worklane_id
            .as_ref()
            .and_then(|id| {
                self.worklane_order
                    .iter()
                    .position(|candidate| candidate == id)
            })
            .map(|index| index + 1)
            .unwrap_or(self.worklane_order.len());
        self.worklane_order
            .insert(insertion_index, worklane_id.clone());
        self.focused_pane_id_by_worklane_id
            .insert(worklane_id.clone(), pane_id.clone());
        self.active_worklane_id = Some(worklane_id);
        self.push_and_focus_running_pane(new_spec, session);
        Ok(AppCommandExecutionResult::Applied)
    }

    fn cycle_worklane(&mut self, delta: isize) -> AppCommandExecutionResult {
        let available_worklanes = self
            .worklane_order
            .iter()
            .filter(|worklane_id| {
                self.panes
                    .iter()
                    .any(|pane| pane.spec.worklane_id == **worklane_id)
            })
            .cloned()
            .collect::<Vec<_>>();
        if available_worklanes.len() <= 1 {
            return AppCommandExecutionResult::Unavailable;
        }

        let current_worklane_id = self
            .active_worklane_id
            .as_ref()
            .or_else(|| {
                self.focused_running_pane()
                    .map(|pane| &pane.spec.worklane_id)
            })
            .cloned();
        let current_index = current_worklane_id
            .as_ref()
            .and_then(|id| {
                available_worklanes
                    .iter()
                    .position(|candidate| candidate == id)
            })
            .unwrap_or(0);
        let target_index = (current_index as isize + delta)
            .rem_euclid(available_worklanes.len() as isize) as usize;
        self.focus_worklane(&available_worklanes[target_index])
    }

    fn move_active_worklane_by(&mut self, delta: isize) -> AppCommandExecutionResult {
        let Some(active_worklane_id) = self.active_worklane_id.as_ref() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let Some(current_index) = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == active_worklane_id)
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

    fn focused_pane_result(
        &self,
        result: fn(String) -> AppCommandExecutionResult,
    ) -> AppCommandExecutionResult {
        self.focused_running_pane()
            .map(|pane| result(pane.spec.pane_id.clone()))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn copy_focused_pane_path(&self) -> AppCommandExecutionResult {
        self.focused_running_pane()
            .and_then(|pane| pane.spec.terminal_request.working_directory.as_deref())
            .and_then(trimmed_non_empty)
            .map(|path| AppCommandExecutionResult::CopyText {
                text: path.to_string(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn focused_pane_path(&self) -> Option<&str> {
        self.focused_running_pane()
            .and_then(|pane| pane.spec.terminal_request.working_directory.as_deref())
            .and_then(trimmed_non_empty)
    }

    fn has_worklane_id(&self, worklane_id: &str) -> bool {
        self.worklane_order
            .iter()
            .any(|candidate| candidate == worklane_id)
            || self
                .panes
                .iter()
                .any(|pane| pane.spec.worklane_id == worklane_id)
    }

    fn focused_branch_url(&self) -> Option<&str> {
        let pane_id = self.focused_running_pane()?.spec.pane_id.as_str();
        self.branch_urls_by_pane_id
            .get(pane_id)
            .map(String::as_str)
            .and_then(trimmed_non_empty)
    }

    fn open_with_primary_target(&self) -> AppCommandExecutionResult {
        let Some(target) = self.open_with_targets.first() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_with_target(&target.stable_id)
    }

    fn open_with_target(&self, stable_id: &str) -> AppCommandExecutionResult {
        let Some(path) = self.focused_pane_path() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_with_targets
            .iter()
            .find(|target| target.stable_id == stable_id)
            .map(|target| AppCommandExecutionResult::OpenPathWithTarget {
                path: path.to_string(),
                target_id: target.stable_id.clone(),
                target_name: target.display_name.clone(),
                app_path: target.app_path.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn open_primary_server(&self) -> AppCommandExecutionResult {
        let Some(server) = self.detected_servers.first() else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.open_server(&server.id)
    }

    fn open_server(&self, id: &str) -> AppCommandExecutionResult {
        self.detected_servers
            .iter()
            .find(|server| server.id == id)
            .map(|server| AppCommandExecutionResult::OpenServer {
                server_id: server.id.clone(),
                origin: server.origin.clone(),
                url: server.url.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn open_focused_branch_url(&self) -> AppCommandExecutionResult {
        self.focused_branch_url()
            .map(|url| AppCommandExecutionResult::OpenUrl {
                url: url.to_string(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn focus_pane_item(
        &mut self,
        worklane_id: &str,
        pane_id: &str,
    ) -> CommandPaletteItemExecutionResult {
        self.focus_pane_reference(
            PaneReference::new(worklane_id, PaneId::from(pane_id.to_string())),
            true,
            true,
        )
        .into()
    }

    fn restored_command_for_pane(&self, pane_id: &str) -> Option<String> {
        self.panes
            .iter()
            .find(|pane| pane.spec.pane_id == pane_id)
            .and_then(|pane| pane.spec.restored_rerunnable_command.as_deref())
            .and_then(trimmed_non_empty)
            .map(ToOwned::to_owned)
    }

    fn set_active_worklane_color(
        &mut self,
        color: &Option<String>,
    ) -> CommandPaletteItemExecutionResult {
        let Some(worklane_id) = self
            .active_worklane_id
            .as_ref()
            .filter(|worklane_id| {
                self.panes
                    .iter()
                    .any(|pane| pane.spec.worklane_id == **worklane_id)
            })
            .cloned()
        else {
            return CommandPaletteItemExecutionResult::Unavailable;
        };
        let color = match color.as_deref() {
            Some(raw) => match WorklaneColor::from_raw_value(raw) {
                Some(color) => Some(color.raw_value().to_string()),
                None => return CommandPaletteItemExecutionResult::Unsupported,
            },
            None => None,
        };

        if let Some(color) = &color {
            self.worklane_colors_by_id
                .insert(worklane_id.clone(), color.clone());
        } else {
            self.worklane_colors_by_id.remove(&worklane_id);
        }

        CommandPaletteItemExecutionResult::SetWorklaneColor { worklane_id, color }
    }

    fn rename_active_worklane(&self) -> AppCommandExecutionResult {
        self.active_worklane_id
            .as_ref()
            .filter(|worklane_id| {
                self.panes
                    .iter()
                    .any(|pane| pane.spec.worklane_id == **worklane_id)
            })
            .map(
                |worklane_id| AppCommandExecutionResult::BeginRenameWorklane {
                    worklane_id: worklane_id.clone(),
                },
            )
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn request_close_window(&self) -> AppCommandExecutionResult {
        self.window_id
            .as_ref()
            .map(|window_id| AppCommandExecutionResult::RequestCloseWindow {
                window_id: window_id.clone(),
            })
            .unwrap_or(AppCommandExecutionResult::Unavailable)
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
        self.focused_running_pane()
            .map(
                |pane| AppCommandExecutionResult::RequestMovePaneToNewWindow {
                    pane_id: pane.spec.pane_id.clone(),
                },
            )
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn apply_layout_command(&mut self, command_id: AppCommandId) -> AppCommandExecutionResult {
        let mut window = self.running_window_snapshot();
        let result = window.execute_command(command_id);
        if result == AppCommandExecutionResult::Applied {
            self.apply_running_window_snapshot(window);
        }
        result
    }

    fn running_window_snapshot(&self) -> WindowLaunchPlan {
        let worklane_ids = self.running_worklane_ids();
        WindowLaunchPlan {
            window_id: self
                .window_id
                .clone()
                .unwrap_or_else(|| "window-main".to_string()),
            active_worklane_id: self.active_worklane_id.clone(),
            focus_history: self.focus_history.clone(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: self.open_with_targets.clone(),
            detected_servers: self.detected_servers.clone(),
            task_runner_actions: self.task_runner_actions.clone(),
            branch_urls_by_pane_id: self.branch_urls_by_pane_id.clone(),
            worklane_colors_by_id: self.worklane_colors_by_id.clone(),
            worklanes: worklane_ids
                .into_iter()
                .filter_map(|worklane_id| {
                    let focused_pane_id = self
                        .focused_pane_id_by_worklane_id
                        .get(&worklane_id)
                        .cloned();
                    let worklane = self.running_worklane_snapshot(&worklane_id, focused_pane_id);
                    (!worklane.panes.is_empty()).then_some(worklane)
                })
                .collect(),
        }
    }

    fn running_worklane_ids(&self) -> Vec<String> {
        let mut worklane_ids = self.worklane_order.clone();
        for pane in &self.panes {
            if !worklane_ids
                .iter()
                .any(|worklane_id| worklane_id == &pane.spec.worklane_id)
            {
                worklane_ids.push(pane.spec.worklane_id.clone());
            }
        }
        worklane_ids
    }

    fn apply_running_window_snapshot(&mut self, window: WindowLaunchPlan) {
        let mut specs_by_pane_id = BTreeMap::new();
        let mut pane_order_by_id = BTreeMap::new();
        for (index, spec) in window
            .worklanes
            .iter()
            .flat_map(|worklane| worklane.panes.iter())
            .enumerate()
        {
            specs_by_pane_id.insert(spec.pane_id.clone(), spec.clone());
            pane_order_by_id.insert(spec.pane_id.clone(), index);
        }

        for pane in &mut self.panes {
            if let Some(spec) = specs_by_pane_id.get(&pane.spec.pane_id) {
                pane.spec = spec.clone();
            }
        }
        self.panes.sort_by_key(|pane| {
            pane_order_by_id
                .get(&pane.spec.pane_id)
                .copied()
                .unwrap_or(usize::MAX)
        });
        self.active_worklane_id = window.active_worklane_id;
        self.worklane_order = window
            .worklanes
            .iter()
            .map(|worklane| worklane.worklane_id.clone())
            .collect();
        self.focused_pane_id_by_worklane_id = window
            .worklanes
            .iter()
            .filter_map(|worklane| {
                worklane
                    .focused_pane_id
                    .as_ref()
                    .map(|pane_id| (worklane.worklane_id.clone(), pane_id.clone()))
            })
            .collect();
        self.task_runner_actions = window.task_runner_actions;
        self.worklane_colors_by_id = window.worklane_colors_by_id;
        self.worklane_titles_by_id = window
            .worklanes
            .iter()
            .filter_map(|worklane| {
                normalized_worklane_title(worklane.title.as_deref())
                    .map(|title| (worklane.worklane_id.clone(), title))
            })
            .collect();
        self.focus_history = window.focus_history;
        self.focused_pane_id = self
            .active_worklane_id
            .as_ref()
            .and_then(|worklane_id| {
                self.focused_pane_id_by_worklane_id
                    .get(worklane_id)
                    .cloned()
            })
            .or_else(|| self.panes.first().map(|pane| pane.spec.pane_id.clone()));
    }

    fn focused_worklane_snapshot(&self) -> Option<WorklaneLaunchPlan> {
        let focused = self.focused_running_pane()?;
        let worklane_id = focused.spec.worklane_id.clone();
        let panes = self
            .panes
            .iter()
            .filter(|pane| pane.spec.worklane_id == worklane_id)
            .map(|pane| pane.spec.clone())
            .collect::<Vec<_>>();
        Some(WorklaneLaunchPlan {
            title: self.worklane_titles_by_id.get(&worklane_id).cloned(),
            worklane_id,
            panes,
            focused_pane_id: Some(focused.spec.pane_id.clone()),
        })
    }

    fn next_focus_after_running_removal(&self, removed: &PaneLaunchSpec) -> Option<String> {
        let worklane = self.running_worklane_snapshot(&removed.worklane_id, None);
        if !worklane.panes.is_empty() {
            return next_focus_after_removal(&worklane, removed)
                .or_else(|| worklane.panes.first().map(|pane| pane.pane_id.clone()));
        }
        self.panes.first().map(|pane| pane.spec.pane_id.clone())
    }

    fn running_worklane_snapshot(
        &self,
        worklane_id: &str,
        focused_pane_id: Option<String>,
    ) -> WorklaneLaunchPlan {
        WorklaneLaunchPlan {
            worklane_id: worklane_id.to_string(),
            title: self.worklane_titles_by_id.get(worklane_id).cloned(),
            panes: self
                .panes
                .iter()
                .filter(|pane| pane.spec.worklane_id == worklane_id)
                .map(|pane| pane.spec.clone())
                .collect(),
            focused_pane_id,
        }
    }

    fn focused_running_pane(&self) -> Option<&RunningPane> {
        let pane_id = self.focused_pane_id.as_deref()?;
        self.panes.iter().find(|pane| pane.spec.pane_id == pane_id)
    }

    fn spawn_running_pane(&mut self, spec: &PaneLaunchSpec) -> Result<NativePtySession, PtyError> {
        let pane_environment = self.agent_ipc_pane_environment_for_spec(spec);
        spec.spawn_pty_with_agent_ipc(
            self.default_size,
            self.window_id.as_deref(),
            pane_environment.as_ref(),
        )
    }

    fn agent_ipc_pane_environment_for_spec(
        &mut self,
        spec: &PaneLaunchSpec,
    ) -> Option<AgentIpcPaneEnvironment> {
        let window_id = self.window_id.clone();
        let window_id = window_id.as_deref();
        let environment = self.agent_ipc_environment.as_mut()?;
        if environment.pane_environment(window_id, spec).is_none() {
            let pane_token = generate_agent_ipc_pane_token().ok()?;
            environment.set_pane_token(window_id, &spec.worklane_id, &spec.pane_id, pane_token);
        }
        environment.pane_environment(window_id, spec)
    }

    fn current_pane_reference(&self) -> Option<PaneReference> {
        let pane = self.focused_running_pane()?;
        Some(PaneReference::new(
            pane.spec.worklane_id.clone(),
            PaneId::from(pane.spec.pane_id.clone()),
        ))
    }

    fn all_pane_references(&self) -> HashSet<PaneReference> {
        self.panes
            .iter()
            .map(|pane| {
                PaneReference::new(
                    pane.spec.worklane_id.clone(),
                    PaneId::from(pane.spec.pane_id.clone()),
                )
            })
            .collect()
    }

    fn focus_pane_reference(
        &mut self,
        reference: PaneReference,
        record_history: bool,
        same_focus_is_applied: bool,
    ) -> AppCommandExecutionResult {
        if !self.panes.iter().any(|pane| {
            pane.spec.worklane_id == reference.worklane_id
                && pane.spec.pane_id == reference.pane_id.as_str()
        }) {
            return AppCommandExecutionResult::Unavailable;
        }
        if self.current_pane_reference().as_ref() == Some(&reference) && !same_focus_is_applied {
            return AppCommandExecutionResult::Unavailable;
        }
        if record_history
            && let Some(current) = self.current_pane_reference()
                && current != reference {
                    self.focus_history.record(current);
                }

        let worklane_id = reference.worklane_id;
        let pane_id = reference.pane_id.as_str().to_string();
        self.focused_pane_id_by_worklane_id
            .insert(worklane_id.clone(), pane_id.clone());
        self.active_worklane_id = Some(worklane_id);
        self.focused_pane_id = Some(pane_id);
        AppCommandExecutionResult::Applied
    }

    fn navigate_focus_history(&mut self, backward: bool) -> AppCommandExecutionResult {
        let Some(current) = self.current_pane_reference() else {
            return AppCommandExecutionResult::Unavailable;
        };
        let all_pane_ids = self.all_pane_references();
        let destination = if backward {
            self.focus_history.navigate_back(current, &all_pane_ids)
        } else {
            self.focus_history.navigate_forward(current, &all_pane_ids)
        };
        destination
            .map(|reference| self.focus_pane_reference(reference, false, true))
            .unwrap_or(AppCommandExecutionResult::Unavailable)
    }

    fn focus_running_pane(&mut self, pane_id: String) -> AppCommandExecutionResult {
        let Some(reference) = self
            .panes
            .iter()
            .find(|pane| pane.spec.pane_id == pane_id)
            .map(|pane| {
                PaneReference::new(
                    pane.spec.worklane_id.clone(),
                    PaneId::from(pane.spec.pane_id.clone()),
                )
            })
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_pane_reference(reference, true, false)
    }

    fn push_and_focus_running_pane(&mut self, spec: PaneLaunchSpec, session: NativePtySession) {
        let pane_id = spec.pane_id.clone();
        self.panes.push(RunningPane {
            spec,
            session,
            shell_activity_state: TaskRunnerShellActivityState::Unknown,
            root_pid: None,
        });
        let _ = self.focus_running_pane(pane_id);
    }

    fn remove_empty_running_worklane(&mut self, worklane_id: &str) {
        let removed_index = self
            .worklane_order
            .iter()
            .position(|candidate| candidate == worklane_id);
        self.worklane_order
            .retain(|candidate| candidate != worklane_id);
        self.focused_pane_id_by_worklane_id.remove(worklane_id);
        self.worklane_titles_by_id.remove(worklane_id);

        if self.active_worklane_id.as_deref() != Some(worklane_id) {
            return;
        }

        let Some(next_worklane_id) = removed_index
            .and_then(|index| {
                self.worklane_order.get(
                    index
                        .saturating_sub(1)
                        .min(self.worklane_order.len().saturating_sub(1)),
                )
            })
            .cloned()
            .or_else(|| self.worklane_order.first().cloned())
        else {
            self.active_worklane_id = None;
            self.focused_pane_id = None;
            return;
        };

        let next_pane_id = self
            .focused_pane_id_by_worklane_id
            .get(&next_worklane_id)
            .cloned()
            .or_else(|| {
                self.panes
                    .iter()
                    .find(|pane| pane.spec.worklane_id == next_worklane_id)
                    .map(|pane| pane.spec.pane_id.clone())
            });
        self.active_worklane_id = Some(next_worklane_id);
        self.focused_pane_id = next_pane_id;
    }

    fn normalize_running_after_remove(&mut self, removed: &PaneLaunchSpec) {
        let removed_column_still_exists = self.panes.iter().any(|pane| {
            pane.spec.worklane_id == removed.worklane_id
                && pane.spec.column_index == removed.column_index
        });
        for pane in self
            .panes
            .iter_mut()
            .filter(|pane| pane.spec.worklane_id == removed.worklane_id)
        {
            if pane.spec.column_index == removed.column_index
                && pane.spec.pane_index > removed.pane_index
            {
                pane.spec.pane_index -= 1;
            }
            if pane.spec.column_index > removed.column_index && !removed_column_still_exists {
                pane.spec.column_index -= 1;
            }
        }
        self.panes.sort_by_key(|pane| {
            (
                self.worklane_order
                    .iter()
                    .position(|worklane_id| worklane_id == &pane.spec.worklane_id)
                    .unwrap_or(usize::MAX),
                pane.spec.column_index,
                pane.spec.pane_index,
                pane.spec.pane_id.clone(),
            )
        });
    }

    fn sort_running_panes(&mut self) {
        let worklane_order = self.worklane_order.clone();
        self.panes.sort_by_key(|pane| {
            (
                worklane_order
                    .iter()
                    .position(|worklane_id| worklane_id == &pane.spec.worklane_id)
                    .unwrap_or(usize::MAX),
                pane.spec.column_index,
                pane.spec.pane_index,
                pane.spec.pane_id.clone(),
            )
        });
    }

    fn next_detached_window_id(&self) -> String {
        let current_window = self.running_window_snapshot();
        next_window_id(&[current_window])
    }

    fn set_window_id(&mut self, window_id: String) {
        self.window_id = Some(window_id);
    }

    fn ensure_running_worklane(&mut self, worklane_id: &str) {
        if self.worklane_order.iter().any(|id| id == worklane_id) {
            return;
        }
        let insertion_index = self
            .active_worklane_id
            .as_ref()
            .and_then(|id| {
                self.worklane_order
                    .iter()
                    .position(|candidate| candidate == id)
            })
            .map(|index| index + 1)
            .unwrap_or(self.worklane_order.len());
        self.worklane_order
            .insert(insertion_index, worklane_id.to_string());
    }

    fn focus_worklane(&mut self, worklane_id: &str) -> AppCommandExecutionResult {
        let focused_pane_id = self
            .focused_pane_id_by_worklane_id
            .get(worklane_id)
            .cloned();
        let worklane = self.running_worklane_snapshot(worklane_id, focused_pane_id);
        let Some(target_pane_id) =
            focused_pane_in_worklane(&worklane).map(|pane| pane.pane_id.clone())
        else {
            return AppCommandExecutionResult::Unavailable;
        };
        self.focus_running_pane(target_pane_id)
    }

    fn next_running_worklane_id(&self) -> String {
        let mut index = self.worklane_order.len() + 1;
        loop {
            let candidate = format!("worklane-{index}");
            if !self.worklane_order.iter().any(|id| id == &candidate) {
                return candidate;
            }
            index += 1;
        }
    }

    fn next_running_pane_id(&self) -> String {
        let mut index = self.panes.len() + 1;
        loop {
            let candidate = format!("pane-{index}");
            if !self.panes.iter().any(|pane| pane.spec.pane_id == candidate) {
                return candidate;
            }
            index += 1;
        }
    }

    fn pane_mut(&mut self, pane_id: &str) -> Result<&mut RunningPane, AppRuntimeError> {
        self.panes
            .iter_mut()
            .find(|pane| pane.spec.pane_id == pane_id)
            .ok_or_else(|| AppRuntimeError::PaneNotFound(pane_id.to_string()))
    }
}

pub struct RunningPane {
    pub spec: PaneLaunchSpec,
    session: NativePtySession,
    shell_activity_state: TaskRunnerShellActivityState,
    root_pid: Option<i32>,
}

impl RunningPane {
    pub fn run_with_streams<R, W>(
        self,
        input: R,
        output: W,
        timeout: Option<std::time::Duration>,
    ) -> Result<PtyProcessOutput, PtyError>
    where
        R: std::io::Read + Send + 'static,
        W: std::io::Write + Send + 'static,
    {
        self.session.run_with_streams(input, output, timeout)
    }

    pub fn into_output_stream(self) -> Result<PaneOutputStream, PtyError> {
        self.session
            .into_output_stream()
            .map(|stream| PaneOutputStream { stream })
    }

    pub fn write_all(&mut self, bytes: &[u8]) -> Result<(), AppRuntimeError> {
        self.session.write_all(bytes).map_err(AppRuntimeError::Pty)
    }

    pub fn resize(&mut self, size: TerminalSize) -> Result<(), AppRuntimeError> {
        self.session.resize(size).map_err(AppRuntimeError::Pty)
    }

    pub fn terminate(&mut self) -> Result<(), AppRuntimeError> {
        self.session.terminate().map_err(AppRuntimeError::Pty)
    }

    pub fn wait_with_output(
        self,
        timeout: std::time::Duration,
    ) -> Result<zentty_pty::PtyProcessOutput, PtyError> {
        self.session.wait_with_output(timeout)
    }
}

fn running_column_snapshots(panes: &[RunningPane], worklane_id: &str) -> Vec<ColumnLaunchSnapshot> {
    let mut pane_specs = panes
        .iter()
        .filter(|pane| pane.spec.worklane_id == worklane_id)
        .map(|pane| &pane.spec)
        .collect::<Vec<_>>();
    pane_specs.sort_by(|lhs, rhs| {
        lhs.column_index
            .cmp(&rhs.column_index)
            .then(lhs.pane_index.cmp(&rhs.pane_index))
            .then(lhs.pane_id.cmp(&rhs.pane_id))
    });

    let mut seen_column_indices = BTreeSet::new();
    let mut snapshots = Vec::new();
    for pane in pane_specs {
        if seen_column_indices.insert(pane.column_index) {
            snapshots.push(ColumnLaunchSnapshot {
                column_id: pane.column_id.clone(),
                column_index: pane.column_index,
                width: pane.column_width,
            });
        }
    }
    snapshots
}

fn next_running_pane_id_with_reserved(
    panes: &[RunningPane],
    reserved_pane_ids: &HashSet<String>,
) -> String {
    let mut index = panes
        .iter()
        .map(|pane| pane.spec.pane_id.as_str())
        .chain(reserved_pane_ids.iter().map(String::as_str))
        .filter_map(pane_id_numeric_suffix)
        .max()
        .unwrap_or(panes.len().max(reserved_pane_ids.len()))
        + 1;
    loop {
        let candidate = format!("pane-{index}");
        if !reserved_pane_ids.contains(&candidate)
            && !panes.iter().any(|pane| pane.spec.pane_id == candidate)
        {
            return candidate;
        }
        index += 1;
    }
}

fn pane_id_numeric_suffix(pane_id: &str) -> Option<usize> {
    pane_id.strip_prefix("pane-")?.parse().ok()
}

fn task_manager_status_text(state: TaskRunnerShellActivityState) -> Option<String> {
    match state {
        TaskRunnerShellActivityState::CommandRunning => Some("Running".to_string()),
        TaskRunnerShellActivityState::PromptIdle => Some("Idle".to_string()),
        TaskRunnerShellActivityState::Unknown => None,
    }
}

pub struct PaneOutputStream {
    stream: NativePtyOutputStream,
}

impl PaneOutputStream {
    pub fn write_all(&mut self, bytes: &[u8]) -> Result<(), PtyError> {
        self.stream.write_all(bytes)
    }

    pub fn resize(&mut self, size: TerminalSize) -> Result<(), PtyError> {
        self.stream.resize(size)
    }

    pub fn read_available_bytes(&mut self) -> Result<Vec<u8>, PtyError> {
        self.stream.read_available_bytes()
    }

    pub fn read_until_contains(
        &mut self,
        needle: &str,
        timeout: std::time::Duration,
    ) -> Result<String, PtyError> {
        self.stream.read_until_contains(needle, timeout)
    }

    pub fn read_into_screen_until_contains(
        &mut self,
        screen: &mut TerminalScreen,
        needle: &str,
        timeout: std::time::Duration,
    ) -> Result<String, PtyError> {
        let output = self.stream.read_until_contains(needle, timeout)?;
        screen.feed(output.as_bytes());
        Ok(output)
    }

    pub fn wait_with_output(
        self,
        timeout: std::time::Duration,
    ) -> Result<PtyProcessOutput, PtyError> {
        self.stream.wait_with_output(timeout)
    }

    pub fn terminate(&mut self) -> Result<(), PtyError> {
        self.stream.terminate()
    }
}

#[derive(Debug)]
pub enum AppLaunchError {
    PaneSpawn { pane_id: String, source: PtyError },
}

#[derive(Debug)]
pub enum AppRuntimeError {
    NoFocusedPane,
    PaneNotFound(String),
    Pty(PtyError),
}

impl PaneLaunchSpec {
    pub fn pty_request(&self) -> PtySessionRequest {
        pty_request_for_terminal_request(&self.terminal_request)
    }

    pub fn pty_request_with_agent_ipc(
        &self,
        window_id: Option<&str>,
        agent_ipc_environment: Option<&AgentIpcPaneEnvironment>,
    ) -> PtySessionRequest {
        let mut request = pty_request_for_terminal_request(&self.terminal_request);
        if let Some(window_id) = window_id.and_then(trimmed_non_empty) {
            request = request.env("ZENTTY_WINDOW_ID", window_id);
        }
        request = request
            .env("ZENTTY_WORKLANE_ID", &self.worklane_id)
            .env("ZENTTY_PANE_ID", &self.pane_id);
        if let Some(environment) = agent_ipc_environment {
            request = request
                .env("ZENTTY_INSTANCE_SOCKET", &environment.socket_path)
                .env("ZENTTY_PANE_TOKEN", &environment.pane_token)
                .env("ZENTTY_CLI_BIN", &environment.cli_bin)
                .env("ZENTTY_INSTANCE_ID", &environment.instance_id);
        }
        request
    }

    pub fn spawn_pty(&self, size: TerminalSize) -> Result<NativePtySession, PtyError> {
        NativePtySession::spawn(self.pty_request(), size)
    }

    pub fn spawn_pty_with_agent_ipc(
        &self,
        size: TerminalSize,
        window_id: Option<&str>,
        agent_ipc_environment: Option<&AgentIpcPaneEnvironment>,
    ) -> Result<NativePtySession, PtyError> {
        NativePtySession::spawn(
            self.pty_request_with_agent_ipc(window_id, agent_ipc_environment),
            size,
        )
    }
}

pub fn pty_request_for_terminal_request(request: &TerminalSessionRequest) -> PtySessionRequest {
    let mut pty_request = shell_request(request.command.as_deref());

    if let Some(working_directory) = request
        .working_directory
        .as_deref()
        .and_then(trimmed_non_empty)
    {
        pty_request = pty_request.cwd(working_directory);
    }

    for (key, value) in &request.environment_variables {
        pty_request = pty_request.env(key, value);
    }

    pty_request
}

fn restore_drafts_by_pane_id(
    restore_draft_window: Option<&SessionRestoreDraftWindow>,
) -> BTreeMap<String, PaneRestoreDraft> {
    restore_draft_window
        .map(|window| {
            window
                .pane_drafts
                .iter()
                .map(|draft| (draft.pane_id.clone(), draft.clone()))
                .collect()
        })
        .unwrap_or_default()
}

fn shell_request(command: Option<&str>) -> PtySessionRequest {
    let request = PtySessionRequest::new(default_shell());
    match command.and_then(trimmed_non_empty) {
        Some(command) => shell_request_with_auto_command(request, command),
        None => request,
    }
}

#[cfg(windows)]
fn shell_request_with_auto_command(request: PtySessionRequest, command: &str) -> PtySessionRequest {
    request.arg("/d").arg("/s").arg("/k").arg(command)
}

#[cfg(not(windows))]
fn shell_request_with_auto_command(request: PtySessionRequest, command: &str) -> PtySessionRequest {
    request.arg("-lc").arg(command)
}

fn trimmed_non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}
