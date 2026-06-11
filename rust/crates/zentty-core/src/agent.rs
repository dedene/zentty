use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::task_runner::TaskRunnerShellActivityState;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AgentTool {
    Zentty,
    Amp,
    ClaudeCode,
    Codex,
    Copilot,
    Cursor,
    Droid,
    Gemini,
    Kimi,
    OpenCode,
    Pi,
    Grok,
    Agy,
    Hermes,
    Custom(String),
}

impl AgentTool {
    pub fn resolve(raw_name: Option<&str>) -> Option<Self> {
        let normalized = Self::normalized(raw_name)?;
        if let Some(tool) = Self::resolve_known_tool(&normalized, true) {
            return Some(tool);
        }
        trimmed(raw_name).map(|name| Self::Custom(name.to_string()))
    }

    pub fn resolve_known(raw_name: Option<&str>) -> Option<Self> {
        let normalized = Self::normalized(raw_name)?;
        Self::resolve_known_tool(&normalized, false)
    }

    fn resolve_known_tool(normalized: &str, include_hook_driven_only: bool) -> Option<Self> {
        let matchers = [
            ToolNameMatcher::leading(Self::Amp, false, &["amp"]),
            ToolNameMatcher::contains(Self::ClaudeCode, false, "claude"),
            ToolNameMatcher::contains(Self::Codex, false, "codex"),
            ToolNameMatcher::contains(Self::Copilot, true, "copilot"),
            ToolNameMatcher::contains(Self::Cursor, true, "cursor"),
            ToolNameMatcher::contains(Self::Droid, false, "droid"),
            ToolNameMatcher::contains(Self::Gemini, false, "gemini"),
            ToolNameMatcher::contains(Self::Kimi, false, "kimi"),
            ToolNameMatcher::contains_any(Self::OpenCode, false, &["opencode", "open code"]),
            ToolNameMatcher::pi(Self::Pi, false),
            ToolNameMatcher::leading(Self::Grok, false, &["grok", "grok-build"]),
            ToolNameMatcher::leading(Self::Agy, false, &["agy", "antigravity"]),
            ToolNameMatcher::leading(Self::Hermes, false, &["hermes"]),
        ];

        matchers
            .into_iter()
            .filter(|matcher| include_hook_driven_only || !matcher.is_hook_driven_only)
            .find(|matcher| matcher.matches(normalized))
            .map(|matcher| matcher.tool)
    }

    fn normalized(value: Option<&str>) -> Option<String> {
        trimmed(value).map(|value| value.to_lowercase())
    }
}

struct ToolNameMatcher {
    tool: AgentTool,
    is_hook_driven_only: bool,
    match_kind: MatchKind,
}

impl ToolNameMatcher {
    fn contains(tool: AgentTool, is_hook_driven_only: bool, needle: &'static str) -> Self {
        Self {
            tool,
            is_hook_driven_only,
            match_kind: MatchKind::Contains(vec![needle]),
        }
    }

    fn contains_any(
        tool: AgentTool,
        is_hook_driven_only: bool,
        needles: &'static [&'static str],
    ) -> Self {
        Self {
            tool,
            is_hook_driven_only,
            match_kind: MatchKind::Contains(needles.to_vec()),
        }
    }

    fn leading(
        tool: AgentTool,
        is_hook_driven_only: bool,
        tokens: &'static [&'static str],
    ) -> Self {
        Self {
            tool,
            is_hook_driven_only,
            match_kind: MatchKind::Leading(tokens),
        }
    }

    fn pi(tool: AgentTool, is_hook_driven_only: bool) -> Self {
        Self {
            tool,
            is_hook_driven_only,
            match_kind: MatchKind::Pi,
        }
    }

    fn matches(&self, normalized: &str) -> bool {
        match &self.match_kind {
            MatchKind::Contains(needles) => {
                needles.iter().any(|needle| normalized.contains(needle))
            }
            MatchKind::Leading(tokens) => matches_leading_token(normalized, tokens),
            MatchKind::Pi => matches_pi(normalized),
        }
    }
}

