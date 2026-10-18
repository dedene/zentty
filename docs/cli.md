# Zentty CLI

Zentty includes an embedded `zentty` CLI for scripting windows, worklanes, and panes.

Most commands must run inside a Zentty pane because they use pane environment variables such as `ZENTTY_INSTANCE_SOCKET`, `ZENTTY_WINDOW_ID`, `ZENTTY_WORKLANE_ID`, `ZENTTY_PANE_ID`, and `ZENTTY_PANE_TOKEN`. Commands that target another pane can use selector flags when a control token is available.

## Open a Folder From Outside Zentty

To open a new window at a directory from a script, a URL handler, or another app, hand the folder to Zentty through LaunchServices:

```bash
open -a Zentty ~/Development/my-project
```

This reaches the running instance, or launches Zentty first if it is not running. Finder's "Open With" and dropping a folder on the Dock icon do the same. A file opens its parent folder.

## Common Selectors

Pane and layout commands accept these selector flags unless noted otherwise:

- `--window-id <window-id>`: target a specific window.
- `--worklane-id <worklane-id>`: target a specific worklane.
- `--pane-id <pane-id>`: target a specific pane by ID.
- `--pane-index <pane-index>`: target a specific 1-based pane index within the selected worklane.
- `--pane-token <pane-token>`: authorize out-of-pane control. The token only authenticates; it does not pick the pane. Outside the target pane, also pass `--pane-id` (or `--worklane-id` / `--window-id`) to say which pane you mean.

Discovery commands accept:

- `--window-id <window-id>`: filter by window.
- `--worklane-id <worklane-id>`: filter by worklane.
- `--include-control-token`: include pane control tokens in JSON output.
- `--json`: output JSON.

## Version

Show the running Zentty version and bundled git commit.

```bash
zentty version
```

## Discovery

List windows, worklanes, and panes.

```bash
zentty list [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
zentty list windows [--json]
zentty list worklanes [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
zentty list panes [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
```

Aliases:

```bash
zentty window list [--json]
zentty worklane list [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
zentty pane list [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
```

`zentty pane list` defaults to the calling pane's current worklane when no window or worklane filter is provided. Use `zentty list panes` for broader discovery.

Examples:

```bash
zentty list
zentty list panes --json
zentty list panes --worklane-id wl_123 --include-control-token --json
```

## Select

Resolve a single pane target and print its IDs.

```bash
zentty select pane [--window-id <window-id>] [--worklane-id <worklane-id>] [--pane-id <pane-id>] [--pane-index <pane-index>] [--shell] [--include-control-token]
```

Options:

- `--shell`: print `export ...` lines for the selected pane.
- `--include-control-token`: include `ZENTTY_PANE_TOKEN` when printing shell exports.

Examples:

```bash
zentty select pane --pane-index 2
zentty select pane --pane-index 2 --shell --include-control-token
```

## Split

Split a pane in a direction. `hsplit` is an alias for `split right`; `vsplit` is an alias for `split down`.

```bash
zentty split [right|left|up|down] [--equal|--golden|--ratio <ratio>] [selectors] [-- <command> ...]
zentty hsplit [--equal|--golden|--ratio <ratio>] [selectors] [-- <command> ...]
zentty vsplit [--equal|--golden|--ratio <ratio>] [selectors] [-- <command> ...]
```

Options:

- `--equal`: split into equal halves.
- `--golden`: split using the golden ratio, with the focused pane around 62%.
- `--ratio <ratio>`: set the focused pane percentage, for example `60`.

To run a program in the new pane, put `--` before the program name and its
arguments, for example `zentty split right -- claude`. With `split`, always
write the direction before `--`. With `hsplit` or `vsplit`, omit the direction:
`zentty hsplit -- claude`.

Put Zentty options, such as `--equal` or `--pane-index 2`, before `--`.
Everything after it is passed to the program, not treated as a Zentty option.

If you leave out the program (`zentty split right --`), the new pane opens a
normal shell.

Examples:

