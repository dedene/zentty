use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use toml::Value;

use crate::agent::{AgentBootstrapTool, AgentIntegrationConsent, AgentIntegrationState};
use crate::commands::AppCommandId;
use crate::servers::ServerPortRule;

#[derive(Clone, Debug, PartialEq)]
#[derive(Default)]
pub struct AppConfig {
    pub sidebar: SidebarConfig,
    pub pane_layout: PaneLayoutConfig,
    pub panes: PanesConfig,
    pub appearance: AppearanceConfig,
    pub open_with: OpenWithConfig,
    pub confirmations: ConfirmationsConfig,
    pub error_reporting: ErrorReportingConfig,
    pub updates: UpdatesConfig,
    pub notifications: NotificationsConfig,
    pub clipboard: ClipboardConfig,
    pub worklanes: WorklanesConfig,
    pub restore: RestoreConfig,
    pub shortcuts: ShortcutsConfig,
    pub server_detection: ServerDetectionConfig,
    pub agent_teams: AgentTeamsConfig,
    pub agent_caffeination: AgentCaffeinationConfig,
    pub menu_bar: MenuBarConfig,
    pub agent_integrations: AgentIntegrationsConfig,
}

impl AppConfig {
    pub fn normalized(mut self) -> Self {
        self.pane_layout = self.pane_layout.normalized();
        self.panes = self.panes.normalized();
        self.open_with = self.open_with.normalized();
        self.shortcuts = self.shortcuts.normalized();
        self.notifications = self.notifications.normalized();
        self.server_detection = self.server_detection.normalized();
        self
    }
}


#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SidebarConfig {
    pub width: f64,
    pub visibility: SidebarVisibility,
}

