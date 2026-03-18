# zentty shell integration for bash

if [[ "${ZENTTY_BASH_INTEGRATION_LOADED:-0}" == "1" ]]; then
    return 0
fi
export ZENTTY_BASH_INTEGRATION_LOADED=1

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

_zentty_emit_pane_context() {
    local path="${PWD:-}"
    local home="${HOME:-}"

    if _zentty_is_remote_shell; then
        _zentty_agent_signal pane-context remote \
            --path "$path" \
            --home "$home" \
            --user "${USER:-}" \
            --host "$(_zentty_hostname)"
        return 0
    fi

    _zentty_agent_signal pane-context local \
        --path "$path" \
        --home "$home" \
        --user "${USER:-}" \
        --host "$(_zentty_hostname)"
}

_zentty_bash_original_prompt_command="${ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND:-}"

_zentty_bash_prompt_hook() {
    _zentty_ensure_wrapper_path
    _zentty_agent_signal shell-state prompt
    _zentty_emit_pane_context
    if [[ -n "$_zentty_bash_original_prompt_command" ]]; then
        eval "$_zentty_bash_original_prompt_command"
    fi
}

_zentty_bash_preexec_hook() {
    [[ -n "${COMP_LINE:-}" ]] && return 0
    _zentty_agent_signal shell-state running
}

trap '_zentty_bash_preexec_hook' DEBUG
PROMPT_COMMAND="_zentty_bash_prompt_hook"
_zentty_ensure_wrapper_path
_zentty_bash_prompt_hook
