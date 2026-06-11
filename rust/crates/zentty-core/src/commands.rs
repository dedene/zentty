use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum AppCommandId {
    ToggleSidebar,
    NewWorklane,
    RenameCurrentWorklane,
    NextWorklane,
    PreviousWorklane,
    WorklaneMoveUp,
    WorklaneMoveDown,
    Find,
    GlobalFind,
    UseSelectionForFind,
    FindNext,
    FindPrevious,
    CopyFocusedPanePath,
    JumpToLatestNotification,
    DuplicateFocusedPane,
    MovePaneToNewWindow,
    SplitHorizontally,
    ForceSplitRight,
    ForceAddPaneRight,
    SplitVertically,
    ArrangeWidthFull,
    ArrangeWidthHalves,
    ArrangeWidthThirds,
    ArrangeWidthQuarters,
    ArrangeHeightFull,
    ArrangeHeightTwoPerColumn,
    ArrangeHeightThreePerColumn,
    ArrangeHeightFourPerColumn,
    ArrangeWidthGoldenFocusWide,
    ArrangeWidthGoldenFocusNarrow,
    ArrangeHeightGoldenFocusTall,
    ArrangeHeightGoldenFocusShort,
    CloseFocusedPane,
    RestoreClosedPane,
    FocusPreviousPane,
    FocusNextPane,
    FocusLeftPane,
    FocusRightPane,
    FocusUpInColumn,
    FocusDownInColumn,
    ResizePaneLeft,
    ResizePaneRight,
    ResizePaneUp,
    ResizePaneDown,
    ResetPaneLayout,
    NavigateBack,
    NavigateForward,
    ShowCommandPalette,
    ShowTaskManager,
    OpenWithSelectedApp,
    OpenSelectedServer,
    OpenBranchOnRemote,
    ToggleLightDarkTheme,
    UseDarkTheme,
    UseLightTheme,
    UseAutoTheme,
    OpenSettings,
    NewWindow,
    CloseWindow,
    CleanCopy,
    CopyRaw,
    ReloadConfig,
    OpenBookmarksPopover,
}

