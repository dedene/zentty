use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use zentty_core::agent::{AgentBootstrapTool, AgentIntegrationState};
use zentty_core::config::{
    AgentIntegrationsConfig, AgentIntegrationsToml, AppConfig, AppConfigStore, AppConfigToml,
    AppUpdateChannel, AppearanceThemeMode, FocusFollowsMouseDelay, NewWorklanePlacement,
    OpenWithCustomApp, PaneLayoutPreset, PaneSplitBehaviorMode, ServerBrowserCustomApp,
    ShortcutBindingOverride, SidebarVisibility,
};

#[test]
fn agent_integrations_toml_round_trip_preserves_states_and_flag() {
    let mut config = AgentIntegrationsConfig {
        states: BTreeMap::new(),
        grandfathered_v1: true,
    };
    config
        .states
        .insert("agy".to_string(), AgentIntegrationState::On);
    config
        .states
        .insert("grok".to_string(), AgentIntegrationState::Off);
    config
        .states
        .insert("claude".to_string(), AgentIntegrationState::Off);

    let encoded = AgentIntegrationsToml::encode(&config);
    let decoded = AgentIntegrationsToml::decode(&encoded).expect("config should decode");

    assert!(decoded.grandfathered_v1);
    assert_eq!(decoded.states.get("agy"), Some(&AgentIntegrationState::On));
    assert_eq!(
        decoded.states.get("grok"),
        Some(&AgentIntegrationState::Off)
    );
    assert_eq!(
        decoded.states.get("claude"),
        Some(&AgentIntegrationState::Off)
    );
}

#[test]
fn defaults_round_trip_to_empty_states_and_class_defaults() {
    let decoded = AgentIntegrationsToml::decode(&AgentIntegrationsToml::encode(
        &AgentIntegrationsConfig::default(),
    ))
    .expect("default config should decode");

    assert!(!decoded.grandfathered_v1);
    assert!(decoded.states.is_empty());
    assert_eq!(
        decoded.state(AgentBootstrapTool::Agy),
        AgentIntegrationState::Ask
    );
    assert_eq!(
        decoded.state(AgentBootstrapTool::Claude),
        AgentIntegrationState::On
    );
}

#[test]
fn encode_sorts_states_deterministically() {
    let mut config = AgentIntegrationsConfig::default();
    config
        .states
        .insert("grok".to_string(), AgentIntegrationState::Off);
    config
        .states
        .insert("agy".to_string(), AgentIntegrationState::On);
    config
        .states
        .insert("cursor".to_string(), AgentIntegrationState::On);

    let encoded = AgentIntegrationsToml::encode(&config);
    let agy = encoded.find("agy = ").expect("agy state should be encoded");
    let cursor = encoded
        .find("cursor = ")
        .expect("cursor state should be encoded");
    let grok = encoded
        .find("grok = ")
        .expect("grok state should be encoded");

    assert!(agy < cursor);
    assert!(cursor < grok);
}

#[test]
fn unknown_state_value_is_skipped_not_fatal() {
    let source = r#"
[agent_integrations]
grandfathered_v1 = true

[agent_integrations.states]
agy = "on"
future = "paused"
"#;

    let decoded = AgentIntegrationsToml::decode(source).expect("config should decode");

    assert_eq!(decoded.states.get("agy"), Some(&AgentIntegrationState::On));
    assert_eq!(decoded.states.get("future"), None);
    assert!(decoded.grandfathered_v1);
}

#[test]
fn unknown_agent_key_with_valid_state_is_preserved() {
    let source = r#"
[agent_integrations.states]
someNewAgent = "on"
"#;

    let decoded = AgentIntegrationsToml::decode(source).expect("config should decode");

    assert_eq!(
        decoded.states.get("someNewAgent"),
        Some(&AgentIntegrationState::On)
    );
}

