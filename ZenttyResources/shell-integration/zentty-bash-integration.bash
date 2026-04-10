# zentty shell integration for bash

if [[ "${ZENTTY_BASH_INTEGRATION_LOADED:-0}" == "1" ]]; then
    return 0
fi
export ZENTTY_BASH_INTEGRATION_LOADED=1
_zentty_shell_activity_last=""

_zentty_ensure_wrapper_path() {
    local wrapper_dirs="${ZENTTY_ALL_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIRS:-${ZENTTY_WRAPPER_BIN_DIR:-}}}"
    [[ -n "$wrapper_dirs" ]] || return 0

    local -a wrappers entries cleaned_path next_path
    local wrapper entry tool_name
    IFS=: read -r -a wrappers <<< "$wrapper_dirs"
    IFS=: read -r -a entries <<< "${PATH:-}"
    cleaned_path=()
    for entry in "${entries[@]}"; do
        [[ -z "$entry" ]] && continue
        for wrapper in "${wrappers[@]}"; do
            if [[ "$entry" == "$wrapper" ]]; then
                continue 2
            fi
        done
        cleaned_path+=("$entry")
    done

    next_path=()
    for wrapper in "${wrappers[@]}"; do
        [[ -n "$wrapper" ]] || continue
        tool_name="${wrapper##*/}"
        for entry in "${cleaned_path[@]}"; do
            if [[ -x "${entry}/${tool_name}" ]]; then
                next_path+=("$wrapper")
                break
            fi
        done
    done
    next_path+=("${cleaned_path[@]}")

    PATH="$(
        local IFS=:
        printf '%s' "${next_path[*]}"
    )"
    if (( ${#next_path[@]} > ${#cleaned_path[@]} )); then
        local active_wrapper_count=$(( ${#next_path[@]} - ${#cleaned_path[@]} ))
        local -a active_wrappers=("${next_path[@]:0:${active_wrapper_count}}")
        ZENTTY_WRAPPER_BIN_DIR="${active_wrappers[0]}"
        ZENTTY_WRAPPER_BIN_DIRS="$(
            local IFS=:
            printf '%s' "${active_wrappers[*]}"
        )"
        export ZENTTY_WRAPPER_BIN_DIR ZENTTY_WRAPPER_BIN_DIRS
    else
        unset ZENTTY_WRAPPER_BIN_DIR
        unset ZENTTY_WRAPPER_BIN_DIRS
    fi
    hash -r 2>/dev/null || true
    export PATH
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
