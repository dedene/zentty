# Agent Teams and tmux-based agent tools

Some agent tools run their teammates or subagents in tmux panes. Zentty ships a small `tmux` command that answers those tools from inside a Zentty pane, so each teammate shows up as a Zentty pane rather than in a tmux session you can't see. The first teammate opens a column to the right of the pane that started the team; later teammates stack in that column. Closing the lead pane closes its teammates.

This is experimental. Nothing gets installed into your agent configs or your real tmux. The tmux command only exists for the processes Zentty starts in team mode.

## Turning it on

You can turn it on in two ways.

**For one launch.** Start the tool from a Zentty pane:

```bash
zentty launch --teams claude          # Claude Code with agent teams on
zentty launch claude --teams          # same thing
zentty launch --tmux-shim -- omx team 3:executor "fix the failing tests"
zentty launch --tmux-shim             # a login shell in team mode; run any tmux-based tool from it
```

`--teams <agent>` launches an integrated agent the normal way (status hooks included) with the tmux command on `PATH`. For Claude Code it also sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. `--teams` must come before the agent's own arguments.

`--tmux-shim [--] [command …]` runs any command that way. Without a command you get your login shell, and everything you start from it sees the same tmux.

**For every new pane.** Turn on **Settings → Agents → Agent teams**, or set it in `~/.config/zentty/config.toml`:

```toml
[agent_teams]
enabled = true
```

New panes then start in team mode with Claude Code's team switch on. Panes that were already open keep their old environment. If Zentty itself was started from inside a real tmux session, it leaves that session's `TMUX` alone.

Inside Zentty the team switch wins over Claude Code's own settings. Claude normally lets an `env` entry in `~/.claude/settings.json` override the environment, so a `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0"` there would turn teams back off. In team-mode panes Zentty also puts `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in the settings it passes to Claude, which take precedence. With the setting off, Zentty leaves the variable alone.

## Tools

| Tool | How to start it | Notes |
| --- | --- | --- |
| Claude Code agent teams | `zentty launch --teams claude`, or the Settings toggle | Uses Claude's tmux teammate mode. If you set `teammateMode` to `in-process` in Claude's settings, teammates stay in Claude's own UI. |
| oh-my-claudecode (`omc team …`) | `zentty launch --tmux-shim -- omc team 2:claude "…"` | Workers open as panes in the current worklane. |
| oh-my-codex (`omx team …`) | `zentty launch --tmux-shim -- omx team 3:executor "…"` | Its HUD pane lands in the teammate column too. |
| oh-my-openagent / oh-my-opencode | `zentty launch --tmux-shim -- opencode` | Set `"tmux": { "enabled": true }` in its config. Use `isolation: "inline"` or `"window"`; detached sessions are not shown. For team mode also set `team_mode.tmux_visualization`. |
| Codex CLI | not needed | Codex has no tmux teammate mode. |

## What the tmux command understands

Zentty maps tmux's model onto its own: the Zentty window is the tmux session, each worklane is a tmux window, each pane a tmux pane. A `new-window` pane opens in the teammate column too, but tools see it, and the panes later split from it, as a window of its own, so one tool's window commands don't reach another tool's panes. Pane, window and session ids are numeric (`%3`, `@1`, `$0`) like tmux's. `tmux -V` reports `tmux 3.4`.

| Area | Supported |
| --- | --- |
| Creating panes | `split-window`, `new-window` (title from `-n`), `new-session -P`, with `-c`, `-e NAME=VALUE`, `-d`, `-P -F`, a command as one string or as argv |
| Driving panes | `send-keys` (key names, `-l`, `--`), `respawn-pane` (deferred or live with `-k`; the pane keeps its id), `select-pane -T`, `kill-pane`, `capture-pane -p` |
| Reading state | `display-message -p`, `list-panes [-a\|-s]`, `list-windows`, `list-sessions`, `has-session`, `show-options` |
| Options | `set-option` / `set-window-option` with `-p`, `-w`, `-g`, `-s`, `-a`, `-u`, `-o`, `-F`; user options (`@name`) read back by `show-options` and `#{@name}` |
| Command lines | `cmd ; cmd` sequences, `if-shell [-F]`, `run-shell [-b] [-C]`, `wait-for` |
| Targets | `%N`, `@N`, `$N`, `session:window.pane`, `=name`, indexes and names |
| Formats | `#{var}`, `#{?cond,a,b}`, `#{==:a,b}`, `#{!=:…}`, `#{<:…}` and friends, `#{&&:…}`, `#{\|\|:…}`, `#{m:…}`, `#{=N:…}`, `#{b:…}`, `#{d:…}`, `#{q:…}`, `#S` / `#I` / `#P` / `#D` / `#T` |
| Format variables | `pane_id`, `pane_index`, `pane_title`, `pane_active`, `pane_pid`, `pane_dead`, `pane_current_path`, `pane_current_command`, `pane_start_command`, `pane_width`, `pane_height`, `window_id`, `window_index`, `window_name`, `window_width`, `window_height`, `session_id`, `session_name`, `session_created`, `socket_path`, `pid`, `version` and more |

Missing targets fail like tmux: `can't find pane: %9` on stderr and exit status 1. A command without `-t` from a pane that no longer exists fails the same way instead of acting on another pane.

`-P` without `-F` prints a target that keeps naming the new pane (`zentty:@4.%7` for `split-window`, `zentty:@9` for `new-window`), where tmux would print window and pane positions that shift when you add or close panes.

Zentty keeps control of focus and layout. `select-layout` and `resize-pane` only rebalance the teammate column. `select-window`, `rename-window`, `set-hook`, `switch-client`, `kill-session` and `kill-server` succeed and change nothing, so a tool's cleanup can't close your own panes. For the same reason `kill-pane` and `respawn-pane -k` only act on the calling pane and on panes the tmux command created; on any other pane they succeed and change nothing. `kill-window` only closes panes the tmux command created in that window, never the pane that started the team, and `kill-pane -a` is ignored. Unknown commands also succeed and do nothing.

Not supported: attaching to detached sessions, copy mode, popups (`display-popup` fails), key bindings, and exact tmux layouts and sizes. Pane sizes are reported in cells but are approximate.

## Troubleshooting

Set `ZENTTY_TMUX_COMPAT_TRACE_PATH` to a file before launching and every tmux call is logged there as JSON lines. Panes opened with the Settings toggle on log to `~/Library/Application Support/Zentty/tmux-compat-trace.jsonl` (`Zentty Dev` for the dev build) by default.

`pane_pid` comes from the pane's shell. A pane whose command does not run through a supported login shell (zsh, bash or fish) may report it empty.