#[test]
fn app_config_defaults_match_swift_behavior() {
    let config = AppConfig::default();

    assert_eq!(config.sidebar.width, 280.0);
    assert_eq!(config.sidebar.visibility, SidebarVisibility::PinnedOpen);
    assert_eq!(config.pane_layout.laptop, PaneLayoutPreset::Compact);
    assert_eq!(config.pane_layout.large_display, PaneLayoutPreset::Balanced);
    assert_eq!(config.pane_layout.ultrawide, PaneLayoutPreset::Balanced);
    assert_eq!(
        config.pane_layout.right_split_behavior,
        PaneSplitBehaviorMode::Adaptive
    );
    assert_eq!(config.pane_layout.visible_split_window_width, 1920);
    assert!(config.panes.show_labels);
    assert_eq!(config.panes.inactive_opacity, 0.7);
    assert!(config.panes.show_project_icons);
    assert!(!config.panes.smooth_scrolling_enabled);
    assert!(!config.panes.focus_follows_mouse);
    assert_eq!(
        config.panes.focus_follows_mouse_delay,
        FocusFollowsMouseDelay::Short
    );
    assert_eq!(
        config.appearance.theme_mode,
        AppearanceThemeMode::AlwaysDark
    );
    assert!(config.appearance.sync_opencode_theme_with_terminal);
    assert_eq!(config.open_with.primary_target_id, "finder");
    assert_eq!(
        config.open_with.enabled_target_ids,
        vec![
            "finder".to_string(),
            "vscode".to_string(),
            "cursor".to_string(),
            "xcode".to_string()
        ]
    );
    assert!(config.open_with.custom_apps.is_empty());
    assert!(config.confirmations.confirm_before_closing_pane);
    assert!(config.confirmations.confirm_before_closing_window);
    assert!(config.confirmations.confirm_before_quitting);
    assert!(config.error_reporting.enabled);
    assert_eq!(config.updates.channel, AppUpdateChannel::Stable);
    assert_eq!(config.notifications.sound_name, "");
    assert_eq!(config.notifications.custom_sound_display_name, None);
    assert!(!config.clipboard.always_clean_copies);
    assert_eq!(
        config.worklanes.new_worklane_placement,
        NewWorklanePlacement::AfterCurrent
    );
    assert!(config.restore.restore_workspace_on_launch);
    assert!(config.server_detection.passive_detection_enabled);
    assert_eq!(
        config.server_detection.preferred_browser_id,
        "system-default"
    );
    assert!(
        config
            .server_detection
            .enabled_browser_target_ids
            .is_empty()
    );
    assert!(config.server_detection.custom_browsers.is_empty());
    assert!(config.server_detection.ignored_port_rules.is_empty());
    assert!(config.shortcuts.bindings.is_empty());
    assert!(!config.agent_teams.enabled);
    assert!(config.agent_caffeination.enabled);
    assert!(config.menu_bar.show_status_item);
}

#[test]
fn app_config_toml_rejects_unknown_sidebar_visibility() {
    let source = r#"
[sidebar]
width = 280.0
visibility = "floating"
"#;

    assert_eq!(AppConfigToml::decode(source), None);
}

