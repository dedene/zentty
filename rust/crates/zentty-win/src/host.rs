use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

use zentty_core::agent::{AgentIpcRequest, AgentIpcRequestKind};
use zentty_core::commands::AppCommandId;
use zentty_core::session_restore::SessionRestoreEnvelope;
use zentty_pty::native::NativePtySession;
use zentty_pty::{PtyError, PtySessionRequest, TerminalSize};

use crate::app::{
    AppCommandExecutionResult, AppLaunchError, AppLaunchPlan, AppRuntimeError, RunningAppSet,
};
use crate::ipc::{AgentIpcTransportError, send_agent_ipc_request};

const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostConfig {
    pub size: TerminalSize,
    pub request: PtySessionRequest,
    pub command_supplied: bool,
    pub workspace_path: Option<PathBuf>,
    pub app_command_ids: Vec<AppCommandId>,
}

impl HostConfig {
    pub fn parse<I, S>(args: I) -> Result<Self, HostConfigError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut args = args.into_iter().map(Into::into).peekable();
        let mut cols = TerminalSize::default().cols;
        let mut rows = TerminalSize::default().rows;
        let mut cwd = None;
        let mut env = Vec::new();
        let mut command = Vec::new();
        let mut workspace_path = None;
        let mut app_command_ids = Vec::new();

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "-h" | "--help" => return Err(HostConfigError::HelpRequested),
                "--cols" => {
                    let value = next_value(&mut args, "--cols")?;
                    cols = parse_dimension("--cols", &value)?;
                }
                "--rows" => {
                    let value = next_value(&mut args, "--rows")?;
                    rows = parse_dimension("--rows", &value)?;
                }
                "--cwd" => {
                    cwd = Some(next_value(&mut args, "--cwd")?);
                }
                "--env" => {
                    let assignment = next_value(&mut args, "--env")?;
                    let (key, value) = assignment.split_once('=').ok_or_else(|| {
                        HostConfigError::InvalidEnvironmentAssignment(assignment.clone())
                    })?;
                    if key.is_empty() {
                        return Err(HostConfigError::InvalidEnvironmentAssignment(assignment));
                    }
                    env.push((key.to_string(), value.to_string()));
                }
                "--workspace" => {
                    workspace_path = Some(PathBuf::from(next_value(&mut args, "--workspace")?));
                }
                "--app-command" => {
                    let value = next_value(&mut args, "--app-command")?;
                    let command_id = AppCommandId::from_raw_value(&value)
                        .ok_or_else(|| HostConfigError::UnknownAppCommand(value.clone()))?;
                    app_command_ids.push(command_id);
                }
                "--" => {
                    command.extend(args);
                    break;
                }
                value if value.starts_with("--") => {
                    return Err(HostConfigError::UnknownOption(value.to_string()));
                }
                _ => {
                    command.push(arg);
                    command.extend(args);
                    break;
                }
            }
        }

        let command_supplied = !command.is_empty();
        let mut command = command.into_iter();
        let program = command.next().unwrap_or_else(default_shell);
        let mut request = PtySessionRequest::new(program).extend_args(command);

        if let Some(cwd) = cwd {
            request = request.cwd(cwd);
        }

        for (key, value) in env {
            request = request.env(key, value);
        }

        request
            .validate()
            .map_err(|error| HostConfigError::InvalidPtyRequest(error.to_string()))?;

        if workspace_path.is_none()
            && let Some(command_id) = app_command_ids.first()
        {
            return Err(HostConfigError::AppCommandRequiresWorkspace(*command_id));
        }
        if workspace_path.is_some() && command_supplied {
            return Err(HostConfigError::WorkspaceCommandConflict);
        }

        Ok(Self {
            size: TerminalSize::new(cols, rows),
            request,
            command_supplied,
            workspace_path,
            app_command_ids,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostConfigError {
    MissingValue(String),
    InvalidNumber { option: String, value: String },
    InvalidEnvironmentAssignment(String),
    UnknownOption(String),
    UnknownAppCommand(String),
    AppCommandRequiresWorkspace(AppCommandId),
    WorkspaceCommandConflict,
    InvalidPtyRequest(String),
    HelpRequested,
}

impl fmt::Display for HostConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HostConfigError::MissingValue(option) => {
                write!(formatter, "missing value for {option}")
            }
            HostConfigError::InvalidNumber { option, value } => {
                write!(formatter, "invalid numeric value for {option}: {value:?}")
            }
            HostConfigError::InvalidEnvironmentAssignment(assignment) => {
                write!(
                    formatter,
                    "environment assignment must use KEY=VALUE: {assignment:?}"
                )
            }
            HostConfigError::UnknownOption(option) => write!(formatter, "unknown option: {option}"),
            HostConfigError::UnknownAppCommand(command_id) => {
                write!(formatter, "unknown app command: {command_id}")
            }
            HostConfigError::AppCommandRequiresWorkspace(command_id) => {
                write!(
                    formatter,
                    "app command {} requires --workspace",
                    command_id.raw_value()
                )
            }
            HostConfigError::WorkspaceCommandConflict => {
                write!(
                    formatter,
                    "--workspace cannot be combined with a trailing command"
                )
            }
            HostConfigError::InvalidPtyRequest(error) => write!(formatter, "{error}"),
            HostConfigError::HelpRequested => write!(formatter, "help requested"),
        }
    }
}

