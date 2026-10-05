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
ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay scripts/test-on-virtual-display
```

Regenerate the Xcode project when needed:

```bash
bundle exec fastlane mac generate_project
```

## Test-driving a dev build

To try the current checkout as a release candidate without touching your everyday Zentty:

```bash
scripts/build-dev-release
```

The script builds the Release configuration and installs it as `Zentty Dev.app` next to `/Applications/Zentty.app` (override the folder with `ZENTTY_DEV_INSTALL_DIR`). If Zentty Dev is already running, it asks it to quit, replaces the bundle and relaunches it. Use `--adhoc` to skip the Developer ID identity, `--no-install` to only build, and `--help` for the rest. It needs `FrameworksLocal/GhosttyKit.xcframework`, so run `scripts/build_ghosttykit.sh` first on a fresh clone.

Zentty Dev is a separate app:

- Bundle id `be.zenjoy.zentty.dev`, so macOS treats it as its own app for permissions and defaults.
- Settings live in `~/.config/zentty-dev`. On first launch it copies `~/.config/zentty/config.toml` and `bookmarks.json` once; after that the two diverge.
- Its Application Support and Caches folders are named "Zentty Dev", and session restore is separate.
- No Sparkle feed and no error reporting, so it never updates itself into the production app.
- The icon carries an orange DEV badge.

Known limitation: agents that write persistent global hook files (Cursor, Droid, Grok, Kimi, Hermes, Vibe, Amp, agy) record the CLI path of whichever Zentty launched them last. Events still reach the right app, but the recorded path may point at the other one.

## Code Signing

`project.yml` commits `DEVELOPMENT_TEAM: 25TVW8MSGJ`, which is Zenjoy's Apple Developer team. The team ID itself is not a secret — it ships inside every signed macOS binary — but only Zenjoy can sign with it. External contributors building locally should override it with their own Apple Developer team:

```bash
xcodebuild -scheme Zentty -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic build
```

For test-only runs, you can skip signing entirely:

```bash
ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay scripts/test-on-virtual-display \
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
