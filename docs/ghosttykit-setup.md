# GhosttyKit Setup

`GhosttyKit` is required for normal Zentty app builds. XCTest can still use mock adapters, but app builds and manual acceptance require a local `FrameworksLocal/GhosttyKit.xcframework`.

## Prerequisites

- Xcode selected correctly: `xcode-select -p` should point at `/Applications/Xcode.app/Contents/Developer`
- `zig` available on `PATH`
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

If `zig` is missing:

```bash
brew install zig
```

If `gettext` is missing:

```bash
brew install gettext
```

If Xcode command line tools or the active developer directory are wrong:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If Metal toolchain assets are missing:

- Open Xcode once and let it finish installing components.
- Re-run `xcodebuild -downloadPlatform macOS` if the SDK/toolchain install is incomplete.

If the script fails while fetching Ghostty tags:

- Re-run `./scripts/build_ghosttykit.sh`.
- The script now forces a tag refresh (`git fetch --tags --prune --force origin`) to recover from stale local tags.
