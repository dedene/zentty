use std::collections::BTreeMap;
use std::io::Cursor;

use zentty_core::agent::{
    AgentIpcRequest, AgentIpcRequestKind, AgentIpcResponse, AgentIpcResponseResult,
};
use zentty_win::ipc::{
    AGENT_IPC_MAX_REQUEST_BYTES, read_agent_ipc_request, read_agent_ipc_request_data,
    write_agent_ipc_response,
};

#[test]
fn agent_ipc_reader_stops_at_newline_and_decodes_request() {
    let request = transport_request("request-1", true);
    let mut payload = serde_json::to_vec(&request).expect("request should encode");
    payload.extend_from_slice(b"\nignored");
    let mut cursor = Cursor::new(payload);

    assert_eq!(
        read_agent_ipc_request(&mut cursor).expect("request should decode"),
        request
    );
}

#[test]
fn agent_ipc_reader_accepts_eof_terminated_request() {
    let request = transport_request("request-2", false);
    let payload = serde_json::to_vec(&request).expect("request should encode");
    let mut cursor = Cursor::new(payload.clone());

    assert_eq!(
        read_agent_ipc_request_data(&mut cursor).expect("request data should read"),
        payload
    );
}

#[test]
fn agent_ipc_reader_rejects_oversized_request_before_newline() {
    let payload = vec![b'a'; AGENT_IPC_MAX_REQUEST_BYTES + 1];
    let mut cursor = Cursor::new(payload);

    assert!(read_agent_ipc_request_data(&mut cursor).is_err());
}

#[test]
fn agent_ipc_response_writer_appends_newline() {
    let response = AgentIpcResponse {
        version: 1,
        id: "response-1".to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    };
    let mut buffer = Vec::new();

    write_agent_ipc_response(&mut buffer, &response).expect("response should write");

    assert!(buffer.ends_with(b"\n"));
    assert_eq!(
        serde_json::from_slice::<AgentIpcResponse>(&buffer[..buffer.len() - 1])
            .expect("response should decode"),
        response
    );
}

#[test]
#[cfg(windows)]
fn agent_ipc_named_pipe_serves_one_request_and_response() {
    use std::io::{BufRead, BufReader, Write};
    use std::thread;

    use zentty_win::ipc::serve_agent_ipc_named_pipe_once;

    let pipe_path = format!(r"\\.\pipe\zentty-ipc-transport-{}", std::process::id());
    let server_path = pipe_path.clone();
    let server = thread::spawn(move || {
        serve_agent_ipc_named_pipe_once(&server_path, |request| {
            assert_eq!(request.id, "pipe-request");
            Some(AgentIpcResponse {
                version: 1,
                id: request.id,
                ok: true,
                result: Some(AgentIpcResponseResult::default()),
                error: None,
            })
        })
        .expect("named pipe server should handle one request");
    });

    let mut client = open_pipe_client_with_retry(&pipe_path, std::time::Duration::from_secs(2));
    serde_json::to_writer(&mut client, &transport_request("pipe-request", true))
        .expect("request should write");
    client.write_all(b"\n").expect("newline should write");
    client.flush().expect("request should flush");

    let mut reader = BufReader::new(client);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .expect("response line should read");
    let response: AgentIpcResponse =
        serde_json::from_str(line.trim_end()).expect("response should decode");
    assert_eq!(response.id, "pipe-request");
    assert!(response.ok);

    server.join().expect("server thread should finish");
}

#[test]
#[cfg(windows)]
fn agent_ipc_named_pipe_listener_dispatches_requests_and_responses() {
    use std::io::{BufRead, BufReader, Write};
    use std::time::Duration;

    use zentty_win::ipc::AgentIpcNamedPipeListener;

    let pipe_path = format!(r"\\.\pipe\zentty-ipc-listener-{}", std::process::id());
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");

    let mut client = open_pipe_client_with_retry(&pipe_path, Duration::from_secs(2));
    serde_json::to_writer(&mut client, &transport_request("listener-request", true))
        .expect("request should write");
    client.write_all(b"\n").expect("newline should write");
    client.flush().expect("request should flush");

    let pending = listener
        .recv_timeout(Duration::from_secs(2))
        .expect("listener should dispatch request");
    assert_eq!(pending.request.id, "listener-request");
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: "listener-request".to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let mut reader = BufReader::new(client);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .expect("response line should read");
    let response: AgentIpcResponse =
        serde_json::from_str(line.trim_end()).expect("response should decode");
    assert_eq!(response.id, "listener-request");
    assert!(response.ok);
}

#[test]
#[cfg(windows)]
fn agent_ipc_client_sends_request_and_reads_listener_response() {
    use std::thread;
    use std::time::Duration;

    use zentty_win::ipc::{AgentIpcNamedPipeListener, send_agent_ipc_request};

    let pipe_path = format!(r"\\.\pipe\zentty-ipc-client-{}", std::process::id());
    let listener = AgentIpcNamedPipeListener::start(pipe_path.clone())
        .expect("named pipe listener should start");
    let client_path = pipe_path.clone();
    let client = thread::spawn(move || {
        send_agent_ipc_request(&client_path, &transport_request("client-request", true))
            .expect("client should receive response")
            .expect("response should be present")
    });

    let pending = listener
        .recv_timeout(Duration::from_secs(2))
        .expect("listener should dispatch request");
    assert_eq!(pending.request.id, "client-request");
    pending.respond(Some(AgentIpcResponse {
        version: 1,
        id: "client-request".to_string(),
        ok: true,
        result: Some(AgentIpcResponseResult::default()),
        error: None,
    }));

    let response = client.join().expect("client thread should finish");
    assert_eq!(response.id, "client-request");
    assert!(response.ok);
}

fn transport_request(id: &str, expects_response: bool) -> AgentIpcRequest {
    AgentIpcRequest {
        version: 1,
        id: id.to_string(),
        kind: AgentIpcRequestKind::Ipc,
        arguments: vec!["agent-signal".to_string(), "shell-state".to_string()],
        standard_input: None,
        environment: BTreeMap::new(),
        expects_response,
        subcommand: Some("agent-signal".to_string()),
        tool: None,
    }
}

#[cfg(windows)]
fn open_pipe_client_with_retry(path: &str, timeout: std::time::Duration) -> std::fs::File {
    use std::fs::OpenOptions;
    use std::thread;
    use std::time::Instant;

    let deadline = Instant::now() + timeout;
    loop {
        match OpenOptions::new().read(true).write(true).open(path) {
            Ok(file) => return file,
            Err(error) if Instant::now() < deadline => {
                let _ = error;
                thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(error) => panic!("pipe client should connect: {error}"),
        }
    }
}
