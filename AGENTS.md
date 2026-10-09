# AGENTS.md

## Testing

Two test targets:
- **ZenttyLogicTests** — no app host, parallel-safe. Pure logic + detached AppKit component tests (~380 tests).
- **ZenttyTests** — hosted in Zentty.app, serial. Tests that need real windows or app lifecycle (~24 tests).

Run the full all-target gate only when you explicitly need Logic + hosted app + integration in one command. Use the virtual-display harness so AppKit windows are created on the test display:
```
ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay scripts/test-on-virtual-display
```

For normal local verification of hosted window/AppKit behavior, use the hosted virtual-display wrapper instead of running `ZenttyTests` through plain `xcodebuild`:
```
scripts/test-hosted-on-virtual-display
```

The virtual-display harness is the expected local path for tests that can create AppKit windows. It creates or reuses a display named `ZenttyTests`, sets `ZENTTY_TEST_SCREEN_NAME=ZenttyTests`, and runs the scheme's testables by default. It supports `ZENTTY_TEST_DISPLAY_PROVIDER=auto`, `betterdisplay`, or `simpledisplay`; `auto` prefers BetterDisplay when available. This moves prepared test windows off the active display, but AppKit tests still run in the same Aqua session and can still steal focus.

The virtual-display scripts set `TEST_RUNNER_SWIFT_BACKTRACE=enable=no`. If you bypass them and call `xcodebuild` directly, always prefix with `TEST_RUNNER_SWIFT_BACKTRACE=enable=no`. On macOS 26 (Tahoe) the Swift backtrace handler shows an interactive "Press space to interact" prompt on crash, which hangs xcodebuild indefinitely until a 30s timeout. The `TEST_RUNNER_` prefix forwards env vars from xcodebuild to the xctest subprocess (a plain `SWIFT_BACKTRACE=...` on xcodebuild does NOT propagate).

Multiple agents often run in parallel in this repo.

Guidelines:
- New tests go in `ZenttyLogicTests` unless they call `showWindow()`, `makeKeyAndOrderFront()`, or access `NSApp` lifecycle.
- Use `scripts/test-on-virtual-display -only-testing:ZenttyLogicTests` for local `ZenttyLogicTests` runs that may create real AppKit windows.
- Use `scripts/test-hosted-on-virtual-display` for local `ZenttyTests` runs that open real AppKit windows.
- Use `scripts/test-modern-shell-integrations` before release after changing shell integration; it requires local `fish`, `nu`, and `/usr/bin/expect`, and fails if the fish/nu resource files are not tracked.
- Tests that create windows must close them in `tearDown` or `addTeardownBlock`.
- Use XCTest expectations instead of `RunLoop.current.run(until:)`.
- The app host runs inert during tests (no main window, `.prohibited` activation policy) via `XCTestConfigurationFilePath` detection in `main.swift`.
- **Do not pass `-derivedDataPath` to xcodebuild.** Use the default DerivedData location. Creating per-agent directories under `/tmp/` wastes gigabytes of disk and they never get cleaned up.
- Do not use `./runner`.

## Design Docs

- Do not add design docs, specs, or plans to git unless Peter explicitly asks.
- It is fine to create them locally for discussion or planning, but keep them untracked and ignored by default.

## Dependencies

