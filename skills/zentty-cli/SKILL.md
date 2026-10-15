---
name: zentty-cli
description: Use when an agent is running inside Zentty or needs to discover panes, split or grid layouts, open temporary command overlays, focus panes, launch nested coding agents, or notify the user through the Zentty CLI.
---

# Zentty CLI

Zentty injects a pane-aware CLI into sessions running inside the app. Use it to inspect the current terminal layout, control panes and worklanes, launch supported agents with Zentty status hooks, and notify the user when work needs attention.

## Detect Zentty

Prefer the injected binary:

```bash
ZENTTY="${ZENTTY_CLI_BIN:-zentty}"
```

You are inside a controllable Zentty pane when these are set:

```bash
test -n "${ZENTTY_INSTANCE_SOCKET:-}" &&
test -n "${ZENTTY_WORKLANE_ID:-}" &&
test -n "${ZENTTY_PANE_ID:-}" &&
test -n "${ZENTTY_PANE_TOKEN:-}"
```

If they are missing, do not assume pane control works. Explain that the command must run from a Zentty pane, or use ordinary shell behavior.

## Operating Rules

- Use `$ZENTTY_CLI_BIN` when available; it points at the bundled CLI for the running Zentty app.
- Prefer `--json` for discovery and parse IDs from JSON instead of scraping table output.
- Default to the current pane/worklane. Only target other panes with explicit selectors.
- Treat `ZENTTY_PANE_TOKEN` and `--include-control-token` output as sensitive routing credentials. Do not print them unless needed for a concrete command.
- Use `zentty --help` or `zentty <command> --help` when available before guessing at a subcommand.
- If a command fails with "Not running inside a Zentty instance" or "Not running inside a Zentty pane", stop and explain the missing Zentty context.

## Discovery

```bash
"$ZENTTY" version
"$ZENTTY" list --json
"$ZENTTY" list panes --json
"$ZENTTY" list panes --worklane-id "$ZENTTY_WORKLANE_ID" --json
"$ZENTTY" select pane --pane-index 2 --shell
```

Use `--include-control-token` only when you need to control a pane from outside its own environment:

```bash
"$ZENTTY" list panes --worklane-id "$ZENTTY_WORKLANE_ID" --include-control-token --json
```

The token only authenticates. From outside the pane, pass the target too:

```bash
"$ZENTTY" pane focus --pane-id "$PANE_ID" --pane-token "$PANE_TOKEN"
```

## Layout And Pane Control

Common pane actions:

```bash
"$ZENTTY" split right
"$ZENTTY" split down --equal
"$ZENTTY" hsplit --ratio 70
"$ZENTTY" vsplit --pane-index 2
"$ZENTTY" pane focus 2
"$ZENTTY" pane focus left
"$ZENTTY" pane resize 60%
"$ZENTTY" pane zoom
"$ZENTTY" layout thirds
"$ZENTTY" layout reset
```

Create grids carefully; large grids create many live panes:

```bash
"$ZENTTY" grid 2x2
"$ZENTTY" grid 2x2 --new-only -- codex
"$ZENTTY" grid 2x3 --worklane-id new -- claude
```

## Quick Action Overlays

An overlay runs a command in a temporary terminal floating inside its owning worklane without changing the layout. The default placement fills the visible worklane content with a 16 point inset, leaving the sidebar and toolbar accessible. Use `--placement pane` to cover only the target pane, or `--size-percent N` to make either placement smaller. Assign a shortcut to “Toggle Quick Action Overlay” in Settings to open, hide, or restore a manual shell overlay. It is unbound by default. Hidden sessions keep running. Switching worklanes hides the overlay, and returning leaves it hidden until explicitly restored. The toggle is disabled during Ctrl+Tab preview. Opening an overlay on the visible worklane gives it keyboard focus; opening one on another worklane leaves the current worklane selected. Pass `--follow` to select the target worklane. Use `--wait` for short commands so their output remains visible until the user dismisses the overlay. Use `--notify` when the user is viewing another worklane; the notification is tied to the target pane, also appears in Zentty's inbox, and following it reveals the overlay. Relative `--cwd` paths resolve against the caller's directory. Quitting Zentty, closing its window, or closing the pane or worklane an overlay belongs to asks first while that overlay still runs a process. Pane search is off while an overlay has keyboard focus.

```bash
"$ZENTTY" overlay open --wait --notify -- git log --oneline --decorate --color --graph --all
"$ZENTTY" overlay open --follow -- lazygit
"$ZENTTY" overlay open --placement pane --wait -- git diff --color
"$ZENTTY" overlay list
"$ZENTTY" overlay show
"$ZENTTY" overlay close
```

`overlay open` prints an overlay ID. The default target is the calling pane, even if the user switches worklanes while the command runs. The command starts in that pane's current directory; use `--cwd DIR` to override it. Worklane-placement overlays are shared by all panes in that worklane, with at most one per worklane. Pane-placement overlays allow at most one per pane and can coexist with the shared worklane overlay. `overlay show` and `overlay close` prefer the target pane’s pane-placement overlay; otherwise they act on its shared worklane overlay. `overlay list` returns both overlays applicable to the calling or selected pane, including hidden sessions. It does not list unrelated panes or worklanes. Use pane selectors and a control token to address another pane. Overlays are not panes. Their shell runs Zentty's shell integration under the overlay's own ID, so the sidebar follows its directory, branch and running command, but `zentty` commands that act on the calling pane fail inside them and agents started there report no status, so launch nested agents in a pane instead.

## Launch Agents Through Zentty

When starting a nested coding agent from inside Zentty, prefer the normal wrapped command if it is already on `PATH` in the Zentty pane. Zentty's wrapper adds status hooks and then execs the real tool.

Use the hidden launch command only when you explicitly need to force Zentty's bootstrap path:

```bash
"$ZENTTY" launch codex --model gpt-5
"$ZENTTY" launch claude --dangerously-skip-permissions
```

Supported launch tool names include `amp`, `claude`, `codex`, `copilot`, `cursor`, `droid`, `gemini`, `kimi`, `opencode`, `pi`, `grok`, `agy`, and `hermes`.

## Notify The User

Use notifications for completion, blocked input, or handoff points that should bring the user back to the pane:

```bash
"$ZENTTY" notify --title "Tests finished" --subtitle "Review the result"
"$ZENTTY" notify --title "Approval needed" --body "The deploy command is waiting for confirmation"
```

Use `--silent` for low-priority updates and `--no-inbox` when the notification should not stay in Zentty's inbox.

## Manual Hook Installs

Wrapped launches usually install or inject agent hooks automatically. Manual installs are for debugging, recovery, or globally persistent integrations:

```bash
"$ZENTTY" install cursor-hooks
"$ZENTTY" uninstall cursor-hooks
```

Check `zentty install --help` for the supported targets in the installed Zentty version.
