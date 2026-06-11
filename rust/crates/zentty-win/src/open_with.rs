use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use zentty_core::command_palette::{
    OpenWithBuiltInTargetId, OpenWithResolvedTarget, OpenWithTargetKind,
};
use zentty_core::config::OpenWithConfig;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OpenWithDiscoveryEnvironment {
    pub local_app_data: Option<PathBuf>,
    pub program_files: Vec<PathBuf>,
    pub path_entries: Vec<PathBuf>,
}

impl OpenWithDiscoveryEnvironment {
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

pub fn resolve_open_with_targets(config: &OpenWithConfig) -> Vec<OpenWithResolvedTarget> {
    resolve_open_with_targets_in_environment(config, &OpenWithDiscoveryEnvironment::from_process())
}

pub fn resolve_available_open_with_targets(config: &OpenWithConfig) -> Vec<OpenWithResolvedTarget> {
    resolve_available_open_with_targets_in_environment(
        config,
        &OpenWithDiscoveryEnvironment::from_process(),
    )
}

pub fn resolve_open_with_targets_in_environment(
    config: &OpenWithConfig,
    environment: &OpenWithDiscoveryEnvironment,
) -> Vec<OpenWithResolvedTarget> {
    let config = config.clone().normalized();
    let enabled_ids: HashSet<&str> = config
        .enabled_target_ids
        .iter()
        .map(String::as_str)
        .collect();
    let targets = resolve_available_open_with_targets_in_environment(&config, environment)
        .into_iter()
        .filter(|target| enabled_ids.contains(target.stable_id.as_str()))
        .collect();

    promote_primary_target(targets, &config.primary_target_id)
}

pub fn resolve_available_open_with_targets_in_environment(
    config: &OpenWithConfig,
    environment: &OpenWithDiscoveryEnvironment,
) -> Vec<OpenWithResolvedTarget> {
    let config = config.clone().normalized();
    let mut targets = Vec::new();

    for spec in OPEN_WITH_BUILT_INS {
        if let Some(app_path) = resolve_built_in_app_path(spec, environment) {
            targets.push(OpenWithResolvedTarget::new(
                spec.stable_id,
                spec.kind,
                spec.display_name,
                Some(spec.built_in_id),
                app_path.as_deref(),
            ));
        }
    }

    for app in config.custom_apps {
        if !path_is_readable_file(&app.path) {
            continue;
        }
        targets.push(OpenWithResolvedTarget::new(
            app.id,
            OpenWithTargetKind::Editor,
            app.name,
            None,
            Some(&app.path),
        ));
    }

    targets
}

#[derive(Clone, Copy)]
struct OpenWithBuiltInSpec {
    stable_id: &'static str,
    display_name: &'static str,
    kind: OpenWithTargetKind,
    built_in_id: OpenWithBuiltInTargetId,
    path_kind: BuiltInPathKind,
}

#[derive(Clone, Copy)]
enum BuiltInPathKind {
    AlwaysAvailable,
    Standard {
        relative_paths: &'static [&'static str],
        executable_names: &'static [&'static str],
    },
    JetBrains {
        product_prefix: &'static str,
        executable_name: &'static str,
    },
    Unavailable,
}

