#!/usr/bin/env bash
# recall:classes=chromium,Chromium,chrome,google-chrome,google-chrome-stable,brave,brave-browser
# recall:description=Chromium-family browser windows (not Omarchy web apps)
# recall:priority=10
# recall:singleton=true

# A browser window shares one pid with every other window of that browser, so
# /proc can never describe just this one. The browser's own session store knows
# far more than we could capture -- but only reopens it when asked.
#
# Without --restore-last-session a fresh launch shows the start page and, if the
# profile has pinned tabs, only those, which reads as "my tabs are gone". The
# flag is exactly what "Continue where you left off" does from the menu.
#
# --restore-last-session is only honoured by the process that starts the
# browser. Omarchy web apps are --app= windows of the *same* browser, so if one
# of them starts first the flag arrives at an already-running instance and does
# nothing -- which is exactly how a restore ends up showing only pinned tabs.
# Hence the low priority number: this window must be launched first.
#
# And singleton=true, because restoring the session brings back *every* browser
# window by itself. Launching once per saved window would restore the session
# and then add a spare empty window for each one after the first.
#
# Note the Omarchy web apps (class chrome-<host>__-Default) are deliberately not
# claimed here: those are single-purpose --app= windows, handled by the webapp
# tier, and restoring a whole session into one would be wrong.
app_command() {
  local window="$1" class exe
  class="$(jq -r '.class // ""' <<<"$window")"
  case "$class" in
    chrome-*) return 1 ;;   # an --app= web app window; not ours
  esac
  for exe in chromium google-chrome-stable google-chrome brave chrome; do
    if command -v "$exe" >/dev/null 2>&1; then
      printf '%s --restore-last-session' "$exe"
      return 0
    fi
  done
  return 1
}