```bash
zentty split right
zentty split down --equal
zentty hsplit --ratio 70
zentty vsplit --pane-index 2
zentty split right -- claude
zentty split down --equal -- codex --model gpt-5.2
zentty hsplit --pane-index 2 -- npm run dev
zentty vsplit -- python3 -m http.server 8000
```

## Grid

Turn the selected pane into a fixed rows-by-columns grid.

```bash
zentty grid <rows>x<columns> [options] [-- <command> ...]
```

By default, a command after `--` runs in every grid pane, including the source pane. Use `--new-only` to leave the source pane untouched and run the command only in panes Zentty creates for the grid.

Options:

- `--focus source|first|last`: choose the focused pane after the grid is created. Default: `source`.
- `--new-only`: run the command only in newly-created panes.
- `--include-source`: explicitly run the command in the source pane too. This is the default.
- `--window-id <window-id|new>`: target an existing window, or use `new` to create a new window for the grid.
- `--worklane-id <worklane-id|new>`: target an existing worklane, or use `new` to create a new worklane for the grid.
- `--pane-id <pane-id>`: select the source pane by ID.
- `--pane-index <pane-index>`: select the source pane by 1-based index within the selected worklane.
- `--pane-token <pane-token>`: authorize out-of-pane control. Pair it with `--pane-id` (or `--worklane-id` / `--window-id`) when running outside the source pane.

When `--window-id new` or `--worklane-id new` is used, Zentty still uses the selected source pane as the context for the new grid. A new worklane inherits the source pane's working directory and local Ghostty configuration where possible. A new window inherits the source pane's working directory.

Examples:

```bash
zentty grid 2x2
zentty grid 3x3 -- claude
zentty grid 2x3 -- codex --model gpt-5.2
zentty grid 2x2 --new-only -- claude
zentty grid 2x2 --worklane-id new -- claude
zentty grid 2x2 --window-id new -- claude
```

## Layout

Apply a layout preset to the selected pane's worklane.

```bash
zentty layout <preset> [-v|--vertical] [selectors]
```

Presets:

- `full`
- `halves`
- `thirds`
- `quarters`
- `golden-wide`
- `golden-narrow`
- `golden-tall`
- `golden-short`
- `reset`

Options:

- `-v, --vertical`: apply vertically as panes per column instead of horizontally as columns.

Examples:

```bash
zentty layout halves
zentty layout thirds --vertical
zentty layout reset
```

## Pane Commands

### List Panes

List panes in the current worklane by default.

```bash
zentty pane list [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
```

### Focus

Focus a pane by index, pane ID, or direction.

```bash
zentty pane focus [<pane-index|pane-id|left|right|up|down>] [selectors]
```

Examples:

```bash
zentty pane focus 2
zentty pane focus left
zentty pane focus --pane-id pn_123
```

### Close

Close a pane. With no positional target, closes the current or selected pane.

```bash
zentty pane close [<pane-index|pane-id>] [selectors]
```

Examples:

```bash
zentty pane close
zentty pane close 2
zentty pane close --pane-id pn_123
```

### Fork

Fork the agent conversation running in a pane into a new pane. The new pane runs the agent's own fork command in the agent's working directory, so the original conversation keeps running. With no positional target, forks the current or selected pane. Prints the new pane ID.

```bash
zentty pane fork [<pane-index|pane-id>] [--down | --worklane] [selectors]
```

Options:

- `--down`: open the fork below the source pane.
- `--worklane`: open the fork in a new worklane.

Without either flag the fork opens to the right of the source pane, or wherever `agents.fork_destination` in `config.toml` points.

Forkable agents and the command Zentty runs:

| Agent | Fork command |
| --- | --- |
| Claude Code | `claude --resume <id> --fork-session` |
| Codex | `codex fork <id>` |
| OpenCode | `opencode --session <id> --fork` |
| Droid | `droid --fork <id>` |
| Grok Build | `grok --resume <id> --fork-session` |
| Pi | `pi --fork <id>` |
| Kilo Code | `kilo --session <id> --fork` |
| Other agent definitions with a `fork` block | the definition's `fork.command` |

