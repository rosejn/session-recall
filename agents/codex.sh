#!/usr/bin/env bash
# recall:agent=codex
# recall:description=OpenAI Codex CLI

# Codex keeps per-directory trust in ~/.codex/config.toml as
#   [projects."/path"]
#   trust_level = "trusted"
# Appending the stanza is enough; codex reads it on start. Restoring a session
# the user created in that directory is not a new trust decision.
agent_trust() {
  local cwd="$1" file="$HOME/.codex/config.toml"
  [[ -n "$cwd" && -d "$cwd" ]] || return 1
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : > "$file"

  # Already declared? Match the exact quoted path so /home/x never satisfies
  # a lookup for /home/x/y.
  grep -qxF "[projects.\"$cwd\"]" "$file" 2>/dev/null && return 0

  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$cwd" >> "$file"
}

agent_resume_command() {
  local cwd="$1" id="$2" method="$3" exe script
  exe="$(command -v codex 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  # codex has no --continue; without a verified id there is nothing to reopen.
  [[ "$method" != "continue" ]] || return 1
  [[ -n "$id" ]] || return 1
  # Let the supported daemon manager finish cold-boot startup. If it cannot,
  # keep the saved conversation usable through the CLI's documented fallback.
  # This command is typed into the user's shell (often fish). Keep Bash
  # control flow inside an explicit interpreter so fish does not wait for an
  # `end` forever. exec also leaves the actual agent visible in the process tree.
  printf -v script 'if timeout 20 %q app-server daemon start >/dev/null 2>&1; then exec %q resume %q; else exec %q --no-daemon resume %q; fi' \
    "$exe" "$exe" "$id" "$exe" "$id"
  printf 'bash -c %q' "$script"
}
