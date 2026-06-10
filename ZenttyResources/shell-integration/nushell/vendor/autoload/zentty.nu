# zentty shell integration for nushell
# Full port of bash/zsh/fish behaviors using native $env.config.hooks (pre_prompt, pre_execution, env_change.PWD)
# Safe: early returns, try/ignore on signals and tty, never mutates user env destructively.
# XDG restore best-effort via env_change (no direct exit hook in autoload; fish uses fish_exit).

if ($env | get -o ZENTTY_NU_INTEGRATION_LOADED | default "") == "1" {
    return
}
$env.ZENTTY_NU_INTEGRATION_LOADED = '1'

# Restore XDG_DATA_DIRS early (Ghostty/Kitty pattern). Vendor autoload discovery
# has already happened by the time this script runs, so stripping our injected
# entry now keeps this session and every child process it spawns clean. Nushell
# has no exit hook, so early restore is the only viable approach.
if ($env | get -o ZENTTY_SHELL_INTEGRATION_XDG_DIR | default '') != '' {
    let zentty_xdg_dir = $env.ZENTTY_SHELL_INTEGRATION_XDG_DIR
    if ($env | get -o XDG_DATA_DIRS | default '') != '' {
        $env.XDG_DATA_DIRS = (
            $env.XDG_DATA_DIRS
            | split row ':'
            | where {|d| $d != '' and $d != $zentty_xdg_dir}
            | str join ':'
        )
    }
    hide-env ZENTTY_SHELL_INTEGRATION_XDG_DIR
}

# Internal bookkeeping that must survive across hook invocations (dedupe keys,
# last-reported pid, the loaded guard above) lives in $env on purpose. Nushell hook
# closures have no non-exported persistent scope — a plain `let`/`mut` would not carry
# from one prompt to the next — so $env is the only place to keep this state. The
# trade-off is that these `_zentty_`-prefixed entries are exported to child processes,
# unlike the non-exported shell vars bash/zsh/fish use. That is harmless: the names are
# namespaced, and XDG_DATA_DIRS is already stripped above so nested shells do not
# re-autoload off the inherited ZENTTY_NU_INTEGRATION_LOADED.
$env._zentty_shell_activity_last = ''

def _zentty_print_tty [sequence: string] {
    let tty_path = ($env.TTY? | default "/dev/tty")
    if ($tty_path | path exists) {
        try { $sequence | save --raw --force $tty_path } | ignore
    }
}

def _zentty_wrapper_binary_candidates [tool_name: string] {
    match $tool_name {
        "cursor" => ["cursor-agent"],
        "kimi" => ["kimi", "kimi-cli"],
        _ => [$tool_name]
    }
}

def _zentty_real_binary_candidates [tool_name: string] {
    _zentty_wrapper_binary_candidates $tool_name
}

def _zentty_is_executable [candidate: string] {
    if $candidate == '' { return false }
    # Native check (no fork). _zentty_ensure_wrapper_path calls this O(wrappers x PATH)
    # times on every pre_prompt and pre_execution; spawning external `test` here cost
    # tens-to-hundreds of ms per prompt (bash/zsh/fish use shell builtins). `path expand`
    # resolves symlinks so we read the real target's mode, matching `test -x` semantics
    # for Homebrew-style symlinked CLIs (nushell's `ls` reports a symlink's own mode,
    # which always carries an x bit). Missing paths fall through try/catch to false.
    try { (ls -l ($candidate | path expand) | get 0.mode | str contains 'x') } catch { false }
}

def _zentty_agent_signal [...args: string] {
    if ($env | get -o ZENTTY_SHELL_INTEGRATION | default '1') == '0' { return }
    if not (($env | get -o ZENTTY_INSTANCE_SOCKET | default '') | is-not-empty) { return }
    if not (($env | get -o ZENTTY_PANE_TOKEN | default '') | is-not-empty) { return }
    mut cli_bin = ($env | get -o ZENTTY_CLI_BIN | default '')
    if $cli_bin == '' or not ($cli_bin | path exists) {
        $cli_bin = (try { which zentty | get 0.path } catch { '' })
    }
    if $cli_bin == '' or not ($cli_bin | path exists) { return }
    try { ^$cli_bin ipc agent-signal ...$args | complete | ignore } | ignore
}

def --env _zentty_report_shell_activity [state: string, ...rest: string] {
    let key = $"($state) ($rest | str join ' ')"
    if ($env | get -o _zentty_shell_activity_last | default '') == $key { return }
    $env._zentty_shell_activity_last = $key
    _zentty_agent_signal "shell-state" $state ...$rest
}

