use regex::Regex;

const AGENT_PROMPT_MARKERS: &[char] = &['›', '❯', '•', '⏺', '●'];
const BOX_DRAWING_CLASS: &str = "│┃║╎╏┆┇┊┋╽╿￨｜";
const BORDER_BOX_CLASS: &str = "─━┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╭╮╯╰┏┓┗┛┣┫┳┻╋";
const MAX_AGENT_PROMPT_REFLOW_LINES: usize = 60;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CleanCopyResult {
    pub text: String,
    pub was_modified: bool,
}

pub struct CleanCopyPipeline;

impl CleanCopyPipeline {
    pub fn clean(input: &str) -> CleanCopyResult {
        let mut text = input.to_string();
        text = Self::strip_ansi_escapes(&text);
        text = Self::trim_trailing_whitespace_per_line(&text);
        text = Self::trim_trailing_blank_lines(&text);
        if let Some(cleaned) = Self::strip_agent_prompt_selection(&text) {
            text = cleaned;
        }
        text = Self::strip_prompts(&text);
        text = Self::strip_line_number_prefixes(&text);
        if let Some(cleaned) = Self::strip_box_drawing_artifacts(&text) {
            text = cleaned;
        }
        text = Self::dedent_common_prefix(&text);
        CleanCopyResult {
            text: text.clone(),
            was_modified: text != input,
        }
    }

    pub fn should_clean_terminal_copy_action(
        is_auto_clean_enabled: bool,
        suppress_callback_cleaning: bool,
    ) -> bool {
        is_auto_clean_enabled && !suppress_callback_cleaning
    }

    pub fn strip_ansi_escapes(input: &str) -> String {
        if !input.contains('\x1b') {
            return input.to_string();
        }
        let regex = Regex::new(
            r"\x1B(?:\[[0-9;?]*[A-Za-z]|\][^\x07\x1B]*(?:\x07|\x1B\\)|\([A-Z0-9]|=[^\n]*)",
        )
        .expect("ANSI escape regex should compile");
        regex.replace_all(input, "").to_string()
    }