#[test]
fn app_config_toml_round_trip_core_sections_and_agent_integrations() {
    let mut config = AppConfig::default();
    config.panes.show_labels = false;
    config.panes.inactive_opacity = 0.85;
    config.panes.smooth_scrolling_enabled = true;
    config.panes.focus_follows_mouse = true;
    config.panes.focus_follows_mouse_delay = FocusFollowsMouseDelay::Immediate;
    config.pane_layout.laptop = PaneLayoutPreset::Roomy;
    config.pane_layout.large_display = PaneLayoutPreset::Compact;
    config.pane_layout.ultrawide = PaneLayoutPreset::Roomy;
    config.pane_layout.right_split_behavior = PaneSplitBehaviorMode::AlwaysAdd;
    config.pane_layout.visible_split_window_width = 1680;
    config.appearance.theme_mode = AppearanceThemeMode::FollowMacOS;
    config.appearance.preferred_dark_theme_name = Some("TokyoNight".to_string());
    config.appearance.preferred_light_theme_name = Some("GitHub Light Default".to_string());
    config.appearance.local_background_opacity = Some(0.87);
    config.appearance.sync_opencode_theme_with_terminal = false;
    config.open_with.primary_target_id = "custom:bbedit".to_string();
    config.open_with.enabled_target_ids = vec![
        "custom:bbedit".to_string(),
        "finder".to_string(),
        "cursor".to_string(),
    ];
    config.open_with.custom_apps = vec![OpenWithCustomApp {
        id: "custom:bbedit".to_string(),
        name: "BBEdit Custom".to_string(),
        path: r"C:\Program Files\BBEdit\BBEdit.exe".to_string(),
    }];
    config.confirmations.confirm_before_closing_pane = false;
    config.clipboard.always_clean_copies = true;
    config.worklanes.new_worklane_placement = NewWorklanePlacement::Top;
    config.restore.restore_workspace_on_launch = false;
    config.server_detection.passive_detection_enabled = false;
    config.server_detection.preferred_browser_id = "custom:sizzy".to_string();
    config.server_detection.enabled_browser_target_ids =
        vec!["chrome".to_string(), "custom:sizzy".to_string()];
    config.server_detection.custom_browsers = vec![ServerBrowserCustomApp {
        id: "custom:sizzy".to_string(),
        name: "Sizzy".to_string(),
        path: r"C:\Program Files\Sizzy\Sizzy.exe".to_string(),
        bundle_identifier: Some("com.sizzy.browser".to_string()),
    }];
    config.server_detection.ignored_port_rules =
        vec!["9229".to_string(), "24678-24680".to_string()];
    config.error_reporting.enabled = false;
    config.updates.channel = AppUpdateChannel::Beta;
    config.notifications.sound_name = "zentty-custom-sample.caf".to_string();
    config.notifications.custom_sound_display_name = Some("My Personal Chime.mp3".to_string());
    config.shortcuts.bindings = vec![
        ShortcutBindingOverride {
            command_id: "sidebar.toggle".to_string(),
            shortcut: Some("command+b".to_string()),
        },
        ShortcutBindingOverride {
            command_id: "pane.copy_path".to_string(),
            shortcut: None,
        },
    ];
    config.agent_caffeination.enabled = false;
    config.menu_bar.show_status_item = false;
    config
        .agent_integrations
        .states
        .insert("agy".to_string(), AgentIntegrationState::On);
    config
        .agent_integrations
        .states
        .insert("grok".to_string(), AgentIntegrationState::Off);

    let encoded = AppConfigToml::encode(&config);
    let decoded = AppConfigToml::decode(&encoded).expect("app config should decode");

    assert!(encoded.contains("[pane_layout]"));
    assert!(encoded.contains("laptop = \"roomy\""));
    assert!(encoded.contains("large_display = \"compact\""));
    assert!(encoded.contains("right_split_behavior = \"alwaysAdd\""));
    assert!(encoded.contains("visible_split_window_width = 1680"));
    assert!(!decoded.panes.show_labels);
    assert_eq!(decoded.panes.inactive_opacity, 0.85);
    assert!(decoded.panes.smooth_scrolling_enabled);
    assert!(decoded.panes.focus_follows_mouse);
    assert_eq!(
        decoded.panes.focus_follows_mouse_delay,
        FocusFollowsMouseDelay::Immediate
    );
    assert_eq!(decoded.pane_layout.laptop, PaneLayoutPreset::Roomy);
    assert_eq!(decoded.pane_layout.large_display, PaneLayoutPreset::Compact);
    assert_eq!(decoded.pane_layout.ultrawide, PaneLayoutPreset::Roomy);
    assert_eq!(
        decoded.pane_layout.right_split_behavior,
        PaneSplitBehaviorMode::AlwaysAdd
    );
    assert_eq!(decoded.pane_layout.visible_split_window_width, 1680);
    assert_eq!(
        decoded.appearance.theme_mode,
        AppearanceThemeMode::FollowMacOS
    );
    assert_eq!(
        decoded.appearance.preferred_dark_theme_name.as_deref(),
        Some("TokyoNight")
    );
    assert_eq!(
        decoded.appearance.preferred_light_theme_name.as_deref(),
        Some("GitHub Light Default")
    );
    assert_eq!(decoded.appearance.local_background_opacity, Some(0.87));
    assert!(!decoded.appearance.sync_opencode_theme_with_terminal);
    assert_eq!(decoded.open_with.primary_target_id, "custom:bbedit");
    assert_eq!(
        decoded.open_with.enabled_target_ids,
        vec![
            "custom:bbedit".to_string(),
            "finder".to_string(),
            "cursor".to_string()
        ]
    );
    assert_eq!(
        decoded.open_with.custom_apps,
        vec![OpenWithCustomApp {
            id: "custom:bbedit".to_string(),
            name: "BBEdit Custom".to_string(),
            path: r"C:\Program Files\BBEdit\BBEdit.exe".to_string(),
        }]
    );
    assert!(!decoded.confirmations.confirm_before_closing_pane);
    assert!(decoded.clipboard.always_clean_copies);
    assert_eq!(
        decoded.worklanes.new_worklane_placement,
        NewWorklanePlacement::Top
    );
    assert!(!decoded.restore.restore_workspace_on_launch);
    assert!(!decoded.server_detection.passive_detection_enabled);
    assert_eq!(
        decoded.server_detection.preferred_browser_id,
        "custom:sizzy"
    );
    assert_eq!(
        decoded.server_detection.enabled_browser_target_ids,
        vec!["chrome".to_string(), "custom:sizzy".to_string()]
    );
    assert_eq!(decoded.server_detection.custom_browsers.len(), 1);
    assert_eq!(
        decoded.server_detection.custom_browsers[0],
        ServerBrowserCustomApp {
            id: "custom:sizzy".to_string(),
            name: "Sizzy".to_string(),
            path: r"C:\Program Files\Sizzy\Sizzy.exe".to_string(),
            bundle_identifier: Some("com.sizzy.browser".to_string()),
        }
    );
    assert_eq!(
        decoded.server_detection.ignored_port_rules,
        vec!["9229".to_string(), "24678-24680".to_string()]
    );
    assert!(encoded.contains("[error_reporting]"));
    assert!(encoded.contains("enabled = false"));
    assert!(encoded.contains("[updates]"));
    assert!(encoded.contains("channel = \"beta\""));
    assert!(encoded.contains("[notifications]"));
    assert!(encoded.contains("sound_name = \"zentty-custom-sample.caf\""));
    assert!(encoded.contains("custom_sound_display_name = \"My Personal Chime.mp3\""));
    assert!(!decoded.error_reporting.enabled);
    assert_eq!(decoded.updates.channel, AppUpdateChannel::Beta);
    assert_eq!(decoded.notifications.sound_name, "zentty-custom-sample.caf");
    assert_eq!(
        decoded.notifications.custom_sound_display_name.as_deref(),
        Some("My Personal Chime.mp3")
    );
    assert!(encoded.contains("[[shortcuts.bindings]]"));
    assert!(encoded.contains("command_id = \"sidebar.toggle\""));
    assert!(encoded.contains("shortcut = \"command+b\""));
    assert!(encoded.contains("shortcut = \"\""));
    assert_eq!(
        decoded.shortcuts.bindings,
        vec![
            ShortcutBindingOverride {
                command_id: "sidebar.toggle".to_string(),
                shortcut: Some("command+b".to_string()),
            },
            ShortcutBindingOverride {
                command_id: "pane.copy_path".to_string(),
                shortcut: None,
            }
        ]
    );
    assert!(!decoded.agent_caffeination.enabled);
    assert!(!decoded.menu_bar.show_status_item);
    assert_eq!(
        decoded.agent_integrations.states.get("agy"),
        Some(&AgentIntegrationState::On)
    );
    assert_eq!(
        decoded.agent_integrations.states.get("grok"),
        Some(&AgentIntegrationState::Off)
    );
}

