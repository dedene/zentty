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
