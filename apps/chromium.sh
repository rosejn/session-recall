#!/usr/bin/env bash
# recall:classes=chromium,Chromium,chrome,google-chrome,google-chrome-stable,brave,brave-browser
# recall:description=Chromium-family browser windows (not Omarchy web apps)
# recall:priority=10
# recall:singleton=true

app_capture() {
  "$RECALL_ROOT/bin/recall-browser-profile" "$1"
}

# Restore once per profile. Explicit profiles bypass Chrome's profile picker.
# Session-title evidence also lets old snapshots recover profile identity.
app_command() {
  local window="$1" class exe profiles profile command
  class="$(jq -r '.class // ""' <<<"$window")"
  case "$class" in
    chromium|Chromium) exe=chromium ;;
    brave|brave-browser) exe=brave-browser; command -v "$exe" >/dev/null || exe=brave ;;
    *) exe=google-chrome-stable; command -v "$exe" >/dev/null || exe=google-chrome ;;
  esac
  command -v "$exe" >/dev/null || return 1
  profiles="$(app_capture "$window")" || return 1
  command=""
  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    printf -v command '%s%s%q --profile-directory=%q --restore-last-session --hide-crash-restore-bubble' \
      "$command" "${command:+; }" "$exe" "$profile"
  done < <(jq -r '.browser.profiles[]' <<<"$profiles")
  [[ -n "$command" ]] || return 1
  printf 'bash -c %q' "$command"
}
