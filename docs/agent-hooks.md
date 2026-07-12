# Agent Hooks

Zentty exports these environment variables into every pane:

- `ZENTTY_CLI_BIN`
- `ZENTTY_AGENT_EVENT_COMMAND`
- `ZENTTY_INSTANCE_SOCKET`
- `ZENTTY_PANE_TOKEN`
- `ZENTTY_WINDOW_ID`
- `ZENTTY_WORKLANE_ID`
- `ZENTTY_PANE_ID`

`ZENTTY_AGENT_EVENT_COMMAND` expands to the bundled Zentty helper for canonical agent events:

```sh
$ZENTTY_CLI_BIN ipc agent-event
```

## Pane Notifications

Any process running inside a Zentty pane can send an actionable local notification:

```sh
"$ZENTTY_CLI_BIN" notify --title "Build done" --subtitle "Tests passed"
```

The notification is routed through the pane's Zentty IPC context. The system notification stores the originating window, worklane, and pane IDs, so clicking the notification or choosing `Jump to Pane` brings focus back to the pane that sent it.

By default, `notify` also adds the item to Zentty's notification inbox and uses the configured notification sound. Use `--no-inbox` to only show the macOS notification, and `--silent` to suppress sound:

```sh
"$ZENTTY_CLI_BIN" notify --title "Deploy finished" --no-inbox --silent
```

`notify` is intentionally pane-local. It fails when required pane routing variables such as `ZENTTY_PANE_TOKEN`, `ZENTTY_WORKLANE_ID`, or `ZENTTY_PANE_ID` are missing.

## Claude Code

Register the same command for these Claude hook events:

- `Notification`
- `PermissionRequest`
- `UserPromptSubmit`
- `SessionStart`
- `Stop`
- `SessionEnd`
- `PreToolUse` with matcher `AskUserQuestion`
- `TaskCreated`
- `TaskCompleted`

