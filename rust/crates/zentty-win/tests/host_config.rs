use zentty_core::commands::AppCommandId;
use zentty_win::host::{HostConfig, HostConfigError};

#[test]
fn parses_size_cwd_env_and_command_after_separator() {
    let config = HostConfig::parse([
        "--cols",
        "100",
        "--rows",
        "32",
        "--cwd",
        "C:\\Projects\\zentty",
        "--env",
        "ZENTTY_TEST=1",
        "--",
        "cmd.exe",
        "/d",
        "/s",
        "/c",
        "echo hello",
    ])
    .expect("host config should parse");

    assert_eq!(config.size.cols, 100);
    assert_eq!(config.size.rows, 32);
    assert_eq!(config.request.program(), "cmd.exe");
    assert_eq!(
        config.request.args(),
        &[
            "/d".to_string(),
            "/s".to_string(),
            "/c".to_string(),
            "echo hello".to_string()
        ]
    );
    assert_eq!(
        config.request.working_directory().map(String::as_str),
        Some("C:\\Projects\\zentty")
    );
    assert_eq!(
        config
            .request
            .environment()
            .get("ZENTTY_TEST")
            .map(String::as_str),
        Some("1")
    );
}

#[test]
fn rejects_missing_option_values_and_bad_environment_assignment() {
    assert_eq!(
        HostConfig::parse(["--cols"]).unwrap_err(),
        HostConfigError::MissingValue("--cols".to_string())
    );
    assert_eq!(
        HostConfig::parse(["--env", "NO_EQUALS"]).unwrap_err(),
        HostConfigError::InvalidEnvironmentAssignment("NO_EQUALS".to_string())
    );
}

#[test]
fn defaults_to_platform_shell_when_no_command_is_supplied() {
    let config = HostConfig::parse(["--cols", "81"]).expect("host config should parse");

    assert_eq!(config.size.cols, 81);
    assert!(!config.request.program().trim().is_empty());
}

#[test]
fn parses_workspace_envelope_path() {
    let config = HostConfig::parse([
        "--cols",
        "100",
        "--rows",
        "30",
        "--workspace",
        "C:\\Projects\\zentty\\restore.json",
    ])
    .expect("workspace host config should parse");

    assert_eq!(config.size.cols, 100);
    assert_eq!(config.size.rows, 30);
    assert_eq!(
        config.workspace_path.as_deref(),
        Some(std::path::Path::new("C:\\Projects\\zentty\\restore.json"))
    );
    assert!(!config.command_supplied);
}

#[test]
fn rejects_trailing_command_with_workspace_mode() {
    assert_eq!(
        HostConfig::parse([
            "--workspace",
            "C:\\Projects\\zentty\\restore.json",
            "--",
            "cmd.exe",
            "/c",
            "echo ignored",
        ])
        .unwrap_err(),
        HostConfigError::WorkspaceCommandConflict
    );
}

#[test]
fn parses_repeated_workspace_app_commands() {
    let config = HostConfig::parse([
        "--workspace",
        "C:\\Projects\\zentty\\restore.json",
        "--app-command",
        AppCommandId::FocusRightPane.raw_value(),
        "--app-command",
        AppCommandId::FocusLeftPane.raw_value(),
    ])
    .expect("workspace host config should parse repeated app commands");

    assert_eq!(
        config.app_command_ids,
        vec![AppCommandId::FocusRightPane, AppCommandId::FocusLeftPane]
    );
}

#[test]
fn rejects_app_commands_without_workspace_mode() {
    assert_eq!(
        HostConfig::parse(["--app-command", AppCommandId::FocusRightPane.raw_value()]).unwrap_err(),
        HostConfigError::AppCommandRequiresWorkspace(AppCommandId::FocusRightPane)
    );
}
