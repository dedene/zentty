# AGENTS.md

## Testing

- Always kill stale `xcodebuild` and `Zentty` processes before starting a new test run:
  `pkill -9 -f 'xcodebuild|Zentty' 2>/dev/null`
- Run tests with `-parallel-testing-enabled NO` — the Zentty test host app hangs when multiple test runners fight over it:
  `xcodebuild test-without-building -scheme Zentty -destination 'platform=macOS' -parallel-testing-enabled NO`
- Use `build-for-testing` + `test-without-building` as separate steps for faster iteration.
