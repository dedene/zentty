use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use zentty_core::agent::{
    AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse, AgentIpcResponseResult,
    AgentSignalCommand, AgentTool, PaneListEntry,
};
use zentty_core::command_palette::{
    CommandPaletteItemGroup, CommandPaletteItemId, DetectedServer, OpenWithBuiltInTargetId,
    OpenWithResolvedTarget, OpenWithTargetKind, TaskRunnerAction, TaskRunnerDisabledReason,
    TaskRunnerSourceKind, WorklaneColor,
};
use zentty_core::commands::AppCommandId;
use zentty_core::config::AppearanceThemeMode;
use zentty_core::focus_history::PaneFocusHistory;
use zentty_core::layout::TerminalSessionRequest;
use zentty_core::restore::ClosedPaneStack;
use zentty_core::restore::PaneRestoreDraft;
use zentty_core::session_restore::{
    SaveReason, SessionRestoreDraftWindow, SessionRestoreEnvelope, WorkspaceRecipe,
    WorkspaceRecipeColumn, WorkspaceRecipePane, WorkspaceRecipeWindow, WorkspaceRecipeWorklane,
};
use zentty_core::task_runner::TaskRunnerShellActivityState;
use zentty_pty::TerminalSize;
use zentty_terminal::{
    clipboard::TerminalClipboardPaste, input::TerminalPasteMode, screen::TerminalScreen,
};
use zentty_win::app::{
    AgentIpcRuntimeEnvironment, AppCommandExecutionResult, AppLaunchPlan,
    CommandPaletteItemExecutionResult, RunningApp, RunningAppSet,
};

#[test]
fn launch_plan_restores_workspace_layout_and_rerunnable_pane_metadata() {
    let cwd = test_directory("workspace-rerunnable");
    let envelope = SessionRestoreEnvelope {
        reason: SaveReason::LiveSnapshot,
        workspace: WorkspaceRecipe {
            active_window_id: Some("window-main".to_string()),
            windows: vec![workspace_window(
                "window-main",
                &cwd,
                vec![
                    pane("pane-shell", "shell", Some("pnpm dev"), None),
                    pane("pane-agent", "Codex", None, None),
                ],
            )],
            ..WorkspaceRecipe::default()
        },
        ..SessionRestoreEnvelope::default()
    };

    let plan = AppLaunchPlan::from_envelope(&envelope);

    assert_eq!(plan.active_window_id.as_deref(), Some("window-main"));
    assert_eq!(plan.windows.len(), 1);
    let window = &plan.windows[0];
    assert_eq!(window.window_id, "window-main");
    assert_eq!(window.active_worklane_id.as_deref(), Some("main"));
    assert_eq!(window.worklanes.len(), 1);
    assert_eq!(
        window.worklanes[0].focused_pane_id.as_deref(),
        Some("pane-shell")
    );

    let shell = find_pane(&plan, "pane-shell");
    assert_eq!(shell.worklane_id, "main");
    assert_eq!(shell.column_id, "column-main");
    assert_eq!(shell.column_index, 0);
    assert_eq!(shell.pane_index, 0);
    assert_eq!(shell.column_width, 640.0);
    assert_eq!(shell.pane_height, Some(360.0));
    assert_eq!(shell.title, "shell");
    assert_eq!(
        shell.terminal_request.working_directory.as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(shell.terminal_request.command, None);
    assert_eq!(
        shell.restored_rerunnable_command.as_deref(),
        Some("pnpm dev")
    );
    assert_eq!(shell.status_text, None);

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_applies_secure_agent_restore_drafts_to_matching_panes() {
    let cwd = test_directory("agent-restore-draft");
    let envelope = SessionRestoreEnvelope {
        workspace: WorkspaceRecipe {
            active_window_id: Some("window-main".to_string()),
            windows: vec![workspace_window(
                "window-main",
                &cwd,
                vec![
                    pane("pane-agent", "Codex", None, None),
                    pane("pane-danger", "Codex", None, None),
                ],
            )],
            ..WorkspaceRecipe::default()
        },
        restore_draft_windows: vec![SessionRestoreDraftWindow {
            window_id: "window-main".to_string(),
            pane_drafts: vec![
                PaneRestoreDraft::agent_resume(
                    "pane-agent",
                    AgentTool::Codex,
                    "Codex",
                    "019e4548-2fab-7542-9d5b-378a5da96fa5",
                    Some(cwd.to_string_lossy().as_ref()),
                    4242,
                    None,
                ),
                PaneRestoreDraft::agent_resume(
                    "pane-danger",
                    AgentTool::Codex,
                    "Codex",
                    "bad;rm -rf",
                    Some(cwd.to_string_lossy().as_ref()),
                    4243,
                    None,
                ),
            ],
        }],
        ..SessionRestoreEnvelope::default()
    };

    let plan = AppLaunchPlan::from_envelope(&envelope);

    assert_eq!(
        find_pane(&plan, "pane-agent")
            .terminal_request
            .command
            .as_deref(),
        Some("codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5")
    );
    assert_eq!(
        find_pane(&plan, "pane-agent")
            .applied_restore_draft_tool
            .as_deref(),
        Some("Codex")
    );
    assert_eq!(
        find_pane(&plan, "pane-danger").terminal_request.command,
        None
    );
    assert_eq!(
        find_pane(&plan, "pane-danger").applied_restore_draft_tool,
        None
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_builds_active_window_command_palette_commands_from_layout_context() {
    let cwd = test_directory("palette-commands");
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    let mut other_worklane = minimal_pane_spec_with_id("pane-other-worklane");
    other_worklane.worklane_id = "secondary".to_string();
    other_worklane.column_id = "column-secondary".to_string();

    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "main".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-left".to_string()),
                    panes: vec![left, right],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "secondary".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-other-worklane".to_string()),
                    panes: vec![other_worklane],
                },
            ],
        }],
    };

    let items = plan.command_palette_command_items();

    assert_eq!(
        items
            .iter()
            .take(3)
            .map(|item| item.title.as_str())
            .collect::<Vec<_>>(),
        vec!["Toggle Sidebar", "Navigate Back", "Navigate Forward"]
    );
    assert!(!items.iter().any(|item| item.id
        == CommandPaletteItemId::command(AppCommandId::ShowCommandPalette.raw_value())));
    assert!(
        items.iter().any(|item| item.id
            == CommandPaletteItemId::command(AppCommandId::FocusLeftPane.raw_value()))
    );
    assert!(items.iter().any(|item| item.id
        == CommandPaletteItemId::command(AppCommandId::MovePaneToNewWindow.raw_value())));
    assert!(
        items.iter().any(|item| item.id
            == CommandPaletteItemId::command(AppCommandId::WorklaneMoveUp.raw_value()))
    );

    let copy_path = items
        .iter()
        .find(|item| {
            item.id == CommandPaletteItemId::command(AppCommandId::CopyFocusedPanePath.raw_value())
        })
        .expect("copy path command should be present");
    assert_eq!(
        copy_path.subtitle,
        format!("Copy Path \u{2014} {}", cwd.to_string_lossy())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_command_palette_items_include_settings_and_focused_restored_command() {
    let mut pane = minimal_pane_spec();
    pane.restored_rerunnable_command = Some("pnpm dev".to_string());
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-main".to_string()),
                panes: vec![pane],
            }],
        }],
    };

    let items = plan.command_palette_items();

    assert!(
        items.iter().any(|item| item.id
            == CommandPaletteItemId::command(AppCommandId::ToggleSidebar.raw_value()))
    );
    assert!(
        items
            .iter()
            .any(|item| item.id == CommandPaletteItemId::settings("appearance"))
    );

    let restored = items
        .iter()
        .find(|item| item.id == CommandPaletteItemId::restored_command("pane-main"))
        .expect("restored command item should be present");
    assert_eq!(restored.title, "Run Last Command Again");
    assert_eq!(restored.subtitle, "pnpm dev");
}

#[test]
fn launch_plan_command_palette_items_include_pane_navigation_destinations() {
    let cwd = test_directory("palette-panes");
    let mut focused = minimal_pane_spec_with_id("pane-focused");
    focused.title = "server".to_string();
    focused.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    focused.status_text = Some("running".to_string());
    let mut secondary = minimal_pane_spec_with_id("pane-secondary");
    secondary.title = "logs".to_string();
    secondary.worklane_id = "secondary".to_string();
    secondary.column_id = "column-secondary".to_string();

    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "main".to_string(),
                    title: Some("Dev".to_string()),
                    focused_pane_id: Some("pane-focused".to_string()),
                    panes: vec![focused],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "secondary".to_string(),
                    title: Some("Logs".to_string()),
                    focused_pane_id: Some("pane-secondary".to_string()),
                    panes: vec![secondary],
                },
            ],
        }],
    };

    let items = plan.command_palette_items();
    let current = items
        .iter()
        .find(|item| item.id == CommandPaletteItemId::pane("main", "pane-focused"))
        .expect("current pane should be present");

    assert_eq!(current.title, "server");
    assert_eq!(
        current.subtitle,
        format!("Dev \u{2022} {} \u{2022} running", cwd.to_string_lossy())
    );
    assert_eq!(current.category, "Current Pane");
    assert_eq!(current.group, CommandPaletteItemGroup::Pane);
    assert_eq!(current.icon_system_name, "arrow.right.square");
    assert_eq!(current.ranking_boost, 0.02);
    assert!(current.search_text.contains("server"));
    assert!(current.search_text.contains("running"));

    let other = items
        .iter()
        .find(|item| item.id == CommandPaletteItemId::pane("secondary", "pane-secondary"))
        .expect("other pane should be present");
    assert_eq!(other.subtitle, "Logs");
    assert_eq!(other.category, "Pane");
    assert_eq!(other.ranking_boost, 0.08);

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_resolves_command_palette_results_with_empty_actions_and_panes() {
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.restored_rerunnable_command = Some("pnpm dev".to_string());
    let mut logs = minimal_pane_spec_with_id("pane-logs");
    logs.title = "logs".to_string();
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-main".to_string()),
                panes: vec![pane, logs],
            }],
        }],
    };

    let empty = plan.resolve_command_palette("");

    assert_eq!(
        empty.sections.first().map(|section| section.title.as_str()),
        Some("Actions")
    );
    assert_eq!(
        empty.sections[0]
            .items
            .iter()
            .map(|item| item.item.id.clone())
            .collect::<Vec<_>>(),
        vec![
            CommandPaletteItemId::restored_command("pane-main"),
            CommandPaletteItemId::command(AppCommandId::NewWorklane.raw_value()),
            CommandPaletteItemId::command(AppCommandId::SplitHorizontally.raw_value()),
            CommandPaletteItemId::command(AppCommandId::SplitVertically.raw_value()),
            CommandPaletteItemId::command(AppCommandId::OpenSettings.raw_value()),
        ]
    );

    let typed = plan.resolve_command_palette("logs");
    assert_eq!(
        typed.items.first().map(|item| item.item.id.clone()),
        Some(CommandPaletteItemId::pane("main", "pane-logs"))
    );
}

#[test]
fn launch_plan_execute_command_moves_focus_between_columns_and_vertical_stack() {
    let mut left_top = minimal_pane_spec_with_id("pane-left-top");
    left_top.column_id = "column-left".to_string();
    left_top.column_index = 0;
    left_top.pane_index = 0;
    let mut left_bottom = minimal_pane_spec_with_id("pane-left-bottom");
    left_bottom.column_id = "column-left".to_string();
    left_bottom.column_index = 0;
    left_bottom.pane_index = 1;
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    right.pane_index = 0;

    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-left-top".to_string()),
                panes: vec![left_top, left_bottom, right],
            }],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::FocusDownInColumn),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left-bottom"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusLeftPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left-top"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusDownInColumn),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left-bottom"));
    assert_eq!(
        plan.execute_command(AppCommandId::FocusUpInColumn),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left-top"));
}

#[test]
fn launch_plan_execute_command_moves_focus_by_sidebar_order_across_worklanes() {
    let mut alpha_one = minimal_pane_spec_with_id("pane-alpha-one");
    alpha_one.worklane_id = "alpha".to_string();
    alpha_one.column_index = 0;
    alpha_one.pane_index = 0;
    let mut alpha_two = minimal_pane_spec_with_id("pane-alpha-two");
    alpha_two.worklane_id = "alpha".to_string();
    alpha_two.column_index = 1;
    alpha_two.pane_index = 0;
    let mut beta_one = minimal_pane_spec_with_id("pane-beta-one");
    beta_one.worklane_id = "beta".to_string();
    beta_one.column_index = 0;
    beta_one.pane_index = 0;
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("alpha".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "alpha".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-alpha-one".to_string()),
                    panes: vec![alpha_one, alpha_two],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "beta".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-beta-one".to_string()),
                    panes: vec![beta_one],
                },
            ],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::FocusNextPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("alpha"));
    assert_eq!(focused_pane_id(&plan), Some("pane-alpha-two"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusNextPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("beta"));
    assert_eq!(focused_pane_id(&plan), Some("pane-beta-one"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusNextPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("alpha"));
    assert_eq!(focused_pane_id(&plan), Some("pane-alpha-one"));

    assert_eq!(
        plan.execute_command(AppCommandId::FocusPreviousPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("beta"));
    assert_eq!(focused_pane_id(&plan), Some("pane-beta-one"));
}

#[test]
fn launch_plan_execute_command_navigates_back_and_forward_through_focus_history() {
    let mut pane_left = minimal_pane_spec_with_id("pane-left");
    pane_left.worklane_id = "main".to_string();
    pane_left.column_id = "column-left".to_string();
    pane_left.column_index = 0;
    let mut pane_right = minimal_pane_spec_with_id("pane-right");
    pane_right.worklane_id = "main".to_string();
    pane_right.column_id = "column-right".to_string();
    pane_right.column_index = 1;
    let mut pane_other = minimal_pane_spec_with_id("pane-other");
    pane_other.worklane_id = "other".to_string();

    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "main".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-left".to_string()),
                    panes: vec![pane_left, pane_right],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "other".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-other".to_string()),
                    panes: vec![pane_other],
                },
            ],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        plan.execute_command(AppCommandId::FocusNextPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("other"));
    assert_eq!(focused_pane_id(&plan), Some("pane-other"));

    assert_eq!(
        plan.execute_command(AppCommandId::NavigateBack),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("main"));
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));

    assert_eq!(
        plan.execute_command(AppCommandId::NavigateBack),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("main"));
    assert_eq!(focused_pane_id(&plan), Some("pane-left"));

    assert_eq!(
        plan.execute_command(AppCommandId::NavigateForward),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("main"));
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));
}

#[test]
fn launch_plan_execute_palette_item_preserves_back_forward_navigation() {
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.column_index = 0;
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    let mut plan = layout_plan("pane-left", vec![left, right]);

    assert_eq!(
        plan.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::command(
            AppCommandId::NavigateBack.raw_value()
        )),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left"));

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::command(
            AppCommandId::NavigateForward.raw_value()
        )),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));
}

#[test]
fn launch_plan_execute_command_updates_current_pane_palette_state() {
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.column_index = 0;
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-left".to_string()),
                panes: vec![left, right],
            }],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::FocusRightPane),
        AppCommandExecutionResult::Applied
    );

    let current = plan
        .command_palette_items()
        .into_iter()
        .find(|item| item.id == CommandPaletteItemId::pane("main", "pane-right"))
        .expect("right pane item should be present");
    assert_eq!(current.category, "Current Pane");
    assert_eq!(current.ranking_boost, 0.02);
}

