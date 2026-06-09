use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TmuxCompatArguments {
    values_by_flag: HashMap<String, String>,
    flags: HashSet<String>,
    pub positionals: Vec<String>,
}

impl TmuxCompatArguments {
    pub fn parse<I, V, B>(arguments: I, value_flags: V, bool_flags: B) -> Self
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
        V: IntoIterator,
        V::Item: AsRef<str>,
        B: IntoIterator,
        B::Item: AsRef<str>,
    {
        let arguments: Vec<String> = arguments
            .into_iter()
            .map(|value| value.as_ref().to_string())
            .collect();
        let value_flags: HashSet<String> = value_flags
            .into_iter()
            .map(|value| value.as_ref().to_string())
            .collect();
        let bool_flags: HashSet<String> = bool_flags
            .into_iter()
            .map(|value| value.as_ref().to_string())
            .collect();
        let mut values_by_flag = HashMap::new();
        let mut flags = HashSet::new();
        let mut positionals = Vec::new();
        let mut index = 0;

        while index < arguments.len() {
            let argument = &arguments[index];
            if value_flags.contains(argument) {
                if let Some(value) = arguments.get(index + 1) {
                    values_by_flag.insert(argument.clone(), value.clone());
                    index += 2;
                } else {
                    index += 1;
                }
                continue;
            }

            if bool_flags.contains(argument) {
                flags.insert(argument.clone());
                index += 1;
                continue;
            }

            if argument.starts_with('-')
                && !argument.starts_with("--")
                && argument.chars().count() > 2
            {
                let cluster_flags: Vec<String> = argument
                    .chars()
                    .skip(1)
                    .map(|ch| format!("-{ch}"))
                    .collect();
                if cluster_flags.iter().all(|flag| bool_flags.contains(flag)) {
                    flags.extend(cluster_flags);
                    index += 1;
                    continue;
                }
                if let Some(value_flag) = cluster_flags
                    .iter()
                    .find(|flag| value_flags.contains(*flag))
                    && argument.starts_with(value_flag) {
                        values_by_flag
                            .insert(value_flag.clone(), argument[value_flag.len()..].to_string());
                        index += 1;
                        continue;
                    }
            }

            positionals.push(argument.clone());
            index += 1;
        }

        Self {
            values_by_flag,
            flags,
            positionals,
        }
    }

    pub fn value(&self, flag: &str) -> Option<&str> {
        self.values_by_flag.get(flag).map(String::as_str)
    }

    pub fn has_flag(&self, flag: &str) -> bool {
        self.flags.contains(flag)
    }

    pub fn format_template(&self) -> Option<&str> {
        self.value("-F")
    }

    pub fn display_template(&self) -> Option<String> {
        if self.positionals.is_empty() {
            self.format_template().map(ToOwned::to_owned)
        } else {
            Some(self.positionals.join(" "))
        }
    }
}

pub fn send_keys_text<I, S>(arguments: I, standard_input: Option<&str>) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut skip_next = false;
    let mut pieces = Vec::new();
    let mut literal = false;
    for argument in arguments {
        let argument = argument.as_ref();
        if skip_next {
            skip_next = false;
            continue;
        }
        if matches!(argument, "-t" | "-T" | "-N") {
            skip_next = true;
            continue;
        }
        if argument == "-l" {
            literal = true;
            continue;
        }
        if argument.starts_with('-') {
            continue;
        }
        pieces.push(argument.to_string());
    }
    let joined = tmux_send_keys_text(&pieces, literal);
    if joined.is_empty() {
        standard_input.unwrap_or_default().to_string()
    } else {
        joined
    }
}

pub fn launch_command_from_send_keys_text(text: &str) -> Option<String> {
    if !(text.ends_with('\r') || text.ends_with('\n')) {
        return None;
    }
    let command = text[..text.len() - 1].trim();
    if command.is_empty() || command.contains('\r') || command.contains('\n') {
        return None;
    }
    Some(command.to_string())
}

