use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;
use zentty_core::agent::AgentTool;
use zentty_core::restore::{AgentLaunchSnapshot, PaneRestoreDraft};
use zentty_core::session_restore::{
    LaunchDecisionReason, SaveReason, SessionRestoreDraftWindow, SessionRestoreEnvelope,
    SessionRestoreStore, WorkspaceRecipe, WorkspaceRecipeColumn, WorkspaceRecipePane,
    WorkspaceRecipeWindow, WorkspaceRecipeWorklane,
};

#[test]
fn prepare_for_launch_returns_clean_restore_when_snapshot_exists_and_restore_is_enabled() {
    let dir = test_directory("clean-restore");
    let store = make_store(&dir);
    store
        .save_snapshot(&envelope("window-main"))
        .expect("snapshot should save");
    store
        .mark_launch_started()
        .expect("launch state should save");
    store.mark_clean_exit().expect("clean exit should save");

    let relaunched = make_store(&dir);
    let decision = relaunched
        .prepare_for_launch(true)
        .expect("launch should prepare")
        .expect("snapshot should restore");

    assert_eq!(decision.reason, LaunchDecisionReason::NormalRestore);
    assert_eq!(decision.envelope.workspace.windows[0].id, "window-main");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn prepare_for_launch_returns_crash_recovery_even_when_preference_disabled() {
    let dir = test_directory("crash-recovery");
    let store = make_store(&dir);
    store
        .save_snapshot(&envelope("window-main"))
        .expect("snapshot should save");
    store
        .mark_launch_started()
        .expect("launch state should save");

    let relaunched = make_store(&dir);
    let decision = relaunched
        .prepare_for_launch(false)
        .expect("launch should prepare")
        .expect("crash snapshot should restore");

    assert_eq!(decision.reason, LaunchDecisionReason::CrashRecovery);
    assert_eq!(decision.envelope.workspace.windows[0].id, "window-main");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn clean_exit_snapshot_respects_restore_preference() {
    let dir = test_directory("preference-disabled");
    let store = make_store(&dir);
    store
        .save_snapshot(&envelope("window-main"))
        .expect("snapshot should save");
    store
        .mark_launch_started()
        .expect("launch state should save");
    store.mark_clean_exit().expect("clean exit should save");

    let relaunched = make_store(&dir);
    let decision = relaunched
        .prepare_for_launch(false)
        .expect("launch should prepare");

    assert_eq!(decision, None);
    fs::remove_dir_all(dir).ok();
}

#[test]
fn delete_snapshot_removes_snapshot_file() {
    let dir = test_directory("delete-snapshot");
    let store = make_store(&dir);
    store
        .save_snapshot(&envelope("window-main"))
        .expect("snapshot should save");

    assert!(dir.join("restore-snapshot.json").exists());

    store.delete_snapshot().expect("snapshot should delete");

    assert!(!dir.join("restore-snapshot.json").exists());
    fs::remove_dir_all(dir).ok();
}

#[test]
fn save_snapshot_round_trips_restore_drafts() {
    let dir = test_directory("draft-roundtrip");
    let store = make_store(&dir);
    let envelope = SessionRestoreEnvelope {
        workspace: WorkspaceRecipe {
            windows: vec![WorkspaceRecipeWindow {
                id: "window-main".to_string(),
                worklanes: vec![],
                active_worklane_id: None,
            }],
            ..WorkspaceRecipe::default()
        },
        restore_draft_windows: vec![SessionRestoreDraftWindow {
            window_id: "window-main".to_string(),
            pane_drafts: vec![PaneRestoreDraft::agent_resume(
                "pane-agent",
                AgentTool::Codex,
                "Codex",
                "session-codex",
                Some("/tmp/project"),
                4242,
                Some(AgentLaunchSnapshot::new(["--sandbox", "workspace-write"])),
            )],
        }],
        ..SessionRestoreEnvelope::default()
    };

    store
        .save_snapshot(&envelope)
        .expect("snapshot should save");
    store
        .mark_launch_started()
        .expect("launch state should save");
    store.mark_clean_exit().expect("clean exit should save");

    let decision = make_store(&dir)
        .prepare_for_launch(true)
        .expect("launch should prepare")
        .expect("snapshot should restore");

    assert_eq!(
        decision.envelope.restore_draft_windows,
        envelope.restore_draft_windows
    );
    fs::remove_dir_all(dir).ok();
}

#[test]
fn clean_exit_save_preserves_existing_restore_drafts_for_matching_panes_only() {
    let dir = test_directory("merge-drafts");
    let store = make_store(&dir);
    let workspace = workspace_with_panes("window-main", ["pane-agent"]);
    let live_envelope = SessionRestoreEnvelope {
        reason: SaveReason::LiveSnapshot,
        workspace: workspace.clone(),
        restore_draft_windows: vec![SessionRestoreDraftWindow {
            window_id: "window-main".to_string(),
            pane_drafts: vec![
                PaneRestoreDraft::agent_resume(
                    "pane-agent",
                    AgentTool::Codex,
                    "Codex",
                    "session-codex",
                    Some("/tmp/project"),
                    4242,
                    None,
                ),
                PaneRestoreDraft::agent_resume(
                    "pane-gone",
                    AgentTool::ClaudeCode,
                    "Claude Code",
                    "237d8c32-2a27-4850-8da8-3a110f13682c",
                    Some("/tmp/project"),
                    4243,
                    None,
                ),
            ],
        }],
        ..SessionRestoreEnvelope::default()
    };
    let clean_exit = SessionRestoreEnvelope {
        reason: SaveReason::CleanExit,
        workspace,
        restore_draft_windows: vec![],
        ..SessionRestoreEnvelope::default()
    };

    store
        .save_snapshot(&live_envelope)
        .expect("live snapshot should save");
    store
        .save_snapshot(&clean_exit)
        .expect("clean exit snapshot should save");
    store
        .mark_launch_started()
        .expect("launch state should save");
    store.mark_clean_exit().expect("clean exit should save");

    let decision = make_store(&dir)
        .prepare_for_launch(true)
        .expect("launch should prepare")
        .expect("snapshot should restore");
    let drafts = &decision.envelope.restore_draft_windows[0].pane_drafts;

    assert_eq!(decision.envelope.reason, SaveReason::CleanExit);
    assert_eq!(drafts.len(), 1);
    assert_eq!(drafts[0].pane_id, "pane-agent");
    fs::remove_dir_all(dir).ok();
}

#[test]
fn restore_draft_json_matches_swift_field_names_without_rust_tool_field() {
    let draft = PaneRestoreDraft::agent_resume(
        "pane-agent",
        AgentTool::Codex,
        "Codex",
        "019e4548-2fab-7542-9d5b-378a5da96fa5",
        Some("/tmp/project"),
        4242,
        Some(AgentLaunchSnapshot::new(["--sandbox", "workspace-write"])),
    );

    let value = serde_json::to_value(&draft).expect("draft should serialize");

    assert_eq!(value["paneID"], json!("pane-agent"));
    assert_eq!(value["kind"], json!("agentResume"));
    assert_eq!(value["toolName"], json!("Codex"));
    assert_eq!(
        value["sessionID"],
        json!("019e4548-2fab-7542-9d5b-378a5da96fa5")
    );
    assert_eq!(value["workingDirectory"], json!("/tmp/project"));
    assert_eq!(value["trackedPID"], json!(4242));
    assert_eq!(
        value["agentLaunchSnapshot"]["arguments"],
        json!(["--sandbox", "workspace-write"])
    );
    assert!(
        value["agentLaunchSnapshot"].get("environment").is_none(),
        "Swift omits nil launch environments"
    );
    assert!(
        value.get("tool").is_none(),
        "Swift persists toolName, not Rust's resolved AgentTool"
    );
}

#[test]
fn restore_draft_decodes_swift_json_and_resolves_internal_tool() {
    let value = json!({
        "paneID": "pane-agent",
        "kind": "agentResume",
        "toolName": "Claude Code",
        "sessionID": "237d8c32-2a27-4850-8da8-3a110f13682c",
        "workingDirectory": "/tmp/project",
        "trackedPID": 4243,
        "agentLaunchSnapshot": {
            "arguments": ["--continue"],
            "environment": {
                "CLAUDE_CONFIG_DIR": "/tmp/claude"
            }
        }
    });

    let draft: PaneRestoreDraft =
        serde_json::from_value(value).expect("Swift restore draft JSON should decode");

    assert_eq!(draft.pane_id, "pane-agent");
    assert_eq!(draft.tool, AgentTool::ClaudeCode);
    assert_eq!(draft.tool_name, "Claude Code");
    assert_eq!(draft.session_id, "237d8c32-2a27-4850-8da8-3a110f13682c");
    assert_eq!(draft.working_directory.as_deref(), Some("/tmp/project"));
    assert_eq!(draft.tracked_pid, 4243);
    assert_eq!(
        draft
            .agent_launch_snapshot
            .as_ref()
            .and_then(|snapshot| snapshot.environment.get("CLAUDE_CONFIG_DIR")),
        Some(&"/tmp/claude".to_string())
    );
}

fn make_store(dir: &Path) -> SessionRestoreStore {
    SessionRestoreStore::new(
        dir.join("restore-snapshot.json"),
        dir.join("restore-lifecycle.json"),
    )
}

fn test_directory(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "zentty-session-restore-{name}-{}",
        std::process::id()
    ));
    fs::remove_dir_all(&dir).ok();
    fs::create_dir_all(&dir).expect("test directory should be created");
    dir
}

