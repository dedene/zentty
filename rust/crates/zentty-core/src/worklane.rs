use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::layout::{PaneId, PaneState, PaneStripState, TerminalSessionRequest};
use crate::restore::{
    ClosedPaneCwdResolver, ClosedPaneEntry, ClosedPaneRestoreCommand,
    ClosedPaneRestoreCommandResolver, ClosedPaneStack,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneShellContextScope {
    Local,
    Remote,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PaneShellContext {
    pub scope: PaneShellContextScope,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct PaneRawState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell_context: Option<PaneShellContext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restored_rerunnable_command: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct PanePresentationState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remembered_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_activity_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status_text: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_remote_shell: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct PaneAuxiliaryState {
    #[serde(default)]
    pub raw: PaneRawState,
    #[serde(default)]
    pub presentation: PanePresentationState,
}

impl PaneAuxiliaryState {
    pub fn is_remote_shell(&self) -> bool {
        self.presentation.is_remote_shell
            || matches!(
                self.raw
                    .shell_context
                    .as_ref()
                    .map(|context| &context.scope),
                Some(PaneShellContextScope::Remote)
            )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WorklaneState {
    pub id: String,
    pub title: Option<String>,
    pub pane_strip_state: PaneStripState,
    pub next_pane_number: u32,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub auxiliary_state_by_pane_id: BTreeMap<String, PaneAuxiliaryState>,
}

impl WorklaneState {
    pub fn new(id: impl Into<String>, pane_strip_state: PaneStripState) -> Self {
        Self {
            id: id.into(),
            title: None,
            pane_strip_state,
            next_pane_number: 1,
            auxiliary_state_by_pane_id: BTreeMap::new(),
        }
    }

    pub fn pane_count(&self) -> usize {
        self.pane_strip_state.pane_count()
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PaneCloseSource {
    UserCommand,
    ShellExit,
    Cascade,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PaneCloseResult {
    Closed,
    CloseWindow,
    NotFound,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RestoreClosedPaneResult {
    pub restored_pane_id: PaneId,
    pub restored_worklane_id: String,
    pub toast_message: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorklaneStore {
    worklanes: Vec<WorklaneState>,
    active_worklane_id: Option<String>,
    closed_pane_stack: ClosedPaneStack,
    home_directory: String,
    current_time: f64,
    next_restored_pane_number: u32,
}

impl WorklaneStore {
    pub fn new(
        worklanes: Vec<WorklaneState>,
        active_worklane_id: Option<String>,
        home_directory: String,
    ) -> Self {
        let active_worklane_id = active_worklane_id
            .filter(|id| worklanes.iter().any(|worklane| &worklane.id == id))
            .or_else(|| worklanes.first().map(|worklane| worklane.id.clone()));
        Self {
            worklanes,
            active_worklane_id,
            closed_pane_stack: ClosedPaneStack::default(),
            home_directory,
            current_time: 0.0,
            next_restored_pane_number: 1,
        }
    }

    pub fn active_worklane(&self) -> Option<&WorklaneState> {
        let active = self.active_worklane_id.as_ref()?;
        self.worklanes
            .iter()
            .find(|worklane| &worklane.id == active)
    }

    pub fn closed_pane_stack(&self) -> &ClosedPaneStack {
        &self.closed_pane_stack
    }

    pub fn set_current_time(&mut self, current_time: f64) {
        self.current_time = current_time;
    }

    pub fn replace_worklanes(
        &mut self,
        worklanes: Vec<WorklaneState>,
        active_worklane_id: Option<String>,
    ) {
        self.worklanes = worklanes;
        self.active_worklane_id = active_worklane_id
            .filter(|id| self.worklanes.iter().any(|worklane| &worklane.id == id))
            .or_else(|| self.worklanes.first().map(|worklane| worklane.id.clone()));
    }

    pub fn close_pane(&mut self, pane_id: &PaneId) -> PaneCloseResult {
        self.close_pane_with_source(pane_id, PaneCloseSource::UserCommand)
    }

    pub fn close_pane_from_shell_exit(&mut self, pane_id: &PaneId) -> PaneCloseResult {
        self.close_pane_with_source(pane_id, PaneCloseSource::ShellExit)
    }

    pub fn restore_closed_pane(&mut self) -> Option<RestoreClosedPaneResult> {
        let entry = self.closed_pane_stack.peek(self.current_time)?.clone();
        let target = self.resolve_restore_target(&entry)?;
        let _ = self.closed_pane_stack.pop_latest(self.current_time);

        let cwd_resolution = ClosedPaneCwdResolver::resolve(
            entry.working_directory.as_deref(),
            &self.home_directory,
        );
        let prefill_text = restore_prefill_text(&entry);
        let pane_id = self.make_restored_pane_id();
        let mut restored_pane = PaneState::new(pane_id.clone(), entry.title.clone());
        restored_pane.width = entry.original_column_width;
        restored_pane.session_request = TerminalSessionRequest {
            working_directory: Some(cwd_resolution.path.clone()),
            prefill_text,
            ..TerminalSessionRequest::default()
        };

        let worklane_index = self
            .worklanes
            .iter()
            .position(|worklane| worklane.id == target.worklane_id)?;
        self.active_worklane_id = Some(target.worklane_id.clone());
        insert_restored_pane(
            &mut self.worklanes[worklane_index],
            restored_pane,
            &target,
            entry.original_height_in_column,
        );

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

        Some(RestoreClosedPaneResult {
            restored_pane_id: pane_id,
            restored_worklane_id: target.worklane_id,
            toast_message,
        })
    }

    fn close_pane_with_source(
        &mut self,
        pane_id: &PaneId,
        source: PaneCloseSource,
    ) -> PaneCloseResult {
        let Some(worklane_index) = self.worklane_index_containing_pane(pane_id, source) else {
            return PaneCloseResult::NotFound;
        };

        let is_last_pane_in_worklane = self.worklanes[worklane_index].pane_count() == 1;
        if is_last_pane_in_worklane && self.worklanes.len() == 1 {
            return PaneCloseResult::CloseWindow;
        }

        if source == PaneCloseSource::UserCommand {
            self.capture_closed_pane(worklane_index, pane_id);
        }

        if is_last_pane_in_worklane {
            let removed_id = self.worklanes[worklane_index].id.clone();
            self.worklanes.remove(worklane_index);
            if self.active_worklane_id.as_ref() == Some(&removed_id) {
                self.active_worklane_id = self
                    .worklanes
                    .get(
                        worklane_index
                            .saturating_sub(1)
                            .min(self.worklanes.len().saturating_sub(1)),
                    )
                    .map(|worklane| worklane.id.clone());
            }
            return PaneCloseResult::Closed;
        }

        if source != PaneCloseSource::ShellExit {
            let _ = self.worklanes[worklane_index]
                .pane_strip_state
                .focus_pane(pane_id);
        }
        self.worklanes[worklane_index]
            .pane_strip_state
            .remove_pane(pane_id);
        PaneCloseResult::Closed
    }

    fn capture_closed_pane(&mut self, worklane_index: usize, pane_id: &PaneId) {
        let worklane = &self.worklanes[worklane_index];
        let Some((column_index, column)) = worklane
            .pane_strip_state
            .columns()
            .iter()
            .enumerate()
            .find(|(_, column)| column.panes().iter().any(|pane| pane.id() == pane_id))
        else {
            return;
        };
        let Some(pane_index) = column.panes().iter().position(|pane| pane.id() == pane_id) else {
            return;
        };
        let pane = &column.panes()[pane_index];
        let original_height_in_column = if column.panes().len() > 1 {
            column.pane_heights().get(pane_index).copied()
        } else {
            None
        };
        let entry = ClosedPaneEntry {
            id: format!("closed-{}", self.current_time),
            closed_at: self.current_time,
            original_pane_id: pane_id.clone(),
            original_worklane_id: worklane.id.clone(),
            original_column_id: column.id().clone(),
            original_column_index: column_index,
            original_pane_index: pane_index,
            original_column_width: column.width,
            original_height_in_column,
            title: pane.title().to_string(),
            working_directory: pane.session_request.working_directory.clone(),
            original_native_command: pane.session_request.native_command.clone(),
            original_command: pane.session_request.command.clone(),
            agent_snapshot: None,
            scrollback_text: None,
        };
        self.closed_pane_stack.push(entry, self.current_time);
    }

    fn worklane_index_containing_pane(
        &self,
        pane_id: &PaneId,
        source: PaneCloseSource,
    ) -> Option<usize> {
        if source == PaneCloseSource::ShellExit {
            return self.worklanes.iter().position(|worklane| {
                worklane
                    .pane_strip_state
                    .columns()
                    .iter()
                    .any(|column| column.panes().iter().any(|pane| pane.id() == pane_id))
            });
        }
        let active_id = self.active_worklane_id.as_ref()?;
        self.worklanes.iter().position(|worklane| {
            &worklane.id == active_id
                && worklane
                    .pane_strip_state
                    .columns()
                    .iter()
                    .any(|column| column.panes().iter().any(|pane| pane.id() == pane_id))
        })
    }

    fn resolve_restore_target(&self, entry: &ClosedPaneEntry) -> Option<RestoreTarget> {
        if let Some(worklane) = self
            .worklanes
            .iter()
            .find(|worklane| worklane.id == entry.original_worklane_id)
        {
            if let Some((column_index, column)) = worklane
                .pane_strip_state
                .columns()
                .iter()
                .enumerate()
                .find(|(_, column)| column.id() == &entry.original_column_id)
            {
                return Some(RestoreTarget {
                    worklane_id: worklane.id.clone(),
                    column_id: Some(column.id().clone()),
                    column_index,
                    pane_index: entry.original_pane_index.min(column.panes().len()),
                });
            }
            return Some(RestoreTarget {
                worklane_id: worklane.id.clone(),
                column_id: None,
                column_index: entry
                    .original_column_index
                    .min(worklane.pane_strip_state.columns().len()),
                pane_index: 0,
            });
        }

        let active_id = self.active_worklane_id.as_ref()?;
        let active = self
            .worklanes
            .iter()
            .find(|worklane| &worklane.id == active_id)?;
        Some(RestoreTarget {
            worklane_id: active.id.clone(),
            column_id: active.pane_strip_state.focused_column_id().cloned(),
            column_index: active.pane_strip_state.columns().len(),
            pane_index: 0,
        })
    }

    fn make_restored_pane_id(&mut self) -> PaneId {
        let id = PaneId::from(format!("restored-{}", self.next_restored_pane_number));
        self.next_restored_pane_number += 1;
        id
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RestoreTarget {
    worklane_id: String,
    column_id: Option<crate::layout::PaneColumnId>,
    column_index: usize,
    pane_index: usize,
}

fn insert_restored_pane(
    worklane: &mut WorklaneState,
    pane: PaneState,
    target: &RestoreTarget,
    original_height_in_column: Option<f64>,
) {
    let pane_id = pane.id().clone();
    if let Some(column_id) = &target.column_id
        && let Some(column_index) = worklane
            .pane_strip_state
            .columns()
            .iter()
            .position(|column| column.id() == column_id)
        && worklane.pane_strip_state.insert_existing_pane_into_column(
            pane.clone(),
            column_id,
            target.pane_index,
        )
    {
        if let Some(height) = original_height_in_column {
            let _ = worklane
                .pane_strip_state
                .set_pane_height(column_index, &pane_id, height);
        }
        return;
    }

    worklane
        .pane_strip_state
        .insert_pane_as_column(pane.clone(), target.column_index, pane.width);
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

fn tool_display_name(tool: &crate::agent::AgentTool) -> &'static str {
    match tool {
        crate::agent::AgentTool::ClaudeCode => "Claude Code",
        crate::agent::AgentTool::OpenCode => "OpenCode",
        crate::agent::AgentTool::Agy => "Antigravity",
        crate::agent::AgentTool::Copilot => "GitHub Copilot",
        crate::agent::AgentTool::Custom(_) => "Agent",
        crate::agent::AgentTool::Zentty => "Zentty",
        crate::agent::AgentTool::Amp => "Amp",
        crate::agent::AgentTool::Codex => "Codex",
        crate::agent::AgentTool::Cursor => "Cursor",
        crate::agent::AgentTool::Droid => "Droid",
        crate::agent::AgentTool::Gemini => "Gemini",
        crate::agent::AgentTool::Kimi => "Kimi",
        crate::agent::AgentTool::Pi => "Pi",
        crate::agent::AgentTool::Grok => "Grok",
        crate::agent::AgentTool::Hermes => "Hermes",
    }
}
