use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::command_palette::{TaskRunnerAction, TaskRunnerDisabledReason, TaskRunnerSourceKind};

#[derive(Clone, Debug, Default)]
pub struct TaskRunnerDiscoveryService;

impl TaskRunnerDiscoveryService {
    pub fn new() -> Self {
        Self
    }

    pub fn discover(&self, focused_working_directory: impl AsRef<Path>) -> Vec<TaskRunnerAction> {
        let focused_working_directory = focused_working_directory.as_ref();
        let focused_working_directory_string = path_string(focused_working_directory);
        let actions = ancestry_directories(focused_working_directory)
            .into_iter()
            .flat_map(|source_root| {
                TaskRunnerSourceScanner::new(source_root, focused_working_directory_string.clone())
                    .scan()
            })
            .collect::<Vec<_>>();
        uniqued_actions(actions)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskRunnerShellActivityState {
    Unknown,
    PromptIdle,
    CommandRunning,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskRunnerFocusedPaneState {
    pub pane_id: String,
    pub runtime_available: bool,
    pub shell_activity_state: TaskRunnerShellActivityState,
    pub terminal_progress_indicates_activity: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TaskRunnerExecutionPlan {
    OpenSource {
        source_path: String,
    },
    FocusedPane {
        pane_id: String,
        command: String,
    },
    NewPane {
        command: String,
        working_directory: String,
        environment: BTreeMap<String, String>,
    },
}

pub struct TaskRunnerExecutionPlanner;

impl TaskRunnerExecutionPlanner {
    pub fn plan(
        action: &TaskRunnerAction,
        focused_pane: Option<&TaskRunnerFocusedPaneState>,
    ) -> TaskRunnerExecutionPlan {
        if !action.is_enabled() {
            return TaskRunnerExecutionPlan::OpenSource {
                source_path: action.source_path.clone(),
            };
        }

        if action.environment.is_empty()
            && let Some(focused_pane) = focused_pane
                && focused_pane.runtime_available
                    && focused_pane.shell_activity_state == TaskRunnerShellActivityState::PromptIdle
                    && !focused_pane.terminal_progress_indicates_activity
                {
                    return TaskRunnerExecutionPlan::FocusedPane {
                        pane_id: focused_pane.pane_id.clone(),
                        command: action.execution_command.clone(),
                    };
                }

        TaskRunnerExecutionPlan::NewPane {
            command: action.execution_command.clone(),
            working_directory: action.working_directory.clone(),
            environment: action.environment.clone(),
        }
    }
}

struct TaskRunnerSourceScanner {
    source_root: PathBuf,
    focused_working_directory: String,
}

impl TaskRunnerSourceScanner {
    fn new(source_root: PathBuf, focused_working_directory: String) -> Self {
        Self {
            source_root,
            focused_working_directory,
        }
    }

    fn scan(&self) -> Vec<TaskRunnerAction> {
        let mut actions = Vec::new();
        actions.extend(self.scan_package_scripts());
        actions.extend(self.scan_taskfile());
        actions.extend(self.scan_vscode_tasks());
        actions.extend(self.scan_justfile());
        actions.extend(self.scan_makefile());
        actions.extend(self.scan_mise());
        actions
    }

    fn scan_package_scripts(&self) -> Vec<TaskRunnerAction> {
        let source_path = self.source_root.join("package.json");
        if !source_path.is_file() {
            return Vec::new();
        }

        let Ok(data) = fs::read_to_string(&source_path) else {
            return Vec::new();
        };
        let Ok(value) = serde_json::from_str::<Value>(&data) else {
            return Vec::new();
        };
        let Some(object) = value.as_object() else {
            return Vec::new();
        };
        let Some(scripts) = object.get("scripts").and_then(Value::as_object) else {
            return Vec::new();
        };

        let runner = package_runner(&self.source_root, &value);
        let mut actions = scripts
            .iter()
            .filter_map(|(title, script)| {
                script.as_str()?;
                let execution_command = format!("{} run {}", runner, quote_shell_word(title));
                Some(self.action(
                    title,
                    None,
                    TaskRunnerSourceKind::PackageScript,
                    &source_path,
                    execution_command,
                    BTreeMap::new(),
                    None,
                ))
            })
            .collect::<Vec<_>>();
        actions.sort_by(|lhs, rhs| lhs.title.cmp(&rhs.title));
        actions
    }

    fn scan_taskfile(&self) -> Vec<TaskRunnerAction> {
        let Some(source_path) = ["Taskfile.yml", "Taskfile.yaml"]
            .into_iter()
            .map(|name| self.source_root.join(name))
            .find(|path| path.is_file())
        else {
            return Vec::new();
        };
        let Some(root) = parse_taskfile(&source_path) else {
            return Vec::new();
        };

        let mut actions = self.taskfile_actions(&root.tasks, None, &source_path, None);
        for include in root.includes {
            let Some(include_path) = resolved_taskfile_include(&include.path, &self.source_root)
            else {
                continue;
            };
            let Some(included) = parse_taskfile(&include_path) else {
                continue;
            };
            actions.extend(self.taskfile_actions(
                &included.tasks,
                Some(&include.alias),
                &include_path,
                Some(&include.alias),
            ));
        }
        actions
    }

    fn taskfile_actions(
        &self,
        tasks: &[ParsedTaskfileTask],
        title_prefix: Option<&str>,
        source_path: &Path,
        command_prefix: Option<&str>,
    ) -> Vec<TaskRunnerAction> {
        tasks
            .iter()
            .filter(|task| !task.name.starts_with('_'))
            .map(|task| {
                let title = join_colon(title_prefix, &task.name);
                let command_target = join_colon(command_prefix, &task.name);
                let command = format!("task {}", quote_shell_word(&command_target));
                let disabled_reason = (!task.required_variables.is_empty()).then(|| {
                    TaskRunnerDisabledReason::unsupported(format!(
                        "Task requires variables: {}",
                        task.required_variables.join(", ")
                    ))
                });
                self.action(
                    &title,
                    task.description.clone(),
                    TaskRunnerSourceKind::Taskfile,
                    source_path,
                    command,
                    BTreeMap::new(),
                    disabled_reason,
                )
            })
            .collect()
    }

    fn scan_vscode_tasks(&self) -> Vec<TaskRunnerAction> {
        let source_path = self.source_root.join(".vscode/tasks.json");
        if !source_path.is_file() {
            return Vec::new();
        }
        let Ok(data) = fs::read_to_string(&source_path) else {
            return Vec::new();
        };
        let relaxed = strip_json_trailing_commas(&strip_json_comments(&data));
        let Ok(value) = serde_json::from_str::<Value>(&relaxed) else {
            return Vec::new();
        };
        let Some(tasks) = value.get("tasks").and_then(Value::as_array) else {
            return Vec::new();
        };

        tasks
            .iter()
            .filter_map(|raw_task| {
                let task = merge_vscode_task(raw_task.as_object()?);
                let title = task.get("label").and_then(Value::as_str)?;
                if title.is_empty() {
                    return None;
                }
                let Some(command_text) = task.get("command").and_then(Value::as_str) else {
                    return Some(self.action(
                        title,
                        None,
                        TaskRunnerSourceKind::VscodeTask,
                        &source_path,
                        String::new(),
                        BTreeMap::new(),
                        Some(TaskRunnerDisabledReason::unsupported(
                            "VS Code task has no runnable command",
                        )),
                    ));
                };
                if command_text.is_empty() {
                    return Some(self.action(
                        title,
                        None,
                        TaskRunnerSourceKind::VscodeTask,
                        &source_path,
                        String::new(),
                        BTreeMap::new(),
                        Some(TaskRunnerDisabledReason::unsupported(
                            "VS Code task has no runnable command",
                        )),
                    ));
                }

                let args = task
                    .get("args")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_string)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let environment = vscode_environment(&task);
                let raw_command = std::iter::once(command_text.to_string())
                    .chain(args.iter().map(|arg| quote_shell_word(arg)))
                    .collect::<Vec<_>>()
                    .join(" ");
                let variable_issue = unsupported_vscode_variable(
                    std::iter::once(command_text.to_string())
                        .chain(args.iter().cloned())
                        .collect::<Vec<_>>()
                        .as_slice(),
                )
                .or_else(|| {
                    unsupported_vscode_variable(
                        environment
                            .iter()
                            .map(|(key, value)| format!("{key}={value}"))
                            .collect::<Vec<_>>()
                            .as_slice(),
                    )
                });
                let disabled_reason = variable_issue.map(TaskRunnerDisabledReason::unsupported);
                Some(self.action(
                    title,
                    None,
                    TaskRunnerSourceKind::VscodeTask,
                    &source_path,
                    self.resolve_vscode_variables(&raw_command),
                    environment,
                    disabled_reason,
                ))
            })
            .collect()
    }

    fn scan_justfile(&self) -> Vec<TaskRunnerAction> {
        let Some(source_path) = ["justfile", ".justfile", "Justfile"]
            .into_iter()
            .map(|name| self.source_root.join(name))
            .find(|path| path.is_file())
        else {
            return Vec::new();
        };
        let Ok(contents) = fs::read_to_string(&source_path) else {
            return Vec::new();
        };

        contents
            .lines()
            .filter_map(parse_just_recipe)
            .filter(|recipe| !recipe.name.starts_with('_'))
            .map(|recipe| {
                let command = format!("just {}", quote_shell_word(&recipe.name));
                let disabled_reason = (!recipe.parameters.is_empty()).then(|| {
                    TaskRunnerDisabledReason::unsupported(format!(
                        "Task requires parameters: {}",
                        recipe.parameters.join(", ")
                    ))
                });
                self.action(
                    &recipe.name,
                    None,
                    TaskRunnerSourceKind::Justfile,
                    &source_path,
                    command,
                    BTreeMap::new(),
                    disabled_reason,
                )
            })
            .collect()
    }

    fn scan_makefile(&self) -> Vec<TaskRunnerAction> {
        let Some(source_path) = ["Makefile", "makefile"]
            .into_iter()
            .map(|name| self.source_root.join(name))
            .find(|path| path.is_file())
        else {
            return Vec::new();
        };
        let Ok(contents) = fs::read_to_string(&source_path) else {
            return Vec::new();
        };

        parse_make_targets(contents.lines())
            .into_iter()
            .map(|target| {
                let command = format!("make {}", quote_shell_word(&target.name));
                self.action(
                    &target.name,
                    target.description,
                    TaskRunnerSourceKind::Makefile,
                    &source_path,
                    command,
                    BTreeMap::new(),
                    None,
                )
            })
            .collect()
    }

    fn scan_mise(&self) -> Vec<TaskRunnerAction> {
        let mut actions = Vec::new();
        let toml_path = self.source_root.join("mise.toml");
        if toml_path.is_file() {
            actions.extend(parse_mise_toml_tasks(&toml_path).into_iter().map(|task| {
                let command = format!("mise run {}", quote_shell_word(&task.name));
                self.action(
                    &task.name,
                    task.description,
                    TaskRunnerSourceKind::Mise,
                    &toml_path,
                    command,
                    BTreeMap::new(),
                    None,
                )
            }));
        }

        for task_directory in [
            self.source_root.join("mise-tasks"),
            self.source_root.join(".mise/tasks"),
        ] {
            let Ok(entries) = fs::read_dir(task_directory) else {
                continue;
            };
            let mut files = entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| path.is_file())
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| !name.starts_with('.'))
                })
                .collect::<Vec<_>>();
            files.sort_by_key(|path| path.file_name().map(|name| name.to_os_string()));
            actions.extend(files.into_iter().filter_map(|source_path| {
                let name = source_path
                    .file_stem()
                    .and_then(|name| name.to_str())?
                    .to_string();
                let command = format!("mise run {}", quote_shell_word(&name));
                Some(self.action(
                    &name,
                    None,
                    TaskRunnerSourceKind::Mise,
                    &source_path,
                    command,
                    BTreeMap::new(),
                    None,
                ))
            }));
        }