impl Default for SidebarConfig {
    fn default() -> Self {
        Self {
            width: 280.0,
            visibility: SidebarVisibility::PinnedOpen,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[derive(Default)]
pub enum SidebarVisibility {
    #[serde(rename = "pinnedOpen")]
    #[default]
    PinnedOpen,
    #[serde(rename = "hidden")]
    Hidden,
    #[serde(rename = "hoverPeek")]
    HoverPeek,
}

impl SidebarVisibility {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::PinnedOpen => "pinnedOpen",
            Self::Hidden => "hidden",
            Self::HoverPeek => "hoverPeek",
        }
    }

    pub fn is_visible(self) -> bool {
        self != Self::Hidden
    }

    pub fn toggle(self) -> Self {
        if self == Self::PinnedOpen {
            Self::Hidden
        } else {
            Self::PinnedOpen
        }
    }
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PaneLayoutConfig {
    pub laptop: PaneLayoutPreset,
    pub large_display: PaneLayoutPreset,
    pub ultrawide: PaneLayoutPreset,
    pub right_split_behavior: PaneSplitBehaviorMode,
    pub visible_split_window_width: u32,
}

impl PaneLayoutConfig {
    const DEFAULT_VISIBLE_SPLIT_WINDOW_WIDTH: u32 = 1920;
    const VISIBLE_SPLIT_WINDOW_WIDTHS: [u32; 5] = [1200, 1440, 1680, 1920, 2560];

    pub fn normalized(mut self) -> Self {
        if !Self::VISIBLE_SPLIT_WINDOW_WIDTHS.contains(&self.visible_split_window_width) {
            self.visible_split_window_width = Self::DEFAULT_VISIBLE_SPLIT_WINDOW_WIDTH;
        }
        self
    }

    pub fn should_split_right_visibly(&self, viewport_width: f64) -> bool {
        match self.right_split_behavior {
            PaneSplitBehaviorMode::Adaptive => {
                viewport_width >= f64::from(self.visible_split_window_width)
            }
            PaneSplitBehaviorMode::AlwaysSplit => true,
            PaneSplitBehaviorMode::AlwaysAdd => false,
        }
    }
}

impl Default for PaneLayoutConfig {
    fn default() -> Self {
        Self {
            laptop: PaneLayoutPreset::Compact,
            large_display: PaneLayoutPreset::Balanced,
            ultrawide: PaneLayoutPreset::Balanced,
            right_split_behavior: PaneSplitBehaviorMode::Adaptive,
            visible_split_window_width: Self::DEFAULT_VISIBLE_SPLIT_WINDOW_WIDTH,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum PaneLayoutPreset {
    Compact,
    #[default]
    Balanced,
    Roomy,
}


#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[derive(Default)]
pub enum PaneSplitBehaviorMode {
    #[serde(rename = "adaptive")]
    #[default]
    Adaptive,
    #[serde(rename = "alwaysSplit")]
    AlwaysSplit,
    #[serde(rename = "alwaysAdd")]
    AlwaysAdd,
}


#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PanesConfig {
    pub show_labels: bool,
    pub inactive_opacity: f64,
    pub show_project_icons: bool,
    #[serde(rename = "smooth_scroll_enabled")]
    pub smooth_scrolling_enabled: bool,
    pub focus_follows_mouse: bool,
    pub focus_follows_mouse_delay: FocusFollowsMouseDelay,
}

impl PanesConfig {
    pub const MINIMUM_INACTIVE_OPACITY: f64 = 0.6;
    pub const MAXIMUM_INACTIVE_OPACITY: f64 = 1.0;

    pub fn normalized(mut self) -> Self {
        self.inactive_opacity = self.inactive_opacity.clamp(
            Self::MINIMUM_INACTIVE_OPACITY,
            Self::MAXIMUM_INACTIVE_OPACITY,
        );
        self
    }
}

impl Default for PanesConfig {
    fn default() -> Self {
        Self {
            show_labels: true,
            inactive_opacity: 0.7,
            show_project_icons: true,
            smooth_scrolling_enabled: false,
            focus_follows_mouse: false,
            focus_follows_mouse_delay: FocusFollowsMouseDelay::Short,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(Default)]
pub enum FocusFollowsMouseDelay {
    Immediate,
    #[default]
    Short,
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct OpenWithConfig {
    pub primary_target_id: String,
    pub enabled_target_ids: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub custom_apps: Vec<OpenWithCustomApp>,
}

impl OpenWithConfig {
    const DEFAULT_PRIMARY_TARGET_ID: &'static str = "finder";
    const BUILT_IN_TARGET_IDS: [&'static str; 21] = [
        "vscode",
        "vscode-insiders",
        "cursor",
        "zed",
        "windsurf",
        "antigravity",
        "codex",
        "claude",
        "finder",
        "xcode",
        "android-studio",
        "intellij-idea",
        "rider",
        "goland",
        "rustrover",
        "pycharm",
        "webstorm",
        "phpstorm",
        "sublime-text",
        "bbedit",
        "textmate",
    ];

    pub fn normalized(mut self) -> Self {
        let built_in_ids: HashSet<&'static str> = Self::BUILT_IN_TARGET_IDS.into_iter().collect();
        let mut canonical_apps = Vec::new();
        let mut seen_custom_ids = HashSet::new();
        let mut canonical_id_by_duplicate_id = HashMap::new();

        for app in self.custom_apps {
            if app.id.is_empty() || app.name.is_empty() || app.path.is_empty() {
                continue;
            }

            if let Some(existing) = canonical_apps
                .iter()
                .find(|existing: &&OpenWithCustomApp| existing.path == app.path)
            {
                canonical_id_by_duplicate_id.insert(app.id, existing.id.clone());
                continue;
            }

            if built_in_ids.contains(app.id.as_str()) || !seen_custom_ids.insert(app.id.clone()) {
                continue;
            }

            canonical_apps.push(app);
        }

        let valid_custom_ids: HashSet<&str> =
            canonical_apps.iter().map(|app| app.id.as_str()).collect();
        let mut normalized_enabled_target_ids = Vec::new();
        let mut seen_enabled_target_ids = HashSet::new();
        for target_id in self.enabled_target_ids {
            let canonical_target_id = canonical_id_by_duplicate_id
                .get(&target_id)
                .cloned()
                .unwrap_or(target_id);
            if (built_in_ids.contains(canonical_target_id.as_str())
                || valid_custom_ids.contains(canonical_target_id.as_str()))
                && seen_enabled_target_ids.insert(canonical_target_id.clone())
            {
                normalized_enabled_target_ids.push(canonical_target_id);
            }
        }

        let requested_target_id = canonical_id_by_duplicate_id
            .get(&self.primary_target_id)
            .cloned()
            .unwrap_or_else(|| self.primary_target_id.clone());
        let normalized_primary_target_id = if built_in_ids.contains(requested_target_id.as_str())
            || valid_custom_ids.contains(requested_target_id.as_str())
        {
            requested_target_id
        } else {
            normalized_enabled_target_ids
                .first()
                .cloned()
                .unwrap_or_else(|| Self::DEFAULT_PRIMARY_TARGET_ID.to_string())
        };

        self.primary_target_id = normalized_primary_target_id;
        self.enabled_target_ids = normalized_enabled_target_ids;
        self.custom_apps = canonical_apps;
        self
    }
}

impl Default for OpenWithConfig {
    fn default() -> Self {
        Self {
            primary_target_id: OpenWithConfig::DEFAULT_PRIMARY_TARGET_ID.to_string(),
            enabled_target_ids: ["finder", "vscode", "cursor", "xcode"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            custom_apps: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct OpenWithCustomApp {
    pub id: String,
    pub name: String,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppearanceConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_theme_name: Option<String>,
    #[serde(skip_serializing_if = "is_default_theme_mode")]
    pub theme_mode: AppearanceThemeMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_dark_theme_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preferred_light_theme_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_background_opacity: Option<f64>,
    #[serde(
        rename = "sync_opencode_theme_with_terminal",
        skip_serializing_if = "is_true"
    )]
    pub sync_opencode_theme_with_terminal: bool,
}

impl Default for AppearanceConfig {
    fn default() -> Self {
        Self {
            local_theme_name: None,
            theme_mode: AppearanceThemeMode::AlwaysDark,
            preferred_dark_theme_name: None,
            preferred_light_theme_name: None,
            local_background_opacity: None,
            sync_opencode_theme_with_terminal: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[derive(Default)]
pub enum AppearanceThemeMode {
    #[serde(rename = "followMacOS")]
    FollowMacOS,
    #[serde(rename = "alwaysDark")]
    #[default]
    AlwaysDark,
    #[serde(rename = "alwaysLight")]
    AlwaysLight,
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ConfirmationsConfig {
    pub confirm_before_closing_pane: bool,
    pub confirm_before_closing_window: bool,
    pub confirm_before_quitting: bool,
}

impl Default for ConfirmationsConfig {
    fn default() -> Self {
        Self {
            confirm_before_closing_pane: true,
            confirm_before_closing_window: true,
            confirm_before_quitting: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ErrorReportingConfig {
    pub enabled: bool,
}

impl Default for ErrorReportingConfig {
    fn default() -> Self {
        Self { enabled: true }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UpdatesConfig {
    pub channel: AppUpdateChannel,
}

impl Default for UpdatesConfig {
    fn default() -> Self {
        Self {
            channel: AppUpdateChannel::Stable,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum AppUpdateChannel {
    #[default]
    Stable,
    Beta,
}


#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotificationsConfig {
    pub sound_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_sound_display_name: Option<String>,
}

impl NotificationsConfig {
    pub fn normalized(mut self) -> Self {
        if !is_custom_notification_sound_name(&self.sound_name) {
            self.custom_sound_display_name = None;
        }
        self
    }
}

fn is_custom_notification_sound_name(name: &str) -> bool {
    name.starts_with("zentty-custom-") && name.ends_with(".caf")
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
#[derive(Default)]
pub struct ClipboardConfig {
    pub always_clean_copies: bool,
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WorklanesConfig {
    pub new_worklane_placement: NewWorklanePlacement,
}

impl Default for WorklanesConfig {
    fn default() -> Self {
        Self {
            new_worklane_placement: NewWorklanePlacement::AfterCurrent,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(Default)]
pub enum NewWorklanePlacement {
    Top,
    #[default]
    AfterCurrent,
    End,
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RestoreConfig {
    pub restore_workspace_on_launch: bool,
}

impl Default for RestoreConfig {
    fn default() -> Self {
        Self {
            restore_workspace_on_launch: true,
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ShortcutsConfig {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub bindings: Vec<ShortcutBindingOverride>,
}

impl ShortcutsConfig {
    pub fn is_empty(&self) -> bool {
        self.bindings.is_empty()
    }

    pub fn normalized(self) -> Self {
        let mut accepted_commands = HashSet::new();
        let mut accepted_shortcuts = HashSet::new();
        let mut bindings = Vec::new();

        for binding in self.bindings.into_iter().rev() {
            let Some(command_id) = AppCommandId::from_raw_value(binding.command_id.trim()) else {
                continue;
            };

            let shortcut = match normalized_shortcut_override(binding.shortcut.as_deref()) {
                ShortcutOverrideNormalization::Bound(shortcut) => {
                    if !accepted_shortcuts.insert(shortcut.clone()) {
                        continue;
                    }
                    Some(shortcut)
                }
                ShortcutOverrideNormalization::Unbound => None,
                ShortcutOverrideNormalization::Invalid => continue,
            };

            let command_id = command_id.raw_value().to_string();
            if !accepted_commands.insert(command_id.clone()) {
                continue;
            }

            bindings.push(ShortcutBindingOverride {
                command_id,
                shortcut,
            });
        }

        bindings.reverse();
        Self { bindings }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ShortcutBindingOverride {
    pub command_id: String,
    #[serde(
        default,
        serialize_with = "serialize_shortcut_override",
        deserialize_with = "deserialize_shortcut_override"
    )]
    pub shortcut: Option<String>,
}

enum ShortcutOverrideNormalization {
    Bound(String),
    Unbound,
    Invalid,
}

fn normalized_shortcut_override(shortcut: Option<&str>) -> ShortcutOverrideNormalization {
    let Some(shortcut) = shortcut else {
        return ShortcutOverrideNormalization::Unbound;
    };
    let shortcut = shortcut.trim();
    if shortcut.is_empty() {
        return ShortcutOverrideNormalization::Unbound;
    }

    normalize_shortcut_text(shortcut)
        .map(ShortcutOverrideNormalization::Bound)
        .unwrap_or(ShortcutOverrideNormalization::Invalid)
}

fn normalize_shortcut_text(shortcut: &str) -> Option<String> {
    let mut command = false;
    let mut control = false;
    let mut option = false;
    let mut shift = false;
    let mut key = None;

    for component in shortcut.split('+') {
        let component = component
            .trim()
            .to_ascii_lowercase()
            .replace([' ', '_'], "");
        match component.as_str() {
            "" => return None,
            "command" | "cmd" | "meta" | "windows" | "win" => command = true,
            "control" | "ctrl" => control = true,
            "option" | "alt" => option = true,
            "shift" => shift = true,
            value => {
                if key.is_some() {
                    return None;
                }
                key = normalize_shortcut_key(value);
            }
        }
    }

    if !(command || control || option) {
        return None;
    }

    let key = key?;
    let mut parts = Vec::new();
    if command {
        parts.push("command");
    }
    if control {
        parts.push("control");
    }
    if option {
        parts.push("option");
    }
    if shift {
        parts.push("shift");
    }
    parts.push(&key);
    Some(parts.join("+"))
}

fn normalize_shortcut_key(key: &str) -> Option<String> {
    match key {
        "left" | "leftarrow" | "arrowleft" => Some("left".to_string()),
        "right" | "rightarrow" | "arrowright" => Some("right".to_string()),
        "up" | "uparrow" | "arrowup" => Some("up".to_string()),
        "down" | "downarrow" | "arrowdown" => Some("down".to_string()),
        "delete" | "del" => Some("delete".to_string()),
        "tab" => Some("tab".to_string()),
        "home" => Some("home".to_string()),
        "end" => Some("end".to_string()),
        "pageup" | "pgup" => Some("pageup".to_string()),
        "pagedown" | "pgdn" => Some("pagedown".to_string()),
        value => {
            let mut chars = value.chars();
            let key = chars.next()?;
            if chars.next().is_none() && !key.is_control() {
                Some(key.to_ascii_lowercase().to_string())
            } else {
                None
            }
        }
    }
}

fn serialize_shortcut_override<S>(
    shortcut: &Option<String>,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(shortcut.as_deref().unwrap_or(""))
}

fn deserialize_shortcut_override<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let shortcut = String::deserialize(deserializer)?;
    Ok((!shortcut.trim().is_empty()).then_some(shortcut))
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ServerDetectionConfig {
    pub passive_detection_enabled: bool,
    pub preferred_browser_id: String,
    pub enabled_browser_target_ids: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub custom_browsers: Vec<ServerBrowserCustomApp>,
    pub ignored_port_rules: Vec<String>,
}

impl ServerDetectionConfig {
    const SYSTEM_DEFAULT_BROWSER_ID: &'static str = "system-default";
    const BUILT_IN_BROWSER_TARGET_IDS: [&'static str; 20] = [
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
    ];

    pub fn normalized(mut self) -> Self {
        let built_in_ids: HashSet<&'static str> =
            Self::BUILT_IN_BROWSER_TARGET_IDS.into_iter().collect();
        let mut canonical_browsers = Vec::new();
        let mut seen_ids = HashSet::new();
        let mut canonical_id_by_duplicate_id = HashMap::new();

        for browser in self.custom_browsers {
            if browser.id.is_empty() || browser.name.is_empty() || browser.path.is_empty() {
                continue;
            }

            if let Some(existing) = canonical_browsers
                .iter()
                .find(|existing: &&ServerBrowserCustomApp| existing.path == browser.path)
            {
                canonical_id_by_duplicate_id.insert(browser.id, existing.id.clone());
                continue;
            }

            if !seen_ids.insert(browser.id.clone()) {
                continue;
            }

            canonical_browsers.push(browser);
        }

        let valid_custom_ids: HashSet<&str> = canonical_browsers
            .iter()
            .map(|browser| browser.id.as_str())
            .collect();
        let enabled_source = if self.enabled_browser_target_ids.is_empty() {
            Self::BUILT_IN_BROWSER_TARGET_IDS
                .into_iter()
                .map(str::to_string)
                .chain(canonical_browsers.iter().map(|browser| browser.id.clone()))
                .collect()
        } else {
            self.enabled_browser_target_ids
        };
        let mut normalized_enabled_browser_target_ids = Vec::new();
        let mut seen_enabled = HashSet::new();
        for stable_id in enabled_source {
            let canonical_id = canonical_id_by_duplicate_id
                .get(&stable_id)
                .cloned()
                .unwrap_or(stable_id);
            if (built_in_ids.contains(canonical_id.as_str())
                || valid_custom_ids.contains(canonical_id.as_str()))
                && seen_enabled.insert(canonical_id.clone())
            {
                normalized_enabled_browser_target_ids.push(canonical_id);
            }
        }

        let enabled_set: HashSet<&str> = normalized_enabled_browser_target_ids
            .iter()
            .map(String::as_str)
            .collect();
        let resolved_preferred = canonical_id_by_duplicate_id
            .get(&self.preferred_browser_id)
            .cloned()
            .unwrap_or_else(|| self.preferred_browser_id.clone());
        let normalized_preferred_browser_id =
            if resolved_preferred == Self::SYSTEM_DEFAULT_BROWSER_ID {
                Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
            } else if let Some(bundle_identifier) = resolved_preferred.strip_prefix("bundle:") {
                if bundle_identifier.is_empty() {
                    Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
                } else if let Some(slug) =
                    built_in_browser_slug_for_bundle_identifier(bundle_identifier)
                {
                    if enabled_set.contains(slug) {
                        resolved_preferred
                    } else {
                        Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
                    }
                } else {
                    Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
                }
            } else if built_in_ids.contains(resolved_preferred.as_str())
                || valid_custom_ids.contains(resolved_preferred.as_str())
            {
                if enabled_set.contains(resolved_preferred.as_str()) {
                    resolved_preferred
                } else {
                    Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
                }
            } else {
                Self::SYSTEM_DEFAULT_BROWSER_ID.to_string()
            };

        self.preferred_browser_id = normalized_preferred_browser_id;
        self.enabled_browser_target_ids = normalized_enabled_browser_target_ids;
        self.custom_browsers = canonical_browsers;
        self.ignored_port_rules = ServerPortRule::canonical_strings(&self.ignored_port_rules);
        self
    }
}

impl Default for ServerDetectionConfig {
    fn default() -> Self {
        Self {
            passive_detection_enabled: true,
            preferred_browser_id: "system-default".to_string(),
            enabled_browser_target_ids: Vec::new(),
            custom_browsers: Vec::new(),
            ignored_port_rules: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ServerBrowserCustomApp {
    pub id: String,
    pub name: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle_identifier: Option<String>,
}

fn built_in_browser_slug_for_bundle_identifier(bundle_identifier: &str) -> Option<&'static str> {
    match bundle_identifier {
        "com.apple.Safari" => Some("safari"),
        "com.google.Chrome" => Some("chrome"),
        "org.mozilla.firefox" => Some("firefox"),
        "company.thebrowser.Browser" => Some("arc"),
        "com.brave.Browser" => Some("brave"),
        "com.microsoft.edgemac" => Some("edge"),
        "com.kagi.kagimacOS.Browser" | "com.mac.Orion" => Some("orion"),
        "company.thebrowser.dia" => Some("dia"),
        "io.github.zen_browser.zen" | "app.zen-browser.zen" => Some("zen"),
        "com.sizzy.Sizzy" => Some("sizzy"),
        "org.mullvad.mullvadbrowser" | "org.mozilla.mullvadbrowser" => Some("mullvad-browser"),
        "com.JadenGeller.Helium" => Some("helium"),
        "com.vivaldi.Vivaldi" => Some("vivaldi"),
        "com.operasoftware.Opera" => Some("opera"),
        "org.chromium.Chromium" => Some("chromium"),
        "org.torproject.torbrowser" => Some("tor-browser"),
        "com.sindresorhus.Velja" => Some("velja"),
        "company.sigmaos.sigmaos.macos" => Some("sigmaos"),
        "xyz.floorp.browser" => Some("floorp"),
        "ai.perplexity.comet" | "com.perplexity.comet" => Some("comet"),
        _ => None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
#[derive(Default)]
pub struct AgentTeamsConfig {
    pub enabled: bool,
}


#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentCaffeinationConfig {
    pub enabled: bool,
}

impl Default for AgentCaffeinationConfig {
    fn default() -> Self {
        Self { enabled: true }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MenuBarConfig {
    pub show_status_item: bool,
}

impl Default for MenuBarConfig {
    fn default() -> Self {
        Self {
            show_status_item: true,
        }
    }
}

pub struct AppConfigToml;

impl AppConfigToml {
    pub fn encode(config: &AppConfig) -> String {
        let normalized = config.clone().normalized();
        let root = AppConfigTomlRoot {
            sidebar: &normalized.sidebar,
            pane_layout: &normalized.pane_layout,
            panes: &normalized.panes,
            appearance: (normalized.appearance != AppearanceConfig::default())
                .then_some(&normalized.appearance),
            open_with: &normalized.open_with,
            confirmations: &normalized.confirmations,
            error_reporting: &normalized.error_reporting,
            updates: &normalized.updates,
            notifications: &normalized.notifications,
            clipboard: &normalized.clipboard,
            worklanes: &normalized.worklanes,
            restore: &normalized.restore,
            shortcuts: &normalized.shortcuts,
            server_detection: &normalized.server_detection,
            agent_teams: &normalized.agent_teams,
            agent_caffeination: &normalized.agent_caffeination,
            menu_bar: &normalized.menu_bar,
            agent_integrations: AgentIntegrationsTomlSection {
                grandfathered_v1: normalized.agent_integrations.grandfathered_v1,
                states: &normalized.agent_integrations.states,
            },
        };
        toml::to_string(&root).expect("app config should serialize")
    }

    pub fn decode(source: &str) -> Option<AppConfig> {
        let root: RawAppConfigTomlRoot = toml::from_str(source).ok()?;
        let mut appearance = root.appearance;
        if let Some(local_theme_name) = appearance.local_theme_name.clone() {
            appearance.theme_mode = AppearanceThemeMode::AlwaysDark;
            if appearance.preferred_dark_theme_name.is_none() {
                appearance.preferred_dark_theme_name = Some(local_theme_name);
            }
        }

        let mut states = BTreeMap::new();
        for (key, value) in root.agent_integrations.states {
            let raw_state = value.as_str()?;
            if let Some(state) = AgentIntegrationState::parse(raw_state) {
                states.insert(key, state);
            }
        }

        Some(
            AppConfig {
                sidebar: root.sidebar,
                pane_layout: root.pane_layout,
                panes: root.panes,
                appearance,
                open_with: root.open_with,
                confirmations: root.confirmations,
                error_reporting: root.error_reporting,
                updates: root.updates,
                notifications: root.notifications,
                clipboard: root.clipboard,
                worklanes: root.worklanes,
                restore: root.restore,
                shortcuts: root.shortcuts,
                server_detection: root.server_detection,
                agent_teams: root.agent_teams,
                agent_caffeination: root.agent_caffeination,
                menu_bar: root.menu_bar,
                agent_integrations: AgentIntegrationsConfig {
                    states,
                    grandfathered_v1: root.agent_integrations.grandfathered_v1,
                },
            }
            .normalized(),
        )
    }
}

#[derive(Clone, Debug)]
pub struct AppConfigStore {
    path: PathBuf,
    current: AppConfig,
    did_load_from_valid_file: bool,
}

impl AppConfigStore {
    pub fn load(path: PathBuf) -> io::Result<Self> {
        match fs::read_to_string(&path) {
            Ok(source) => {
                let (current, did_load_from_valid_file) = match AppConfigToml::decode(&source) {
                    Some(config) => (config, true),
                    None => (AppConfig::default().normalized(), false),
                };
                Ok(Self {
                    path,
                    current,
                    did_load_from_valid_file,
                })
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let current = AppConfig::default().normalized();
                let store = Self {
                    path,
                    current,
                    did_load_from_valid_file: true,
                };
                let _ = store.write(&store.current);
                Ok(store)
            }
            Err(error) => Err(error),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn current(&self) -> &AppConfig {
        &self.current
    }

    pub fn did_load_from_valid_file(&self) -> bool {
        self.did_load_from_valid_file
    }

    pub fn update<F>(&mut self, updater: F) -> io::Result<()>
    where
        F: FnOnce(&mut AppConfig),
    {
        let mut updated = self.current.clone();
        updater(&mut updated);
        updated = updated.normalized();
        self.write(&updated)?;
        self.current = updated;
        Ok(())
    }

    fn write(&self, config: &AppConfig) -> io::Result<()> {
        if let Some(parent) = self.path.parent()
            && !parent.as_os_str().is_empty()
        {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, AppConfigToml::encode(config))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
#[derive(Default)]
pub struct AgentIntegrationsConfig {
    pub states: BTreeMap<String, AgentIntegrationState>,
    pub grandfathered_v1: bool,
}

impl AgentIntegrationsConfig {
    pub fn state(&self, tool: AgentBootstrapTool) -> AgentIntegrationState {
        let raw_key = tool.raw_value();
        AgentIntegrationConsent::effective_state(tool, self.states.get(raw_key).copied())
    }
}


pub struct AgentIntegrationsToml;

impl AgentIntegrationsToml {
    pub fn encode(config: &AgentIntegrationsConfig) -> String {
        let root = TomlRoot {
            agent_integrations: AgentIntegrationsTomlSection {
                grandfathered_v1: config.grandfathered_v1,
                states: &config.states,
            },
        };
        toml::to_string(&root).expect("agent integrations config should serialize")
    }

    pub fn decode(source: &str) -> Option<AgentIntegrationsConfig> {
        let root: RawTomlRoot = toml::from_str(source).ok()?;
        let mut states = BTreeMap::new();

        for (key, value) in root.agent_integrations.states {
            let raw_state = value.as_str()?;
            if let Some(state) = AgentIntegrationState::parse(raw_state) {
                states.insert(key, state);
            }
        }

        Some(AgentIntegrationsConfig {
            states,
            grandfathered_v1: root.agent_integrations.grandfathered_v1,
        })
    }
}

impl AgentBootstrapTool {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Amp => "amp",
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor",
            Self::Droid => "droid",
            Self::Gemini => "gemini",
            Self::Kimi => "kimi",
            Self::Opencode => "opencode",
            Self::Pi => "pi",
            Self::Grok => "grok",
            Self::Agy => "agy",
            Self::Hermes => "hermes",
        }
    }
}

#[derive(Serialize)]
struct TomlRoot<'a> {
    agent_integrations: AgentIntegrationsTomlSection<'a>,
}

#[derive(Serialize)]
struct AgentIntegrationsTomlSection<'a> {
    grandfathered_v1: bool,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    states: &'a BTreeMap<String, AgentIntegrationState>,
}

#[derive(Default, Deserialize)]
struct RawTomlRoot {
    #[serde(default)]
    agent_integrations: RawAgentIntegrationsTomlSection,
}

#[derive(Default, Deserialize)]
struct RawAgentIntegrationsTomlSection {
    #[serde(default)]
    grandfathered_v1: bool,
    #[serde(default)]
    states: BTreeMap<String, Value>,
}

#[derive(Serialize)]
struct AppConfigTomlRoot<'a> {
    sidebar: &'a SidebarConfig,
    pane_layout: &'a PaneLayoutConfig,
    panes: &'a PanesConfig,
    #[serde(skip_serializing_if = "Option::is_none")]
    appearance: Option<&'a AppearanceConfig>,
    open_with: &'a OpenWithConfig,
    confirmations: &'a ConfirmationsConfig,
    error_reporting: &'a ErrorReportingConfig,
    updates: &'a UpdatesConfig,
    notifications: &'a NotificationsConfig,
    clipboard: &'a ClipboardConfig,
    worklanes: &'a WorklanesConfig,
    restore: &'a RestoreConfig,
    #[serde(skip_serializing_if = "ShortcutsConfig::is_empty")]
    shortcuts: &'a ShortcutsConfig,
    server_detection: &'a ServerDetectionConfig,
    agent_teams: &'a AgentTeamsConfig,
    agent_caffeination: &'a AgentCaffeinationConfig,
    menu_bar: &'a MenuBarConfig,
    agent_integrations: AgentIntegrationsTomlSection<'a>,
}

#[derive(Default, Deserialize)]
struct RawAppConfigTomlRoot {
    #[serde(default)]
    sidebar: SidebarConfig,
    #[serde(default)]
    pane_layout: PaneLayoutConfig,
    #[serde(default)]
    panes: PanesConfig,
    #[serde(default)]
    appearance: AppearanceConfig,
    #[serde(default)]
    open_with: OpenWithConfig,
    #[serde(default)]
    confirmations: ConfirmationsConfig,
    #[serde(default)]
    error_reporting: ErrorReportingConfig,
    #[serde(default)]
    updates: UpdatesConfig,
    #[serde(default)]
    notifications: NotificationsConfig,
    #[serde(default)]
    clipboard: ClipboardConfig,
    #[serde(default)]
    worklanes: WorklanesConfig,
    #[serde(default)]
    restore: RestoreConfig,
    #[serde(default)]
    shortcuts: ShortcutsConfig,
    #[serde(default)]
    server_detection: ServerDetectionConfig,
    #[serde(default)]
    agent_teams: AgentTeamsConfig,
    #[serde(default)]
    agent_caffeination: AgentCaffeinationConfig,
    #[serde(default)]
    menu_bar: MenuBarConfig,
    #[serde(default)]
    agent_integrations: RawAgentIntegrationsTomlSection,
}

fn is_true(value: &bool) -> bool {
    *value
}

fn is_default_theme_mode(value: &AppearanceThemeMode) -> bool {
    *value == AppearanceThemeMode::default()
}
