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

## Lock Stamp

`scripts/build_ghosttykit.sh` writes `FrameworksLocal/GhosttyKit.xcframework/.ghosttykit-inputs`, a fingerprint of `scripts/ghosttykit.lock` plus any `scripts/patches/ghostty-*.patch` (computed by `scripts/ghosttykit-inputs`). The stamp lives inside the xcframework so it travels with every copy, including the `wtp` post-create hook.

The app's "Verify GhosttyKit" build phase compares the stamp with the checkout's lock:

- `error: GhosttyKit.xcframework was built for a different scripts/ghosttykit.lock`: the framework is for another revision. Run `./scripts/build_ghosttykit.sh` in that checkout.
- `warning: GhosttyKit.xcframework has no build stamp`: the framework predates the stamp and can't be checked. Rebuild it when convenient.

## Recovery Steps

If the locked Zig version is missing (currently `0.16.0`):

```bash
brew install zig
```

You do not need to relink a versioned Homebrew formula; `scripts/build_ghosttykit.sh` resolves the locked version directly.

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

Smooth-scroll guard rows are captured as `RenderState` overscan rows (upstream #14400), so render row `y` is viewport row `y - viewportStart()`. The fork maps cursor, preedit and hyperlink coordinates accordingly; link underlines used to need a separate build-time patch for this. To run the fork's smooth-scroll regressions, including the link mapping:

```bash
zig build test -Dtest-filter='smooth scroll' -Demit-macos-app=false
```

To reproduce visually, run `scripts/repro-hyperlink-underline` inside Zentty. It prints ordinary URLs and OSC 8 links into scrollback. Scroll by a fraction of a text row, then hold Cmd while hovering each link. The underline must follow the link's text row; repeat with smooth scrolling disabled for comparison.

The downstream audit range should stay small:

```bash
git log --oneline <upstream_revision>..zentty/smooth-scroll
```

It should contain only Zentty's smooth-scroll patch stack, the embedder-vsync patch, and any direct conflict-resolution commits.

The embedder-vsync patch (`feat(zentty): let the embedder drive vsync instead of CVDisplayLink`) adds the `vsync_request_cb` runtime callback and `ghostty_surface_vsync_tick`. On macOS 14+ Zentty sets the callback and drives each surface from an `NSView.displayLink` (`LibghosttyVsyncDriver`), so libghostty never creates a CVDisplayLink. CoreVideo stops running CVDisplayLinks from its display-reconfiguration callback on the main thread, and that stop can hang forever (issue #131, ghostty-org/ghostty#14150). Keep this patch when rebasing until upstream stops using CVDisplayLink.