Example config snippet:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "TaskCreated": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_AGENT_EVENT_COMMAND --adapter=claude"
          }
        ]
      }
    ]
  }
}
```

## Current Mapping

- `SessionStart` -> session/PID attach only
- `Notification`, `PermissionRequest`, `PreToolUse(AskUserQuestion)` -> `needs-input`
- `UserPromptSubmit` -> `running`
- `Stop` -> `idle`
- `SessionEnd` -> clear session + PID mapping

This keeps Zentty’s sidebar and alerts aligned with Claude’s own lifecycle instead of terminal heuristics.

### Task Progress

Claude Code task hooks are used to maintain a per-session task registry. When a top-level session emits `TaskCreated` / `TaskCompleted`, Zentty can render running status as `Running (<done>/<total>)`.

Counts are intentionally scoped to the main session only. Subagent or nested task lists are ignored so the suffix stays stable.

Claude hook execution is best effort. If the Claude adapter fails internally, Zentty returns success to Claude and suppresses stderr so users do not see hook error banners.

## Codex CLI

Zentty injects Codex hooks through per-launch `-c` config flags. It does not create a temporary `CODEX_HOME` overlay, so the user's real Codex home and config files stay untouched.
If a wrapped Codex session inherits a Zentty-managed nested `CODEX_HOME`, Zentty unsets it for the child launch so parent-session hook state does not leak into the new session.

The launch flags:

- enable Codex hooks with `features.hooks=true`
- register Zentty command hooks for the wrapped session
- pre-trust only those generated session-flag hooks with `hooks.state`

This avoids Codex's `/hooks review` prompt for Zentty's own hooks without changing the trust state for user, project, or plugin hooks.

Zentty registers these Codex hook events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `Stop`

Each hook calls:

```sh
"$ZENTTY_CLI_BIN" ipc agent-event --adapter=codex <event>
```

### Current mapping

- `SessionStart` -> PID attach + `starting`
- `UserPromptSubmit` -> `running`
- `PreToolUse` -> `running`
- `PermissionRequest` -> `needs-input` with `approval`
- `PostToolUse` -> `running`
- `Stop` -> `idle`

Codex 0.129's built-in AskUserQuestion UI does not emit a `PreToolUse` hook.
When Codex switches the terminal title to `[ ! ] Action Required | ...`, Zentty
treats that title as `needs-input` so the sidebar still reflects the blocked
session.

## GitHub Copilot CLI

Zentty injects Copilot hooks via a temporary `COPILOT_HOME` overlay so the user's real `~/.copilot` config stays untouched. Official schema: https://docs.github.com/en/copilot/reference/hooks-configuration.

The overlay:

- preserves existing Copilot config/state entries (deep-merged)
- ensures `"version": 1` at the top level (required by Copilot)
- appends Zentty hook commands without removing user hook commands

Copilot CLI exposes six hook events (all camelCase). Zentty registers the bundled helper for each:

- `sessionStart`
- `sessionEnd`
- `userPromptSubmitted`
- `preToolUse`
- `postToolUse`
- `errorOccurred`

Entry format: `{"type": "command", "bash": "<command>", "timeoutSec": N}`.

### Current mapping

- `sessionStart` -> PID attach + seed agentStatus at `idle`
- `sessionEnd` -> clear session (lifecycle payload with `state: null`)
- `userPromptSubmitted` -> no-op; OSC 9;4 (libghostty progress) drives Running
- `preToolUse` with `toolName` matching `askuserquestion*` -> `needs-input` with the parsed question text
- `postToolUse` with the matching tool -> revert to `idle` so OSC drives Running again
- `errorOccurred` -> no-op for now

### Running detection

Unlike Claude Code (which has a `Stop` hook), Copilot has no "turn complete" event. Running detection relies on libghostty's OSC 9;4 progress state (`TerminalProgressReport.indicatesActivity`): when Copilot emits `SET`/`INDETERMINATE`, the normalizer promotes the pane from `idle` to `running`; when Copilot emits `REMOVE`, it drops back to `idle`. The copilot special case in `PanePresentationNormalizer.normalizedRuntimePhase` implements this.

## Gemini CLI

Zentty injects Gemini hooks automatically for wrapped `gemini` launches by generating a per-pane system-settings overlay and pointing `GEMINI_CLI_SYSTEM_SETTINGS_PATH` at it. The user's real Gemini config is not modified.

The overlay:

- preserves any existing system settings that Gemini would have loaded
- forces `general.enableNotifications = true` for wrapped sessions
- appends Zentty hook commands without removing existing hook commands

Gemini hook commands use the hidden bundled CLI helper:

```sh
"$ZENTTY_CLI_BIN" gemini-hook
```

Zentty registers the helper for these Gemini hook events:

- `SessionStart`
- `SessionEnd`
- `BeforeAgent`
- `AfterAgent`
- `Notification`
- `BeforeTool`

### Current mapping

- `SessionStart` -> PID attach + `starting`
- `BeforeAgent` -> `running`
- `BeforeTool` -> `running` as a blocked-session recovery signal after approval
- `AfterAgent` -> `idle`
- `SessionEnd` -> clear session + PID mapping
- `Notification` with `notification_type = ToolPermission` -> `needs-input` with `approval`

### Terminal notifications

Gemini's built-in terminal notifications still matter for wrapped sessions. Zentty treats:

- `Action required` as approval-needed attention
- `Session complete` as a ready/completion signal

This gives Gemini first-class sidebar and notification behavior even when the hook payload is minimal.

## Kimi CLI

Wrapped `kimi` launches use a per-launch overlay config under Zentty's runtime directory. Zentty reads the active Kimi config source and merges in its hook block for that session.
- For the **legacy Kimi CLI**, it launches Kimi with `--config-file <overlay>`. The user's `~/.kimi/config.toml` is left untouched.
- For the **modern Kimi Code CLI**, because it no longer supports `--config-file`, Zentty creates a temporary home directory overlay, links non-config files, writes the merged config, and isolates the session by pointing the `KIMI_CODE_HOME` environment variable to it. The user's `~/.kimi-code/config.toml` is left untouched.

Kimi's own setup commands are stricter than normal chat turns:

- `kimi login` must run against Kimi's default config location. Zentty now passthroughs `kimi login` and the other Kimi management commands directly to the real Kimi binary so they keep using the default Kimi config.
- `/login` and `/model` inside a wrapped `kimi` session are not reliable because Kimi rejects those flows when launched with `--config` or `--config-file`.
- For model selection in wrapped sessions, prefer `kimi --model <model-id>` or update the default config directly (`~/.kimi/config.toml` or `~/.kimi-code/config.toml`).

Manual fallback commands:

```sh
zentty install kimi-hooks
zentty uninstall kimi-hooks
```

`zentty install kimi-hooks` remains available if you explicitly want a persistent global hook install for debugging or recovery. Set `ZENTTY_KIMI_HOOKS_DISABLED=1` to bypass Zentty's Kimi hook overlay and launch Kimi directly.

Zentty registers these Kimi hooks:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `Stop`
- `Notification` with `matcher = "permission_prompt"`
- `PreToolUse` with `matcher = "AskUserQuestion"`
- `PostToolUse` with `matcher = "AskUserQuestion"`

Each hook calls:

```sh
"$ZENTTY_CLI_BIN" ipc agent-event --adapter=kimi
```

### Current mapping

- `SessionStart` -> PID attach + `starting`
- `UserPromptSubmit` -> `running`
- `Stop` -> `idle`
- `SessionEnd` -> clear session + PID mapping
- `Notification(permission_prompt)` -> `needs-input` with `approval`
- `PreToolUse(AskUserQuestion)` -> `needs-input` with `question`
- `PostToolUse(AskUserQuestion)` -> `running`


## Pi

Wrapped `pi` launches inject an ephemeral coding-agent extension with `-e <bundle>/pi/extensions/zentty-pi-zentty.js`. The extension shares implementation with OMP via `shared/pi-family/zentty-pi-family-zentty.js` and emits canonical JSON through `zentty ipc agent-event`.

Pi management subcommands (`install`, `remove`, `update`, `list`, `config`, …) and early-exit flags (`--help`, `--version`, `--list-models`, …) bypass Zentty bootstrap so the real `pi` binary handles them unchanged. Set `ZENTTY_PI_HOOKS_DISABLED=1` to launch without the bridge.

### Current mapping

- `session_start` -> `session.start`
- `agent_start` -> `agent.running`
- `agent_end` -> `agent.idle`
- `session_shutdown` -> `session.end`

## Oh My Pi (OMP)

OMP uses the same Pi-lineage extension host and ephemeral `-e` injection pattern as Pi. Zentty prepends `-e <bundle>/omp/extensions/zentty-omp-zentty.js`, sets `ZENTTY_AGENT_CANONICAL_NAME=OMP`, and does not modify the user's OMP config. Management commands from `omp --help` (including `plugin`, `install`, `config`, …) passthrough without bootstrap; set `ZENTTY_OMP_HOOKS_DISABLED=1` to skip the bridge.

### Current mapping

Same lifecycle events as Pi (`session.start`, `agent.running`, `agent.idle`, `session.end`). OMP is a distinct tool in the sidebar (`agent.name` **OMP**, title match leading token `omp` only—not Pi's `π` rules).

## OpenCode

Zentty injects a local OpenCode plugin overlay via the shared agent wrapper. The plugin forwards `session.status`, `session.idle`, permission/question events, and `todo.updated`.

`todo.updated` is normalized inside the plugin into `taskProgressDoneCount` / `taskProgressTotalCount`. The Swift bridge treats those as the authoritative OpenCode task counts and uses them only for the main session's running label.

## Hermes Agent

Wrapped `hermes` launches get persistent status hooks in the active Hermes home (`$HERMES_HOME` or `~/.hermes`). Zentty writes a managed block to `config.yaml` and matching approvals to `shell-hooks-allowlist.json`; foreign hooks and settings are preserved.

Zentty registers these Hermes events:

- `on_session_start` / `on_session_reset` -> `session.start`
- `pre_llm_call`, non-clarify `pre_tool_call`, `post_tool_call`, `post_approval_response` -> `running`
- `post_llm_call` -> `idle`
- `pre_tool_call(clarify)` -> `needs-input` with question or decision text
- `pre_approval_request` -> `needs-input` with approval text
- `on_session_end` / `on_session_finalize` -> `session.end`

Manual control is available with `zentty install hermes-hooks` and `zentty uninstall hermes-hooks`. Disable automatic hook setup with `ZENTTY_HERMES_HOOKS_DISABLED=1`.

When Hermes provides a real session id, Zentty can restore the pane with `hermes --resume <session_id>` and preserves the captured `HERMES_HOME` value.

## Grok Build (Early Beta — May 2026)

Grok Build (the `grok` CLI from xAI) is in early beta. Per Grok's official docs (`~/.grok/docs/user-guide/10-hooks.md`), its "Always trusted" global hook source is `~/.grok/hooks/*.json` — a single JSON file there registers hooks that fire on every grok session with no `/hooks-trust` ceremony and no `/plugins enable`.

Zentty's `GrokHooksInstaller` writes exactly two files into that location:

| Path | Purpose |
|---|---|
| `~/.grok/hooks/zentty-status.json` | Registers all managed events. JSON only — Grok ignores `.sh` files at this depth. |
| `~/.grok/hooks/zentty-status/01-zentty-status.sh` | Thin forwarder that `exec`s `zentty ipc agent-event --adapter=grok`. Lives in a subdirectory so the `*.json` glob doesn't pick it up. |

Zentty provides first-class support:

- **Automatic on first run**: the first time `grok` (or `zentty launch grok`) runs inside a Zentty pane, Zentty drops the two files above. You get "Running (N/M)" for `TodoWrite` task lists and proper `needs-input` badges immediately.
- **Manual**: `zentty install grok-hooks` / `zentty uninstall grok-hooks`.
- `--adapter=grok` plus a Swift-side re-emitter produces canonical `task.progress`, `agent.needs-input`, and `session.start` events alongside the raw forward.

Disable with `ZENTTY_GROK_HOOKS_DISABLED=1`.

### Schema gotcha (lifecycle events vs tool-use events)

Grok's hook schema strictly forbids a `matcher` field on lifecycle events. From the binary's own runtime log: `"lifecycle hooks () must not specify a matcher in v0"`. Including a matcher on `SessionStart`, `Stop`, `Notification`, etc. silently invalidates the entry — Grok loads the file, drops the bogus event, and you see no firings.

Only `PreToolUse` and `PostToolUse` may specify a `matcher`. Our installer enforces this split: the lifecycle events come out matcher-free; the tool-use events get `matcher: ".*"`. There are Logic tests that pin this shape (`test_grok_hooks_installer_lifecycle_events_have_no_matcher_field`, `test_grok_hooks_installer_tool_use_events_have_matcher_dot_star`).

### Zero external runtime dependencies

The forwarder is a single `exec "$ZENTTY_BIN" ipc agent-event --adapter=grok` line. All payload parsing lives in Swift — see [`GrokCanonicalReEmitter`](../Zentty/AppState/Agent/GrokCanonicalReEmitter.swift). The CLI inspects the forwarded payload and, when it represents a TodoWrite update, an ask/permission prompt, or a SessionStart, fans out an additional `zentty ipc agent-event` request carrying the canonical Agent Status Protocol envelope.

### Diagnostic commands

```bash
grok inspect          # should list our entries under Hooks
# In the Grok TUI:
# /hooks               # opens the hooks/plugins modal
```

`grok inspect`'s Hooks section primarily lists plugin-derived entries, so our settings-file hooks may not show up by name there. The easiest end-to-end check is to launch grok and watch the Zentty sidebar — `Running` ↔ `Idle` transitions plus task progress confirm the forwarders are firing.

### Events with smart detection

Detection runs in Swift inside the `zentty ipc agent-event --adapter=grok` CLI; the shell scripts only forward stdin.

- `PreToolUse` — when `tool_name`/`tool_use.name` resolves to `TodoWrite`/`todo_write`/`WriteTodos`, emits canonical `task.progress` with `done`/`total` derived from the `todos[]` shape (top-level or nested under `tool_use.input` / `tool_input` / `input`).
- `PreToolUse` — when the tool is `AskUserQuestion`/`ask_user_question`/similar, emits canonical `agent.needs-input` with `kind: "question"`.
- `Notification` — emits `agent.needs-input` when `notification_type` is on a structured allowlist (`permission`, `ask`, `question`, …) or the message contains unambiguous words (`permission`, `approve`, `needs input`). Uses word-boundary matching so "Task completed" never falsely triggers needs-input.
- `SessionStart` — emits canonical `session.start` with the session id resolved from any of `session_id`, `session.id`, `context.session_id`, `data.id`, etc.
- `SessionEnd`, `UserPromptSubmit`, `Stop`, `PostToolUse`, etc. — forwarded raw; the `grokAdapter` updates lifecycle state.

### Uninstall cleans up legacy artifacts

Earlier Zentty versions wrote to several places that Grok does not actually read as hook sources: `~/.grok/user-settings.json`, `~/.grok/hooks-paths`, and a plugin manifest at `~/.grok/plugins/zentty-status/`. None of these fire hooks, but they linger on disk for users upgrading. `zentty uninstall grok-hooks` removes the current layout AND all of those legacy artifacts so re-installing leaves a clean state.

See the [Agent Status Protocol](agent-status-protocol.md) for the canonical events Zentty expects.

Feedback via `/feedback` inside Grok is welcome.
