# zentty shell integration for fish
# Port of the bash/zsh behaviors using fish event hooks and fish-native syntax.
# Must be loaded via XDG_DATA_DIRS (see WorklaneSessionEnvironment) or manual source.

# Restore XDG_DATA_DIRS early (Ghostty/Kitty pattern). vendor_conf.d discovery has
# already happened by the time this file is sourced, so stripping our injected entry
# now keeps this session and every child process it spawns clean. Runs before the
# interactive/loaded guards so even non-interactive children inherit a clean value.
function _zentty_fish_restore_xdg
    if set -q ZENTTY_SHELL_INTEGRATION_XDG_DIR
        if set -q XDG_DATA_DIRS
            set -l new_xdg
            for d in (string split ':' -- $XDG_DATA_DIRS)
                if not string match -q -- $ZENTTY_SHELL_INTEGRATION_XDG_DIR $d
                    set -a new_xdg $d
                end
            end
            set -gx XDG_DATA_DIRS (string join ':' $new_xdg)
        end
        set -e ZENTTY_SHELL_INTEGRATION_XDG_DIR
    end
end
_zentty_fish_restore_xdg

if not status --is-interactive; and test -z "$ZENTTY_FORCE_SHELL_INTEGRATION"
    exit 0
end

if set -q ZENTTY_FISH_INTEGRATION_LOADED
    exit 0
end
set -g ZENTTY_FISH_INTEGRATION_LOADED 1

set -g _zentty_shell_activity_last ""

function _zentty_print_tty
    set -l sequence $argv[1]
    set -l tty_path $TTY
    if test -z "$tty_path" -o ! -w "$tty_path"
        set tty_path /dev/tty
    end
    if test -w "$tty_path"
        printf '%s' $sequence > $tty_path 2>/dev/null || true
    end
end

function _zentty_wrapper_binary_candidates
    set -l tool_name $argv[1]
    switch $tool_name
        case cursor
            echo cursor-agent
        case kimi
            echo kimi
            echo kimi-cli
        case '*'
            echo $tool_name
    end
end

function _zentty_real_binary_candidates
    _zentty_wrapper_binary_candidates $argv[1]
end

function _zentty_ensure_wrapper_path
    set -l wrapper_dirs
    set -l raw_wrapper_dirs ""
    if test -n "$ZENTTY_ALL_WRAPPER_BIN_DIRS"
        set raw_wrapper_dirs $ZENTTY_ALL_WRAPPER_BIN_DIRS
    else if test -n "$ZENTTY_WRAPPER_BIN_DIRS"
        set raw_wrapper_dirs $ZENTTY_WRAPPER_BIN_DIRS
    else if test -n "$ZENTTY_WRAPPER_BIN_DIR"
        set raw_wrapper_dirs $ZENTTY_WRAPPER_BIN_DIR
    end
    if test -n "$raw_wrapper_dirs"
        set wrapper_dirs (string split ':' -- $raw_wrapper_dirs)
    end
    set -l tmux_shim_dir $ZENTTY_TMUX_SHIM_DIR
    set -l tmux_shim_enabled 0
    if test "$CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" = "1" -a -n "$tmux_shim_dir" -a -x "$tmux_shim_dir/tmux"
        set tmux_shim_enabled 1
    end
    if test -z "$wrapper_dirs" -a -z "$tmux_shim_dir"
        return 0
    end

    set -l cleaned_path
    for entry in $PATH
        set -l skip 0
        for w in $wrapper_dirs
            if test "$entry" = "$w"
                set skip 1
                break
            end
        end
        if test "$entry" = "$tmux_shim_dir"
            set skip 1
        end
        if test $skip -eq 0
            set -a cleaned_path $entry
        end
    end

    set -l enabled_wrappers
    for wrapper in $wrapper_dirs
        test -n "$wrapper" || continue
        set -l tool_name (basename $wrapper)
        set -l has 0
        for candidate in (_zentty_wrapper_binary_candidates $tool_name)
            if test -x "$wrapper/$candidate"
                set has 1
                break
            end
        end
        if test $has -eq 1
            set -l enabled_for_wrapper 0
            for entry in $cleaned_path
                test $enabled_for_wrapper -eq 0 || break
                for candidate in (_zentty_real_binary_candidates $tool_name)
                    if test -x "$entry/$candidate"
                        if not contains -- $wrapper $enabled_wrappers
                            set -a enabled_wrappers $wrapper
                        end
                        set enabled_for_wrapper 1
                        break
                    end
                end
            end
        end
    end

    set -l next_path
    if test $tmux_shim_enabled -eq 1
        set -a next_path $tmux_shim_dir
    end
    set -a next_path $enabled_wrappers $cleaned_path

    set -g PATH $next_path
    if test (count $enabled_wrappers) -gt 0
        set -gx ZENTTY_WRAPPER_BIN_DIR $enabled_wrappers[1]
        set -gx ZENTTY_WRAPPER_BIN_DIRS (string join ':' $enabled_wrappers)
    else
        set -e ZENTTY_WRAPPER_BIN_DIR
        set -e ZENTTY_WRAPPER_BIN_DIRS
    end
    # hash not needed in fish; PATH change visible
end

function _zentty_agent_signal
    if test "$ZENTTY_SHELL_INTEGRATION" = "0"
        return 0
    end
    if test -z "$ZENTTY_INSTANCE_SOCKET" -o -z "$ZENTTY_PANE_TOKEN"
        return 0
    end
    set -l cli_bin $ZENTTY_CLI_BIN
    if test -z "$cli_bin" -o ! -x "$cli_bin"
        set cli_bin (command -v zentty 2>/dev/null || true)
    end
    test -n "$cli_bin" || return 0
    $cli_bin ipc agent-signal $argv >/dev/null 2>&1 || true
