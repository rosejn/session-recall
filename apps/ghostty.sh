#!/usr/bin/env bash
# recall:classes=com.mitchellh.ghostty,ghostty
# recall:description=Ghostty terminal: every tab, its directory, and what was running in it
# recall:priority=5
# recall:serialize=true

# Ghostty's /proc argv is only how the *window* was opened -- typically
# `ghostty --gtk-single-instance=true --working-directory=~` -- and says
# nothing about the tabs inside it or what their shells went on to run. A
# verbatim relaunch gives back one empty prompt; if that window hosted herdr
# there is then no herdr server either, and the agent pass times out.
#
# So at capture time walk the process tree: with gtk-single-instance every
# surface's shell is a direct child of the one ghostty pid, and the tty's
# foreground process group says what is running in it. At restore time the
# window is launched into the first tab's directory and the remaining tabs are
# opened one at a time over D-Bus. Ghostty can only open a tab *bare*, so each
# tab's directory and program are queued as a spec that the shell hook in
# shell/session-recall.fish claims at its first prompt.
#
# What gets relaunched inside a tab is deliberately narrow: herdr, an agent
# whose session was verified, and the interactive tools below. Anything else
# comes back as a shell in the right directory, and the log says what it was.

TAB_PROGRAMS="nvim vim vi hx helix nano micro emacs lazygit lazydocker yazi ranger lf nnn htop btop top k9s ssh mosh tmux"
# The shell hook reads the queue from the default state dir, so this path is
# the one place RECALL_STATE_DIR is deliberately not honoured.
TAB_QUEUE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-recall/tab-queue"
GHOSTTY_BUS="com.mitchellh.ghostty"

# ---------------------------------------------------------------- /proc reads

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

_is_shell() {
  case "$(basename "$1")" in fish|bash|zsh|sh|dash|nu|elvish|xonsh) return 0 ;; *) return 1 ;; esac
}

# Foreground process group of the pid's controlling tty (tpgid in /proc/stat).
_tpgid() {
  local stat rest
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  rest="${stat##*) }"
  set -- $rest
  printf '%s' "$6"
}

