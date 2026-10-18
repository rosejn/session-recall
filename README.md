# Session Recall

Automatic desktop session save and restore for Omarchy 4 (Quattro).

It remembers your windows and which workspace each one lived on, every terminal
tab and pane with its working directory, and — the part other session managers
skip — which coding agent was running in it and which conversation it was in.
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

## Browser profiles and crash recovery

Chromium windows launch with an explicit `--profile-directory`,
`--restore-last-session`, and `--hide-crash-restore-bubble`. This bypasses the
profile picker and permits automatic restoration after an unclean shutdown.
The flags must reach the first browser process; changing them while Chrome is
already running does not change that process's crash-recovery behavior.

Capture records profile identity when the window title matches exactly one
profile's session files. Older snapshots can use the same evidence at restore
time. When identity is ambiguous, the last active profiles are used instead.
Each profile starts once, and restored browser windows are placed by title
rather than their arrival order. A changed title may prevent placement; the
restore log names windows it could not match. Web apps retain the profile
encoded in their window class.

Codex restores first ask the daemon manager to start, with a 20-second timeout.
If startup fails, the same saved conversation opens with `--no-daemon`.

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

## Adding support for an app

No app-specific logic lives in the engine. Everything Session Recall knows about
a particular program lives in one small file, so teaching it about a new app
never means touching the core.

```
apps/<name>.sh      a window: how to relaunch it, and when
agents/<name>.sh    a coding agent: how to trust a directory and resume it
```

Each file is plain bash, sourced in a subshell, so every handler can use the
same function names without colliding.

Handlers with only `recall:classes` and `app_command` are the common case.
Beyond that a handler can declare `recall:serialize=true` and define
`app_prepare` (runs just before the launch), `app_post_launch` (runs once the
window is on screen, with its address) and `app_plan` (what the dry run
prints); `apps/ghostty.sh` uses all three to rebuild tabs.

### An app handler

```bash
#!/usr/bin/env bash
# recall:classes=Spotify,spotify        # window classes, globs allowed
# recall:description=Spotify desktop client
# recall:priority=10                    # optional; lower launches earlier (default 50)
# recall:singleton=true                 # optional; launch once however many windows were saved

# Print the command that relaunches this window. Print nothing (or return 1) to
# let the generic /proc recipe handle it.
app_command() {
  local window="$1"       # the saved window as JSON
  printf 'spotify'
}

# Optional. Print a JSON object to fold into the saved record.
app_capture() { local window="$1" pid="$2"; }
```

A handler outranks every generic recipe, and also rescues an app that would
otherwise be parked as an uncertain class-only guess.

`priority` matters more than it looks. A browser only honours
`--restore-last-session` in the process that *starts* the browser, so its main
window has to be launched before any `--app=` web app window, or the flag
arrives at a running instance and does nothing.

`singleton` is for apps that restore their own windows: launch once, and let the
app bring the rest back. Without it you get the app's restored session *plus* one
spare window for every window after the first.

### An agent handler

```bash
#!/usr/bin/env bash
# recall:agent=codex

# Record the directory as trusted, so a restored agent starts in its session
# instead of on a "do you trust this folder?" prompt. Restoring a session the
# user created is not a new trust decision.
agent_trust() { local cwd="$1"; }

# Print the command that reopens a captured conversation.
agent_resume_command() {
  local cwd="$1" id="$2" method="$3"   # method: argv | pane-title | process-log | launch-time | continue
  printf '%q resume %q' "$(command -v codex)" "$id"
}
```

### What ships today