#[test]
fn app_config_decode_uses_defaults_and_normalizes_panes_like_swift() {
    let source = r#"
[pane_layout]
laptop = "roomy"
large_display = "compact"
ultrawide = "balanced"
right_split_behavior = "alwaysSplit"
visible_split_window_width = 999

[panes]
show_labels = false
inactive_opacity = 0.2
show_project_icons = false
smooth_scroll_enabled = true
focus_follows_mouse = true
focus_follows_mouse_delay = "immediate"

[worklanes]
new_worklane_placement = "end"

[restore]
restore_workspace_on_launch = false

[error_reporting]
enabled = false

[updates]
channel = "beta"

[notifications]
sound_name = "Glass"
custom_sound_display_name = "Stale Custom.mp3"

[agent_caffeination]
enabled = false

[menu_bar]
show_status_item = false
"#;

    let config = AppConfigToml::decode(source).expect("partial config should decode");

    assert_eq!(config.pane_layout.laptop, PaneLayoutPreset::Roomy);
    assert_eq!(config.pane_layout.large_display, PaneLayoutPreset::Compact);
    assert_eq!(config.pane_layout.ultrawide, PaneLayoutPreset::Balanced);
    assert_eq!(
        config.pane_layout.right_split_behavior,
        PaneSplitBehaviorMode::AlwaysSplit
    );
    assert_eq!(config.pane_layout.visible_split_window_width, 1920);
    assert!(!config.panes.show_labels);
    assert_eq!(config.panes.inactive_opacity, 0.6);
    assert!(!config.panes.show_project_icons);
    assert!(config.panes.smooth_scrolling_enabled);
    assert!(config.panes.focus_follows_mouse);
    assert_eq!(
        config.panes.focus_follows_mouse_delay,
        FocusFollowsMouseDelay::Immediate
    );
    assert_eq!(
        config.worklanes.new_worklane_placement,
        NewWorklanePlacement::End
    );
    assert!(!config.restore.restore_workspace_on_launch);
    assert!(!config.error_reporting.enabled);
    assert_eq!(config.updates.channel, AppUpdateChannel::Beta);
    assert_eq!(config.notifications.sound_name, "Glass");
    assert_eq!(config.notifications.custom_sound_display_name, None);
    assert!(!config.agent_caffeination.enabled);
    assert!(!config.menu_bar.show_status_item);
    assert!(config.confirmations.confirm_before_closing_pane);
}

