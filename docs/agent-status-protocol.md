# Agent Status Protocol

Version 1 — Draft

## 1. Overview

The Agent Status Protocol defines how coding agents (Claude Code, GitHub Copilot, Codex, Gemini CLI, OpenCode, or any custom tool) report lifecycle state, interaction needs, and task progress to Zentty. An agent that implements this protocol gets sidebar status indicators, attention badges, crash detection, and task progress display — without any changes to Zentty's codebase.

The protocol is transport-agnostic from the agent's perspective: send a JSON event to the bundled `zentty` CLI on stdin. Zentty handles the rest.

## 2. Concepts

**Pane.** A single terminal session inside Zentty. Each pane runs one shell process and can host one or more agent sessions.

**Worklane.** A group of related panes displayed together. A worklane is the primary unit of organization in the sidebar.

**Session.** A logical agent invocation identified by a `session.id`. An agent process may spawn child sessions (subagents), forming a hierarchy via `session.parentId`. Multiple sessions can coexist in a single pane; Zentty picks the highest-priority one for display.

**Phase.** The agent's current lifecycle state. One of:

| Phase | Meaning |
|---|---|
| `starting` | Session is initializing |
| `running` | Agent is actively working |
| `needs-input` | Agent is blocked waiting for human action |
| `idle` | Turn complete, agent is waiting for the next prompt |
| `unresolved-stop` | *(internal only)* Agent process died unexpectedly while running |

Agents send the first four. Zentty derives `unresolved-stop` from PID death detection.

