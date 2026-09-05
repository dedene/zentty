# zentty shell integration for zsh

[[ "${ZENTTY_ZSH_INTEGRATION_LOADED:-0}" == "1" ]] && return 0
typeset -g ZENTTY_ZSH_INTEGRATION_LOADED=1
typeset -g _zentty_shell_activity_last=""
# Initialised up front so a user's `setopt nounset` does not abort the first precmd.
typeset -g _zentty_pane_root_pid_last=""
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

_zentty_reset_keyboard_protocol() {
    # Reset kitty keyboard protocol if a program enabled it and exited
    # without disabling it (e.g., Ctrl+C killing an agent). Pop up to 99
    # entries to clear multi-level stacks (e.g., Ink/React TUI layers).
    # Extra pops beyond the stack depth are harmless no-ops.
    _zentty_print_tty $'\e[<99u'
}

_zentty_discard_leaked_key_event() { :; }

_zentty_bind_leaked_key_events() {
    # Absorb kitty keyboard protocol key events that leak into the line
    # editor. When Ctrl+C kills an agent TUI that enabled the protocol with
    # key-release reporting (e.g. codex), the release of that Ctrl+C — and
    # any extra presses during the teardown window — are CSI-u encoded in
    # the pty buffer before the precmd reset can pop the mode, and ZLE would
    # echo them as literal text like "9;5:3u". Map Ctrl+C presses to a real
    # interrupt and drop repeat/release events. Sequences a user already
    # bound are left alone.
    [[ -o interactive ]] || return 0
    builtin zle -N _zentty_discard_leaked_key_event 2>/dev/null || return 0
    local seq widget
    for seq widget in \
        '\e[99;5u'   send-break \
        '\e[99;5:1u' send-break \
        '\e[99;5:2u' _zentty_discard_leaked_key_event \
        '\e[99;5:3u' _zentty_discard_leaked_key_event \
        '\e[9;1:3u'  _zentty_discard_leaked_key_event \
        '\e[13;1:3u' _zentty_discard_leaked_key_event \
        '\e[27;1:3u' _zentty_discard_leaked_key_event; do
        [[ "$(builtin bindkey "$seq" 2>/dev/null)" == *undefined-key* ]] || continue
        builtin bindkey "$seq" "$widget" 2>/dev/null || true
    done
}