# One surface of the window: the direct child ghostty spawned for it. Prints
# a JSON record of where it was and what was running.
_surface() {
  local root="$1" root_argv shell_pid="" prog_pid="" prog_argv="null" cwd="" fg d h herdr_pid=""
  local -a hargs=()
  root_argv="$(proc_argv_json "$root" 2>/dev/null)" || return 1
  cwd="$(proc_cwd "$root" 2>/dev/null || true)"
  if _is_shell "$(jq -r '.[0] // ""' <<<"$root_argv")"; then
    shell_pid="$root"
    fg="$(_tpgid "$root" 2>/dev/null || true)"
    # The shell is its own group leader; a different foreground group is a
    # job it is running, whose leader is the command as typed.
    if [[ "$fg" =~ ^[0-9]+$ && "$fg" != "$root" && -d "/proc/$fg" ]]; then
      prog_pid="$fg"; prog_argv="$(proc_argv_json "$fg" 2>/dev/null || echo null)"
    fi
  else
    # Opened with `-e`: the program is the surface, no shell underneath.
    prog_pid="$root"; prog_argv="$root_argv"
  fi

  # herdr is special: its server is the thing every agent pane hangs off, so
  # it is recorded by name, and whatever runs under it belongs to the herdr
  # backend rather than to this tab.
  for d in "$prog_pid" $(_descendants "$root"); do
    [[ -n "$d" && "$(cat "/proc/$d/comm" 2>/dev/null)" == "herdr" ]] || continue
    if _herdr_client_args "$d" >/dev/null 2>&1; then herdr_pid="$d"; break; fi
  done
  if [[ -n "$herdr_pid" ]]; then
    mapfile -t hargs < <(_herdr_client_args "$herdr_pid")
    jq -nc --arg cwd "$cwd" --argjson sp "${shell_pid:-0}" \
      --argjson args "$(printf '%s\n' "${hargs[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
      { cwd: $cwd, shellPid: $sp, herdr: true, herdrArgs: $args, program: null, agentKind: "" }'
    return 0
  fi

  jq -nc --arg cwd "$cwd" --argjson sp "${shell_pid:-0}" --argjson pp "${prog_pid:-0}" \
    --argjson prog "$prog_argv" '
    { cwd: $cwd, shellPid: $sp, programPid: $pp, herdr: false, herdrArgs: [],
      program: (if ($prog | type) == "array" and ($prog | length) > 0 then $prog else null end),
      agentKind: "" }'
}

# ------------------------------------------------------------------- capture

app_capture() {
  local window="$1" pid="$2" title hostname_ addr c s tabs='[]' note=""
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != "0" ]] || return 1
  title="$(jq -r '.title // ""' <<<"$window")"
  addr="$(jq -r '.address // ""' <<<"$window")"
  hostname_="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"

  local surfaces='[]'
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    s="$(_surface "$c" 2>/dev/null)" || continue
    surfaces="$(jq -c --argjson s "$s" '. + [$s]' <<<"$surfaces")"
  done < <(proc_children "$pid")
  [[ "$(jq 'length' <<<"$surfaces")" != "0" ]] || return 1

  # With gtk-single-instance every ghostty window shares this pid, so /proc
  # cannot say which surface sits in which window. One window is the common
  # case and then the answer is all of them. With several, the herdr client
  # goes to the window herdr titles "{hostname}: {workspace}", and the rest go
  # to the first other window; the remaining windows come back with one tab.
  local wins rank n herdr_rank
  wins="$(hyprctl -j clients 2>/dev/null \
    | jq -c --argjson p "$pid" '[ .[] | select(.pid == $p) | { address, title } ]' 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$wins")"
  rank="$(jq -r --arg a "$addr" 'map(.address) | index($a) // 0' <<<"$wins")"
  if ((n <= 1)); then
    tabs="$surfaces"
  else
    herdr_rank="$(jq -r --arg h "$hostname_: " '[ to_entries[] | select(.value.title | startswith($h)) | .key ] | .[0] // -1' <<<"$wins")"
    ((herdr_rank < 0)) && herdr_rank=0
    local other_rank=0; ((other_rank == herdr_rank)) && other_rank=1
    if ((rank == herdr_rank)); then
      tabs="$(jq -c '[ .[] | select(.herdr) ]' <<<"$surfaces")"
    elif ((rank == other_rank)); then
      tabs="$(jq -c '[ .[] | select(.herdr | not) ]' <<<"$surfaces")"
    else
      tabs='[]'
    fi
    note="$n ghostty windows share pid $pid; tabs were attributed by title, which is a guess"
  fi

  # Agents living directly in a tab (not under herdr). The window title is the
  # focused tab's title, which may be another tab's, so it only helps identify
  # a session when no other tab could claim it: same agent, same directory.
  local i tab kind cwd shell_pid others
  n="$(jq 'length' <<<"$tabs")"
  for ((i = 0; i < n; i++)); do
    tab="$(jq -c --argjson i "$i" '.[$i]' <<<"$tabs")"
    [[ "$(jq -r '.herdr' <<<"$tab")" == "false" ]] || continue
    shell_pid="$(jq -r '.shellPid' <<<"$tab")"; [[ "$shell_pid" == "0" ]] && shell_pid="$(jq -r '.programPid' <<<"$tab")"
    [[ "$shell_pid" =~ ^[0-9]+$ && "$shell_pid" != "0" ]] || continue
    cwd="$(jq -r '.cwd' <<<"$tab")"
    discover_agent "$shell_pid" 2>/dev/null || continue
    kind="$AGENT_KIND"
    others="$(jq -r --argjson i "$i" --arg cwd "$cwd" '[ to_entries[] | select(.key != $i and .value.cwd == $cwd) ] | length' <<<"$tabs")"
    local hint="$title"; ((others > 0)) && hint=""
    identify_agent "$shell_pid" "$cwd" "$hint" || continue
    tabs="$(jq -c --argjson i "$i" --arg k "$AGENT_KIND" --arg id "$AGENT_SESSION_ID" \
      --arg m "$AGENT_METHOD" --arg f "$AGENT_SESSION_FILE" '
      .[$i] += { agentKind: $k, agentSessionId: $id, agentMethod: $m, agentSessionFile: $f }' <<<"$tabs")"
  done

  # The flat herdr fields stay for the no-hook fallback and for `recall status`.
  jq -nc --argjson tabs "$tabs" --arg note "$note" '
    ($tabs | map(select(.herdr)) | .[0]) as $h
    | { app: ({ tabs: ($tabs | map(del(.shellPid, .programPid))),
                herdr: ($h != null),
                herdrArgs: ($h.herdrArgs // []),
                cwd: ($h.cwd // $tabs[0].cwd // "") }
              + (if $note != "" then { note: $note } else {} end)) }'
}

# ------------------------------------------------------------------- restore

# Which shell will run in a fresh tab, so we know whether our hook is there.
# Ghostty's `command` defaults to $SHELL, so ask with $SHELL set to the login
# shell as it would be when the desktop launches ghostty, not to whatever
# shell happens to be running this restore.
_tab_shell() {
  local login cmd
  login="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
  [[ -n "$login" ]] || login="${SHELL:-/bin/sh}"
  cmd="$(SHELL="$login" ghostty +show-config 2>/dev/null | sed -n 's/^command = //p' | head -1)"
  [[ -n "$cmd" ]] || cmd="$login"
  basename "${cmd%% *}"
}

# True when a fresh tab will run the hook. fish has conf.d, where a dropped-in
# file is the supported way to add startup code, so for fish the hook is ours
# to install (see _hook_install); bash and zsh have no such directory, so
# those need one line in their rc file and we only check for it.
_hook_ready() {
  case "$(_tab_shell)" in
    fish) [[ -f "$RECALL_ROOT/shell/session-recall.fish" ]] ;;
    bash) grep -qs 'session-recall.bash' "$HOME/.bashrc" ;;
    zsh)  grep -qs 'session-recall.bash' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    *) return 1 ;;
  esac
}

