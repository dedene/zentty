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

To try the latest `main` as a release candidate without touching your everyday Zentty:

```bash
scripts/build-dev-release --main
```

`--main` fetches `origin/main` and builds it in a worktree the script owns, `.worktrees/dev-release` under the main repo (override with `ZENTTY_DEV_WORKTREE`). Your own checkout and its branch stay as they are. `--ref <ref>` does the same for any branch, tag or commit. The worktree is created on first use and moved to the requested commit on later runs; the script refuses to touch it if it has local changes. GhosttyKit is copied into it from the checkout you run the script from, so that checkout needs a `FrameworksLocal/GhosttyKit.xcframework` built for the same `scripts/ghosttykit.lock` (otherwise the script stops and tells you).

Without `--main` or `--ref`, the script builds the current checkout as is.

Either way it builds the Release configuration and installs it as `Zentty Dev.app` next to `/Applications/Zentty.app` (override the folder with `ZENTTY_DEV_INSTALL_DIR`). If Zentty Dev is running, it asks it to quit, swaps in the new bundle and relaunches it. Use `--adhoc` to skip the Developer ID identity, `--no-install` to only build, and `--help` for the rest. On a fresh clone, run `scripts/build_ghosttykit.sh` first.

Run it from production Zentty or another terminal, not from a Zentty Dev pane: installing quits Zentty Dev, and the script refuses to start there unless you pass `--no-install`.

Zentty Dev is a separate app:

- Bundle id `be.zenjoy.zentty.dev`, so macOS treats it as its own app for permissions and defaults.
- Settings live in `~/.config/zentty-dev`. When `~/.config/zentty-dev/config.toml` doesn't exist yet, it copies `config.toml` and `bookmarks.json` from `~/.config/zentty`; after that the two diverge. To start over from your production settings, delete `~/.config/zentty-dev` and relaunch.
- Its Application Support and Caches folders are named "Zentty Dev", and session restore is separate.
- No Sparkle feed and no error reporting, so it never updates itself into the production app.
- The icon carries an orange DEV badge.

Some things are shared on purpose:

- `~/.config/ghostty/config.ghostty`, if you use the shared Ghostty config mode.
- User agent manifests in `~/.config/zentty/agents`.
- The runtime dir `~/.config/zentty/run`. Each running instance has its own socket there, so the two apps don't collide.

Known limitation: agents that write persistent global hook files (Cursor, Droid, Grok, Kimi, Hermes, Vibe, Amp, agy) record the CLI path of whichever Zentty launched them last, so the path may point at the other app's `zentty` CLI. Events are routed by the pane's socket environment, so they normally still reach the right app. If the two builds' IPC protocols differ, though, a hook that runs through the other app's CLI can fail.

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
