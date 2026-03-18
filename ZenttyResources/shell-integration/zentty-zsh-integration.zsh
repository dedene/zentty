# zentty shell integration for zsh

[[ "${ZENTTY_ZSH_INTEGRATION_LOADED:-0}" == "1" ]] && return 0
typeset -g ZENTTY_ZSH_INTEGRATION_LOADED=1

_zentty_ensure_wrapper_path() {
    [[ -n "${ZENTTY_WRAPPER_BIN_DIR:-}" ]] || return 0
    typeset -gU path
    path=("$ZENTTY_WRAPPER_BIN_DIR" "${path[@]}")
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

_zentty_precmd() {
    _zentty_ensure_wrapper_path
    _zentty_agent_signal shell-state prompt
    _zentty_emit_pane_context
}

_zentty_preexec() {
    _zentty_agent_signal shell-state running
}

autoload -Uz add-zsh-hook 2>/dev/null || true
if typeset -f add-zsh-hook >/dev/null 2>&1; then
    add-zsh-hook precmd _zentty_precmd
    add-zsh-hook preexec _zentty_preexec
else
    precmd_functions+=(_zentty_precmd)
    preexec_functions+=(_zentty_preexec)
fi

_zentty_ensure_wrapper_path
_zentty_precmd