def _zentty_agent_tool_for_command [cmd: string] {
    let c = ($cmd | path basename)
    match $c {
        "amp" => "Amp",
        "claude" => "Claude Code",
        "codex" => "Codex",
        "droid" => "Droid",
        "gemini" => "Gemini",
        "kimi" | "kimi-cli" => "Kimi",
        "opencode" => "OpenCode",
        "pi" => "Pi",
        "agy" => "Antigravity",
        _ => ''
    }
}

def --env _zentty_report_pane_root_pid [] {
    let pid = $nu.pid
    if ($env | get -o _zentty_pane_root_pid_last | default '') == $pid { return }
    $env._zentty_pane_root_pid_last = $pid
    _zentty_agent_signal "pane-root-pid" "attach" ($pid | into string)
}

def _zentty_is_remote_shell [] {
    let c = ($env | get -o SSH_CONNECTION | default '')
    let cl = ($env | get -o SSH_CLIENT | default '')
    let t = ($env | get -o SSH_TTY | default '')
    ($c != '') or ($cl != '') or ($t != '')
}

def _zentty_hostname [] {
    let h = ($env | get -o HOSTNAME | default ($env | get -o HOST | default ''))
    if $h == '' {
        try { ^hostname -s | str trim } catch { try { ^hostname | str trim } catch { "localhost" } }
    } else {
        $h | str replace -r '\..*' ''
    }
}

def --env _zentty_apply_initial_working_directory [] {
    let initial = ($env | get -o ZENTTY_INITIAL_WORKING_DIRECTORY | default '')
    if $initial == '' { return }
    hide-env ZENTTY_INITIAL_WORKING_DIRECTORY
    if (_zentty_is_remote_shell) { return }
    if ($initial | path exists) {
        cd $initial
    }
}

def _zentty_local_git_branch [] {
    try {
        if (^git rev-parse --git-dir | complete).exit_code == 0 {
            ^git branch --show-current | str trim
        } else {
            ''
        }
    } catch { '' }
}

def _zentty_reset_title_to_cwd [] {
    # Anchor to the leading path prefix (port of bash/zsh ${PWD/#$HOME/~}); a plain
    # `str replace` rewrites the first $HOME match anywhere in the path.
    let pwd = $env.PWD
    let home = $env.HOME
    let title = if ($pwd | str starts-with $home) {
        '~' + ($pwd | str substring ($home | str length)..)
    } else {
        $pwd
    }
    _zentty_print_tty $"\e]2;($title)\a"
}

def _zentty_emit_pane_context [] {
    let cwd = ($env.PWD | default '')
    let home = ($env.HOME | default '')
    mut git_branch = ''
    if (_zentty_is_remote_shell) {
        _zentty_agent_signal "pane-context" "remote" "--path" $cwd "--home" $home "--user" ($env.USER? | default '') "--host" (_zentty_hostname) "--git-branch" $git_branch
        return
    }
    $git_branch = (_zentty_local_git_branch)
    _zentty_agent_signal "pane-context" "local" "--path" $cwd "--home" $home "--user" ($env.USER? | default '') "--host" (_zentty_hostname) "--git-branch" $git_branch
}

def _zentty_report_directory_change [] {
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
}

def --env _zentty_ensure_wrapper_path [] {
    mut wrapper_dirs = []
    if ($env | get -o ZENTTY_ALL_WRAPPER_BIN_DIRS | default '') != '' {
        $wrapper_dirs = ($env.ZENTTY_ALL_WRAPPER_BIN_DIRS | split row ':')
    } else if ($env | get -o ZENTTY_WRAPPER_BIN_DIRS | default '') != '' {
        $wrapper_dirs = ($env.ZENTTY_WRAPPER_BIN_DIRS | split row ':')
    } else if ($env | get -o ZENTTY_WRAPPER_BIN_DIR | default '') != '' {
        $wrapper_dirs = [$env.ZENTTY_WRAPPER_BIN_DIR]
    }
    let tmux_shim_dir = ($env | get -o ZENTTY_TMUX_SHIM_DIR | default '')
    mut tmux_shim_enabled = false
    if ($env | get -o CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS | default '') == '1' and $tmux_shim_dir != '' and (_zentty_is_executable ($tmux_shim_dir | path join tmux)) {
        $tmux_shim_enabled = true
    }
    if ($wrapper_dirs | is-empty) and $tmux_shim_dir == '' { return }

    let path_entries = ($env.PATH | default [])
    let cleaned_path = ($path_entries | where { |e| not ($wrapper_dirs | any { |w| $e == $w }) and $e != $tmux_shim_dir })

    mut enabled = []
    for wrapper in $wrapper_dirs {
        if $wrapper == '' { continue }
        let tool = ($wrapper | path basename)
        let has = (_zentty_wrapper_binary_candidates $tool | any { |c| _zentty_is_executable ($wrapper | path join $c) })
        if not $has { continue }
        for entry in $cleaned_path {
            if (_zentty_real_binary_candidates $tool | any { |c| _zentty_is_executable ($entry | path join $c) }) {
                $enabled = ($enabled | append $wrapper)
                break
            }
        }
    }

    mut next_path = []
    if $tmux_shim_enabled { $next_path = ($next_path | append $tmux_shim_dir) }
    $next_path = ($next_path | append $enabled | append $cleaned_path)
    $env.PATH = $next_path

    if ($enabled | is-not-empty) {
        $env.ZENTTY_WRAPPER_BIN_DIR = ($enabled | first)
        $env.ZENTTY_WRAPPER_BIN_DIRS = ($enabled | str join ':')
    } else {
        if "ZENTTY_WRAPPER_BIN_DIR" in ($env | columns) {
            hide-env ZENTTY_WRAPPER_BIN_DIR
        }
        if "ZENTTY_WRAPPER_BIN_DIRS" in ($env | columns) {
            hide-env ZENTTY_WRAPPER_BIN_DIRS
        }
    }
}

