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

Useful options:

- `--agents codex,claude` limits the agent set.
- `--scenarios smoke` runs only smoke coverage.
- `--strict` treats missing binaries/auth as failures instead of skips.
- `--no-build --app-path /Applications/Zentty.app` uses an existing app bundle.
- `--run-dir /tmp/zentty-agent-bench` writes traces to a fixed location.

Each run writes `trace.jsonl`, per-agent terminal logs, `summary.json`, and
`report.md` under `.agent-bench-runs/<timestamp>/` unless `--run-dir` is set.

Claude scenarios pass `--setting-sources project,local` so user-level hooks do
not inject unrelated context into the live model run. The bench still supplies
its own hook settings through the wrapper bootstrap path.
