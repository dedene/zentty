# Program Status

Any program can set its pane's status in the sidebar by printing one escape sequence. There's no CLI to call, no hook to install and no manifest to write. Because the sequence is plain terminal output, it works the same from a remote program over ssh.

Zentty reads the OSC 9;4 progress sequence that many tools already print:

```
ESC ] 9 ; 4 ; <state> [ ; <percent> ] BEL
```

`ST` (`ESC \`) works in place of `BEL`.

| State | Meaning | Sidebar |
|---|---|---|
| `0` | Remove | Status cleared |
| `1` | Progress, with an optional percentage (0–100) | Running, with a progress ring when a percentage is given |
| `2` | Error | Error |
| `3` | Working, no percentage | Running |
| `4` | Paused | Paused, needs attention |

## Examples

Print these from inside a running program or script. At an interactive prompt the command ends right away, and the returning prompt clears a running or paused status before you see it (an error stays).

```sh
printf '\033]9;4;3\007'      # working
printf '\033]9;4;1;42\007'   # working, 42%
printf '\033]9;4;2\007'      # error
printf '\033]9;4;4\007'      # paused, needs attention
printf '\033]9;4;0\007'      # clear
```

To try one by hand, keep the command alive for a moment:

```sh
printf '\033]9;4;1;42\007'; sleep 10
```

Wrap a command so its pane shows it running, and shows an error if it fails. This works in bash and zsh:

```sh
with_status() {
  printf '\033]9;4;3\007'
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '\033]9;4;0\007'
  else
    printf '\033]9;4;2\007'
  fi
  return "$rc"
}

with_status make test
```

Report a percentage from a loop (bash and zsh):

```sh
total=${#files[@]}
i=0
for f in "${files[@]}"; do
  printf '\033]9;4;1;%d\007' $(( i * 100 / total ))
  process "$f"
  i=$(( i + 1 ))
done
printf '\033]9;4;0\007'
```

## How it shows up

- **Running** shows the working indicator on the pane's sidebar row. A percentage below 100 adds a progress ring; hover it for the exact value.
- **Paused** marks the pane as needing attention.
- **Error** marks the pane with an error.

Program status is for panes that don't run an agent. When an agent reports its own status, through hooks or the [Agent Status Protocol](agent-status-protocol.md), the agent's status wins and the sequence is ignored.

## When it clears

- The program prints state `0`.
- The program prints a new state, which replaces the current one.
- The shell prompt comes back. Running and paused clear. An error stays so you can see what failed, and clears once you run the next command.
- You press Return in the pane. Paused and error clear; running stays, because programs read input while they run.
- You press Ctrl+C in the pane.
- A running status gets no new sequence for 5 minutes, unless the shell reports that the command is still running locally. This keeps a program that died without the prompt coming back (for example, over ssh, or in a shell without shell integration) from leaving a spinner behind. A remote job that wants to keep its status should repeat the sequence more often than that; printing an updated percentage counts.

Clearing on prompt return needs Zentty's shell integration in that shell. Without it, state `0` and the timeout still apply.

## Attention

When a pane turns to error or paused, Zentty adds an entry to the notification inbox. If you aren't looking at that pane, it also posts a system notification, using your notification sound settings.

## Turning it off

Set `program_status = false` under `[panes]` in `~/.config/zentty/config.toml`:

```toml
[panes]
program_status = false
```

Turning it off also clears any program status that's showing.