impl AppCommandId {
    pub const ALL: [Self; 63] = [
        Self::ToggleSidebar,
        Self::NewWorklane,
        Self::RenameCurrentWorklane,
        Self::NextWorklane,
        Self::PreviousWorklane,
        Self::WorklaneMoveUp,
        Self::WorklaneMoveDown,
        Self::Find,
        Self::GlobalFind,
        Self::UseSelectionForFind,
        Self::FindNext,
        Self::FindPrevious,
        Self::CopyFocusedPanePath,
        Self::JumpToLatestNotification,
        Self::DuplicateFocusedPane,
        Self::MovePaneToNewWindow,
        Self::SplitHorizontally,
        Self::ForceSplitRight,
        Self::ForceAddPaneRight,
        Self::SplitVertically,
        Self::ArrangeWidthFull,
        Self::ArrangeWidthHalves,
        Self::ArrangeWidthThirds,
        Self::ArrangeWidthQuarters,
        Self::ArrangeHeightFull,
        Self::ArrangeHeightTwoPerColumn,
        Self::ArrangeHeightThreePerColumn,
        Self::ArrangeHeightFourPerColumn,
        Self::ArrangeWidthGoldenFocusWide,
        Self::ArrangeWidthGoldenFocusNarrow,
        Self::ArrangeHeightGoldenFocusTall,
        Self::ArrangeHeightGoldenFocusShort,
        Self::CloseFocusedPane,
        Self::RestoreClosedPane,
        Self::FocusPreviousPane,
        Self::FocusNextPane,
        Self::FocusLeftPane,
        Self::FocusRightPane,
        Self::FocusUpInColumn,
        Self::FocusDownInColumn,
        Self::ResizePaneLeft,
        Self::ResizePaneRight,
        Self::ResizePaneUp,
        Self::ResizePaneDown,
        Self::ResetPaneLayout,
        Self::NavigateBack,
        Self::NavigateForward,
        Self::ShowCommandPalette,
        Self::ShowTaskManager,
        Self::OpenWithSelectedApp,
        Self::OpenSelectedServer,
        Self::OpenBranchOnRemote,
        Self::ToggleLightDarkTheme,
        Self::UseDarkTheme,
        Self::UseLightTheme,
        Self::UseAutoTheme,
        Self::OpenSettings,
        Self::NewWindow,
        Self::CloseWindow,
        Self::CleanCopy,
        Self::CopyRaw,
        Self::ReloadConfig,
        Self::OpenBookmarksPopover,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::ToggleSidebar => "sidebar.toggle",
            Self::NewWorklane => "worklane.new",
            Self::RenameCurrentWorklane => "worklane.rename",
            Self::NextWorklane => "worklane.next",
            Self::PreviousWorklane => "worklane.previous",
            Self::WorklaneMoveUp => "worklane.move_up",
            Self::WorklaneMoveDown => "worklane.move_down",
            Self::Find => "pane.search.find",
            Self::GlobalFind => "window.search.find",
            Self::UseSelectionForFind => "pane.search.selection",
            Self::FindNext => "pane.search.next",
            Self::FindPrevious => "pane.search.previous",
            Self::CopyFocusedPanePath => "pane.copy_path",
            Self::JumpToLatestNotification => "notifications.jump_latest",
            Self::DuplicateFocusedPane => "pane.duplicate",
            Self::MovePaneToNewWindow => "pane.move_to_new_window",
            Self::SplitHorizontally => "pane.split.horizontal",
            Self::ForceSplitRight => "pane.split.right.force",
            Self::ForceAddPaneRight => "pane.add_right.force",
            Self::SplitVertically => "pane.split.vertical",
            Self::ArrangeWidthFull => "pane.arrange.width.full",
            Self::ArrangeWidthHalves => "pane.arrange.width.halves",
            Self::ArrangeWidthThirds => "pane.arrange.width.thirds",
            Self::ArrangeWidthQuarters => "pane.arrange.width.quarters",
            Self::ArrangeHeightFull => "pane.arrange.height.full",
            Self::ArrangeHeightTwoPerColumn => "pane.arrange.height.two_per_column",
            Self::ArrangeHeightThreePerColumn => "pane.arrange.height.three_per_column",
            Self::ArrangeHeightFourPerColumn => "pane.arrange.height.four_per_column",
            Self::ArrangeWidthGoldenFocusWide => "pane.arrange.width.golden_focus_wide",
            Self::ArrangeWidthGoldenFocusNarrow => "pane.arrange.width.golden_focus_narrow",
            Self::ArrangeHeightGoldenFocusTall => "pane.arrange.height.golden_focus_tall",
            Self::ArrangeHeightGoldenFocusShort => "pane.arrange.height.golden_focus_short",
            Self::CloseFocusedPane => "pane.close_focused",
            Self::RestoreClosedPane => "pane.restore_closed",
            Self::FocusPreviousPane => "pane.focus.previous",
            Self::FocusNextPane => "pane.focus.next",
            Self::FocusLeftPane => "pane.focus.left",
            Self::FocusRightPane => "pane.focus.right",
            Self::FocusUpInColumn => "pane.focus.up",
            Self::FocusDownInColumn => "pane.focus.down",
            Self::ResizePaneLeft => "pane.resize.left",
            Self::ResizePaneRight => "pane.resize.right",
            Self::ResizePaneUp => "pane.resize.up",
            Self::ResizePaneDown => "pane.resize.down",
            Self::ResetPaneLayout => "pane.reset_layout",
            Self::NavigateBack => "navigate.back",
            Self::NavigateForward => "navigate.forward",
            Self::ShowCommandPalette => "command_palette.show",
            Self::ShowTaskManager => "task_manager.show",
            Self::OpenWithSelectedApp => "open_with.selected_app",
            Self::OpenSelectedServer => "server.open_selected",
            Self::OpenBranchOnRemote => "branch.open_remote",
            Self::ToggleLightDarkTheme => "theme.toggle_light_dark",
            Self::UseDarkTheme => "theme.use_dark",
            Self::UseLightTheme => "theme.use_light",
            Self::UseAutoTheme => "theme.use_auto",
            Self::OpenSettings => "app.open_settings",
            Self::NewWindow => "app.new_window",
            Self::CloseWindow => "app.close_window",
            Self::CleanCopy => "clipboard.clean_copy",
            Self::CopyRaw => "clipboard.copy_raw",
            Self::ReloadConfig => "app.reload_config",
            Self::OpenBookmarksPopover => "bookmarks.openPopover",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|command_id| command_id.raw_value() == value)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShortcutCategory {
    General,
    Worklanes,
    Panes,
    Notifications,
}

impl ShortcutCategory {
    pub fn title(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::Worklanes => "Worklanes",
            Self::Panes => "Panes",
            Self::Notifications => "Notifications",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[derive(Default)]
pub enum PaneRightCommandPresentation {
    SplitsVisibly,
    #[default]
    AddsToWorklane,
}


impl PaneRightCommandPresentation {
    pub fn primary_title(self) -> &'static str {
        match self {
            Self::SplitsVisibly => "Split Right",
            Self::AddsToWorklane => "Add Pane Right",
        }
    }

    pub fn primary_detail_description(self) -> &'static str {
        match self {
            Self::SplitsVisibly => "Split the current pane area into two visible panes.",
            Self::AddsToWorklane => {
                "Add a pane to the right in the worklane without shrinking the current pane."
            }
        }
    }

