# Turn a set of saved window rectangles back into the sequence of dwindle
# operations that reproduces them.
#
# Hyprland does not let you set a tiled window's geometry directly: position
# and size fall out of the split tree, and the tree is built by insertion
# order. Two windows side by side and two windows stacked are the same two
# resize calls but different trees, so ratios alone can never fix a layout that
# was built in a different order.
#
# So: recover the tree from the rectangles by finding the straight line that
# cuts the set in two, recurse on each side, and emit the insertions that
# rebuild it. Each insertion says "focus this window, preselect this direction,
# then drop that window in".

# Topmost-then-leftmost rect. This is the window that keeps the region when it
# is split, matching how dwindle leaves the focused window in the first half.
def firstleaf: sort_by(.y, .x) | .[0];

# A vertical cut at $X is real only if every rect lies wholly on one side of it.
# A rect straddling the line means the set is not a clean binary split there.
def vsplit:
  . as $r
  | ([ $r[] | .x + .w ] | unique) as $xs
  | first(
      $xs[] as $X
      | ([ $r[] | select(.x + .w <= $X) ]) as $L
      | ([ $r[] | select(.x >= $X) ]) as $R
      | select(($L | length) > 0 and ($R | length) > 0
               and (($L | length) + ($R | length)) == ($r | length))
      | { dir: "r", L: $L, R: $R }
    ) // null;

def hsplit:
  . as $r
  | ([ $r[] | .y + .h ] | unique) as $ys
  | first(
      $ys[] as $Y
      | ([ $r[] | select(.y + .h <= $Y) ]) as $L
      | ([ $r[] | select(.y >= $Y) ]) as $R
      | select(($L | length) > 0 and ($R | length) > 0
               and (($L | length) + ($R | length)) == ($r | length))
      | { dir: "d", L: $L, R: $R }
    ) // null;

# Pre-order: the split that creates the two regions, then the splits inside
# each. Every `focus` target is already tiled by the time its entry runs,
# because it was either the root window or inserted by an earlier entry.
def plan:
  . as $rects
  | if ($rects | length) <= 1 then []
    else
      (($rects | vsplit) // ($rects | hsplit)) as $s
      | if $s == null
        then []          # not a clean binary partition; caller falls back to resizing
        else
          [ { focus: ($s.L | firstleaf | .id),
              dir: $s.dir,
              insert: ($s.R | firstleaf | .id) } ]
          + ($s.L | plan)
          + ($s.R | plan)
        end
    end;

{ root: (. | firstleaf | .id), steps: plan, complete: ((. | length) <= 1 or ((. | vsplit) // (. | hsplit)) != null) }
