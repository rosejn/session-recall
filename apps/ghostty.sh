#!/usr/bin/env bash
# recall:classes=com.mitchellh.ghostty,ghostty
# recall:description=Ghostty terminal, including the window that hosts herdr
# recall:priority=5

# Ghostty's /proc argv is only how the *window* was opened -- typically
# `ghostty --gtk-single-instance=true --working-directory=~` -- and says
# nothing about what the shell inside went on to run. When that was `herdr`,
# a verbatim relaunch gives back an empty prompt: no herdr client, so no herdr
# server, so nothing for the agent-resume pass to talk to. It waits, times
# out, and every agent is skipped.
#
# So at capture time walk the process tree under the window and note whether
# a herdr client lives there. At restore time relaunch with `-e herdr ...` so
# the server comes up as part of the window, and the priority is low so it is
# up long before the agent pass needs it.

# Descendant pids of $1, breadth first.
_descendants() {
  local queue=("$1") pid c
  while ((${#queue[@]})); do
    pid="${queue[0]}"; queue=("${queue[@]:1}")
    for c in $(proc_children "$pid"); do
      printf '%s\n' "$c"; queue+=("$c")
    done
  done
}

# Is this pid an attached herdr client (not the server, not a CLI helper)?
# Prints its arguments after argv[0], one per line.
_herdr_client_args() {
  local pid="$1" argv first
  argv="$(proc_argv_json "$pid" 2>/dev/null)" || return 1
  [[ "$(basename "$(jq -r '.[0] // ""' <<<"$argv")")" == "herdr" ]] || return 1
  first="$(jq -r '.[1] // ""' <<<"$argv")"
  case "$first" in
    "" | --session | --remote | --remote-keybindings | --handoff) ;;
    session) [[ "$(jq -r '.[2] // ""' <<<"$argv")" == "attach" ]] || return 1 ;;
    *) return 1 ;;
  esac
  jq -r '.[1:][]' <<<"$argv"
}

app_capture() {
  local window="$1" pid="$2" title hostname_ d args shell_pid p
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != "0" ]] || return 1
  title="$(jq -r '.title // ""' <<<"$window")"
  hostname_="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"

  local found=() found_shell=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if args="$(_herdr_client_args "$d")"; then
      found+=("$d"); found_shell+=("$(_shell_under "$pid" "$d")")
    fi
  done < <(_descendants "$pid")
  ((${#found[@]})) || return 1

  # With gtk-single-instance every ghostty window shares this pid, so a herdr
  # client somewhere under it does not prove it is in *this* window. herdr
  # titles its window "{hostname}: {workspace}" by default; take that as the
  # tie-breaker when there is more than one window on the pid.
  local windows_on_pid
  windows_on_pid="$(hyprctl -j clients 2>/dev/null \
    | jq -r --argjson p "$pid" '[.[] | select(.pid == $p)] | length' 2>/dev/null || echo 1)"
  if ((windows_on_pid > 1)) && [[ "$title" != "$hostname_: "* ]]; then
    return 1
  fi
  ((${#found[@]} == 1)) || return 1   # two clients, no way to tell which is ours

  p="${found[0]}"; shell_pid="${found_shell[0]}"
  args="$(_herdr_client_args "$p" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -nc --argjson args "$args" \
    --arg cwd "$(proc_cwd "${shell_pid:-$p}" 2>/dev/null || true)" \
    '{ app: { herdr: true, herdrArgs: $args, cwd: $cwd } }'
}

# The direct child of the window pid (the shell) that the herdr client sits
# under; its cwd is where the shell was, which is where herdr should reopen.
_shell_under() {
  local root="$1" pid="$2" parent
  while [[ -n "$pid" && "$pid" != "$root" && "$pid" != "1" ]]; do
    parent="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [[ "$parent" == "$root" ]] && { printf '%s' "$pid"; return 0; }
    pid="$parent"
  done
  return 1
}

app_command() {
  local window="$1" cwd exe a
  [[ "$(jq -r '.app.herdr // false' <<<"$window")" == "true" ]] || return 1
  exe="$(command -v ghostty 2>/dev/null)" || return 1
  command -v herdr >/dev/null 2>&1 || return 1
  cwd="$(jq -r '.app.cwd // ""' <<<"$window")"
  [[ -d "$cwd" ]] || cwd="$(jq -r '.launch.cwd // ""' <<<"$window")"

  # Keep the flags the window was opened with (single-instance and the like),
  # but the working directory and the command are ours to set.
  local -a flags=()
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case "$a" in
      --working-directory=*|-e) break ;;
      *) flags+=("$a") ;;
    esac
  done < <(jq -r '.launch.argv[1:][]?' <<<"$window")

  local -a cmd=("$exe" "${flags[@]}")
  [[ -n "$cwd" && -d "$cwd" ]] && cmd+=("--working-directory=$cwd")
  cmd+=(-e herdr)
  while IFS= read -r a; do [[ -n "$a" ]] && cmd+=("$a"); done < <(jq -r '.app.herdrArgs[]?' <<<"$window")
  printf '%q ' "${cmd[@]}" | sed 's/ $//'
}