_hook_install() {
  local src="$RECALL_ROOT/shell/session-recall.fish"
  local dst="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/session-recall.fish"
  [[ "$(_tab_shell)" == "fish" ]] || return 0
  cmp -s "$src" "$dst" && return 0
  mkdir -p "$(dirname "$dst")" && cp -f "$src" "$dst" && chmod 644 "$dst"
}

# The saved tabs, as a JSON array. A snapshot from before tabs were recorded
# only has the flat herdr fields; treat those as one tab so it still comes
# back with herdr in it.
_tabs_json() {
  jq -c '
    .app.tabs // (if (.app.herdr // false) == true
                  then [{ cwd: (.app.cwd // ""), herdr: true, herdrArgs: (.app.herdrArgs // []), program: null, agentKind: "" }]
                  else [] end)' <<<"$1"
}

# What each tab will run, one line per tab: "<cwd>\t<argv...>" with argv
# NUL-free and one field per token; an empty argv means just a shell.
# Prints a note on stderr for every tab that will not get its program back.
_tab_commands() {
  local window="$1" trust="${2:-0}" i n tab tabs cwd kind sid method sfile resume prog base
  local -a argv
  tabs="$(_tabs_json "$window")"
  n="$(jq -r 'length' <<<"$tabs")"
  for ((i = 0; i < n; i++)); do
    tab="$(jq -c --argjson i "$i" '.[$i]' <<<"$tabs")"
    cwd="$(jq -r '.cwd // ""' <<<"$tab")"
    [[ -d "$cwd" ]] || cwd="$HOME"
    argv=()
    if [[ "$(jq -r '.herdr' <<<"$tab")" == "true" ]]; then
      if command -v herdr >/dev/null 2>&1; then
        argv=(herdr); while IFS= read -r a; do [[ -n "$a" ]] && argv+=("$a"); done < <(jq -r '.herdrArgs[]?' <<<"$tab")
      else
        printf 'tab %d: herdr is not installed; leaving a shell\n' $((i + 1)) >&2
      fi
    elif kind="$(jq -r '.agentKind // ""' <<<"$tab")" && [[ -n "$kind" ]]; then
      sid="$(jq -r '.agentSessionId // ""' <<<"$tab")"
      method="$(jq -r '.agentMethod // ""' <<<"$tab")"
      sfile="$(jq -r '.agentSessionFile // ""' <<<"$tab")"
      resume=""
      if [[ "$method" != "continue" && -z "$sid" ]]; then
        printf 'tab %d: %s was running but no session id was verified; leaving a shell\n' $((i + 1)) "$kind" >&2
      elif [[ "$method" != "continue" ]] && ! agent_session_alive "$kind" "$sid" "$sfile"; then
        printf 'tab %d: %s session %s no longer exists on disk; leaving a shell\n' $((i + 1)) "$kind" "$sid" >&2
      else
        if agent_path="$(agent_handler_for "$kind" 2>/dev/null)" && [[ -n "$agent_path" ]]; then
          ((trust)) && { agent_hook_trust "$agent_path" "$cwd" >/dev/null 2>&1 || true; }
          resume="$(agent_hook_resume_command "$agent_path" "$cwd" "$sid" "$method" 2>/dev/null || true)"
        fi
        [[ -n "$resume" ]] || resume="$(agent_resume_command "$kind" "$sid" "$method" 2>/dev/null || true)"
        [[ -n "$resume" ]] || printf 'tab %d: cannot rebuild a %s resume; leaving a shell\n' $((i + 1)) "$kind" >&2
      fi
      # The resume is a %q-quoted command line; split it back into words.
      [[ -n "$resume" ]] && eval "argv=($resume)"
    elif prog="$(jq -c '.program // empty' <<<"$tab")" && [[ -n "$prog" ]]; then
      base="$(basename "$(jq -r '.[0]' <<<"$prog")")"
      if [[ " $TAB_PROGRAMS " == *" $base "* ]]; then
        while IFS= read -r a; do argv+=("$a"); done < <(jq -r '.[]' <<<"$prog")
      else
        printf 'tab %d: was running %s; not something restore relaunches, leaving a shell\n' $((i + 1)) "$(jq -r 'join(" ")' <<<"$prog" | cut -c1-60)" >&2
      fi
    fi
    printf '%s' "$cwd"
    for a in ${argv[@]+"${argv[@]}"}; do printf '\t%s' "${a//$'\n'/ }"; done
    printf '\n'
  done
}

app_plan() {
  local window="$1" cwd rest n notes
  n="$(_tabs_json "$window" | jq -r 'length')"
  ((n > 0)) || return 0
  if ! _hook_ready; then
    printf 'tabs: %d saved, but %s has no session-recall hook, so only the first comes back, with herdr if it was there (see README)\n' "$n" "$(_tab_shell)"
    return 0
  fi
  notes="$(mktemp)"
  printf 'with %d tab(s):\n' "$n"
  while IFS=$'\t' read -r cwd rest; do
    printf '  %s%s\n' "${cwd/#$HOME/\~}" "${rest:+  ->  ${rest//$'\t'/ }}"
  done < <(_tab_commands "$window" 2>"$notes")
  sed 's/^/  note: /' "$notes"; rm -f "$notes"
}

# Queue every tab's spec before the window exists: the first tab's shell will
# claim the first spec on its own as soon as it starts.
app_prepare() {
  local window="$1" i=0 line
  _hook_ready && _hook_install || return 0
  rm -rf -- "$TAB_QUEUE"
  mkdir -p "$TAB_QUEUE/pending" "$TAB_QUEUE/claimed"
  while IFS= read -r line; do
    i=$((i + 1))
    printf '%s\n' "${line//$'\t'/$'\n'}" > "$TAB_QUEUE/pending/$(printf '%03d' "$i").tab"
  done < <(_tab_commands "$window" 1 2>/dev/null)
}

# Is a ghostty instance already on the session bus?
_ghostty_running() {
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$GHOSTTY_BUS" 2>/dev/null | grep -q true
}

app_command() {
  local window="$1" cwd exe a
  exe="$(command -v ghostty 2>/dev/null)" || return 1
  [[ "$(jq -r '(.app.tabs // []) | length' <<<"$window")" != "0" || "$(jq -r '.app.herdr // false' <<<"$window")" == "true" ]] || return 1
  cwd="$(_tabs_json "$window" | jq -r '.[0].cwd // ""')"
  [[ -d "$cwd" ]] || cwd="$(jq -r '.launch.cwd // ""' <<<"$window")"

  local -a cmd
  if _ghostty_running; then
    # A plain `ghostty --working-directory=X` handed to a running single
    # instance loses X: the primary just inherits its own cwd. `+new-window`
    # is the IPC that carries it (and -e) across.
    cmd=("$exe" +new-window)
  else
    # Keep the flags the window was opened with (single-instance and the
    # like), but the working directory and the command are ours to set.
    local -a flags=()
    while IFS= read -r a; do
      [[ -n "$a" ]] || continue
      case "$a" in
        --working-directory=*|-e) break ;;
        *) flags+=("$a") ;;
      esac
    done < <(jq -r '.launch.argv[1:][]?' <<<"$window")
    # Tabs 2..n are opened over D-Bus, which only a single-instance ghostty
    # answers. With several windows sharing one pid the saved argv is null, so
    # the flag the desktop entry launched it with is lost; put it back.
    [[ " ${flags[*]} " == *" --gtk-single-instance="* ]] || flags+=(--gtk-single-instance=true)
    cmd=("$exe" "${flags[@]}")
  fi
  [[ -n "$cwd" && -d "$cwd" ]] && cmd+=("--working-directory=$cwd")
  # Without the shell hook nothing can run inside a tab after the fact, so
  # fall back to putting herdr straight into the window with -e: the server
  # still has to come up for the agent pass, whatever else is lost.
  if ! _hook_ready && [[ "$(jq -r '.app.herdr // false' <<<"$window")" == "true" ]] && command -v herdr >/dev/null 2>&1; then
    cmd+=(-e herdr)
    while IFS= read -r a; do [[ -n "$a" ]] && cmd+=("$a"); done < <(jq -r '.app.herdrArgs[]?' <<<"$window")
  fi
  printf '%q ' "${cmd[@]}" | sed 's/ $//'
}

