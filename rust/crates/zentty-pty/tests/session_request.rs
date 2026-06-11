use std::time::Duration;

use zentty_pty::{PtySessionRequest, TerminalSize, native::NativePtySession};

#[test]
fn terminal_size_clamps_to_non_zero_cells() {
    let size = TerminalSize::new(0, 0);

    assert_eq!(size.cols, 1);
    assert_eq!(size.rows, 1);
}

#[test]
fn request_rejects_empty_program_and_env_keys() {
    let request = PtySessionRequest::new("  ");
    assert!(request.validate().is_err());

    let request = PtySessionRequest::new("cmd.exe").env("", "value");
    assert!(request.validate().is_err());
}

#[test]
fn request_preserves_arguments_and_environment() {
    let request = PtySessionRequest::new("cmd.exe")
        .arg("/c")
        .arg("echo hello")
        .env("ZENTTY_TEST_MARKER", "smoke")
        .cwd("C:\\Projects");

    assert_eq!(request.program(), "cmd.exe");
    assert_eq!(
        request.args(),
        &["/c".to_string(), "echo hello".to_string()]
    );
    assert_eq!(
        request
            .environment()
            .get("ZENTTY_TEST_MARKER")
            .map(String::as_str),
        Some("smoke")
    );
    assert_eq!(
        request.working_directory().map(String::as_str),
        Some("C:\\Projects")
    );
}

#[test]
#[cfg(windows)]
fn native_windows_pty_runs_command_and_captures_output() {
    let request = PtySessionRequest::new("cmd.exe").arg("/d");
    let mut session = NativePtySession::spawn(request, TerminalSize::new(80, 24))
        .expect("ConPTY session should spawn");
    session
        .write_all(b"echo ZENTTY_CONPTY_SMOKE\rexit\r")
        .expect("ConPTY session should accept input");

    let output = session
        .wait_with_output(Duration::from_secs(5))
        .expect("ConPTY command should exit and produce output");

    assert!(output.status_success, "exit code: {:?}", output.exit_code);
    assert!(
        output.output.contains("ZENTTY_CONPTY_SMOKE"),
        "output was: {:?}",
        output.output
    );
}

#[test]
#[cfg(windows)]
fn native_windows_pty_stream_bridge_accepts_interactive_input() {
    let request = PtySessionRequest::new("cmd.exe").arg("/d");
    let session = NativePtySession::spawn(request, TerminalSize::new(80, 24))
        .expect("ConPTY session should spawn");

    let output = session
        .run_with_streams(
            std::io::Cursor::new(b"echo ZENTTY_INTERACTIVE_SMOKE\rexit\r".to_vec()),
            Vec::<u8>::new(),
            Some(Duration::from_secs(5)),
        )
        .expect("interactive stream bridge should complete");

    assert!(output.status_success, "exit code: {:?}", output.exit_code);
    assert!(
        output.output.contains("ZENTTY_INTERACTIVE_SMOKE"),
        "output was: {:?}",
        output.output
    );
}

#[test]
#[cfg(windows)]
fn native_windows_pty_terminate_stops_interactive_child() {
    let request = PtySessionRequest::new("cmd.exe").arg("/d");
    let mut session = NativePtySession::spawn(request, TerminalSize::new(80, 24))
        .expect("ConPTY session should spawn");

    session
        .terminate()
        .expect("ConPTY session should accept explicit termination");
    let output = session
        .wait_with_output(Duration::from_secs(5))
        .expect("terminated ConPTY session should become waitable");

    assert!(!output.status_success, "exit code: {:?}", output.exit_code);
}

#[test]
#[cfg(windows)]
fn native_windows_pty_stream_reports_exit_after_shell_ends() {
    let request = PtySessionRequest::new("cmd.exe").arg("/d").arg("/c").arg("exit");
    let mut stream = NativePtySession::spawn(request, TerminalSize::new(80, 24))
        .expect("ConPTY session should spawn")
        .into_output_stream()
        .expect("ConPTY session should expose an output stream");

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !stream.has_exited() && std::time::Instant::now() < deadline {
        let _ = stream.read_available();
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(
        stream.has_exited(),
        "shell process should be reported as exited after `cmd /c exit`"
    );
}
