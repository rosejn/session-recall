#!/usr/bin/env bash
# recall:classes=slack,Slack
# recall:description=Slack desktop client

# Slack is Electron, so it rewrites its own argv into a single space-joined
# blob. /proc therefore reports one "argument" that is really a whole command
# line, and the desktop entry is a more trustworthy source than reconstructing
# it. `-s` is only --silent (no console output) and `%U` is a file-argument
# placeholder that expands to nothing, so neither belongs in a relaunch.
app_command() {
  local desktop exec_line
  for desktop in "$HOME/.local/share/applications/slack.desktop" \
                 /usr/share/applications/slack.desktop; do
    [[ -f "$desktop" ]] || continue
    exec_line="$(sed -n 's/^Exec=//p' "$desktop" | head -1)"
    [[ -n "$exec_line" ]] || continue
    # Strip desktop-entry field codes; they are launcher placeholders, not flags.
    exec_line="$(sed -E 's/%[fFuUdDnNickvm]//g; s/  +/ /g; s/ +$//' <<<"$exec_line")"
    printf '%s' "$exec_line"
    return 0
  done
  command -v slack >/dev/null 2>&1 && { printf 'slack'; return 0; }
  return 1
}