- `Zentty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is committed and is the source of truth for dependency versions. Commit it whenever a bump changes it; do not ignore it again.
- Release builds pass `-disableAutomaticPackageResolution`, so a range change in `project.yml` without a matching resolved-file update fails the release instead of silently picking a new version.
- The release lane builds `generate_appcast` from the Sparkle revision in `Package.resolved`, never from whatever checkout is newest in DerivedData.

## Project Generation

- Treat `project.yml` as the source of truth for Xcode project structure and generated build scripts.
- Do not make manual edits directly in `Zentty.xcodeproj/project.pbxproj` unless Peter explicitly asks.
- When project configuration changes are needed, update `project.yml` first and regenerate the project.

## Agent Bench

`scripts/agent-bench/` drives each supported agent CLI through the Zentty wrapper and asserts the hook events the integration depends on. It is the regression backstop for the Antigravity (agy) integration in particular, where the hook pipeline has historically been fragile.

For the agy integration, the gate is `scripts/test-agy-bench`. It builds Zentty (skip with `--no-build`) and runs the full agy scenario sweep — `smoke,session_capture,approval,tools,restore_launch,restore_launch_with_id` — in `--strict` mode (auth-skip / binary-skip become failures).

Re-run after:
- any agy CLI version bump (it is the upstream side of the contract),
- any change to `AgyHooksInstaller`, `agyAdapter`, or `AgyCanonicalReEmitter`,
- any change to `scripts/agent-bench/profiles/agy.json`.

For the devin integration, the gate is `scripts/test-devin-bench`. It runs the full devin scenario sweep — `smoke,session_capture,tools,approval,restore_launch,subagents,subagents_async` — in `--strict` mode and covers the `--config` overlay contract plus subagent lifecycle inferred from `run_subagent` / `sidekick` hooks.

Re-run after:
- any devin CLI version bump,
- any change to `AgentLaunchBootstrap.devinPlan` or `DevinEventAdapter`,
- any change to `scripts/agent-bench/profiles/devin.json`.

For the kilo integration, the gate is `scripts/test-kilo-bench`. It runs `smoke,session_capture,approval,restore_launch,manual_compact` through the manifest-driven opencode-plugin path.

Re-run after:
- any kilo CLI version bump,
- any change to the shared opencode-family plan (`openCodeFamilyPlan`) or the shared plugin `zentty-opencode-zentty.js`,
- any change to `ZenttyResources/agents/kilo.json` or `scripts/agent-bench/profiles/kilo.json`.

For the opencode integration, the gate is `scripts/test-opencode-bench`. OpenCode ships two incompatible CLIs as `opencode`: v1 (npm `opencode-ai`, profile `opencode`) and v2 (npm `@opencode/cli`, profile `opencode-v2`). Each profile picks its binary by probing `--version`. v2 runs plugins in a shared background service by default, so Zentty launches it `--standalone` with the plugin from `ZenttyResources/opencode/v2-plugins/`. Both profiles pin a free model (`ZENTTY_BENCH_OPENCODE_MODEL` overrides), so results don't depend on your last TUI model. The v2 bench also runs isolated (overlay data/state/cache), and the gate installs `@opencode/cli` into a temp prefix when no v2 is on PATH.

Re-run after:
- any opencode v1 or v2 CLI version bump,
- any change to `openCodeFamilyPlan`, `OpenCodeGeneration`, or either opencode plugin,
- any change to `scripts/agent-bench/profiles/opencode*.json`.

For the generic manifest seam, the gate is `scripts/test-generic-agent-bench`. It runs `smoke,session_capture,approval,restore_launch` against the `generic-canonical` fixture agent — a bash script that emits canonical events with no model auth required.

Re-run after:
- any change to `AgentManifest*`, `AgentManifestRegistry`, or `AgentManifestWrapperMaterializer`,
- any change to `canonicalManifestPlan`,
- any change to the shared `zentty-agent-wrapper` script,
- any change to shell-integration manifest lookup (`ZENTTY_AGENT_MANIFEST_TABLE`).

Profile-level Python tests (`scripts/agent-bench/tests/test_agent_bench.py`) run via `python3 -m unittest discover scripts/agent-bench/tests` and catch bad profile shapes before the harness is even invoked.

## Error Handling

Two-tier strategy based on execution context:

1. **Fatal/exit** — CLI tools (ClaudeHookBridge, AgentStatusHelper). When the process IS the error reporter, log to stderr and exit with a non-zero status code.
2. **Log and continue** — In-app observers (AgentStatusCenter, PRArtifactResolver, GhosttyThemeResolver, WorklaneReviewStateResolver). Best-effort detection should never crash the app. Log via `os.Logger` and fall back to a safe default.

Exception: `LibghosttyRuntime` initialization uses `fatalError` — the terminal engine is an essential dependency with no meaningful fallback.
