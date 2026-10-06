---
name: zentty-cli
description: Use when an agent is running inside Zentty or needs to discover panes, split or grid layouts, focus panes, launch nested coding agents, or notify the user through the Zentty CLI.
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
