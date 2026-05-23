# zentty shell integration for zsh

[[ "${ZENTTY_ZSH_INTEGRATION_LOADED:-0}" == "1" ]] && return 0
typeset -g ZENTTY_ZSH_INTEGRATION_LOADED=1
typeset -g _zentty_shell_activity_last=""
typeset -gi _zentty_tty_fd=0

_zentty_open_tty_fd() {
    (( _zentty_tty_fd > 0 )) && return 0
    {
        builtin zmodload zsh/system && (( $+builtins[sysopen] )) && {
            { [[ -n "${TTY:-}" && -w "$TTY" ]] && builtin sysopen -o cloexec -wu _zentty_tty_fd -- "$TTY" } ||
            { [[ -w /dev/tty ]] && builtin sysopen -o cloexec -wu _zentty_tty_fd -- /dev/tty }
        }
    } 2>/dev/null || return 1
    (( _zentty_tty_fd > 0 ))
}

_zentty_print_tty() {
    _zentty_open_tty_fd || return 0
    builtin print -rn -u "$_zentty_tty_fd" -- "$1"
}

_zentty_ensure_wrapper_path() {
    local wrapper_dirs="${ZENTTY_ALL_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIR:-}}}"
    local tmux_shim_dir="${ZENTTY_TMUX_SHIM_DIR:-}"
    local tmux_shim_enabled=0
    if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" == "1" && -n "$tmux_shim_dir" && -x "$tmux_shim_dir/tmux" ]]; then
        tmux_shim_enabled=1
    fi
    [[ -n "$wrapper_dirs" || -n "$tmux_shim_dir" ]] || return 0
    local -a wrappers cleaned_path enabled_wrappers next_path wrapper_bins real_bins
    local wrapper entry tool_name binary_name
    wrappers=()
    [[ -z "$wrapper_dirs" ]] || wrappers=("${(@s/:/)wrapper_dirs}")
    cleaned_path=()
    for entry in "${path[@]}"; do
        (( ${wrappers[(I)$entry]} == 0 )) || continue
        [[ -z "$tmux_shim_dir" || "$entry" != "$tmux_shim_dir" ]] || continue
        cleaned_path+=("$entry")
    done
    for wrapper in "${wrappers[@]}"; do
        tool_name="${wrapper:t}"
        wrapper_bins=($(_zentty_wrapper_binary_candidates "$tool_name"))
        real_bins=($(_zentty_real_binary_candidates "$tool_name"))
        local has_wrapper_binary=0
        for binary_name in "${wrapper_bins[@]}"; do
            [[ -x "${wrapper}/${binary_name}" ]] || continue
            has_wrapper_binary=1
            break
        done
        (( has_wrapper_binary )) || continue

        for entry in "${cleaned_path[@]}"; do
            for binary_name in "${real_bins[@]}"; do
                [[ -x "${entry}/${binary_name}" ]] || continue
                enabled_wrappers+=("$wrapper")
                break 2
            done
        done
    done
    next_path=()
    if (( tmux_shim_enabled )); then
        next_path+=("$tmux_shim_dir")
    fi
    next_path+=("${enabled_wrappers[@]}" "${cleaned_path[@]}")
    typeset -gU path
    path=("${next_path[@]}")
    if (( ${#enabled_wrappers[@]} > 0 )); then
        export ZENTTY_WRAPPER_BIN_DIR="${enabled_wrappers[1]}"
        export ZENTTY_WRAPPER_BIN_DIRS="${(j.:.)enabled_wrappers}"
    else
        unset ZENTTY_WRAPPER_BIN_DIR
        unset ZENTTY_WRAPPER_BIN_DIRS
    fi
    rehash 2>/dev/null || true
    export PATH
}

_zentty_wrapper_binary_candidates() {
    local tool_name="$1"
    case "$tool_name" in
        cursor) printf '%s\n' "cursor-agent" ;;
        kimi) printf '%s\n' "kimi" "kimi-cli" ;;
        *) printf '%s\n' "$tool_name" ;;
    esac
}

_zentty_real_binary_candidates() {
    _zentty_wrapper_binary_candidates "$1"
}

_zentty_agent_signal() {
    [[ "${ZENTTY_SHELL_INTEGRATION:-1}" == "0" ]] && return 0
    [[ -n "${ZENTTY_INSTANCE_SOCKET:-}" ]] || return 0
    [[ -n "${ZENTTY_PANE_TOKEN:-}" ]] || return 0
    local cli_bin="${ZENTTY_CLI_BIN:-}"
    if [[ -z "$cli_bin" || ! -x "$cli_bin" ]]; then
        cli_bin="$(command -v zentty 2>/dev/null || true)"
    fi
    [[ -n "$cli_bin" ]] || return 0
    "$cli_bin" ipc agent-signal "$@" >/dev/null 2>&1 || true
}

_zentty_report_shell_activity() {
    local state="$1"
    shift || true
    local key="$state $*"
    [[ "$_zentty_shell_activity_last" == "$key" ]] && return 0
    typeset -g _zentty_shell_activity_last="$key"
    _zentty_agent_signal shell-state "$state" "$@"
}

