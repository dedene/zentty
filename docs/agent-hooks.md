# Agent Hooks

Zentty exports these environment variables into every pane:

- `ZENTTY_AGENT_BIN`
- `ZENTTY_CLAUDE_HOOK_COMMAND`
- `ZENTTY_WORKLANE_ID`
- `ZENTTY_PANE_ID`

`ZENTTY_CLAUDE_HOOK_COMMAND` expands to the bundled Zentty helper with the Claude bridge subcommand:

```sh
$ZENTTY_AGENT_BIN claude-hook
```

## Claude Code

Register the same command for these Claude hook events:

- `Notification`
- `UserPromptSubmit`
- `SessionStart`
- `Stop`
- `SubagentStop`

Example config snippet:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_CLAUDE_HOOK_COMMAND"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_CLAUDE_HOOK_COMMAND"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_CLAUDE_HOOK_COMMAND"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_CLAUDE_HOOK_COMMAND"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$ZENTTY_CLAUDE_HOOK_COMMAND"
          }
        ]
      }
    ]
  }
}
```

## Current Mapping

- `SessionStart` -> session/PID attach only
- `Notification`, `PermissionRequest` -> `needs-input`
- `UserPromptSubmit`, `PreToolUse`, `SubagentStart` -> `running`
- `Stop`, `SubagentStop` -> `completed`

This keeps Zentty’s sidebar and alerts aligned with Claude’s own lifecycle instead of terminal heuristics.

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