        actions
    }

    #[allow(clippy::too_many_arguments)] // cohesive action descriptor; splitting into a struct adds no clarity
    fn action(
        &self,
        title: &str,
        description: Option<String>,
        source_kind: TaskRunnerSourceKind,
        source_path: &Path,
        execution_command: String,
        environment: BTreeMap<String, String>,
        disabled_reason: Option<TaskRunnerDisabledReason>,
    ) -> TaskRunnerAction {
        let source_path = path_string(source_path);
        let source_root = path_string(&self.source_root);
        let id = format!("{}|{}|{}", source_kind.raw_value(), source_path, title);
        let mut action = TaskRunnerAction::new(
            id,
            title,
            description.as_deref(),
            source_kind,
            source_path,
            execution_command,
            disabled_reason,
        )
        .with_source_root(source_root.clone())
        .with_working_directory(source_root);
        for (key, value) in environment {
            action = action.with_environment(key, value);
        }
        action
    }

    fn resolve_vscode_variables(&self, value: &str) -> String {
        value
            .replace("${workspaceFolder}", &path_string(&self.source_root))
            .replace("${cwd}", &self.focused_working_directory)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedTaskfileTask {
    name: String,
    description: Option<String>,
    required_variables: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedTaskfileInclude {
    alias: String,
    path: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedTaskfile {
    tasks: Vec<ParsedTaskfileTask>,
    includes: Vec<ParsedTaskfileInclude>,
}

fn parse_taskfile(path: &Path) -> Option<ParsedTaskfile> {
    let contents = fs::read_to_string(path).ok()?;
    let mut tasks = Vec::<ParsedTaskfileTask>::new();
    let mut includes = Vec::<ParsedTaskfileInclude>::new();
    let mut section: Option<String> = None;
    let mut current_task_index: Option<usize> = None;
    let mut current_include_alias: Option<String> = None;
    let mut in_requires = false;
    let mut reading_requires_vars = false;

    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let indent = line
            .chars()
            .take_while(|character| *character == ' ')
            .count();
        if indent <= 6 {
            reading_requires_vars = false;
        }

        if indent == 0 && trimmed.ends_with(':') {
            section = Some(trimmed.trim_end_matches(':').to_string());
            current_task_index = None;
            current_include_alias = None;
            in_requires = false;
            reading_requires_vars = false;
            continue;
        }

        match section.as_deref() {
            Some("includes") => {
                if indent == 2 {
                    if let Some((key, value)) = yaml_key_value(trimmed) {
                        current_include_alias = Some(key.clone());
                        if !value.is_empty() {
                            let include_path = yaml_inline_map_value(&value, "taskfile")
                                .or_else(|| yaml_inline_map_value(&value, "dir"))
                                .unwrap_or_else(|| stripped_yaml_scalar(&value));
                            includes.push(ParsedTaskfileInclude {
                                alias: key,
                                path: include_path,
                            });
                        }
                    }
                    continue;
                }

                if indent == 4
                    && let (Some(alias), Some((key, value))) =
                        (current_include_alias.as_ref(), yaml_key_value(trimmed))
                        && (key == "taskfile" || key == "dir") {
                            includes.push(ParsedTaskfileInclude {
                                alias: alias.clone(),
                                path: stripped_yaml_scalar(&value),
                            });
                        }
            }
            Some("tasks") => {
                if indent == 2 && trimmed.ends_with(':') {
                    tasks.push(ParsedTaskfileTask {
                        name: trimmed.trim_end_matches(':').to_string(),
                        description: None,
                        required_variables: Vec::new(),
                    });
                    current_task_index = tasks.len().checked_sub(1);
                    current_include_alias = None;
                    in_requires = false;
                    continue;
                }

                let Some(task_index) = current_task_index else {
                    continue;
                };
                if indent == 4
                    && let Some((key, value)) = yaml_key_value(trimmed) {
                        match key.as_str() {
                            "desc" | "summary" => {
                                tasks[task_index].description = Some(stripped_yaml_scalar(&value));
                            }
                            "requires" => in_requires = true,
                            _ => {
                                in_requires = false;
                                reading_requires_vars = false;
                            }
                        }
                        continue;
                    }

                if indent == 6 && in_requires
                    && let Some((key, value)) = yaml_key_value(trimmed)
                        && key == "vars" {
                            tasks[task_index].required_variables = parse_yaml_inline_array(&value);
                            reading_requires_vars = value.is_empty();
                            continue;
                        }

                if indent == 8 && reading_requires_vars && trimmed.starts_with("- ") {
                    let name = stripped_yaml_scalar(trimmed.trim_start_matches("- ").trim());
                    if !name.is_empty() {
                        tasks[task_index].required_variables.push(name);
                    }
                }
            }
            _ => {}
        }
    }

    Some(ParsedTaskfile { tasks, includes })
}

fn yaml_key_value(line: &str) -> Option<(String, String)> {
    let (key, value) = line.split_once(':')?;
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    Some((key.to_string(), value.trim().to_string()))
}

fn stripped_yaml_scalar(value: &str) -> String {
    value.trim_matches(['"', '\'']).to_string()
}

fn yaml_inline_map_value(value: &str, key: &str) -> Option<String> {
    let trimmed = value.trim();
    if !trimmed.starts_with('{') || !trimmed.ends_with('}') {
        return None;
    }
    trimmed
        .trim_start_matches('{')
        .trim_end_matches('}')
        .split(',')
        .filter_map(|entry| {
            let (observed_key, raw_value) = entry.split_once(':')?;
            (observed_key.trim() == key).then(|| stripped_yaml_scalar(raw_value.trim()))
        })
        .next()
}

fn parse_yaml_inline_array(value: &str) -> Vec<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
        return vec![stripped_yaml_scalar(trimmed)];
    }
    trimmed
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(|entry| stripped_yaml_scalar(entry.trim()))
        .filter(|entry| !entry.is_empty())
        .collect()
}