enum MatchKind {
    Contains(Vec<&'static str>),
    Leading(&'static [&'static str]),
    Pi,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentInteractionKind {
    None,
    Approval,
    Question,
    Decision,
    Auth,
    GenericInput,
}

pub struct AgentInteractionClassifier;

impl AgentInteractionClassifier {
    pub fn requires_human_input(message: Option<&str>) -> bool {
        let Some(message) = normalized(message) else {
            return false;
        };
        let markers = [
            "waiting for your input",
            "waiting for input",
            "needs your input",
            "needs input",
            "needs your attention",
            "action required",
            "input-requested",
            "input requested",
            "approval-requested",
            "approval requested",
            "question requested",
            "questions requested",
            "plan-mode-prompt",
            "plan mode prompt",
            "permission",
            "approve",
            "approval",
            "allow ",
            "wants to edit",
            "confirm",
            "select ",
            "choose ",
            "grant access",
            "press enter",
            "log in",
            "login",
        ];
        markers.iter().any(|marker| message.contains(marker))
            || looks_like_question_prompt(&message)
    }

    pub fn interaction_kind(message: Option<&str>) -> Option<AgentInteractionKind> {
        let message = normalized(message)?;

        if message.contains("plan-mode-prompt") || message.contains("plan mode prompt") {
            return Some(AgentInteractionKind::Approval);
        }
        if message.contains("question requested") || message.contains("questions requested") {
            return Some(AgentInteractionKind::Decision);
        }
        if message.contains("log in") || message.contains("login") {
            return Some(AgentInteractionKind::Auth);
        }

        let approval_markers = [
            "action required",
            "approval-requested",
            "approval requested",
            "permission",
            "approve",
            "approval",
            "allow ",
            "grant access",
            "wants to edit",
        ];
        if approval_markers
            .iter()
            .any(|marker| message.contains(marker))
        {
            return Some(AgentInteractionKind::Approval);
        }
        if looks_like_question_prompt(&message) {
            return Some(if contains_decision_options(&message) {
                AgentInteractionKind::Decision
            } else {
                AgentInteractionKind::Question
            });
        }
        if Self::requires_human_input(Some(&message)) {
            return Some(AgentInteractionKind::GenericInput);
        }
        None
    }

