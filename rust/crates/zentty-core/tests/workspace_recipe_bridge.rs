use std::fs;

use serde_json::{Value, json};
use zentty_core::layout::{PaneColumnId, PaneColumnState, PaneId, PaneState, PaneStripState};
use zentty_core::session_restore::{
    WindowWorkspaceState, WorkspaceRecipe, WorkspaceRecipeColumn, WorkspaceRecipeExporter,
    WorkspaceRecipeImporter, WorkspaceRecipePane, WorkspaceRecipeWindow, WorkspaceRecipeWorklane,
};
use zentty_core::worklane::WorklaneState;

#[test]
fn exporter_persists_window_worklanes_layout_focus_and_pane_metadata() {
    let window = WorkspaceRecipeExporter::make_window(
        "window-main",
        &[main_worklane(), review_worklane()],
        Some("main"),
    );

    assert_eq!(window.id, "window-main");
    assert_eq!(window.active_worklane_id.as_deref(), Some("main"));
    assert_eq!(window.worklanes.len(), 2);
    assert_eq!(window.worklanes[0].id, "main");
    assert_eq!(window.worklanes[0].title, None);
    assert_eq!(window.worklanes[0].next_pane_number, 4);
    assert_eq!(
        window.worklanes[0].focused_column_id.as_deref(),
        Some("column-left")
    );
    assert_eq!(
        window.worklanes[0]
            .columns
            .iter()
            .map(|column| column.width)
            .collect::<Vec<_>>(),
        vec![420.0, 360.0]
    );
    assert_eq!(
        window.worklanes[0].columns[0].pane_heights,
        vec![320.0, 180.0]
    );
    assert_eq!(
        window.worklanes[0].columns[0]
            .panes
            .iter()
            .map(|pane| pane.working_directory.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("C:\\Projects\\api"), Some("C:\\Projects\\api")]
    );
    assert_eq!(
        window.worklanes[0].columns[0]
            .panes
            .iter()
            .map(|pane| pane.title_seed.as_deref())
            .collect::<Vec<_>>(),
        vec![Some("API shell"), Some("Test runner")]
    );
}

#[test]
fn importer_rebuilds_worklanes_from_workspace_recipe_window() {
    let window = WorkspaceRecipeExporter::make_window(
        "window-main",
        &[main_worklane(), review_worklane()],
        Some("main"),
    );

    let restored = WorkspaceRecipeImporter::make_worklanes(&window);

    assert_eq!(
        restored,
        WindowWorkspaceState {
            worklanes: restored.worklanes.clone(),
            active_worklane_id: Some("main".to_string()),
        }
    );
    assert_eq!(
        restored
            .worklanes
            .iter()
            .map(|worklane| worklane.id.as_str())
            .collect::<Vec<_>>(),
        vec!["main", "review"]
    );
    assert_eq!(restored.worklanes[1].title.as_deref(), Some("REVIEW"));
    assert_eq!(restored.worklanes[0].next_pane_number, 4);
    assert_eq!(
        restored.worklanes[0]
            .pane_strip_state
            .columns()
            .iter()
            .map(|column| column.width)
            .collect::<Vec<_>>(),
        vec![420.0, 360.0]
    );
    assert_eq!(
        restored.worklanes[0].pane_strip_state.columns()[0].pane_heights(),
        &[320.0, 180.0]
    );
    assert_eq!(
        restored.worklanes[0]
            .pane_strip_state
            .focused_pane_id()
            .map(PaneId::as_str),
        Some("pane-bottom")
    );

    let right_pane = restored.worklanes[0]
        .pane_strip_state
        .columns()
        .iter()
        .flat_map(|column| column.panes())
        .find(|pane| pane.id().as_str() == "pane-right")
        .expect("right pane should restore");

    assert_eq!(right_pane.title(), "Editor");
    assert_eq!(
        right_pane.session_request.working_directory.as_deref(),
        Some("C:\\Projects\\web")
    );
}