fn resolved_taskfile_include(path: &str, source_root: &Path) -> Option<PathBuf> {
    if path.contains("{{") || path.starts_with("http://") || path.starts_with("https://") {
        return None;
    }
    let requested = Path::new(path);
    let resolved = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        source_root.join(requested)
    };
    if resolved.is_file() {
        return Some(resolved);
    }
    let taskfile_yml = resolved.join("Taskfile.yml");
    if taskfile_yml.is_file() {
        return Some(taskfile_yml);
    }
    let taskfile_yaml = resolved.join("Taskfile.yaml");
    if taskfile_yaml.is_file() {
        return Some(taskfile_yaml);
    }
    None
}

fn merge_vscode_task(task: &Map<String, Value>) -> Map<String, Value> {
    let mut merged = task.clone();
    if let Some(platform) = task
        .get(vscode_platform_override_key())
        .and_then(Value::as_object)
    {
        for (key, value) in platform {
            merged.insert(key.clone(), value.clone());
        }
    }
    merged
}

fn vscode_platform_override_key() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "osx"
    } else {
        "linux"
    }
}

fn vscode_environment(task: &Map<String, Value>) -> BTreeMap<String, String> {
    task.get("options")
        .and_then(Value::as_object)
        .and_then(|options| options.get("env"))
        .and_then(Value::as_object)
        .map(|env| {
            env.iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn unsupported_vscode_variable(values: &[String]) -> Option<String> {
    let supported = ["${workspaceFolder}", "${cwd}"];
    values.iter().find_map(|value| {
        variable_matches(value)
            .into_iter()
            .find(|candidate| !supported.contains(&candidate.as_str()))
            .map(|candidate| format!("Unsupported VS Code variable: {candidate}"))
    })
}

fn variable_matches(value: &str) -> Vec<String> {
    let mut matches = Vec::new();
    let mut remainder = value;
    while let Some(start) = remainder.find("${") {
        let after_start = &remainder[start..];
        let Some(end) = after_start.find('}') else {
            break;
        };
        matches.push(after_start[..=end].to_string());
        remainder = &after_start[end + 1..];
    }
    matches
}

fn strip_json_comments(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    let mut in_string = false;
    let mut escaped = false;
    while let Some(character) = chars.next() {
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }

        if character == '"' {
            in_string = true;
            output.push(character);
            continue;
        }
        if character == '/' && chars.peek() == Some(&'/') {
            chars.next();
            for next in chars.by_ref() {
                if next == '\n' {
                    output.push('\n');
                    break;
                }
            }
            continue;
        }
        if character == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut previous = '\0';
            for next in chars.by_ref() {
                if previous == '*' && next == '/' {
                    break;
                }
                previous = next;
            }
            continue;
        }
        output.push(character);
    }
    output
}

fn strip_json_trailing_commas(value: &str) -> String {
    let mut output = String::new();
    let chars = value.chars().collect::<Vec<_>>();
    let mut index = 0;
    let mut in_string = false;
    let mut escaped = false;
    while index < chars.len() {
        let character = chars[index];
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if character == '"' {
            in_string = true;
            output.push(character);
            index += 1;
            continue;
        }
        if character == ',' {
            let next_significant = chars[index + 1..]
                .iter()
                .copied()
                .find(|candidate| !candidate.is_whitespace());
            if matches!(next_significant, Some(']') | Some('}')) {
                index += 1;
                continue;
            }
        }
        output.push(character);
        index += 1;
    }
    output
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct JustRecipe {
    name: String,
    parameters: Vec<String>,
}

fn parse_just_recipe(line: &str) -> Option<JustRecipe> {
    if line.chars().next().is_some_and(char::is_whitespace) || line.trim_start().starts_with('#') {
        return None;
    }
    let (header, _) = line.split_once(':')?;
    let mut parts = header.split_whitespace().map(str::to_string);
    let name = parts.next()?;
    if name.is_empty() {
        return None;
    }
    Some(JustRecipe {
        name,
        parameters: parts.collect(),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MakeTarget {
    name: String,
    description: Option<String>,
}

fn parse_make_targets<'a>(lines: impl IntoIterator<Item = &'a str>) -> Vec<MakeTarget> {
    let mut phony_order = Vec::<String>::new();
    let mut descriptions = HashMap::<String, String>::new();
    let mut explicit_help_order = Vec::<String>::new();

    for line in lines {
        if let Some(rest) = line.strip_prefix(".PHONY:") {
            phony_order.extend(rest.split_whitespace().map(str::to_string));
            continue;
        }
        if line.chars().next().is_some_and(char::is_whitespace) {
            continue;
        }
        let Some((name, _)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty() || name.contains(' ') {
            continue;
        }
        if let Some((_, description)) = line.split_once("##") {
            descriptions.insert(name.to_string(), description.trim().to_string());
            explicit_help_order.push(name.to_string());
        }
    }

    removing_duplicates(phony_order.into_iter().chain(explicit_help_order))
        .into_iter()
        .map(|name| MakeTarget {
            description: descriptions.get(&name).cloned(),
            name,
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MiseTask {
    name: String,
    description: Option<String>,
}

fn parse_mise_toml_tasks(path: &Path) -> Vec<MiseTask> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut tasks = Vec::<MiseTask>::new();
    let mut current_name: Option<String> = None;
    let mut current_description: Option<String> = None;
    let mut section: Option<String> = None;

    fn flush(
        tasks: &mut Vec<MiseTask>,
        current_name: &mut Option<String>,
        current_description: &mut Option<String>,
    ) {
        if let Some(name) = current_name.take() {
            tasks.push(MiseTask {
                name,
                description: current_description.take(),
            });
        }
    }

    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("[tasks.") && trimmed.ends_with(']') {
            flush(&mut tasks, &mut current_name, &mut current_description);
            current_name = Some(
                trimmed
                    .trim_start_matches("[tasks.")
                    .trim_end_matches(']')
                    .to_string(),
            );
            current_description = None;
            section = None;
            continue;
        }
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            flush(&mut tasks, &mut current_name, &mut current_description);
            current_name = None;
            current_description = None;
            section = Some(
                trimmed
                    .trim_start_matches('[')
                    .trim_end_matches(']')
                    .to_string(),
            );
            continue;
        }
        if section.as_deref() == Some("tasks") {
            if let Some((name, _)) = trimmed.split_once('=') {
                let name = name.trim();
                if !name.is_empty() {
                    tasks.push(MiseTask {
                        name: name.to_string(),
                        description: None,
                    });
                }
            }
            continue;
        }
        if current_name.as_deref().is_some_and(|name| !name.is_empty())
            && trimmed.starts_with("description")
            && let Some((_, value)) = trimmed.split_once('=') {
                current_description = Some(value.trim().trim_matches(['"', '\'']).to_string());
            }
    }
    flush(&mut tasks, &mut current_name, &mut current_description);
    tasks
}

fn join_colon(prefix: Option<&str>, name: &str) -> String {
    match prefix {
        Some(prefix) => format!("{prefix}:{name}"),
        None => name.to_string(),
    }
}

fn removing_duplicates(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = HashSet::new();
    values
        .into_iter()
        .filter(|value| seen.insert(value.clone()))
        .collect()
}

fn ancestry_directories(focused_working_directory: &Path) -> Vec<PathBuf> {
    let mut directories = Vec::new();
    let mut current = if focused_working_directory.is_file() {
        focused_working_directory
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| focused_working_directory.to_path_buf())
    } else {
        focused_working_directory.to_path_buf()
    };

    loop {
        directories.push(current.clone());
        if current.join(".git").exists() {
            break;
        }
        let Some(parent) = current.parent().map(Path::to_path_buf) else {
            break;
        };
        if parent == current || directories.len() >= 16 {
            break;
        }
        current = parent;
    }

    directories
}

fn package_runner(source_root: &Path, package_json: &Value) -> &'static str {
    if let Some(name) = package_json
        .get("packageManager")
        .and_then(Value::as_str)
        .and_then(|package_manager| package_manager.split('@').next())
        .filter(|name| matches!(*name, "pnpm" | "yarn" | "bun" | "npm"))
    {
        return match name {
            "pnpm" => "pnpm",
            "yarn" => "yarn",
            "bun" => "bun",
            "npm" => "npm",
            _ => "npm",
        };
    }

    [
        ("pnpm-lock.yaml", "pnpm"),
        ("yarn.lock", "yarn"),
        ("bun.lockb", "bun"),
        ("bun.lock", "bun"),
        ("package-lock.json", "npm"),
    ]
    .into_iter()
    .find_map(|(lockfile, runner)| source_root.join(lockfile).is_file().then_some(runner))
    .unwrap_or("npm")
}

fn quote_shell_word(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    if value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "_@%+=:,./-".contains(character))
    {
        return value.to_string();
    }

    format!("'{}'", value.replace('\'', "'\\''"))
}

fn uniqued_actions(actions: Vec<TaskRunnerAction>) -> Vec<TaskRunnerAction> {
    let mut next_duplicate_index_by_id = HashMap::<String, usize>::new();
    actions
        .into_iter()
        .map(|action| {
            let duplicate_index = next_duplicate_index_by_id
                .entry(action.id.clone())
                .and_modify(|index| *index += 1)
                .or_insert(1);
            if *duplicate_index == 1 {
                action
            } else {
                let id = format!("{}#{}", action.id, duplicate_index);
                action.with_id(id)
            }
        })
        .collect()
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}