    pub fn preferred_waiting_message(
        existing: Option<&str>,
        candidate: Option<&str>,
    ) -> Option<String> {
        let existing = trimmed(existing);
        let candidate = trimmed(candidate);
        match (existing, candidate) {
            (None, None) => None,
            (Some(existing), None) => Some(existing.to_string()),
            (None, Some(candidate)) => Some(candidate.to_string()),
            (Some(existing), Some(candidate)) => {
                if specificity(Some(candidate)) > specificity(Some(existing)) {
                    Some(candidate.to_string())
                } else {
                    Some(existing.to_string())
                }
            }
        }
    }
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn normalized(value: Option<&str>) -> Option<String> {
    trimmed(value).map(|value| value.to_lowercase())
}

fn looks_like_question_prompt(message: &str) -> bool {
    message.contains('?')
}

fn contains_decision_options(message: &str) -> bool {
    if message.contains('[') && message.contains(']') {
        return true;
    }
    message.lines().any(|line| {
        let trimmed = line.trim();
        let Some((prefix, remainder)) = trimmed.split_once('.') else {
            return false;
        };
        !prefix.is_empty()
            && prefix.chars().all(|ch| ch.is_ascii_digit())
            && !remainder.trim().is_empty()
    })
}

fn specificity(message: Option<&str>) -> u8 {
    let Some(message) = normalized(message) else {
        return 0;
    };
    if matches!(message.as_str(), "action required")
        || has_any_prefix(
            &message,
            &[
                "claude needs your approval",
                "claude needs your permission",
                "gemini needs your approval",
                "gemini needs your permission",
                "approval needed",
                "permission required",
            ],
        )
    {
        return 1;
    }
    if AgentInteractionClassifier::interaction_kind(Some(&message)).is_some() {
        return 2;
    }
    0
}

fn has_any_prefix(value: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|prefix| value.starts_with(prefix))
}

fn matches_pi(normalized: &str) -> bool {
    normalized
        .split_whitespace()
        .any(|token| token == "pi" || token == "π")
}

fn matches_leading_token(normalized: &str, expected_tokens: &[&str]) -> bool {
    let token: String = normalized
        .chars()
        .take_while(|ch| ch.is_alphanumeric())
        .collect();
    !token.is_empty() && expected_tokens.iter().any(|expected| *expected == token)
}

pub const AGENT_IPC_PROTOCOL_VERSION: u32 = 1;
pub const AGENT_IPC_SELF_PID_PLACEHOLDER: &str = "__ZENTTY_SELF_PID__";
pub const AGENT_IPC_AWAIT_CONSENT_TIMEOUT_SECONDS: u32 = 300;
pub const AGENT_IPC_CONSENT_PANEL_TIMEOUT_MARGIN: u32 = 30;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentSignalKind {
    Lifecycle,
    ShellState,
    Pid,
    PaneRootPid,
    PaneContext,
}

impl AgentSignalKind {
    fn parse(raw_value: &str) -> Option<Self> {
        match raw_value {
            "lifecycle" => Some(Self::Lifecycle),
            "shell-state" => Some(Self::ShellState),
            "pid" => Some(Self::Pid),
            "pane-root-pid" => Some(Self::PaneRootPid),
            "pane-context" => Some(Self::PaneContext),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentSignalOrigin {
    Compatibility,
    ExplicitHook,
    ExplicitApi,
    Heuristic,
    Shell,
    Inferred,
}

impl AgentSignalOrigin {
    fn parse(raw_value: &str) -> Option<Self> {
        match raw_value {
            "compatibility" => Some(Self::Compatibility),
            "explicit-hook" => Some(Self::ExplicitHook),
            "explicit-api" => Some(Self::ExplicitApi),
            "heuristic" => Some(Self::Heuristic),
            "shell" => Some(Self::Shell),
            "inferred" => Some(Self::Inferred),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentPidSignalEvent {
    Attach,
    Clear,
}

impl AgentPidSignalEvent {
    fn parse(raw_value: &str) -> Option<Self> {
        match raw_value {
            "attach" => Some(Self::Attach),
            "clear" => Some(Self::Clear),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentSignalPayload {
    pub window_id: Option<String>,
    pub worklane_id: String,
    pub pane_id: String,
    pub signal_kind: AgentSignalKind,
    pub shell_activity_state: Option<TaskRunnerShellActivityState>,
    pub shell_command: Option<String>,
    pub pid: Option<i32>,
    pub pid_event: Option<AgentPidSignalEvent>,
    pub origin: AgentSignalOrigin,
    pub tool_name: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentSignalCommand {
    pub payload: AgentSignalPayload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentSignalParseError {
    InvalidArguments(String),
    MissingWorklaneId,
    MissingPaneId,
    MissingPid,
}

impl fmt::Display for AgentSignalParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArguments(message) => formatter.write_str(message),
            Self::MissingWorklaneId => formatter.write_str("Missing worklane id."),
            Self::MissingPaneId => formatter.write_str("Missing pane id."),
            Self::MissingPid => formatter.write_str("Missing pid."),
        }
    }
}

impl Error for AgentSignalParseError {}

impl AgentSignalCommand {
    pub fn parse(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> Result<Self, AgentSignalParseError> {
        let trimmed_arguments = trim_agent_signal_command(arguments);
        let raw_kind = trimmed_arguments
            .first()
            .ok_or_else(|| invalid_agent_signal_arguments("Missing or invalid signal kind."))?;
        let kind = AgentSignalKind::parse(raw_kind)
            .ok_or_else(|| invalid_agent_signal_arguments("Missing or invalid signal kind."))?;
        let (positionals, options) = parse_signal_positionals_and_options(&trimmed_arguments[1..])?;
        let worklane_id = options
            .get("worklane-id")
            .or_else(|| environment.get("ZENTTY_WORKLANE_ID"))
            .cloned()
            .ok_or(AgentSignalParseError::MissingWorklaneId)?;
        let pane_id = options
            .get("pane-id")
            .or_else(|| environment.get("ZENTTY_PANE_ID"))
            .cloned()
            .ok_or(AgentSignalParseError::MissingPaneId)?;
        let window_id = options
            .get("window-id")
            .or_else(|| environment.get("ZENTTY_WINDOW_ID"))
            .cloned();
        let origin = options
            .get("origin")
            .and_then(|origin| AgentSignalOrigin::parse(origin))
            .unwrap_or_else(|| default_signal_origin(kind));

        match kind {
            AgentSignalKind::ShellState => {
                let raw_state = positionals
                    .first()
                    .ok_or_else(|| invalid_agent_signal_arguments("Missing shell state."))?;
                let shell_activity_state = parse_shell_activity_state(raw_state)?;
                Ok(Self {
                    payload: AgentSignalPayload {
                        window_id,
                        worklane_id,
                        pane_id,
                        signal_kind: AgentSignalKind::ShellState,
                        shell_activity_state: Some(shell_activity_state),
                        shell_command: options.get("command").cloned(),
                        pid: None,
                        pid_event: None,
                        origin,
                        tool_name: options.get("tool").cloned(),
                    },
                })
            }
            AgentSignalKind::Pid | AgentSignalKind::PaneRootPid => {
                let raw_event = positionals.first().ok_or_else(|| {
                    invalid_agent_signal_arguments("Missing or invalid pid event.")
                })?;
                let pid_event = AgentPidSignalEvent::parse(raw_event).ok_or_else(|| {
                    invalid_agent_signal_arguments("Missing or invalid pid event.")
                })?;
                let pid = match pid_event {
                    AgentPidSignalEvent::Attach => {
                        let raw_pid = positionals
                            .get(1)
                            .ok_or(AgentSignalParseError::MissingPid)?;
                        let parsed_pid = raw_pid
                            .parse::<i32>()
                            .ok()
                            .filter(|pid| *pid > 0)
                            .ok_or(AgentSignalParseError::MissingPid)?;
                        Some(parsed_pid)
                    }
                    AgentPidSignalEvent::Clear => None,
                };

                Ok(Self {
                    payload: AgentSignalPayload {
                        window_id,
                        worklane_id,
                        pane_id,
                        signal_kind: kind,
                        shell_activity_state: None,
                        shell_command: None,
                        pid,
                        pid_event: Some(pid_event),
                        origin,
                        tool_name: (kind == AgentSignalKind::Pid)
                            .then(|| options.get("tool").cloned())
                            .flatten(),
                    },
                })
            }
            _ => Err(invalid_agent_signal_arguments(format!(
                "Unsupported signal kind: {raw_kind}"
            ))),
        }
    }
}

fn trim_agent_signal_command(arguments: &[String]) -> &[String] {
    if let Some(index) = arguments
        .iter()
        .position(|argument| argument == "agent-signal")
    {
        return &arguments[index + 1..];
    }
    arguments
}

fn parse_signal_positionals_and_options(
    arguments: &[String],
) -> Result<(Vec<String>, BTreeMap<String, String>), AgentSignalParseError> {
    let mut positionals = Vec::new();
    let mut options = BTreeMap::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if let Some(option) = argument.strip_prefix("--") {
            if let Some((name, value)) = option.split_once('=') {
                options.insert(name.to_string(), value.to_string());
                index += 1;
                continue;
            }
            let value_index = index + 1;
            let Some(value) = arguments.get(value_index) else {
                return Err(invalid_agent_signal_arguments(format!(
                    "Missing value for {argument}"
                )));
            };
            options.insert(option.to_string(), value.clone());
            index += 2;
        } else {
            positionals.push(argument.clone());
            index += 1;
        }
    }
    Ok((positionals, options))
}

fn parse_shell_activity_state(
    raw_state: &str,
) -> Result<TaskRunnerShellActivityState, AgentSignalParseError> {
    match raw_state {
        "prompt" | "idle" => Ok(TaskRunnerShellActivityState::PromptIdle),
        "running" | "busy" | "command" => Ok(TaskRunnerShellActivityState::CommandRunning),
        "clear" | "unknown" => Ok(TaskRunnerShellActivityState::Unknown),
        _ => Err(invalid_agent_signal_arguments(format!(
            "Unsupported shell state: {raw_state}"
        ))),
    }
}

fn default_signal_origin(kind: AgentSignalKind) -> AgentSignalOrigin {
    match kind {
        AgentSignalKind::ShellState | AgentSignalKind::PaneRootPid => AgentSignalOrigin::Shell,
        AgentSignalKind::Pid => AgentSignalOrigin::ExplicitApi,
        AgentSignalKind::Lifecycle | AgentSignalKind::PaneContext => {
            AgentSignalOrigin::Compatibility
        }
    }
}

fn invalid_agent_signal_arguments(message: impl Into<String>) -> AgentSignalParseError {
    AgentSignalParseError::InvalidArguments(message.into())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentIpcRequestKind {
    Ipc,
    Bootstrap,
    Pane,
    Discover,
    Server,
    #[serde(rename = "tmux_compat")]
    TmuxCompat,
    #[serde(rename = "await_consent")]
    AwaitConsent,
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentBootstrapTool {
    Amp,
    Claude,
    Codex,
    Copilot,
    Cursor,
    Droid,
    Gemini,
    Kimi,
    Opencode,
    Pi,
    Grok,
    Agy,
    Hermes,
}

impl AgentBootstrapTool {
    pub fn all() -> &'static [Self] {
        &[
            Self::Amp,
            Self::Claude,
            Self::Codex,
            Self::Copilot,
            Self::Cursor,
            Self::Droid,
            Self::Gemini,
            Self::Kimi,
            Self::Opencode,
            Self::Pi,
            Self::Grok,
            Self::Agy,
            Self::Hermes,
        ]
    }

    pub fn real_binary_names(self) -> &'static [&'static str] {
        match self {
            Self::Cursor => &["cursor-agent"],
            Self::Kimi => &["kimi", "kimi-cli"],
            Self::Amp => &["amp"],
            Self::Claude => &["claude"],
            Self::Codex => &["codex"],
            Self::Copilot => &["copilot"],
            Self::Droid => &["droid"],
            Self::Gemini => &["gemini"],
            Self::Opencode => &["opencode"],
            Self::Pi => &["pi"],
            Self::Grok => &["grok"],
            Self::Agy => &["agy"],
            Self::Hermes => &["hermes"],
        }
    }

    pub fn wrapped_agent(command: &str) -> Option<Self> {
        let binary_name = wrapped_agent_binary_name(command)?;
        Self::all()
            .iter()
            .copied()
            .find(|tool| tool.real_binary_names().contains(&binary_name.as_str()))
    }

    pub fn integration_class(self) -> AgentIntegrationClass {
        match self {
            Self::Amp | Self::Cursor | Self::Droid | Self::Grok | Self::Agy | Self::Hermes => {
                AgentIntegrationClass::Persistent
            }
            Self::Claude
            | Self::Codex
            | Self::Copilot
            | Self::Gemini
            | Self::Kimi
            | Self::Opencode
            | Self::Pi => AgentIntegrationClass::Ephemeral,
        }
    }

    pub fn default_integration_state(self) -> AgentIntegrationState {
        match self.integration_class() {
            AgentIntegrationClass::Persistent => AgentIntegrationState::Ask,
            AgentIntegrationClass::Ephemeral => AgentIntegrationState::On,
        }
    }

    pub fn integration_display_name(self) -> &'static str {
        match self {
            Self::Amp => "Amp",
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Copilot => "GitHub Copilot",
            Self::Cursor => "Cursor",
            Self::Droid => "Droid",
            Self::Gemini => "Gemini",
            Self::Kimi => "Kimi",
            Self::Opencode => "OpenCode",
            Self::Pi => "Pi",
            Self::Grok => "Grok",
            Self::Agy => "Antigravity",
            Self::Hermes => "Hermes",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentIntegrationClass {
    Persistent,
    Ephemeral,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentIntegrationState {
    Ask,
    On,
    Off,
}

impl AgentIntegrationState {
    pub fn parse(raw_value: &str) -> Option<Self> {
        match raw_value {
            "ask" => Some(Self::Ask),
            "on" => Some(Self::On),
            "off" => Some(Self::Off),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentIntegrationDecision {
    Proceed,
    Off,
    SuppressedByRestore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentIntegrationGate {
    Proceed,
    Off,
    SuppressedByRestore,
    NeedsConsent,
}

impl AgentIntegrationGate {
    pub fn immediate_decision(self) -> Option<AgentIntegrationDecision> {
        match self {
            Self::Proceed => Some(AgentIntegrationDecision::Proceed),
            Self::Off => Some(AgentIntegrationDecision::Off),
            Self::SuppressedByRestore => Some(AgentIntegrationDecision::SuppressedByRestore),
            Self::NeedsConsent => None,
        }
    }
}

pub struct AgentIntegrationConsent;

impl AgentIntegrationConsent {
    pub fn persistent_tools() -> &'static [AgentBootstrapTool] {
        &[
            AgentBootstrapTool::Amp,
            AgentBootstrapTool::Cursor,
            AgentBootstrapTool::Droid,
            AgentBootstrapTool::Grok,
            AgentBootstrapTool::Agy,
            AgentBootstrapTool::Hermes,
        ]
    }

    pub fn ephemeral_tools() -> &'static [AgentBootstrapTool] {
        &[
            AgentBootstrapTool::Claude,
            AgentBootstrapTool::Codex,
            AgentBootstrapTool::Copilot,
            AgentBootstrapTool::Gemini,
            AgentBootstrapTool::Kimi,
            AgentBootstrapTool::Opencode,
            AgentBootstrapTool::Pi,
        ]
    }

    pub fn all_tools() -> &'static [AgentBootstrapTool] {
        &[
            AgentBootstrapTool::Amp,
            AgentBootstrapTool::Cursor,
            AgentBootstrapTool::Droid,
            AgentBootstrapTool::Grok,
            AgentBootstrapTool::Agy,
            AgentBootstrapTool::Hermes,
            AgentBootstrapTool::Claude,
            AgentBootstrapTool::Codex,
            AgentBootstrapTool::Copilot,
            AgentBootstrapTool::Gemini,
            AgentBootstrapTool::Kimi,
            AgentBootstrapTool::Opencode,
            AgentBootstrapTool::Pi,
        ]
    }

    pub fn effective_state(
        tool: AgentBootstrapTool,
        stored_state: Option<AgentIntegrationState>,
    ) -> AgentIntegrationState {
        stored_state.unwrap_or_else(|| tool.default_integration_state())
    }

    pub fn gate(
        tool: AgentBootstrapTool,
        stored_state: Option<AgentIntegrationState>,
        is_restore: bool,
    ) -> AgentIntegrationGate {
        match Self::effective_state(tool, stored_state) {
            AgentIntegrationState::On => AgentIntegrationGate::Proceed,
            AgentIntegrationState::Off => AgentIntegrationGate::Off,
            AgentIntegrationState::Ask => {
                if tool.integration_class() == AgentIntegrationClass::Persistent {
                    if is_restore {
                        AgentIntegrationGate::SuppressedByRestore
                    } else {
                        AgentIntegrationGate::NeedsConsent
                    }
                } else {
                    AgentIntegrationGate::Proceed
                }
            }
        }
    }

    pub fn decision_for_consent_answer(state: AgentIntegrationState) -> AgentIntegrationDecision {
        match state {
            AgentIntegrationState::On => AgentIntegrationDecision::Proceed,
            AgentIntegrationState::Ask | AgentIntegrationState::Off => {
                AgentIntegrationDecision::Off
            }
        }
    }
}

fn wrapped_agent_binary_name(command: &str) -> Option<String> {
    let words = shell_words(command);
    let mut executable = words.first()?;

    if last_path_component(executable) == "env" {
        executable = words
            .iter()
            .skip(1)
            .find(|word| !is_environment_assignment(word))?;
    }

    Some(last_path_component(executable).to_string())
}

fn is_environment_assignment(word: &str) -> bool {
    let Some((name, _)) = word.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_alphabetic()) && chars.all(|ch| ch == '_' || ch.is_alphanumeric())
}

fn shell_words(command: &str) -> Vec<String> {
    #[derive(Clone, Copy, Eq, PartialEq)]
    enum Quote {
        None,
        Single,
        Double,
    }

    let mut words = Vec::new();
    let mut current = String::new();
    let mut has_current_word = false;
    let mut quote = Quote::None;
    let mut is_escaped = false;

    for character in command.chars() {
        if is_escaped {
            current.push(character);
            has_current_word = true;
            is_escaped = false;
            continue;
        }

        match quote {
            Quote::None => {
                if character == '\\' {
                    is_escaped = true;
                    has_current_word = true;
                } else if character == '\'' {
                    quote = Quote::Single;
                    has_current_word = true;
                } else if character == '"' {
                    quote = Quote::Double;
                    has_current_word = true;
                } else if character.is_whitespace() {
                    if has_current_word {
                        words.push(current);
                        current = String::new();
                        has_current_word = false;
                    }
                } else {
                    current.push(character);
                    has_current_word = true;
                }
            }
            Quote::Single => {
                if character == '\'' {
                    quote = Quote::None;
                } else {
                    current.push(character);
                }
            }
            Quote::Double => {
                if character == '"' {
                    quote = Quote::None;
                } else if character == '\\' {
                    is_escaped = true;
                } else {
                    current.push(character);
                }
            }
        }
    }

    if is_escaped {
        current.push('\\');
    }
    if has_current_word {
        words.push(current);
    }
    words
}

fn last_path_component(value: &str) -> &str {
    value
        .rsplit(['/', '\\'])
        .next()
        .filter(|component| !component.is_empty())
        .unwrap_or(value)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentIpcRequest {
    pub version: u32,
    pub id: String,
    pub kind: AgentIpcRequestKind,
    pub arguments: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub standard_input: Option<String>,
    pub environment: BTreeMap<String, String>,
    pub expects_response: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subcommand: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<AgentBootstrapTool>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunchAction {
    pub subcommand: String,
    pub arguments: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub standard_input: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunchPlan {
    pub executable_path: String,
    pub arguments: Vec<String>,
    pub set_environment: BTreeMap<String, String>,
    pub unset_environment: Vec<String>,
    pub pre_launch_actions: Vec<AgentLaunchAction>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneListEntry {
    pub index: i32,
    pub id: String,
    pub column: i32,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    pub is_focused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_tool: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_status: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredWindow {
    pub id: String,
    pub order: i32,
    pub is_focused: bool,
    pub worklane_count: i32,
    pub pane_count: i32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredWorklane {
    pub id: String,
    pub window_id: String,
    pub order: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub is_focused: bool,
    pub pane_count: i32,
    pub column_count: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub focused_pane_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredPane {
    pub id: String,
    pub window_id: String,
    pub worklane_id: String,
    pub index: i32,
    pub column: i32,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    pub is_focused: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_tool: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub control_token: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerListEntry {
    pub id: String,
    pub origin: String,
    pub url: String,
    pub display: String,
    pub worklane_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    pub source: String,
    pub ports: Vec<i32>,
    pub confidence: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasons: Option<Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerListResult {
    pub version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_server_id: Option<String>,
    pub servers: Vec<ServerListEntry>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentIpcResponseResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub launch_plan: Option<AgentLaunchPlan>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_list: Option<Vec<PaneListEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discovered_windows: Option<Vec<DiscoveredWindow>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discovered_worklanes: Option<Vec<DiscoveredWorklane>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discovered_panes: Option<Vec<DiscoveredPane>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_state: Option<ServerListResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub consent_required: Option<bool>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentIpcResponseError {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentIpcResponse {
    pub version: u32,
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<AgentIpcResponseResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<AgentIpcResponseError>,
}
