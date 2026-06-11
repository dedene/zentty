#![cfg(windows)]

use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use zentty_core::config::{ServerBrowserCustomApp, ServerDetectionConfig};
use zentty_win::server_browser::{
    ServerBrowserDiscoveryEnvironment, resolve_available_server_browser_targets_in_environment,
    resolve_server_browser_targets_in_environment, server_browser_target_for_open_in_environment,
};

#[test]
fn server_browser_resolver_uses_configured_custom_preferred_browser() {
    let root = test_directory("server-browser-custom-preferred");
    let browser = root.join("Browsers").join("Preview.exe");
    write_fake_exe(&browser);
    let config = ServerDetectionConfig {
        preferred_browser_id: "custom:preview".to_string(),
        enabled_browser_target_ids: vec!["custom:preview".to_string()],
        custom_browsers: vec![ServerBrowserCustomApp {
            id: "custom:preview".to_string(),
            name: "Preview Browser".to_string(),
            path: browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        }],
        ..ServerDetectionConfig::default()
    };

    let target = server_browser_target_for_open_in_environment(&config, None, &empty_environment())
        .expect("preferred custom browser should resolve");

    assert_eq!(target.stable_id, "custom:preview");
    assert_eq!(target.display_name, "Preview Browser");
    assert_eq!(target.app_path, browser.to_string_lossy());

    fs::remove_dir_all(root).ok();
}

#[test]
fn server_browser_resolver_prefers_explicit_browser_argument_over_config_preference() {
    let root = test_directory("server-browser-explicit");
    let preferred = root.join("Browsers").join("Preferred.exe");
    let explicit = root.join("Browsers").join("Explicit.exe");
    write_fake_exe(&preferred);
    write_fake_exe(&explicit);
    let config = ServerDetectionConfig {
        preferred_browser_id: "custom:preferred".to_string(),
        enabled_browser_target_ids: vec![
            "custom:preferred".to_string(),
            "custom:explicit".to_string(),
        ],
        custom_browsers: vec![
            ServerBrowserCustomApp {
                id: "custom:preferred".to_string(),
                name: "Preferred Browser".to_string(),
                path: preferred.to_string_lossy().to_string(),
                bundle_identifier: None,
            },
            ServerBrowserCustomApp {
                id: "custom:explicit".to_string(),
                name: "Explicit Browser".to_string(),
                path: explicit.to_string_lossy().to_string(),
                bundle_identifier: None,
            },
        ],
        ..ServerDetectionConfig::default()
    };

    let target = server_browser_target_for_open_in_environment(
        &config,
        Some("custom:explicit"),
        &empty_environment(),
    )
    .expect("explicit custom browser should resolve");

    assert_eq!(target.stable_id, "custom:explicit");
    assert_eq!(target.display_name, "Explicit Browser");
    assert_eq!(target.app_path, explicit.to_string_lossy());

    fs::remove_dir_all(root).ok();
}

#[test]
fn server_browser_resolver_maps_bundle_alias_to_windows_builtin_browser() {
    let root = test_directory("server-browser-bundle-alias");
    let program_files = root.join("Program Files");
    let chrome = program_files
        .join("Google")
        .join("Chrome")
        .join("Application")
        .join("chrome.exe");
    write_fake_exe(&chrome);
    let config = ServerDetectionConfig {
        enabled_browser_target_ids: vec!["chrome".to_string()],
        ..ServerDetectionConfig::default()
    };
    let environment = ServerBrowserDiscoveryEnvironment {
        local_app_data: None,
        program_files: vec![program_files],
        path_entries: Vec::new(),
    };

    let targets = resolve_server_browser_targets_in_environment(&config, &environment);
    assert_eq!(targets.len(), 1);
    let target = server_browser_target_for_open_in_environment(
        &config,
        Some("bundle:com.google.Chrome"),
        &environment,
    )
    .expect("chrome bundle alias should resolve to chrome");

    assert_eq!(target.stable_id, "chrome");
    assert_eq!(target.app_path, chrome.to_string_lossy());

    fs::remove_dir_all(root).ok();
}

#[test]
fn server_browser_available_resolver_keeps_disabled_readable_targets_visible() {
    let root = test_directory("server-browser-available-disabled");
    let browser = root.join("Browsers").join("Preview.exe");
    write_fake_exe(&browser);
    let config = ServerDetectionConfig {
        preferred_browser_id: "system-default".to_string(),
        enabled_browser_target_ids: Vec::new(),
        custom_browsers: vec![ServerBrowserCustomApp {
            id: "custom:preview".to_string(),
            name: "Preview Browser".to_string(),
            path: browser.to_string_lossy().to_string(),
            bundle_identifier: None,
        }],
        ..ServerDetectionConfig::default()
    };
    let disabled_config = ServerDetectionConfig {
        enabled_browser_target_ids: vec!["chrome".to_string()],
        ..config.clone()
    };

    let enabled_targets =
        resolve_server_browser_targets_in_environment(&disabled_config, &empty_environment());
    assert!(enabled_targets.is_empty());

    let available_targets = resolve_available_server_browser_targets_in_environment(
        &disabled_config,
        &empty_environment(),
    );
    assert_eq!(
        available_targets
            .iter()
            .map(|target| target.stable_id.as_str())
            .collect::<Vec<_>>(),
        vec!["custom:preview"]
    );

    fs::remove_dir_all(root).ok();
}

fn empty_environment() -> ServerBrowserDiscoveryEnvironment {
    ServerBrowserDiscoveryEnvironment {
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
