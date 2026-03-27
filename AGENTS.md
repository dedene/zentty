# AGENTS.md

## Testing

Two test targets:
- **ZenttyLogicTests** — no app host, parallel-safe. Pure logic + detached AppKit component tests (~380 tests).
- **ZenttyTests** — hosted in Zentty.app, serial. Tests that need real windows or app lifecycle (~24 tests).

Run all tests (scheme controls parallelism per-target automatically):
```
xcodebuild test -scheme Zentty -destination 'platform=macOS'
```

Before CLI test runs, inspect for stale or stuck `xcodebuild` / `Zentty` processes if test behavior looks suspicious. Do not kill active processes automatically. If an obviously stale instance is blocking the run, confirm with Peter before terminating it.

Guidelines:
- New tests go in `ZenttyLogicTests` unless they call `showWindow()`, `makeKeyAndOrderFront()`, or access `NSApp` lifecycle.
- Tests that create windows must close them in `tearDown` or `addTeardownBlock`.
- Use XCTest expectations instead of `RunLoop.current.run(until:)`.
- The app host runs inert during tests (no main window, `.prohibited` activation policy) via `XCTestConfigurationFilePath` detection in `main.swift`.

## Design Docs

- Do not add design docs, specs, or plans to git unless Peter explicitly asks.
- It is fine to create them locally for discussion or planning, but keep them untracked and ignored by default.

## Error Handling

Two-tier strategy based on execution context:

1. **Fatal/exit** — CLI tools (ClaudeHookBridge, AgentStatusHelper). When the process IS the error reporter, log to stderr and exit with a non-zero status code.
2. **Log and continue** — In-app observers (AgentStatusCenter, PRArtifactResolver, GhosttyThemeResolver, WorklaneReviewStateResolver). Best-effort detection should never crash the app. Log via `os.Logger` and fall back to a safe default.

Exception: `LibghosttyRuntime` initialization uses `fatalError` — the terminal engine is an essential dependency with no meaningful fallback.
