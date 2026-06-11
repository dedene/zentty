use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use zentty_core::agent::{AgentIpcResponse, AgentIpcResponseResult};
use zentty_core::commands::AppCommandId;
use zentty_win::ipc::AgentIpcNamedPipeListener;

#[test]
#[cfg(windows)]
fn zentty_win_binary_runs_command_through_pty() {
    let output = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "--cols",
            "80",
            "--rows",
            "24",
            "--",
            "cmd.exe",
            "/d",
            "/s",
            "/c",
            "echo ZENTTY_WIN_SMOKE",
        ])
        .output()
        .expect("zentty-win binary should run");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("ZENTTY_WIN_SMOKE"),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_agent_signal_over_named_pipe() {
    let pipe_path = format!(r"\\.\pipe\zentty-binary-ipc-{}", std::process::id());
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "agent-signal",
            "shell-state",
            "prompt",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Ipc
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("agent-signal"));
    assert_eq!(
        pending.request.arguments,
        vec!["shell-state".to_string(), "prompt".to_string()]
    );
    assert_eq!(
        pending.request.environment.get("ZENTTY_PANE_TOKEN"),
        Some(&"pane-token".to_string())
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_server_set_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-server-set-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["ipc", "server", "set", "http://127.0.0.1:5173/", "--json"])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Server
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("server-set"));
    assert_eq!(
        pending.request.arguments,
        vec!["http://127.0.0.1:5173/".to_string(), "--json".to_string()]
    );
    assert_eq!(
        pending.request.environment.get("ZENTTY_PANE_TOKEN"),
        Some(&"pane-token".to_string())
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_server_list_alias_sends_server_list_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-server-list-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["server", "list", "--json"])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win server should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Server
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("server-list"));
    assert_eq!(pending.request.arguments, vec!["--json".to_string()]);
    assert_eq!(
        pending.request.environment.get("ZENTTY_PANE_TOKEN"),
        Some(&"pane-token".to_string())
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win server should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_list_over_named_pipe() {
    let pipe_path = format!(r"\\.\pipe\zentty-binary-pane-ipc-{}", std::process::id());
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["ipc", "--expect-response", "pane", "list"])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("list"));
    assert!(pending.request.arguments.is_empty());
    assert_eq!(
        pending.request.environment.get("ZENTTY_PANE_TOKEN"),
        Some(&"pane-token".to_string())
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_focus_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-focus-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["ipc", "--expect-response", "pane", "focus", "right"])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("focus"));
    assert_eq!(pending.request.arguments, vec!["right".to_string()]);
    assert_eq!(
        pending.request.environment.get("ZENTTY_PANE_TOKEN"),
        Some(&"pane-token".to_string())
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_split_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-split-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "pane",
            "split",
            "left",
            "--ratio",
            "50",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("split"));
    assert_eq!(
        pending.request.arguments,
        vec!["left".to_string(), "--ratio".to_string(), "50".to_string()]
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_worklane_color_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-worklane-color-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "pane",
            "worklane-color",
            "--color",
            "blue",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(
        pending.request.subcommand.as_deref(),
        Some("worklane-color")
    );
    assert_eq!(
        pending.request.arguments,
        vec!["--color".to_string(), "blue".to_string()]
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_worklane_rename_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-worklane-rename-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "pane",
            "worklane-rename",
            "--title",
            "Agent Lane",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(
        pending.request.subcommand.as_deref(),
        Some("worklane-rename")
    );
    assert_eq!(
        pending.request.arguments,
        vec!["--title".to_string(), "Agent Lane".to_string()]
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_notify_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-notify-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "pane",
            "notify",
            "--title",
            "Build Ready",
            "--subtitle",
            "Agent",
            "--body",
            "Done",
            "--silent",
            "--no-inbox",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("notify"));
    assert_eq!(
        pending.request.arguments,
        vec![
            "--title".to_string(),
            "Build Ready".to_string(),
            "--subtitle".to_string(),
            "Agent".to_string(),
            "--body".to_string(),
            "Done".to_string(),
            "--silent".to_string(),
            "--no-inbox".to_string(),
        ]
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_grid_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-grid-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "ipc",
            "--expect-response",
            "pane",
            "grid",
            "--rows",
            "2",
            "--columns",
            "3",
            "--command-json",
            r#"["findstr","."]"#,
            "--include-source",
            "--focus",
            "last",
        ])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("grid"));
    assert_eq!(
        pending.request.arguments,
        vec![
            "--rows".to_string(),
            "2".to_string(),
            "--columns".to_string(),
            "3".to_string(),
            "--command-json".to_string(),
            r#"["findstr","."]"#.to_string(),
            "--include-source".to_string(),
            "--focus".to_string(),
            "last".to_string(),
        ]
    );
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_ipc_sends_pane_theme_over_named_pipe() {
    let pipe_path = format!(
        r"\\.\pipe\zentty-binary-pane-theme-ipc-{}",
        std::process::id()
    );
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["ipc", "--expect-response", "pane", "theme", "toggle"])
        .env("ZENTTY_INSTANCE_SOCKET", &pipe_path)
        .env("ZENTTY_WINDOW_ID", "window-main")
        .env("ZENTTY_WORKLANE_ID", "main")
        .env("ZENTTY_PANE_ID", "pane-right")
        .env("ZENTTY_PANE_TOKEN", "pane-token")
        .env("ZENTTY_INSTANCE_ID", "instance-id")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win ipc should spawn");

    let pending = listener
        .recv_timeout(std::time::Duration::from_secs(2))
        .expect("listener should receive ipc request");
    assert_eq!(
        pending.request.kind,
        zentty_core::agent::AgentIpcRequestKind::Pane
    );
    assert_eq!(pending.request.subcommand.as_deref(), Some("theme"));
    assert_eq!(pending.request.arguments, vec!["toggle".to_string()]);
    assert!(pending.request.expects_response);
    let response_id = pending.request.id.clone();
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: response_id,
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let output = child
        .wait_with_output()
        .expect("zentty-win ipc should exit");
    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let response: AgentIpcResponse =
        serde_json::from_slice(String::from_utf8_lossy(&output.stdout).trim().as_bytes())
            .expect("stdout should contain response json");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_without_command_runs_default_shell_interactively() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args(["--cols", "80", "--rows", "24"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win binary should start");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"echo ZENTTY_WIN_INTERACTIVE_SMOKE\rexit\r")
        .expect("stdin should accept commands");

    let output = child
        .wait_with_output()
        .expect("zentty-win binary should finish");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("ZENTTY_WIN_INTERACTIVE_SMOKE"),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_runs_workspace_envelope_focused_pane() {
    let dir = test_directory("workspace-envelope");
    let envelope_path = dir.join("restore.json");
    let cwd_json = dir.to_string_lossy().replace('\\', "\\\\");
    fs::write(
        &envelope_path,
        format!(
            r#"{{
              "schemaVersion": 1,
              "savedAt": 0,
              "reason": "liveSnapshot",
              "workspace": {{
                "schemaVersion": 2,
                "activeWindowID": "window-main",
                "windows": [{{
                  "id": "window-main",
                  "activeWorklaneID": "main",
                  "worklanes": [{{
                    "id": "main",
                    "nextPaneNumber": 2,
                    "focusedColumnID": "column-main",
                    "columns": [{{
                      "id": "column-main",
                      "width": 640.0,
                      "focusedPaneID": "pane-main",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-main",
                        "titleSeed": "shell",
                        "workingDirectory": "{cwd_json}"
                      }}]
                    }}]
                  }}]
                }}]
              }},
              "restoreDraftWindows": []
            }}"#
        ),
    )
    .expect("restore envelope should be written");

    let mut child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "--cols",
            "80",
            "--rows",
            "24",
            "--workspace",
            envelope_path.to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win workspace mode should start");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"echo ZENTTY_WORKSPACE_HOST\rexit\r")
        .expect("stdin should accept commands");

    let output = child
        .wait_with_output()
        .expect("zentty-win workspace mode should finish");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("ZENTTY_WORKSPACE_HOST"),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_applies_workspace_app_commands_before_attach() {
    let dir = test_directory("workspace-app-command");
    let left_dir = dir.join("left");
    let right_dir = dir.join("right");
    fs::create_dir_all(&left_dir).expect("left pane directory should be created");
    fs::create_dir_all(&right_dir).expect("right pane directory should be created");

    let envelope_path = dir.join("restore.json");
    let left_cwd_json = left_dir.to_string_lossy().replace('\\', "\\\\");
    let right_cwd_json = right_dir.to_string_lossy().replace('\\', "\\\\");
    fs::write(
        &envelope_path,
        format!(
            r#"{{
              "schemaVersion": 1,
              "savedAt": 0,
              "reason": "liveSnapshot",
              "workspace": {{
                "schemaVersion": 2,
                "activeWindowID": "window-main",
                "windows": [{{
                  "id": "window-main",
                  "activeWorklaneID": "main",
                  "worklanes": [{{
                    "id": "main",
                    "nextPaneNumber": 3,
                    "focusedColumnID": "column-left",
                    "columns": [{{
                      "id": "column-left",
                      "width": 320.0,
                      "focusedPaneID": "pane-left",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-left",
                        "titleSeed": "left",
                        "workingDirectory": "{left_cwd_json}"
                      }}]
                    }}, {{
                      "id": "column-right",
                      "width": 320.0,
                      "focusedPaneID": "pane-right",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-right",
                        "titleSeed": "right",
                        "workingDirectory": "{right_cwd_json}"
                      }}]
                    }}]
                  }}]
                }}]
              }},
              "restoreDraftWindows": []
            }}"#
        ),
    )
    .expect("restore envelope should be written");

    let mut child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "--cols",
            "80",
            "--rows",
            "24",
            "--workspace",
            envelope_path.to_string_lossy().as_ref(),
            "--app-command",
            AppCommandId::FocusRightPane.raw_value(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win workspace mode should start");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"cd\rexit\r")
        .expect("stdin should accept commands");

    let output = child
        .wait_with_output()
        .expect("zentty-win workspace mode should finish");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(right_dir.to_string_lossy().as_ref()),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !String::from_utf8_lossy(&output.stdout).contains(left_dir.to_string_lossy().as_ref()),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_applies_workspace_new_window_app_command_before_attach() {
    let dir = test_directory("workspace-new-window-app-command");
    let cwd = dir.join("source");
    fs::create_dir_all(&cwd).expect("source pane directory should be created");

    let envelope_path = dir.join("restore.json");
    let cwd_json = cwd.to_string_lossy().replace('\\', "\\\\");
    fs::write(
        &envelope_path,
        format!(
            r#"{{
              "schemaVersion": 1,
              "savedAt": 0,
              "reason": "liveSnapshot",
              "workspace": {{
                "schemaVersion": 2,
                "activeWindowID": "window-main",
                "windows": [{{
                  "id": "window-main",
                  "activeWorklaneID": "main",
                  "worklanes": [{{
                    "id": "main",
                    "nextPaneNumber": 2,
                    "focusedColumnID": "column-main",
                    "columns": [{{
                      "id": "column-main",
                      "width": 640.0,
                      "focusedPaneID": "pane-main",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-main",
                        "titleSeed": "source",
                        "workingDirectory": "{cwd_json}"
                      }}]
                    }}]
                  }}]
                }}]
              }},
              "restoreDraftWindows": []
            }}"#
        ),
    )
    .expect("restore envelope should be written");

    let mut child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "--cols",
            "80",
            "--rows",
            "24",
            "--workspace",
            envelope_path.to_string_lossy().as_ref(),
            "--app-command",
            AppCommandId::NewWindow.raw_value(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win workspace mode should start");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"cd\rexit\r")
        .expect("stdin should accept commands");

    let output = child
        .wait_with_output()
        .expect("zentty-win workspace mode should finish");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(cwd.to_string_lossy().as_ref()),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn zentty_win_binary_applies_workspace_move_pane_to_new_window_app_command_before_attach() {
    let dir = test_directory("workspace-move-pane-app-command");
    let left_dir = dir.join("left");
    let right_dir = dir.join("right");
    fs::create_dir_all(&left_dir).expect("left pane directory should be created");
    fs::create_dir_all(&right_dir).expect("right pane directory should be created");

    let envelope_path = dir.join("restore.json");
    let left_cwd_json = left_dir.to_string_lossy().replace('\\', "\\\\");
    let right_cwd_json = right_dir.to_string_lossy().replace('\\', "\\\\");
    fs::write(
        &envelope_path,
        format!(
            r#"{{
              "schemaVersion": 1,
              "savedAt": 0,
              "reason": "liveSnapshot",
              "workspace": {{
                "schemaVersion": 2,
                "activeWindowID": "window-main",
                "windows": [{{
                  "id": "window-main",
                  "activeWorklaneID": "main",
                  "worklanes": [{{
                    "id": "main",
                    "nextPaneNumber": 3,
                    "focusedColumnID": "column-left",
                    "columns": [{{
                      "id": "column-left",
                      "width": 320.0,
                      "focusedPaneID": "pane-left",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-left",
                        "titleSeed": "left",
                        "workingDirectory": "{left_cwd_json}"
                      }}]
                    }}, {{
                      "id": "column-right",
                      "width": 320.0,
                      "focusedPaneID": "pane-right",
                      "paneHeights": [480.0],
                      "panes": [{{
                        "id": "pane-right",
                        "titleSeed": "right",
                        "workingDirectory": "{right_cwd_json}"
                      }}]
                    }}]
                  }}]
                }}]
              }},
              "restoreDraftWindows": []
            }}"#
        ),
    )
    .expect("restore envelope should be written");

    let mut child = Command::new(env!("CARGO_BIN_EXE_zentty-win"))
        .args([
            "--cols",
            "80",
            "--rows",
            "24",
            "--workspace",
            envelope_path.to_string_lossy().as_ref(),
            "--app-command",
            AppCommandId::MovePaneToNewWindow.raw_value(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("zentty-win workspace mode should start");

    child
        .stdin
        .as_mut()
        .expect("stdin should be piped")
        .write_all(b"cd\rexit\r")
        .expect("stdin should accept commands");

    let output = child
        .wait_with_output()
        .expect("zentty-win workspace mode should finish");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(left_dir.to_string_lossy().as_ref()),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !String::from_utf8_lossy(&output.stdout).contains(right_dir.to_string_lossy().as_ref()),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );

    fs::remove_dir_all(dir).ok();
}

#[test]
#[cfg(windows)]
fn zentty_win_desktop_binary_prints_usage_without_opening_window() {
    let output = Command::new(env!("CARGO_BIN_EXE_zentty-win-desktop"))
        .arg("--help")
        .output()
        .expect("zentty-win-desktop binary should run");

    assert!(
        output.status.success(),
        "status: {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("Usage: zentty-win-desktop"),
        "stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );
}

fn test_directory(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("zentty-win-{name}-{}", std::process::id()));
    fs::remove_dir_all(&dir).ok();
    fs::create_dir_all(&dir).expect("test directory should be created");
    dir
}
