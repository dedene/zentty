use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::layout::{PaneColumnId, PaneColumnState, PaneId, PaneState, PaneStripState};
pub use crate::restore::PaneRestoreDraft;
use crate::worklane::{
    PaneAuxiliaryState, PanePresentationState, PaneRawState, PaneShellContext,
    PaneShellContextScope, WorklaneState,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchDecision {
    pub reason: LaunchDecisionReason,
    pub envelope: SessionRestoreEnvelope,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LaunchDecisionReason {
    NormalRestore,
    CrashRecovery,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SaveReason {
    LiveSnapshot,
    CleanExit,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRestoreEnvelope {
    pub schema_version: i32,
    pub saved_at: i64,
    pub reason: SaveReason,
    pub workspace: WorkspaceRecipe,
    pub restore_draft_windows: Vec<SessionRestoreDraftWindow>,
}

impl SessionRestoreEnvelope {
    pub fn restore_draft_window(&self, window_id: &str) -> Option<&SessionRestoreDraftWindow> {
        self.restore_draft_windows
            .iter()
            .find(|window| window.window_id == window_id)
    }

    pub fn merging_missing_restore_drafts(&self, previous: Option<&Self>) -> Self {
        let Some(previous) = previous else {
            return self.clone();
        };
        let valid_pane_ids_by_window_id = self.workspace.pane_ids_by_window_id();
        if valid_pane_ids_by_window_id.is_empty() {
            return self.clone();
        }

        let mut merged = self.clone();
        let mut existing_pane_ids_by_window_id: BTreeMap<String, BTreeSet<String>> = merged
            .restore_draft_windows
            .iter()
            .map(|window| {
                (
                    window.window_id.clone(),
                    window
                        .pane_drafts
                        .iter()
                        .map(|draft| draft.pane_id.clone())
                        .collect(),
                )
            })
            .collect();

        for previous_window in &previous.restore_draft_windows {
            let Some(valid_pane_ids) = valid_pane_ids_by_window_id.get(&previous_window.window_id)
            else {
                continue;
            };
            let missing_pane_drafts: Vec<_> = previous_window
                .pane_drafts
                .iter()
                .filter(|draft| {
                    valid_pane_ids.contains(&draft.pane_id)
                        && !existing_pane_ids_by_window_id
                            .get(&previous_window.window_id)
                            .is_some_and(|existing| existing.contains(&draft.pane_id))
                })
                .cloned()
                .collect();
            if missing_pane_drafts.is_empty() {
                continue;
            }

            if let Some(window) = merged
                .restore_draft_windows
                .iter_mut()
                .find(|window| window.window_id == previous_window.window_id)
            {
                window.pane_drafts.extend(missing_pane_drafts.clone());
            } else {
                merged
                    .restore_draft_windows
                    .push(SessionRestoreDraftWindow {
                        window_id: previous_window.window_id.clone(),
                        pane_drafts: missing_pane_drafts.clone(),
                    });
            }

            existing_pane_ids_by_window_id
                .entry(previous_window.window_id.clone())
                .or_default()
                .extend(missing_pane_drafts.into_iter().map(|draft| draft.pane_id));
        }

        merged
    }
}

impl Default for SessionRestoreEnvelope {
    fn default() -> Self {
        Self {
            schema_version: 1,
            saved_at: 0,
            reason: SaveReason::LiveSnapshot,
            workspace: WorkspaceRecipe::default(),
            restore_draft_windows: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRestoreDraftWindow {
    #[serde(rename = "windowID")]
    pub window_id: String,
    pub pane_drafts: Vec<PaneRestoreDraft>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecipe {
    pub schema_version: Option<i32>,
    pub windows: Vec<WorkspaceRecipeWindow>,
    #[serde(rename = "activeWindowID", skip_serializing_if = "Option::is_none")]
    pub active_window_id: Option<String>,
}

impl WorkspaceRecipe {
    pub const CURRENT_SCHEMA_VERSION: i32 = 2;

    fn pane_ids_by_window_id(&self) -> BTreeMap<String, BTreeSet<String>> {
        self.windows
            .iter()
            .map(|window| {
                let pane_ids = window
                    .worklanes
                    .iter()
                    .flat_map(|worklane| &worklane.columns)
                    .flat_map(|column| &column.panes)
                    .map(|pane| pane.id.clone())
                    .collect();
                (window.id.clone(), pane_ids)
            })
            .collect()
    }
}

impl Default for WorkspaceRecipe {
    fn default() -> Self {
        Self {
            schema_version: Some(Self::CURRENT_SCHEMA_VERSION),
            windows: Vec::new(),
            active_window_id: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecipeWindow {
    pub id: String,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub worklanes: Vec<WorkspaceRecipeWorklane>,
    #[serde(rename = "activeWorklaneID", skip_serializing_if = "Option::is_none")]
    pub active_worklane_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecipeWorklane {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub next_pane_number: i32,
    #[serde(rename = "focusedColumnID", skip_serializing_if = "Option::is_none")]
    pub focused_column_id: Option<String>,
    pub columns: Vec<WorkspaceRecipeColumn>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(rename = "bookmarkOriginID", skip_serializing_if = "Option::is_none")]
    pub bookmark_origin_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecipeColumn {
    pub id: String,
    pub width: f64,
    #[serde(rename = "focusedPaneID", skip_serializing_if = "Option::is_none")]
    pub focused_pane_id: Option<String>,
    #[serde(rename = "lastFocusedPaneID", skip_serializing_if = "Option::is_none")]
    pub last_focused_pane_id: Option<String>,
    pub pane_heights: Vec<f64>,
    pub panes: Vec<WorkspaceRecipePane>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRecipePane {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title_seed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_run_command: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowWorkspaceState {
    pub worklanes: Vec<WorklaneState>,
    pub active_worklane_id: Option<String>,
}

pub struct WorkspaceRecipeExporter;

impl WorkspaceRecipeExporter {
    pub fn make_window(
        window_id: impl Into<String>,
        worklanes: &[WorklaneState],
        active_worklane_id: Option<&str>,
    ) -> WorkspaceRecipeWindow {
        WorkspaceRecipeWindow {
            id: window_id.into(),
            worklanes: worklanes.iter().map(Self::make_worklane).collect(),
            active_worklane_id: active_worklane_id.map(str::to_string),
        }
    }

    fn make_worklane(worklane: &WorklaneState) -> WorkspaceRecipeWorklane {
        WorkspaceRecipeWorklane {
            id: worklane.id.clone(),
            title: worklane.title.clone(),
            next_pane_number: i32::try_from(worklane.next_pane_number).unwrap_or(i32::MAX),
            focused_column_id: worklane
                .pane_strip_state
                .focused_column_id()
                .map(|id| id.as_str().to_string()),
            columns: worklane
                .pane_strip_state
                .columns()
                .iter()
                .map(|column| Self::make_column(column, worklane))
                .collect(),
            color: None,
            bookmark_origin_id: None,
        }
    }

    fn make_column(column: &PaneColumnState, worklane: &WorklaneState) -> WorkspaceRecipeColumn {
        WorkspaceRecipeColumn {
            id: column.id().as_str().to_string(),
            width: column.width,
            focused_pane_id: column.focused_pane_id().map(|id| id.as_str().to_string()),
            last_focused_pane_id: column
                .last_focused_pane_id()
                .map(|id| id.as_str().to_string()),
            pane_heights: column.pane_heights().to_vec(),
            panes: column
                .panes()
                .iter()
                .map(|pane| Self::make_pane(pane, worklane))
                .collect(),
        }
    }

    fn make_pane(pane: &PaneState, worklane: &WorklaneState) -> WorkspaceRecipePane {
        let auxiliary = worklane.auxiliary_state_by_pane_id.get(pane.id().as_str());
        let is_remote_shell = auxiliary
            .map(PaneAuxiliaryState::is_remote_shell)
            .unwrap_or(false);
        let working_directory = if is_remote_shell {
            None
        } else {
            auxiliary
                .and_then(|state| {
                    state
                        .presentation
                        .cwd
                        .as_deref()
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                })
                .or_else(|| {
                    pane.session_request
                        .working_directory
                        .as_deref()
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                })
        };
        let last_run_command = if is_remote_shell || working_directory.is_none() {
            None
        } else {
            auxiliary
                .and_then(|state| {
                    state
                        .raw
                        .last_run_command
                        .as_deref()
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                })
                .or_else(|| {
                    pane.session_request
                        .command
                        .as_deref()
                        .or(pane.session_request.native_command.as_deref())
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                })
        };

        WorkspaceRecipePane {
            id: pane.id().as_str().to_string(),
            title_seed: auxiliary
                .and_then(|state| {
                    state
                        .presentation
                        .remembered_title
                        .as_deref()
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                })
                .or_else(|| trimmed_non_empty(pane.title()).map(str::to_string)),
            working_directory,
            last_activity_title: auxiliary.and_then(|state| {
                state
                    .presentation
                    .last_activity_title
                    .as_deref()
                    .and_then(trimmed_non_empty)
                    .map(str::to_string)
            }),
            last_run_command,
        }
    }
}

pub struct WorkspaceRecipeImporter;

impl WorkspaceRecipeImporter {
    pub fn make_worklanes(window: &WorkspaceRecipeWindow) -> WindowWorkspaceState {
        let worklanes: Vec<_> = window.worklanes.iter().map(Self::make_worklane).collect();
        let active_worklane_id = window
            .active_worklane_id
            .as_ref()
            .filter(|candidate| worklanes.iter().any(|worklane| &worklane.id == *candidate))
            .cloned()
            .or_else(|| worklanes.first().map(|worklane| worklane.id.clone()));

        WindowWorkspaceState {
            worklanes,
            active_worklane_id,
        }
    }

    fn make_worklane(recipe: &WorkspaceRecipeWorklane) -> WorklaneState {
        let mut auxiliary_state_by_pane_id = BTreeMap::new();
        let columns = recipe
            .columns
            .iter()
            .map(|column| Self::make_column(column, &mut auxiliary_state_by_pane_id))
            .collect();
        let mut worklane = WorklaneState::new(
            recipe.id.clone(),
            PaneStripState::new(
                columns,
                recipe
                    .focused_column_id
                    .as_ref()
                    .map(|id| PaneColumnId::from(id.clone())),
            ),
        );
        worklane.title = recipe.title.clone();
        worklane.next_pane_number = u32::try_from(recipe.next_pane_number.max(1)).unwrap_or(1);
        worklane.auxiliary_state_by_pane_id = auxiliary_state_by_pane_id;
        worklane
    }

    fn make_column(
        recipe: &WorkspaceRecipeColumn,
        auxiliary_state_by_pane_id: &mut BTreeMap<String, PaneAuxiliaryState>,
    ) -> PaneColumnState {
        PaneColumnState::new(
            PaneColumnId::from(recipe.id.clone()),
            recipe
                .panes
                .iter()
                .map(|pane| Self::make_pane(pane, auxiliary_state_by_pane_id))
                .collect(),
            recipe.width,
            recipe.pane_heights.clone(),
            recipe
                .focused_pane_id
                .as_ref()
                .map(|id| PaneId::from(id.clone())),
            recipe
                .last_focused_pane_id
                .as_ref()
                .map(|id| PaneId::from(id.clone())),
        )
    }

    fn make_pane(
        recipe: &WorkspaceRecipePane,
        auxiliary_state_by_pane_id: &mut BTreeMap<String, PaneAuxiliaryState>,
    ) -> PaneState {
        let legacy_last_activity_title = legacy_last_activity_title(recipe);
        let title_seed = if legacy_last_activity_title.is_some() {
            None
        } else {
            recipe.title_seed.as_deref().and_then(trimmed_non_empty)
        };
        let title = title_seed.unwrap_or("shell");
        let mut pane = PaneState::new(PaneId::from(recipe.id.clone()), title);
        let requested_working_directory = recipe
            .working_directory
            .as_deref()
            .and_then(trimmed_non_empty);
        let working_directory_missing = requested_working_directory
            .map(|path| !Path::new(path).is_dir())
            .unwrap_or(false);
        pane.session_request.working_directory = requested_working_directory.map(str::to_string);
        pane.session_request.command = None;

        let can_restore_rerunnable_command =
            requested_working_directory.is_some() && !working_directory_missing;
        let last_run_command = if can_restore_rerunnable_command {
            recipe
                .last_run_command
                .as_deref()
                .and_then(trimmed_non_empty)
                .map(str::to_string)
        } else {
            None
        };
        let legacy_rerunnable_source = recipe
            .last_activity_title
            .as_deref()
            .and_then(trimmed_non_empty)
            .or(legacy_last_activity_title);
        let restored_rerunnable_command = if can_restore_rerunnable_command {
            last_run_command.clone().or_else(|| {
                legacy_rerunnable_source
                    .and_then(legacy_rerunnable_command)
                    .map(str::to_string)
            })
        } else {
            None
        };
        auxiliary_state_by_pane_id.insert(
            recipe.id.clone(),
            PaneAuxiliaryState {
                raw: PaneRawState {
                    shell_context: requested_working_directory.map(|path| PaneShellContext {
                        scope: PaneShellContextScope::Local,
                        path: Some(path.to_string()),
                        home: None,
                        user: None,
                        host: None,
                    }),
                    last_run_command,
                    restored_rerunnable_command,
                },
                presentation: PanePresentationState {
                    cwd: requested_working_directory.map(str::to_string),
                    remembered_title: title_seed.map(str::to_string),
                    last_activity_title: recipe
                        .last_activity_title
                        .as_deref()
                        .and_then(trimmed_non_empty)
                        .map(str::to_string)
                        .or_else(|| legacy_last_activity_title.map(str::to_string)),
                    status_text: working_directory_missing
                        .then(|| "Original path unavailable".to_string()),
                    is_remote_shell: false,
                },
            },
        );
        pane
    }
}

fn legacy_last_activity_title(recipe: &WorkspaceRecipePane) -> Option<&str> {
    if recipe.last_activity_title.is_some() {
        return None;
    }
    let title_seed = recipe.title_seed.as_deref().and_then(trimmed_non_empty)?;
    looks_like_legacy_local_process_title(title_seed).then_some(title_seed)
}

fn legacy_rerunnable_command(value: &str) -> Option<&str> {
    let command = trimmed_non_empty(value)?;
    (!looks_like_ssh_command_title(command)
        && !is_generic_local_shell_title(command)
        && !looks_like_agent_status_title(command)
        && !looks_like_ui_phrase(command))
    .then_some(command)
}

fn looks_like_legacy_local_process_title(value: &str) -> bool {
    if looks_like_ssh_command_title(value) {
        return false;
    }
    let normalized = value.trim();
    let Some(first_word) = normalized.split_whitespace().next() else {
        return false;
    };
    first_word == first_word.to_lowercase()
        && first_word.chars().any(char::is_alphabetic)
        && normalized.contains(' ')
}

fn looks_like_agent_status_title(value: &str) -> bool {
    let trimmed = value.trim();
    let Some(first) = trimmed.chars().next() else {
        return true;
    };
    if !(first.is_alphanumeric() || matches!(first, '.' | '/' | '~' | '$' | '_')) {
        return true;
    }

    let normalized = trimmed.to_lowercase();
    if normalized.contains("(branch)") {
        return true;
    }
    [
        "waiting for your input",
        "waiting for your decision",
        "needs your input",
        "needs your attention",
        "needs your approval",
        "press esc",
        "esc to",
        "tokens",
    ]
    .into_iter()
    .any(|fragment| normalized.contains(fragment))
}

fn looks_like_ssh_command_title(value: &str) -> bool {
    let normalized = value.trim().to_lowercase();
    normalized.starts_with("ssh ") || normalized.starts_with("mosh ")
}

fn is_generic_local_shell_title(value: &str) -> bool {
    let normalized = value.trim().to_lowercase();
    if let Some(number) = normalized.strip_prefix("pane ")
        && !number.is_empty() && number.chars().all(|ch| ch.is_ascii_digit()) {
            return true;
        }
    matches!(
        normalized.as_str(),
        "shell" | "shell pane" | "terminal" | "pane" | "zsh" | "bash" | "sh" | "fish"
    )
}

fn looks_like_ui_phrase(value: &str) -> bool {
    let normalized = value.trim().to_lowercase();
    normalized.contains("...")
        || normalized.contains('…')
        || normalized
            .split(|ch: char| !ch.is_alphanumeric())
            .any(|word| word == "ago")
}

fn trimmed_non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LifecycleState {
    clean_exit: bool,
    updated_at: i64,
}

#[derive(Clone, Debug)]
pub struct SessionRestoreStore {
    snapshot_path: PathBuf,
    lifecycle_path: PathBuf,
}

impl SessionRestoreStore {
    pub fn new(snapshot_path: PathBuf, lifecycle_path: PathBuf) -> Self {
        Self {
            snapshot_path,
            lifecycle_path,
        }
    }

    pub fn prepare_for_launch(
        &self,
        restore_preference_enabled: bool,
    ) -> io::Result<Option<LaunchDecision>> {
        let Some(envelope) = self.load_snapshot()? else {
            return Ok(None);
        };
        let previous_lifecycle = self.load_lifecycle_state()?;
        if previous_lifecycle.is_some_and(|state| !state.clean_exit) {
            return Ok(Some(LaunchDecision {
                reason: LaunchDecisionReason::CrashRecovery,
                envelope,
            }));
        }

        if !restore_preference_enabled {
            return Ok(None);
        }

        Ok(Some(LaunchDecision {
            reason: LaunchDecisionReason::NormalRestore,
            envelope,
        }))
    }

    pub fn mark_launch_started(&self) -> io::Result<()> {
        self.persist(
            &LifecycleState {
                clean_exit: false,
                updated_at: 0,
            },
            &self.lifecycle_path,
        )
    }

    pub fn mark_clean_exit(&self) -> io::Result<()> {
        self.persist(
            &LifecycleState {
                clean_exit: true,
                updated_at: 0,
            },
            &self.lifecycle_path,
        )
    }

    pub fn save_snapshot(&self, envelope: &SessionRestoreEnvelope) -> io::Result<()> {
        let envelope_to_persist = if envelope.reason == SaveReason::CleanExit {
            envelope.merging_missing_restore_drafts(self.load_snapshot()?.as_ref())
        } else {
            envelope.clone()
        };
        self.persist(&envelope_to_persist, &self.snapshot_path)
    }

    pub fn delete_snapshot(&self) -> io::Result<()> {
        if self.snapshot_path.exists() {
            fs::remove_file(&self.snapshot_path)?;
        }
        Ok(())
    }

    fn load_snapshot(&self) -> io::Result<Option<SessionRestoreEnvelope>> {
        self.load(&self.snapshot_path)
    }

    fn load_lifecycle_state(&self) -> io::Result<Option<LifecycleState>> {
        self.load(&self.lifecycle_path)
    }

    fn load<T>(&self, path: &PathBuf) -> io::Result<Option<T>>
    where
        T: for<'de> Deserialize<'de>,
    {
        if !path.exists() {
            return Ok(None);
        }
        let data = fs::read(path)?;
        serde_json::from_slice(&data)
            .map(Some)
            .map_err(io::Error::other)
    }

    fn persist<T>(&self, value: &T, path: &PathBuf) -> io::Result<()>
    where
        T: Serialize,
    {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_vec(value).map_err(io::Error::other)?;
        fs::write(path, data)
    }
}
