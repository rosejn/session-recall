#!/usr/bin/env bash
# recall:classes=chrome-*
# recall:description=Chromium web apps with their original profile
# recall:priority=60
app_command() {
  local window="$1" class profile exe url
  class="$(jq -r '.class' <<<"$window")"
  case "$class" in
    *-Default) profile=Default ;;
    *-Profile_*) profile="Profile ${class##*-Profile_}" ;;
    *) return 1 ;;
  esac
  url="$(jq -r '.launch.command // ""' <<<"$window" | python3 -c '
import shlex, sys
print(next((a for a in shlex.split(sys.stdin.read()) if a.startswith(("https://", "http://"))), ""))
')"
  [[ -n "$url" ]] || return 1
  exe=google-chrome-stable
  command -v "$exe" >/dev/null || exe=google-chrome
  command -v "$exe" >/dev/null || return 1
  printf '%q --profile-directory=%q --hide-crash-restore-bubble --app=%q' "$exe" "$profile" "$url"
}
