# Session Recall

Automatic desktop session save and restore for Omarchy 4 (Quattro).

It remembers your windows and which workspace each one lived on, the working
directory of every terminal pane, and — the part other session managers skip —
which coding agent was running in that pane and which conversation it was in.
After a reboot your desktop comes back, and `claude` picks up where it left off.

No `autostart.lua` edits and nothing to remember to press. It is a shell plugin;
enabling it is the whole setup.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-session-recall.git --enable
```

Or, working from a local checkout:

```bash
cp -r session-recall ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy plugin enable session-recall --section right
```

Optional, for the CLI:

```bash
ln -s ~/.config/omarchy/plugins/session-recall/bin/recall ~/.local/bin/recall
```

## How it decides what it can restore

Every window is given a restore recipe and an honest confidence tier. This is
the whole design: a restore you can trust is worth more than a restore that
tries hard.

| Tier | How it was worked out | On restore |
|---|---|---|
| `exact` | The window owns its pid, so `/proc` gave us the real argv and cwd | Launched verbatim |
| `webapp` | A Chromium class such as `chrome-discord.com__channels_@me-Default` decoded back to a URL and matched a `.desktop` | Launched via `omarchy-launch-webapp` |
| `guess` | Only the window class matched a desktop entry | **Parked**, and you get a notification offering to launch it |
| `none` | Shared pid, no desktop entry | Recorded, never launched |

Restoring reconciles instead of recreating: a window that is already open is
moved to its saved workspace rather than opened a second time. Restoring twice
does nothing the second time, which also makes it usable as a tidy-up button.

## Window geometry

Positions and sizes are restored exactly, not just workspace assignment.

That takes more than a resize call. In a tiling layout a window's geometry is a
property of the split tree, and the tree comes from insertion order — two
windows side by side and two stacked are the same resize calls but a different
tree. Ratios alone can never repair a layout that was built in a different
order.

So Session Recall recovers the tree from the saved rectangles: find the
straight line that cuts the set cleanly in two, recurse on each side, and emit
the insertions that rebuild it. Applying it uses a trick — floating every
window on the workspace empties the tree without closing anything, and each
window is then un-floated in planned order, against a focused neighbour with
`preselect` forcing the split direction. A final sizing pass runs outermost
window first, so each correction only has to fix what the previous one moved.

Floating windows are set outright, and fullscreen is applied last so it does not
hide the tree being built underneath it.

Verified by scrambling a live workspace — different tree, different sizes,
different order — and restoring it back to a byte-identical `hyprctl clients`
dump. Expect the odd 1–2px difference where gaps round.

Workspaces running Omarchy's `scrolling` layout build their own geometry and are
left alone. `--no-geometry` skips the whole pass.

## Agents

Terminal backends are detected, never required — herdr, tmux, or neither.

herdr already restores its own workspaces, tabs, panes and their working
directories from `~/.config/herdr/session.json`. What it does not restore is
which agent was living in each pane, so that is the only thing this adds.

A session id is only accepted when one of these produced it:

| Method | Agent | What it is |
|---|---|---|
| `argv` | all | The id is in the process command line because the session was itself resumed |
| `pane-title` | claude | The terminal title is the session's own summary; a *unique* grep hit across that project's transcripts identifies it |
| `process-log` | codex | `~/.codex/logs_2.sqlite` tags log rows with the owning pid — an exact join |
| `launch-time` | codex | Process start time lines up with exactly one rollout header in the same cwd, within 5 minutes |
| `continue` | claude, pi, opencode, crush | No id worth staking a resume on, but the CLI can reopen the most recent conversation for that directory |

Ambiguity is a failure, not a coin flip. Two candidates means no resume, and the
pane comes back as a plain shell — a wrong resume is worse than none. The
snapshot before restoring is verified to still exist on disk.

## Using it

Mostly you don't. The bar dropdown is for when you want to be explicit:

- **Left click** — the dropdown: name a setup, restore one, toggle behaviour
- **Right click** — snapshot right now, before whatever you are about to do
- **Middle click** — restore the newest snapshot

Named setups are suggested from the git repo most of your terminals are sitting
in, so `sbx_engine` beats `20260829-105317` when you come back to it a week later.

## CLI

```
recall save [NAME]              Save a named setup
recall restore [NAME]           Restore (default: newest)
recall restore --dry-run        Show what would happen, change nothing
recall list [--json]            List setups
recall status [NAME]            What a snapshot holds, agent by agent
recall doctor                   What this machine can capture
recall delete NAME
```

`recall doctor` is the first thing to run if something looks wrong; it reports
which backends answered and which agents are installed.

## Settings

`~/.local/state/omarchy-recall/config.json` is the single source of truth, watched
live by the service and written by the dropdown or `recall config <key> <value>`.

| Key | Default | Meaning |
|---|---|---|
| `autoSave` | `true` | Snapshot when the desktop settles after a change |
| `autoRestore` | `true` | Restore once on the first shell start after a boot |
| `autoSaveDebounceSec` | `8` | Quiet period before a snapshot is taken |
| `keepAutoSnapshots` | `20` | Automatic snapshots kept before the oldest are trimmed |
| `ignoreClasses` | `[]` | Extra window classes to leave out, on top of the built-in desktop furniture |

## Notes

- State lives in `~/.local/state/omarchy-recall`, mode `0700`: snapshots include
  terminal scrollback, which includes whatever was on your screen.
- Restore is keyed to monitor topology and warns when it changed since the
  snapshot, so a docked layout does not silently pile onto a laptop panel.
- Restoring runs once per boot, keyed on `/proc/sys/kernel/random/boot_id`, so
  restarting the shell never triggers a second restore.
- The herdr integration is gated on its reported socket `protocol` version and
  skips agent resume rather than guessing if that number moves.

## Credit

The agent-identification tiers are ported from `devteam`, an earlier tmux-only
tool of mine, and extended to herdr and to agents beyond claude and codex.