    pub fn primary_icon_system_name(self) -> &'static str {
        match self {
            Self::SplitsVisibly => "rectangle.split.2x1",
            Self::AddsToWorklane => "arrow.right.square",
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CommandPaletteCommandBuildContext {
    shortcut_display_by_command_id: HashMap<AppCommandId, String>,
    focused_pane_path: Option<String>,
    focused_branch_name: Option<String>,
    right_pane_command_presentation: PaneRightCommandPresentation,
}

impl CommandPaletteCommandBuildContext {
    pub fn with_shortcut_display(
        mut self,
        command_id: AppCommandId,
        shortcut_display: impl Into<String>,
    ) -> Self {
        self.shortcut_display_by_command_id
            .insert(command_id, shortcut_display.into());
        self
    }

    pub fn with_focused_pane_path(mut self, path: impl Into<String>) -> Self {
        self.focused_pane_path = Some(path.into());
        self
    }

    pub fn with_focused_branch_name(mut self, branch_name: impl Into<String>) -> Self {
        self.focused_branch_name = Some(branch_name.into());
        self
    }

    pub fn with_right_pane_command_presentation(
        mut self,
        presentation: PaneRightCommandPresentation,
    ) -> Self {
        self.right_pane_command_presentation = presentation;
        self
    }

    pub fn shortcut_display(&self, command_id: AppCommandId) -> Option<&str> {
        self.shortcut_display_by_command_id
            .get(&command_id)
            .map(String::as_str)
    }

    pub fn focused_pane_path(&self) -> Option<&str> {
        self.focused_pane_path.as_deref()
    }

    pub fn focused_branch_name(&self) -> Option<&str> {
        self.focused_branch_name.as_deref()
    }

    pub fn right_pane_command_presentation(&self) -> PaneRightCommandPresentation {
        self.right_pane_command_presentation
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AppCommandDefinition {
    pub id: AppCommandId,
    pub title: &'static str,
    pub category: ShortcutCategory,
    pub detail_description: &'static str,
}

impl AppCommandDefinition {
    pub fn search_text(self) -> String {
        match self.id {
            AppCommandId::OpenBranchOnRemote => format!(
                "{} {} remote branch github branch gitlab branch",
                self.title, self.detail_description
            )
            .to_lowercase(),
            _ => format!("{} {}", self.title, self.detail_description).to_lowercase(),
        }
    }
}

pub struct AppCommandRegistry;

impl AppCommandRegistry {
    pub const ORDERED_IDS: [AppCommandId; 63] = [
        AppCommandId::ToggleSidebar,
        AppCommandId::NavigateBack,
        AppCommandId::NavigateForward,
        AppCommandId::NewWorklane,
        AppCommandId::RenameCurrentWorklane,
        AppCommandId::NextWorklane,
        AppCommandId::PreviousWorklane,
        AppCommandId::WorklaneMoveUp,
        AppCommandId::WorklaneMoveDown,
        AppCommandId::Find,
        AppCommandId::GlobalFind,
        AppCommandId::UseSelectionForFind,
        AppCommandId::FindNext,
        AppCommandId::FindPrevious,
        AppCommandId::CopyFocusedPanePath,
        AppCommandId::CleanCopy,
        AppCommandId::CopyRaw,
        AppCommandId::JumpToLatestNotification,
        AppCommandId::DuplicateFocusedPane,
        AppCommandId::MovePaneToNewWindow,
        AppCommandId::SplitHorizontally,
        AppCommandId::ForceSplitRight,
        AppCommandId::ForceAddPaneRight,
        AppCommandId::SplitVertically,
        AppCommandId::ArrangeWidthFull,
        AppCommandId::ArrangeWidthHalves,
        AppCommandId::ArrangeWidthThirds,
        AppCommandId::ArrangeWidthQuarters,
        AppCommandId::ArrangeHeightFull,
        AppCommandId::ArrangeHeightTwoPerColumn,
        AppCommandId::ArrangeHeightThreePerColumn,
        AppCommandId::ArrangeHeightFourPerColumn,
        AppCommandId::ArrangeWidthGoldenFocusWide,
        AppCommandId::ArrangeWidthGoldenFocusNarrow,
        AppCommandId::ArrangeHeightGoldenFocusTall,
        AppCommandId::ArrangeHeightGoldenFocusShort,
        AppCommandId::CloseFocusedPane,
        AppCommandId::RestoreClosedPane,
        AppCommandId::FocusPreviousPane,
        AppCommandId::FocusNextPane,
        AppCommandId::FocusLeftPane,
        AppCommandId::FocusRightPane,
        AppCommandId::FocusUpInColumn,
        AppCommandId::FocusDownInColumn,
        AppCommandId::ResizePaneLeft,
        AppCommandId::ResizePaneRight,
        AppCommandId::ResizePaneUp,
        AppCommandId::ResizePaneDown,
        AppCommandId::ResetPaneLayout,
        AppCommandId::ShowCommandPalette,
        AppCommandId::OpenBranchOnRemote,
        AppCommandId::ToggleLightDarkTheme,
        AppCommandId::UseDarkTheme,
        AppCommandId::UseLightTheme,
        AppCommandId::UseAutoTheme,
        AppCommandId::OpenSettings,
        AppCommandId::NewWindow,
        AppCommandId::CloseWindow,
        AppCommandId::ReloadConfig,
        AppCommandId::OpenBookmarksPopover,
        AppCommandId::ShowTaskManager,
        AppCommandId::OpenWithSelectedApp,
        AppCommandId::OpenSelectedServer,
    ];

    pub fn definition(id: AppCommandId) -> AppCommandDefinition {
        AppCommandDefinition {
            id,
            title: Self::title(id),
            category: Self::category(id),
            detail_description: Self::detail_description(id),
        }
    }

    fn title(id: AppCommandId) -> &'static str {
        match id {
            AppCommandId::ToggleSidebar => "Toggle Sidebar",
            AppCommandId::NewWorklane => "New Worklane",
            AppCommandId::RenameCurrentWorklane => "Rename Worklane\u{2026}",
            AppCommandId::NextWorklane => "Next Worklane",
            AppCommandId::PreviousWorklane => "Previous Worklane",
            AppCommandId::WorklaneMoveUp => "Move Worklane Up",
            AppCommandId::WorklaneMoveDown => "Move Worklane Down",
            AppCommandId::Find => "Find",
            AppCommandId::GlobalFind => "Global Find",
            AppCommandId::UseSelectionForFind => "Use Selection for Find",
            AppCommandId::FindNext => "Find Next",
            AppCommandId::FindPrevious => "Find Previous",
            AppCommandId::CopyFocusedPanePath => "Copy Path",
            AppCommandId::JumpToLatestNotification => "Jump To Latest Attention Item",
            AppCommandId::DuplicateFocusedPane => "Duplicate This Pane",
            AppCommandId::MovePaneToNewWindow => "Move Pane to New Window",
            AppCommandId::SplitHorizontally => "Add Pane Right",
            AppCommandId::ForceSplitRight => "Split Right Visibly",
            AppCommandId::ForceAddPaneRight => "Add Pane Right Without Resizing",
            AppCommandId::SplitVertically => "New Pane Below",
            AppCommandId::ArrangeWidthFull => "Arrange Width: Full Width",
            AppCommandId::ArrangeWidthHalves => "Arrange Width: Half Width",
            AppCommandId::ArrangeWidthThirds => "Arrange Width: Thirds",
            AppCommandId::ArrangeWidthQuarters => "Arrange Width: Quarters",
            AppCommandId::ArrangeHeightFull => "Arrange Height: Full Height",
            AppCommandId::ArrangeHeightTwoPerColumn => "Arrange Height: 2 Per Column",
            AppCommandId::ArrangeHeightThreePerColumn => "Arrange Height: 3 Per Column",
            AppCommandId::ArrangeHeightFourPerColumn => "Arrange Height: 4 Per Column",
            AppCommandId::ArrangeWidthGoldenFocusWide => {
                "Arrange Width: Golden \u{2014} Focus Wide"
            }
            AppCommandId::ArrangeWidthGoldenFocusNarrow => {
                "Arrange Width: Golden \u{2014} Focus Narrow"
            }
            AppCommandId::ArrangeHeightGoldenFocusTall => {
                "Arrange Height: Golden \u{2014} Focus Tall"
            }
            AppCommandId::ArrangeHeightGoldenFocusShort => {
                "Arrange Height: Golden \u{2014} Focus Short"
            }
            AppCommandId::CloseFocusedPane => "Close Pane",
            AppCommandId::RestoreClosedPane => "Undo Close Pane",
            AppCommandId::FocusPreviousPane => "Focus Previous Pane",
            AppCommandId::FocusNextPane => "Focus Next Pane",
            AppCommandId::FocusLeftPane => "Focus Left Pane",
            AppCommandId::FocusRightPane => "Focus Right Pane",
            AppCommandId::FocusUpInColumn => "Focus Up In Column",
            AppCommandId::FocusDownInColumn => "Focus Down In Column",
            AppCommandId::ResizePaneLeft => "Resize Pane Left",
            AppCommandId::ResizePaneRight => "Resize Pane Right",
            AppCommandId::ResizePaneUp => "Resize Pane Up",
            AppCommandId::ResizePaneDown => "Resize Pane Down",
            AppCommandId::ResetPaneLayout => "Reset Pane Layout",
            AppCommandId::NavigateBack => "Navigate Back",
            AppCommandId::NavigateForward => "Navigate Forward",
            AppCommandId::ShowCommandPalette => "Command Palette",
            AppCommandId::ShowTaskManager => "Task Manager",
            AppCommandId::OpenWithSelectedApp => "Open With Selected App",
            AppCommandId::OpenSelectedServer => "Open Selected Server",
            AppCommandId::OpenBranchOnRemote => "Open Branch on Remote",
            AppCommandId::ToggleLightDarkTheme => "Toggle Light/Dark Theme",
            AppCommandId::UseDarkTheme => "Use Dark Theme",
            AppCommandId::UseLightTheme => "Use Light Theme",
            AppCommandId::UseAutoTheme => "Use Auto Theme",
            AppCommandId::OpenSettings => "Open Settings",
            AppCommandId::NewWindow => "New Window",
            AppCommandId::CloseWindow => "Close Window",
            AppCommandId::CleanCopy => "Clean Copy",
            AppCommandId::CopyRaw => "Copy Raw",
            AppCommandId::ReloadConfig => "Reload Configuration",
            AppCommandId::OpenBookmarksPopover => "Show Bookmarks & Presets",
        }
    }

    fn category(id: AppCommandId) -> ShortcutCategory {
        match id {
            AppCommandId::NewWorklane
            | AppCommandId::RenameCurrentWorklane
            | AppCommandId::NextWorklane
            | AppCommandId::PreviousWorklane
            | AppCommandId::WorklaneMoveUp
            | AppCommandId::WorklaneMoveDown => ShortcutCategory::Worklanes,
            AppCommandId::Find
            | AppCommandId::GlobalFind
            | AppCommandId::UseSelectionForFind
            | AppCommandId::FindNext
            | AppCommandId::FindPrevious
            | AppCommandId::CopyFocusedPanePath
            | AppCommandId::DuplicateFocusedPane
            | AppCommandId::MovePaneToNewWindow
            | AppCommandId::SplitHorizontally
            | AppCommandId::ForceSplitRight
            | AppCommandId::ForceAddPaneRight
            | AppCommandId::SplitVertically
            | AppCommandId::ArrangeWidthFull
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
            | AppCommandId::CloseFocusedPane
            | AppCommandId::RestoreClosedPane
            | AppCommandId::FocusPreviousPane
            | AppCommandId::FocusNextPane
            | AppCommandId::FocusLeftPane
            | AppCommandId::FocusRightPane
            | AppCommandId::FocusUpInColumn
            | AppCommandId::FocusDownInColumn
            | AppCommandId::ResizePaneLeft
            | AppCommandId::ResizePaneRight
            | AppCommandId::ResizePaneUp
            | AppCommandId::ResizePaneDown
            | AppCommandId::ResetPaneLayout => ShortcutCategory::Panes,
            AppCommandId::JumpToLatestNotification => ShortcutCategory::Notifications,
            _ => ShortcutCategory::General,
        }
    }

    fn detail_description(id: AppCommandId) -> &'static str {
        match id {
            AppCommandId::ToggleSidebar => "Show or hide the sidebar.",
            AppCommandId::NavigateBack => "Go back to the pane you were in before.",
            AppCommandId::NavigateForward => "Go forward again after navigating back.",
            AppCommandId::NewWorklane => "Open a new worklane.",
            AppCommandId::RenameCurrentWorklane => {
                "Give the active worklane a custom name, or clear it."
            }
            AppCommandId::NextWorklane => "Switch to the next worklane.",
            AppCommandId::PreviousWorklane => "Switch to the previous worklane.",
            AppCommandId::WorklaneMoveUp => "Move the active worklane up in the sidebar.",
            AppCommandId::WorklaneMoveDown => "Move the active worklane down in the sidebar.",
            AppCommandId::Find => "Open find in the focused pane.",
            AppCommandId::GlobalFind => "Search across all panes in this window.",
            AppCommandId::UseSelectionForFind => "Find the selected text in the focused pane.",
            AppCommandId::FindNext => "Go to the next search result.",
            AppCommandId::FindPrevious => "Go to the previous search result.",
            AppCommandId::CopyFocusedPanePath => {
                "Copy the working directory path from the focused pane."
            }
            AppCommandId::CleanCopy => {
                "Copy the selected text with extra whitespace, color codes, and shell prompts removed."
            }
            AppCommandId::CopyRaw => {
                "Copy the selected text exactly as it appears, without any cleanup."
            }
            AppCommandId::JumpToLatestNotification => {
                "Go to the most recent notification, or the next waiting agent pane."
            }
            AppCommandId::DuplicateFocusedPane => {
                "Duplicate the focused pane in a new column, keeping its working directory."
            }
            AppCommandId::MovePaneToNewWindow => {
                "Move the focused pane into its own window without restarting the terminal session."
            }
            AppCommandId::SplitHorizontally => {
                "Add a pane to the right using your pane split behavior setting."
            }
            AppCommandId::ForceSplitRight => "Force a visible side-by-side split to the right.",
            AppCommandId::ForceAddPaneRight => {
                "Force adding a pane to the right without shrinking the current pane."
            }
            AppCommandId::SplitVertically => "Add a pane below in the same column.",
            AppCommandId::ArrangeWidthFull => "Give each column the full window width.",
            AppCommandId::ArrangeWidthHalves => "Set all columns to equal halves.",
            AppCommandId::ArrangeWidthThirds => "Set all columns to equal thirds.",
            AppCommandId::ArrangeWidthQuarters => "Set all columns to equal quarters.",
            AppCommandId::ArrangeHeightFull => "One pane per column, full height.",
            AppCommandId::ArrangeHeightTwoPerColumn => "Stack two panes per column.",
            AppCommandId::ArrangeHeightThreePerColumn => "Stack three panes per column.",
            AppCommandId::ArrangeHeightFourPerColumn => "Stack four panes per column.",
            AppCommandId::ArrangeWidthGoldenFocusWide => {
                "Golden ratio: focused column gets the wide side (~62%)."
            }
            AppCommandId::ArrangeWidthGoldenFocusNarrow => {
                "Golden ratio: focused column gets the narrow side (~38%)."
            }
            AppCommandId::ArrangeHeightGoldenFocusTall => {
                "Golden ratio: focused pane gets the tall side (~62%)."
            }
            AppCommandId::ArrangeHeightGoldenFocusShort => {
                "Golden ratio: focused pane gets the short side (~38%)."
            }
            AppCommandId::CloseFocusedPane => "Close the focused pane.",
            AppCommandId::RestoreClosedPane => {
                "Reopen the most recently closed pane in this window, restoring its working directory and resuming its agent session if there was one."
            }
            AppCommandId::FocusPreviousPane => {
                "Focus the previous pane, wrapping across worklanes."
            }
            AppCommandId::FocusNextPane => "Focus the next pane, wrapping across worklanes.",
            AppCommandId::FocusLeftPane => "Focus the pane to the left.",
            AppCommandId::FocusRightPane => "Focus the pane to the right.",
            AppCommandId::FocusUpInColumn => {
                "Focus the pane above, or the previous worklane at the top."
            }
            AppCommandId::FocusDownInColumn => {
                "Focus the pane below, or the next worklane at the bottom."
            }
            AppCommandId::ResizePaneLeft => "Grow the focused pane to the left.",
            AppCommandId::ResizePaneRight => "Grow the focused pane to the right.",
            AppCommandId::ResizePaneUp => "Grow the focused pane upward.",
            AppCommandId::ResizePaneDown => "Grow the focused pane downward.",
            AppCommandId::ResetPaneLayout => "Reset pane sizes to their defaults.",
            AppCommandId::ShowCommandPalette => "Open the command palette.",
            AppCommandId::ShowTaskManager => "Show CPU and memory usage for live panes.",
            AppCommandId::OpenWithSelectedApp => {
                "Open the focused pane in the selected Open With app."
            }
            AppCommandId::OpenSelectedServer => {
                "Open the selected detected server in the selected browser."
            }
            AppCommandId::OpenBranchOnRemote => {
                "Open the current branch on GitHub or your remote host."
            }
            AppCommandId::ToggleLightDarkTheme => {
                "Switch between the selected dark and light terminal themes."
            }
            AppCommandId::UseDarkTheme => "Use the selected dark terminal theme.",
            AppCommandId::UseLightTheme => "Use the selected light terminal theme.",
            AppCommandId::UseAutoTheme => "Follow macOS light and dark appearance.",
            AppCommandId::OpenSettings => "Open settings.",
            AppCommandId::NewWindow => "Open a new window.",
            AppCommandId::CloseWindow => "Close this window.",
            AppCommandId::ReloadConfig => "Reload the config file from disk.",
            AppCommandId::OpenBookmarksPopover => "Open the bookmarks and presets popover.",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommandAvailabilityContext {
    pub worklane_count: usize,
    pub active_pane_count: usize,
    pub total_pane_count: usize,
    pub active_column_count: usize,
    pub focused_column_pane_count: usize,
    pub focused_pane_has_remembered_search: bool,
    pub global_search_has_remembered_search: bool,
    pub active_worklane_has_branch_url: bool,
    pub focused_pane_can_open_with_primary: bool,
    pub active_worklane_has_primary_server: bool,
}

impl CommandAvailabilityContext {
    pub fn new(worklane_count: usize, active_pane_count: usize, total_pane_count: usize) -> Self {
        Self {
            worklane_count,
            active_pane_count,
            total_pane_count,
            active_column_count: active_pane_count,
            focused_column_pane_count: active_pane_count,
            focused_pane_has_remembered_search: false,
            global_search_has_remembered_search: false,
            active_worklane_has_branch_url: false,
            focused_pane_can_open_with_primary: false,
            active_worklane_has_primary_server: false,
        }
    }

    pub fn with_layout_counts(
        mut self,
        active_column_count: usize,
        focused_column_pane_count: usize,
    ) -> Self {
        self.active_column_count = active_column_count;
        self.focused_column_pane_count = focused_column_pane_count;
        self
    }

    pub fn with_focused_search_memory(mut self, has_remembered_search: bool) -> Self {
        self.focused_pane_has_remembered_search = has_remembered_search;
        self
    }

    pub fn with_global_search_memory(mut self, has_remembered_search: bool) -> Self {
        self.global_search_has_remembered_search = has_remembered_search;
        self
    }

    pub fn with_active_worklane_branch_url(mut self, has_branch_url: bool) -> Self {
        self.active_worklane_has_branch_url = has_branch_url;
        self
    }

    pub fn with_focused_pane_can_open_with_primary(mut self, can_open: bool) -> Self {
        self.focused_pane_can_open_with_primary = can_open;
        self
    }

    pub fn with_active_worklane_primary_server(mut self, has_primary_server: bool) -> Self {
        self.active_worklane_has_primary_server = has_primary_server;
        self
    }
}

pub struct CommandAvailabilityResolver;

impl CommandAvailabilityResolver {
    pub fn available_command_ids(context: CommandAvailabilityContext) -> HashSet<AppCommandId> {
        let mut available = AppCommandId::ALL
            .into_iter()
            .filter(|command_id| Self::is_command_available(*command_id, context))
            .collect::<HashSet<_>>();
        available.remove(&AppCommandId::ShowCommandPalette);
        available
    }

    pub fn available_command_ids_in_registry_order(
        context: CommandAvailabilityContext,
    ) -> Vec<AppCommandId> {
        let available = Self::available_command_ids(context);
        AppCommandRegistry::ORDERED_IDS
            .into_iter()
            .filter(|command_id| available.contains(command_id))
            .collect()
    }

    pub fn is_command_available(
        command_id: AppCommandId,
        context: CommandAvailabilityContext,
    ) -> bool {
        match command_id {
            AppCommandId::OpenWithSelectedApp => context.focused_pane_can_open_with_primary,
            AppCommandId::OpenSelectedServer => context.active_worklane_has_primary_server,
            AppCommandId::OpenBranchOnRemote => context.active_worklane_has_branch_url,
            AppCommandId::FindNext | AppCommandId::FindPrevious => {
                context.focused_pane_has_remembered_search
                    || context.global_search_has_remembered_search
            }
            AppCommandId::FocusPreviousPane | AppCommandId::FocusNextPane => {
                context.total_pane_count > 1
            }
            AppCommandId::CloseFocusedPane => context.active_pane_count >= 1,
            AppCommandId::DuplicateFocusedPane => context.active_pane_count >= 1,
            AppCommandId::MovePaneToNewWindow => {
                context.active_pane_count >= 1
                    && !(context.worklane_count == 1 && context.active_pane_count == 1)
            }
            AppCommandId::FocusLeftPane
            | AppCommandId::FocusRightPane
            | AppCommandId::ResizePaneLeft
            | AppCommandId::ResizePaneRight
            | AppCommandId::ResizePaneUp
            | AppCommandId::ResizePaneDown
            | AppCommandId::ResetPaneLayout => context.active_pane_count > 1,
            AppCommandId::FocusUpInColumn | AppCommandId::FocusDownInColumn => {
                context.active_pane_count > 1 || context.worklane_count > 1
            }
            AppCommandId::ArrangeWidthFull => context.active_pane_count >= 2,
            AppCommandId::ArrangeWidthHalves => context.active_column_count >= 2,
            AppCommandId::ArrangeWidthThirds => context.active_column_count >= 3,
            AppCommandId::ArrangeWidthQuarters => context.active_column_count >= 4,
            AppCommandId::ArrangeHeightFull | AppCommandId::ArrangeHeightTwoPerColumn => {
                context.active_pane_count >= 2
            }
            AppCommandId::ArrangeHeightThreePerColumn => context.active_pane_count >= 3,
            AppCommandId::ArrangeHeightFourPerColumn => context.active_pane_count >= 4,
            AppCommandId::ArrangeWidthGoldenFocusWide
            | AppCommandId::ArrangeWidthGoldenFocusNarrow => context.active_column_count >= 2,
            AppCommandId::ArrangeHeightGoldenFocusTall
            | AppCommandId::ArrangeHeightGoldenFocusShort => context.focused_column_pane_count >= 2,
            AppCommandId::WorklaneMoveUp | AppCommandId::WorklaneMoveDown => {
                context.worklane_count > 1
            }
            AppCommandId::RenameCurrentWorklane => context.worklane_count >= 1,
            AppCommandId::NextWorklane | AppCommandId::PreviousWorklane => true,
            _ => true,
        }
    }
}
