const SHELL_SENSITIVE_CHARACTERS: &[char] = &[
    '\\', ' ', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '!', '#', '$', '&', ';',
    '|', '*', '?', '\t', '\n', '\r',
];

pub struct ShellEscaping;

impl ShellEscaping {
    pub fn escape_path(path: &str) -> String {
        let mut escaped = String::with_capacity(path.len());
        for ch in path.chars() {
            if SHELL_SENSITIVE_CHARACTERS.contains(&ch) {
                escaped.push('\\');
            }
            escaped.push(ch);
        }
        escaped
    }
}
