#!/usr/bin/env bash
# recall:classes=Spotify,spotify
# recall:description=Spotify desktop client

# Spotify's desktop entry is `spotify --uri=%u`. Launched without a URL the
# field code collapses and the running process carries a bare `--uri`, which is
# an artifact of how it was started rather than an argument worth reproducing.
app_command() {
  command -v spotify >/dev/null 2>&1 || [[ -x /opt/spotify/spotify ]] || return 1
  printf 'spotify'
}