#[test]
fn workspace_recipe_json_uses_swift_field_names() {
    let recipe = WorkspaceRecipe {
        windows: vec![WorkspaceRecipeExporter::make_window(
            "window-main",
            &[main_worklane()],
            Some("main"),
        )],
        active_window_id: Some("window-main".to_string()),
        ..WorkspaceRecipe::default()
    };

    let json = serde_json::to_string(&recipe).expect("recipe should serialize");

    assert!(json.contains("\"schemaVersion\":2"));
    assert!(json.contains("\"activeWindowID\":\"window-main\""));
    assert!(json.contains("\"activeWorklaneID\":\"main\""));
    assert!(json.contains("\"focusedColumnID\":\"column-left\""));
    assert!(json.contains("\"focusedPaneID\":\"pane-bottom\""));
    assert!(json.contains("\"lastFocusedPaneID\":\"pane-bottom\""));
    assert!(json.contains("\"paneHeights\":[320.0,180.0]"));
    assert!(json.contains("\"titleSeed\":\"API shell\""));
    assert!(json.contains("\"workingDirectory\":\"C:\\\\Projects\\\\api\""));
}

#[test]
fn exporter_persists_last_run_command_from_local_auxiliary_state() {
    let working_directory = test_directory("export-local-rerun-command");
    let command = "pnpm start:staging\nnpm run smoke";
    let worklane = worklane_with_auxiliary(
        single_pane_worklane("main", "pane-main", "shell", &working_directory),
        json!({
            "pane-main": {
                "raw": {
                    "shell_context": {
                        "scope": "local",
                        "path": working_directory,
                        "home": "C:\\Users\\peter",
                        "user": "peter"
                    },
                    "last_run_command": command
                },
                "presentation": {
                    "cwd": working_directory,
                    "last_activity_title": "pnpm start:staging"
                }
            }
        }),
    );

    let window = WorkspaceRecipeExporter::make_window("window-main", &[worklane], Some("main"));
    let pane = &window.worklanes[0].columns[0].panes[0];

    assert_eq!(
        pane.working_directory.as_deref(),
        Some(working_directory.as_str())
    );
    assert_eq!(pane.last_run_command.as_deref(), Some(command));
}

#[test]
fn exporter_drops_last_run_command_for_remote_auxiliary_state() {
    let worklane = worklane_with_auxiliary(
        single_pane_worklane("main", "pane-main", "shell", "C:\\Users\\peter"),
        json!({
            "pane-main": {
                "raw": {
                    "shell_context": {
                        "scope": "remote",
                        "path": "/srv/app",
                        "home": "/home/peter",
                        "user": "peter",
                        "host": "example.com"
                    },
                    "last_run_command": "pnpm start:staging"
                },
                "presentation": {
                    "cwd": "/srv/app",
                    "is_remote_shell": true
                }
            }
        }),
    );

    let window = WorkspaceRecipeExporter::make_window("window-main", &[worklane], Some("main"));
    let pane = &window.worklanes[0].columns[0].panes[0];

    assert_eq!(pane.working_directory, None);
    assert_eq!(pane.last_run_command, None);
}

#[test]
fn importer_restores_last_run_command_as_one_shot_without_auto_launching() {
    let working_directory = test_directory("import-rerun-command");
    let command = "pnpm start:staging\nnpm run smoke";
    let window = recipe_window_with_single_pane(
        &working_directory,
        Some("pnpm start:staging"),
        Some(command),
    );

    let restored = WorkspaceRecipeImporter::make_worklanes(&window);
    let pane = restored.worklanes[0].pane_strip_state.columns()[0].panes()[0].clone();
    let worklane_json = serde_json::to_value(&restored.worklanes[0])
        .expect("worklane should serialize with auxiliary state");

    assert_eq!(pane.session_request.command, None);
    assert_eq!(
        worklane_json.pointer("/auxiliary_state_by_pane_id/pane-main/raw/last_run_command"),
        Some(&json!(command))
    );
    assert_eq!(
        worklane_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/raw/restored_rerunnable_command"),
        Some(&json!(command))
    );
}

