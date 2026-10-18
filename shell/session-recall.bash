# Session Recall (Omarchy plugin) -- restores ghostty tabs.
#
# Source this from ~/.bashrc or ~/.zshrc:
#   [ -f ~/.config/omarchy/plugins/session-recall/shell/session-recall.bash ] \
#     && . ~/.config/omarchy/plugins/session-recall/shell/session-recall.bash
#
# Inert unless a restore is in progress; see session-recall.fish for the idea.

__recall_restore_tab() {
  local q="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-recall/tab-queue" spec name dir ppid
  local -a lines cmd
  case $- in *i*) ;; *) return 0 ;; esac
  [[ "${TERM_PROGRAM:-}" == "ghostty" && -d "$q/pending" ]] || return 0
  ppid="$(awk '{print $4}' "/proc/$$/stat" 2>/dev/null)"
  [[ "$(cat "/proc/$ppid/comm" 2>/dev/null)" == "ghostty" ]] || return 0
  for spec in "$q"/pending/*.tab; do
    [[ -f "$spec" ]] || continue
    name="${spec##*/}"
    mv "$spec" "$q/claimed/$name" 2>/dev/null || continue
    lines=(); while IFS= read -r l; do lines+=("$l"); done < "$q/claimed/$name"
    # Offset slices are 0-based in both bash and zsh; plain indexing is not.
    dir="${lines[@]:0:1}"; cmd=("${lines[@]:1}")
    [[ -d "$dir" ]] && cd "$dir"
    if ((${#cmd[@]})); then
      if command -v "${cmd[0]}" >/dev/null 2>&1; then
        printf '\e[2msession-recall: %s\e[0m\n' "${cmd[*]}"
        command "${cmd[@]}"
      else
        printf 'session-recall: %s is not installed; leaving a shell\n' "${cmd[0]}" >&2
      fi
    fi
    return 0
  done
}
__recall_restore_tab
unset -f __recall_restore_tab
