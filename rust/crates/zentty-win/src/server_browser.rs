use std::collections::HashSet;
use std::env;
use std::path::{Path, PathBuf};

use zentty_core::config::ServerDetectionConfig;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerBrowserOpenTarget {
    pub stable_id: String,
    pub display_name: String,
    pub app_path: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ServerBrowserDiscoveryEnvironment {
    pub local_app_data: Option<PathBuf>,
    pub program_files: Vec<PathBuf>,
    pub path_entries: Vec<PathBuf>,
}

impl ServerBrowserDiscoveryEnvironment {
    pub fn from_process() -> Self {
        let local_app_data = env::var_os("LOCALAPPDATA").map(PathBuf::from);
        let program_files = ["ProgramFiles", "ProgramFiles(x86)"]
            .into_iter()
            .filter_map(env::var_os)
            .map(PathBuf::from)
            .collect();
        let path_entries = env::var_os("PATH")
            .map(|value| env::split_paths(&value).collect())
            .unwrap_or_default();

        Self {
            local_app_data,
            program_files,
            path_entries,
        }
    }
}

pub fn server_browser_target_for_open(
    config: &ServerDetectionConfig,
    requested_browser_id: Option<&str>,
) -> Option<ServerBrowserOpenTarget> {
    server_browser_target_for_open_in_environment(
        config,
        requested_browser_id,
        &ServerBrowserDiscoveryEnvironment::from_process(),
    )
}

pub fn server_browser_target_for_open_in_environment(
    config: &ServerDetectionConfig,
    requested_browser_id: Option<&str>,
    environment: &ServerBrowserDiscoveryEnvironment,
) -> Option<ServerBrowserOpenTarget> {
    let targets = resolve_server_browser_targets_in_environment(config, environment);
    if let Some(requested_browser_id) = requested_browser_id
        && let Some(target) = find_browser_target(&targets, requested_browser_id)
    {
        return Some(target.clone());
    }

    find_browser_target(&targets, &config.preferred_browser_id).cloned()
}

pub fn resolve_available_server_browser_targets(
    config: &ServerDetectionConfig,
) -> Vec<ServerBrowserOpenTarget> {
    resolve_available_server_browser_targets_in_environment(
        config,
        &ServerBrowserDiscoveryEnvironment::from_process(),
    )
}

pub fn resolve_server_browser_targets_in_environment(
    config: &ServerDetectionConfig,
    environment: &ServerBrowserDiscoveryEnvironment,
) -> Vec<ServerBrowserOpenTarget> {
    let enabled_ids = enabled_browser_ids(config);
    resolve_available_server_browser_targets_in_environment(config, environment)
        .into_iter()
        .filter(|target| enabled_ids.contains(target.stable_id.as_str()))
        .collect()
}

pub fn resolve_available_server_browser_targets_in_environment(
    config: &ServerDetectionConfig,
    environment: &ServerBrowserDiscoveryEnvironment,
) -> Vec<ServerBrowserOpenTarget> {
    let mut targets = Vec::new();
    let mut seen_paths = HashSet::new();

    for spec in SERVER_BROWSER_BUILT_INS {
        if let Some(app_path) = resolve_built_in_browser_path(spec, environment) {
            let path_key = app_path.to_string_lossy().to_lowercase();
            if seen_paths.insert(path_key) {
                targets.push(ServerBrowserOpenTarget {
                    stable_id: spec.stable_id.to_string(),
                    display_name: spec.display_name.to_string(),
                    app_path: app_path.to_string_lossy().into_owned(),
                });
            }
        }
    }

    for browser in &config.custom_browsers {
        if browser.id.is_empty()
            || browser.name.is_empty()
            || browser.path.is_empty()
            || !path_is_readable_file(&browser.path)
        {
            continue;
        }

        let path_key = browser.path.to_lowercase();
        if seen_paths.insert(path_key) {
            targets.push(ServerBrowserOpenTarget {
                stable_id: browser.id.clone(),
                display_name: browser.name.clone(),
                app_path: browser.path.clone(),
            });
        }
    }

    targets
}

#[derive(Clone, Copy)]
struct ServerBrowserBuiltInSpec {
    stable_id: &'static str,
    display_name: &'static str,
    bundle_identifiers: &'static [&'static str],
    relative_paths: &'static [&'static str],
    executable_names: &'static [&'static str],
}

