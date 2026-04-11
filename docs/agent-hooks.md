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

## OpenCode

Zentty injects a local OpenCode plugin overlay via the shared agent wrapper. The plugin forwards `session.status`, `session.idle`, permission/question events, and `todo.updated`.

`todo.updated` is normalized inside the plugin into `taskProgressDoneCount` / `taskProgressTotalCount`. The Swift bridge treats those as the authoritative OpenCode task counts and uses them only for the main session's running label.
