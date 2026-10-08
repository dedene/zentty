# Zentty Agent Bench

On-demand live bench for Zentty agent integrations. It drives real agent CLIs
through Zentty's wrapper path and records the raw hook IPC calls that reach the
bench capture server.

Run a no-model harness check:

```sh
python3 scripts/agent-bench/agent_bench.py self-test --app-path /path/to/Zentty.app
```

Run live scenarios:

```sh
python3 scripts/agent-bench/agent_bench.py run --agents all --scenarios smoke,approval
```

Probe restored-agent launch wiring without model auth:

```sh
python3 scripts/agent-bench/agent_bench.py run --agents all --scenarios restore_launch --no-build
```

Verify live hooks contain the identity needed to create restore drafts:

```sh
python3 scripts/agent-bench/agent_bench.py run --agents all --scenarios session_capture --no-build --app-path /Applications/Zentty.app
```

Useful options:

- `--agents codex,claude` limits the agent set.
- `--scenarios smoke` runs only smoke coverage.
- `--strict` treats missing binaries/auth as failures instead of skips.
- `--no-build --app-path /Applications/Zentty.app` uses an existing app bundle.
- `--signing auto|team|ad-hoc` controls how the bench build is signed. `auto`
  (the default) signs with the project's development team when the keychain
  has an Apple Development identity for it, and falls back to ad-hoc signing
  otherwise, so contributors outside the team can build without a certificate.
- `--run-dir /tmp/zentty-agent-bench` writes traces to a fixed location.

Each run writes `trace.jsonl`, per-agent terminal logs, `summary.json`, and
`report.md` under `.agent-bench-runs/<timestamp>/` unless `--run-dir` is set.
It also writes `timeline.json`, a normalized per-scenario stream of process,
hook, and terminal observations.

`summary.json` keeps the original pass/fail fields and adds:

- `result_kind`, one of:
  - passes: `hook-pass`, `bootstrap-pass`, `terminal-pass`, `resume-pass`.
  - hook failures: `missing-hook`, `forbidden-hook`, `missing-bootstrap`,
    `missing-session-identity`, `missing-task-hook`,
    `missing-task-progress`, `missing-task-items`, `missing-subagent-payload`,
    `hook-order`, `missing-nested-subagent`.
  - terminal failures: `missing-terminal-phase`, `forbidden-terminal-phase`,
    `missing-terminal-needs-input`, `stale-terminal-needs-input`,
    `missing-scripted-input`.
  - resume failures: `resume-no-session`, `resume-no-marker`,
    `resume-not-found`.
  - routing failures: `wrong-pane-routing`.
  - process outcomes: `process-timeout`, `agent-refusal`.
  - skips: `auth-skip`, `binary-skip`, `missing-wrapper`, `scenario-skip`
    (each is a skip in normal mode and a failure under `--strict`).
- `timeline`: relative-millisecond events for that scenario.
- `terminal_observations`: advisory OSC title, OSC 9, and progress signals.
- `session_identity_observations`: hook-provided session IDs and tracked PIDs
  observed by `session_capture`.
- `warnings`: non-fatal diagnostics.
- `rerun_command`: a single-agent/single-scenario command using the same app.

Terminal observations are advisory for now. Hook expectations and process
classification still decide pass/fail/skip.

To rerun one failure, copy the `Rerun:` command from `report.md`, or run:

```sh
python3 scripts/agent-bench/agent_bench.py run --agents codex --scenarios approval --no-build --app-path /path/to/Zentty.app
```

Claude scenarios pass `--setting-sources project,local` so user-level hooks do
not inject unrelated context into the live model run. The bench still supplies
its own hook settings through the wrapper bootstrap path.

Interactive Claude Code (2.1.261+) skips every hook while the workspace trust
dialog has not been accepted, and it never shows that dialog inside the bench
pty. The bench therefore marks each temporary Claude repo as trusted in
`~/.claude.json` (`hasTrustDialogAccepted` only) before launching and prunes
entries for bench repos that no longer exist. Print-mode scenarios (`smoke`,
`session_capture`) are unaffected.

`approval_then_work` is the regression scenario for the sidebar status: it
approves a Write, then has Claude continue with Read and Grep before
finishing. The trace must show `PostToolUse` events between
`PermissionRequest` and `Stop`; those are the only hooks Claude emits while it
works through tools outside the PreToolUse matcher, and without them the pane
stays on "Needs input" after an approval typed as `1`/`y`.

`subagents` is the regression scenario for the sidebar subagent badge. It asks
the agent to spawn one subagent (Claude `Agent`, Codex `spawn_agent`, Grok
`spawn_subagent`) and requires a `SubagentStart` / `SubagentStop` pair. With
`subagent_payload_required` the bench also checks, before redaction, that the
hook payload names an agent type and that the transcript sidecar next to it
yields a model (`agent-<id>.meta.json` or the first assistant line for Claude,
the sub-thread rollout's `turn_context` for Codex), because those two facts are
what the badge and its expanded list are built from.

`subagents_async` and `subagents_nested` (Claude only) pin the upstream
contract that the badge logic depends on since Claude Code 2.1.261 launches
every Agent tool call asynchronously:

- `subagents_async` asks for one Explore agent with `run_in_background` and an
  immediate `DONE`. Besides the usual required events it sets
  `event_order: [["Stop", "SubagentStop"]]`: some `Stop` must be observed
  before the last `SubagentStop`, proving the parent went idle while its
  subagent was still alive. `Stop` therefore must not clear the badge. A
  violation reports `hook-order` with the observed hook sequence.
- `subagents_nested` asks for one general-purpose agent that itself spawns one
  Explore agent. It requires two `SubagentStart` and two `SubagentStop` events
  and sets `subagent_nested_required: true`: the starts must carry distinct
  `agent_id`s and every stop must match a start. A violation reports
  `missing-nested-subagent`.

`event_order` is generic: each entry is a `[before, after]` pair of hook event
names, checked against the scenario's own hook records after the required
events pass.

`environment_by_scenario` injects environment variables for one scenario only,
e.g. Claude's `tasks` sets `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` because the
TaskCreate/TaskUpdate tools are gated on it and `--setting-sources
project,local` skips user-level settings that would otherwise enable them.

`background_routing` (Claude only, `daemon_pane_routing: true`) guards the
shared-daemon bug from dedene/zentty#121. Claude runs `claude --bg` sessions
under one per-user daemon that keeps the environment of whichever pane started
it. The scenario starts that daemon with the real binary under a foreign pane
identity, then launches `claude --bg` through the wrapper as the bench pane.
Every captured hook must carry the bench pane and worklane, and none may keep
the starter's `ZENTTY_CLAUDE_PID`; a violation reports `wrong-pane-routing`.

It then runs `claude attach <id>` through the wrapper from a third pane. The
attach client fires no hooks, so the wrapper must send one `ZenttyAttach`
event naming the session, from the attaching pane and with the client's pid.
That event is what lets the app move the session to the attaching pane.

It starts and stops the per-user Claude daemon, so it is not part of any
default sweep and skips (`scenario-skip`) when a daemon or background session
is already running. It makes two short model calls. Run it on its own:

```sh
python3 scripts/agent-bench/agent_bench.py run --agents claude --scenarios background_routing
```