fn envelope(window_id: &str) -> SessionRestoreEnvelope {
    SessionRestoreEnvelope {
        workspace: WorkspaceRecipe {
            windows: vec![WorkspaceRecipeWindow {
                id: window_id.to_string(),
                worklanes: vec![],
                active_worklane_id: None,
            }],
            ..WorkspaceRecipe::default()
        },
        ..SessionRestoreEnvelope::default()
    }
}

fn workspace_with_panes<const N: usize>(window_id: &str, pane_ids: [&str; N]) -> WorkspaceRecipe {
    WorkspaceRecipe {
        windows: vec![WorkspaceRecipeWindow {
            id: window_id.to_string(),
            worklanes: vec![WorkspaceRecipeWorklane {
                id: "main".to_string(),
                title: None,
                next_pane_number: 2,
                focused_column_id: Some("column-main".to_string()),
                columns: vec![WorkspaceRecipeColumn {
                    id: "column-main".to_string(),
                    width: 640.0,
                    focused_pane_id: pane_ids.first().map(|id| id.to_string()),
                    last_focused_pane_id: pane_ids.first().map(|id| id.to_string()),
                    pane_heights: vec![1.0; pane_ids.len()],
                    panes: pane_ids
                        .iter()
                        .map(|id| WorkspaceRecipePane {
                            id: id.to_string(),
                            title_seed: Some("Agent".to_string()),
                            working_directory: Some("/tmp/project".to_string()),
                            last_activity_title: None,
                            last_run_command: None,
                        })
                        .collect(),
                }],
                color: None,
                bookmark_origin_id: None,
            }],
            active_worklane_id: Some("main".to_string()),
        }],
        ..WorkspaceRecipe::default()
    }
}