_zentty_agent_tool_for_command() {
    local cmd="${1:t}"
    case "$cmd" in
        amp) printf '%s\n' "Amp" ;;
        claude) printf '%s\n' "Claude Code" ;;
        codex) printf '%s\n' "Codex" ;;
        droid) printf '%s\n' "Droid" ;;
        gemini) printf '%s\n' "Gemini" ;;
        kimi|kimi-cli) printf '%s\n' "Kimi" ;;
        opencode) printf '%s\n' "OpenCode" ;;
        pi) printf '%s\n' "Pi" ;;
        agy) printf '%s\n' "Antigravity" ;;
        *) return 1 ;;
    esac
}

_zentty_report_pane_root_pid() {
    local pid="$$"
    [[ "$_zentty_pane_root_pid_last" == "$pid" ]] && return 0
    typeset -g _zentty_pane_root_pid_last="$pid"
    _zentty_agent_signal pane-root-pid attach "$pid"
}

_zentty_is_remote_shell() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

_zentty_hostname() {
    local host="${HOSTNAME:-${HOST:-}}"
    if [[ -z "$host" ]]; then
        host="$(command hostname -s 2>/dev/null || command hostname 2>/dev/null || true)"
    fi
    host="${host%%.*}"
    printf '%s' "$host"
}

_zentty_apply_initial_working_directory() {
    local initial_cwd="${ZENTTY_INITIAL_WORKING_DIRECTORY:-}"
    [[ -n "$initial_cwd" ]] || return 0

    unset ZENTTY_INITIAL_WORKING_DIRECTORY
    _zentty_is_remote_shell && return 0
    [[ -d "$initial_cwd" ]] || return 0

    builtin cd -- "$initial_cwd"
}

_zentty_local_git_branch() {
    command git rev-parse --git-dir >/dev/null 2>&1 || return 0
    command git branch --show-current 2>/dev/null || true
}

_zentty_reset_title_to_cwd() {
    _zentty_print_tty $'\e]2;'"${PWD/#$HOME/~}"$'\a'
}

_zentty_emit_pane_context() {
    local cwd_path="${PWD:-}"
    local home_path="${HOME:-}"
    local git_branch=""

    if _zentty_is_remote_shell; then
        _zentty_agent_signal pane-context remote \
            --path "$cwd_path" \
            --home "$home_path" \
            --user "${USER:-}" \
            --host "$(_zentty_hostname)" \
            --git-branch "$git_branch"
        return 0
    fi

    git_branch="$(_zentty_local_git_branch)"
    _zentty_agent_signal pane-context local \
        --path "$cwd_path" \
        --home "$home_path" \
        --user "${USER:-}" \
        --host "$(_zentty_hostname)" \
        --git-branch "$git_branch"
}

_zentty_chpwd() {
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
}

_zentty_precmd() {
    _zentty_ensure_wrapper_path
    _zentty_apply_initial_working_directory
    # Reset kitty keyboard protocol if a program enabled it and exited
    # without disabling it (e.g., Ctrl+C killing an agent). Pop up to 99
    # entries to clear multi-level stacks (e.g., Ink/React TUI layers).
    # Extra pops beyond the stack depth are harmless no-ops.
    _zentty_print_tty $'\e[<99u'
    _zentty_report_pane_root_pid
    _zentty_report_shell_activity prompt
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
}

_zentty_is_navigation_command() {
    local cmd="$1"
    case "$cmd" in
        cd|pushd|popd|z|j) return 0 ;;
    esac
    # User-configured navigation commands (comma-separated)
    if [[ -n "${ZENTTY_NAVIGATION_COMMANDS:-}" ]]; then
        local nav
        for nav in ${(s:,:)ZENTTY_NAVIGATION_COMMANDS}; do
            [[ "$cmd" == "$nav" ]] && return 0
        done
    fi
    # Alias that resolves to cd
    local expansion="${aliases[$cmd]:-}"
    [[ -n "$expansion" && "${expansion%%[[:space:]]*}" == "cd" ]] && return 0
    return 1
}

_zentty_preexec() {
    _zentty_ensure_wrapper_path
    local cmd="${1%%[[:space:]]*}"
    local agent_tool=""
    agent_tool="$(_zentty_agent_tool_for_command "$cmd" 2>/dev/null || true)"
    if ! _zentty_is_navigation_command "$cmd"; then
        if [[ -n "$agent_tool" ]]; then
            _zentty_report_shell_activity running --tool "$agent_tool" --command "$1"
        else
            _zentty_report_shell_activity running --command "$1"
        fi
    fi
    # Set terminal title to the running command (first line only)
    _zentty_print_tty $'\e]2;'"${1%%$'\n'*}"$'\a'
}

autoload -Uz add-zsh-hook 2>/dev/null || true
if typeset -f add-zsh-hook >/dev/null 2>&1; then
    add-zsh-hook chpwd _zentty_chpwd
    add-zsh-hook precmd _zentty_precmd
    add-zsh-hook preexec _zentty_preexec
else
    chpwd_functions+=(_zentty_chpwd)
    precmd_functions+=(_zentty_precmd)
    preexec_functions+=(_zentty_preexec)
fi

_zentty_ensure_wrapper_path
_zentty_precmd
