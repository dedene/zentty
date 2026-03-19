# AGENTS.md

## Testing

- Always kill stale `xcodebuild` and `Zentty` processes before starting a new test run:
  `pkill -9 -f 'xcodebuild|Zentty' 2>/dev/null`
- Run tests with `-parallel-testing-enabled NO` — the Zentty test host app hangs when multiple test runners fight over it:
  `xcodebuild test-without-building -scheme Zentty -destination 'platform=macOS' -parallel-testing-enabled NO`
- Use `build-for-testing` + `test-without-building` as separate steps for faster iteration.

## Error Handling

Two-tier strategy based on execution context:

1. **Fatal/exit** — CLI tools (ClaudeHookBridge, AgentStatusHelper). When the process IS the error reporter, log to stderr and exit with a non-zero status code.
2. **Log and continue** — In-app observers (AgentStatusCenter, PRArtifactResolver, GhosttyThemeResolver, WorkspaceReviewStateResolver). Best-effort detection should never crash the app. Log via `os.Logger` and fall back to a safe default.

Exception: `LibghosttyRuntime` initialization uses `fatalError` — the terminal engine is an essential dependency with no meaningful fallback.