_zentty_precmd() {
    _zentty_ensure_wrapper_path
    _zentty_apply_initial_working_directory
    _zentty_reset_keyboard_protocol
    _zentty_report_pane_root_pid
    _zentty_report_shell_activity prompt
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
    _zentty_reset_keyboard_protocol
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

# --- ssh wrapper (GHOSTTY_SHELL_FEATURES: ssh-env / ssh-terminfo) --------------
#
# libghostty advertises the user's shell-integration-features through
# GHOSTTY_SHELL_FEATURES whether or not the integration implements them, so
# Zentty ships its own wrapper instead of shelling out to `ghostty +ssh`
# (Zentty does not bundle that CLI). Behaviour mirrors upstream Ghostty v1.3.1
# with upstream PR #11518 applied: COLORTERM is exported locally and forwarded
# with SendEnv instead of `-o SetEnv COLORTERM=truecolor`, so a user's own
# SetEnv entries in ssh_config are not clobbered.
#
# The terminfo install deliberately diverges from upstream, which appends its
# installer script after "$@": with `ssh host 'make deploy'` OpenSSH would
# concatenate the two and run the user's command during the install probe. Here
# the installer travels as `-o RemoteCommand=` (placed before "$@", carrying the
# terminfo base64-encoded so stdin stays free and `%` never appears — OpenSSH
# percent-expands RemoteCommand). OpenSSH then refuses the combination outright
# ("Cannot execute command-line and remote command.", exit 255) and runs
# nothing, which we treat as a silent skip.
#
# We only open a ControlMaster when the user has none of their own: if `ssh -G`
# reports a controlpath other than `none` (ssh_config, or an explicit -S), their
# multiplexing already gives the install and the session one connection, and
# hijacking it — or worse, sending `-O exit` to their master — would tear down
# their other sessions.
#
# The cache upstream keeps via `ghostty +ssh-cache` lives here in a flat file,
# one entry per line: `user@host` for a host that has the terminfo, and
# `!user@host` for one whose installer ran and failed (no tic, no base64, an
# exotic login shell) so we neither retry nor warn on every connection. Delete
# the file, or the one line, to try again.

_zentty_ssh_cache_file() {
    local state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
    printf '%s' "$state_home/zentty/ssh_cache"
}

_zentty_ssh_cache_has() {
    local cache_file
    cache_file="$(_zentty_ssh_cache_file)"
    [[ -f "$cache_file" ]] || return 1
    command grep -qxF -- "$1" "$cache_file" 2>/dev/null
}

_zentty_ssh_cache_add() {
    local cache_file
    cache_file="$(_zentty_ssh_cache_file)"
    _zentty_ssh_cache_has "$1" && return 0
    command mkdir -p -- "${cache_file:h}" 2>/dev/null || return 0
    builtin print -r -- "$1" >> "$cache_file" 2>/dev/null || true
}

# Remote installer for xterm-ghostty terminfo. Passed via -o RemoteCommand=, so
# it must not contain a '%' (OpenSSH percent-expansion) — hence echo, not printf.
_zentty_ssh_remote_installer() {
    printf '%s' "infocmp xterm-ghostty >/dev/null 2>&1 && exit 0; command -v tic >/dev/null 2>&1 || exit 1; command -v base64 >/dev/null 2>&1 || exit 1; mkdir -p ~/.terminfo 2>/dev/null && echo '$1' | base64 -d | tic -x - 2>/dev/null && exit 0; exit 1"
}

_zentty_ssh_has_feature() {
    local feature
    for feature in ${(s:,:)${GHOSTTY_SHELL_FEATURES:-}}; do
        [[ "$feature" == "$1" ]] && return 0
    done
    return 1
}

if _zentty_ssh_has_feature ssh-env || _zentty_ssh_has_feature ssh-terminfo; then
    function ssh() {
        # `emulate -L zsh` restores zsh's own options for the body, so a user's
        # nounset/globsubst settings cannot change how this function behaves.
        emulate -L zsh
        local ssh_term="xterm-256color"
        local ssh_hostname="" ssh_cpath_dir="" ssh_cpath=""
        local -i ssh_master=0 ssh_status=0 ssh_env_enabled=0

        local -a ssh_opts
        ssh_opts=()
        if _zentty_ssh_has_feature ssh-env; then
            ssh_env_enabled=1
            ssh_opts+=(-o "SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION")
        fi

        if _zentty_ssh_has_feature ssh-terminfo; then
            local ssh_user="" ssh_sessiontype="" ssh_controlpath="" ssh_key="" ssh_value=""
            while IFS=' ' read -r ssh_key ssh_value; do
                case "$ssh_key" in
                    user) ssh_user="$ssh_value" ;;
                    hostname) ssh_hostname="$ssh_value" ;;
                    sessiontype) ssh_sessiontype="$ssh_value" ;;
                    controlpath) ssh_controlpath="$ssh_value" ;;
                esac
            done < <(command ssh -G "$@" 2>/dev/null)
            # OpenSSH < 8.7 reports neither key; assume a normal, unmultiplexed session.
            [[ -n "$ssh_sessiontype" ]] || ssh_sessiontype="default"
            [[ -n "$ssh_controlpath" ]] || ssh_controlpath="none"

            if [[ -n "$ssh_hostname" ]]; then
                local ssh_target="${ssh_user}@${ssh_hostname}"
                if _zentty_ssh_cache_has "$ssh_target"; then
                    ssh_term="xterm-ghostty"
                elif _zentty_ssh_cache_has "!$ssh_target"; then
                    : # Known to reject the terminfo; don't spend a connection or warn again.
                elif [[ "$ssh_sessiontype" != "default" ]]; then
                    : # -N / -s: no remote command can run, so skip silently.
                elif (( $+commands[infocmp] )); then
                    local ssh_terminfo="" ssh_install_error="" ssh_tmp_root=""
                    local -i ssh_install_status=0
                    local -a ssh_master_opts
                    ssh_master_opts=()
                    ssh_terminfo=$(command infocmp -0 -x xterm-ghostty 2>/dev/null | command base64 | command tr -d '\n')
                    if [[ -n "$ssh_terminfo" ]]; then
                        ssh_tmp_root="${TMPDIR:-/tmp}"
                        # Unix domain sockets cap out around 104 bytes and OpenSSH appends a
                        # ~17-char random suffix while binding the ControlPath, so a long
                        # TMPDIR (macOS's per-user /var/folders/... is ~49 chars on its own)
                        # cannot host the socket. The user name is left out of the template
                        # for the same reason; mktemp already creates the dir 0700.
                        (( ${#ssh_tmp_root} > 40 )) && ssh_tmp_root="/tmp"
                        ssh_cpath_dir=$(command mktemp -d "$ssh_tmp_root/zentty-ssh.XXXXXX" 2>/dev/null) || ssh_cpath_dir=""
                        if [[ -n "$ssh_cpath_dir" ]]; then
                            ssh_install_error="$ssh_cpath_dir/install.err"
                            if [[ "$ssh_controlpath" == "none" ]]; then
                                ssh_cpath="$ssh_cpath_dir/socket"
                                ssh_master_opts=(-o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s)
                            fi
                            command ssh "${ssh_opts[@]}" "${ssh_master_opts[@]}" \
                                -o RequestTTY=no \
                                -o RemoteCommand="$(_zentty_ssh_remote_installer "$ssh_terminfo")" \
                                "$@" </dev/null >/dev/null 2>"$ssh_install_error"
                            ssh_install_status=$?
                            if (( ssh_install_status == 0 )); then
                                ssh_term="xterm-ghostty"
                                if [[ -n "$ssh_cpath" ]]; then
                                    ssh_opts+=(-o "ControlPath=$ssh_cpath")
                                    ssh_master=1
                                fi
                                _zentty_ssh_cache_add "$ssh_target"
                            elif (( ssh_install_status == 255 )); then
                                # ssh itself failed (refusal, auth, network): transient, no cache.
                                if command grep -q "Cannot execute command-line and remote command" "$ssh_install_error" 2>/dev/null; then
                                    : # The user passed their own remote command; ssh ran nothing.
                                else
                                    builtin print "Warning: Failed to install xterm-ghostty terminfo on $ssh_hostname." >&2
                                fi
                            else
                                # The installer itself ran and failed: no tic/base64 on the
                                # remote, or a shell that cannot run it. Remember, warn once.
                                _zentty_ssh_cache_add "!$ssh_target"
                                builtin print "Warning: Could not install xterm-ghostty terminfo on $ssh_hostname; using xterm-256color. Remove the \"!$ssh_target\" line from $(_zentty_ssh_cache_file) to retry." >&2
                            fi
                        fi
                    else
                        builtin print "Warning: Could not generate xterm-ghostty terminfo data." >&2
                    fi
                fi
            fi
        fi

        # COLORTERM is part of the ssh-env feature; ssh-terminfo alone must not add it.
        if (( ssh_env_enabled )); then
            TERM="$ssh_term" COLORTERM=truecolor command ssh "${ssh_opts[@]}" "$@"
        else
            TERM="$ssh_term" command ssh "${ssh_opts[@]}" "$@"
        fi
        ssh_status=$?
        # Only ever close a master we opened, and address it by ControlPath and host
        # alone: replaying "$@" would let a user's own -S/-o ControlPath win and shut
        # down their multiplexed connection. A Ctrl-C that kills the shell before this
        # point skips the teardown; ControlPersist=60s bounds the stray master and the
        # temp dir is left behind (accepted).
        (( ssh_master )) && command ssh -o ControlPath="$ssh_cpath" -O exit -- "$ssh_hostname" >/dev/null 2>&1
        [[ -n "$ssh_cpath_dir" ]] && command rm -rf -- "$ssh_cpath_dir" 2>/dev/null
        return $ssh_status
    }
fi

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
_zentty_bind_leaked_key_events
_zentty_precmd