| Handler | What it knows |
|---|---|
| `apps/slack.sh` | Electron rewrites its argv into one blob, so use the desktop entry instead; strip `%U` and `-s` |
| `apps/spotify.sh` | The running process carries a bare `--uri` left over from the desktop entry's `%u` |
| `apps/chromium.sh` | Needs `--restore-last-session` or you get only pinned tabs; must start before its web apps; restores its own windows |
| `apps/ghostty.sh` | `/proc` only knows how the window was opened, not what its tabs were doing; walks the process tree at save time and rebuilds every tab on restore — see [Terminal tabs](#terminal-tabs) |
| `agents/claude.sh` | Trust lives in `~/.claude.json`; resumes with `--resume <id>` or `--continue` |
| `agents/codex.sh` | Trust lives in `~/.codex/config.toml`; resumes with `codex resume <id>`; has no `--continue` |

Anything without a handler still gets the generic recipe. The log names those
apps explicitly on every save, so a gap is something you can see and fill rather
than a silent shrug — and the bar dropdown shows the count.

## Logs

Save and restore both run unattended, so the log is the whole story when a
window does not come back.

```
recall logs            # last 200 lines
recall logs -n 500 -f  # follow
```

The dropdown has a button for it, next to one for `recall doctor`. Every entry
names the handler that ran, or says which app had none.

## Terminal tabs

A Ghostty window is one Hyprland window however many tabs it holds, and with
`gtk-single-instance` every window shares one pid, so `hyprctl` and `/proc`
argv say nothing about the tabs. What they do expose is the process tree:
each tab's shell is a direct child of the ghostty pid, and the tty's
foreground process group says what that shell is running. So a save records,
per tab, the directory and the program — `herdr`, an agent and its session, or
`ssh leo`.

Getting them back is the harder half. Ghostty's only IPC for tabs is a bare
`new-tab` action: no directory, no command. So the restore launches the window
into the first tab's directory, then opens the rest one at a time over D-Bus,
and a small hook in the shell does the part Ghostty cannot: at its first
prompt, a fresh tab claims the next queued spec, `cd`s there, and runs the
program as if you had typed it — a real job, with history and job control. The
queue lives only for the seconds a restore is opening tabs; the rest of the
time the hook is inert.

For fish the hook is installed by the first restore, as
`~/.config/fish/conf.d/session-recall.fish`. bash and zsh have no drop-in
directory, so add one line to `~/.bashrc` or `~/.zshrc`:

```bash
. ~/.config/omarchy/plugins/session-recall/shell/session-recall.bash
```

`recall doctor` says whether the hook is in place. Without it the window still
comes back, with herdr in its first tab via `-e herdr` when that is where herdr
was, and the log names the tabs that were left out.

What runs inside a restored tab is deliberately narrow: `herdr`, an agent whose
session was verified (the same rules as below), and a short list of
interactive tools — editors, `lazygit`, `htop`, `ssh`, `tmux` and the like,
kept in `TAB_PROGRAMS` at the top of `apps/ghostty.sh`. A tab that was running
anything else comes back as a shell in the right directory, and the log says
what it was running. Relaunching arbitrary commands unattended at boot is not
a restore anyone can trust.

Tabs and splits look the same from `/proc`, so a split comes back as a tab.
Tab order is process creation order, which is the tab order unless tabs were
dragged around. With several Ghostty windows open they all share one pid, so
which tab belonged to which window is attributed by title and logged as the
guess it is.

## Agents

Terminal backends are detected, never required — herdr, tmux, or neither.

herdr already restores its own workspaces, tabs, panes and their working
directories from `~/.config/herdr/session.json`. What it does not restore is
which agent was living in each pane, so that is the only thing this adds.

None of that happens unless the herdr server is running, and on a cold boot
nothing starts it but the terminal tab that hosted it — which is why
`apps/ghostty.sh` records that tab as running `herdr` and starts it there again
rather than leaving the bare shell `/proc` reported. A terminal without a
handler comes back as a plain prompt, the server never appears, and the log
reads `herdr did not come up within 45s; skipping agent resume`.

An agent running straight in a terminal tab, outside herdr or tmux, is found
the same way and resumed by the same rules.

A session id is only accepted when one of these produced it:

| Method | Agent | What it is |
|---|---|---|
| `argv` | all | The id is in the process command line because the session was itself resumed |
| `pid-registry` | claude | Claude Code registers each running process in `~/.claude/sessions/<pid>.json` with its session id and start time — an exact join |
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
- A handler is only consulted if it existed when the snapshot was *saved*; a
  restore reads what the save recorded. Adding a handler pays off from the next
  automatic snapshot on, not for the one already on disk.
- The herdr integration is gated on its reported socket `protocol` version and
  skips agent resume rather than guessing if that number moves.

## Credit

The agent-identification tiers are ported from `devteam`, an earlier tmux-only
tool of mine, and extended to herdr and to agents beyond claude and codex.