#[test]
fn importer_drops_rerunnable_command_when_working_directory_is_missing() {
    let missing_directory = format!(
        "{}\\missing-rerun-command-{}",
        std::env::temp_dir().to_string_lossy(),
        std::process::id()
    );
    let window = recipe_window_with_single_pane(
        &missing_directory,
        Some("pnpm start:staging"),
        Some("pnpm start:staging"),
    );

    let restored = WorkspaceRecipeImporter::make_worklanes(&window);
    let pane = restored.worklanes[0].pane_strip_state.columns()[0].panes()[0].clone();
    let worklane_json = serde_json::to_value(&restored.worklanes[0])
        .expect("worklane should serialize with auxiliary state");

    assert_eq!(pane.session_request.command, None);
    assert_eq!(
        worklane_json.pointer("/auxiliary_state_by_pane_id/pane-main/presentation/status_text"),
        Some(&json!("Original path unavailable"))
    );
    assert_eq!(
        worklane_json.pointer("/auxiliary_state_by_pane_id/pane-main/raw/last_run_command"),
        None
    );
    assert_eq!(
        worklane_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/raw/restored_rerunnable_command"),
        None
    );
}

#[test]
fn importer_treats_legacy_local_process_title_as_last_activity_and_one_shot_command() {
    let working_directory = test_directory("import-legacy-title-rerun-command");
    let window = recipe_window_with_single_pane_title_seed(
        &working_directory,
        "cmatrix -C cyan",
        None,
        None,
    );

    let restored = WorkspaceRecipeImporter::make_worklanes(&window);
    let pane = restored.worklanes[0].pane_strip_state.columns()[0].panes()[0].clone();
    let worklane_json = serde_json::to_value(&restored.worklanes[0])
        .expect("worklane should serialize with auxiliary state");

    assert_eq!(pane.title(), "shell");
    assert_eq!(
        worklane_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/presentation/remembered_title"),
        None
    );
    assert_eq!(
        worklane_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/presentation/last_activity_title"),
        Some(&json!("cmatrix -C cyan"))
    );
    assert_eq!(
        worklane_json.pointer("/auxiliary_state_by_pane_id/pane-main/raw/last_run_command"),
        None
    );
    assert_eq!(
        worklane_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/raw/restored_rerunnable_command"),
        Some(&json!("cmatrix -C cyan"))
    );
}

#[test]
fn importer_treats_legacy_last_activity_title_as_one_shot_command_only_when_command_like() {
    let working_directory = test_directory("import-legacy-last-activity-rerun-command");
    let command_window = recipe_window_with_single_pane(&working_directory, Some("pnpm dev"), None);
    let status_window = recipe_window_with_single_pane(
        &working_directory,
        Some("\u{273b} we need to...me ago, somehow (Branch)"),
        None,
    );

    let command_restored = WorkspaceRecipeImporter::make_worklanes(&command_window);
    let command_json = serde_json::to_value(&command_restored.worklanes[0])
        .expect("worklane should serialize with auxiliary state");
    let status_restored = WorkspaceRecipeImporter::make_worklanes(&status_window);
    let status_json = serde_json::to_value(&status_restored.worklanes[0])
        .expect("worklane should serialize with auxiliary state");

    assert_eq!(
        command_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/raw/restored_rerunnable_command"),
        Some(&json!("pnpm dev"))
    );
    assert_eq!(
        command_json.pointer("/auxiliary_state_by_pane_id/pane-main/raw/last_run_command"),
        None
    );
    assert_eq!(
        status_json
            .pointer("/auxiliary_state_by_pane_id/pane-main/raw/restored_rerunnable_command"),
        None
    );
}

fn main_worklane() -> WorklaneState {
    let mut left = PaneState::new(PaneId::from("pane-left"), "API shell");
    left.width = 420.0;
    left.session_request.working_directory = Some("C:\\Projects\\api".to_string());

    let mut bottom = PaneState::new(PaneId::from("pane-bottom"), "Test runner");
    bottom.width = 420.0;
    bottom.session_request.working_directory = Some("C:\\Projects\\api".to_string());

    let mut right = PaneState::new(PaneId::from("pane-right"), "Editor");
    right.width = 360.0;
    right.session_request.working_directory = Some("C:\\Projects\\web".to_string());

    let mut worklane = WorklaneState::new(
        "main",
        PaneStripState::new(
            vec![
                PaneColumnState::new(
                    PaneColumnId::from("column-left"),
                    vec![left, bottom],
                    420.0,
                    vec![320.0, 180.0],
                    Some(PaneId::from("pane-bottom")),
                    Some(PaneId::from("pane-bottom")),
                ),
                PaneColumnState::new(
                    PaneColumnId::from("column-right"),
                    vec![right],
                    360.0,
                    vec![500.0],
                    Some(PaneId::from("pane-right")),
                    Some(PaneId::from("pane-right")),
                ),
            ],
            Some(PaneColumnId::from("column-left")),
        ),
    );
    worklane.next_pane_number = 4;
    worklane
}

