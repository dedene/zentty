# Zentty

Zentty is a Ghostty-based native macOS terminal for agent-native development.

## Status

Zentty is in active development. Expect rapid iteration, rough edges, and occasional breaking changes while the project is opened up.

## Requirements

- macOS 14 or later
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

## Test

Run the full test suite:

```bash
xcodebuild test -scheme Zentty -destination 'platform=macOS'
```

## Agent Hooks

Zentty bundles helper commands and environment variables for agent-aware workflows inside terminal panes.

Hook configuration details are documented in [`docs/agent-hooks.md`](docs/agent-hooks.md).

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

Before a non-trivial contribution can be merged, contributors must agree to [`CLA.md`](CLA.md).

## License

Zentty is available under the GNU General Public License v3.0 only (`GPL-3.0-only`). See [`LICENSE`](LICENSE).

If your organization cannot or does not want to comply with GPLv3, alternative commercial licensing may be available from Zenjoy BV. Contact `hallo@zenjoy.be`.

## Trademarks

The GPL license covers the code. It does not grant rights to use the Zentty name, logos, icons, or other branding for your own distribution.

See [`TRADEMARKS.md`](TRADEMARKS.md) for branding rules.