def _zentty_is_navigation_command [cmd: string] {
    if $cmd in ["cd", "pushd", "popd", "z", "j"] { return true }
    let navs = ($env | get -o ZENTTY_NAVIGATION_COMMANDS | default '' | split row ',')
    if $cmd in $navs { return true }
    false
}

def --env _zentty_pre_execution_for_command [full: string] {
    _zentty_ensure_wrapper_path
    let cmd = ($full | split row ' ' | first | default '')
    if not (_zentty_is_navigation_command $cmd) {
        let tool = (try { _zentty_agent_tool_for_command $cmd } catch { '' })
        if $tool != '' {
            _zentty_report_shell_activity "running" "--tool" $tool "--command" $full
        } else {
            _zentty_report_shell_activity "running" "--command" $full
        }
    }
    let title = ($full | split row "\n" | first | default '')
    _zentty_print_tty $"\e]2;($title)\a"
}

def _zentty_reset_keyboard_protocol [] {
    # Reset kitty keyboard protocol if a program enabled it and exited
    # without disabling it (e.g., Ctrl+C killing an agent). Pop up to 99
    # entries to clear multi-level stacks (e.g., Ink/React TUI layers).
    # Extra pops beyond the stack depth are harmless no-ops.
    _zentty_print_tty $"\e[<99u"
}

# Unlike zsh/bash, there is no CSI-u absorb counterpart here
# (_zentty_bind_leaked_key_events): reedline keybindings address named keys,
# not raw escape sequences, so kitty-protocol key events that leak into the
# input stream after an agent TUI dies cannot be bound away. The bracketed
# protocol resets above remain the only mitigation for nushell.

def --env _zentty_pre_prompt [] {
    _zentty_ensure_wrapper_path
    _zentty_apply_initial_working_directory
    _zentty_reset_keyboard_protocol
    _zentty_report_pane_root_pid
    _zentty_report_shell_activity "prompt"
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
    _zentty_reset_keyboard_protocol
}

# --- Hook registration (nu native) ---
mut cfg = ($env.config | default {})
if not ($cfg | get -o hooks | is-not-empty) {
    $cfg.hooks = {}
}
let pre_prompt_hooks = ($cfg.hooks | get -o pre_prompt | default [])
$cfg.hooks.pre_prompt = ($pre_prompt_hooks | append {|| _zentty_pre_prompt })

let pre_exec_hooks = ($cfg.hooks | get -o pre_execution | default [])
$cfg.hooks.pre_execution = ($pre_exec_hooks | append {||
    _zentty_pre_execution_for_command (commandline)
})

mut env_change = ($cfg.hooks | get -o env_change | default {})
let pwd_hooks = ($env_change | get -o PWD | default [])
$env_change.PWD = ($pwd_hooks | append {|before, after| _zentty_report_directory_change })
$cfg.hooks.env_change = $env_change

$env.config = $cfg

# Initial activation (like bash/zsh/fish)
_zentty_ensure_wrapper_path
_zentty_apply_initial_working_directory
# one-shot context
_zentty_emit_pane_context
_zentty_reset_title_to_cwd

# XDG_DATA_DIRS is restored early at load (top of this script), not on exit:
# nushell has no exit hook, and early restore matches the Ghostty/Kitty pattern.