const SERVER_BROWSER_BUILT_INS: &[ServerBrowserBuiltInSpec] = &[
    ServerBrowserBuiltInSpec {
        stable_id: "chrome",
        display_name: "Google Chrome",
        bundle_identifiers: &["com.google.Chrome"],
        relative_paths: &[r"Google\Chrome\Application\chrome.exe"],
        executable_names: &["chrome.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "firefox",
        display_name: "Firefox",
        bundle_identifiers: &["org.mozilla.firefox"],
        relative_paths: &[r"Mozilla Firefox\firefox.exe"],
        executable_names: &["firefox.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "brave",
        display_name: "Brave",
        bundle_identifiers: &["com.brave.Browser"],
        relative_paths: &[r"BraveSoftware\Brave-Browser\Application\brave.exe"],
        executable_names: &["brave.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "edge",
        display_name: "Microsoft Edge",
        bundle_identifiers: &["com.microsoft.edgemac"],
        relative_paths: &[r"Microsoft\Edge\Application\msedge.exe"],
        executable_names: &["msedge.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "arc",
        display_name: "Arc",
        bundle_identifiers: &["company.thebrowser.Browser"],
        relative_paths: &[r"Microsoft\WindowsApps\Arc.exe"],
        executable_names: &["Arc.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "dia",
        display_name: "Dia",
        bundle_identifiers: &["company.thebrowser.dia"],
        relative_paths: &[r"Programs\Dia\Dia.exe", r"Dia\Dia.exe"],
        executable_names: &["Dia.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "zen",
        display_name: "Zen",
        bundle_identifiers: &["io.github.zen_browser.zen", "app.zen-browser.zen"],
        relative_paths: &[r"Zen Browser\zen.exe", r"Zen\zen.exe"],
        executable_names: &["zen.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "sizzy",
        display_name: "Sizzy",
        bundle_identifiers: &["com.sizzy.Sizzy"],
        relative_paths: &[r"Programs\Sizzy\Sizzy.exe", r"Sizzy\Sizzy.exe"],
        executable_names: &["Sizzy.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "mullvad-browser",
        display_name: "Mullvad Browser",
        bundle_identifiers: &["org.mullvad.mullvadbrowser", "org.mozilla.mullvadbrowser"],
        relative_paths: &[r"Mullvad Browser\Browser\firefox.exe"],
        executable_names: &["mullvadbrowser.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "vivaldi",
        display_name: "Vivaldi",
        bundle_identifiers: &["com.vivaldi.Vivaldi"],
        relative_paths: &[r"Vivaldi\Application\vivaldi.exe"],
        executable_names: &["vivaldi.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "opera",
        display_name: "Opera",
        bundle_identifiers: &["com.operasoftware.Opera"],
        relative_paths: &[r"Programs\Opera\opera.exe", r"Opera\launcher.exe"],
        executable_names: &["opera.exe", "launcher.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "chromium",
        display_name: "Chromium",
        bundle_identifiers: &["org.chromium.Chromium"],
        relative_paths: &[
            r"Chromium\Application\chrome.exe",
            r"Chromium\Application\chromium.exe",
        ],
        executable_names: &["chromium.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "tor-browser",
        display_name: "Tor Browser",
        bundle_identifiers: &["org.torproject.torbrowser"],
        relative_paths: &[r"Tor Browser\Browser\firefox.exe"],
        executable_names: &["firefox.exe"],
    },
    ServerBrowserBuiltInSpec {
        stable_id: "floorp",
        display_name: "Floorp",
        bundle_identifiers: &["one.ablaze.floorp"],
        relative_paths: &[r"Floorp\floorp.exe"],
        executable_names: &["floorp.exe"],
    },
];

fn enabled_browser_ids(config: &ServerDetectionConfig) -> HashSet<&str> {
    if !config.enabled_browser_target_ids.is_empty() {
        return config
            .enabled_browser_target_ids
            .iter()
            .map(String::as_str)
            .collect();
    }

    SERVER_BROWSER_BUILT_INS
        .iter()
        .map(|browser| browser.stable_id)
        .chain(
            config
                .custom_browsers
                .iter()
                .map(|browser| browser.id.as_str()),
        )
        .collect()
}

fn find_browser_target<'a>(
    targets: &'a [ServerBrowserOpenTarget],
    browser_id: &str,
) -> Option<&'a ServerBrowserOpenTarget> {
    if browser_id == "system-default" {
        return None;
    }

    let normalized = normalized_browser_id(browser_id);
    targets.iter().find(|target| {
        if target.stable_id == normalized {
            return true;
        }
        let Some(bundle_identifier) = normalized.strip_prefix("bundle:") else {
            return false;
        };
        bundle_matches_target(bundle_identifier, target.stable_id.as_str())
    })
}

fn normalized_browser_id(browser_id: &str) -> String {
    if browser_id == "system-default"
        || browser_id.starts_with("bundle:")
        || browser_id.starts_with("custom:")
        || SERVER_BROWSER_BUILT_INS
            .iter()
            .any(|browser| browser.stable_id == browser_id)
    {
        browser_id.to_string()
    } else {
        format!("bundle:{browser_id}")
    }
}

fn bundle_matches_target(bundle_identifier: &str, stable_id: &str) -> bool {
    SERVER_BROWSER_BUILT_INS
        .iter()
        .find(|browser| browser.stable_id == stable_id)
        .is_some_and(|browser| browser.bundle_identifiers.contains(&bundle_identifier))
}

fn resolve_built_in_browser_path(
    spec: &ServerBrowserBuiltInSpec,
    environment: &ServerBrowserDiscoveryEnvironment,
) -> Option<PathBuf> {
    let roots = environment
        .local_app_data
        .iter()
        .chain(environment.program_files.iter());

    for root in roots {
        for relative_path in spec.relative_paths {
            let candidate = root.join(relative_path);
            if path_is_readable_file(&candidate) {
                return Some(candidate);
            }
        }
    }

    for path_entry in &environment.path_entries {
        for executable_name in spec.executable_names {
            let candidate = path_entry.join(executable_name);
            if path_is_readable_file(&candidate) {
                return Some(candidate);
            }
        }
    }

    None
}

fn path_is_readable_file(path: impl AsRef<Path>) -> bool {
    path.as_ref()
        .metadata()
        .map(|metadata| metadata.is_file())
        .unwrap_or(false)
}