impl Error for HostConfigError {}

pub fn run_agent_ipc_cli<I, S, W>(args: I, output: &mut W) -> Result<u32, AgentIpcCliError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
    W: Write,
{
    let mut response_override = None;
    let mut arguments = Vec::new();
    for arg in args.into_iter().map(Into::into) {
        match arg.as_str() {
            "--expect-response" => response_override = Some(true),
            "--no-response" => response_override = Some(false),
            _ => arguments.push(arg),
        }
    }
    let Some(first_argument) = arguments.first().cloned() else {
        return Err(AgentIpcCliError::MissingSubcommand);
    };
    let (kind, subcommand, request_arguments) = match first_argument.as_str() {
        "pane" => {
            let Some(subcommand) = arguments.get(1).cloned() else {
                return Err(AgentIpcCliError::MissingSubcommand);
            };
            (
                AgentIpcRequestKind::Pane,
                subcommand,
                arguments[2..].to_vec(),
            )
        }
        "server" => {
            let Some(subcommand) = arguments.get(1) else {
                return Err(AgentIpcCliError::MissingSubcommand);
            };
            (
                AgentIpcRequestKind::Server,
                server_ipc_subcommand(subcommand),
                arguments[2..].to_vec(),
            )
        }
        _ => (
            AgentIpcRequestKind::Ipc,
            first_argument,
            arguments[1..].to_vec(),
        ),
    };
    let expects_response = response_override.unwrap_or_else(|| {
        kind == AgentIpcRequestKind::Server && request_arguments.iter().any(|arg| arg == "--json")
    });
    let socket_path = std::env::var("ZENTTY_INSTANCE_SOCKET")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(AgentIpcCliError::OutsidePane)?;
    let environment = forwarded_agent_ipc_environment();
    if ["ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"]
        .iter()
        .any(|key| !environment.contains_key(*key))
    {
        return Err(AgentIpcCliError::OutsidePane);
    }
    let request = AgentIpcRequest {
        version: 1,
        id: next_agent_ipc_request_id(),
        kind,
        arguments: request_arguments,
        standard_input: None,
        environment,
        expects_response,
        subcommand: Some(subcommand),
        tool: None,
    };
    let response = send_agent_ipc_request(&socket_path, &request)?;
    if let Some(response) = response {
        let ok = response.ok;
        serde_json::to_writer(&mut *output, &response)?;
        output.write_all(b"\n")?;
        return Ok(if ok { 0 } else { 1 });
    }
    Ok(0)
}

fn server_ipc_subcommand(subcommand: &str) -> String {
    match subcommand {
        "set" => "server-set",
        "clear" => "server-clear",
        "list" => "server-list",
        "open" => "server-open",
        "watch-set" => "server-watch-set",
        "watch-clear" => "server-watch-clear",
        other => other,
    }
    .to_string()
}

#[derive(Debug)]
pub enum AgentIpcCliError {
    MissingSubcommand,
    OutsidePane,
    Transport(AgentIpcTransportError),
    Json(serde_json::Error),
    Io(io::Error),
}

