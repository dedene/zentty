use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::agent::AgentTool;
use crate::layout::{PaneColumnId, PaneId};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PaneCloseSource {
    UserCommand,
    ShellExit,
    Cascade,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ClosedPaneAgentSnapshot {
    pub tool: AgentTool,
    pub tool_display_name: String,
    pub session_id: Option<String>,
    pub working_directory: Option<String>,
    pub agent_launch_snapshot: Option<AgentLaunchSnapshot>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentLaunchSnapshot {
    pub arguments: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub environment: BTreeMap<String, String>,
}

impl AgentLaunchSnapshot {
    pub fn new<I, S>(arguments: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            arguments: arguments.into_iter().map(Into::into).collect(),
            environment: BTreeMap::new(),
        }
    }

    pub fn with_environment(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.environment.insert(key.into(), value.into());
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneRestoreDraftKind {
    AgentResume,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaneRestoreDraft {
    pub pane_id: String,
    pub kind: PaneRestoreDraftKind,
    pub tool: AgentTool,
    pub tool_name: String,
    pub session_id: String,
    pub working_directory: Option<String>,
    pub tracked_pid: i32,
    pub agent_launch_snapshot: Option<AgentLaunchSnapshot>,
}

#[derive(Serialize, Deserialize)]
struct PaneRestoreDraftWire {
    #[serde(rename = "paneID")]
    pane_id: String,
    kind: PaneRestoreDraftKind,
    #[serde(rename = "toolName")]
    tool_name: String,
    #[serde(rename = "sessionID")]
    session_id: String,
    #[serde(rename = "workingDirectory", skip_serializing_if = "Option::is_none")]
    working_directory: Option<String>,
    #[serde(rename = "trackedPID")]
    tracked_pid: i32,
    #[serde(
        rename = "agentLaunchSnapshot",
        skip_serializing_if = "Option::is_none"
    )]
    agent_launch_snapshot: Option<AgentLaunchSnapshot>,
}

impl From<&PaneRestoreDraft> for PaneRestoreDraftWire {
    fn from(draft: &PaneRestoreDraft) -> Self {
        Self {
            pane_id: draft.pane_id.clone(),
            kind: draft.kind.clone(),
            tool_name: draft.tool_name.clone(),
            session_id: draft.session_id.clone(),
            working_directory: draft.working_directory.clone(),
            tracked_pid: draft.tracked_pid,
            agent_launch_snapshot: draft.agent_launch_snapshot.clone(),
        }
    }
}

impl From<PaneRestoreDraftWire> for PaneRestoreDraft {
    fn from(wire: PaneRestoreDraftWire) -> Self {
        let tool = AgentTool::resolve(Some(&wire.tool_name))
            .unwrap_or_else(|| AgentTool::Custom(wire.tool_name.clone()));
        Self {
            pane_id: wire.pane_id,
            kind: wire.kind,
            tool,
            tool_name: wire.tool_name,
            session_id: wire.session_id,
            working_directory: wire.working_directory,
            tracked_pid: wire.tracked_pid,
            agent_launch_snapshot: wire.agent_launch_snapshot,
        }
    }
}

impl Serialize for PaneRestoreDraft {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        PaneRestoreDraftWire::from(self).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for PaneRestoreDraft {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        PaneRestoreDraftWire::deserialize(deserializer).map(Self::from)
    }
}

impl PaneRestoreDraft {
    pub fn agent_resume(
        pane_id: impl Into<String>,
        tool: AgentTool,
        tool_name: impl Into<String>,
        session_id: impl Into<String>,
        working_directory: Option<&str>,
        tracked_pid: i32,
        agent_launch_snapshot: Option<AgentLaunchSnapshot>,
    ) -> Self {
        Self {
            pane_id: pane_id.into(),
            kind: PaneRestoreDraftKind::AgentResume,
            tool,
            tool_name: tool_name.into(),
            session_id: session_id.into(),
            working_directory: working_directory.map(str::to_string),
            tracked_pid,
            agent_launch_snapshot,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClosedPaneEntry {
    pub id: String,
    pub closed_at: f64,
    pub original_pane_id: PaneId,
    pub original_worklane_id: String,
    pub original_column_id: PaneColumnId,
    pub original_column_index: usize,
    pub original_pane_index: usize,
    pub original_column_width: f64,
    pub original_height_in_column: Option<f64>,
    pub title: String,
    pub working_directory: Option<String>,
    pub original_native_command: Option<String>,
    pub original_command: Option<String>,
    pub agent_snapshot: Option<ClosedPaneAgentSnapshot>,
    pub scrollback_text: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClosedPaneStack {
    entries: Vec<ClosedPaneEntry>,
    capacity: usize,
    expiry_seconds: f64,
}

impl ClosedPaneStack {
    pub const DEFAULT_CAPACITY: usize = 10;
    pub const DEFAULT_EXPIRY_SECONDS: f64 = 60.0 * 60.0;

    pub fn new(capacity: usize, expiry_seconds: f64) -> Self {
        Self {
            entries: Vec::new(),
            capacity: capacity.max(1),
            expiry_seconds: expiry_seconds.max(0.0),
        }
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn push(&mut self, entry: ClosedPaneEntry, now: f64) {
        self.prune(now);
        self.entries.push(entry);
        while self.entries.len() > self.capacity {
            self.entries.remove(0);
        }
    }

    pub fn pop_latest(&mut self, now: f64) -> Option<ClosedPaneEntry> {
        self.prune(now);
        self.entries.pop()
    }

    pub fn prune(&mut self, now: f64) {
        let cutoff = now - self.expiry_seconds;
        self.entries.retain(|entry| entry.closed_at >= cutoff);
    }

    pub fn peek(&self, now: f64) -> Option<&ClosedPaneEntry> {
        let cutoff = now - self.expiry_seconds;
        self.entries
            .iter()
            .rev()
            .find(|entry| entry.closed_at >= cutoff)
    }
}

impl Default for ClosedPaneStack {
    fn default() -> Self {
        Self::new(Self::DEFAULT_CAPACITY, Self::DEFAULT_EXPIRY_SECONDS)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClosedPaneRestoreCommand {
    AgentResume {
        command: String,
        tool: AgentTool,
        session_id: Option<String>,
    },
    ReplayCommand(String),
    PlainShell,
}

pub struct ClosedPaneRestoreCommandResolver;

impl ClosedPaneRestoreCommandResolver {
    pub fn resolve(entry: &ClosedPaneEntry) -> ClosedPaneRestoreCommand {
        if let Some(snapshot) = &entry.agent_snapshot
            && let Some(command) = AgentResumeCommandBuilder::command(PaneRestoreDraft {
                pane_id: entry.original_pane_id.as_str().to_string(),
                kind: PaneRestoreDraftKind::AgentResume,
                tool: snapshot.tool.clone(),
                tool_name: snapshot.tool_display_name.clone(),
                session_id: snapshot.session_id.clone().unwrap_or_default(),
                working_directory: snapshot
                    .working_directory
                    .clone()
                    .or_else(|| entry.working_directory.clone()),
                tracked_pid: 0,
                agent_launch_snapshot: snapshot.agent_launch_snapshot.clone(),
            })
        {
            return ClosedPaneRestoreCommand::AgentResume {
                command,
                tool: snapshot.tool.clone(),
                session_id: snapshot.session_id.clone(),
            };
        }

        if let Some(command) = trimmed_non_empty(entry.original_native_command.as_deref()) {
            return ClosedPaneRestoreCommand::ReplayCommand(command.to_string());
        }
        if let Some(command) = trimmed_non_empty(entry.original_command.as_deref()) {
            return ClosedPaneRestoreCommand::ReplayCommand(command.to_string());
        }

        ClosedPaneRestoreCommand::PlainShell
    }
}

pub struct AgentResumeCommandBuilder;

impl AgentResumeCommandBuilder {
    pub fn command(draft: PaneRestoreDraft) -> Option<String> {
        match draft.tool {
            AgentTool::Amp => {
                let session_id = validated_amp_thread_id(&draft.session_id)?;
                let resume_arguments = sanitized_amp_resume_arguments(
                    draft
                        .agent_launch_snapshot
                        .as_ref()
                        .map(|snapshot| snapshot.arguments.as_slice())
                        .unwrap_or(&[]),
                )?;
                let command_arguments = ["amp", "threads", "continue"]
                    .into_iter()
                    .map(str::to_string)
                    .chain(resume_arguments)
                    .chain([session_id])
                    .collect::<Vec<_>>();
                Some(shell_command(&command_arguments))
            }
            AgentTool::ClaudeCode => {
                let session_id = validated_uuid(&draft.session_id)?;
                Some(format!("claude --resume {session_id}"))
            }
            AgentTool::Codex => {
                let session_id = validated_codex_session_id(&draft.session_id)?;
                Some(format!("codex resume {session_id}"))
            }
            AgentTool::OpenCode => {
                let session_id = validated_opencode_session_id(&draft.session_id)?;
                Some(format!("opencode --session {session_id}"))
            }
            AgentTool::Copilot => {
                let session_id = validated_uuid(&draft.session_id)?;
                Some(format!("copilot --resume={session_id}"))
            }
            AgentTool::Cursor => {
                let session_id = validated_uuid(&draft.session_id)?;
                Some(format!("cursor-agent --resume={session_id}"))
            }
            AgentTool::Gemini => {
                has_working_directory(&draft).then(|| "gemini --resume".to_string())
            }
            AgentTool::Kimi => {
                let session_id = validated_uuid(&draft.session_id)?;
                Some(format!("kimi -r {session_id}"))
            }
            AgentTool::Droid => {
                let session_id = validated_pattern(&draft.session_id, is_droid_session_char)?;
                Some(format!("droid exec -s {session_id}"))
            }
            AgentTool::Pi => has_working_directory(&draft).then(|| "pi -c".to_string()),
            AgentTool::Grok => {
                if let Some(session_id) = validated_grok_session_id(&draft.session_id) {
                    return Some(format!("grok --resume {session_id}"));
                }
                has_working_directory(&draft).then(|| "grok --resume".to_string())
            }
            AgentTool::Agy => {
                if draft.session_id.is_empty()
                    || draft.session_id.starts_with("zentty-placeholder-")
                {
                    return Some("agy --continue".to_string());
                }
                let session_id = validated_agy_session_id(&draft.session_id)?;
                Some(format!("agy --conversation {session_id}"))
            }
            AgentTool::Hermes => {
                let session_id = validated_hermes_session_id(&draft.session_id)?;
                let resume_arguments = sanitized_hermes_resume_arguments(
                    draft
                        .agent_launch_snapshot
                        .as_ref()
                        .map(|snapshot| snapshot.arguments.as_slice())
                        .unwrap_or(&[]),
                )?;
                let command_arguments = ["hermes".to_string()]
                    .into_iter()
                    .chain(resume_arguments)
                    .chain(["--resume".to_string(), session_id])
                    .collect::<Vec<_>>();
                let command = shell_command(&command_arguments);
                let hermes_home = draft
                    .agent_launch_snapshot
                    .as_ref()
                    .and_then(|snapshot| snapshot.environment.get("HERMES_HOME"))
                    .and_then(|value| trimmed_non_empty(Some(value)));
                if let Some(hermes_home) = hermes_home {
                    return Some(format!(
                        "env HERMES_HOME={} {command}",
                        shell_quoted_argument(hermes_home)
                    ));
                }
                Some(command)
            }
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClosedPaneCwdResolution {
    pub path: String,
    pub original_missing: bool,
}

pub struct ClosedPaneCwdResolver;

impl ClosedPaneCwdResolver {
    pub fn resolve(original: Option<&str>, home_directory: &str) -> ClosedPaneCwdResolution {
        let Some(original) = trimmed_non_empty(original) else {
            return ClosedPaneCwdResolution {
                path: home_directory.to_string(),
                original_missing: true,
            };
        };

        let mut candidate = PathBuf::from(original);
        loop {
            if candidate.exists() {
                return ClosedPaneCwdResolution {
                    path: candidate.to_string_lossy().into_owned(),
                    original_missing: candidate.to_string_lossy() != original,
                };
            }

            if !candidate.pop() {
                return ClosedPaneCwdResolution {
                    path: home_directory.to_string(),
                    original_missing: true,
                };
            }
        }
    }
}

fn trimmed_non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn validated_uuid(value: &str) -> Option<String> {
    is_uuid(value).then(|| value.to_ascii_lowercase())
}

fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    for (index, byte) in bytes.iter().enumerate() {
        let expected_hyphen = matches!(index, 8 | 13 | 18 | 23);
        if expected_hyphen {
            if *byte != b'-' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

fn validated_codex_session_id(session_id: &str) -> Option<String> {
    if let Some(uuid) = validated_uuid(session_id) {
        return Some(uuid);
    }
    let mut chars = session_id.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphanumeric() {
        return None;
    }
    chars
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
        .then(|| session_id.to_string())
}

fn validated_opencode_session_id(session_id: &str) -> Option<String> {
    session_id
        .strip_prefix("ses_")
        .filter(|tail| !tail.is_empty() && tail.chars().all(|ch| ch.is_ascii_alphanumeric()))
        .map(|_| session_id.to_string())
}

fn validated_grok_session_id(session_id: &str) -> Option<String> {
    if let Some(uuid) = validated_uuid(session_id) {
        return Some(uuid);
    }
    let mut chars = session_id.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphanumeric() {
        return None;
    }
    let remaining: String = chars.collect();
    (remaining.len() >= 3
        && remaining
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'))
    .then(|| session_id.to_string())
}

fn validated_amp_thread_id(session_id: &str) -> Option<String> {
    session_id
        .strip_prefix("T-")
        .filter(|tail| {
            !tail.is_empty()
                && tail
                    .chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
        })
        .map(|_| session_id.to_string())
}

fn validated_agy_session_id(session_id: &str) -> Option<String> {
    if session_id.starts_with("zentty-placeholder-") {
        return None;
    }
    validated_pattern(session_id, |ch| {
        ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
    })
}

fn validated_hermes_session_id(session_id: &str) -> Option<String> {
    if session_id.starts_with("zentty-hermes-placeholder-") {
        return None;
    }
    validated_pattern(session_id, is_droid_session_char)
}

fn validated_pattern<F>(session_id: &str, allowed: F) -> Option<String>
where
    F: Fn(char) -> bool,
{
    (!session_id.is_empty() && session_id.chars().all(allowed)).then(|| session_id.to_string())
}

fn is_droid_session_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | ':' | '-')
}

fn has_working_directory(draft: &PaneRestoreDraft) -> bool {
    trimmed_non_empty(draft.working_directory.as_deref()).is_some()
}

fn sanitized_amp_resume_arguments(arguments: &[String]) -> Option<Vec<String>> {
    let mut remaining = if arguments.first().is_some_and(|argument| argument == "amp") {
        arguments[1..].to_vec()
    } else {
        arguments.to_vec()
    };

    if remaining
        .first()
        .is_some_and(|argument| AMP_REJECTED_SUBCOMMANDS.contains(&argument.as_str()))
        || remaining
            .iter()
            .any(|argument| is_amp_rejected_flag(argument))
    {
        return None;
    }
    strip_amp_resume_preamble(&mut remaining);

    let mut sanitized = Vec::new();
    let mut index = 0;
    while index < remaining.len() {
        let argument = &remaining[index];
        if argument.starts_with("--") {
            let option_name = option_name(argument);
            if AMP_SAFE_VALUE_OPTIONS.contains(&option_name) {
                if argument.contains('=') {
                    sanitized.push(argument.clone());
                } else if remaining
                    .get(index + 1)
                    .is_some_and(|next| !next.starts_with('-'))
                {
                    sanitized.push(argument.clone());
                    sanitized.push(remaining[index + 1].clone());
                    index += 1;
                }
            } else if AMP_DROPPED_VALUE_OPTIONS.contains(&option_name) {
                if !argument.contains('=')
                    && remaining
                        .get(index + 1)
                        .is_some_and(|next| !next.starts_with('-'))
                {
                    index += 1;
                }
            } else if AMP_DROPPED_FLAGS.contains(&option_name)
                && option_name == "--output-format"
                && !argument.contains('=')
                && remaining
                    .get(index + 1)
                    .is_some_and(|next| !next.starts_with('-'))
            {
                index += 1;
            }
        } else if argument == "-m" {
            if remaining
                .get(index + 1)
                .is_some_and(|next| !next.starts_with('-'))
            {
                sanitized.push(argument.clone());
                sanitized.push(remaining[index + 1].clone());
                index += 1;
            }
        } else if argument == "-l" {
            if remaining
                .get(index + 1)
                .is_some_and(|next| !next.starts_with('-'))
            {
                index += 1;
            }
        } else if argument.starts_with('-') {
            if is_amp_rejected_flag(argument) {
                return None;
            }
        } else {
            break;
        }
        index += 1;
    }
    Some(sanitized)
}

fn strip_amp_resume_preamble(arguments: &mut Vec<String>) {
    if arguments.len() < 2 {
        return;
    }
    if !AMP_THREAD_SUBCOMMANDS.contains(&arguments[0].as_str())
        || !AMP_CONTINUE_SUBCOMMANDS.contains(&arguments[1].as_str())
    {
        return;
    }
    arguments.drain(0..2);
    if arguments
        .first()
        .and_then(|argument| validated_amp_thread_id(argument))
        .is_some()
    {
        arguments.remove(0);
    }
}

fn is_amp_rejected_flag(argument: &str) -> bool {
    AMP_REJECTED_FLAGS.contains(&option_name(argument))
}

fn sanitized_hermes_resume_arguments(arguments: &[String]) -> Option<Vec<String>> {
    if arguments.iter().any(|argument| {
        let option = if argument.starts_with("--") {
            option_name(argument)
        } else {
            argument.as_str()
        };
        HERMES_ONE_SHOT_FLAGS.contains(&option)
    }) {
        return None;
    }

    let mut result = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if index == 0 && argument == "chat" {
            index += 1;
            continue;
        }
        if argument == "--resume" || argument == "-r" {
            index += 2;
            continue;
        }
        if argument.starts_with("--resume=") {
            index += 1;
            continue;
        }
        result.push(argument.clone());
        index += 1;
    }
    Some(result)
}

fn option_name(argument: &str) -> &str {
    argument
        .split_once('=')
        .map(|(name, _)| name)
        .unwrap_or(argument)
}

fn shell_command(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|argument| shell_quoted_argument(argument))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quoted_argument(argument: &str) -> String {
    if argument.chars().all(|ch| {
        ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '/' | ':' | '=' | '+' | '-')
    }) {
        return argument.to_string();
    }
    format!("'{}'", argument.replace('\'', "'\\''"))
}

const AMP_SAFE_VALUE_OPTIONS: &[&str] = &[
    "--mode",
    "-m",
    "--effort",
    "--settings-file",
    "--log-level",
    "--log-file",
    "--mcp-config",
    "--visibility",
];
const AMP_DROPPED_VALUE_OPTIONS: &[&str] = &["--label", "-l"];
const AMP_DROPPED_FLAGS: &[&str] = &[
    "--archive",
    "--stream-json",
    "--stream-json-input",
    "--stream-json-thinking",
    "--json",
    "--output-format",
];
const AMP_REJECTED_FLAGS: &[&str] = &[
    "--execute",
    "--print",
    "-x",
    "--help",
    "-h",
    "--version",
    "-V",
    "--jetbrains",
];
const AMP_REJECTED_SUBCOMMANDS: &[&str] = &[
    "login",
    "logout",
    "mcp",
    "permission",
    "permissions",
    "review",
    "skill",
    "skills",
    "tool",
    "tools",
    "update",
    "up",
    "usage",
    "version",
];
const AMP_THREAD_SUBCOMMANDS: &[&str] = &["threads", "thread", "t"];
const AMP_CONTINUE_SUBCOMMANDS: &[&str] = &["continue", "c"];
const HERMES_ONE_SHOT_FLAGS: &[&str] = &["--oneshot", "-z", "--query", "-q", "--quiet", "-Q"];