#[test]
fn app_config_toml_omits_default_appearance_section_like_swift() {
    let encoded = AppConfigToml::encode(&AppConfig::default());

    assert!(!encoded.contains("[appearance]"));
    assert!(!encoded.contains("theme_mode"));
    assert!(!encoded.contains("preferred_dark_theme_name"));
    assert!(encoded.contains("[menu_bar]"));
    assert!(encoded.contains("show_status_item = true"));
}

#[test]
fn app_config_store_loads_existing_file_with_defaults_and_normalization() {
    let path = temp_config_path("load-existing");
    fs::write(
        &path,
        r#"
[panes]
inactive_opacity = 2.5

[restore]
restore_workspace_on_launch = false
"#,
    )
    .expect("config fixture should write");

    let store = AppConfigStore::load(path.clone()).expect("config store should load");

    assert_eq!(store.path(), path.as_path());
    assert!(store.did_load_from_valid_file());
    assert_eq!(store.current().panes.inactive_opacity, 1.0);
    assert!(store.current().panes.show_labels);
    assert!(!store.current().restore.restore_workspace_on_launch);
    assert!(store.current().menu_bar.show_status_item);

    fs::remove_file(path).ok();
}

#[test]
fn app_config_store_materializes_missing_file_with_normalized_defaults_like_swift() {
    let path = temp_config_path("missing-materializes");
    fs::remove_file(&path).ok();

    let store = AppConfigStore::load(path.clone()).expect("missing config should load");

    assert_eq!(store.path(), path.as_path());
    assert!(store.did_load_from_valid_file());
    assert_eq!(store.current(), &AppConfig::default().normalized());
    assert_eq!(
        store.current().server_detection.enabled_browser_target_ids,
        expected_server_browser_target_ids()
    );
    let persisted = fs::read_to_string(&path).expect("missing config should be materialized");
    assert!(persisted.contains("[open_with]"));
    assert!(
        persisted.contains("enabled_target_ids = [\"finder\", \"vscode\", \"cursor\", \"xcode\"]")
    );
    assert!(persisted.contains("[server_detection]"));
    assert!(persisted.contains("enabled_browser_target_ids"));
    assert!(persisted.contains("\"chrome\""));

    fs::remove_file(path).ok();
}

#[test]
fn app_config_store_ignores_invalid_file_without_overwriting_like_swift() {
    let path = temp_config_path("invalid-fallback");
    let invalid_source = "[panes]\ninactive_opacity = \"not-a-number\"\n";
    fs::write(&path, invalid_source).expect("invalid config fixture should write");

    let store = AppConfigStore::load(path.clone()).expect("invalid config should not fail load");

    assert_eq!(store.path(), path.as_path());
    assert_eq!(store.current(), &AppConfig::default().normalized());
    assert!(!store.did_load_from_valid_file());
    assert_eq!(
        fs::read_to_string(&path).expect("invalid config should remain on disk"),
        invalid_source
    );

    fs::remove_file(path).ok();
}