pub fn shell_wrapped_ghostty_command(
    command: &str,
    login_shell_path: Option<&str>,
) -> Option<String> {
    let trimmed = command.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(shell_path) = login_shell_path
        .map(str::trim)
        .filter(|value| !value.is_empty())
        && is_login_shell_supported(shell_path) {
            return Some(format!(
                "{} -lic {}",
                shell_quote(shell_path),
                shell_quote(trimmed)
            ));
        }
    Some(format!("sh -c {}", shell_quote(trimmed)))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapturePaneOptions {
    pub target: Option<String>,
    pub print: bool,
    pub include_scrollback: bool,
    pub line_limit: Option<usize>,
}

pub fn capture_pane_options<I, S>(arguments: I) -> CapturePaneOptions
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let parsed = TmuxCompatArguments::parse(arguments, ["-E", "-S", "-t"], ["-J", "-N", "-p"]);
    let line_limit = parsed
        .value("-S")
        .and_then(|value| value.parse::<isize>().ok())
        .filter(|start| *start < 0)
        .map(|start| start.unsigned_abs());
    CapturePaneOptions {
        target: parsed.value("-t").map(ToOwned::to_owned),
        print: parsed.has_flag("-p"),
        include_scrollback: true,
        line_limit,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TmuxWaitAction {
    Signal(String),
    Wait { name: String, timeout: f64 },
    Invalid,
}

pub fn wait_for_action<I, S>(arguments: I) -> TmuxWaitAction
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let parsed = TmuxCompatArguments::parse(arguments, ["--timeout"], ["-S", "--signal"]);
    let Some(name) = parsed.positionals.first() else {
        return TmuxWaitAction::Invalid;
    };
    if parsed.has_flag("-S") || parsed.has_flag("--signal") {
        return TmuxWaitAction::Signal(name.clone());
    }
    let timeout = parsed
        .value("--timeout")
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| *value > 0.0)
        .unwrap_or(30.0);
    TmuxWaitAction::Wait {
        name: name.clone(),
        timeout,
    }
}

pub fn show_options_stdout<I, S>(arguments: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let parsed = TmuxCompatArguments::parse(arguments, ["-t"], ["-A", "-g", "-v", "-w"]);
    let Some(option_name) = parsed.positionals.last().filter(|value| !value.is_empty()) else {
        return String::new();
    };
    let value = tmux_option_value(option_name);
    if parsed.has_flag("-v") {
        format!("{value}\n")
    } else {
        format!("{option_name} {value}\n")
    }
}

pub fn tail_terminal_lines(text: &str, max_lines: usize) -> String {
    if max_lines == 0 {
        return String::new();
    }
    let had_trailing_newline = text.ends_with('\n');
    let mut lines: Vec<&str> = text.split('\n').collect();
    if had_trailing_newline && lines.last() == Some(&"") {
        lines.pop();
    }
    let start = lines.len().saturating_sub(max_lines);
    let mut output = lines[start..].join("\n");
    if had_trailing_newline && !output.is_empty() {
        output.push('\n');
    }
    output
}

fn tmux_send_keys_text(tokens: &[String], literal: bool) -> String {
    if literal {
        return tokens.join(" ");
    }

    let mut result = String::new();
    let mut pending_space = false;
    for token in tokens {
        if let Some(special) = tmux_special_key_text(token) {
            result.push_str(special);
            pending_space = false;
            continue;
        }
        if pending_space {
            result.push(' ');
        }
        result.push_str(token);
        pending_space = true;
    }
    result
}

fn tmux_special_key_text(token: &str) -> Option<&'static str> {
    match token.to_lowercase().as_str() {
        "enter" | "c-m" | "kpenter" => Some("\r"),
        "tab" | "c-i" => Some("\t"),
        "space" => Some(" "),
        "bspace" | "backspace" => Some("\u{7f}"),
        "escape" | "esc" | "c-[" => Some("\u{1b}"),
        "c-c" => Some("\u{03}"),
        "c-d" => Some("\u{04}"),
        "c-z" => Some("\u{1a}"),
        "c-l" => Some("\u{0c}"),
        _ => None,
    }
}

fn is_login_shell_supported(shell_path: &str) -> bool {
    matches!(
        shell_path.rsplit(['/', '\\']).next(),
        Some("zsh" | "bash" | "fish")
    )
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn tmux_option_value(name: &str) -> &'static str {
    match name {
        "focus-events" | "mouse" | "synchronize-panes" => "off",
        _ => "",
    }
}
