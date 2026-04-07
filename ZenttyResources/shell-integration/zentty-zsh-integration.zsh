# zentty shell integration for zsh

[[ "${ZENTTY_ZSH_INTEGRATION_LOADED:-0}" == "1" ]] && return 0
typeset -g ZENTTY_ZSH_INTEGRATION_LOADED=1
typeset -g _zentty_shell_activity_last=""

_zentty_ensure_wrapper_path() {
    local wrapper_dirs="${ZENTTY_ALL_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIR:-}}}"
    [[ -n "$wrapper_dirs" ]] || return 0
    local -a wrappers cleaned_path enabled_wrappers
    local wrapper entry tool_name
    wrappers=("${(@s/:/)wrapper_dirs}")
    cleaned_path=()
    for entry in "${path[@]}"; do
        (( ${wrappers[(I)$entry]} == 0 )) || continue
        cleaned_path+=("$entry")
    done
    for wrapper in "${wrappers[@]}"; do
        tool_name="${wrapper:t}"
        for entry in "${cleaned_path[@]}"; do
            [[ -x "${entry}/${tool_name}" ]] || continue
            enabled_wrappers+=("$wrapper")
            break
        done
    done
    typeset -gU path
    path=("${enabled_wrappers[@]}" "${cleaned_path[@]}")
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

_zentty_agent_signal() {
    [[ "${ZENTTY_SHELL_INTEGRATION:-1}" == "0" ]] && return 0
    [[ -n "${ZENTTY_AGENT_BIN:-}" ]] || return 0
    "$ZENTTY_AGENT_BIN" agent-signal "$@" >/dev/null 2>&1 || true
}

_zentty_report_shell_activity() {
    local state="$1"
    [[ "$_zentty_shell_activity_last" == "$state" ]] && return 0
    typeset -g _zentty_shell_activity_last="$state"
    _zentty_agent_signal shell-state "$state"
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
    builtin printf '\e]2;%s\a' "${PWD/#$HOME/~}"
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
    builtin printf '\e[<99u'
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
    local cmd="${1%%[[:space:]]*}"
    _zentty_is_navigation_command "$cmd" || _zentty_report_shell_activity running
    # Set terminal title to the running command (first line only)
    builtin printf '\e]2;%s\a' "${1%%$'\n'*}"
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
