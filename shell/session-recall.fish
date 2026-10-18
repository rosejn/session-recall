# Session Recall (Omarchy plugin) -- restores ghostty tabs.
#
# Installed into ~/.config/fish/conf.d by `recall restore`. Inert unless a
# restore is in progress: ghostty can only open a tab bare, so while the
# restore is creating tabs it leaves one spec per tab in a queue, and the
# first prompt of each fresh tab claims the next one: cd there, run its
# program, then fall to a normal prompt.
#
# Spec format: line 1 is the directory, the remaining lines are the argv of
# the program to run (none means just a shell).

status is-interactive; or return
test "$TERM_PROGRAM" = ghostty; or return

set -l state_home $XDG_STATE_HOME
test -n "$state_home"; or set state_home $HOME/.local/state
set -g __recall_tab_queue $state_home/omarchy-recall/tab-queue
test -d $__recall_tab_queue/pending; or return

function __recall_restore_tab --on-event fish_prompt
    functions -e __recall_restore_tab

    # Only a surface ghostty itself spawned is a tab the restore is waiting
    # on; a nested fish or one started by a program must never claim a spec.
    set -l ppid (string split ' ' (string replace -r '.*\) ' '' < /proc/$fish_pid/stat))[2]
    test "$(cat /proc/$ppid/comm 2>/dev/null)" = ghostty; or return

    for spec in $__recall_tab_queue/pending/*.tab
        set -l name (path basename $spec)
        set -l claimed $__recall_tab_queue/claimed/$name
        # mv is atomic on one filesystem, so two tabs racing for the same spec
        # leaves exactly one of them holding it.
        mv $spec $claimed 2>/dev/null; or continue

        set -l lines (cat $claimed)
        set -l dir $lines[1]
        set -l cmd $lines[2..]
        test -d "$dir"; and cd $dir
        if test (count $cmd) -gt 0
            if command -q $cmd[1]
                # Put it on the command line and run it as if typed: a real
                # job with job control and a history entry, not a child of
                # this event handler.
                commandline -r -- (string join ' ' -- (string escape -- $cmd))
                commandline -f execute
            else
                echo "session-recall: $cmd[1] is not installed; leaving a shell" >&2
            end
        end
        return
    end
end