# The newest ghostty window on the session bus. Launches are serialised, so
# right after ours appears it is the highest-numbered one.
_bus_window() {
  gdbus introspect --session --dest "$GHOSTTY_BUS" --object-path /com/mitchellh/ghostty/window 2>/dev/null \
    | sed -n 's|^ *node \([0-9][0-9]*\) {.*|\1|p' | sort -n | tail -1
}

_wait_claimed() {
  local spec="$1" deadline=$((SECONDS + ${2:-15}))
  while ((SECONDS < deadline)); do
    [[ -f "$TAB_QUEUE/claimed/$spec" ]] && return 0
    sleep 0.25
  done
  return 1
}

app_post_launch() {
  local window="$1" addr="$2" n i spec win
  n="$(_tabs_json "$window" | jq -r 'length')"
  ((n > 0)) || return 0
  if ! _hook_ready; then
    ((n > 1)) && printf 'tabs    %d saved; %s has no session-recall hook, so only the first came back\n' "$n" "$(_tab_shell)"
    return 0
  fi
  [[ -d "$TAB_QUEUE" ]] || return 0
  trap 'rm -rf -- "$TAB_QUEUE"' EXIT

  # The first tab is the window itself. Its shell must take its spec before
  # the queue can go away, and before the next tab so specs are handed out in
  # order.
  if ! _wait_claimed 001.tab; then
    printf 'tabs    the first tab never ran the shell hook; nothing restored inside this window\n'
    return 0
  fi
  if ((n > 1)); then
    if ! command -v gdbus >/dev/null 2>&1; then
      printf 'tabs    gdbus is missing (glib2); cannot open the other %d tab(s)\n' $((n - 1))
      return 0
    fi
    # A cold-started instance can take a moment to claim its bus name.
    local deadline=$((SECONDS + 10))
    while win="$(_bus_window)"; [[ -z "$win" ]] && ((SECONDS < deadline)); do sleep 0.25; done
    if [[ -z "$win" ]]; then
      printf 'tabs    ghostty is not on the session bus (gtk-single-instance off?); cannot open the other %d tab(s)\n' $((n - 1))
      return 0
    fi
    for ((i = 2; i <= n; i++)); do
      spec="$(printf '%03d' "$i").tab"
      gdbus call --session --dest "$GHOSTTY_BUS" \
        --object-path "/com/mitchellh/ghostty/window/$win" \
        --method org.gtk.Actions.Activate new-tab '[]' '{}' >/dev/null 2>&1 \
        || { printf 'tabs    could not open tab %d over D-Bus; stopping at %d\n' "$i" $((i - 1)); return 0; }
      if ! _wait_claimed "$spec"; then
        printf 'tabs    tab %d opened but never ran the shell hook; stopping at %d\n' "$i" "$i"
        return 0
      fi
    done
  fi
  printf 'tabs    %d restored\n' "$n"
  _tab_commands "$window" 2>&1 >/dev/null | sed 's/^/tabs    /'
}