impl fmt::Display for AgentIpcCliError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingSubcommand => write!(formatter, "missing ipc subcommand"),
            Self::OutsidePane => write!(formatter, "zentty ipc must run inside a Zentty pane"),
            Self::Transport(error) => write!(formatter, "{error}"),
            Self::Json(error) => write!(formatter, "{error}"),
            Self::Io(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for AgentIpcCliError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::MissingSubcommand | Self::OutsidePane => None,
            Self::Transport(error) => Some(error),
            Self::Json(error) => Some(error),
            Self::Io(error) => Some(error),
        }
    }
}

impl From<AgentIpcTransportError> for AgentIpcCliError {
    fn from(error: AgentIpcTransportError) -> Self {
        Self::Transport(error)
    }
}

impl From<serde_json::Error> for AgentIpcCliError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<io::Error> for AgentIpcCliError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Debug)]
pub enum HostRunError {
    ScriptedCommandRequired,
    WorkspaceFocusedPaneUnavailable,
    WorkspaceRead {
        path: PathBuf,
        source: io::Error,
    },
    WorkspaceDecode {
        path: PathBuf,
        source: serde_json::Error,
    },
    WorkspaceLaunch(AppLaunchError),
    WorkspaceAppCommandUnavailable {
        command_id: AppCommandId,
        result: AppCommandExecutionResult,
    },
    Runtime(AppRuntimeError),
    Pty(PtyError),
    Io(io::Error),
}

impl fmt::Display for HostRunError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HostRunError::ScriptedCommandRequired => {
                write!(formatter, "scripted mode requires a command after --")
            }
            HostRunError::WorkspaceFocusedPaneUnavailable => {
                write!(formatter, "workspace has no focused pane to attach")
            }
            HostRunError::WorkspaceRead { path, source } => {
                write!(
                    formatter,
                    "failed to read workspace {}: {source}",
                    path.display()
                )
            }
            HostRunError::WorkspaceDecode { path, source } => {
                write!(
                    formatter,
                    "failed to decode workspace {}: {source}",
                    path.display()
                )
            }
            HostRunError::WorkspaceLaunch(error) => write!(formatter, "{error:?}"),
            HostRunError::WorkspaceAppCommandUnavailable { command_id, result } => {
                write!(
                    formatter,
                    "workspace app command {} was not applied: {result:?}",
                    command_id.raw_value()
                )
            }
            HostRunError::Runtime(error) => write!(formatter, "{error:?}"),
            HostRunError::Pty(error) => write!(formatter, "{error}"),
            HostRunError::Io(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for HostRunError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            HostRunError::WorkspaceRead { source, .. } => Some(source),
            HostRunError::WorkspaceDecode { source, .. } => Some(source),
            HostRunError::Pty(error) => Some(error),
            HostRunError::Io(error) => Some(error),
            HostRunError::ScriptedCommandRequired
            | HostRunError::WorkspaceFocusedPaneUnavailable
            | HostRunError::WorkspaceLaunch(_)
            | HostRunError::WorkspaceAppCommandUnavailable { .. }
            | HostRunError::Runtime(_) => None,
        }
    }
}

impl From<PtyError> for HostRunError {
    fn from(error: PtyError) -> Self {
        HostRunError::Pty(error)
    }
}

impl From<io::Error> for HostRunError {
    fn from(error: io::Error) -> Self {
        HostRunError::Io(error)
    }
}

pub fn run_scripted<W: Write>(config: HostConfig, output: &mut W) -> Result<u32, HostRunError> {
    if !config.command_supplied {
        return Err(HostRunError::ScriptedCommandRequired);
    }

    let session = NativePtySession::spawn(config.request, config.size)?;
    let child_output = session.wait_with_output(DEFAULT_COMMAND_TIMEOUT)?;
    output.write_all(child_output.output.as_bytes())?;
    output.flush()?;

    Ok(child_output
        .exit_code
        .unwrap_or(u32::from(!child_output.status_success)))
}

pub fn run_interactive<R, W>(
    config: HostConfig,
    input: R,
    output: W,
    timeout: Option<Duration>,
) -> Result<u32, HostRunError>
where
    R: Read + Send + 'static,
    W: Write + Send + 'static,
{
    let session = NativePtySession::spawn(config.request, config.size)?;
    let child_output = session.run_with_streams(input, output, timeout)?;

    Ok(child_output
        .exit_code
        .unwrap_or(u32::from(!child_output.status_success)))
}