#[test]
fn launch_plan_execute_command_splits_right_and_below_with_inherited_session_context() {
    let cwd = test_directory("split-commands");
    let mut focused = minimal_pane_spec_with_id("pane-source");
    focused.column_id = "column-left".to_string();
    focused.column_index = 0;
    focused.pane_index = 0;
    focused.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut neighbor = minimal_pane_spec_with_id("pane-neighbor");
    neighbor.column_id = "column-right".to_string();
    neighbor.column_index = 1;
    neighbor.pane_index = 0;
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-source".to_string()),
                panes: vec![focused, neighbor],
            }],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::SplitHorizontally),
        AppCommandExecutionResult::Applied
    );
    let right_split_id = focused_pane_id(&plan)
        .expect("new right pane should be focused")
        .to_string();
    assert_ne!(right_split_id, "pane-source");
    let right_split = find_pane(&plan, &right_split_id);
    assert_eq!(right_split.column_index, 1);
    assert_eq!(right_split.pane_index, 0);
    assert_eq!(
        right_split
            .terminal_request
            .inherit_from_pane_id
            .as_ref()
            .map(|id| id.as_str()),
        Some("pane-source")
    );
    assert_eq!(
        find_pane(&plan, "pane-neighbor").column_index,
        2,
        "columns to the right should shift after inserting a new right pane"
    );

    assert_eq!(
        plan.execute_command(AppCommandId::SplitVertically),
        AppCommandExecutionResult::Applied
    );
    let below_split_id = focused_pane_id(&plan).expect("new below pane should be focused");
    let below_split = find_pane(&plan, below_split_id);
    assert_eq!(below_split.column_index, 1);
    assert_eq!(below_split.pane_index, 1);
    assert_eq!(
        below_split
            .terminal_request
            .inherit_from_pane_id
            .as_ref()
            .map(|id| id.as_str()),
        Some(right_split_id.as_str())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_duplicates_and_closes_focused_pane() {
    let cwd = test_directory("duplicate-close");
    let mut source = minimal_pane_spec_with_id("pane-source");
    source.column_id = "column-left".to_string();
    source.column_index = 0;
    source.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-source".to_string()),
                panes: vec![source],
            }],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::DuplicateFocusedPane),
        AppCommandExecutionResult::Applied
    );
    let duplicate_id = focused_pane_id(&plan)
        .expect("duplicate should be focused")
        .to_string();
    assert_ne!(duplicate_id, "pane-source");
    let duplicate = find_pane(&plan, &duplicate_id);
    assert_eq!(
        duplicate.terminal_request.working_directory.as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(duplicate.terminal_request.inherit_from_pane_id, None);

    assert_eq!(
        plan.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-source"));
    assert!(
        plan.windows[0].worklanes[0]
            .panes
            .iter()
            .all(|pane| pane.pane_id != duplicate_id)
    );

    assert_eq!(
        plan.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::RequestCloseWindow {
            window_id: "window-main".to_string(),
        },
        "closing the last pane in the only worklane should request the window close layer"
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-source"));
    assert_eq!(plan.windows.len(), 1);
    assert_eq!(plan.windows[0].worklanes[0].panes.len(), 1);

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_restores_user_closed_pane_with_replay_context() {
    let cwd = test_directory("restore-closed-pane");
    let mut left = pane_in_column("pane-left", "column-left", 0, 0, 500.0, Some(1.0));
    left.title = "left".to_string();
    let mut right = pane_in_column("pane-right", "column-right", 1, 0, 900.0, Some(3.0));
    right.title = "dev server".to_string();
    right.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    right.terminal_request.native_command = Some("npm run dev".to_string());
    let mut right_bottom =
        pane_in_column("pane-right-bottom", "column-right", 1, 1, 900.0, Some(1.0));
    right_bottom.title = "logs".to_string();
    let mut plan = layout_plan("pane-right", vec![left, right, right_bottom]);

    assert_eq!(
        plan.execute_command(AppCommandId::CloseFocusedPane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-right-bottom"));
    assert!(
        plan.windows[0].worklanes[0]
            .panes
            .iter()
            .all(|pane| pane.pane_id != "pane-right")
    );

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::RestoreClosedPane)
        ),
        format!(
            "RestoredClosedPane {{ pane_id: \"restored-1\", worklane_id: \"main\", toast_message: {:?} }}",
            format!("Restored \"dev server\" at {}", cwd.to_string_lossy())
        )
    );

    let restored = find_pane(&plan, "restored-1");
    assert_eq!(restored.title, "dev server");
    assert_eq!(restored.column_id, "column-right");
    assert_eq!(restored.column_index, 1);
    assert_eq!(restored.pane_index, 0);
    assert_eq!(restored.column_width, 900.0);
    assert_eq!(restored.pane_height, Some(3.0));
    assert_eq!(find_pane(&plan, "pane-right-bottom").pane_index, 1);
    assert_eq!(
        restored.terminal_request.working_directory.as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(restored.terminal_request.native_command, None);
    assert_eq!(restored.terminal_request.command, None);
    assert_eq!(
        restored.terminal_request.prefill_text.as_deref(),
        Some("npm run dev\n")
    );
    assert_eq!(focused_pane_id(&plan), Some("restored-1"));

    assert_eq!(
        plan.execute_command(AppCommandId::RestoreClosedPane),
        AppCommandExecutionResult::Unavailable,
        "restoring consumes the closed pane entry"
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_restore_closed_pane_is_unavailable_when_stack_is_empty() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        plan.execute_command(AppCommandId::RestoreClosedPane),
        AppCommandExecutionResult::Unavailable
    );
}

#[test]
fn launch_plan_execute_command_creates_new_active_worklane_from_focused_context() {
    let cwd = test_directory("new-worklane");
    let mut source = minimal_pane_spec_with_id("pane-source");
    source.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: Some("Main".to_string()),
                focused_pane_id: Some("pane-source".to_string()),
                panes: vec![source],
            }],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::NewWorklane),
        AppCommandExecutionResult::Applied
    );

    let window = &plan.windows[0];
    assert_eq!(window.worklanes.len(), 2);
    assert_ne!(window.active_worklane_id.as_deref(), Some("main"));
    let active_worklane = window
        .worklanes
        .iter()
        .find(|worklane| {
            Some(worklane.worklane_id.as_str()) == window.active_worklane_id.as_deref()
        })
        .expect("new worklane should be active");
    assert_eq!(active_worklane.title, None);
    assert_eq!(active_worklane.panes.len(), 1);
    assert_eq!(
        active_worklane.panes[0]
            .terminal_request
            .working_directory
            .as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(
        active_worklane.focused_pane_id.as_deref(),
        Some(active_worklane.panes[0].pane_id.as_str())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_cycles_worklanes_with_wraparound() {
    let mut plan = three_worklane_plan("beta");

    assert_eq!(
        plan.execute_command(AppCommandId::NextWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("gamma"));

    assert_eq!(
        plan.execute_command(AppCommandId::NextWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("alpha"));

    assert_eq!(
        plan.execute_command(AppCommandId::PreviousWorklane),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("gamma"));
}

#[test]
fn launch_plan_execute_command_moves_active_worklane_in_sidebar_order() {
    let mut plan = three_worklane_plan("beta");

    assert_eq!(
        plan.execute_command(AppCommandId::WorklaneMoveUp),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("beta"));
    assert_eq!(worklane_ids(&plan), vec!["beta", "alpha", "gamma"]);

    assert_eq!(
        plan.execute_command(AppCommandId::WorklaneMoveDown),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(active_worklane_id(&plan), Some("beta"));
    assert_eq!(worklane_ids(&plan), vec!["alpha", "beta", "gamma"]);

    assert_eq!(
        plan.execute_command(AppCommandId::WorklaneMoveDown),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(worklane_ids(&plan), vec!["alpha", "gamma", "beta"]);
    assert_eq!(
        plan.execute_command(AppCommandId::WorklaneMoveDown),
        AppCommandExecutionResult::Unavailable,
        "last worklane cannot move down"
    );
    assert_eq!(worklane_ids(&plan), vec!["alpha", "gamma", "beta"]);
}

#[test]
fn launch_plan_execute_command_arranges_column_widths_and_golden_neighbor_pair() {
    let mut plan = layout_plan(
        "pane-middle",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 300.0, Some(480.0)),
            pane_in_column("pane-middle", "column-middle", 1, 0, 500.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 2, 0, 700.0, Some(480.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ArrangeWidthThirds),
        AppCommandExecutionResult::Applied
    );
    assert_column_widths(&plan, &[500.0, 500.0, 500.0]);

    assert_eq!(
        plan.execute_command(AppCommandId::ArrangeWidthQuarters),
        AppCommandExecutionResult::Unavailable,
        "quarters requires at least four active columns"
    );

    let mut golden_plan = layout_plan(
        "pane-right",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 300.0, Some(480.0)),
            pane_in_column("pane-middle", "column-middle", 1, 0, 500.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 2, 0, 700.0, Some(480.0)),
        ],
    );

    assert_eq!(
        golden_plan.execute_command(AppCommandId::ArrangeWidthGoldenFocusWide),
        AppCommandExecutionResult::Applied
    );
    let golden_major = golden_major_ratio();
    assert_close(find_pane(&golden_plan, "pane-left").column_width, 300.0);
    assert_close(
        find_pane(&golden_plan, "pane-right").column_width,
        1_200.0 * golden_major,
    );
    assert_close(
        find_pane(&golden_plan, "pane-middle").column_width,
        1_200.0 * (1.0 - golden_major),
    );
}

#[test]
fn launch_plan_execute_command_arranges_panes_vertically_in_reading_order() {
    let mut plan = layout_plan(
        "pane-d",
        vec![
            pane_in_column("pane-a", "column-left", 0, 0, 320.0, Some(2.0)),
            pane_in_column("pane-b", "column-left", 0, 1, 320.0, Some(4.0)),
            pane_in_column("pane-c", "column-right", 1, 0, 520.0, Some(8.0)),
            pane_in_column("pane-d", "column-right", 1, 1, 520.0, Some(16.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ArrangeHeightThreePerColumn),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        pane_layout(&plan),
        vec![
            ("pane-a", "column-left", 0, 0, 320.0, Some(1.0)),
            ("pane-b", "column-left", 0, 1, 320.0, Some(1.0)),
            ("pane-c", "column-left", 0, 2, 320.0, Some(1.0)),
            ("pane-d", "column-right", 1, 0, 520.0, Some(1.0)),
        ]
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-d"));

    let mut full_height_plan = layout_plan(
        "pane-a",
        vec![
            pane_in_column("pane-a", "column-left", 0, 0, 320.0, Some(1.0)),
            pane_in_column("pane-b", "column-left", 0, 1, 320.0, Some(1.0)),
            pane_in_column("pane-c", "column-right", 1, 0, 520.0, Some(1.0)),
            pane_in_column("pane-d", "column-right", 1, 1, 520.0, Some(1.0)),
        ],
    );

    assert_eq!(
        full_height_plan.execute_command(AppCommandId::ArrangeHeightFull),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        pane_layout(&full_height_plan),
        vec![
            ("pane-a", "column-left", 0, 0, 320.0, Some(1.0)),
            ("pane-b", "column-right", 1, 0, 520.0, Some(1.0)),
            ("pane-c", "column-pane-c", 2, 0, 520.0, Some(1.0)),
            ("pane-d", "column-pane-d", 3, 0, 520.0, Some(1.0)),
        ]
    );
}

#[test]
fn launch_plan_execute_command_applies_golden_height_to_focused_neighbor_pair() {
    let mut plan = layout_plan(
        "pane-bottom",
        vec![
            pane_in_column("pane-top", "column-main", 0, 0, 640.0, Some(100.0)),
            pane_in_column("pane-middle", "column-main", 0, 1, 640.0, Some(200.0)),
            pane_in_column("pane-bottom", "column-main", 0, 2, 640.0, Some(300.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ArrangeHeightGoldenFocusTall),
        AppCommandExecutionResult::Applied
    );
    let golden_major = golden_major_ratio();
    assert_close(find_pane(&plan, "pane-top").pane_height.unwrap(), 100.0);
    assert_close(
        find_pane(&plan, "pane-bottom").pane_height.unwrap(),
        500.0 * golden_major,
    );
    assert_close(
        find_pane(&plan, "pane-middle").pane_height.unwrap(),
        500.0 * (1.0 - golden_major),
    );
}

#[test]
fn launch_plan_execute_command_resizes_focused_column_against_neighbor() {
    let mut plan = layout_plan(
        "pane-middle",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 300.0, Some(1.0)),
            pane_in_column("pane-middle", "column-middle", 1, 0, 500.0, Some(1.0)),
            pane_in_column("pane-right", "column-right", 2, 0, 700.0, Some(1.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ResizePaneRight),
        AppCommandExecutionResult::Applied
    );
    assert_close(find_pane(&plan, "pane-left").column_width, 300.0);
    assert_close(find_pane(&plan, "pane-middle").column_width, 524.0);
    assert_close(find_pane(&plan, "pane-right").column_width, 700.0);

    assert_eq!(
        plan.execute_command(AppCommandId::ResizePaneLeft),
        AppCommandExecutionResult::Applied
    );
    assert_column_widths(&plan, &[300.0, 500.0, 700.0]);

    let mut boundary_plan = layout_plan(
        "pane-only",
        vec![pane_in_column(
            "pane-only",
            "column-only",
            0,
            0,
            640.0,
            Some(1.0),
        )],
    );
    assert_eq!(
        boundary_plan.execute_command(AppCommandId::ResizePaneRight),
        AppCommandExecutionResult::Unavailable
    );
}

#[test]
fn launch_plan_execute_command_resizes_focused_pane_height_against_neighbor() {
    let mut plan = layout_plan(
        "pane-middle",
        vec![
            pane_in_column("pane-top", "column-main", 0, 0, 640.0, Some(100.0)),
            pane_in_column("pane-middle", "column-main", 0, 1, 640.0, Some(200.0)),
            pane_in_column("pane-bottom", "column-main", 0, 2, 640.0, Some(300.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ResizePaneDown),
        AppCommandExecutionResult::Applied
    );
    assert_close(find_pane(&plan, "pane-top").pane_height.unwrap(), 100.0);
    assert_close(find_pane(&plan, "pane-middle").pane_height.unwrap(), 224.0);
    assert_close(find_pane(&plan, "pane-bottom").pane_height.unwrap(), 276.0);

    assert_eq!(
        plan.execute_command(AppCommandId::ResizePaneUp),
        AppCommandExecutionResult::Applied
    );
    assert_close(find_pane(&plan, "pane-top").pane_height.unwrap(), 100.0);
    assert_close(find_pane(&plan, "pane-middle").pane_height.unwrap(), 200.0);
    assert_close(find_pane(&plan, "pane-bottom").pane_height.unwrap(), 300.0);

    let mut single_stack_plan = layout_plan(
        "pane-left",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(1.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 320.0, Some(1.0)),
        ],
    );
    assert_eq!(
        single_stack_plan.execute_command(AppCommandId::ResizePaneDown),
        AppCommandExecutionResult::Unavailable
    );
}

#[test]
fn launch_plan_execute_command_resets_active_worklane_layout_weights() {
    let mut plan = layout_plan(
        "pane-middle",
        vec![
            pane_in_column("pane-top", "column-left", 0, 0, 300.0, Some(100.0)),
            pane_in_column("pane-middle", "column-left", 0, 1, 300.0, Some(200.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 700.0, Some(300.0)),
        ],
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ResetPaneLayout),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        pane_layout(&plan),
        vec![
            ("pane-top", "column-left", 0, 0, 640.0, Some(1.0)),
            ("pane-middle", "column-left", 0, 1, 640.0, Some(1.0)),
            ("pane-right", "column-right", 1, 0, 640.0, Some(1.0)),
        ]
    );

    assert_eq!(
        plan.execute_command(AppCommandId::ResetPaneLayout),
        AppCommandExecutionResult::Unavailable,
        "reset is idempotent when the launch plan already has default weights"
    );
}

#[test]
fn launch_plan_execute_command_moves_focused_pane_to_new_window() {
    let cwd = test_directory("move-pane-new-window");
    let left = pane_in_column("pane-left", "column-main", 0, 0, 320.0, Some(2.0));
    let mut right = pane_in_column("pane-right", "column-main", 0, 1, 320.0, Some(4.0));
    right.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-right", vec![left, right]);

    assert_eq!(
        plan.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::Applied
    );

    assert_eq!(plan.windows.len(), 2);
    assert_ne!(plan.active_window_id.as_deref(), Some("window-main"));
    let source_window = plan
        .windows
        .iter()
        .find(|window| window.window_id == "window-main")
        .expect("source window should remain");
    assert_eq!(source_window.worklanes[0].panes.len(), 1);
    assert_eq!(source_window.worklanes[0].panes[0].pane_id, "pane-left");
    assert_eq!(
        source_window.worklanes[0].focused_pane_id.as_deref(),
        Some("pane-left")
    );

    let destination_window = plan
        .windows
        .iter()
        .find(|window| Some(window.window_id.as_str()) == plan.active_window_id.as_deref())
        .expect("destination window should be active");
    assert_eq!(destination_window.worklanes.len(), 1);
    let destination_worklane = &destination_window.worklanes[0];
    assert_eq!(
        destination_window.active_worklane_id.as_deref(),
        Some(destination_worklane.worklane_id.as_str())
    );
    assert_eq!(
        destination_worklane.focused_pane_id.as_deref(),
        Some("pane-right")
    );
    assert_eq!(destination_worklane.panes.len(), 1);
    let moved = &destination_worklane.panes[0];
    assert_eq!(moved.pane_id, "pane-right");
    assert_eq!(moved.worklane_id, destination_worklane.worklane_id);
    assert_eq!(moved.column_id, "column-pane-right");
    assert_eq!(moved.column_index, 0);
    assert_eq!(moved.pane_index, 0);
    assert_eq!(moved.column_width, 640.0);
    assert_eq!(moved.pane_height, Some(1.0));
    assert_eq!(
        moved.terminal_request.working_directory.as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_moves_single_pane_worklane_to_new_window() {
    let mut alpha_pane = minimal_pane_spec_with_id("pane-alpha");
    alpha_pane.worklane_id = "alpha".to_string();
    let mut beta_pane = minimal_pane_spec_with_id("pane-beta");
    beta_pane.worklane_id = "beta".to_string();
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("alpha".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "alpha".to_string(),
                    title: Some("Alpha".to_string()),
                    focused_pane_id: Some("pane-alpha".to_string()),
                    panes: vec![alpha_pane],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "beta".to_string(),
                    title: Some("Beta".to_string()),
                    focused_pane_id: Some("pane-beta".to_string()),
                    panes: vec![beta_pane],
                },
            ],
        }],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::Applied
    );

    let source_window = plan
        .windows
        .iter()
        .find(|window| window.window_id == "window-main")
        .expect("source window should remain");
    assert_eq!(source_window.active_worklane_id.as_deref(), Some("beta"));
    assert_eq!(
        source_window
            .worklanes
            .iter()
            .map(|worklane| worklane.worklane_id.as_str())
            .collect::<Vec<_>>(),
        vec!["beta"]
    );

    let destination_window = plan
        .windows
        .iter()
        .find(|window| Some(window.window_id.as_str()) == plan.active_window_id.as_deref())
        .expect("destination window should be active");
    assert_eq!(destination_window.worklanes.len(), 1);
    assert_eq!(destination_window.worklanes[0].worklane_id, "alpha");
    assert_eq!(
        destination_window.worklanes[0].title.as_deref(),
        Some("Alpha")
    );
    assert_eq!(
        destination_window.worklanes[0].focused_pane_id.as_deref(),
        Some("pane-alpha")
    );
}

#[test]
fn launch_plan_execute_command_refuses_to_move_the_only_pane_to_new_window() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let before = plan.clone();

    assert_eq!(
        plan.execute_command(AppCommandId::MovePaneToNewWindow),
        AppCommandExecutionResult::Unavailable
    );
    assert_eq!(plan, before);
}

#[test]
fn launch_plan_execute_command_creates_new_active_window_from_focused_context() {
    let cwd = test_directory("new-window");
    let mut source = minimal_pane_spec_with_id("pane-source");
    source.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-source", vec![source]);

    assert_eq!(
        plan.execute_command(AppCommandId::NewWindow),
        AppCommandExecutionResult::Applied
    );

    assert_eq!(plan.windows.len(), 2);
    assert_ne!(plan.active_window_id.as_deref(), Some("window-main"));
    let new_window = plan
        .windows
        .iter()
        .find(|window| Some(window.window_id.as_str()) == plan.active_window_id.as_deref())
        .expect("new window should be active");
    assert_eq!(new_window.worklanes.len(), 1);
    let worklane = &new_window.worklanes[0];
    assert_eq!(
        new_window.active_worklane_id.as_deref(),
        Some(worklane.worklane_id.as_str())
    );
    assert_eq!(worklane.title, None);
    assert_eq!(worklane.panes.len(), 1);
    assert_eq!(
        worklane.focused_pane_id.as_deref(),
        Some(worklane.panes[0].pane_id.as_str())
    );
    assert_eq!(worklane.panes[0].worklane_id, worklane.worklane_id);
    assert_eq!(worklane.panes[0].column_index, 0);
    assert_eq!(worklane.panes[0].pane_index, 0);
    assert_eq!(worklane.panes[0].column_width, 640.0);
    assert_eq!(
        worklane.panes[0]
            .terminal_request
            .working_directory
            .as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_closes_active_window_and_falls_back() {
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-beta".to_string()),
        windows: vec![
            zentty_win::app::WindowLaunchPlan {
                window_id: "window-alpha".to_string(),
                active_worklane_id: Some("alpha".to_string()),
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
                worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "alpha".to_string(),
                    title: Some("Alpha".to_string()),
                    focused_pane_id: Some("pane-alpha".to_string()),
                    panes: vec![minimal_pane_spec_with_id("pane-alpha")],
                }],
            },
            zentty_win::app::WindowLaunchPlan {
                window_id: "window-beta".to_string(),
                active_worklane_id: Some("beta".to_string()),
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
                worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "beta".to_string(),
                    title: Some("Beta".to_string()),
                    focused_pane_id: Some("pane-beta".to_string()),
                    panes: vec![minimal_pane_spec_with_id("pane-beta")],
                }],
            },
        ],
    };

    assert_eq!(
        plan.execute_command(AppCommandId::CloseWindow),
        AppCommandExecutionResult::Applied
    );

    assert_eq!(plan.windows.len(), 1);
    assert_eq!(plan.windows[0].window_id, "window-alpha");
    assert_eq!(plan.active_window_id.as_deref(), Some("window-alpha"));

    assert_eq!(
        plan.execute_command(AppCommandId::CloseWindow),
        AppCommandExecutionResult::Unavailable,
        "the launch plan refuses to close the last remaining window"
    );
    assert_eq!(plan.windows.len(), 1);
    assert_eq!(plan.active_window_id.as_deref(), Some("window-alpha"));
}

#[test]
fn launch_plan_execute_command_returns_ui_handoff_results() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    let cases = [
        (AppCommandId::ToggleSidebar, "ToggleSidebar"),
        (AppCommandId::ShowCommandPalette, "ShowCommandPalette"),
        (AppCommandId::ShowTaskManager, "ShowTaskManager"),
        (
            AppCommandId::OpenSettings,
            "ShowSettings { section: \"general\" }",
        ),
        (AppCommandId::ReloadConfig, "ReloadConfiguration"),
        (AppCommandId::OpenBookmarksPopover, "OpenBookmarksPopover"),
        (
            AppCommandId::ToggleLightDarkTheme,
            "SetThemeMode { mode: \"toggleLightDark\" }",
        ),
        (
            AppCommandId::UseDarkTheme,
            "SetThemeMode { mode: \"dark\" }",
        ),
        (
            AppCommandId::UseLightTheme,
            "SetThemeMode { mode: \"light\" }",
        ),
        (
            AppCommandId::UseAutoTheme,
            "SetThemeMode { mode: \"auto\" }",
        ),
    ];

    for (command_id, expected_debug) in cases {
        assert_eq!(
            format!("{:?}", plan.execute_command(command_id)),
            expected_debug,
            "{command_id:?} should return an explicit UI handoff result"
        );
    }
}

#[test]
fn launch_plan_execute_palette_item_for_ui_commands_preserves_handoff_results() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::OpenSettings.raw_value()
            ))
        ),
        "ShowSettings { section: \"general\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::ToggleLightDarkTheme.raw_value()
            ))
        ),
        "SetThemeMode { mode: \"toggleLightDark\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::OpenBookmarksPopover.raw_value()
            ))
        ),
        "OpenBookmarksPopover"
    );
}

