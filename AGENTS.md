# AGENTS.md

## Testing

Two test targets:
- **ZenttyLogicTests** — no app host, parallel-safe. Pure logic + detached AppKit component tests (~380 tests).
- **ZenttyTests** — hosted in Zentty.app, serial. Tests that need real windows or app lifecycle (~24 tests).

Run all tests (scheme controls parallelism per-target automatically):
```
pkill -9 -f 'xcodebuild|Zentty' 2>/dev/null; sleep 1
xcodebuild test -scheme Zentty -destination 'platform=macOS'
```

Before CLI test runs, always kill stale processes:
```
pkill -9 -f 'xcodebuild|Zentty' 2>/dev/null
```

Guidelines:
- New tests go in `ZenttyLogicTests` unless they call `showWindow()`, `makeKeyAndOrderFront()`, or access `NSApp` lifecycle.
- Tests that create windows must close them in `tearDown` or `addTeardownBlock`.
- Use XCTest expectations instead of `RunLoop.current.run(until:)`.
- The app host runs inert during tests (no main window, `.prohibited` activation policy) via `XCTestConfigurationFilePath` detection in `main.swift`.

## Error Handling

Two-tier strategy based on execution context:

1. **Fatal/exit** — CLI tools (ClaudeHookBridge, AgentStatusHelper). When the process IS the error reporter, log to stderr and exit with a non-zero status code.
2. **Log and continue** — In-app observers (AgentStatusCenter, PRArtifactResolver, GhosttyThemeResolver, WorkspaceReviewStateResolver). Best-effort detection should never crash the app. Log via `os.Logger` and fall back to a safe default.

Exception: `LibghosttyRuntime` initialization uses `fatalError` — the terminal engine is an essential dependency with no meaningful fallback.
