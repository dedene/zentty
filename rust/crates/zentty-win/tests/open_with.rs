#![cfg(windows)]

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use zentty_core::command_palette::{OpenWithBuiltInTargetId, OpenWithTargetKind};
use zentty_core::config::{OpenWithConfig, OpenWithCustomApp};
use zentty_win::open_with::{
    OpenWithDiscoveryEnvironment, resolve_available_open_with_targets_in_environment,
    resolve_open_with_targets_in_environment,
};

#[test]
fn open_with_resolver_makes_file_explorer_available_for_default_finder_target() {
    let targets =
        resolve_open_with_targets_in_environment(&OpenWithConfig::default(), &empty_environment());

    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].stable_id, "finder");
    assert_eq!(targets[0].display_name, "File Explorer");
    assert_eq!(targets[0].kind, OpenWithTargetKind::FileManager);
    assert_eq!(
        targets[0].built_in_id,
        Some(OpenWithBuiltInTargetId::Finder)
    );
    assert_eq!(targets[0].app_path, None);
}

#[test]
fn open_with_resolver_detects_windows_vscode_install_locations() {
    let root = test_directory("open-with-vscode");
    let local_app_data = root.join("LocalAppData");
    let code = local_app_data
        .join("Programs")
        .join("Microsoft VS Code")
        .join("Code.exe");
    write_fake_exe(&code);

    let environment = OpenWithDiscoveryEnvironment {
        local_app_data: Some(local_app_data),
        program_files: Vec::new(),
        path_entries: Vec::new(),
    };
    let targets =
        resolve_open_with_targets_in_environment(&OpenWithConfig::default(), &environment);

    assert_eq!(
        targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["finder", "vscode"]
    );
    assert_eq!(
        targets
            .iter()
            .find(|target| target.stable_id == "vscode")
            .and_then(|target| target.app_path.as_deref()),
        Some(code.to_string_lossy().as_ref())
    );

    fs::remove_dir_all(root).ok();
}

#[test]
fn open_with_resolver_promotes_configured_custom_primary_target() {
    let root = test_directory("open-with-custom-primary");
    let custom_editor = root.join("Editors").join("CustomEditor.exe");
    write_fake_exe(&custom_editor);
    let config = OpenWithConfig {
        primary_target_id: "custom:editor".to_string(),
        enabled_target_ids: vec![
            "finder".to_string(),
            "custom:editor".to_string(),
            "cursor".to_string(),
        ],
        custom_apps: vec![OpenWithCustomApp {
            id: "custom:editor".to_string(),
            name: "Custom Editor".to_string(),
            path: custom_editor.to_string_lossy().to_string(),
        }],
    };

    let targets = resolve_open_with_targets_in_environment(&config, &empty_environment());

    assert_eq!(
        targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["custom:editor", "finder"]
    );
    assert_eq!(targets[0].display_name, "Custom Editor");
    assert_eq!(
        targets[0].app_path.as_deref(),
        Some(config.custom_apps[0].path.as_str())
    );

    fs::remove_dir_all(root).ok();
}

#[test]
fn open_with_available_resolver_keeps_disabled_readable_targets_visible() {
    let root = test_directory("open-with-available-disabled");
    let custom_editor = root.join("Editors").join("CustomEditor.exe");
    write_fake_exe(&custom_editor);
    let config = OpenWithConfig {
        primary_target_id: "finder".to_string(),
        enabled_target_ids: vec!["finder".to_string()],
        custom_apps: vec![OpenWithCustomApp {
            id: "custom:editor".to_string(),
            name: "Custom Editor".to_string(),
            path: custom_editor.to_string_lossy().to_string(),
        }],
    };

    let enabled_targets = resolve_open_with_targets_in_environment(&config, &empty_environment());
    assert_eq!(
        enabled_targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["finder"]
    );

    let available_targets =
        resolve_available_open_with_targets_in_environment(&config, &empty_environment());
    assert_eq!(
        available_targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["finder", "custom:editor"]
    );

    fs::remove_dir_all(root).ok();
}

fn empty_environment() -> OpenWithDiscoveryEnvironment {
    OpenWithDiscoveryEnvironment {
        local_app_data: None,
        program_files: Vec::new(),
        path_entries: Vec::new(),
    }
}

fn write_fake_exe(path: &PathBuf) {
    fs::create_dir_all(path.parent().expect("fake exe should have parent"))
        .expect("fake exe parent should be created");
    fs::write(path, "fake exe").expect("fake exe should be written");
}

fn test_directory(name: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("time should be monotonic")
        .as_nanos();
    let path = std::env::temp_dir().join(format!("zentty-{name}-{suffix}"));
    fs::create_dir_all(&path).expect("test directory should be created");
    path
}