#[test]
fn launch_plan_execute_command_returns_clipboard_and_search_results() {
    let cwd = test_directory("clipboard-search");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);

    let cases = [
        (
            AppCommandId::Find,
            "ShowPaneSearch { pane_id: \"pane-main\" }".to_string(),
        ),
        (AppCommandId::GlobalFind, "ShowGlobalSearch".to_string()),
        (
            AppCommandId::UseSelectionForFind,
            "UseSelectionForFind { pane_id: \"pane-main\" }".to_string(),
        ),
        (
            AppCommandId::FindNext,
            "FindNext { pane_id: \"pane-main\" }".to_string(),
        ),
        (
            AppCommandId::FindPrevious,
            "FindPrevious { pane_id: \"pane-main\" }".to_string(),
        ),
        (
            AppCommandId::CleanCopy,
            "CopySelection { mode: \"clean\" }".to_string(),
        ),
        (
            AppCommandId::CopyRaw,
            "CopySelection { mode: \"raw\" }".to_string(),
        ),
        (
            AppCommandId::CopyFocusedPanePath,
            format!(
                "CopyText {{ text: {:?} }}",
                cwd.to_string_lossy().to_string()
            ),
        ),
    ];

    for (command_id, expected_debug) in cases {
        assert_eq!(
            format!("{:?}", plan.execute_command(command_id)),
            expected_debug,
            "{command_id:?} should return a typed clipboard/search result"
        );
    }

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_refuses_to_copy_missing_focused_pane_path() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        plan.execute_command(AppCommandId::CopyFocusedPanePath),
        AppCommandExecutionResult::Unavailable
    );
}

#[test]
fn launch_plan_execute_palette_item_preserves_clipboard_and_search_results() {
    let cwd = test_directory("palette-clipboard-search");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::CopyFocusedPanePath.raw_value()
            ))
        ),
        format!(
            "CopyText {{ text: {:?} }}",
            cwd.to_string_lossy().to_string()
        )
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::Find.raw_value()
            ))
        ),
        "ShowPaneSearch { pane_id: \"pane-main\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::CleanCopy.raw_value()
            ))
        ),
        "CopySelection { mode: \"clean\" }"
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_returns_navigation_handoff_results() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(active_worklane_id(&plan), Some("main"));
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::RenameCurrentWorklane)
        ),
        "BeginRenameWorklane { worklane_id: \"main\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::JumpToLatestNotification)
        ),
        "JumpToLatestNotification"
    );
}

#[test]
fn launch_plan_execute_palette_item_preserves_navigation_handoff_results() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::RenameCurrentWorklane.raw_value()
            ))
        ),
        "BeginRenameWorklane { worklane_id: \"main\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::JumpToLatestNotification.raw_value()
            ))
        ),
        "JumpToLatestNotification"
    );
}

#[test]
fn launch_plan_execute_command_returns_open_context_results() {
    let cwd = test_directory("open-context");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    plan.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "vscode",
        OpenWithTargetKind::Editor,
        "Visual Studio Code",
        Some(OpenWithBuiltInTargetId::VsCode),
        Some("C:\\Program Files\\Microsoft VS Code\\Code.exe"),
    )];
    plan.windows[0].detected_servers = vec![DetectedServer::new(
        "server-5173",
        "http://localhost:5173",
        "http://localhost:5173/",
        "localhost:5173",
    )];
    plan.windows[0].branch_urls_by_pane_id.insert(
        "pane-main".to_string(),
        "https://github.com/ucsandman/zentty/tree/feature/windows".to_string(),
    );

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::OpenWithSelectedApp)
        ),
        format!(
            "OpenPathWithTarget {{ path: {:?}, target_id: \"vscode\", target_name: \"Visual Studio Code\", app_path: Some(\"C:\\\\Program Files\\\\Microsoft VS Code\\\\Code.exe\") }}",
            cwd.to_string_lossy().to_string()
        )
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::OpenSelectedServer)
        ),
        "OpenServer { server_id: \"server-5173\", origin: \"http://localhost:5173\", url: \"http://localhost:5173/\" }"
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_command(AppCommandId::OpenBranchOnRemote)
        ),
        "OpenUrl { url: \"https://github.com/ucsandman/zentty/tree/feature/windows\" }"
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_command_palette_items_and_execution_include_open_context() {
    let cwd = test_directory("palette-open-context");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    plan.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "cursor",
        OpenWithTargetKind::Editor,
        "Cursor",
        Some(OpenWithBuiltInTargetId::Cursor),
        None,
    )];
    plan.windows[0].detected_servers = vec![DetectedServer::new(
        "server-3000",
        "http://localhost:3000",
        "http://localhost:3000/",
        "localhost:3000",
    )];
    plan.windows[0].branch_urls_by_pane_id.insert(
        "pane-main".to_string(),
        "https://github.com/ucsandman/zentty/tree/main".to_string(),
    );

    let item_ids = plan
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(item_ids.contains(&CommandPaletteItemId::open_with("cursor")));
    assert!(item_ids.contains(&CommandPaletteItemId::server("server-3000")));
    assert!(item_ids.contains(&CommandPaletteItemId::command(
        AppCommandId::OpenWithSelectedApp.raw_value()
    )));
    assert!(item_ids.contains(&CommandPaletteItemId::command(
        AppCommandId::OpenSelectedServer.raw_value()
    )));
    assert!(item_ids.contains(&CommandPaletteItemId::command(
        AppCommandId::OpenBranchOnRemote.raw_value()
    )));

    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::open_with("cursor"))
        ),
        format!(
            "OpenPathWithTarget {{ path: {:?}, target_id: \"cursor\", target_name: \"Cursor\", app_path: None }}",
            cwd.to_string_lossy().to_string()
        )
    );
    assert_eq!(
        format!(
            "{:?}",
            plan.execute_palette_item(&CommandPaletteItemId::server("server-3000"))
        ),
        "OpenServer { server_id: \"server-3000\", origin: \"http://localhost:3000\", url: \"http://localhost:3000/\" }"
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_execute_command_open_context_is_unavailable_without_context() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        plan.execute_command(AppCommandId::OpenWithSelectedApp),
        AppCommandExecutionResult::Unavailable
    );
    assert_eq!(
        plan.execute_command(AppCommandId::OpenSelectedServer),
        AppCommandExecutionResult::Unavailable
    );
    assert_eq!(
        plan.execute_command(AppCommandId::OpenBranchOnRemote),
        AppCommandExecutionResult::Unavailable
    );
}

#[test]
fn launch_plan_execute_palette_item_dispatches_commands_and_pane_navigation() {
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.column_index = 0;
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-left".to_string()),
                panes: vec![left, right],
            }],
        }],
    };

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::command(
            AppCommandId::FocusRightPane.raw_value()
        )),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-right"));

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::pane("main", "pane-left")),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-left"));
}

#[test]
fn launch_plan_execute_palette_item_preserves_last_pane_close_window_request() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::command(
            AppCommandId::CloseFocusedPane.raw_value()
        )),
        CommandPaletteItemExecutionResult::RequestCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(focused_pane_id(&plan), Some("pane-main"));
    assert_eq!(plan.windows[0].worklanes[0].panes.len(), 1);
}

#[test]
fn launch_plan_execute_palette_item_can_create_new_worklane() {
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-main".to_string()),
                panes: vec![minimal_pane_spec()],
            }],
        }],
    };

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::command(
            AppCommandId::NewWorklane.raw_value()
        )),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(plan.windows[0].worklanes.len(), 2);
}

#[test]
fn launch_plan_execute_palette_item_resolves_restored_commands_and_settings() {
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.restored_rerunnable_command = Some("pnpm dev".to_string());
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-main".to_string()),
                panes: vec![pane],
            }],
        }],
    };

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::restored_command("pane-main")),
        CommandPaletteItemExecutionResult::RunRestoredCommand {
            pane_id: "pane-main".to_string(),
            command: "pnpm dev".to_string(),
        }
    );
    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::settings("appearance")),
        CommandPaletteItemExecutionResult::ShowSettings {
            section: "appearance".to_string(),
        }
    );
}

#[test]
fn launch_plan_command_palette_items_and_execution_include_worklane_colors() {
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);

    let item_ids = plan
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(
        item_ids.contains(&CommandPaletteItemId::worklane_color(Some(
            WorklaneColor::Blue.raw_value()
        )))
    );
    assert!(item_ids.contains(&CommandPaletteItemId::worklane_color(None::<&str>)));

    assert_eq!(plan.windows[0].active_worklane_color(), None);
    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::worklane_color(Some(
            WorklaneColor::Blue.raw_value()
        ))),
        CommandPaletteItemExecutionResult::SetWorklaneColor {
            worklane_id: "main".to_string(),
            color: Some("blue".to_string()),
        }
    );
    assert_eq!(
        plan.windows[0].active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );
    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::worklane_color(None::<&str>)),
        CommandPaletteItemExecutionResult::SetWorklaneColor {
            worklane_id: "main".to_string(),
            color: None,
        }
    );
    assert_eq!(plan.windows[0].active_worklane_color(), None);
}

#[test]
fn launch_plan_command_palette_items_and_execution_include_task_runners() {
    let cwd = test_directory("task-runner-launch");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    let enabled = TaskRunnerAction::new(
        "package|task-runner-launch/package.json|dev",
        "dev",
        None,
        TaskRunnerSourceKind::PackageScript,
        cwd.join("package.json").to_string_lossy(),
        "pnpm run dev",
        None,
    )
    .with_working_directory(cwd.to_string_lossy())
    .with_environment("NODE_ENV", "test");
    let disabled = TaskRunnerAction::new(
        "taskfile|task-runner-launch/Taskfile.yml|deploy",
        "deploy",
        None,
        TaskRunnerSourceKind::Taskfile,
        cwd.join("Taskfile.yml").to_string_lossy(),
        "task deploy",
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: TARGET",
        )),
    );
    plan.windows[0].task_runner_actions = vec![enabled.clone(), disabled.clone()];

    let item_ids = plan
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(item_ids.contains(&CommandPaletteItemId::task_runner(&enabled.id)));
    assert!(item_ids.contains(&CommandPaletteItemId::task_runner(&disabled.id)));

    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::task_runner(&enabled.id)),
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: "pane-2".to_string(),
            command: "pnpm run dev".to_string(),
        }
    );
    let launched = plan.windows[0]
        .worklanes
        .iter()
        .flat_map(|worklane| &worklane.panes)
        .find(|pane| pane.pane_id == "pane-2")
        .expect("task runner should launch a new pane");
    assert_eq!(
        launched.terminal_request.command.as_deref(),
        Some("pnpm run dev")
    );
    assert_eq!(
        launched.terminal_request.working_directory.as_deref(),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(
        launched.terminal_request.environment_variables,
        vec![("NODE_ENV".to_string(), "test".to_string())]
    );
    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::task_runner(&disabled.id)),
        CommandPaletteItemExecutionResult::OpenTaskRunnerSource {
            source_path: cwd.join("Taskfile.yml").to_string_lossy().to_string(),
        }
    );
    assert_eq!(
        plan.execute_palette_item(&CommandPaletteItemId::task_runner("missing")),
        CommandPaletteItemExecutionResult::Unavailable
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn launch_plan_can_refresh_task_runner_actions_from_focused_pane_directory() {
    let cwd = test_directory("task-runner-refresh");
    fs::write(
        cwd.join("package.json"),
        r#"{
          "packageManager": "pnpm@10.0.0",
          "scripts": { "dev": "vite" }
        }"#,
    )
    .expect("package.json should be written");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);

    assert_eq!(plan.windows[0].refresh_task_runner_actions(), 1);

    let task_item_id = CommandPaletteItemId::task_runner(format!(
        "packageScript|{}|dev",
        cwd.join("package.json").to_string_lossy()
    ));
    assert!(
        plan.windows[0]
            .command_palette_items()
            .iter()
            .any(|item| item.id == task_item_id)
    );
    assert_eq!(
        plan.execute_palette_item(&task_item_id),
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: "pane-2".to_string(),
            command: "pnpm run dev".to_string(),
        }
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn pane_pty_request_preserves_cwd_and_env_without_auto_running_prefill_text() {
    let cwd = test_directory("pty-request-prefill");
    let mut spec = minimal_pane_spec();
    spec.terminal_request = TerminalSessionRequest {
        working_directory: Some(cwd.to_string_lossy().to_string()),
        prefill_text: Some("rm -rf should-not-run".to_string()),
        environment_variables: vec![("ZENTTY_TEST_MARKER".to_string(), "1".to_string())],
        ..TerminalSessionRequest::default()
    };

    let request = spec.pty_request();

    assert!(!request.program().trim().is_empty());
    assert_eq!(
        request.working_directory().map(String::as_str),
        Some(cwd.to_string_lossy().as_ref())
    );
    assert_eq!(
        request
            .environment()
            .get("ZENTTY_TEST_MARKER")
            .map(String::as_str),
        Some("1")
    );
    assert!(
        request
            .args()
            .iter()
            .all(|arg| !arg.contains("should-not-run")),
        "prefill text must stay out of process launch args: {:?}",
        request.args()
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
fn pane_pty_request_runs_auto_command_through_shell_args() {
    let mut spec = minimal_pane_spec();
    spec.terminal_request.command =
        Some("codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5".to_string());

    let request = spec.pty_request();

    assert!(!request.program().trim().is_empty());
    assert!(
        request
            .args()
            .iter()
            .any(|arg| arg == "codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5"),
        "auto command should be present exactly once in shell args: {:?}",
        request.args()
    );

    #[cfg(windows)]
    assert_eq!(
        request.args(),
        &[
            "/d".to_string(),
            "/s".to_string(),
            "/k".to_string(),
            "codex resume 019e4548-2fab-7542-9d5b-378a5da96fa5".to_string()
        ]
    );
}

#[test]
#[cfg(windows)]
fn pane_launch_spec_spawns_conpty_for_auto_command() {
    let mut spec = minimal_pane_spec();
    spec.terminal_request.command = Some("echo ZENTTY_APP_SPAWN_SMOKE & exit".to_string());

    let session = spec
        .spawn_pty(TerminalSize::new(80, 24))
        .expect("pane launch spec should spawn ConPTY");
    let output = session
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("auto command should exit");

    assert!(
        output.output.contains("ZENTTY_APP_SPAWN_SMOKE"),
        "output was: {:?}",
        output.output
    );
}

#[test]
fn pane_pty_request_injects_agent_ipc_environment_after_user_env() {
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.environment_variables = vec![
        ("USER_MARKER".to_string(), "kept".to_string()),
        ("ZENTTY_PANE_ID".to_string(), "spoofed".to_string()),
        ("ZENTTY_PANE_TOKEN".to_string(), "spoofed-token".to_string()),
    ];
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-test",
        r"C:\Zentty\zentty-win.exe",
        "instance-1",
    )
    .with_pane_token(
        Some("window-main"),
        "main",
        "pane-main",
        "pane-secret-token",
    );
    let request = pane.pty_request_with_agent_ipc(
        Some("window-main"),
        ipc_environment
            .pane_environment(Some("window-main"), &pane)
            .as_ref(),
    );

    let environment = request.environment();
    assert_eq!(
        environment.get("USER_MARKER").map(String::as_str),
        Some("kept")
    );
    assert_eq!(
        environment.get("ZENTTY_WINDOW_ID").map(String::as_str),
        Some("window-main")
    );
    assert_eq!(
        environment.get("ZENTTY_WORKLANE_ID").map(String::as_str),
        Some("main")
    );
    assert_eq!(
        environment.get("ZENTTY_PANE_ID").map(String::as_str),
        Some("pane-main")
    );
    assert_eq!(
        environment
            .get("ZENTTY_INSTANCE_SOCKET")
            .map(String::as_str),
        Some(r"\\.\pipe\zentty-test")
    );
    assert_eq!(
        environment.get("ZENTTY_PANE_TOKEN").map(String::as_str),
        Some("pane-secret-token")
    );
    assert_eq!(
        environment.get("ZENTTY_CLI_BIN").map(String::as_str),
        Some(r"C:\Zentty\zentty-win.exe")
    );
    assert_eq!(
        environment.get("ZENTTY_INSTANCE_ID").map(String::as_str),
        Some("instance-1")
    );
}

#[test]
#[cfg(windows)]
fn running_app_spawns_all_panes_and_preserves_pane_identity() {
    let mut first = minimal_pane_spec_with_id("pane-one");
    first.terminal_request.command = Some("echo ZENTTY_PANE_ONE & exit".to_string());
    let mut second = minimal_pane_spec_with_id("pane-two");
    second.terminal_request.command = Some("echo ZENTTY_PANE_TWO & exit".to_string());
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };

    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(output_one.output.contains("ZENTTY_PANE_ONE"));
    assert!(output_two.output.contains("ZENTTY_PANE_TWO"));
    assert!(running.take_pane("pane-one").is_none());
}

