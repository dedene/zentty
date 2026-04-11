# Contributing to Zentty

Thanks for your interest in contributing.

## Before You Start

- Read [`LICENSE`](LICENSE).
- Read [`CLA.md`](CLA.md).
- Read [`TRADEMARKS.md`](TRADEMARKS.md).

## Contribution Process

1. Open an issue or pull request that explains the problem or change.
2. Keep changes focused and reviewable.
3. Add or update tests when the change affects behavior.
4. Run the relevant build and test commands before asking for review.

## CLA Requirement

Before we can merge a non-trivial contribution, you must agree to the contributor license agreement by including this statement in your pull request description or in a pull request comment:

```text
I have read CLA.md and agree to its terms.
```

## Build and Test

Bootstrap the required Ghostty framework:

```bash
./scripts/build_ghosttykit.sh
```

Run the test suite:

```bash
xcodebuild test -scheme Zentty -destination 'platform=macOS'
```

Regenerate the Xcode project when needed:

```bash
bundle exec fastlane mac generate_project
```

## Code Signing

`project.yml` commits `DEVELOPMENT_TEAM: 25TVW8MSGJ`, which is Zenjoy's Apple Developer team. The team ID itself is not a secret — it ships inside every signed macOS binary — but only Zenjoy can sign with it. External contributors building locally should override it with their own Apple Developer team:

```bash
xcodebuild -scheme Zentty -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic build
```

For test-only runs, you can skip signing entirely:

```bash
xcodebuild test -scheme Zentty -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Do not commit a local change to `DEVELOPMENT_TEAM` in `project.yml`.

## Project Notes

- Zentty is a native macOS app.
- The app depends on a local `FrameworksLocal/GhosttyKit.xcframework` for normal builds.
- Hosted and logic tests have different runtime characteristics; use the existing project guidance and test targets.
- Release-only build settings (`GLITCHTIP_DSN`, `SPARKLE_FEED_URL`, `SPARKLE_PUBLIC_ED_KEY`) default to empty and are injected via `xcargs` during official releases. Debug builds work fine without them; error reporting and Sparkle updates are simply disabled.

## Licensing Expectations

By contributing to Zentty, you are contributing to a project published under `GPL-3.0-only`.

Zenjoy BV may also offer Zentty under alternative commercial terms. The CLA exists so Zenjoy BV can maintain that option while continuing to accept community contributions.
