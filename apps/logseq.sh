#!/usr/bin/env bash
# recall:classes=logseq,Logseq
# recall:description=Logseq AppImage (stable launcher, never a /tmp mount)
# recall:singleton=true
app_command() {
  local exe
  for exe in "$HOME/.local/bin/Logseq.AppImage" /usr/bin/logseq; do
    if [[ -x "$exe" ]]; then
      printf '%q --no-sandbox' "$exe"
      return 0
    fi
  done
  return 1
}