fn single_pane_worklane(
    worklane_id: &str,
    pane_id: &str,
    title: &str,
    working_directory: &str,
) -> WorklaneState {
    let mut pane = PaneState::new(PaneId::from(pane_id), title);
    pane.width = 640.0;
    pane.session_request.working_directory = Some(working_directory.to_string());

    let mut worklane = WorklaneState::new(
        worklane_id,
        PaneStripState::new(
            vec![PaneColumnState::new(
                PaneColumnId::from("column-main"),
                vec![pane],
                640.0,
                vec![480.0],
                Some(PaneId::from(pane_id)),
                Some(PaneId::from(pane_id)),
            )],
            Some(PaneColumnId::from("column-main")),
        ),
    );
    worklane.next_pane_number = 2;
    worklane
}

fn worklane_with_auxiliary(worklane: WorklaneState, auxiliary_state: Value) -> WorklaneState {
    let mut value = serde_json::to_value(worklane).expect("worklane should serialize");
    value["auxiliary_state_by_pane_id"] = auxiliary_state;
    serde_json::from_value(value).expect("worklane should deserialize with auxiliary state")
}

fn recipe_window_with_single_pane(
    working_directory: &str,
    last_activity_title: Option<&str>,
    last_run_command: Option<&str>,
) -> WorkspaceRecipeWindow {
    recipe_window_with_single_pane_title_seed(
        working_directory,
        "shell",
        last_activity_title,
        last_run_command,
    )
}

fn recipe_window_with_single_pane_title_seed(
    working_directory: &str,
    title_seed: &str,
    last_activity_title: Option<&str>,
    last_run_command: Option<&str>,
) -> WorkspaceRecipeWindow {
    WorkspaceRecipeWindow {
        id: "window-main".to_string(),
        worklanes: vec![WorkspaceRecipeWorklane {
            id: "main".to_string(),
            title: None,
            next_pane_number: 2,
            focused_column_id: Some("column-main".to_string()),
            columns: vec![WorkspaceRecipeColumn {
                id: "column-main".to_string(),
                width: 640.0,
                focused_pane_id: Some("pane-main".to_string()),
                last_focused_pane_id: Some("pane-main".to_string()),
                pane_heights: vec![480.0],
                panes: vec![WorkspaceRecipePane {
                    id: "pane-main".to_string(),
                    title_seed: Some(title_seed.to_string()),
                    working_directory: Some(working_directory.to_string()),
                    last_activity_title: last_activity_title.map(str::to_string),
                    last_run_command: last_run_command.map(str::to_string),
                }],
            }],
            color: None,
            bookmark_origin_id: None,
        }],
        active_worklane_id: Some("main".to_string()),
    }
}

fn test_directory(name: &str) -> String {
    let path = std::env::temp_dir().join(format!("zentty-core-{name}-{}", std::process::id()));
    fs::create_dir_all(&path).expect("test directory should be created");
    path.to_string_lossy().to_string()
}

fn review_worklane() -> WorklaneState {
    let mut review = PaneState::new(PaneId::from("pane-review"), "Review shell");
    review.width = 640.0;
    review.session_request.working_directory = Some("C:\\Projects\\review".to_string());

    let mut worklane = WorklaneState::new(
        "review",
        PaneStripState::new(
            vec![PaneColumnState::new(
                PaneColumnId::from("column-review"),
                vec![review],
                640.0,
                vec![480.0],
                Some(PaneId::from("pane-review")),
                Some(PaneId::from("pane-review")),
            )],
            Some(PaneColumnId::from("column-review")),
        ),
    );
    worklane.title = Some("REVIEW".to_string());
    worklane.next_pane_number = 2;
    worklane
}
