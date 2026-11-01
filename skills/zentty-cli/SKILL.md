---
name: zentty-cli
description: Use when an agent is running inside Zentty or needs to discover panes, split or grid layouts, float, minimize or dock panes, open temporary command overlays, focus panes, type into or read other panes, watch agent and pane events, launch nested coding agents, or notify the user through the Zentty CLI.
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
"$ZENTTY" pane fork
"$ZENTTY" pane fork 2 --down
"$ZENTTY" layout thirds
"$ZENTTY" layout reset
```

`pane fork` branches the agent conversation in a pane into a new pane that runs the agent's own fork command, leaving the original running. It opens to the right by default (`--down` or `--worklane` to change that), prints the new pane ID, and fails with a reason when the agent can't fork or hasn't reported a session ID yet.

Create grids carefully; large grids create many live panes:

```bash
"$ZENTTY" grid 2x2
"$ZENTTY" grid 2x2 --new-only -- codex
"$ZENTTY" grid 2x3 --worklane-id new -- claude
```

## Drive And Watch Other Panes

Type into a pane, press keys, and read its screen. The destination of `send` and `send-key` must be named; to target your own pane, pass its ID. Both refuse while an agent in the target pane is mid-turn or showing an approval, decision, or sign-in prompt, because input could answer that prompt for the user. Wait for it, and pass `--force` only when the user asked you to. `send-key ... C-c` and `Escape` always go through. Empty text is an error; multi-line text is always sent as a paste.

```bash
"$ZENTTY" pane send 2 -- npm test
"$ZENTTY" pane send 2 --no-enter -- "draft text"
printf '%s\n' "$PROMPT" | "$ZENTTY" pane send 2 --paste
"$ZENTTY" pane send-key 2 C-c
"$ZENTTY" pane send-key 2 Escape
"$ZENTTY" pane read 2 --lines 40
"$ZENTTY" pane read 2 --scrollback --json
```

Wait for something to happen instead of polling the screen:

```bash
"$ZENTTY" events --json --type agent.phase --type attention
```

Each line is `{"v":1,"type":...,"ts":...}` plus fields such as `pane`, `agent`, `phase` (`running`, `needs-input`, `idle`, `exited`, ...), `interaction`, and `attention`. The first line is `stream.ready`; every change after it is reported. An unknown `--type` fails. Stop reading (or kill the process) when you have what you need.

## Floating Panes

A pane can leave the tiled layout and float above its worklane. A float can also be put away as picture in picture (a small live view in a corner) or minimized to a pill in the bottom bar. Every change keeps the same pane and process; nothing restarts.

```bash
"$ZENTTY" pane float 2
"$ZENTTY" pane pip 2 --corner top-left
"$ZENTTY" pane minimize 2
"$ZENTTY" pane restore 2
"$ZENTTY" pane dock 2
"$ZENTTY" float new --cwd ../api -- npm run dev
"$ZENTTY" float new --temporary -- htop
"$ZENTTY" float list --json
"$ZENTTY" float hide
"$ZENTTY" float show
```

- `pane float|dock|pip|minimize|restore [pane]` take a pane index or ID and default to the calling pane. Indexes follow `pane list`: tiles first, then floats in the order they were created.
- Each command sets a target state, so repeating it does nothing. `pip` and `minimize` float a tile first. `float` brings a picture-in-picture pane or pill back as a float. `restore` does the same and focuses it; on a tile it fails. `dock` puts a float back in the column it came from.
- `pip` keeps a picture-in-picture pane in its corner unless `--corner` is given (`top-left`, `top-right`, `bottom-left`, `bottom-right`); others go bottom-right. A corner holds two; a third sends the oldest to the bottom bar. Picture-in-picture panes and pills never hold keyboard focus.
- The commands act on the pane's own worklane even when the user is looking at another one, and never switch worklanes.
- `float new` opens a focused float in the calling pane's worklane, in that pane's directory unless `--cwd` is given, and prints its pane ID. A command after `--` is typed into its shell, so the float stays open when the command ends. `--temporary` floats are not restored when Zentty relaunches and do not keep their worklane open.
- `float list` lists the worklane's floats with `index`, `id`, `mode` (`floating`, `pip`, `minimized`), `frame` for a float (fractions of the canvas, origin top-left), `corner` for a picture-in-picture pane, `status` (`working`, `needs-input`, `done`, `stopped`, `check-back`, `running`, `idle`), `isFocused`, `isHidden`, and `isTemporary`. `pane list` also reports `mode` for floats.
- `float hide` hides the worklane's floats and picture-in-picture panes (pills stay); `float show` brings them back. Hidden panes keep running.
- While the user is dragging a pane, the commands fail with a message to retry.

The user drives the same states with ⌥⌘F (float or dock), ⌥⌘P, ⌥⌘M, ⌥⌘. (hide or show), ⌥⌘N (new float), and ⌥⌘` (cycle floats). A minimized agent that needs input pops up as picture in picture unless the user turned that off.