pub fn run_workspace_interactive<R, W>(
    config: HostConfig,
    input: R,
    output: W,
    timeout: Option<Duration>,
) -> Result<u32, HostRunError>
where
    R: Read + Send + 'static,
    W: Write + Send + 'static,
{
    let workspace_path = config
        .workspace_path
        .clone()
        .ok_or(HostRunError::WorkspaceFocusedPaneUnavailable)?;
    let json =
        std::fs::read_to_string(&workspace_path).map_err(|source| HostRunError::WorkspaceRead {
            path: workspace_path.clone(),
            source,
        })?;
    let envelope: SessionRestoreEnvelope =
        serde_json::from_str(&json).map_err(|source| HostRunError::WorkspaceDecode {
            path: workspace_path.clone(),
            source,
        })?;
    let plan = AppLaunchPlan::from_envelope(&envelope);
    let mut running =
        RunningAppSet::spawn(plan, config.size).map_err(HostRunError::WorkspaceLaunch)?;
    for command_id in config.app_command_ids {
        match running.execute_command(command_id) {
            Ok(AppCommandExecutionResult::Applied) => {}
            Ok(result) => {
                running
                    .terminate_all_panes()
                    .map_err(HostRunError::Runtime)?;
                return Err(HostRunError::WorkspaceAppCommandUnavailable { command_id, result });
            }
            Err(error) => {
                running
                    .terminate_all_panes()
                    .map_err(HostRunError::Runtime)?;
                return Err(HostRunError::Runtime(error));
            }
        }
    }
    let focused = running
        .take_active_focused_pane()
        .ok_or(HostRunError::WorkspaceFocusedPaneUnavailable)?;
    let child_output = focused.run_with_streams(input, output, timeout)?;
    running
        .terminate_all_panes()
        .map_err(HostRunError::Runtime)?;

    Ok(child_output
        .exit_code
        .unwrap_or(u32::from(!child_output.status_success)))
}

pub fn usage() -> &'static str {
    "Usage: zentty-win [--cols N] [--rows N] [--cwd PATH] [--env KEY=VALUE] [--workspace RESTORE_JSON] [--app-command COMMAND_ID]... -- PROGRAM [ARG]...\n       zentty-win server <set|clear|list|open|watch-set|watch-clear> [ARG]..."
}

fn next_value<I>(args: &mut I, option: &str) -> Result<String, HostConfigError>
where
    I: Iterator<Item = String>,
{
    args.next()
        .ok_or_else(|| HostConfigError::MissingValue(option.to_string()))
}

fn parse_dimension(option: &str, value: &str) -> Result<u16, HostConfigError> {
    value.parse().map_err(|_| HostConfigError::InvalidNumber {
        option: option.to_string(),
        value: value.to_string(),
    })
}

fn forwarded_agent_ipc_environment() -> BTreeMap<String, String> {
    [
        "ZENTTY_WINDOW_ID",
        "ZENTTY_WORKLANE_ID",
        "ZENTTY_PANE_ID",
        "ZENTTY_PANE_TOKEN",
        "ZENTTY_INSTANCE_ID",
    ]
    .into_iter()
    .filter_map(|key| {
        std::env::var(key)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| (key.to_string(), value))
    })
    .collect()
}

fn next_agent_ipc_request_id() -> String {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("zentty-win-ipc-{}-{timestamp}", std::process::id())
}

pub(crate) fn default_shell() -> String {
    platform_shell().unwrap_or_else(|| fallback_shell().to_string())
}

fn platform_shell() -> Option<String> {
    let key = platform_shell_env_key();
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(windows)]
fn platform_shell_env_key() -> &'static str {
    "COMSPEC"
}

#[cfg(not(windows))]
fn platform_shell_env_key() -> &'static str {
    "SHELL"
}

#[cfg(windows)]
fn fallback_shell() -> &'static str {
    "cmd.exe"
}

#[cfg(not(windows))]
fn fallback_shell() -> &'static str {
    "sh"
}
