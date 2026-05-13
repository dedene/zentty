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

Useful options:

- `--agents codex,claude` limits the agent set.
- `--scenarios smoke` runs only smoke coverage.
- `--strict` treats missing binaries/auth as failures instead of skips.
- `--no-build --app-path /Applications/Zentty.app` uses an existing app bundle.
- `--run-dir /tmp/zentty-agent-bench` writes traces to a fixed location.

Each run writes `trace.jsonl`, per-agent terminal logs, `summary.json`, and
`report.md` under `.agent-bench-runs/<timestamp>/` unless `--run-dir` is set.
It also writes `timeline.json`, a normalized per-scenario stream of process,
hook, and terminal observations.

`summary.json` keeps the original pass/fail fields and adds:

- `result_kind`: `hook-pass`, `process-timeout`, `agent-refusal`,
  `auth-skip`, `missing-hook`, `bootstrap-pass`, `missing-bootstrap`,
  `scenario-skip`, or `binary-skip`.
- `timeline`: relative-millisecond events for that scenario.
- `terminal_observations`: advisory OSC title, OSC 9, and progress signals.
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
