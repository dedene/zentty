use std::collections::BTreeMap;

use serde_json::json;
use zentty_core::agent::{
    AgentBootstrapTool, AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse,
    AgentIpcResponseResult, AgentLaunchAction, AgentLaunchPlan, AgentPidSignalEvent,
    AgentSignalCommand, AgentSignalKind, AgentSignalOrigin, PaneListEntry,
};
use zentty_core::task_runner::TaskRunnerShellActivityState;

#[test]
fn agent_ipc_request_serializes_with_swift_field_names_and_raw_values() {
    let request = AgentIpcRequest {
        version: 1,
        id: "request-1".to_string(),
        kind: AgentIpcRequestKind::TmuxCompat,
        arguments: vec!["send-keys".to_string(), "Enter".to_string()],
        standard_input: Some("stdin".to_string()),
        environment: BTreeMap::from([
            ("ZENTTY_WORKLANE_ID".to_string(), "wl_1".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pn_1".to_string()),
        ]),
        expects_response: true,
        subcommand: Some("send-keys".to_string()),
        tool: Some(AgentBootstrapTool::Claude),
    };

    let value = serde_json::to_value(&request).expect("request should serialize");

    assert_eq!(
        value,
        json!({
            "version": 1,
            "id": "request-1",
            "kind": "tmux_compat",
            "arguments": ["send-keys", "Enter"],
            "standardInput": "stdin",
            "environment": {
                "ZENTTY_WORKLANE_ID": "wl_1",
                "ZENTTY_PANE_ID": "pn_1"
            },
            "expectsResponse": true,
            "subcommand": "send-keys",
            "tool": "claude"
        })
    );
}

#[test]
fn agent_ipc_response_round_trips_launch_plan_and_pane_list() {
    let response = AgentIpcResponse {
        version: 1,
        id: "request-2".to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult {
            launch_plan: Some(AgentLaunchPlan {
                executable_path: "C:\\Tools\\claude.exe".to_string(),
                arguments: vec!["--resume".to_string()],
                set_environment: BTreeMap::from([("ZENTTY".to_string(), "1".to_string())]),
                unset_environment: vec!["OLD_ZENTTY".to_string()],
                pre_launch_actions: vec![AgentLaunchAction {
                    subcommand: "agent-status".to_string(),
                    arguments: vec!["running".to_string()],
                    standard_input: None,
                }],
            }),
            pane_list: Some(vec![PaneListEntry {
                index: 0,
                id: "pn_1".to_string(),
                column: 0,
                title: "shell".to_string(),
                working_directory: Some("C:\\Projects\\zentty".to_string()),
                is_focused: true,
                agent_tool: Some("claude".to_string()),
                agent_status: Some("running".to_string()),
            }]),
            ..AgentIpcResponseResult::default()
        }),
        error: None,
    };

    let encoded = serde_json::to_string(&response).expect("response should serialize");
    let decoded: AgentIpcResponse =
        serde_json::from_str(&encoded).expect("response should deserialize");

    assert_eq!(decoded, response);
    let value: serde_json::Value = serde_json::from_str(&encoded).expect("json should parse");
    assert_eq!(
        value["result"]["launchPlan"]["executablePath"],
        "C:\\Tools\\claude.exe"
    );
    assert_eq!(
        value["result"]["paneList"][0]["workingDirectory"],
        "C:\\Projects\\zentty"
    );
    assert_eq!(value["result"]["paneList"][0]["isFocused"], true);
}

#[test]
fn agent_signal_shell_state_parses_swift_cli_aliases_and_target_context() {
    let request = AgentSignalCommand::parse(
        &[
            "ipc".to_string(),
            "agent-signal".to_string(),
            "shell-state".to_string(),
            "running".to_string(),
            "--window-id".to_string(),
            "window-main".to_string(),
            "--worklane-id".to_string(),
            "main".to_string(),
            "--pane-id".to_string(),
            "pane-right".to_string(),
            "--tool".to_string(),
            "codex".to_string(),
            "--command".to_string(),
            "npm test".to_string(),
        ],
        &BTreeMap::new(),
    )
    .expect("shell-state signal should parse");

    assert_eq!(request.payload.signal_kind, AgentSignalKind::ShellState);
    assert_eq!(request.payload.origin, AgentSignalOrigin::Shell);
    assert_eq!(request.payload.window_id.as_deref(), Some("window-main"));
    assert_eq!(request.payload.worklane_id, "main");
    assert_eq!(request.payload.pane_id, "pane-right");
    assert_eq!(
        request.payload.shell_activity_state,
        Some(TaskRunnerShellActivityState::CommandRunning)
    );
    assert_eq!(request.payload.tool_name.as_deref(), Some("codex"));
    assert_eq!(request.payload.shell_command.as_deref(), Some("npm test"));

    let idle = AgentSignalCommand::parse(
        &[
            "agent-signal".to_string(),
            "shell-state".to_string(),
            "idle".to_string(),
        ],
        &BTreeMap::from([
            ("ZENTTY_WORKLANE_ID".to_string(), "main".to_string()),
            ("ZENTTY_PANE_ID".to_string(), "pane-right".to_string()),
        ]),
    )
    .expect("environment target should parse");
    assert_eq!(
        idle.payload.shell_activity_state,
        Some(TaskRunnerShellActivityState::PromptIdle)
    );
}

#[test]
fn agent_signal_pane_root_pid_parses_attach_and_clear_without_agent_tool() {
    let attach = AgentSignalCommand::parse(
        &[
            "agent-signal".to_string(),
            "pane-root-pid".to_string(),
            "attach".to_string(),
            "4242".to_string(),
        ],
        &BTreeMap::from([
            (
                "ZENTTY_WORKLANE_ID".to_string(),
                "worklane-main".to_string(),
            ),
            ("ZENTTY_PANE_ID".to_string(), "pane-main".to_string()),
        ]),
    )
    .expect("pane-root-pid attach should parse");

    assert_eq!(attach.payload.signal_kind, AgentSignalKind::PaneRootPid);
    assert_eq!(attach.payload.pid_event, Some(AgentPidSignalEvent::Attach));
    assert_eq!(attach.payload.pid, Some(4242));
    assert_eq!(attach.payload.origin, AgentSignalOrigin::Shell);
    assert_eq!(attach.payload.tool_name, None);

    let clear = AgentSignalCommand::parse(
        &[
            "agent-signal".to_string(),
            "pane-root-pid".to_string(),
            "clear".to_string(),
        ],
        &BTreeMap::from([
            (
                "ZENTTY_WORKLANE_ID".to_string(),
                "worklane-main".to_string(),
            ),
            ("ZENTTY_PANE_ID".to_string(), "pane-main".to_string()),
        ]),
    )
    .expect("pane-root-pid clear should parse");

    assert_eq!(clear.payload.signal_kind, AgentSignalKind::PaneRootPid);
    assert_eq!(clear.payload.pid_event, Some(AgentPidSignalEvent::Clear));
    assert_eq!(clear.payload.pid, None);
}