Other agents have no fork command. Forking also needs the session ID the agent reports to Zentty and a local pane; otherwise the command fails with the reason.

Examples:

```bash
zentty pane fork
zentty pane fork 2 --down
zentty pane fork --pane-id pn_123 --worklane
```

### Zoom

Toggle zoomed-out pane view for the selected pane.

```bash
zentty pane zoom [selectors]
```

### Resize

Resize the focused pane by direction or set a column width percentage.

```bash
zentty pane resize <left|right|up|down|percentage> [selectors]
```

Examples:

```bash
zentty pane resize left
zentty pane resize 60%
```

### Send Text

Type text into a pane, then press Enter.

```bash
zentty pane send [<pane-index|pane-id>] [--no-enter] [--paste] [--force] [selectors] -- <text...>
```

The text after `--` is typed as if from the keyboard. Without `--`, the text is read from stdin when stdin is a pipe or a file, and one trailing newline is dropped. Empty text is an error, so an empty variable never turns into a bare Enter; to press Enter alone, use `pane send-key <pane> Enter`. Enter follows after a short pause, so programs that read input in chunks see a submit instead of a pasted newline.

Text with more than one line is always delivered as a paste, so a shell does not run each line as it arrives.

- `--no-enter`: type the text without pressing Enter.
- `--paste`: deliver the text as a paste. The program receives a bracketed paste when it asked for one.
- `--force`: send even when the agent in the target pane is mid-turn or showing a prompt.

The destination must be named, with a positional pane index or ID, or with `--pane-id`, `--pane-index`, or `--worklane-id`. To send to your own pane, pass its ID.

If an agent in the target pane is mid-turn, or is showing an approval, decision, or sign-in prompt, the command fails and sends nothing unless you pass `--force`. Typed characters can act as menu hotkeys in those prompts, and Enter picks the highlighted option. An agent asking a question or waiting for plain input, an idle agent, and a stopped agent are fine to send to. A pane whose terminal has not started yet, for example right after a restore, fails with `pane_unavailable` instead of losing the text.

Examples:

```bash
zentty pane send 2 -- npm test
zentty pane send 2 --no-enter -- 'git commit -m "'
git diff | zentty pane send 3 --paste
zentty pane send --pane-id pn_123 --pane-token "$TOKEN" -- yes
```

### Send Keys

Press one or more keys in a pane.

```bash
zentty pane send-key [<pane-index|pane-id>] <key>... [--force] [selectors]
```

Key names are case-insensitive: `Enter`, `Escape`, `Tab`, `BTab`, `Space`, `BSpace`, `Up`, `Down`, `Left`, `Right`, `S-Up` (and the other arrows), `Home`, `End`, `PageUp`, `PageDown`, `Insert`, `Delete`, `F1` to `F12`, `C-<letter>` for Control, and `M-<key>` for Meta. Any single character is sent as typed. An unknown name fails instead of being typed.

Named keys go through the terminal's key encoder, so arrows and function keys produce the sequences the running program expects. A leading pane index or ID picks the pane; as with `pane send`, the destination must be named.

`pane send-key` follows the same agent rule as `pane send`, and `--force` overrides it. `C-c` and `Escape` on their own always go through, so interrupting an agent never needs `--force`.

Examples:

```bash
zentty pane send-key 2 C-c
zentty pane send-key 2 Up Enter
zentty pane send-key --pane-id pn_123 --pane-token "$TOKEN" Escape
```

### Read

Print a pane's screen. Defaults to the calling pane.

```bash
zentty pane read [<pane-index|pane-id>] [--lines <n>] [--scrollback] [--json] [selectors]
```

- `--lines <n>`: only the last `n` lines.
- `--scrollback`: include scrollback history, not just the visible screen.
- `--json`: output an object with `paneID`, `worklaneID`, `windowID`, `columns`, `rows`, `includesScrollback`, `lineLimit`, and `text`.