#[test]
#[cfg(windows)]
fn running_app_spawn_with_agent_ipc_environment_exposes_target_and_token_to_child_shell() {
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.environment_variables.push((
        "ZENTTY_PANE_TOKEN".to_string(),
        "spoofed-before-injection".to_string(),
    ));
    pane.terminal_request.command = Some(
        "echo %ZENTTY_WINDOW_ID% %ZENTTY_WORKLANE_ID% %ZENTTY_PANE_ID% %ZENTTY_INSTANCE_SOCKET% %ZENTTY_PANE_TOKEN% %ZENTTY_CLI_BIN% %ZENTTY_INSTANCE_ID% & exit"
            .to_string(),
    );
    let plan = layout_plan("pane-main", vec![pane]);
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-runtime-test",
        r"C:\Zentty\zentty-win.exe",
        "runtime-instance",
    )
    .with_pane_token(
        Some("window-main"),
        "main",
        "pane-main",
        "runtime-pane-token",
    );

    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn pane with ipc env");
    let output = running
        .take_pane("pane-main")
        .expect("pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane should exit");

    assert!(
        output.output.contains(
            r"window-main main pane-main \\.\pipe\zentty-runtime-test runtime-pane-token C:\Zentty\zentty-win.exe runtime-instance"
        ),
        "output: {}",
        output.output
    );
    assert!(!output.output.contains("spoofed-before-injection"));
}

#[test]
#[cfg(windows)]
fn running_app_routes_input_to_focused_and_named_panes() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    running
        .write_to_focused(b"echo ZENTTY_FOCUSED_PANE\rexit\r")
        .expect("focused pane should accept input");
    running
        .write_to_pane("pane-one", b"echo ZENTTY_NAMED_PANE\rexit\r")
        .expect("named pane should accept input");
    running
        .resize_focused(TerminalSize::new(100, 30))
        .expect("focused pane should resize");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(output_one.output.contains("ZENTTY_NAMED_PANE"));
    assert!(!output_one.output.contains("ZENTTY_FOCUSED_PANE"));
    assert!(output_two.output.contains("ZENTTY_FOCUSED_PANE"));
    assert!(!output_two.output.contains("ZENTTY_NAMED_PANE"));
}

