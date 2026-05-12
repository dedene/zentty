# Zentty CLI

Zentty includes an embedded `zentty` CLI for scripting windows, worklanes, and panes.

Most commands must run inside a Zentty pane because they use pane environment variables such as `ZENTTY_INSTANCE_SOCKET`, `ZENTTY_WINDOW_ID`, `ZENTTY_WORKLANE_ID`, `ZENTTY_PANE_ID`, and `ZENTTY_PANE_TOKEN`. Commands that target another pane can use selector flags when a control token is available.

## Common Selectors

Pane and layout commands accept these selector flags unless noted otherwise:

- `--window-id <window-id>`: target a specific window.
- `--worklane-id <worklane-id>`: target a specific worklane.
- `--pane-id <pane-id>`: target a specific pane by ID.
- `--pane-index <pane-index>`: target a specific 1-based pane index within the selected worklane.
- `--pane-token <pane-token>`: authorize out-of-pane control.

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
zentty split [right|left|up|down] [--equal|--golden|--ratio <ratio>] [selectors]
zentty hsplit [--equal|--golden|--ratio <ratio>] [selectors]
zentty vsplit [--equal|--golden|--ratio <ratio>] [selectors]
```

Options:

- `--equal`: split into equal halves.
- `--golden`: split using the golden ratio, with the focused pane around 62%.
- `--ratio <ratio>`: set the focused pane percentage, for example `60`.

Examples:

```bash
zentty split right
zentty split down --equal
zentty hsplit --ratio 70
zentty vsplit --pane-index 2
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
- `--pane-token <pane-token>`: authorize out-of-pane control.

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
