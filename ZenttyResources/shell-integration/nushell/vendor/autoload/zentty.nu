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

# --- ssh wrapper (GHOSTTY_SHELL_FEATURES: ssh-env / ssh-terminfo) --------------
#
# libghostty advertises the user's shell-integration-features whether or not the
# integration implements them, so Zentty ships its own wrapper rather than shell
# out to `ghostty +ssh` (not bundled). Mirrors upstream Ghostty v1.3.1 plus PR
# #11518 (COLORTERM travels locally + SendEnv, never `-o SetEnv`, so a user's own
# ssh_config SetEnv survives). See zentty-zsh-integration.zsh for the full notes
# on the installer riding in `-o RemoteCommand=` ahead of the user's args.
#
# Two nu-only divergences, both forced by the interpreter:
#
#  1. No ControlMaster. bash/zsh/fish open one for the terminfo probe and reuse it
#     for the session; here the session must be this command's final expression
#     (anything after it would drain its output and replace its exit code), which
#     leaves no place to tear a master down. So the probe is a plain connection
#     and the first ssh to a new host costs one extra authentication. It also
#     keeps `complete` safe: with no backgrounded master holding the pipe open,
#     the probe cannot hang.
#  2. A custom command's pipeline input is collected by the interpreter before the
#     body runs (verified on 0.113 — with or without binding `$in`, and for
#     closures too), so `producer | ssh host cat` delivers the payload correctly
#     but only once the producer finishes. Streaming would need `ssh` to stay an
#     external command or an alias, neither of which can carry this logic.
#     Interactive sessions are unaffected: with no pipeline input the external ssh
#     inherits the terminal's stdin directly.
#
# Unlike bash/zsh/fish this command is defined unconditionally (a nushell `def`
# inside an `if` is block-scoped and `hide` is parse-time), so with no ssh feature
# enabled it is a transparent pass-through, matching upstream ghostty.nu.
#
# The cache upstream keeps via `ghostty +ssh-cache` lives here in a flat file, one
# entry per line: `user@host` for a host that has the terminfo, `!user@host` for
# one whose installer ran and failed. Delete the file, or the line, to try again.

def _zentty_ssh_features [] {
    $env | get -o GHOSTTY_SHELL_FEATURES | default '' | split row ',' | each {|f| $f | str trim }
}

def _zentty_ssh_cache_file [] {
    let state_home = ($env | get -o XDG_STATE_HOME | default '')
    let root = if $state_home == '' {
        ($env | get -o HOME | default '' | path join '.local' 'state')
    } else {
        $state_home
    }
    $root | path join 'zentty' 'ssh_cache'
}

def _zentty_ssh_cache_has [target: string] {
    let cache_file = (_zentty_ssh_cache_file)
    if not ($cache_file | path exists) { return false }
    # Exact line match only; a substring match would treat bob@host as a hit for b@host.
    (try { open --raw $cache_file | lines } catch { [] } | any {|line| $line == $target })
}

def _zentty_ssh_cache_add [target: string] {
    if (_zentty_ssh_cache_has $target) { return }
    let cache_file = (_zentty_ssh_cache_file)
    try { mkdir ($cache_file | path dirname) } catch { }
    try { $"($target)\n" | save --raw --append $cache_file } catch { }
}

# Remote installer for xterm-ghostty terminfo. Passed via -o RemoteCommand=, so
# it must not contain a '%' (OpenSSH percent-expansion) — hence echo, not printf.
def _zentty_ssh_remote_installer [terminfo_b64: string] {
    $"infocmp xterm-ghostty >/dev/null 2>&1 && exit 0; command -v tic >/dev/null 2>&1 || exit 1; command -v base64 >/dev/null 2>&1 || exit 1; mkdir -p ~/.terminfo 2>/dev/null && echo '($terminfo_b64)' | base64 -d | tic -x - 2>/dev/null && exit 0; exit 1"
}

