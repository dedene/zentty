# GhosttyKit Setup

`GhosttyKit` is required for normal Zentty app builds. XCTest can still use mock adapters, but app builds and manual acceptance require a local `FrameworksLocal/GhosttyKit.xcframework`.

## Prerequisites

- Xcode selected correctly: `xcode-select -p` should point at `/Applications/Xcode.app/Contents/Developer`
- the Zig version from `scripts/ghosttykit.lock` available locally
- `gettext` available on `PATH`
- Metal toolchain installed with Xcode

## Canonical Bootstrap Command

Run this from the repo root:

```bash
./scripts/build_ghosttykit.sh
```

Expected artifact:

```text
FrameworksLocal/GhosttyKit.xcframework
```

The script also stages Ghostty resources under `~/Library/Caches/zentty/ghostty-src/zig-out/share/ghostty`.

## First Verification Checkpoint

After the framework build succeeds, confirm the app builds:

```bash
xcodebuild -project Zentty.xcodeproj -scheme Zentty -destination 'platform=macOS' build
```

## Recovery Steps

If the locked Zig version is missing:

```bash
brew install zig@0.15
```

`zig@0.15` is keg-only. You do not need to relink Homebrew's default `zig`; `scripts/build_ghosttykit.sh` resolves the locked version directly.

If `gettext` is missing:

```bash
brew install gettext
```

If Xcode command line tools or the active developer directory are wrong:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If Metal toolchain assets are missing:

- Run `xcodebuild -downloadComponent MetalToolchain`.
- Open Xcode once and let it finish installing components if the download still leaves `xcrun --find metal` unavailable.
- Re-run `xcodebuild -downloadPlatform macOS` if the SDK/toolchain install is incomplete.

If the script fails while fetching Ghostty tags:

- Re-run `./scripts/build_ghosttykit.sh`.
- The script now forces a tag refresh (`git fetch --tags --prune --force origin`) to recover from stale local tags.

## Updating Patched GhosttyKit

Zentty currently builds GhosttyKit from Peter's fork at `dedene/ghostty`, branch `zentty/smooth-scroll`. The lock file records both the patched revision and the official Ghostty base revision.

To update to a newer upstream Ghostty:

```bash
git clone git@github.com:dedene/ghostty.git /tmp/ghostty-zentty-update
cd /tmp/ghostty-zentty-update
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
git checkout -B zentty/smooth-scroll <new-upstream-commit>
git cherry-pick <smooth-scroll-commit-range>
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=universal
git push --force-with-lease origin zentty/smooth-scroll
```

Then update `scripts/ghosttykit.lock`:

- `revision` is the new `zentty/smooth-scroll` commit.
- `upstream_revision` is the official Ghostty commit used as the base.
- `repo` stays `https://github.com/dedene/ghostty.git`.

The downstream audit range should stay small:

```bash
git log --oneline <upstream_revision>..zentty/smooth-scroll
```

It should contain only Zentty's smooth-scroll patch stack and any direct conflict-resolution commits.
