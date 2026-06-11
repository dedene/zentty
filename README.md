<!-- LOGO -->
<h1>
<p align="center">
  <img src="assets/icon.png" alt="Zentty" width="128">
  <br>Zentty
</h1>
  <p align="center">
    A native macOS terminal for agent-driven development, built on Ghostty.
    <br />
    Zentty gets out of the way. Minimal friction, maximum focus.
    <br />
    <a href="https://github.com/dedene/zentty/releases/latest/download/Zentty.dmg">Download</a>
    ·
    <a href="#install">Install</a>
    ·
    <a href="#status">Status</a>
    ·
    <a href="#build">Build</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
  </p>
</p>

<p align="center">
  <img src="assets/screenshot.png" alt="Zentty screenshot" width="880">
</p>

## Features

- **Worklanes, not just tabs.** Borrowed from niri and Hyprland: a horizontally-scrolling strip of columns, each column a vertical stack of panes. Rearrange, resize, and navigate without losing your place.
- **Keyboard-first, top to bottom.** Every action is a command. Every command is bindable. Rebind anything in settings, or fall back to the command palette when your muscle memory runs out.
- **Resume your workspace** Zentty restores your worklanes on relaunch and can reopen agent sessions that were closed without finishing.
- **Command palette** A fuzzy-searchable list of every action in the app, with your recent commands on top.
- **Global search** Search inside the current pane or across every worklane with a single shortcut. Search without losing flow.
- **Agent-aware.** Claude Code, Codex, Copilot CLI, Cursor, Droid CLI, Gemini CLI, Hermes Agent, Kimi CLI, OpenCode, and Pi report their status into the sidebar, so you see what they're doing, what they're asking, and when they need you, without switching panes.
- **Native Ghostty themes.** Zentty reads Ghostty themes directly, with a built-in picker, live preview, opacity, and blur. And if you've never installed
   Ghostty, the default experience is polished out of the box.
- **Scriptable control** Interaction with worklanes or panes is scriptable via the embedded zentty CLI.
- **Built on Ghostty.** GPU-accelerated rendering via `libghostty`, wrapped in a native Swift and AppKit shell. No Electron, no web views. It feels like a Mac app because it is one.

See [Zentty CLI](docs/cli.md) for command-line usage.

## Agent Skill

Agents can install the Zentty CLI skill to discover pane-aware commands while running inside Zentty:

```bash
npx skills add dedene/zentty
```

## Install

Download the latest `.dmg` from the [releases page](https://github.com/dedene/zentty/releases/latest), open it, and drag Zentty to your Applications folder.

Zentty updates itself in place via [Sparkle](https://sparkle-project.org) once installed. No need to check back here for new versions.

Builds are signed and notarized by Zenjoy BV. Requires macOS 14 (Sonoma) or later.

## Status

Zentty is in active development. Expect rapid iteration, rough edges, and occasional breaking changes while the project is opened up.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode
- `zig` on `PATH`
- `gettext` on `PATH`

## Build

Zentty requires a local `GhosttyKit.xcframework` before the app can build normally.

Build the framework:

```bash
./scripts/build_ghosttykit.sh
```

Then build the app:

```bash
xcodebuild -project Zentty.xcodeproj -scheme Zentty -destination 'platform=macOS' build
```

If you need to regenerate the Xcode project from [`project.yml`](project.yml):

```bash
bundle exec fastlane mac generate_project
```

More detail about the Ghostty bootstrap flow lives in [`docs/ghosttykit-setup.md`](docs/ghosttykit-setup.md).

## Windows

A native Windows port lives in [`rust/`](rust/): a Rust workspace rendering with Direct2D/DirectWrite over ConPTY (no Electron, no web views). It ships the same core ideas — worklanes, panes, sidebar with agent status pills, command palette, global search, themes.

Requirements: Rust (MSVC toolchain) and the Windows 10/11 SDK (for the resource compiler that embeds the app icon).

Build and run from a clean clone:

```powershell
cd rust
cargo build --release --workspace
.\target\release\zentty-win-desktop.exe
```

Keyboard map (everything else is reachable through the command palette):

| Keys | Action |
|---|---|
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+D` / `Ctrl+Shift+D` | Split pane side-by-side / stacked |
| `Ctrl+W` | Close pane (a pane also closes itself when its shell exits) |
| `Ctrl+←` `→` `↑` `↓` | Move focus between panes |
| `Ctrl+Shift+F` | Global search |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | Copy selection / paste |

Run the tests:

```powershell
cd rust
cargo test --workspace
```

Package and install (per-user, no admin; creates `rust/dist/zentty-windows-x64.zip`):

```powershell
pwsh -File rust/scripts/package-windows.ps1
Expand-Archive rust/dist/zentty-windows-x64.zip -DestinationPath $env:TEMP\zentty-install
pwsh -File $env:TEMP\zentty-install\install.ps1   # installs to %LOCALAPPDATA%\Zentty + Start-menu shortcut
```

Uninstall with the packaged `uninstall.ps1`. To build an MSI instead, install the [WiX Toolset](https://wixtoolset.org) (`dotnet tool install --global wix`) and `cargo install cargo-wix`, run `cargo wix init --package zentty-win` once to generate `wix/main.wxs`, then `cargo wix --package zentty-win` from `rust/`; signing is a separate `cargo wix sign` step and requires a code-signing certificate (WiX/NSIS are not required for the zip package above).

Note: the desktop binary is a GUI app (`windows_subsystem = "windows"`), so `--help` output is not visible from a console; launch flags are `--config PATH`, `--workspace RESTORE_JSON`, `--cols N`, `--rows N`, `--title TITLE` (see `DesktopShellConfig` in `rust/crates/zentty-win/src/desktop.rs`); screenshot-tooling toggles are env-var based (`ZENTTY_SHOT_*`).

## Test

Run the full test suite:

```bash
ZENTTY_TEST_DISPLAY_PROVIDER=betterdisplay scripts/test-on-virtual-display
```

## Agent Hooks

Zentty bundles helper commands and environment variables for agent-aware workflows inside terminal panes.

Hook configuration details are documented in [`docs/agent-hooks.md`](docs/agent-hooks.md).

For Kimi specifically: do first-time auth with `kimi login` before using wrapped `kimi` inside Zentty. Zentty passthroughs Kimi's management commands directly to the real Kimi binary so login/logout keep using the default Kimi config. If you want a specific model, prefer `kimi --model <model-id>` or set `default_model` in `~/.kimi/config.toml`.

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

Before a non-trivial contribution can be merged, contributors must agree to [`CLA.md`](CLA.md).

## License

Zentty is available under the GNU General Public License v3.0 only (`GPL-3.0-only`). See [`LICENSE`](LICENSE).

If your organization cannot or does not want to comply with GPLv3, alternative commercial licensing may be available from Zenjoy BV. Contact `hallo@zenjoy.be`.

## Trademarks

The GPL license covers the code. It does not grant rights to use the Zentty name, logos, icons, or other branding for your own distribution.

See [`TRADEMARKS.md`](TRADEMARKS.md) for branding rules.