const OPEN_WITH_BUILT_INS: &[OpenWithBuiltInSpec] = &[
    OpenWithBuiltInSpec {
        stable_id: "vscode",
        display_name: "Visual Studio Code",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::VsCode,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[
                r"Programs\Microsoft VS Code\Code.exe",
                r"Microsoft VS Code\Code.exe",
            ],
            executable_names: &["Code.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "vscode-insiders",
        display_name: "Visual Studio Code - Insiders",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::VsCodeInsiders,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[
                r"Programs\Microsoft VS Code Insiders\Code - Insiders.exe",
                r"Microsoft VS Code Insiders\Code - Insiders.exe",
            ],
            executable_names: &["Code - Insiders.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "cursor",
        display_name: "Cursor",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Cursor,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Programs\Cursor\Cursor.exe", r"Cursor\Cursor.exe"],
            executable_names: &["Cursor.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "zed",
        display_name: "Zed",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Zed,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Programs\Zed\Zed.exe", r"Zed\Zed.exe"],
            executable_names: &["Zed.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "windsurf",
        display_name: "Windsurf",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Windsurf,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Programs\Windsurf\Windsurf.exe", r"Windsurf\Windsurf.exe"],
            executable_names: &["Windsurf.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "antigravity",
        display_name: "Antigravity",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Antigravity,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[
                r"Programs\Antigravity\Antigravity.exe",
                r"Antigravity\Antigravity.exe",
            ],
            executable_names: &["Antigravity.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "codex",
        display_name: "Codex",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Codex,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Programs\Codex\Codex.exe", r"Codex\Codex.exe"],
            executable_names: &["Codex.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "claude",
        display_name: "Claude",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Claude,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Programs\Claude\Claude.exe", r"Claude\Claude.exe"],
            executable_names: &["Claude.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "finder",
        display_name: "File Explorer",
        kind: OpenWithTargetKind::FileManager,
        built_in_id: OpenWithBuiltInTargetId::Finder,
        path_kind: BuiltInPathKind::AlwaysAvailable,
    },
    OpenWithBuiltInSpec {
        stable_id: "xcode",
        display_name: "Xcode",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Xcode,
        path_kind: BuiltInPathKind::Unavailable,
    },
    OpenWithBuiltInSpec {
        stable_id: "android-studio",
        display_name: "Android Studio",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::AndroidStudio,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[r"Android\Android Studio\bin\studio64.exe"],
            executable_names: &["studio64.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "intellij-idea",
        display_name: "IntelliJ IDEA",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::IntellijIdea,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "IntelliJ IDEA",
            executable_name: "idea64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "rider",
        display_name: "Rider",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Rider,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "Rider",
            executable_name: "rider64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "goland",
        display_name: "GoLand",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Goland,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "GoLand",
            executable_name: "goland64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "rustrover",
        display_name: "RustRover",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Rustrover,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "RustRover",
            executable_name: "rustrover64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "pycharm",
        display_name: "PyCharm",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Pycharm,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "PyCharm",
            executable_name: "pycharm64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "webstorm",
        display_name: "WebStorm",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Webstorm,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "WebStorm",
            executable_name: "webstorm64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "phpstorm",
        display_name: "PhpStorm",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Phpstorm,
        path_kind: BuiltInPathKind::JetBrains {
            product_prefix: "PhpStorm",
            executable_name: "phpstorm64.exe",
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "sublime-text",
        display_name: "Sublime Text",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::SublimeText,
        path_kind: BuiltInPathKind::Standard {
            relative_paths: &[
                r"Sublime Text\sublime_text.exe",
                r"Sublime Text 4\sublime_text.exe",
            ],
            executable_names: &["sublime_text.exe"],
        },
    },
    OpenWithBuiltInSpec {
        stable_id: "bbedit",
        display_name: "BBEdit",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Bbedit,
        path_kind: BuiltInPathKind::Unavailable,
    },
    OpenWithBuiltInSpec {
        stable_id: "textmate",
        display_name: "TextMate",
        kind: OpenWithTargetKind::Editor,
        built_in_id: OpenWithBuiltInTargetId::Textmate,
        path_kind: BuiltInPathKind::Unavailable,
    },
];

fn resolve_built_in_app_path(
    spec: &OpenWithBuiltInSpec,
    environment: &OpenWithDiscoveryEnvironment,
) -> Option<Option<String>> {
    match spec.path_kind {
        BuiltInPathKind::AlwaysAvailable => Some(None),
        BuiltInPathKind::Unavailable => None,
        BuiltInPathKind::Standard {
            relative_paths,
            executable_names,
        } => find_standard_app_path(environment, relative_paths, executable_names)
            .map(|path| Some(path.to_string_lossy().into_owned())),
        BuiltInPathKind::JetBrains {
            product_prefix,
            executable_name,
        } => find_jetbrains_app_path(environment, product_prefix, executable_name)
            .map(|path| Some(path.to_string_lossy().into_owned())),
    }
}

fn find_standard_app_path(
    environment: &OpenWithDiscoveryEnvironment,
    relative_paths: &[&str],
    executable_names: &[&str],
) -> Option<PathBuf> {
    let roots = environment
        .local_app_data
        .iter()
        .chain(environment.program_files.iter());

    for root in roots {
        for relative_path in relative_paths {
            let candidate = root.join(relative_path);
            if path_is_readable_file(&candidate) {
                return Some(candidate);
            }
        }
    }

    find_on_path(environment, executable_names)
}

fn find_on_path(
    environment: &OpenWithDiscoveryEnvironment,
    executable_names: &[&str],
) -> Option<PathBuf> {
    for path_entry in &environment.path_entries {
        for executable_name in executable_names {
            let candidate = path_entry.join(executable_name);
            if path_is_readable_file(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

fn find_jetbrains_app_path(
    environment: &OpenWithDiscoveryEnvironment,
    product_prefix: &str,
    executable_name: &str,
) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    for root in &environment.program_files {
        let jetbrains_root = root.join("JetBrains");
        let Ok(entries) = fs::read_dir(jetbrains_root) else {
            continue;
        };
        for entry in entries.flatten() {
            let product_name = entry.file_name().to_string_lossy().into_owned();
            if !product_name.starts_with(product_prefix) {
                continue;
            }
            let candidate = entry.path().join("bin").join(executable_name);
            if path_is_readable_file(&candidate) {
                candidates.push(candidate);
            }
        }
    }
    candidates.sort();
    candidates.into_iter().next()
}

fn path_is_readable_file(path: impl AsRef<Path>) -> bool {
    path.as_ref()
        .metadata()
        .map(|metadata| metadata.is_file())
        .unwrap_or(false)
}

fn promote_primary_target(
    mut targets: Vec<OpenWithResolvedTarget>,
    primary_target_id: &str,
) -> Vec<OpenWithResolvedTarget> {
    if let Some(index) = targets
        .iter()
        .position(|target| target.stable_id == primary_target_id)
    {
        let primary = targets.remove(index);
        targets.insert(0, primary);
    }
    targets
}