**Interaction kind.** When an agent needs human input, it classifies what kind of input is required. This drives the sidebar badge and attention indicator. See [section 7](#7-interaction-kinds).

**Signal confidence.** How reliable a status signal is. Explicit hook events are authoritative; title-based heuristics are weak. When multiple signals conflict, higher confidence wins. See [section 9](#9-signal-confidence--priority).

## 3. Transport

### Environment Variables

Zentty sets these environment variables in every pane. Agents read them to address events to the correct pane.

| Variable | Required | Description |
|---|---|---|
| `ZENTTY_CLI_BIN` | yes | Absolute path to the bundled `zentty` CLI |
| `ZENTTY_INSTANCE_SOCKET` | yes | Absolute path to the running Zentty instance socket |
| `ZENTTY_PANE_TOKEN` | yes | Opaque pane-scoped auth token |
| `ZENTTY_WORKLANE_ID` | yes | Opaque identifier for the target worklane |
| `ZENTTY_PANE_ID` | yes | Opaque identifier for the target pane |
| `ZENTTY_WINDOW_ID` | no | Opaque identifier for the target window |

Do not parse or construct these identifiers. Pass them through verbatim.

### Invocation

Send a JSON event on stdin to the `ipc agent-event` subcommand:

```sh
echo '<json>' | "$ZENTTY_CLI_BIN" ipc agent-event
```

Or with a heredoc for readability:

```sh
"$ZENTTY_CLI_BIN" ipc agent-event <<'JSON'
{
  "version": 1,
  "event": "agent.running",
  "agent": { "name": "my-agent" },
  "state": { "text": "Thinking..." }
}
JSON
```

**Exit codes.** `0` on success, non-zero on failure. Errors are written to stderr.

**Fire-and-forget.** Agents should not block on the result. Launch the command asynchronously or accept that a brief fork/exec is the cost of a status update.

**Timeout.** Zentty processes events in under 10ms. If the agent's hook system supports timeouts, 5-10 seconds is a safe ceiling.

## 4. Events

### `session.start`

Seeds a new agent session. Send this once when the agent process begins.

- Sets phase to `starting` (default) or `idle` depending on the agent's initialization model.
- If `agent.pid` is provided, Zentty begins monitoring the process. If the PID dies while the agent is in `running` or `needs-input` phase, Zentty marks the session as `unresolved-stop`.
- `session.id` is recommended. If omitted, Zentty generates a synthetic ID scoped to the pane.

```json
{
  "version": 1,
  "event": "session.start",
  "agent": { "name": "my-agent", "pid": 12345 },
  "session": { "id": "abc-123" },
  "context": { "workingDirectory": "/Users/dev/project" }
}
```

### `session.end`

Tears down the session. The session is removed from tracking and its status is cleared from the sidebar.

No `state` object is needed. The session is unconditionally removed.

```json
{
  "version": 1,
  "event": "session.end",
  "session": { "id": "abc-123" }
}
```

### `agent.running`

The agent is actively working. Clears any pending interaction state.

```json
{
  "version": 1,
  "event": "agent.running",
  "state": { "text": "Editing main.swift" }
}
```

### `agent.idle`

The agent's turn is complete. It is waiting for the next user prompt.

When `state.stopCandidate` is `true`, Zentty applies a 2-second grace window before committing to idle. This allows detecting the difference between a clean turn completion and a crash — if the PID dies during the grace window, Zentty marks the session as `unresolved-stop` instead of `idle`.

```json
{
  "version": 1,
  "event": "agent.idle"
}
```

With stop-candidate semantics:

```json
{
  "version": 1,
  "event": "agent.idle",
  "state": { "stopCandidate": true }
}
```

### `agent.needs-input`

The agent is blocked and needs human action to continue. The `state.interaction` object classifies what kind of input is needed (see [section 7](#7-interaction-kinds)).

If `state.interaction` is omitted, Zentty defaults to `generic-input`.

```json
{
  "version": 1,
  "event": "agent.needs-input",
  "state": {
    "text": "Allow write access to config.json?",
    "interaction": {
      "kind": "approval",
      "text": "Allow write access to config.json?"
    }
  }
}
```

### `agent.input-resolved`

The human responded and the agent is resuming work. Transitions back to `running` and clears interaction state.

```json
{
  "version": 1,
  "event": "agent.input-resolved"
}
```

### `task.progress`

Updates task progress counters. Does not change the lifecycle phase by itself — the agent is presumably already `running`.

`progress.total` must be greater than 0. `progress.done` is clamped to `[0, total]`.

The sidebar displays progress as "Running (3/7)".

```json
{
  "version": 1,
  "event": "task.progress",
  "progress": { "done": 3, "total": 7 }
}
```

## 5. JSON Schema

Every event uses the same JSON envelope. Only `version` and `event` are required — everything else is optional with sensible defaults.

```jsonc
{
  "version": 1,
  "event": "<event-name>",
  "agent": { ... },
  "session": { ... },
  "state": { ... },
  "progress": { ... },
  "artifact": { ... },
  "context": { ... }
}
```

### Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `version` | integer | yes | Protocol version. Must be `1`. |
| `event` | string | yes | One of: `session.start`, `session.end`, `agent.running`, `agent.idle`, `agent.needs-input`, `agent.input-resolved`, `task.progress`. |

### `agent` Object

Information about the agent tool. Sent once in `session.start`; optional on subsequent events (Zentty remembers it per session).

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | inferred | Display name shown in sidebar. If omitted, Zentty infers from process name or terminal title. Known names (`Claude Code`, `Codex`, `Copilot`, `Gemini`, `OpenCode`) enable agent-specific presentation. Any other string creates a custom agent entry. |
| `pid` | integer | none | Process ID for crash/exit detection. If omitted, Zentty cannot detect crashes — the session will eventually expire via the stale-session timer (30 minutes). |

### `session` Object

Session identity and hierarchy.

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | string | auto-generated | Unique session identifier. If omitted, Zentty generates a synthetic ID scoped to the pane. Recommended for agents that support subagents or multiple concurrent sessions. |
| `parentId` | string | none | Parent session ID for subagent hierarchies. When set, Zentty tracks this session as a child. Task progress from child sessions is scoped separately from the parent. |

### `state` Object

Lifecycle state details. Relevant for `agent.running`, `agent.idle`, `agent.needs-input`.

| Field | Type | Default | Description |
|---|---|---|---|
| `text` | string | none | Human-readable status message displayed in the sidebar. Keep it short — one line, under 80 characters. |
| `stopCandidate` | boolean | `false` | Only for `agent.idle`. When `true`, Zentty waits 2 seconds before committing to idle. If the PID dies during this window, the session transitions to `unresolved-stop` instead. Use this for events where the agent might be exiting (e.g., `Stop` in Claude Code). |
| `interaction` | object | see below | Only for `agent.needs-input`. Classifies the type of human input required. |

### `state.interaction` Object

| Field | Type | Default | Description |
|---|---|---|---|
| `kind` | string | `generic-input` | One of: `approval`, `question`, `decision`, `auth`, `generic-input`. See [section 7](#7-interaction-kinds) for when to use each. |
| `text` | string | none | Descriptive text about what the agent needs. Displayed as the interaction prompt in the sidebar. |

### `progress` Object

Task progress counters. Can be sent with any event but is primarily intended for `task.progress`. Both fields are required when the `progress` object is present.

| Field | Type | Required | Description |
|---|---|---|---|
| `done` | integer | yes | Number of completed tasks. Clamped to `[0, total]`. |
| `total` | integer | yes | Total number of tasks. Must be greater than 0. |

### `artifact` Object

Links to external artifacts (PRs, session URLs, etc.) associated with the agent's work.

| Field | Type | Default | Description |
|---|---|---|---|
| `kind` | string | `generic` | One of: `pull-request`, `session`, `share`, `compare`, `generic`. |
| `label` | string | none | Display label for the artifact link (e.g., "PR #42"). |
| `url` | string | none | URL for the artifact. Must be a valid URL. |

### `context` Object

Contextual metadata about the agent's environment.

| Field | Type | Default | Description |
|---|---|---|---|
| `workingDirectory` | string | none | Absolute path to the agent's current working directory. Used for branch detection and PR association. |

## 6. Lifecycle State Machine

```
                    ┌─────────────────────────────────┐
                    │         session.start            │
                    └────────────┬────────────────────┘
                                 │
                                 ▼
                            ┌─────────┐
                            │ starting │
                            └────┬────┘
                                 │
                   agent.running │
                                 ▼
                  ┌──────── ┌─────────┐ ────────┐
                  │         │ running │         │
                  │         └────┬────┘         │
                  │              │               │
   agent.needs-input        agent.idle      (PID dies)
                  │              │               │
                  ▼              ▼               ▼
          ┌──────────────┐  ┌──────┐   ┌─────────────────┐
          │ needs-input  │  │ idle │   │ unresolved-stop  │
          └──────┬───────┘  └──┬───┘   │  (internal only) │
                 │             │       └─────────────────┘
  agent.input-resolved    session.end
                 │             │
                 ▼             ▼
             ┌─────────┐  (removed)
             │ running │
             └─────────┘
```

### Transition Rules

- **`session.start`** → `starting`. If the agent immediately knows it's working, it can follow up with `agent.running`.
- **`agent.running`** → `running`. Clears any interaction state. Can be sent from any phase.
- **`agent.idle`** → `idle`. If `stopCandidate` is `true`, the reducer holds the session in `running` for a 2-second grace window before committing to `idle`.
- **`agent.needs-input`** → `needs-input`. Sets the interaction kind (defaults to `generic-input`).
- **`agent.input-resolved`** → `running`. Clears interaction state and resumes.
- **`session.end`** → session removed entirely.
- **PID death** (internal) → `unresolved-stop`. Zentty polls tracked PIDs. If a PID dies while the session is in `running` or `needs-input`, Zentty transitions to `unresolved-stop` with a 10-minute visibility window.

### Visibility Windows

Zentty automatically clears stale sessions:

| Condition | Window |
|---|---|
| `idle` session with no further activity | 2 minutes |
| `unresolved-stop` session | 10 minutes |
| Any session with no PID and no interaction | 30 minutes |

Agents do not need to manage these timers. Zentty handles cleanup.

## 7. Interaction Kinds

When sending `agent.needs-input`, the `state.interaction.kind` field classifies the type of human action required. Zentty uses this for sidebar badges and attention prioritization.

| Kind | Priority | Use when | Sidebar label | Symbol |
|---|---|---|---|---|
| `approval` | 5 (highest) | Agent needs explicit permission for an action (file write, command execution) | "Requires approval" | `checkmark.shield` |
| `question` | 4 | Agent asks an open-ended question requiring a typed response | "Needs decision" | `list.bullet` |
| `decision` | 3 | Agent presents a set of choices to pick from | "Needs decision" | `list.bullet` |
| `auth` | 2 | Authentication or sign-in is required before the agent can continue | "Needs sign-in" | `key.fill` |
| `generic-input` | 1 (lowest) | Catch-all for unclassified input needs | "Needs input" | `ellipsis.circle` |

When the interaction kind is omitted, `generic-input` is used as the default.

**Priority matters when multiple sessions coexist in the same pane.** If one session needs `approval` and another needs `generic-input`, the approval session takes precedence in the sidebar display.

### Choosing the Right Kind

- Use `approval` when the agent is about to perform a side-effecting action and wants explicit go-ahead.
- Use `question` for free-form prompts where the user types a response.
- Use `decision` when presenting a list of options (e.g., "Which file should I edit?").
- Use `auth` when an OAuth flow, API key, or sign-in is blocking the agent.
- Use `generic-input` as a fallback when the input type is unknown or doesn't fit the above categories.

## 8. Session Hierarchies

Agents that spawn child processes (subagents) can model this relationship using `session.parentId`.

```json
{
  "version": 1,
  "event": "session.start",
  "agent": { "name": "Claude Code", "pid": 67890 },
  "session": { "id": "sub-456", "parentId": "main-123" }
}
```

### Behavior

- Child sessions appear in the same pane as the parent.
- Zentty picks the highest-priority session for sidebar display (see [section 9](#9-signal-confidence--priority)).
- Task progress counters are scoped to the session that reports them. A parent session's "Running (2/5)" counter is not affected by child session task events.
- When the parent session ends, child sessions are not automatically cleared. Each session manages its own lifecycle.

### Recommendation

Most agents do not need subagent support. Use a single session with a stable `session.id` and skip `parentId` entirely.

## 9. Signal Confidence & Priority

When multiple signals arrive for the same pane (e.g., from concurrent sessions, or from both hook events and terminal heuristics), Zentty resolves conflicts using a priority hierarchy.

### Phase Priority

The session with the highest-priority phase wins the sidebar display:

| Phase | Priority |
|---|---|
| `needs-input` | 4 (highest) |
| `unresolved-stop` | 3 |
| `running` | 2 |
| `idle` | 1 |
| `starting` | 0 (lowest) |

An `idle` session outranks a `starting` one because idle indicates a completed turn — the user may have actionable output to review — while `starting` is transient initialization noise.

### Signal Confidence

Events sent via `agent-event` are treated as `explicit` confidence (highest). Zentty also infers agent state from terminal titles and OSC progress sequences — these are `weak` or `strong` signals that yield to explicit ones.

| Confidence | Priority | Source |
|---|---|---|
| `explicit` | 2 | Hook events, `agent-event` protocol |
| `strong` | 1 | Classified heuristics (e.g., title pattern match) |
| `weak` | 0 | Generic inferences (e.g., OSC progress without recognized agent) |

### Conflict Resolution

When two sessions compete for display:

1. Phase priority wins.
2. If tied, higher confidence wins.
3. If tied, signal origin wins (protocol events > heuristics > inferred).
4. If still tied, most recent update wins.

## 10. Quick Start

A minimal integration in ~20 lines of shell:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Check if running inside Zentty
if [[ -z "${ZENTTY_CLI_BIN:-}" ]]; then
  exec my-actual-agent "$@"
fi

SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

send_event() {
  echo "$1" | "$ZENTTY_CLI_BIN" ipc agent-event 2>/dev/null || true
}

# Start session
send_event '{"version":1,"event":"session.start","agent":{"name":"my-agent","pid":'"$$"'},"session":{"id":"'"$SESSION_ID"'"}}'

# Trap cleanup
trap 'send_event "{\"version\":1,\"event\":\"session.end\",\"session\":{\"id\":\"'"$SESSION_ID"'\"}}"' EXIT

# Signal running
send_event '{"version":1,"event":"agent.running","state":{"text":"Working..."}}'

# ... do actual work here ...

# Signal idle when done
send_event '{"version":1,"event":"agent.idle"}'
```

This gives you:
- Sidebar status indicator (running/idle)
- Crash detection (via PID)
- Automatic cleanup on exit

To add needs-input support, send `agent.needs-input` when your agent blocks on user action, and `agent.input-resolved` when the user responds.

To add task progress, send `task.progress` events as tasks complete:

```bash
send_event '{"version":1,"event":"task.progress","progress":{"done":2,"total":5}}'
```

## 11. Existing Agent Adapters

The four built-in agents currently produce these canonical events through their respective wrapper scripts:

| Canonical Event | Claude Code | Copilot | Codex | OpenCode |
|---|---|---|---|---|
| `session.start` | `SessionStart` hook | `session-start` hook | `session-start` hook | plugin load |
| `session.end` | `SessionEnd` hook | `session-end` hook | — | — |
| `agent.running` | `UserPromptSubmit` hook | OSC 9;4 progress | `prompt-submit` hook | `session.status(busy)` |
| `agent.idle` | `Stop` hook | OSC 9;4 remove | `stop` hook | `session.status(idle)` |
| `agent.needs-input` | `Notification`, `PermissionRequest`, `PreToolUse(AskUserQuestion)` hooks | `pre-tool-use(askuserquestion)` hook | — | `permission.asked`, `question.asked` |
| `agent.input-resolved` | `UserPromptSubmit` hook | `post-tool-use(askuserquestion)` hook | — | `permission.replied`, `question.replied` |
| `task.progress` | `TaskCreated`, `TaskCompleted` hooks | — | — | `todo.updated` |

**Note:** Copilot's running detection relies on OSC 9;4 terminal progress sequences rather than hook events, because Copilot's hook API lacks a turn-complete event. The wrapper script translates this into the canonical protocol.

## 12. Versioning & Scope

### Versioning

The `version` field in every event enables future protocol evolution. Zentty will:

- Accept `version: 1` indefinitely.
- Reject events with unknown versions (non-zero exit code, error on stderr).
- Document breaking changes under a new version number.

### What's Not in the Protocol

- **OSC 9;4 progress sequences** — Terminal escape sequences for progress bars. Zentty reads these from the terminal emulator layer, not from the agent protocol. Agents that emit OSC 9;4 get running-state detection for free, but it's not part of this protocol.
- **Terminal title heuristics** — Zentty parses terminal titles to detect agent state when no hook is available. This is a fallback mechanism, not a protocol feature.
- **Desktop notification signals** — Zentty recognizes certain desktop notification patterns as agent state signals. This is also a fallback, not part of the protocol.
