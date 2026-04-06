# zentty shell integration for bash

if [[ "${ZENTTY_BASH_INTEGRATION_LOADED:-0}" == "1" ]]; then
    return 0
fi
export ZENTTY_BASH_INTEGRATION_LOADED=1
_zentty_shell_activity_last=""

_zentty_ensure_wrapper_path() {
    local wrapper="${ZENTTY_WRAPPER_BIN_DIR:-}"
    [[ -n "$wrapper" ]] || return 0

    local -a entries next_path
    local entry
    IFS=: read -r -a entries <<< "${PATH:-}"
    next_path=("$wrapper")
    for entry in "${entries[@]}"; do
        [[ -z "$entry" || "$entry" == "$wrapper" ]] && continue
        next_path+=("$entry")
    done

    PATH="$(
        local IFS=:
        printf '%s' "${next_path[*]}"
    )"
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
    _zentty_shell_activity_last="$state"
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
    printf '\e]2;%s\a' "${PWD/#$HOME/\~}"
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

_zentty_report_directory_change() {
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
}

_zentty_bash_original_prompt_command="${ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND:-}"
_zentty_bash_in_prompt=0

_zentty_bash_prompt_hook() {
    _zentty_bash_in_prompt=1
    _zentty_ensure_wrapper_path
    _zentty_apply_initial_working_directory
    # Reset kitty keyboard protocol if a program enabled it and exited
    # without disabling it (e.g., Ctrl+C killing an agent). Pop up to 99
    # entries to clear multi-level stacks (e.g., Ink/React TUI layers).
    # Extra pops beyond the stack depth are harmless no-ops.
    printf '\e[<99u'
    _zentty_report_shell_activity prompt
    _zentty_emit_pane_context
    if [[ -n "$_zentty_bash_original_prompt_command" ]]; then
        eval "$_zentty_bash_original_prompt_command"
    fi
    _zentty_reset_title_to_cwd
    _zentty_bash_in_prompt=0
}

_zentty_bash_preexec_hook() {
    [[ -n "${COMP_LINE:-}" ]] && return 0
    [[ "$_zentty_bash_in_prompt" == "1" ]] && return 0
    _zentty_report_shell_activity running
    # Set terminal title to the running command (first line only)
    printf '\e]2;%s\a' "${BASH_COMMAND%%$'\n'*}"
}

cd() {
    builtin cd "$@" || return
    _zentty_report_directory_change
}

pushd() {
    builtin pushd "$@" || return
    _zentty_report_directory_change
}

popd() {
    builtin popd "$@" || return
    _zentty_report_directory_change
}

trap '_zentty_bash_preexec_hook' DEBUG
PROMPT_COMMAND="_zentty_bash_prompt_hook"
_zentty_ensure_wrapper_path
_zentty_bash_prompt_hook
