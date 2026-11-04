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
| `~/Library/Application Support/Zentty/` | Session restore snapshot, saved pane output, agent session state | No |
| `~/Library/Application Support/Zentty/AgentHistory/` | Agent History search index and its on/off state. Holds copies of your agent conversations, readable only by you and excluded from Time Machine | **No** |
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

## Session restore

Zentty reopens your windows, worklanes and panes when it starts again, after a normal quit, an update relaunch, or a crash. Turn it off with **Restore worklanes on next launch** in Settings → General, or in `config.toml`:

```toml
[restore]
restore_workspace_on_launch = true
scrollback = true
```

`scrollback` (on by default, **Restore pane output** in Settings) brings back what each pane showed. When a pane comes back, its previous output is printed above the new prompt, followed by a dim `── restored from previous session ──` line. In an agent pane the agent resumes after that, the same way it does without saved output.

- Zentty saves the output when you quit. Every few minutes it also saves panes that are running a command or an agent, or that changed since the last save, so most of it survives a crash too.
- Each pane keeps its last 4,000 lines, up to about 1 MB, and older lines are dropped first. A save is capped at 32 MB in total, so with many panes each one keeps less.
- Only plain text is kept. Colors and other terminal control sequences are removed before saving, so printing the output again can't run anything.
- If a full-screen program such as vim or an agent's full-screen interface was open when the output was saved, the pane comes back with that program's last screen instead of the shell output behind it.
- The output is printed by Zentty's shell integration for zsh, bash, fish and nushell. Other shells, and shells started with `ZENTTY_SHELL_INTEGRATION=0`, come back without it.
- Saved output lives in `~/Library/Application Support/Zentty/session-scrollback/`, one file per pane, readable only by you and excluded from Time Machine backups. Pane output can contain secrets. Zentty deletes a file once its pane is gone, and deletes all of them when you turn `scrollback` or session restore off.

## Agent settings

The `[agents]` section holds agent behaviour that isn't tied to one integration:

```toml
[agents]
# Where "Fork Agent Conversation" opens the fork: split_right, split_down or new_worklane.
fork_destination = "split_right"
```

## Agent History settings

Agent History indexes your past Claude Code, Codex, Grok and opencode conversations so you can search and resume them from **Agent History…** (⌘⇧H) or with `zentty history` (see [CLI](cli.md)). It's off until you turn it on in Settings → Agent History, and it doesn't read any conversations before then.

Its settings live in two places.

Whether Agent History is on, and which agents it reads, belong to one Mac. They're kept in `state.json` inside `~/Library/Application Support/Zentty/AgentHistory/` and don't sync. Each Mac builds its own index and asks before reading anything.

Excluded folders and agent access are preferences, so they live in `config.toml` and sync with the rest of it:

```toml
[agent_history]
excluded_folders = ["~/Development/client-secrets", "~/notes"]
allow_agents_all_projects = false
```

- `excluded_folders`: Agent History never indexes a session whose working directory is inside one of these folders. Adding a folder removes its sessions from the index, and removing it lets them be read again. The check uses the folder the agent ran in, not the files it read, so a session started somewhere else that opened a file in an excluded folder is still indexed. Zentty writes paths under your home folder as `~/…`, so the list works on Macs with different user names.
- `allow_agents_all_projects` (**Allow agents to search all projects**, off by default): `zentty history` only sees sessions from the calling pane's project. Turn this on to let `--all` reach every project.

Keep `excluded_folders` on one line. Zentty reads `config.toml` a line at a time, so an array split over several lines makes the file unreadable, and Zentty won't save to it until you fix it (see [How changes arrive](#how-changes-arrive)).

If `config.toml` is unreadable when Zentty starts, Agent History can't tell which folders you excluded, so it pauses. It reads nothing new, and the palette and `zentty history` can't search until the file loads again. Indexing resumes as soon as you fix it. If the file breaks while Zentty is running, Agent History keeps the excluded folders it already had.

What the index holds:

- Your messages and the agents' replies, session titles, branches and folders, and the file paths and commands a session touched. Raw tool output isn't stored. The folder is readable only by you and excluded from Time Machine backups.
- Before storing text, Zentty replaces common API keys and tokens with `‹redacted›`: `sk-` keys, GitHub, GitLab, Slack, Stripe and npm tokens, Google API keys, AWS access key IDs, JWTs, PEM private keys and `Authorization: Bearer` values. It matches by pattern, so anything without a known shape is stored as written. That includes passwords, AWS secret keys and credentials inside connection strings. Exclude folders that hold secrets.
- When an agent deletes one of its transcripts, the session leaves the index too. Claude Code deletes conversations after 30 days unless `cleanupPeriodDays` says otherwise. If it keeps them for less than a year, the Sources list offers **Keep 1 Year**, which sets `cleanupPeriodDays` to 365 in Claude Code's `settings.json` after saving a `settings.json.zentty-backup-…` copy next to it. Zentty changes that file only when you click the button, and doesn't offer it when your organization manages the setting.
- Turning a source off removes that agent's sessions from the index. **Remove from Agent History** keeps a single session out, even after a rebuild. Settings shows how many you've removed and can restore them all.
- Turning Agent History off stops indexing and keeps the index on disk. **Delete Index and Turn Off** removes the whole `AgentHistory` folder: the index, the removed-sessions list, usage data and the on/off state. Your agents' own transcripts aren't touched. Zentty won't delete the index while another running copy of Zentty is using it.

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

## Program status

Programs can set their pane's sidebar status by printing the OSC 9;4 progress sequence; see [Program Status](program-status.md). It's on by default. To turn it off:

```toml
[panes]
program_status = false
```

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