    pub fn trim_trailing_whitespace_per_line(input: &str) -> String {
        input
            .split('\n')
            .map(|line| line.trim_end_matches([' ', '\t']))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn trim_trailing_blank_lines(input: &str) -> String {
        if input.is_empty() {
            return input.to_string();
        }

        let had_trailing_newline = input.ends_with('\n');
        let mut lines: Vec<&str> = input.split('\n').collect();
        while lines
            .last()
            .is_some_and(|line| line.chars().all(|ch| ch == ' ' || ch == '\t'))
        {
            lines.pop();
        }

        if lines.is_empty() {
            return String::new();
        }

        let mut result = lines.join("\n");
        if had_trailing_newline {
            result.push('\n');
        }
        result
    }

    pub fn strip_prompts(input: &str) -> String {
        let lines: Vec<&str> = input.split('\n').collect();
        let non_empty_lines: Vec<&str> = lines
            .iter()
            .copied()
            .filter(|line| !line.chars().all(char::is_whitespace))
            .collect();
        if non_empty_lines.is_empty() {
            return input.to_string();
        }

        let Some(prompt) = detect_prompt_pattern(&non_empty_lines) else {
            return input.to_string();
        };

        lines
            .into_iter()
            .map(|line| line.strip_prefix(prompt).unwrap_or(line).to_string())
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn strip_agent_prompt_selection(input: &str) -> Option<String> {
        let lines: Vec<String> = input.split('\n').map(str::to_string).collect();
        let non_empty: Vec<&String> = lines
            .iter()
            .filter(|line| !trim_spaces(line).is_empty())
            .collect();
        let first_line = non_empty.first()?;
        let first_trimmed = trim_spaces(first_line);
        let first_character = first_trimmed.chars().next()?;
        if !AGENT_PROMPT_MARKERS.contains(&first_character) {
            return None;
        }
        if non_empty.len() > MAX_AGENT_PROMPT_REFLOW_LINES {
            return None;
        }

        let marker_line_count = non_empty
            .iter()
            .filter(|line| {
                trim_spaces(line)
                    .chars()
                    .next()
                    .is_some_and(|ch| AGENT_PROMPT_MARKERS.contains(&ch))
            })
            .count();
        if marker_line_count > 1 {
            return None;
        }

        let candidate_lines: Vec<String> = if let Some(rule_index) = lines
            .iter()
            .position(|line| is_agent_prompt_rule_line(line))
        {
            lines.into_iter().skip(rule_index + 1).collect()
        } else {
            let mut did_strip_prompt_marker = false;
            lines
                .into_iter()
                .map(|line| {
                    if did_strip_prompt_marker || trim_spaces(&line).is_empty() {
                        return line;
                    }
                    did_strip_prompt_marker = true;
                    strip_leading_agent_prompt_marker(trim_spaces(&line))
                })
                .collect()
        };

        let content_lines = trim_outer_blank_lines(
            candidate_lines
                .iter()
                .map(|line| trim_spaces(line).to_string())
                .collect(),
        );
        let non_empty_content_lines = content_lines.iter().filter(|line| !line.is_empty()).count();
        if non_empty_content_lines == 0 {
            return None;
        }

        let content = content_lines.join("\n");
        if is_likely_source_code(&content)
            || is_likely_list(&content)
            || is_likely_structured_data(&content)
            || is_likely_shell_transcript(&content)
        {
            return None;
        }

        let flattened = flatten_wrapped_prompt_lines(&content_lines);
        (flattened != input).then_some(flattened)
    }

    pub fn strip_line_number_prefixes(input: &str) -> String {
        let lines: Vec<&str> = input.split('\n').collect();
        let non_empty_lines: Vec<&str> = lines
            .iter()
            .copied()
            .filter(|line| !line.chars().all(char::is_whitespace))
            .collect();
        if non_empty_lines.is_empty() {
            return input.to_string();
        }

        let Some(regex) = detect_line_number_pattern(&non_empty_lines) else {
            return input.to_string();
        };

        lines
            .into_iter()
            .map(|line| {
                if regex.is_match(line) {
                    regex.replace(line, "").to_string()
                } else {
                    line.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn strip_box_drawing_artifacts(input: &str) -> Option<String> {
        let box_regex = Regex::new(&format!("[{BOX_DRAWING_CLASS}]")).ok()?;
        let border_regex = Regex::new(&format!("[{BORDER_BOX_CLASS}]")).ok()?;
        if !box_regex.is_match(input) && !border_regex.is_match(input) {
            return None;
        }

        let border_line_regex = Regex::new(&format!(r"^\s*[{BORDER_BOX_CLASS}]{{3,}}\s*$")).ok()?;
        let mut result = input
            .split('\n')
            .filter(|line| !border_line_regex.is_match(line))
            .collect::<Vec<_>>()
            .join("\n");

        result = result.replace("│ │", " ");
        result = regex_replace(
            &result,
            &format!(r"\|[ \t]*[{BOX_DRAWING_CLASS}]+[ \t]*"),
            "| ",
        );
        result = regex_replace(
            &result,
            &format!(r"([:/])[ \t]*[{BOX_DRAWING_CLASS}]+[ \t]*([A-Za-z0-9])"),
            "$1$2",
        );
        result = regex_replace(
            &result,
            &format!(r"(\S)[ \t]*[{BOX_DRAWING_CLASS}]+[ \t]*(\S)"),
            "$1 $2",
        );

        let lines: Vec<String> = result.split('\n').map(str::to_string).collect();
        let non_empty_lines: Vec<&String> = lines
            .iter()
            .filter(|line| !trim_spaces(line).is_empty())
            .collect();
        if !non_empty_lines.is_empty() {
            let leading_regex = Regex::new(&format!(r"^\s*[{BOX_DRAWING_CLASS}]+ ?")).ok()?;
            let trailing_regex = Regex::new(&format!(r" ?[{BOX_DRAWING_CLASS}]+\s*$")).ok()?;
            let majority_threshold = if non_empty_lines.len() == 1 {
                1
            } else {
                non_empty_lines.len() / 2 + 1
            };
            let leading_matches = non_empty_lines
                .iter()
                .filter(|line| leading_regex.is_match(line))
                .count();
            let trailing_matches = non_empty_lines
                .iter()
                .filter(|line| trailing_regex.is_match(line))
                .count();
            let strip_leading = leading_matches >= majority_threshold;
            let strip_trailing = trailing_matches >= majority_threshold;

            if strip_leading || strip_trailing {
                result = lines
                    .into_iter()
                    .map(|line| {
                        let line = if strip_leading {
                            leading_regex.replace(&line, "").to_string()
                        } else {
                            line
                        };
                        if strip_trailing {
                            trailing_regex.replace(&line, "").to_string()
                        } else {
                            line
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
            }
        }

        result = regex_replace(&result, r" {2,}", " ");
        let cleaned = Self::trim_trailing_whitespace_per_line(&result);
        if cleaned.chars().all(char::is_whitespace) && !input.chars().all(char::is_whitespace) {
            return None;
        }
        (cleaned != input).then_some(cleaned)
    }

    pub fn dedent_common_prefix(input: &str) -> String {
        let lines: Vec<&str> = input.split('\n').collect();
        let non_empty_lines: Vec<&str> = lines
            .iter()
            .copied()
            .filter(|line| !line.chars().all(char::is_whitespace))
            .collect();
        if non_empty_lines.is_empty() {
            return input.to_string();
        }

        let min_leading_whitespace = non_empty_lines
            .iter()
            .map(|line| {
                line.chars()
                    .take_while(|ch| *ch == ' ' || *ch == '\t')
                    .count()
            })
            .min()
            .unwrap_or(0);
        if min_leading_whitespace == 0 {
            return input.to_string();
        }

        lines
            .into_iter()
            .map(|line| {
                if line.chars().all(char::is_whitespace) {
                    line.to_string()
                } else {
                    line.chars().skip(min_leading_whitespace).collect()
                }
            })
            .collect::<Vec<String>>()
            .join("\n")
    }
}

fn detect_prompt_pattern(lines: &[&str]) -> Option<&'static str> {
    let candidates = ["$ ", "> ", "# "];
    let line_count = lines.len();
    for candidate in candidates {
        let match_count = lines
            .iter()
            .filter(|line| line.starts_with(candidate))
            .count();

        if line_count <= 3 {
            if lines
                .first()
                .is_some_and(|line| line.starts_with(candidate))
            {
                return Some(candidate);
            }
        } else if match_count > line_count / 2 {
            return Some(candidate);
        }
    }
    None
}

fn strip_leading_agent_prompt_marker(line: &str) -> String {
    line.chars()
        .skip(1)
        .skip_while(|ch| ch.is_whitespace())
        .collect()
}

fn trim_outer_blank_lines(lines: Vec<String>) -> Vec<String> {
    let Some(first_non_empty) = lines.iter().position(|line| !line.is_empty()) else {
        return Vec::new();
    };
    let last_non_empty = lines
        .iter()
        .rposition(|line| !line.is_empty())
        .expect("first non-empty line proves a last non-empty line");
    lines[first_non_empty..=last_non_empty].to_vec()
}

fn is_agent_prompt_rule_line(line: &str) -> bool {
    let trimmed = trim_spaces(line);
    if trimmed.chars().count() < 10 {
        return false;
    }
    let rule_count = trimmed
        .chars()
        .filter(|ch| matches!(ch, '─' | '━' | '—'))
        .count();
    rule_count >= 10 && rule_count == trimmed.chars().count()
}

fn flatten_wrapped_prompt_lines(lines: &[String]) -> String {
    let mut result = String::new();
    let mut paragraph_lines = Vec::new();
    let mut pending_blank_line_count = 0usize;

    for line in lines {
        let trimmed = trim_spaces(line);
        if trimmed.is_empty() {
            append_prompt_paragraph(
                &mut result,
                &mut paragraph_lines,
                &mut pending_blank_line_count,
            );
            pending_blank_line_count += 1;
        } else {
            paragraph_lines.push(trimmed.to_string());
        }
    }

    append_prompt_paragraph(
        &mut result,
        &mut paragraph_lines,
        &mut pending_blank_line_count,
    );
    result
}

fn append_prompt_paragraph(
    result: &mut String,
    paragraph_lines: &mut Vec<String>,
    pending_blank_line_count: &mut usize,
) {
    if paragraph_lines.is_empty() {
        return;
    }

    if !result.is_empty() && *pending_blank_line_count > 0 {
        result.push_str(&"\n".repeat(*pending_blank_line_count + 1));
    }
    result.push_str(&flatten_prompt_paragraph(paragraph_lines));
    paragraph_lines.clear();
    *pending_blank_line_count = 0;
}

fn flatten_prompt_paragraph(lines: &[String]) -> String {
    let mut result = lines.join("\n");
    result = regex_replace(
        &result,
        r"([A-Za-z0-9._~])-\s*\n\s*([A-Za-z0-9._~-])",
        "$1-$2",
    );
    result = regex_replace(
        &result,
        r"([A-Z0-9_])\s*\n\s*([A-Z0-9_.])([A-Z0-9_.])",
        "$1$2$3",
    );
    result = regex_replace(&result, r"([/~])\s*\n\s*([A-Za-z0-9._-])", "$1$2");
    result = regex_replace(&result, r"\\\s*\n", " ");
    result = regex_replace(&result, r"\n+", " ");
    result = regex_replace(&result, r"\s+", " ");
    result.trim_matches(char::is_whitespace).to_string()
}

fn is_likely_source_code(text: &str) -> bool {
    let has_braces =
        text.contains('{') || text.contains('}') || text.to_lowercase().contains("begin");
    let keyword_regex = Regex::new(
        r"(?m)^\s*(import|package|namespace|using|template|class|struct|enum|extension|protocol|interface|func|def|fn|let|var|public|private|internal|open|protected|if|for|while)\b",
    )
    .expect("source keyword regex should compile");
    if has_braces && keyword_regex.is_match(text) {
        return true;
    }

    let code_line_regex = Regex::new(
        r"(?m)^\s*(let|var|await|try|return|guard|func|class|struct|enum|import|extension|protocol)\s+\S",
    )
    .expect("source line regex should compile");
    let punctuation_regex = Regex::new(r"[=(){};]").expect("punctuation regex should compile");
    code_line_regex.is_match(text) && punctuation_regex.is_match(text)
}

fn is_likely_list(text: &str) -> bool {
    let non_empty: Vec<&str> = text
        .split('\n')
        .filter(|line| !trim_spaces(line).is_empty())
        .collect();
    if non_empty.len() < 2 {
        return false;
    }

    let bullet_regex = Regex::new(r"^[-*•]\s+\S").expect("bullet regex should compile");
    let number_regex = Regex::new(r"^[0-9]+[.)]\s+\S").expect("numbered list regex should compile");
    let listish_count = non_empty
        .iter()
        .filter(|line| {
            let trimmed = trim_spaces(line);
            bullet_regex.is_match(trimmed) || number_regex.is_match(trimmed)
        })
        .count();
    listish_count > non_empty.len() / 2
}

fn is_likely_structured_data(text: &str) -> bool {
    let key_regex =
        Regex::new(r#"^["'][^"']+["']\s*:"#).expect("structured key regex should compile");
    text.split('\n').any(|line| {
        let trimmed = trim_spaces(line);
        matches!(trimmed, "{" | "}" | "[" | "]") || key_regex.is_match(trimmed)
    })
}

fn is_likely_shell_transcript(text: &str) -> bool {
    text.split('\n').any(|line| {
        let trimmed = trim_spaces(line);
        trimmed.starts_with("$ ") || trimmed.starts_with("# ") || trimmed.starts_with("% ")
    })
}

fn detect_line_number_pattern(lines: &[&str]) -> Option<Regex> {
    let patterns = [r"^\s*\d+\t", r"^\s*\d+:\s?", r"^\s*\d+\s?[|│┃]\s?"];

    for pattern in patterns {
        let regex = Regex::new(pattern).expect("line number regex should compile");
        let match_count = lines.iter().filter(|line| regex.is_match(line)).count();
        if lines.len() <= 3 {
            if match_count == lines.len() {
                return Some(regex);
            }
        } else {
            let ratio = match_count as f64 / lines.len() as f64;
            if ratio > 0.8 && numbers_are_monotonic(lines, &regex) {
                return Some(regex);
            }
        }
    }
    None
}

fn numbers_are_monotonic(lines: &[&str], regex: &Regex) -> bool {
    let mut last_number = i64::MIN;
    for line in lines {
        let Some(matched) = regex.find(line) else {
            continue;
        };
        let digits: String = matched
            .as_str()
            .chars()
            .filter(char::is_ascii_digit)
            .collect();
        let Ok(number) = digits.parse::<i64>() else {
            continue;
        };
        if number < last_number {
            return false;
        }
        last_number = number;
    }
    true
}

fn regex_replace(input: &str, pattern: &str, replacement: &str) -> String {
    Regex::new(pattern)
        .expect("clean-copy regex should compile")
        .replace_all(input, replacement)
        .to_string()
}

fn trim_spaces(input: &str) -> &str {
    input.trim_matches([' ', '\t'])
}