#[test]
fn app_config_decode_normalizes_server_detection_ignored_port_rules_like_swift() {
    let source = r#"
[server_detection]
passive_detection_enabled = true
ignored_port_rules = ["3001", "abc", "70000", "3000", "5000-4000"]
"#;

    let config = AppConfigToml::decode(source).expect("server detection config should decode");

    assert_eq!(
        config.server_detection.ignored_port_rules,
        vec!["3000-3001".to_string()]
    );
}

#[test]
fn app_config_decode_expands_empty_server_browser_enabled_ids_like_swift() {
    let source = r#"
[server_detection]
passive_detection_enabled = true
preferred_browser_id = "system-default"
"#;

    let config = AppConfigToml::decode(source).expect("server detection config should decode");

    assert_eq!(
        config.server_detection.enabled_browser_target_ids,
        expected_server_browser_target_ids()
    );
    assert_eq!(
        config.server_detection.preferred_browser_id,
        "system-default"
    );
}

#[test]
fn app_config_decode_normalizes_duplicate_server_custom_browsers_like_swift() {
    let source = r#"
[server_detection]
passive_detection_enabled = false
preferred_browser_id = "custom:duplicate"
enabled_browser_target_ids = ["custom:duplicate", "custom:valid", "missing"]

[[server_detection.custom_browsers]]
id = "custom:valid"
name = "Valid Browser"
path = "C:\\Browsers\\ValidBrowser.exe"
bundle_identifier = "com.example.ValidBrowser"
priority = 10

[[server_detection.custom_browsers]]
id = "custom:duplicate"
name = "Duplicate Browser"
path = "C:\\Browsers\\ValidBrowser.exe"
supports_profiles = true
"#;

    let config = AppConfigToml::decode(source).expect("server detection config should decode");

    assert!(!config.server_detection.passive_detection_enabled);
    assert_eq!(
        config.server_detection.custom_browsers,
        vec![ServerBrowserCustomApp {
            id: "custom:valid".to_string(),
            name: "Valid Browser".to_string(),
            path: r"C:\Browsers\ValidBrowser.exe".to_string(),
            bundle_identifier: Some("com.example.ValidBrowser".to_string()),
        }]
    );
    assert_eq!(
        config.server_detection.enabled_browser_target_ids,
        vec!["custom:valid".to_string()]
    );
    assert_eq!(config.server_detection.preferred_browser_id, "custom:valid");
}

#[test]
fn app_config_decode_normalizes_server_browser_preferred_bundle_like_swift() {
    let disabled_source = r#"
[server_detection]
preferred_browser_id = "bundle:com.google.Chrome"
enabled_browser_target_ids = ["firefox"]
"#;

    let disabled =
        AppConfigToml::decode(disabled_source).expect("server detection config should decode");
    assert_eq!(
        disabled.server_detection.preferred_browser_id,
        "system-default"
    );
    assert_eq!(
        disabled.server_detection.enabled_browser_target_ids,
        vec!["firefox".to_string()]
    );

    let enabled_source = r#"
[server_detection]
preferred_browser_id = "bundle:com.google.Chrome"
enabled_browser_target_ids = ["chrome"]
"#;

    let enabled =
        AppConfigToml::decode(enabled_source).expect("server detection config should decode");
    assert_eq!(
        enabled.server_detection.preferred_browser_id,
        "bundle:com.google.Chrome"
    );
    assert_eq!(
        enabled.server_detection.enabled_browser_target_ids,
        vec!["chrome".to_string()]
    );
}