#[test]
#[cfg(windows)]
fn running_app_applies_focus_commands_before_routing_input() {
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.column_index = 0;
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    let plan = layout_plan("pane-left", vec![left, right]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    assert_eq!(running.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        running
            .execute_command(AppCommandId::FocusRightPane)
            .expect("focus command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-right"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_FOCUS_RIGHT\rexit\r")
        .expect("newly focused pane should accept input");
    running
        .write_to_pane("pane-left", b"echo ZENTTY_RUNTIME_LEFT\rexit\r")
        .expect("original pane should accept named input");

    let output_left = running
        .take_pane("pane-left")
        .expect("left pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("left pane should exit");
    let output_right = running
        .take_pane("pane-right")
        .expect("right pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("right pane should exit");

    assert!(output_left.output.contains("ZENTTY_RUNTIME_LEFT"));
    assert!(!output_left.output.contains("ZENTTY_RUNTIME_FOCUS_RIGHT"));
    assert!(output_right.output.contains("ZENTTY_RUNTIME_FOCUS_RIGHT"));
    assert!(!output_right.output.contains("ZENTTY_RUNTIME_LEFT"));
}

#[test]
#[cfg(windows)]
fn running_app_closes_focused_pane_and_routes_input_to_fallback() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::CloseFocusedPane)
            .expect("close command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.pane_ids(), vec!["pane-one"]);
    assert_eq!(running.focused_pane_id(), Some("pane-one"));
    assert!(running.take_pane("pane-two").is_none());

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_AFTER_CLOSE\rexit\r")
        .expect("fallback pane should accept focused input after close");
    let output = running
        .take_pane("pane-one")
        .expect("fallback pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("fallback pane should exit");

    assert!(output.output.contains("ZENTTY_RUNTIME_AFTER_CLOSE"));
}

#[test]
#[cfg(windows)]
fn running_app_restores_last_closed_pane_as_live_pty() {
    let first = minimal_pane_spec_with_id("pane-one");
    let mut second = minimal_pane_spec_with_id("pane-two");
    second.terminal_request.environment_variables.push((
        "ZENTTY_RUNTIME_RESTORE_ENV".to_string(),
        "restored".to_string(),
    ));
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::CloseFocusedPane)
            .expect("close command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.pane_ids(), vec!["pane-one"]);
    assert_eq!(
        running
            .execute_command(AppCommandId::RestoreClosedPane)
            .expect("restore command should execute"),
        AppCommandExecutionResult::RestoredClosedPane {
            pane_id: "pane-two".to_string(),
            worklane_id: "main".to_string(),
            toast_message: "Restored \"shell\"".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_RESTORED %ZENTTY_RUNTIME_RESTORE_ENV%\rexit\r")
        .expect("restored pane should accept focused input");
    running
        .write_to_pane("pane-one", b"echo ZENTTY_RUNTIME_RESTORE_SURVIVOR\rexit\r")
        .expect("surviving pane should remain usable");

    let survivor_output = running
        .take_pane("pane-one")
        .expect("surviving pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("surviving pane should exit");
    let restored_output = running
        .take_pane("pane-two")
        .expect("restored pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("restored pane should exit");

    assert!(
        survivor_output
            .output
            .contains("ZENTTY_RUNTIME_RESTORE_SURVIVOR")
    );
    assert!(!survivor_output.output.contains("ZENTTY_RUNTIME_RESTORED"));
    assert!(restored_output.output.contains("ZENTTY_RUNTIME_RESTORED"));
    assert!(restored_output.output.contains("restored"));
    assert!(
        !restored_output
            .output
            .contains("ZENTTY_RUNTIME_RESTORE_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_close_last_pane_requests_window_close_without_removing_pane() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn the only pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::CloseFocusedPane)
            .expect("close command should execute"),
        AppCommandExecutionResult::RequestCloseWindow {
            window_id: "window-main".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-main"]);
    assert_eq!(running.focused_pane_id(), Some("pane-main"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_LAST_PANE_STILL_OPEN\rexit\r")
        .expect("last pane should still accept focused input");
    let output = running
        .take_pane("pane-main")
        .expect("last pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("last pane should exit");

    assert!(
        output
            .output
            .contains("ZENTTY_RUNTIME_LAST_PANE_STILL_OPEN")
    );
}

#[test]
#[cfg(windows)]
fn running_app_detaches_focused_pane_to_new_window_without_respawning_pty() {
    let plan = layout_plan(
        "pane-right",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");
    running
        .write_to_focused(b"set ZENTTY_TRANSFER_STATE=transferred\r")
        .expect("focused pane should accept pre-transfer state");

    let mut detached = running
        .detach_focused_pane_to_new_window()
        .expect("focused pane should detach into a new running window");

    assert_eq!(running.pane_ids(), vec!["pane-left"]);
    assert_eq!(running.focused_pane_id(), Some("pane-left"));
    assert_eq!(detached.pane_ids(), vec!["pane-right"]);
    assert_eq!(detached.focused_pane_id(), Some("pane-right"));

    running
        .write_to_focused(b"echo ZENTTY_TRANSFER_SOURCE\rexit\r")
        .expect("source window should keep its surviving pane live");
    detached
        .write_to_focused(b"echo ZENTTY_TRANSFER_DEST %ZENTTY_TRANSFER_STATE%\rexit\r")
        .expect("detached window should keep the moved pane live");

    let source_output = running
        .take_pane("pane-left")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let detached_output = detached
        .take_pane("pane-right")
        .expect("detached pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("detached pane should exit");

    assert!(source_output.output.contains("ZENTTY_TRANSFER_SOURCE"));
    assert!(!source_output.output.contains("ZENTTY_TRANSFER_DEST"));
    assert!(detached_output.output.contains("ZENTTY_TRANSFER_DEST"));
    assert!(detached_output.output.contains("transferred"));
    assert!(!detached_output.output.contains("ZENTTY_TRANSFER_SOURCE"));
}

#[test]
#[cfg(windows)]
fn running_app_refuses_to_detach_only_pane_to_new_window() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn the only pane");

    assert!(running.detach_focused_pane_to_new_window().is_none());
    assert_eq!(running.pane_ids(), vec!["pane-main"]);
    assert_eq!(running.focused_pane_id(), Some("pane-main"));

    running
        .write_to_focused(b"echo ZENTTY_TRANSFER_ONLY_PANE\rexit\r")
        .expect("only pane should remain live after refused detach");
    let output = running
        .take_pane("pane-main")
        .expect("only pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("only pane should exit");

    assert!(output.output.contains("ZENTTY_TRANSFER_ONLY_PANE"));
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_move_pane_to_new_window_without_respawning_pty() {
    let plan = layout_plan(
        "pane-right",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn panes");

    running
        .active_window_mut()
        .expect("active source window should exist")
        .write_to_focused(b"set ZENTTY_SET_TRANSFER_STATE=carried\r")
        .expect("focused pane should accept pre-transfer state");

    assert_eq!(
        running
            .execute_command(AppCommandId::MovePaneToNewWindow)
            .expect("move-pane command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    let mut source = running
        .take_window("window-main")
        .expect("source window should remain running");
    let mut destination = running
        .take_window("window-2")
        .expect("destination window should be running");
    assert_eq!(source.pane_ids(), vec!["pane-left"]);
    assert_eq!(source.focused_pane_id(), Some("pane-left"));
    assert_eq!(destination.pane_ids(), vec!["pane-right"]);
    assert_eq!(destination.focused_pane_id(), Some("pane-right"));

    source
        .write_to_focused(b"echo ZENTTY_SET_SOURCE\rexit\r")
        .expect("source pane should remain live");
    destination
        .write_to_focused(b"echo ZENTTY_SET_DEST %ZENTTY_SET_TRANSFER_STATE%\rexit\r")
        .expect("destination pane should remain live");

    let source_output = source
        .take_pane("pane-left")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let destination_output = destination
        .take_pane("pane-right")
        .expect("destination pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("destination pane should exit");

    assert!(source_output.output.contains("ZENTTY_SET_SOURCE"));
    assert!(!source_output.output.contains("ZENTTY_SET_DEST"));
    assert!(destination_output.output.contains("ZENTTY_SET_DEST"));
    assert!(destination_output.output.contains("carried"));
    assert!(!destination_output.output.contains("ZENTTY_SET_SOURCE"));
}

#[test]
#[cfg(windows)]
fn running_app_set_refuses_to_move_only_pane_to_new_window() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn the only pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::MovePaneToNewWindow)
            .expect("move-pane command should execute"),
        AppCommandExecutionResult::Unavailable
    );
    assert_eq!(running.window_ids(), vec!["window-main"]);
    assert_eq!(running.active_window_id(), Some("window-main"));

    let mut window = running
        .take_window("window-main")
        .expect("source window should still be running");
    assert_eq!(window.pane_ids(), vec!["pane-main"]);
    window
        .write_to_focused(b"echo ZENTTY_SET_ONLY_PANE\rexit\r")
        .expect("only pane should remain live after refused move");
    let output = window
        .take_pane("pane-main")
        .expect("only pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("only pane should exit");

    assert!(output.output.contains("ZENTTY_SET_ONLY_PANE"));
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_new_window_with_focused_working_directory() {
    let cwd = test_directory("runtime-app-set-new-window");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");

    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    let mut source = running
        .take_window("window-main")
        .expect("source window should remain running");
    let mut destination = running
        .take_window("window-2")
        .expect("new window should be running");
    assert_eq!(source.pane_ids(), vec!["pane-main"]);
    assert_eq!(destination.pane_ids(), vec!["pane-2"]);
    assert_eq!(destination.focused_pane_id(), Some("pane-2"));

    source
        .write_to_focused(b"echo ZENTTY_SET_NEW_WINDOW_SOURCE\rexit\r")
        .expect("source pane should remain live");
    destination
        .write_to_focused(b"cd\recho ZENTTY_SET_NEW_WINDOW_DEST\rexit\r")
        .expect("new window pane should accept input");

    let source_output = source
        .take_pane("pane-main")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let destination_output = destination
        .take_pane("pane-2")
        .expect("new pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("new pane should exit");

    assert!(
        source_output
            .output
            .contains("ZENTTY_SET_NEW_WINDOW_SOURCE")
    );
    assert!(!source_output.output.contains("ZENTTY_SET_NEW_WINDOW_DEST"));
    assert!(
        destination_output
            .output
            .contains("ZENTTY_SET_NEW_WINDOW_DEST")
    );
    assert!(
        destination_output
            .output
            .contains(cwd.to_string_lossy().as_ref())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_palette_new_window_with_focused_working_directory() {
    let cwd = test_directory("runtime-app-set-palette-new-window");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");

    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::NewWindow.raw_value()
            ))
            .expect("palette new-window command should execute"),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    let mut source = running
        .take_window("window-main")
        .expect("source window should remain running");
    let mut destination = running
        .take_window("window-2")
        .expect("new window should be running");
    assert_eq!(source.pane_ids(), vec!["pane-main"]);
    assert_eq!(destination.pane_ids(), vec!["pane-2"]);
    assert_eq!(destination.focused_pane_id(), Some("pane-2"));

    source
        .write_to_focused(b"echo ZENTTY_SET_PALETTE_NEW_WINDOW_SOURCE\rexit\r")
        .expect("source pane should remain live");
    destination
        .write_to_focused(b"cd\recho ZENTTY_SET_PALETTE_NEW_WINDOW_DEST\rexit\r")
        .expect("new window pane should accept input");

    let source_output = source
        .take_pane("pane-main")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let destination_output = destination
        .take_pane("pane-2")
        .expect("new pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("new pane should exit");

    assert!(
        source_output
            .output
            .contains("ZENTTY_SET_PALETTE_NEW_WINDOW_SOURCE")
    );
    assert!(
        !source_output
            .output
            .contains("ZENTTY_SET_PALETTE_NEW_WINDOW_DEST")
    );
    assert!(
        destination_output
            .output
            .contains("ZENTTY_SET_PALETTE_NEW_WINDOW_DEST")
    );
    assert!(
        destination_output
            .output
            .contains(cwd.to_string_lossy().as_ref())
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_palette_move_pane_to_new_window_without_respawning_pty() {
    let plan = layout_plan(
        "pane-right",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn panes");

    running
        .active_window_mut()
        .expect("active source window should exist")
        .write_to_focused(b"set ZENTTY_SET_PALETTE_TRANSFER_STATE=carried\r")
        .expect("focused pane should accept pre-transfer state");

    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::MovePaneToNewWindow.raw_value()
            ))
            .expect("palette move-pane command should execute"),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    let mut source = running
        .take_window("window-main")
        .expect("source window should remain running");
    let mut destination = running
        .take_window("window-2")
        .expect("destination window should be running");
    assert_eq!(source.pane_ids(), vec!["pane-left"]);
    assert_eq!(destination.pane_ids(), vec!["pane-right"]);

    source
        .write_to_focused(b"echo ZENTTY_SET_PALETTE_SOURCE\rexit\r")
        .expect("source pane should remain live");
    destination
        .write_to_focused(
            b"echo ZENTTY_SET_PALETTE_DEST %ZENTTY_SET_PALETTE_TRANSFER_STATE%\rexit\r",
        )
        .expect("destination pane should remain live");

    let source_output = source
        .take_pane("pane-left")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let destination_output = destination
        .take_pane("pane-right")
        .expect("destination pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("destination pane should exit");

    assert!(source_output.output.contains("ZENTTY_SET_PALETTE_SOURCE"));
    assert!(!source_output.output.contains("ZENTTY_SET_PALETTE_DEST"));
    assert!(
        destination_output
            .output
            .contains("ZENTTY_SET_PALETTE_DEST")
    );
    assert!(destination_output.output.contains("carried"));
    assert!(
        !destination_output
            .output
            .contains("ZENTTY_SET_PALETTE_SOURCE")
    );
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_close_window_and_falls_back() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");
    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    assert_eq!(
        running
            .execute_command(AppCommandId::CloseWindow)
            .expect("close-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main"]);
    assert_eq!(running.active_window_id(), Some("window-main"));
    assert!(running.take_window("window-2").is_none());

    let mut source = running
        .take_window("window-main")
        .expect("fallback window should remain running");
    source
        .write_to_focused(b"echo ZENTTY_SET_CLOSE_FALLBACK\rexit\r")
        .expect("fallback pane should remain live");
    let output = source
        .take_pane("pane-main")
        .expect("fallback pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("fallback pane should exit");

    assert!(output.output.contains("ZENTTY_SET_CLOSE_FALLBACK"));
}

#[test]
#[cfg(windows)]
fn running_app_set_executes_palette_close_window_and_falls_back() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");
    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));

    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::CloseWindow.raw_value()
            ))
            .expect("palette close-window command should execute"),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(running.window_ids(), vec!["window-main"]);
    assert_eq!(running.active_window_id(), Some("window-main"));
    assert!(running.take_window("window-2").is_none());

    let mut source = running
        .take_window("window-main")
        .expect("fallback window should remain running");
    source
        .write_to_focused(b"echo ZENTTY_SET_PALETTE_CLOSE_FALLBACK\rexit\r")
        .expect("fallback pane should remain live");
    let output = source
        .take_pane("pane-main")
        .expect("fallback pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("fallback pane should exit");

    assert!(output.output.contains("ZENTTY_SET_PALETTE_CLOSE_FALLBACK"));
}

#[test]
#[cfg(windows)]
fn running_app_set_execute_palette_item_with_shell_state_runs_task_runner_items() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_SET_PALETTE_TASK_RUNNER_FOCUSED");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn panes");

    assert_eq!(
        running
            .execute_palette_item_with_shell_state(
                &CommandPaletteItemId::task_runner(&task.id),
                TaskRunnerShellActivityState::PromptIdle,
                false,
            )
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_SET_PALETTE_TASK_RUNNER_FOCUSED".to_string(),
        }
    );
    assert_eq!(running.window_ids(), vec!["window-main"]);

    let mut window = running
        .take_window("window-main")
        .expect("active window should remain running");
    assert_eq!(window.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(window.focused_pane_id(), Some("pane-two"));
    window
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    window
        .write_to_pane(
            "pane-one",
            b"echo ZENTTY_SET_PALETTE_TASK_RUNNER_SURVIVOR\rexit\r",
        )
        .expect("surviving pane should accept input");

    let output_one = window
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = window
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(
        output_two
            .output
            .contains("ZENTTY_SET_PALETTE_TASK_RUNNER_FOCUSED")
    );
    assert!(
        !output_one
            .output
            .contains("ZENTTY_SET_PALETTE_TASK_RUNNER_FOCUSED")
    );
    assert!(
        output_one
            .output
            .contains("ZENTTY_SET_PALETTE_TASK_RUNNER_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_set_routes_input_to_active_and_addressed_panes_across_windows() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");

    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.active_window_id(), Some("window-2"));
    assert_eq!(running.focused_pane_id(), Some("pane-2"));
    assert_eq!(running.active_pane_ids(), vec!["pane-2"]);

    running
        .resize_focused(TerminalSize::new(100, 30))
        .expect("active focused pane should resize");
    running
        .write_to_pane("pane-main", b"echo ZENTTY_SET_ADDRESSED_SOURCE\rexit\r")
        .expect("inactive source pane should accept addressed input");
    running
        .submit_command_to_focused("echo ZENTTY_SET_ACTIVE_SUBMIT", TerminalPasteMode::Plain)
        .expect("active focused pane should accept submitted command");
    running
        .paste_to_focused(
            &TerminalClipboardPaste::Text("echo ZENTTY_SET_ACTIVE_PASTE".to_string()),
            TerminalPasteMode::Plain,
        )
        .expect("active focused pane should accept paste");
    running
        .write_to_focused(b"\rexit\r")
        .expect("active focused pane should accept raw input");

    let mut source = running
        .take_window("window-main")
        .expect("source window should remain running");
    let mut destination = running
        .take_window("window-2")
        .expect("destination window should remain running");

    let source_output = source
        .take_pane("pane-main")
        .expect("source pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("source pane should exit");
    let destination_output = destination
        .take_pane("pane-2")
        .expect("destination pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("destination pane should exit");

    assert!(source_output.output.contains("ZENTTY_SET_ADDRESSED_SOURCE"));
    assert!(!source_output.output.contains("ZENTTY_SET_ACTIVE_SUBMIT"));
    assert!(!source_output.output.contains("ZENTTY_SET_ACTIVE_PASTE"));
    assert!(
        destination_output
            .output
            .contains("ZENTTY_SET_ACTIVE_SUBMIT")
    );
    assert!(
        destination_output
            .output
            .contains("ZENTTY_SET_ACTIVE_PASTE")
    );
    assert!(
        !destination_output
            .output
            .contains("ZENTTY_SET_ADDRESSED_SOURCE")
    );
}

#[test]
#[cfg(windows)]
fn running_app_set_command_palette_items_follow_active_window_context() {
    let cwd = test_directory("runtime-app-set-palette-context");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    plan.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "cursor",
        OpenWithTargetKind::Editor,
        "Cursor",
        Some(OpenWithBuiltInTargetId::Cursor),
        None,
    )];
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn source window");

    let initial_ids = running
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(initial_ids.contains(&CommandPaletteItemId::open_with("cursor")));
    assert!(initial_ids.contains(&CommandPaletteItemId::pane("main", "pane-main")));
    let initial_resolved = running.resolve_command_palette("cursor");
    assert!(
        initial_resolved
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .any(|item| item.item.id == CommandPaletteItemId::open_with("cursor")),
        "active source window open-with item should be searchable"
    );

    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.active_window_id(), Some("window-2"));
    let new_window_ids = running
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(!new_window_ids.contains(&CommandPaletteItemId::open_with("cursor")));
    assert!(new_window_ids.contains(&CommandPaletteItemId::pane("worklane-2", "pane-2")));
    let new_window_resolved = running.resolve_command_palette("cursor");
    assert!(
        !new_window_resolved
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .any(|item| item.item.id == CommandPaletteItemId::open_with("cursor")),
        "new active window should not expose source window open-with item"
    );

    running
        .terminate_all_panes()
        .expect("running panes should terminate");
    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_set_refuses_to_close_last_window() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningAppSet::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app set should spawn the only window");

    assert_eq!(
        running
            .execute_command(AppCommandId::CloseWindow)
            .expect("close-window command should execute"),
        AppCommandExecutionResult::Unavailable
    );
    assert_eq!(running.window_ids(), vec!["window-main"]);
    assert_eq!(running.active_window_id(), Some("window-main"));

    let mut window = running
        .take_window("window-main")
        .expect("only window should still be running");
    window
        .write_to_focused(b"echo ZENTTY_SET_LAST_WINDOW\rexit\r")
        .expect("only pane should remain live after refused close");
    let output = window
        .take_pane("pane-main")
        .expect("only pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("only pane should exit");

    assert!(output.output.contains("ZENTTY_SET_LAST_WINDOW"));
}

#[test]
#[cfg(windows)]
fn running_app_splits_focused_pane_into_new_live_pty() {
    let mut pane = minimal_pane_spec();
    pane.terminal_request.environment_variables.push((
        "ZENTTY_RUNTIME_SPLIT_ENV".to_string(),
        "inherited".to_string(),
    ));
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn the initial pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::SplitHorizontally)
            .expect("split command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(running.focused_pane_id(), Some("pane-2"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_SPLIT_NEW %ZENTTY_RUNTIME_SPLIT_ENV%\rexit\r")
        .expect("new split pane should accept focused input");
    running
        .write_to_pane("pane-main", b"echo ZENTTY_RUNTIME_SPLIT_ORIGINAL\rexit\r")
        .expect("original pane should remain usable after split");

    let original_output = running
        .take_pane("pane-main")
        .expect("original pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("original pane should exit");
    let new_output = running
        .take_pane("pane-2")
        .expect("new split pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("new split pane should exit");

    assert!(
        original_output
            .output
            .contains("ZENTTY_RUNTIME_SPLIT_ORIGINAL")
    );
    assert!(!original_output.output.contains("ZENTTY_RUNTIME_SPLIT_NEW"));
    assert!(new_output.output.contains("ZENTTY_RUNTIME_SPLIT_NEW"));
    assert!(new_output.output.contains("inherited"));
    assert!(!new_output.output.contains("ZENTTY_RUNTIME_SPLIT_ORIGINAL"));
}

#[test]
#[cfg(windows)]
fn running_app_duplicates_focused_pane_into_new_live_pty() {
    let mut pane = minimal_pane_spec();
    pane.terminal_request.environment_variables.push((
        "ZENTTY_RUNTIME_DUP_ENV".to_string(),
        "duplicated".to_string(),
    ));
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn the initial pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::DuplicateFocusedPane)
            .expect("duplicate command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(running.focused_pane_id(), Some("pane-2"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_DUP_NEW %ZENTTY_RUNTIME_DUP_ENV%\rexit\r")
        .expect("duplicate pane should accept focused input");
    running
        .write_to_pane("pane-main", b"echo ZENTTY_RUNTIME_DUP_ORIGINAL\rexit\r")
        .expect("original pane should remain usable after duplicate");

    let original_output = running
        .take_pane("pane-main")
        .expect("original pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("original pane should exit");
    let duplicate_output = running
        .take_pane("pane-2")
        .expect("duplicate pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("duplicate pane should exit");

    assert!(
        original_output
            .output
            .contains("ZENTTY_RUNTIME_DUP_ORIGINAL")
    );
    assert!(!original_output.output.contains("ZENTTY_RUNTIME_DUP_NEW"));
    assert!(duplicate_output.output.contains("ZENTTY_RUNTIME_DUP_NEW"));
    assert!(duplicate_output.output.contains("duplicated"));
    assert!(
        !duplicate_output
            .output
            .contains("ZENTTY_RUNTIME_DUP_ORIGINAL")
    );
}

#[test]
#[cfg(windows)]
fn running_app_cycles_worklanes_before_routing_focused_input() {
    let mut alpha = minimal_pane_spec_with_id("pane-alpha");
    alpha.worklane_id = "alpha".to_string();
    alpha.column_id = "column-alpha".to_string();
    let mut beta = minimal_pane_spec_with_id("pane-beta");
    beta.worklane_id = "beta".to_string();
    beta.column_id = "column-beta".to_string();
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("alpha".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "alpha".to_string(),
                    title: Some("Alpha".to_string()),
                    focused_pane_id: Some("pane-alpha".to_string()),
                    panes: vec![alpha],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "beta".to_string(),
                    title: Some("Beta".to_string()),
                    focused_pane_id: Some("pane-beta".to_string()),
                    panes: vec![beta],
                },
            ],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn panes across worklanes");

    assert_eq!(running.focused_pane_id(), Some("pane-alpha"));
    assert_eq!(
        running
            .execute_command(AppCommandId::NextWorklane)
            .expect("next worklane command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-beta"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_WORKLANE_BETA\rexit\r")
        .expect("focused beta pane should accept input");
    running
        .write_to_pane("pane-alpha", b"echo ZENTTY_RUNTIME_WORKLANE_ALPHA\rexit\r")
        .expect("alpha pane should remain usable");

    let alpha_output = running
        .take_pane("pane-alpha")
        .expect("alpha pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("alpha pane should exit");
    let beta_output = running
        .take_pane("pane-beta")
        .expect("beta pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("beta pane should exit");

    assert!(
        alpha_output
            .output
            .contains("ZENTTY_RUNTIME_WORKLANE_ALPHA")
    );
    assert!(!alpha_output.output.contains("ZENTTY_RUNTIME_WORKLANE_BETA"));
    assert!(beta_output.output.contains("ZENTTY_RUNTIME_WORKLANE_BETA"));
    assert!(!beta_output.output.contains("ZENTTY_RUNTIME_WORKLANE_ALPHA"));
}

#[test]
#[cfg(windows)]
fn running_app_moves_active_worklane_before_cycling() {
    let mut alpha = minimal_pane_spec_with_id("pane-alpha");
    alpha.worklane_id = "alpha".to_string();
    alpha.column_id = "column-alpha".to_string();
    let mut beta = minimal_pane_spec_with_id("pane-beta");
    beta.worklane_id = "beta".to_string();
    beta.column_id = "column-beta".to_string();
    let mut gamma = minimal_pane_spec_with_id("pane-gamma");
    gamma.worklane_id = "gamma".to_string();
    gamma.column_id = "column-gamma".to_string();
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("beta".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "alpha".to_string(),
                    title: Some("Alpha".to_string()),
                    focused_pane_id: Some("pane-alpha".to_string()),
                    panes: vec![alpha],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "beta".to_string(),
                    title: Some("Beta".to_string()),
                    focused_pane_id: Some("pane-beta".to_string()),
                    panes: vec![beta],
                },
                zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "gamma".to_string(),
                    title: Some("Gamma".to_string()),
                    focused_pane_id: Some("pane-gamma".to_string()),
                    panes: vec![gamma],
                },
            ],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn panes across worklanes");

    assert_eq!(running.focused_pane_id(), Some("pane-beta"));
    assert_eq!(
        running
            .execute_command(AppCommandId::WorklaneMoveUp)
            .expect("worklane move command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        running
            .execute_command(AppCommandId::PreviousWorklane)
            .expect("previous worklane command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-gamma"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_MOVED_WORKLANE_GAMMA\rexit\r")
        .expect("gamma pane should accept focused input");
    running
        .write_to_pane(
            "pane-alpha",
            b"echo ZENTTY_RUNTIME_MOVED_WORKLANE_ALPHA\rexit\r",
        )
        .expect("alpha pane should remain usable");
    running
        .write_to_pane(
            "pane-beta",
            b"echo ZENTTY_RUNTIME_MOVED_WORKLANE_BETA\rexit\r",
        )
        .expect("beta pane should remain usable");

    let alpha_output = running
        .take_pane("pane-alpha")
        .expect("alpha pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("alpha pane should exit");
    let beta_output = running
        .take_pane("pane-beta")
        .expect("beta pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("beta pane should exit");
    let gamma_output = running
        .take_pane("pane-gamma")
        .expect("gamma pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("gamma pane should exit");

    assert!(
        alpha_output
            .output
            .contains("ZENTTY_RUNTIME_MOVED_WORKLANE_ALPHA")
    );
    assert!(
        beta_output
            .output
            .contains("ZENTTY_RUNTIME_MOVED_WORKLANE_BETA")
    );
    assert!(
        gamma_output
            .output
            .contains("ZENTTY_RUNTIME_MOVED_WORKLANE_GAMMA")
    );
    assert!(
        !alpha_output
            .output
            .contains("ZENTTY_RUNTIME_MOVED_WORKLANE_GAMMA")
    );
    assert!(
        !beta_output
            .output
            .contains("ZENTTY_RUNTIME_MOVED_WORKLANE_GAMMA")
    );
}

#[test]
#[cfg(windows)]
fn running_app_creates_new_worklane_with_live_pty() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn the initial pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::NewWorklane)
            .expect("new worklane command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(running.focused_pane_id(), Some("pane-2"));

    running
        .write_to_focused(b"echo ZENTTY_RUNTIME_NEW_WORKLANE\rexit\r")
        .expect("new worklane pane should accept focused input");
    running
        .write_to_pane(
            "pane-main",
            b"echo ZENTTY_RUNTIME_ORIGINAL_WORKLANE\rexit\r",
        )
        .expect("original worklane pane should remain usable");

    let original_output = running
        .take_pane("pane-main")
        .expect("original pane should still be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("original pane should exit");
    let new_worklane_output = running
        .take_pane("pane-2")
        .expect("new worklane pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("new worklane pane should exit");

    assert!(
        original_output
            .output
            .contains("ZENTTY_RUNTIME_ORIGINAL_WORKLANE")
    );
    assert!(
        !original_output
            .output
            .contains("ZENTTY_RUNTIME_NEW_WORKLANE")
    );
    assert!(
        new_worklane_output
            .output
            .contains("ZENTTY_RUNTIME_NEW_WORKLANE")
    );
    assert!(
        !new_worklane_output
            .output
            .contains("ZENTTY_RUNTIME_ORIGINAL_WORKLANE")
    );
}

#[test]
#[cfg(windows)]
fn running_app_routes_paste_and_submit_payloads_to_panes() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running = RunningApp::spawn(plan, TerminalSize::new(80, 24))
        .expect("running app should spawn every pane");

    running
        .paste_to_focused(
            &TerminalClipboardPaste::Text("echo ZENTTY_FOCUSED_PASTE".to_string()),
            TerminalPasteMode::Plain,
        )
        .expect("focused pane should accept pasted input");
    running
        .write_to_focused(b"\r")
        .expect("focused pane should accept return after paste");
    running
        .paste_to_pane(
            "pane-one",
            &TerminalClipboardPaste::Text("echo ZENTTY_NAMED_PASTE".to_string()),
            TerminalPasteMode::Plain,
        )
        .expect("named pane should accept pasted input");
    running
        .write_to_pane("pane-one", b"\r")
        .expect("named pane should accept return after paste");
    running
        .submit_command_to_focused("echo ZENTTY_FOCUSED_SUBMIT", TerminalPasteMode::Plain)
        .expect("focused pane should accept submitted command input");
    running
        .submit_command_to_pane(
            "pane-one",
            "echo ZENTTY_NAMED_SUBMIT",
            TerminalPasteMode::Plain,
        )
        .expect("named pane should accept submitted command input");
    running
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    running
        .write_to_pane("pane-one", b"exit\r")
        .expect("named pane should accept exit");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(output_one.output.contains("ZENTTY_NAMED_SUBMIT"));
    assert!(output_one.output.contains("ZENTTY_NAMED_PASTE"));
    assert!(!output_one.output.contains("ZENTTY_FOCUSED_PASTE"));
    assert!(!output_one.output.contains("ZENTTY_FOCUSED_SUBMIT"));
    assert!(output_two.output.contains("ZENTTY_FOCUSED_PASTE"));
    assert!(output_two.output.contains("ZENTTY_FOCUSED_SUBMIT"));
    assert!(!output_two.output.contains("ZENTTY_NAMED_SUBMIT"));
    assert!(!output_two.output.contains("ZENTTY_NAMED_PASTE"));
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_returns_clipboard_and_search_results() {
    let cwd = test_directory("runtime-clipboard-search");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

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
                text: cwd.to_string_lossy().to_string(),
            },
        ),
    ];

    for (command_id, expected) in cases {
        assert_eq!(
            running
                .execute_command(command_id)
                .expect("runtime command should execute"),
            expected,
            "{command_id:?} should return the same typed result as launch-plan execution"
        );
    }

    let mut pane = running
        .take_pane("pane-main")
        .expect("pane should still be running");
    pane.terminate().expect("pane should terminate");
    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_returns_ui_handoff_results() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

    let cases = [
        (
            AppCommandId::ToggleSidebar,
            AppCommandExecutionResult::ToggleSidebar,
        ),
        (
            AppCommandId::ShowCommandPalette,
            AppCommandExecutionResult::ShowCommandPalette,
        ),
        (
            AppCommandId::ShowTaskManager,
            AppCommandExecutionResult::ShowTaskManager,
        ),
        (
            AppCommandId::OpenSettings,
            AppCommandExecutionResult::ShowSettings { section: "general" },
        ),
        (
            AppCommandId::ReloadConfig,
            AppCommandExecutionResult::ReloadConfiguration,
        ),
        (
            AppCommandId::OpenBookmarksPopover,
            AppCommandExecutionResult::OpenBookmarksPopover,
        ),
        (
            AppCommandId::ToggleLightDarkTheme,
            AppCommandExecutionResult::SetThemeMode {
                mode: "toggleLightDark",
            },
        ),
        (
            AppCommandId::UseDarkTheme,
            AppCommandExecutionResult::SetThemeMode { mode: "dark" },
        ),
        (
            AppCommandId::UseLightTheme,
            AppCommandExecutionResult::SetThemeMode { mode: "light" },
        ),
        (
            AppCommandId::UseAutoTheme,
            AppCommandExecutionResult::SetThemeMode { mode: "auto" },
        ),
        (
            AppCommandId::RenameCurrentWorklane,
            AppCommandExecutionResult::BeginRenameWorklane {
                worklane_id: "main".to_string(),
            },
        ),
        (
            AppCommandId::JumpToLatestNotification,
            AppCommandExecutionResult::JumpToLatestNotification,
        ),
        (
            AppCommandId::CloseWindow,
            AppCommandExecutionResult::RequestCloseWindow {
                window_id: "window-main".to_string(),
            },
        ),
    ];

    for (command_id, expected) in cases {
        assert_eq!(
            running
                .execute_command(command_id)
                .expect("runtime command should execute"),
            expected,
            "{command_id:?} should return an explicit UI handoff result"
        );
    }

    let mut pane = running
        .take_pane("pane-main")
        .expect("pane should still be running");
    pane.terminate().expect("pane should terminate");
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_returns_open_context_results() {
    let cwd = test_directory("runtime-open-context");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    plan.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "vscode",
        OpenWithTargetKind::Editor,
        "Visual Studio Code",
        Some(OpenWithBuiltInTargetId::VsCode),
        Some("C:\\Program Files\\Microsoft VS Code\\Code.exe"),
    )];
    plan.windows[0].detected_servers = vec![DetectedServer::new(
        "server-5173",
        "http://localhost:5173",
        "http://localhost:5173/",
        "localhost:5173",
    )];
    plan.windows[0].branch_urls_by_pane_id.insert(
        "pane-main".to_string(),
        "https://github.com/ucsandman/zentty/tree/feature/windows".to_string(),
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::OpenWithSelectedApp)
            .expect("open-with command should execute"),
        AppCommandExecutionResult::OpenPathWithTarget {
            path: cwd.to_string_lossy().to_string(),
            target_id: "vscode".to_string(),
            target_name: "Visual Studio Code".to_string(),
            app_path: Some("C:\\Program Files\\Microsoft VS Code\\Code.exe".to_string()),
        }
    );
    assert_eq!(
        running
            .execute_command(AppCommandId::OpenSelectedServer)
            .expect("open-server command should execute"),
        AppCommandExecutionResult::OpenServer {
            server_id: "server-5173".to_string(),
            origin: "http://localhost:5173".to_string(),
            url: "http://localhost:5173/".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_command(AppCommandId::OpenBranchOnRemote)
            .expect("open-branch command should execute"),
        AppCommandExecutionResult::OpenUrl {
            url: "https://github.com/ucsandman/zentty/tree/feature/windows".to_string(),
        }
    );

    let mut pane = running
        .take_pane("pane-main")
        .expect("pane should still be running");
    pane.terminate().expect("pane should terminate");
    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_requests_new_window_from_focused_context() {
    let cwd = test_directory("runtime-new-window");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    let plan = layout_plan("pane-main", vec![pane]);
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

    assert_eq!(
        running
            .execute_command(AppCommandId::NewWindow)
            .expect("new-window command should execute"),
        AppCommandExecutionResult::RequestNewWindow {
            working_directory: Some(cwd.to_string_lossy().to_string()),
        }
    );

    let mut pane = running
        .take_pane("pane-main")
        .expect("pane should still be running");
    pane.terminate().expect("pane should terminate");
    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_requests_move_pane_to_new_window() {
    let plan = layout_plan(
        "pane-right",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_command(AppCommandId::MovePaneToNewWindow)
            .expect("move-pane command should execute"),
        AppCommandExecutionResult::RequestMovePaneToNewWindow {
            pane_id: "pane-right".to_string(),
        }
    );

    for pane_id in ["pane-left", "pane-right"] {
        let mut pane = running
            .take_pane(pane_id)
            .expect("pane should still be running");
        pane.terminate().expect("pane should terminate");
    }
}

#[test]
#[cfg(windows)]
fn running_app_execute_palette_item_dispatches_live_items() {
    let left_dir = test_directory("runtime-palette-left");
    let right_dir = test_directory("runtime-palette-right");
    let mut left = minimal_pane_spec_with_id("pane-left");
    left.column_id = "column-left".to_string();
    left.column_index = 0;
    left.terminal_request.working_directory = Some(left_dir.to_string_lossy().to_string());
    left.restored_rerunnable_command = Some("pnpm dev".to_string());
    let mut right = minimal_pane_spec_with_id("pane-right");
    right.column_id = "column-right".to_string();
    right.column_index = 1;
    right.terminal_request.working_directory = Some(right_dir.to_string_lossy().to_string());
    let mut plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: vec![OpenWithResolvedTarget::new(
                "cursor",
                OpenWithTargetKind::Editor,
                "Cursor",
                Some(OpenWithBuiltInTargetId::Cursor),
                None,
            )],
            detected_servers: vec![DetectedServer::new(
                "server-3000",
                "http://localhost:3000",
                "http://localhost:3000/",
                "localhost:3000",
            )],
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-left".to_string()),
                panes: vec![left, right],
            }],
        }],
    };
    plan.windows[0].branch_urls_by_pane_id.insert(
        "pane-right".to_string(),
        "https://github.com/ucsandman/zentty/tree/windows".to_string(),
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::FocusRightPane.raw_value()
            ))
            .expect("palette command item should execute"),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-right"));
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::OpenBranchOnRemote.raw_value()
            ))
            .expect("branch command item should execute"),
        CommandPaletteItemExecutionResult::OpenUrl {
            url: "https://github.com/ucsandman/zentty/tree/windows".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::pane("main", "pane-left"))
            .expect("pane item should execute"),
        CommandPaletteItemExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-left"));
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::open_with("cursor"))
            .expect("open-with item should execute"),
        CommandPaletteItemExecutionResult::OpenPathWithTarget {
            path: left_dir.to_string_lossy().to_string(),
            target_id: "cursor".to_string(),
            target_name: "Cursor".to_string(),
            app_path: None,
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::NewWindow.raw_value()
            ))
            .expect("new-window command item should execute"),
        CommandPaletteItemExecutionResult::RequestNewWindow {
            working_directory: Some(left_dir.to_string_lossy().to_string()),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::command(
                AppCommandId::MovePaneToNewWindow.raw_value()
            ))
            .expect("move-pane command item should execute"),
        CommandPaletteItemExecutionResult::RequestMovePaneToNewWindow {
            pane_id: "pane-left".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::server("server-3000"))
            .expect("server item should execute"),
        CommandPaletteItemExecutionResult::OpenServer {
            server_id: "server-3000".to_string(),
            origin: "http://localhost:3000".to_string(),
            url: "http://localhost:3000/".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::restored_command("pane-left"))
            .expect("restored command item should execute"),
        CommandPaletteItemExecutionResult::RunRestoredCommand {
            pane_id: "pane-left".to_string(),
            command: "pnpm dev".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::settings("appearance"))
            .expect("settings item should execute"),
        CommandPaletteItemExecutionResult::ShowSettings {
            section: "appearance".to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::worklane_color(Some(
                WorklaneColor::Blue.raw_value()
            )))
            .expect("worklane color item should execute"),
        CommandPaletteItemExecutionResult::SetWorklaneColor {
            worklane_id: "main".to_string(),
            color: Some("blue".to_string()),
        }
    );
    assert_eq!(
        running
            .execute_palette_item(&CommandPaletteItemId::worklane_color(None::<&str>))
            .expect("worklane color reset item should execute"),
        CommandPaletteItemExecutionResult::SetWorklaneColor {
            worklane_id: "main".to_string(),
            color: None,
        }
    );

    for pane_id in ["pane-left", "pane-right"] {
        let mut pane = running
            .take_pane(pane_id)
            .expect("pane should still be running");
        pane.terminate().expect("pane should terminate");
    }
    fs::remove_dir_all(left_dir).ok();
    fs::remove_dir_all(right_dir).ok();
}

#[test]
#[cfg(windows)]
fn running_app_command_palette_items_reflect_live_context() {
    let cwd = test_directory("runtime-palette-items");
    let mut pane = minimal_pane_spec_with_id("pane-main");
    pane.terminal_request.working_directory = Some(cwd.to_string_lossy().to_string());
    pane.restored_rerunnable_command = Some("pnpm dev".to_string());
    let mut plan = layout_plan("pane-main", vec![pane]);
    let task = TaskRunnerAction::new(
        "package|runtime-palette-items/package.json|dev",
        "dev",
        None,
        TaskRunnerSourceKind::PackageScript,
        cwd.join("package.json").to_string_lossy(),
        "pnpm run dev",
        None,
    )
    .with_working_directory(cwd.to_string_lossy());
    plan.windows[0].open_with_targets = vec![OpenWithResolvedTarget::new(
        "cursor",
        OpenWithTargetKind::Editor,
        "Cursor",
        Some(OpenWithBuiltInTargetId::Cursor),
        None,
    )];
    plan.windows[0].detected_servers = vec![DetectedServer::new(
        "server-3000",
        "http://localhost:3000",
        "http://localhost:3000/",
        "localhost:3000",
    )];
    plan.windows[0].task_runner_actions = vec![task.clone()];
    let running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

    let item_ids = running
        .command_palette_items()
        .into_iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    assert!(item_ids.contains(&CommandPaletteItemId::command(
        AppCommandId::ToggleSidebar.raw_value()
    )));
    assert!(item_ids.contains(&CommandPaletteItemId::settings("appearance")));
    assert!(item_ids.contains(&CommandPaletteItemId::restored_command("pane-main")));
    assert!(item_ids.contains(&CommandPaletteItemId::open_with("cursor")));
    assert!(item_ids.contains(&CommandPaletteItemId::server("server-3000")));
    assert!(item_ids.contains(&CommandPaletteItemId::task_runner(&task.id)));
    assert!(
        item_ids.contains(&CommandPaletteItemId::worklane_color(Some(
            WorklaneColor::Blue.raw_value()
        )))
    );
    assert!(item_ids.contains(&CommandPaletteItemId::pane("main", "pane-main")));

    let resolved = running.resolve_command_palette("cursor");
    assert!(
        resolved
            .sections
            .iter()
            .flat_map(|section| &section.items)
            .any(|item| item.item.id == CommandPaletteItemId::open_with("cursor")),
        "cursor open-with item should be searchable"
    );

    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_execute_palette_item_with_shell_state_runs_task_runner_items() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_PALETTE_TASK_RUNNER_FOCUSED");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_palette_item_with_shell_state(
                &CommandPaletteItemId::task_runner(&task.id),
                TaskRunnerShellActivityState::PromptIdle,
                false,
            )
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_PALETTE_TASK_RUNNER_FOCUSED".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    running
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    running
        .write_to_pane(
            "pane-one",
            b"echo ZENTTY_PALETTE_TASK_RUNNER_SURVIVOR\rexit\r",
        )
        .expect("surviving pane should accept input");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(
        output_two
            .output
            .contains("ZENTTY_PALETTE_TASK_RUNNER_FOCUSED")
    );
    assert!(
        !output_one
            .output
            .contains("ZENTTY_PALETTE_TASK_RUNNER_FOCUSED")
    );
    assert!(
        output_one
            .output
            .contains("ZENTTY_PALETTE_TASK_RUNNER_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_execute_palette_item_with_shell_state_handles_disabled_task_runners() {
    let cwd = test_directory("runtime-disabled-task-runner");
    let disabled = TaskRunnerAction::new(
        "taskfile|runtime-disabled-task-runner/Taskfile.yml|deploy",
        "deploy",
        None,
        TaskRunnerSourceKind::Taskfile,
        cwd.join("Taskfile.yml").to_string_lossy(),
        "task deploy",
        Some(TaskRunnerDisabledReason::unsupported(
            "Task requires variables: TARGET",
        )),
    );
    let mut plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    plan.windows[0].task_runner_actions = vec![disabled.clone()];
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");

    assert_eq!(
        running
            .execute_palette_item_with_shell_state(
                &CommandPaletteItemId::task_runner(&disabled.id),
                TaskRunnerShellActivityState::PromptIdle,
                false,
            )
            .expect("disabled task runner item should execute"),
        CommandPaletteItemExecutionResult::OpenTaskRunnerSource {
            source_path: cwd.join("Taskfile.yml").to_string_lossy().to_string(),
        }
    );
    assert_eq!(
        running
            .execute_palette_item_with_shell_state(
                &CommandPaletteItemId::task_runner("missing"),
                TaskRunnerShellActivityState::PromptIdle,
                false,
            )
            .expect("missing task runner item should execute"),
        CommandPaletteItemExecutionResult::Unavailable
    );

    let mut pane = running
        .take_pane("pane-main")
        .expect("pane should still be running");
    pane.terminate().expect("pane should terminate");
    fs::remove_dir_all(cwd).ok();
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_arranges_live_column_widths() {
    let plan = layout_plan(
        "pane-middle",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 300.0, Some(480.0)),
            pane_in_column("pane-middle", "column-middle", 1, 0, 500.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 2, 0, 700.0, Some(480.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_command(AppCommandId::ArrangeWidthThirds)
            .expect("arrange command should execute"),
        AppCommandExecutionResult::Applied
    );

    assert_eq!(
        drain_running_layout(&mut running),
        vec![
            running_layout_entry("pane-left", "column-left", 0, 0, 500.0, Some(480.0)),
            running_layout_entry("pane-middle", "column-middle", 1, 0, 500.0, Some(480.0)),
            running_layout_entry("pane-right", "column-right", 2, 0, 500.0, Some(480.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_arranges_live_panes_vertically() {
    let plan = layout_plan(
        "pane-d",
        vec![
            pane_in_column("pane-a", "column-left", 0, 0, 320.0, Some(2.0)),
            pane_in_column("pane-b", "column-left", 0, 1, 320.0, Some(4.0)),
            pane_in_column("pane-c", "column-right", 1, 0, 520.0, Some(8.0)),
            pane_in_column("pane-d", "column-right", 1, 1, 520.0, Some(16.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_command(AppCommandId::ArrangeHeightThreePerColumn)
            .expect("arrange command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-d"));

    assert_eq!(
        drain_running_layout(&mut running),
        vec![
            running_layout_entry("pane-a", "column-left", 0, 0, 320.0, Some(1.0)),
            running_layout_entry("pane-b", "column-left", 0, 1, 320.0, Some(1.0)),
            running_layout_entry("pane-c", "column-left", 0, 2, 320.0, Some(1.0)),
            running_layout_entry("pane-d", "column-right", 1, 0, 520.0, Some(1.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_resizes_and_resets_live_layout() {
    let plan = layout_plan(
        "pane-top",
        vec![
            pane_in_column("pane-top", "column-left", 0, 0, 300.0, Some(100.0)),
            pane_in_column("pane-middle", "column-left", 0, 1, 300.0, Some(200.0)),
            pane_in_column("pane-right", "column-right", 1, 0, 700.0, Some(300.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_command(AppCommandId::ResizePaneRight)
            .expect("resize command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        running
            .execute_command(AppCommandId::ResizePaneDown)
            .expect("resize command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(
        running
            .execute_command(AppCommandId::ResetPaneLayout)
            .expect("reset command should execute"),
        AppCommandExecutionResult::Applied
    );

    assert_eq!(
        drain_running_layout(&mut running),
        vec![
            running_layout_entry("pane-top", "column-left", 0, 0, 640.0, Some(1.0)),
            running_layout_entry("pane-middle", "column-left", 0, 1, 640.0, Some(1.0)),
            running_layout_entry("pane-right", "column-right", 1, 0, 640.0, Some(1.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_execute_command_navigates_live_focus_history() {
    let plan = layout_plan(
        "pane-left",
        vec![
            pane_in_column("pane-left", "column-left", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-middle", "column-middle", 1, 0, 320.0, Some(480.0)),
            pane_in_column("pane-right", "column-right", 2, 0, 320.0, Some(480.0)),
        ],
    );
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .execute_command(AppCommandId::FocusRightPane)
            .expect("focus-right command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-middle"));

    assert_eq!(
        running
            .execute_command(AppCommandId::FocusRightPane)
            .expect("focus-right command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-right"));

    assert_eq!(
        running
            .execute_command(AppCommandId::NavigateBack)
            .expect("navigate-back command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-middle"));

    assert_eq!(
        running
            .execute_command(AppCommandId::NavigateBack)
            .expect("navigate-back command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-left"));

    assert_eq!(
        running
            .execute_command(AppCommandId::NavigateForward)
            .expect("navigate-forward command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-middle"));

    running
        .write_to_focused(b"echo ZENTTY_NAV_MIDDLE\r")
        .expect("navigated focused pane should accept input");
    running
        .write_to_pane("pane-left", b"echo ZENTTY_NAV_LEFT\rexit\r")
        .expect("left pane should accept input");
    running
        .write_to_pane("pane-middle", b"exit\r")
        .expect("middle pane should accept exit");
    running
        .write_to_pane("pane-right", b"echo ZENTTY_NAV_RIGHT\rexit\r")
        .expect("right pane should accept input");

    let output_left = running
        .take_pane("pane-left")
        .expect("left pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("left pane should exit");
    let output_middle = running
        .take_pane("pane-middle")
        .expect("middle pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("middle pane should exit");
    let output_right = running
        .take_pane("pane-right")
        .expect("right pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("right pane should exit");

    assert!(output_left.output.contains("ZENTTY_NAV_LEFT"));
    assert!(!output_left.output.contains("ZENTTY_NAV_MIDDLE"));
    assert!(output_middle.output.contains("ZENTTY_NAV_MIDDLE"));
    assert!(!output_middle.output.contains("ZENTTY_NAV_LEFT"));
    assert!(!output_middle.output.contains("ZENTTY_NAV_RIGHT"));
    assert!(output_right.output.contains("ZENTTY_NAV_RIGHT"));
    assert!(!output_right.output.contains("ZENTTY_NAV_MIDDLE"));
}

#[test]
#[cfg(windows)]
fn running_app_task_runner_at_idle_prompt_submits_in_focused_pane() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");

    assert_eq!(
        running
            .run_task_runner(
                &runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_FOCUSED"),
                TaskRunnerShellActivityState::PromptIdle,
                false,
            )
            .expect("task runner should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_FOCUSED".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    running
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    running
        .write_to_pane("pane-one", b"echo ZENTTY_TASK_RUNNER_IDLE_SURVIVOR\rexit\r")
        .expect("surviving pane should accept input");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(output_two.output.contains("ZENTTY_TASK_RUNNER_FOCUSED"));
    assert!(!output_one.output.contains("ZENTTY_TASK_RUNNER_FOCUSED"));
    assert!(
        output_one
            .output
            .contains("ZENTTY_TASK_RUNNER_IDLE_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_task_runner_uses_recorded_shell_state_from_agent_signal() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_SIGNAL_FOCUSED");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn panes");
    let signal = AgentSignalCommand::parse(
        &[
            "agent-signal".to_string(),
            "shell-state".to_string(),
            "prompt".to_string(),
        ],
        &BTreeMap::from([
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-two".to_string()),
        ]),
    )
    .expect("shell-state signal should parse");

    assert!(running.apply_agent_signal(&signal.payload));
    assert_eq!(
        running
            .execute_palette_item_with_recorded_shell_state(&CommandPaletteItemId::task_runner(
                &task.id
            ))
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_SIGNAL_FOCUSED".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    running
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    running
        .write_to_pane(
            "pane-one",
            b"echo ZENTTY_TASK_RUNNER_SIGNAL_SURVIVOR\rexit\r",
        )
        .expect("surviving pane should accept input");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(
        output_two
            .output
            .contains("ZENTTY_TASK_RUNNER_SIGNAL_FOCUSED")
    );
    assert!(
        !output_one
            .output
            .contains("ZENTTY_TASK_RUNNER_SIGNAL_FOCUSED")
    );
    assert!(
        output_one
            .output
            .contains("ZENTTY_TASK_RUNNER_SIGNAL_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_agent_signal_ipc_request() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_IPC_FOCUSED");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "valid-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    let request = agent_signal_request("ipc-auth", "valid-token", true);
    assert_eq!(
        running
            .handle_agent_ipc_request(request)
            .expect("ipc request should handle"),
        Some(AgentIpcResponse {
            version: 1,
            id: "ipc-auth".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = running.task_manager_pane_sources();
    let pane_two_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-two")
        .expect("pane-two task manager source should exist");
    assert_eq!(pane_two_source.status_text.as_deref(), Some("Idle"));
    assert_eq!(pane_two_source.root_pid, None);

    let mut root_pid_request = agent_signal_request("ipc-root-pid", "valid-token", true);
    root_pid_request.arguments = vec![
        "pane-root-pid".to_string(),
        "attach".to_string(),
        "4242".to_string(),
    ];
    assert_eq!(
        running
            .handle_agent_ipc_request(root_pid_request)
            .expect("root pid ipc request should handle"),
        Some(AgentIpcResponse {
            version: 1,
            id: "ipc-root-pid".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = running.task_manager_pane_sources();
    let pane_two_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-two")
        .expect("pane-two task manager source should exist");
    assert_eq!(pane_two_source.root_pid, Some(4242));

    let mut clear_root_pid_request =
        agent_signal_request("ipc-root-pid-clear", "valid-token", true);
    clear_root_pid_request.arguments = vec!["pane-root-pid".to_string(), "clear".to_string()];
    assert_eq!(
        running
            .handle_agent_ipc_request(clear_root_pid_request)
            .expect("root pid clear ipc request should handle"),
        Some(AgentIpcResponse {
            version: 1,
            id: "ipc-root-pid-clear".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    let sources = running.task_manager_pane_sources();
    let pane_two_source = sources
        .iter()
        .find(|source| source.pane_id == "pane-two")
        .expect("pane-two task manager source should exist");
    assert_eq!(pane_two_source.root_pid, None);

    assert_eq!(
        running
            .execute_palette_item_with_recorded_shell_state(&CommandPaletteItemId::task_runner(
                &task.id
            ))
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_IPC_FOCUSED".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);

    running
        .write_to_focused(b"exit\r")
        .expect("focused pane should accept exit");
    running
        .write_to_pane("pane-one", b"echo ZENTTY_TASK_RUNNER_IPC_SURVIVOR\rexit\r")
        .expect("surviving pane should accept input");

    let output_one = running
        .take_pane("pane-one")
        .expect("pane one should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane one should exit");
    let output_two = running
        .take_pane("pane-two")
        .expect("pane two should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane two should exit");

    assert!(output_two.output.contains("ZENTTY_TASK_RUNNER_IPC_FOCUSED"));
    assert!(!output_one.output.contains("ZENTTY_TASK_RUNNER_IPC_FOCUSED"));
    assert!(
        output_one
            .output
            .contains("ZENTTY_TASK_RUNNER_IPC_SURVIVOR")
    );
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_pane_list_ipc_request() {
    let mut first = pane_in_column("pane-one", "column-one", 0, 0, 320.0, Some(480.0));
    first.title = "one".to_string();
    let mut second = pane_in_column("pane-two", "column-two", 1, 0, 320.0, Some(480.0));
    second.title = "two".to_string();
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-list-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-list-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_list_request("pane-list", "two-token", true, []))
            .expect("ipc request should handle"),
        Some(AgentIpcResponse {
            version: 1,
            id: "pane-list".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult {
                pane_list: Some(vec![
                    PaneListEntry {
                        index: 1,
                        id: "pane-one".to_string(),
                        column: 1,
                        title: "one".to_string(),
                        working_directory: None,
                        is_focused: false,
                        agent_tool: None,
                        agent_status: None,
                    },
                    PaneListEntry {
                        index: 2,
                        id: "pane-two".to_string(),
                        column: 2,
                        title: "two".to_string(),
                        working_directory: None,
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

    let response = running
        .handle_agent_ipc_request(pane_list_request(
            "pane-list-invalid-token",
            "two-token",
            true,
            ["--pane-id", "pane-one"],
        ))
        .expect("ipc request should produce error response")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(response.id, "pane-list-invalid-token");
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("invalid_pane_token")
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_mutating_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 300.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 500.0, Some(480.0)),
            pane_in_column("pane-three", "column-three", 2, 0, 700.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-mutating-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-mutating-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token")
    .with_pane_token(Some("window-main"), "main", "pane-three", "three-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-focus-left",
                "focus",
                "two-token",
                true,
                ["left"]
            ))
            .expect("focus ipc request should handle"),
        ipc_success_response("pane-focus-left")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-one"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-focus-index",
                "focus",
                "two-token",
                true,
                ["3"]
            ))
            .expect("indexed focus ipc request should handle"),
        ipc_success_response("pane-focus-index")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-three"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-layout-thirds",
                "layout",
                "two-token",
                true,
                ["thirds"]
            ))
            .expect("layout ipc request should handle"),
        ipc_success_response("pane-layout-thirds")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-resize-right",
                "resize",
                "two-token",
                true,
                ["right"]
            ))
            .expect("resize ipc request should handle"),
        ipc_success_response("pane-resize-right")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-close-third",
                "close",
                "two-token",
                true,
                ["3"]
            ))
            .expect("close ipc request should handle"),
        ipc_success_response("pane-close-third")
    );
    assert_eq!(running.pane_ids(), vec!["pane-one", "pane-two"]);
    assert_eq!(running.focused_pane_id(), Some("pane-two"));
    assert_eq!(
        drain_running_layout(&mut running),
        vec![
            running_layout_entry("pane-one", "column-one", 0, 0, 500.0, Some(480.0)),
            running_layout_entry("pane-two", "column-two", 1, 0, 524.0, Some(480.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_grid_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![pane_in_column(
            "pane-two",
            "column-two",
            0,
            0,
            500.0,
            Some(480.0),
        )],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-grid-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-grid-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-grid-current",
                "grid",
                "two-token",
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
            ))
            .expect("grid ipc request should handle"),
        ipc_success_response("pane-grid-current")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-4"));
    assert_eq!(
        drain_running_layout(&mut running),
        vec![
            running_layout_entry("pane-two", "column-two", 0, 0, 640.0, Some(1.0)),
            running_layout_entry("pane-2", "column-two", 0, 1, 640.0, Some(1.0)),
            running_layout_entry("pane-3", "column-pane-3", 1, 0, 640.0, Some(1.0)),
            running_layout_entry("pane-4", "column-pane-3", 1, 1, 640.0, Some(1.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_set_handles_authenticated_grid_new_window_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![pane_in_column(
            "pane-two",
            "column-two",
            0,
            0,
            500.0,
            Some(480.0),
        )],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-grid-new-window-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-grid-new-window-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningAppSet::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app set should spawn panes");

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-grid-new-window",
                "grid",
                "two-token",
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
                ]
            ))
            .expect("grid new-window ipc request should handle"),
        ipc_success_response("pane-grid-new-window")
    );
    assert_eq!(running.window_ids(), vec!["window-main", "window-2"]);
    assert_eq!(running.active_window_id(), Some("window-2"));
    assert_eq!(running.focused_pane_id(), Some("pane-5"));

    let mut source_window = running
        .take_window("window-main")
        .expect("source window should remain open");
    assert_eq!(source_window.pane_ids(), vec!["pane-two"]);
    assert_eq!(
        drain_running_layout(&mut source_window),
        vec![running_layout_entry(
            "pane-two",
            "column-two",
            0,
            0,
            500.0,
            Some(480.0)
        )]
    );

    let mut grid_window = running
        .take_window("window-2")
        .expect("grid window should be created");
    assert_eq!(grid_window.focused_pane_id(), Some("pane-5"));
    assert_eq!(
        drain_running_layout(&mut grid_window),
        vec![
            running_layout_entry("pane-2", "column-pane-2", 0, 0, 640.0, Some(1.0)),
            running_layout_entry("pane-3", "column-pane-2", 0, 1, 640.0, Some(1.0)),
            running_layout_entry("pane-4", "column-pane-4", 1, 0, 640.0, Some(1.0)),
            running_layout_entry("pane-5", "column-pane-4", 1, 1, 640.0, Some(1.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_rejects_invalid_grid_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![pane_in_column(
            "pane-two",
            "column-two",
            0,
            0,
            500.0,
            Some(480.0),
        )],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-grid-invalid-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-grid-invalid-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    let response = running
        .handle_agent_ipc_request(pane_request(
            "pane-grid-invalid-rows",
            "grid",
            "two-token",
            true,
            ["--rows", "0", "--columns", "2"],
        ))
        .expect("invalid grid rows should produce response")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("invalid_value")
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_notify_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-notify-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-notify-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert!(running.pane_notifications().is_empty());
    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-notify-inbox",
                "notify",
                "two-token",
                true,
                [
                    "--title",
                    " Build Ready ",
                    "--subtitle",
                    " Agent ",
                    "--body",
                    " Done ",
                    "--silent",
                ]
            ))
            .expect("notify ipc request should handle"),
        ipc_success_response("pane-notify-inbox")
    );
    let notification = &running.pane_notifications()[0];
    assert_eq!(notification.title, "Build Ready");
    assert_eq!(notification.subtitle.as_deref(), Some("Agent"));
    assert_eq!(notification.body.as_deref(), Some("Done"));
    assert_eq!(notification.primary_text(), "Done");
    assert!(notification.include_inbox);
    assert!(notification.is_silent);
    assert_eq!(notification.window_id, "window-main");
    assert_eq!(notification.worklane_id, "main");
    assert_eq!(notification.pane_id, "pane-two");
    assert_eq!(running.inbox_pane_notifications().len(), 1);

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-notify-no-inbox",
                "notify",
                "two-token",
                true,
                ["--title", "No Inbox", "--no-inbox"]
            ))
            .expect("no-inbox notify ipc request should handle"),
        ipc_success_response("pane-notify-no-inbox")
    );
    assert_eq!(running.pane_notifications().len(), 2);
    assert_eq!(running.pane_notifications()[0].title, "No Inbox");
    assert!(!running.pane_notifications()[0].include_inbox);
    assert_eq!(running.inbox_pane_notifications().len(), 1);

    assert_eq!(
        running
            .execute_command(AppCommandId::FocusLeftPane)
            .expect("focus left command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-one"));
    assert_eq!(
        running
            .execute_command(AppCommandId::JumpToLatestNotification)
            .expect("jump notification command should execute"),
        AppCommandExecutionResult::Applied
    );
    assert_eq!(running.focused_pane_id(), Some("pane-two"));

    let response = running
        .handle_agent_ipc_request(pane_request(
            "pane-notify-missing-title",
            "notify",
            "two-token",
            true,
            ["--title", "   "],
        ))
        .expect("missing title notify ipc request should produce error")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("missing_title")
    );
    assert_eq!(running.pane_notifications().len(), 2);

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_worklane_color_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-worklane-color-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-worklane-color-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(running.active_worklane_color(), None);
    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-color-blue",
                "worklane-color",
                "two-token",
                true,
                ["--color", "blue"]
            ))
            .expect("worklane color ipc request should handle"),
        ipc_success_response("pane-worklane-color-blue")
    );
    assert_eq!(
        running.active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-color-invalid",
                "worklane-color",
                "two-token",
                true,
                ["--color", "ultraviolet"]
            ))
            .expect("invalid worklane color ipc request should no-op"),
        ipc_success_response("pane-worklane-color-invalid")
    );
    assert_eq!(
        running.active_worklane_color(),
        Some(WorklaneColor::Blue.raw_value())
    );

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-color-reset",
                "worklane-color",
                "two-token",
                true,
                ["--color", "default"]
            ))
            .expect("worklane color reset ipc request should handle"),
        ipc_success_response("pane-worklane-color-reset")
    );
    assert_eq!(running.active_worklane_color(), None);

    let response = running
        .handle_agent_ipc_request(pane_request(
            "pane-worklane-color-missing-worklane",
            "worklane-color",
            "two-token",
            true,
            ["--id", "missing", "--color", "blue"],
        ))
        .expect("missing worklane color ipc request should produce error")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("worklane_not_found")
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_worklane_rename_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-worklane-rename-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-worklane-rename-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(running.active_worklane_title(), None);
    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-rename-title",
                "worklane-rename",
                "two-token",
                true,
                ["--title", " Agent Lane "]
            ))
            .expect("worklane rename ipc request should handle"),
        ipc_success_response("pane-worklane-rename-title")
    );
    assert_eq!(running.active_worklane_title(), Some("Agent Lane"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-rename-flag-title",
                "worklane-rename",
                "two-token",
                true,
                ["--title", "--clear"]
            ))
            .expect("flag-looking title should be consumed as title value"),
        ipc_success_response("pane-worklane-rename-flag-title")
    );
    assert_eq!(running.active_worklane_title(), Some("--clear"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-worklane-rename-clear",
                "worklane-rename",
                "two-token",
                true,
                ["--clear"]
            ))
            .expect("worklane clear ipc request should handle"),
        ipc_success_response("pane-worklane-rename-clear")
    );
    assert_eq!(running.active_worklane_title(), None);

    let response = running
        .handle_agent_ipc_request(pane_request(
            "pane-worklane-rename-missing-worklane",
            "worklane-rename",
            "two-token",
            true,
            ["--id", "missing", "--title", "Agent Lane"],
        ))
        .expect("missing worklane rename ipc request should produce error")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("worklane_not_found")
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_theme_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 320.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 320.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-theme-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-theme-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(running.theme_mode(), AppearanceThemeMode::AlwaysDark);
    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-theme-toggle",
                "theme",
                "two-token",
                true,
                ["toggle"]
            ))
            .expect("theme toggle ipc request should handle"),
        ipc_stdout_response("pane-theme-toggle", "light\n")
    );
    assert_eq!(running.theme_mode(), AppearanceThemeMode::AlwaysLight);

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-theme-auto",
                "theme",
                "two-token",
                true,
                ["auto"]
            ))
            .expect("theme auto ipc request should handle"),
        ipc_stdout_response("pane-theme-auto", "auto\n")
    );
    assert_eq!(running.theme_mode(), AppearanceThemeMode::FollowMacOS);

    let response = running
        .handle_agent_ipc_request(pane_request(
            "pane-theme-unsupported",
            "theme",
            "two-token",
            true,
            ["sepia"],
        ))
        .expect("unsupported theme ipc request should produce error")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("unsupported_command")
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_handles_authenticated_split_pane_ipc_requests() {
    let plan = layout_plan(
        "pane-two",
        vec![
            pane_in_column("pane-one", "column-one", 0, 0, 300.0, Some(480.0)),
            pane_in_column("pane-two", "column-two", 1, 0, 500.0, Some(480.0)),
        ],
    );
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-pane-split-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "pane-split-ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-one", "one-token")
    .with_pane_token(Some("window-main"), "main", "pane-two", "two-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-resize-percent",
                "resize",
                "two-token",
                true,
                ["75%"]
            ))
            .expect("resize percent ipc request should handle"),
        ipc_success_response("pane-resize-percent")
    );
    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-split-left-ratio",
                "split",
                "two-token",
                true,
                ["left", "--ratio", "50"]
            ))
            .expect("split left ipc request should handle"),
        ipc_success_response("pane-split-left-ratio")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-3"));

    assert_eq!(
        running
            .handle_agent_ipc_request(pane_request(
                "pane-split-up-equal",
                "split",
                "two-token",
                true,
                ["up", "--equal"]
            ))
            .expect("split up ipc request should handle"),
        ipc_success_response("pane-split-up-equal")
    );
    assert_eq!(running.focused_pane_id(), Some("pane-4"));

    let mut layout = drain_running_layout(&mut running);
    layout.sort_by(|lhs, rhs| lhs.2.cmp(&rhs.2).then(lhs.3.cmp(&rhs.3)));
    assert_eq!(
        layout,
        vec![
            running_layout_entry("pane-one", "column-one", 0, 0, 200.0, Some(480.0)),
            running_layout_entry("pane-3", "column-pane-3", 1, 0, 700.0, Some(480.0)),
            running_layout_entry("pane-4", "column-two", 2, 0, 500.0, Some(1.0)),
            running_layout_entry("pane-two", "column-two", 2, 1, 500.0, Some(1.0)),
        ]
    );
}

#[test]
#[cfg(windows)]
fn running_app_canonicalizes_agent_signal_ipc_request_to_authenticated_pane() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_CANONICAL_IPC");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "valid-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    let mut request = agent_signal_request("ipc-canonical", "valid-token", true);
    request.arguments.extend([
        "--pane-id".to_string(),
        "pane-one".to_string(),
        "--worklane-id".to_string(),
        "main".to_string(),
    ]);

    assert_eq!(
        running
            .handle_agent_ipc_request(request)
            .expect("ipc request should handle"),
        Some(AgentIpcResponse {
            version: 1,
            id: "ipc-canonical".to_string(),
            ok: true,
            result: Some(AgentIpcResponseResult::default()),
            error: None,
        })
    );
    assert_eq!(
        running
            .execute_palette_item_with_recorded_shell_state(&CommandPaletteItemId::task_runner(
                &task.id
            ))
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInFocusedPane {
            pane_id: "pane-two".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_CANONICAL_IPC".to_string(),
        }
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_rejects_agent_signal_ipc_request_with_invalid_pane_token() {
    let first = minimal_pane_spec_with_id("pane-one");
    let second = minimal_pane_spec_with_id("pane-two");
    let task = runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_REJECTED_IPC");
    let plan = AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: vec![task.clone()],
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some("pane-two".to_string()),
                panes: vec![first, second],
            }],
        }],
    };
    let ipc_environment = AgentIpcRuntimeEnvironment::new(
        r"\\.\pipe\zentty-ipc-test",
        r"C:\Zentty\zentty-win.exe",
        "ipc-instance",
    )
    .with_pane_token(Some("window-main"), "main", "pane-two", "valid-token");
    let mut running =
        RunningApp::spawn_with_agent_ipc(plan, TerminalSize::new(80, 24), ipc_environment)
            .expect("running app should spawn panes");

    let response = running
        .handle_agent_ipc_request(agent_signal_request("ipc-reject", "wrong-token", true))
        .expect("ipc request should produce error response")
        .expect("response should be present");
    assert!(!response.ok);
    assert_eq!(response.id, "ipc-reject");
    assert_eq!(
        response.error.as_ref().map(|error| error.code.as_str()),
        Some("invalid_pane_token")
    );
    assert_eq!(
        running
            .execute_palette_item_with_recorded_shell_state(&CommandPaletteItemId::task_runner(
                &task.id
            ))
            .expect("task runner palette item should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: "pane-3".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_REJECTED_IPC".to_string(),
        }
    );

    for pane_id in running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>()
    {
        if let Some(mut pane) = running.take_pane(&pane_id) {
            pane.terminate().ok();
        }
    }
}

#[test]
#[cfg(windows)]
fn running_app_task_runner_new_pane_preserves_environment_when_focused_pane_is_busy() {
    let plan = layout_plan("pane-main", vec![minimal_pane_spec()]);
    let mut running =
        RunningApp::spawn(plan, TerminalSize::new(80, 24)).expect("running app should spawn pane");
    let action = runtime_task_runner_action("echo ZENTTY_TASK_RUNNER_NEW %NODE_ENV%")
        .with_environment("NODE_ENV", "production");

    assert_eq!(
        running
            .run_task_runner(&action, TaskRunnerShellActivityState::PromptIdle, true,)
            .expect("task runner should execute"),
        CommandPaletteItemExecutionResult::RunTaskRunnerInNewPane {
            pane_id: "pane-2".to_string(),
            command: "echo ZENTTY_TASK_RUNNER_NEW %NODE_ENV%".to_string(),
        }
    );
    assert_eq!(running.pane_ids(), vec!["pane-main", "pane-2"]);
    assert_eq!(running.focused_pane_id(), Some("pane-2"));

    running
        .write_to_focused(b"exit\r")
        .expect("task pane should accept exit");
    running
        .write_to_pane("pane-main", b"echo ZENTTY_TASK_RUNNER_ORIGINAL\rexit\r")
        .expect("original pane should remain usable");

    let original_output = running
        .take_pane("pane-main")
        .expect("original pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("original pane should exit");
    let new_output = running
        .take_pane("pane-2")
        .expect("new task pane should be running")
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("new task pane should exit");

    assert!(new_output.output.contains("ZENTTY_TASK_RUNNER_NEW"));
    assert!(new_output.output.contains("production"));
    assert!(!original_output.output.contains("ZENTTY_TASK_RUNNER_NEW"));
    assert!(
        original_output
            .output
            .contains("ZENTTY_TASK_RUNNER_ORIGINAL")
    );
}

#[test]
#[cfg(windows)]
fn running_pane_streams_output_before_process_exit() {
    let spec = minimal_pane_spec();
    let mut running = RunningApp::spawn(
        AppLaunchPlan {
            active_window_id: Some("window-main".to_string()),
            windows: vec![zentty_win::app::WindowLaunchPlan {
                window_id: "window-main".to_string(),
                active_worklane_id: Some("main".to_string()),
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
                worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "main".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-main".to_string()),
                    panes: vec![spec],
                }],
            }],
        },
        TerminalSize::new(80, 24),
    )
    .expect("running app should spawn pane");
    let pane = running
        .take_pane("pane-main")
        .expect("pane should be running");
    let mut stream = pane
        .into_output_stream()
        .expect("pane should convert to streaming mode");

    stream
        .write_all(b"echo ZENTTY_STREAM_BEFORE_EXIT\r")
        .expect("streaming pane should accept input");
    let early_output = stream
        .read_until_contains(
            "ZENTTY_STREAM_BEFORE_EXIT",
            std::time::Duration::from_secs(5),
        )
        .expect("streaming pane should produce output before exit");
    assert!(early_output.contains("ZENTTY_STREAM_BEFORE_EXIT"));

    stream
        .write_all(b"exit\r")
        .expect("streaming pane should accept exit");
    let final_output = stream
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("streaming pane should exit");
    assert!(final_output.output.contains("ZENTTY_STREAM_BEFORE_EXIT"));
}

#[test]
#[cfg(windows)]
fn running_pane_stream_can_update_terminal_screen_model() {
    let spec = minimal_pane_spec();
    let mut running = RunningApp::spawn(
        AppLaunchPlan {
            active_window_id: Some("window-main".to_string()),
            windows: vec![zentty_win::app::WindowLaunchPlan {
                window_id: "window-main".to_string(),
                active_worklane_id: Some("main".to_string()),
                focus_history: PaneFocusHistory::default(),
                closed_pane_stack: ClosedPaneStack::default(),
                open_with_targets: Vec::new(),
                detected_servers: Vec::new(),
                task_runner_actions: Vec::new(),
                branch_urls_by_pane_id: BTreeMap::new(),
                worklane_colors_by_id: BTreeMap::new(),
                worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                    worklane_id: "main".to_string(),
                    title: None,
                    focused_pane_id: Some("pane-main".to_string()),
                    panes: vec![spec],
                }],
            }],
        },
        TerminalSize::new(80, 24),
    )
    .expect("running app should spawn pane");
    let pane = running
        .take_pane("pane-main")
        .expect("pane should be running");
    let mut stream = pane
        .into_output_stream()
        .expect("pane should convert to streaming mode");
    let mut screen = TerminalScreen::new(80, 2);

    stream
        .write_all(b"echo ZENTTY_SCREEN_MODEL\recho ZENTTY_SCREEN_SCROLLBACK\r")
        .expect("streaming pane should accept input");
    stream
        .read_into_screen_until_contains(
            &mut screen,
            "ZENTTY_SCREEN_SCROLLBACK",
            std::time::Duration::from_secs(5),
        )
        .expect("stream should update terminal screen");
    stream.write_all(b"exit\r").expect("pane should exit");
    let _ = stream
        .wait_with_output(std::time::Duration::from_secs(5))
        .expect("pane should finish");

    assert!(
        screen
            .all_lines()
            .iter()
            .any(|line| line.contains("ZENTTY_SCREEN_MODEL")),
        "screen history was: {:?}",
        screen.all_lines()
    );
    assert!(
        screen
            .all_lines()
            .iter()
            .any(|line| line.contains("ZENTTY_SCREEN_SCROLLBACK")),
        "screen history was: {:?}",
        screen.all_lines()
    );
    assert!(
        !screen.scrollback_lines().is_empty(),
        "small renderer should retain scrolled output"
    );
}

fn workspace_window(
    window_id: &str,
    cwd: &Path,
    panes: Vec<WorkspaceRecipePane>,
) -> WorkspaceRecipeWindow {
    WorkspaceRecipeWindow {
        id: window_id.to_string(),
        active_worklane_id: Some("main".to_string()),
        worklanes: vec![WorkspaceRecipeWorklane {
            id: "main".to_string(),
            title: Some("MAIN".to_string()),
            next_pane_number: 3,
            focused_column_id: Some("column-main".to_string()),
            columns: vec![WorkspaceRecipeColumn {
                id: "column-main".to_string(),
                width: 640.0,
                focused_pane_id: Some("pane-shell".to_string()),
                last_focused_pane_id: Some("pane-shell".to_string()),
                pane_heights: vec![360.0; panes.len()],
                panes: panes
                    .into_iter()
                    .map(|mut pane| {
                        pane.working_directory = Some(cwd.to_string_lossy().to_string());
                        pane
                    })
                    .collect(),
            }],
            color: None,
            bookmark_origin_id: None,
        }],
    }
}

fn pane(
    id: &str,
    title: &str,
    last_activity_title: Option<&str>,
    last_run_command: Option<&str>,
) -> WorkspaceRecipePane {
    WorkspaceRecipePane {
        id: id.to_string(),
        title_seed: Some(title.to_string()),
        working_directory: None,
        last_activity_title: last_activity_title.map(str::to_string),
        last_run_command: last_run_command.map(str::to_string),
    }
}

fn minimal_pane_spec() -> zentty_win::app::PaneLaunchSpec {
    minimal_pane_spec_with_id("pane-main")
}

fn minimal_pane_spec_with_id(pane_id: &str) -> zentty_win::app::PaneLaunchSpec {
    zentty_win::app::PaneLaunchSpec {
        pane_id: pane_id.to_string(),
        worklane_id: "main".to_string(),
        column_id: "column-main".to_string(),
        column_index: 0,
        pane_index: 0,
        title: "shell".to_string(),
        column_width: 640.0,
        pane_height: Some(480.0),
        terminal_request: TerminalSessionRequest::default(),
        restored_rerunnable_command: None,
        status_text: None,
        applied_restore_draft_tool: None,
    }
}

fn runtime_task_runner_action(command: &str) -> TaskRunnerAction {
    TaskRunnerAction::new(
        "packageScript|C:\\Projects\\zentty\\package.json|dev",
        "dev",
        None,
        TaskRunnerSourceKind::PackageScript,
        "C:\\Projects\\zentty\\package.json",
        command,
        None,
    )
    .with_source_root("C:\\Projects\\zentty")
    .with_working_directory("C:\\Projects\\zentty")
}

fn agent_signal_request(id: &str, pane_token: &str, expects_response: bool) -> AgentIpcRequest {
    AgentIpcRequest {
        version: 1,
        id: id.to_string(),
        kind: AgentIpcRequestKind::Ipc,
        arguments: vec!["shell-state".to_string(), "prompt".to_string()],
        standard_input: None,
        environment: BTreeMap::from([
            ("ZENTTY_WINDOW_ID".to_string(), "window-main".to_string()),
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-two".to_string()),
            ("ZENTTY_PANE_TOKEN".to_string(), pane_token.to_string()),
        ]),
        expects_response,
        subcommand: Some("agent-signal".to_string()),
        tool: None,
    }
}

fn pane_list_request<'a, I>(
    id: &str,
    pane_token: &str,
    expects_response: bool,
    arguments: I,
) -> AgentIpcRequest
where
    I: IntoIterator<Item = &'a str>,
{
    pane_request(id, "list", pane_token, expects_response, arguments)
}

fn pane_request<'a, I>(
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
            ("ZENTTY_PANE_ID".to_string(), "pane-two".to_string()),
            ("ZENTTY_PANE_TOKEN".to_string(), pane_token.to_string()),
        ]),
        expects_response,
        subcommand: Some(subcommand.to_string()),
        tool: None,
    }
}

fn ipc_success_response(id: &str) -> Option<AgentIpcResponse> {
    Some(AgentIpcResponse {
        version: 1,
        id: id.to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    })
}

fn ipc_stdout_response(id: &str, stdout: &str) -> Option<AgentIpcResponse> {
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

fn pane_in_column(
    pane_id: &str,
    column_id: &str,
    column_index: usize,
    pane_index: usize,
    column_width: f64,
    pane_height: Option<f64>,
) -> zentty_win::app::PaneLaunchSpec {
    zentty_win::app::PaneLaunchSpec {
        column_id: column_id.to_string(),
        column_index,
        pane_index,
        column_width,
        pane_height,
        ..minimal_pane_spec_with_id(pane_id)
    }
}

fn layout_plan(
    focused_pane_id: &str,
    panes: Vec<zentty_win::app::PaneLaunchSpec>,
) -> AppLaunchPlan {
    AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some("main".to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: vec![zentty_win::app::WorklaneLaunchPlan {
                worklane_id: "main".to_string(),
                title: None,
                focused_pane_id: Some(focused_pane_id.to_string()),
                panes,
            }],
        }],
    }
}

fn three_worklane_plan(active_worklane_id: &str) -> AppLaunchPlan {
    AppLaunchPlan {
        active_window_id: Some("window-main".to_string()),
        windows: vec![zentty_win::app::WindowLaunchPlan {
            window_id: "window-main".to_string(),
            active_worklane_id: Some(active_worklane_id.to_string()),
            focus_history: PaneFocusHistory::default(),
            closed_pane_stack: ClosedPaneStack::default(),
            open_with_targets: Vec::new(),
            detected_servers: Vec::new(),
            task_runner_actions: Vec::new(),
            branch_urls_by_pane_id: BTreeMap::new(),
            worklane_colors_by_id: BTreeMap::new(),
            worklanes: ["alpha", "beta", "gamma"]
                .into_iter()
                .map(|worklane_id| {
                    let pane_id = format!("pane-{worklane_id}");
                    zentty_win::app::WorklaneLaunchPlan {
                        worklane_id: worklane_id.to_string(),
                        title: Some(worklane_id.to_string()),
                        focused_pane_id: Some(pane_id.clone()),
                        panes: vec![zentty_win::app::PaneLaunchSpec {
                            worklane_id: worklane_id.to_string(),
                            ..minimal_pane_spec_with_id(&pane_id)
                        }],
                    }
                })
                .collect(),
        }],
    }
}

fn find_pane<'a>(plan: &'a AppLaunchPlan, pane_id: &str) -> &'a zentty_win::app::PaneLaunchSpec {
    plan.windows
        .iter()
        .flat_map(|window| &window.worklanes)
        .flat_map(|worklane| &worklane.panes)
        .find(|pane| pane.pane_id == pane_id)
        .expect("pane should exist")
}

fn active_panes(plan: &AppLaunchPlan) -> Vec<&zentty_win::app::PaneLaunchSpec> {
    let active_window_id = plan.active_window_id.as_ref().expect("active window id");
    let window = plan
        .windows
        .iter()
        .find(|window| &window.window_id == active_window_id)
        .expect("active window");
    let active_worklane_id = window
        .active_worklane_id
        .as_ref()
        .expect("active worklane id");
    let mut panes = window
        .worklanes
        .iter()
        .find(|worklane| &worklane.worklane_id == active_worklane_id)
        .expect("active worklane")
        .panes
        .iter()
        .collect::<Vec<_>>();
    panes.sort_by_key(|pane| (pane.column_index, pane.pane_index, pane.pane_id.clone()));
    panes
}

fn assert_column_widths(plan: &AppLaunchPlan, expected_widths: &[f64]) {
    let widths = active_panes(plan)
        .into_iter()
        .map(|pane| pane.column_width)
        .collect::<Vec<_>>();
    assert_eq!(widths.len(), expected_widths.len());
    for (actual, expected) in widths.into_iter().zip(expected_widths) {
        assert_close(actual, *expected);
    }
}

#[allow(clippy::type_complexity)]
fn pane_layout(plan: &AppLaunchPlan) -> Vec<(&str, &str, usize, usize, f64, Option<f64>)> {
    active_panes(plan)
        .into_iter()
        .map(|pane| {
            (
                pane.pane_id.as_str(),
                pane.column_id.as_str(),
                pane.column_index,
                pane.pane_index,
                pane.column_width,
                pane.pane_height,
            )
        })
        .collect()
}

fn drain_running_layout(
    running: &mut RunningApp,
) -> Vec<(String, String, usize, usize, f64, Option<f64>)> {
    let pane_ids = running
        .pane_ids()
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut layout = Vec::new();

    for pane_id in pane_ids {
        let mut pane = running
            .take_pane(&pane_id)
            .expect("running pane should be available");
        layout.push((
            pane.spec.pane_id.clone(),
            pane.spec.column_id.clone(),
            pane.spec.column_index,
            pane.spec.pane_index,
            pane.spec.column_width,
            pane.spec.pane_height,
        ));
        pane.terminate().expect("running pane should terminate");
    }

    layout
}

fn running_layout_entry(
    pane_id: &str,
    column_id: &str,
    column_index: usize,
    pane_index: usize,
    column_width: f64,
    pane_height: Option<f64>,
) -> (String, String, usize, usize, f64, Option<f64>) {
    (
        pane_id.to_string(),
        column_id.to_string(),
        column_index,
        pane_index,
        column_width,
        pane_height,
    )
}

fn golden_major_ratio() -> f64 {
    let phi = (1.0 + 5.0_f64.sqrt()) / 2.0;
    phi / (1.0 + phi)
}

fn assert_close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() <= 0.001,
        "expected {actual} to be within 0.001 of {expected}"
    );
}

fn focused_pane_id(plan: &AppLaunchPlan) -> Option<&str> {
    let active_window_id = plan.active_window_id.as_ref()?;
    plan.windows
        .iter()
        .find(|window| &window.window_id == active_window_id)
        .and_then(|window| {
            let active_worklane_id = window.active_worklane_id.as_ref()?;
            window
                .worklanes
                .iter()
                .find(|worklane| &worklane.worklane_id == active_worklane_id)
        })
        .and_then(|worklane| worklane.focused_pane_id.as_deref())
}

fn active_worklane_id(plan: &AppLaunchPlan) -> Option<&str> {
    let active_window_id = plan.active_window_id.as_ref()?;
    plan.windows
        .iter()
        .find(|window| &window.window_id == active_window_id)
        .and_then(|window| window.active_worklane_id.as_deref())
}

fn worklane_ids(plan: &AppLaunchPlan) -> Vec<&str> {
    let active_window_id = plan.active_window_id.as_ref().expect("active window id");
    plan.windows
        .iter()
        .find(|window| &window.window_id == active_window_id)
        .expect("active window")
        .worklanes
        .iter()
        .map(|worklane| worklane.worklane_id.as_str())
        .collect()
}

fn test_directory(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("zentty-win-{name}-{}", std::process::id()));
    fs::remove_dir_all(&path).ok();
    fs::create_dir_all(&path).expect("test directory should be created");
    path
}