def --wrapped ssh [...args] {
    let ssh_input = $in
    let features = (_zentty_ssh_features)
    mut ssh_env = {}
    mut ssh_opts = []

    if ('ssh-env' in $features) or ('ssh-terminfo' in $features) {
        mut ssh_term = 'xterm-256color'

        if ('ssh-env' in $features) {
            $ssh_env.COLORTERM = 'truecolor'
            $ssh_opts = ['-o' 'SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION']
        }

        if ('ssh-terminfo' in $features) {
            let ssh_config = (^ssh -G ...$args | complete | get stdout | lines | parse '{key} {value}')
            let ssh_user = ($ssh_config | where key == 'user' | get value | get -o 0 | default '')
            let ssh_hostname = ($ssh_config | where key == 'hostname' | get value | get -o 0 | default '')
            # OpenSSH < 8.7 does not report sessiontype; assume a normal session.
            let ssh_sessiontype = ($ssh_config | where key == 'sessiontype' | get value | get -o 0 | default 'default')

            if $ssh_hostname != '' {
                let ssh_target = $"($ssh_user)@($ssh_hostname)"
                if (_zentty_ssh_cache_has $ssh_target) {
                    $ssh_term = 'xterm-ghostty'
                } else if (_zentty_ssh_cache_has $"!($ssh_target)") {
                    # Known to reject the terminfo; don't spend a connection or warn again.
                } else if $ssh_sessiontype != 'default' {
                    # -N / -s: no remote command can run, so skip silently.
                } else if ((which infocmp | length) > 0) {
                    let ssh_terminfo = (^infocmp -0 -x xterm-ghostty | complete)
                    let ssh_terminfo_b64 = if ($ssh_terminfo.exit_code == 0 and ($ssh_terminfo.stdout | str trim | is-not-empty)) {
                        ($ssh_terminfo.stdout | encode base64)
                    } else {
                        ''
                    }
                    if $ssh_terminfo_b64 != '' {
                        let install_args = (
                            $ssh_opts
                            ++ ['-o' 'RequestTTY=no' '-o' $"RemoteCommand=(_zentty_ssh_remote_installer $ssh_terminfo_b64)"]
                            ++ $args
                        )
                        # Empty input keeps the installer off the terminal's stdin.
                        let installed = ('' | ^ssh ...$install_args | complete)
                        if $installed.exit_code == 0 {
                            $ssh_term = 'xterm-ghostty'
                            _zentty_ssh_cache_add $ssh_target
                        } else if $installed.exit_code == 255 {
                            # ssh itself failed (refusal, auth, network): transient, no cache.
                            if not ($installed.stderr | str contains 'Cannot execute command-line and remote command') {
                                print -e $"Warning: Failed to install xterm-ghostty terminfo on ($ssh_hostname)."
                            }
                        } else {
                            # The installer itself ran and failed: no tic/base64 on the
                            # remote, or a shell that cannot run it. Remember, warn once.
                            _zentty_ssh_cache_add $"!($ssh_target)"
                            print -e ('Warning: Could not install xterm-ghostty terminfo on ' + $ssh_hostname
                                + '; using xterm-256color. Remove the "!' + $ssh_target + '" line from '
                                + (_zentty_ssh_cache_file) + ' to retry.')
                        }
                    } else {
                        print -e 'Warning: Could not generate xterm-ghostty terminfo data.'
                    }
                }
            }
        }

        $ssh_env.TERM = $ssh_term
    }

    # Blocks cannot capture mutable variables; rebind before running. This must stay
    # the final expression so the session's output streams and its exit code stands.
    let ssh_final_env = $ssh_env
    let ssh_final_args = ($ssh_opts ++ $args)
    if ($ssh_input | describe) == 'nothing' {
        with-env $ssh_final_env { ^ssh ...$ssh_final_args }
    } else {
        $ssh_input | with-env $ssh_final_env { ^ssh ...$ssh_final_args }
    }
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
