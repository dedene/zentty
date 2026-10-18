# Configuration and Syncing

Zentty keeps everything you set up in `~/.config/zentty/`. That folder is safe to sync between Macs with Syncthing, a dotfiles repo, or similar, with one exception: the `run/` directory.

## What lives where

| Path | What it holds | Sync it? |
| --- | --- | --- |
| `~/.config/zentty/config.toml` | All app settings: sidebar, pane layout, appearance and theme, keyboard shortcuts, notifications, open-with apps, server detection, agent integration choices | Yes |
| `~/.config/zentty/bookmarks.json` | Saved worklane bookmarks | Yes, see [Bookmarks](#bookmarks) |
| `~/.config/zentty/sounds/` | Copies of custom notification sounds | Yes |
| `~/.config/zentty/agents/` | Your own agent definitions ([Agent Hooks](agent-hooks.md)) | Yes |
| `~/.config/zentty/run/` | The running app's socket, locks and agent wrapper scripts | **No** |
| `~/Library/Application Support/Zentty/` | Session restore snapshot, agent session state | No |
| `~/Library/Preferences/be.zenjoy.zentty.plist` | Window positions, update checks | No |

The Zentty Dev build uses `~/.config/zentty-dev/` and `~/Library/Application Support/Zentty Dev/` instead.

## Syncing with Syncthing

Share `~/.config/zentty` and add this to its `.stignore`:

```
run
```

Zentty 0.3.7 and earlier kept session state in the same folder. Newer versions copy it out once and leave the old files in place, so add these too:

```
restore-snapshot.json
restore-lifecycle.json
tmux-compat-store.json
tmux-compat-trace.jsonl
```

Once every Mac runs a newer version, you can delete those four files from `~/.config/zentty`.

Don't sync the open windows and worklanes themselves. They belong to the Mac they run on, and each Mac restores its own session.

## How changes arrive

- **config.toml** reloads as soon as it changes on disk, so a setting changed on one Mac shows up on the other without a restart. This also works when `config.toml` is a symlink into another folder; Zentty writes through the link instead of replacing it.
- **bookmarks.json** reloads live too.
- **agents/** is read at launch. Restart Zentty after changing it.

If `config.toml` contains a line Zentty can't read, Zentty logs it and won't save over the file until you fix it. In the meantime it runs on its last good settings, or on defaults if the file was already broken at launch. Zentty also keeps sections and keys it doesn't recognize when it saves, so a Mac on an older version doesn't strip settings a newer version added. This works from the version after 0.3.7 onward; 0.3.7 and earlier treat an unknown section as a broken file and reset it to defaults on their next save, so keep shared Macs on the same version. Keys inside individual open-with apps, browsers and shortcut bindings aren't covered.

## Bookmarks

Bookmarks store each pane's working directory as a full path. They work on both Macs when your user name and project folders match. Paths under your home folder in custom open-with apps and browsers are stored as `~/…`, so those don't depend on the user name.

If both Macs edit bookmarks at the same moment, Syncthing keeps one version and saves the other as a conflict file next to it.

## Terminal appearance

Font, colors, padding and terminal keybindings come from your Ghostty config, if you have one:

- `~/.config/ghostty/config` or `~/.config/ghostty/config.ghostty`
- `~/Library/Application Support/com.mitchellh.ghostty/config` (and `config.ghostty`)
- themes in `~/.config/ghostty/themes/`

Sync `~/.config/ghostty/` as well for identical terminals. Ghostty.app reads the same files.

The theme and background opacity you pick in Zentty's settings are always recorded in `config.toml` as well. A Mac without a Ghostty config uses those.

## Custom notification sounds

macOS only plays notification sounds from `~/Library/Sounds`. When you pick a custom sound, Zentty installs it there and keeps a copy in `~/.config/zentty/sounds/`. A Mac that receives the setting through sync installs the sound from that copy the first time it needs it.

## Replying from notifications

When an agent finishes a turn, its macOS notification has a **Reply** field. What you type is sent to the agent's prompt as one message with a single Return. The pane doesn't have to be in front. Line breaks in a reply become spaces, so a reply can't be submitted line by line.

A reply is only typed if the pane still exists, the agent is still running in it, and it is still idle after the turn the notification was raised for. If the agent has started another turn, has exited back to the shell, or the pane is gone, nothing is typed and Zentty opens the pane instead. The same happens when you reply to an older notification after turning the setting off.

Notifications for agents that need input (approvals, questions, choices, sign-in) keep **Jump to Pane** only, since the agent expects keystrokes in its own interface there.

Turn it off in Settings → Notifications, or in `config.toml`:

```toml
[notifications]
inline_reply = false
```