end

function _zentty_report_shell_activity
    set -l state $argv[1]
    set -e argv[1]
    set -l key "$state $argv"
    if test "$_zentty_shell_activity_last" = "$key"
        return 0
    end
    set -g _zentty_shell_activity_last "$key"
    _zentty_agent_signal shell-state $state $argv
end

function _zentty_agent_tool_for_command
    set -l cmd (basename $argv[1])
    switch $cmd
        case amp; echo Amp
        case claude; echo "Claude Code"
        case codex; echo Codex
        case droid; echo Droid
        case gemini; echo Gemini
        case kimi kimi-cli; echo Kimi
        case opencode; echo OpenCode
        case pi; echo Pi
        case agy; echo Antigravity
        case '*'; return 1
    end
end

function _zentty_report_pane_root_pid
    set -l pid $fish_pid
    if test "$_zentty_pane_root_pid_last" = "$pid"
        return 0
    end
    set -g _zentty_pane_root_pid_last $pid
    _zentty_agent_signal pane-root-pid attach $pid
end

function _zentty_is_remote_shell
    set -q SSH_CONNECTION; or set -q SSH_CLIENT; or set -q SSH_TTY
end

function _zentty_hostname
    set -l host $hostname
    if test -z "$host"
        set host (hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)
    end
    echo (string replace -r '\..*' '' -- $host)
end

function _zentty_apply_initial_working_directory
    set -l initial $ZENTTY_INITIAL_WORKING_DIRECTORY
    test -n "$initial" || return 0
    set -e ZENTTY_INITIAL_WORKING_DIRECTORY
    _zentty_is_remote_shell && return 0
    test -d "$initial" || return 0
    cd -- $initial
end

function _zentty_local_git_branch
    git rev-parse --git-dir >/dev/null 2>&1 || return 0
    git branch --show-current 2>/dev/null || true
end

function _zentty_reset_title_to_cwd
    # Anchor to the leading path prefix (port of bash/zsh ${PWD/#$HOME/~}); an
    # unanchored replace would rewrite $HOME anywhere it appears in the path.
    _zentty_print_tty (printf '\e]2;%s\a' (string replace -r -- "^"(string escape --style=regex -- $HOME) '~' $PWD))
end

function _zentty_emit_pane_context
    set -l cwd_path $PWD
    set -l home_path $HOME
    set -l git_branch ""

    if _zentty_is_remote_shell
        # Quote every value: a fish command substitution that yields no output
        # (e.g. an empty git branch) collapses to a zero-element list, which would
        # DROP the flag's value and leave a dangling "--git-branch". The CLI parser
        # rejects a trailing valueless flag, so the whole signal would be discarded.
        # Quoting guarantees exactly one (possibly empty) argument per value.
        _zentty_agent_signal pane-context remote --path "$cwd_path" --home "$home_path" --user "$USER" --host (_zentty_hostname) --git-branch "$git_branch"
        return 0
    end

    set git_branch (_zentty_local_git_branch)
    _zentty_agent_signal pane-context local --path "$cwd_path" --home "$home_path" --user "$USER" --host (_zentty_hostname) --git-branch "$git_branch"
end

function _zentty_report_directory_change
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
end

# --- Fish-specific hooks ---

function _zentty_reset_keyboard_protocol
    # Reset kitty keyboard protocol if a program enabled it and exited
    # without disabling it (e.g., Ctrl+C killing an agent). Pop up to 99
    # entries to clear multi-level stacks (e.g., Ink/React TUI layers).
    # Extra pops beyond the stack depth are harmless no-ops.
    _zentty_print_tty \e'[<99u'
end

# Unlike zsh/bash, no CSI-u absorb bindings (_zentty_bind_leaked_key_events)
# are needed here: fish >= 4 decodes kitty keyboard protocol sequences
# natively, so key events that leak into the input stream after an agent TUI
# dies are interpreted as keys (release events are dropped) instead of being
# echoed as literal text like "9;5:3u".

function _zentty_fish_prompt_hook --on-event fish_prompt
    _zentty_ensure_wrapper_path
    _zentty_apply_initial_working_directory
    _zentty_reset_keyboard_protocol
    _zentty_report_pane_root_pid
    _zentty_report_shell_activity prompt
    _zentty_emit_pane_context
    _zentty_reset_title_to_cwd
    _zentty_reset_keyboard_protocol
end

function _zentty_fish_preexec_hook --on-event fish_preexec
    set -l full_command $argv[1]
    set -l cmd (string split -m 1 ' ' -- $full_command)[1]
    if not _zentty_is_navigation_command $cmd
        set -l tool (_zentty_agent_tool_for_command $cmd 2>/dev/null || true)
        if test -n "$tool"
            _zentty_report_shell_activity running --tool $tool --command $full_command
        else
            _zentty_report_shell_activity running --command $full_command
        end
    end
    _zentty_print_tty (printf '\e]2;%s\a' (string split -m 1 \n -- $full_command)[1])
end

function _zentty_fish_pwd_hook --on-variable PWD
    _zentty_report_directory_change
end

# Navigation filter (port of the zsh logic)
function _zentty_is_navigation_command
    set -l cmd $argv[1]
    switch $cmd
        case cd pushd popd z j
            return 0
    end
    if set -q ZENTTY_NAVIGATION_COMMANDS
        for nav in (string split , -- $ZENTTY_NAVIGATION_COMMANDS)
            if test "$cmd" = "$nav"
                return 0
            end
        end
    end
    # Alias check (fish abbreviations/functions are harder; keep simple for v1)
    return 1
end

# Initial load
_zentty_ensure_wrapper_path
_zentty_fish_prompt_hook   # run once at load so context is reported immediately
