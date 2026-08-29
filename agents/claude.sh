#!/usr/bin/env bash
# recall:agent=claude
# recall:description=Claude Code

# Claude records "you accepted the trust dialog for this folder" per project in
# ~/.claude.json. Restoring a session the user themselves started in that
# folder is not a new trust decision, so pre-record it rather than leaving the
# restored pane sitting on a modal nobody asked for.
#
# The file is also written by any running Claude instance, so touch it only
# when the flag is actually missing, and swap it in atomically.
agent_trust() {
  local cwd="$1" file="$HOME/.claude.json" tmp
  [[ -n "$cwd" && -d "$cwd" ]] || return 1
  [[ -f "$file" ]] || printf '{}\n' > "$file"

  jq -e --arg d "$cwd" '.projects[$d].hasTrustDialogAccepted == true' "$file" >/dev/null 2>&1 \
    && return 0

  tmp="$(mktemp "$(dirname "$file")/.claude.json.XXXXXX")"
  if jq --arg d "$cwd" '
        .projects //= {}
      | .projects[$d] //= {}
      | .projects[$d].hasTrustDialogAccepted = true' "$file" > "$tmp" 2>/dev/null; then
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"; return 1
  fi
}

agent_resume_command() {
  local cwd="$1" id="$2" method="$3" exe
  exe="$(command -v claude 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  if [[ "$method" == "continue" ]]; then
    printf '%q --continue' "$exe"
  else
    [[ -n "$id" ]] || return 1
    printf '%q --resume %q' "$exe" "$id"
  fi
}