## Overlays

An overlay runs a command in a temporary float over its worklane or over one pane, without changing the layout. The default placement fills the visible worklane content with a 16 point inset. Use `--placement pane` to cover only the target pane, or `--size-percent N` (30-100) to make either placement smaller.

```bash
"$ZENTTY" overlay open --wait --notify -- git log --oneline --decorate --color --graph --all
"$ZENTTY" overlay open --follow -- lazygit
"$ZENTTY" overlay open --placement pane --wait -- git diff --color
"$ZENTTY" overlay list
"$ZENTTY" overlay show
"$ZENTTY" overlay close
```

`overlay open` prints the overlay's pane ID and never waits for the command. The default target is the calling pane, even if the user switches worklanes while the command runs. The command starts in that pane's current directory; relative `--cwd` paths resolve against the caller's directory. Without `--wait` the overlay closes when its command exits; use `--wait` for short commands so their output stays until the user closes it.

Each worklane has at most one worklane overlay, and each pane at most one pane overlay; opening one that already exists returns its ID instead of a second overlay. A pane overlay follows its pane to another worklane and closes with it. A worklane overlay moves to another pane when its owner closes, and closes with the last pane. Opening an overlay on the visible worklane gives it keyboard focus. On another worklane it waits there as a pill; pass `--follow` to switch to it, or `--notify` to post a notification (also in Zentty's inbox) that shows the overlay when followed.

`overlay show` and `overlay close` prefer the target pane's pane overlay, otherwise its worklane overlay. `overlay list` returns both for the calling or selected pane, with `placement`, owner `paneID`, `exitCode`, and `mode`. Use pane selectors and a control token to address another pane.

Overlays are floats, so `pane pip`, `pane minimize`, `pane restore`, and `float list` work on them by their pane ID. `pane dock` turns an overlay into a normal pane: it stays after its command and no longer belongs to its owner. Overlays are never restored on relaunch, and turning off "Show overlays in worklane info" in Settings hides them from the sidebar. Their shell runs Zentty's shell integration under their own pane ID, so `zentty` commands and agent status work inside them. Quitting Zentty, closing its window, or closing the pane or worklane an overlay belongs to asks first while that overlay still runs a process.

## Launch Agents Through Zentty

When starting a nested coding agent from inside Zentty, prefer the normal wrapped command if it is already on `PATH` in the Zentty pane. Zentty's wrapper adds status hooks and then execs the real tool.

Use the hidden launch command only when you explicitly need to force Zentty's bootstrap path:

```bash
"$ZENTTY" launch codex --model gpt-5
"$ZENTTY" launch claude --dangerously-skip-permissions
```

To let an agent's tmux-based teammates open as Zentty panes, launch it in team mode. `--tmux-shim` does the same for any tmux-based orchestrator, or for a login shell when no command is given:

```bash
"$ZENTTY" launch --teams claude
"$ZENTTY" launch --tmux-shim -- omx team 3:executor "fix the failing tests"
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