Examples:

```bash
zentty pane read 2 --lines 20
zentty pane read --pane-id pn_123 --pane-token "$TOKEN" --scrollback > pane.log
```

## Worklane Commands

### List Worklanes

List worklanes.

```bash
zentty worklane list [--window-id <window-id>] [--worklane-id <worklane-id>] [--include-control-token] [--json]
```

### Color

Set, clear, or list sidebar colors for worklanes.

```bash
zentty worklane color [<color|reset|default>] [--id <worklane-id>] [--list]
```

Colors:

```text
red orange amber yellow lime green teal cyan blue indigo purple pink
```

Examples:

```bash
zentty worklane color blue
zentty worklane color reset
zentty worklane color --id wl_123 purple
zentty worklane color --list
```

## Window Commands

### List Windows

List windows.

```bash
zentty window list [--json]
```

## Events

Stream workspace events until interrupted.

```bash
zentty events [--json] [--type <type>]... [selectors]
```

- `--json`: print one JSON object per line (NDJSON). Without it, each event is one readable line.
- `--type <type>`: only events of this type (`agent.phase`) or family (`pane`, also written `pane.*`). Repeat it to select several. A name that matches no event type fails.

Every JSON event has a versioned envelope, `{"v":1,"type":"...","ts":"..."}`, with ISO 8601 UTC timestamps. The other fields depend on the type, and absent fields are left out:

| Type | Fields |
| --- | --- |
| `stream.ready` | First line. Every change after it is reported. |
| `stream.dropped` | `count`. Events were dropped because the reader fell behind. |
| `worklane.created`, `worklane.closed` | `window`, `worklane` |
| `worklane.activated` | `window`, `worklane`, `pane` |
| `pane.created`, `pane.closed`, `pane.focused` | `window`, `worklane`, `pane` |
| `pane.moved` | `window`, `worklane`, `pane`, `from_worklane` |
| `agent.phase` | `window`, `worklane`, `pane`, `agent`, `phase`, `previous_phase`, `interaction` |
| `attention.raised` | `window`, `worklane`, `pane`, `agent`, `attention`, `interaction` |
| `attention.cleared` | `window`, `worklane`, `pane`, `agent`, `previous_attention` |

`pane.focused` reports a worklane's focused pane changing, in background worklanes too. `worklane.activated` reports a window switching to another worklane, with that worklane's focused pane. Together they tell which pane each window shows.

`phase` is `starting`, `running`, `needs-input`, `unresolved-stop`, `idle`, or `exited` when the agent leaves the pane. `interaction` is `approval`, `question`, `decision`, `auth`, or `generic-input` while an agent needs input. `attention` is `needs-input`, `unresolved-stop`, `ready`, or `check-back`.

The stream covers every window of the Zentty instance the command talks to, and only that instance. It needs a pane token, like the pane commands: inside a pane the environment provides one, and from outside pass `--pane-id` and `--pane-token`. A reader that stops reading loses events rather than slowing Zentty down, and finds a `stream.dropped` line with the count when it catches up.

Examples:

```bash
zentty events --json --type agent.phase --type attention
zentty events --json | jq -c 'select(.type == "attention.raised")'
```

## Notifications

Send a pane-local Zentty notification.

```bash
zentty notify --title <title> [--subtitle <subtitle>] [--no-inbox] [--silent]
```

Options:

- `--title <title>`: notification title.
- `--subtitle <subtitle>`: optional notification subtitle.
- `--no-inbox`: do not add the notification to Zentty's inbox.
- `--silent`: suppress the notification sound.

Example:

```bash
zentty notify --title "Agent ready" --subtitle "Review the result"
```

## Agent Integrations

Install or remove shell hook integrations managed by Zentty.

```bash
zentty install <cursor-hooks|kimi-hooks>
zentty uninstall <cursor-hooks|kimi-hooks>
```

Examples:

```bash
zentty install cursor-hooks
zentty uninstall kimi-hooks
```
