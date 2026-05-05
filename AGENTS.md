# AGENTS.md

## Testing

Two test targets:
- **ZenttyLogicTests** — no app host, parallel-safe. Pure logic + detached AppKit component tests (~380 tests).
- **ZenttyTests** — hosted in Zentty.app, serial. Tests that need real windows or app lifecycle (~24 tests).

Run all tests (scheme controls parallelism per-target automatically):
```
TEST_RUNNER_SWIFT_BACKTRACE=enable=no xcodebuild test -scheme Zentty -destination 'platform=macOS'
```

Run hosted window tests on a local virtual display when you need to reduce visual interruption:
```
scripts/test-hosted-on-virtual-display
```

The virtual-display harness is optional and local-only. It creates or reuses a display named `ZenttyTests`, sets `ZENTTY_TEST_SCREEN_NAME=ZenttyTests`, and runs the hosted `ZenttyTests` target. It supports `ZENTTY_TEST_DISPLAY_PROVIDER=auto`, `betterdisplay`, or `simpledisplay`; `auto` prefers BetterDisplay when available. This can move test windows off the active display, but AppKit tests still run in the same Aqua session and can still steal focus.

**Always prefix with `TEST_RUNNER_SWIFT_BACKTRACE=enable=no`.** On macOS 26 (Tahoe) the Swift backtrace handler shows an interactive "Press space to interact" prompt on crash, which hangs xcodebuild indefinitely until a 30s timeout. The `TEST_RUNNER_` prefix forwards env vars from xcodebuild to the xctest subprocess (a plain `SWIFT_BACKTRACE=...` on xcodebuild does NOT propagate).

Multiple agents often run in parallel in this repo.

Guidelines:
- New tests go in `ZenttyLogicTests` unless they call `showWindow()`, `makeKeyAndOrderFront()`, or access `NSApp` lifecycle.
- Use `scripts/test-hosted-on-virtual-display` for local `ZenttyTests` runs that open real AppKit windows.
- Tests that create windows must close them in `tearDown` or `addTeardownBlock`.
- Use XCTest expectations instead of `RunLoop.current.run(until:)`.
- The app host runs inert during tests (no main window, `.prohibited` activation policy) via `XCTestConfigurationFilePath` detection in `main.swift`.
- **Do not pass `-derivedDataPath` to xcodebuild.** Use the default DerivedData location. Creating per-agent directories under `/tmp/` wastes gigabytes of disk and they never get cleaned up.
- Do not use `./runner`.

## Design Docs

- Do not add design docs, specs, or plans to git unless Peter explicitly asks.
- It is fine to create them locally for discussion or planning, but keep them untracked and ignored by default.

## Project Generation

- Treat `project.yml` as the source of truth for Xcode project structure and generated build scripts.
- Do not make manual edits directly in `Zentty.xcodeproj/project.pbxproj` unless Peter explicitly asks.
- When project configuration changes are needed, update `project.yml` first and regenerate the project.

## Error Handling

Two-tier strategy based on execution context:

1. **Fatal/exit** — CLI tools (ClaudeHookBridge, AgentStatusHelper). When the process IS the error reporter, log to stderr and exit with a non-zero status code.
2. **Log and continue** — In-app observers (AgentStatusCenter, PRArtifactResolver, GhosttyThemeResolver, WorklaneReviewStateResolver). Best-effort detection should never crash the app. Log via `os.Logger` and fall back to a safe default.

Exception: `LibghosttyRuntime` initialization uses `fatalError` — the terminal engine is an essential dependency with no meaningful fallback.