#[test]
fn app_config_decode_normalizes_open_with_custom_apps_like_swift() {
    let source = r#"
[open_with]
primary_target_id = "custom:duplicate"
enabled_target_ids = ["finder", "custom:duplicate", "custom:valid", "finder", "missing"]

[[open_with.custom_apps]]
id = "custom:valid"
name = "Valid Editor"
path = "C:\\Editors\\Valid.exe"

[[open_with.custom_apps]]
id = "custom:duplicate"
name = "Duplicate Editor"
path = "C:\\Editors\\Valid.exe"

[[open_with.custom_apps]]
id = "custom:empty"
name = ""
path = "C:\\Editors\\Empty.exe"

[[open_with.custom_apps]]
id = "finder"
name = "Built In Collision"
path = "C:\\Editors\\Finder.exe"
"#;

    let config = AppConfigToml::decode(source).expect("open with config should decode");

    assert_eq!(
        config.open_with.custom_apps,
        vec![OpenWithCustomApp {
            id: "custom:valid".to_string(),
            name: "Valid Editor".to_string(),
            path: r"C:\Editors\Valid.exe".to_string(),
        }]
    );
    assert_eq!(
        config.open_with.enabled_target_ids,
        vec!["finder".to_string(), "custom:valid".to_string()]
    );
    assert_eq!(config.open_with.primary_target_id, "custom:valid");
}

#[test]
fn app_config_decode_preserves_empty_open_with_enabled_list_like_swift() {
    let source = r#"
[open_with]
primary_target_id = "finder"
enabled_target_ids = []
"#;

    let config = AppConfigToml::decode(source).expect("open with config should decode");

    assert!(config.open_with.enabled_target_ids.is_empty());
    assert_eq!(config.open_with.primary_target_id, "finder");
}

#[test]
fn app_config_decode_normalizes_shortcut_overrides_like_swift() {
    let source = r#"
[[shortcuts.bindings]]
command_id = "sidebar.toggle"
shortcut = "command+b"

[[shortcuts.bindings]]
command_id = "missing.command"
shortcut = "command+m"

[[shortcuts.bindings]]
command_id = "pane.split.horizontal"
shortcut = "shift+t"

[[shortcuts.bindings]]
command_id = "pane.split.horizontal"
shortcut = "command+control+z"

[[shortcuts.bindings]]
command_id = "sidebar.toggle"
shortcut = "command+control+z"

[[shortcuts.bindings]]
command_id = "pane.copy_path"
shortcut = ""

[[shortcuts.bindings]]
command_id = "worklane.next"
shortcut = "control+tab"
"#;

    let config = AppConfigToml::decode(source).expect("shortcut config should decode");

    assert_eq!(
        config.shortcuts.bindings,
        vec![
            ShortcutBindingOverride {
                command_id: "sidebar.toggle".to_string(),
                shortcut: Some("command+control+z".to_string()),
            },
            ShortcutBindingOverride {
                command_id: "pane.copy_path".to_string(),
                shortcut: None,
            },
            ShortcutBindingOverride {
                command_id: "worklane.next".to_string(),
                shortcut: Some("control+tab".to_string()),
            }
        ]
    );
}

#[test]
fn app_config_store_update_persists_normalized_config() {
    let path = temp_config_path("update-persists");
    let mut store = AppConfigStore::load(path.clone()).expect("config store should load");

    store
        .update(|config| {
            config.panes.inactive_opacity = 0.1;
            config.menu_bar.show_status_item = false;
            config.agent_caffeination.enabled = false;
        })
        .expect("config update should persist");

    assert_eq!(store.current().panes.inactive_opacity, 0.6);
    assert!(!store.current().menu_bar.show_status_item);
    let persisted = fs::read_to_string(&path).expect("config should persist");
    assert!(persisted.contains("[menu_bar]"));
    assert!(persisted.contains("show_status_item = false"));
    assert!(persisted.contains("[agent_caffeination]"));
    assert!(persisted.contains("enabled = false"));
    assert!(persisted.contains("inactive_opacity = 0.6"));

    fs::remove_file(path).ok();
}

fn temp_config_path(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("zentty-rust-{label}-{nonce}.toml"))
}

fn expected_server_browser_target_ids() -> Vec<String> {
    [
        "safari",
        "chrome",
        "firefox",
        "arc",
        "brave",
        "edge",
        "orion",
        "dia",
        "zen",
        "sizzy",
        "mullvad-browser",
        "helium",
        "vivaldi",
        "opera",
        "chromium",
        "tor-browser",
        "velja",
        "sigmaos",
        "floorp",
        "comet",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}
