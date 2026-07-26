#!/bin/bash
# omarchy-hook bar-orientation <position>   (position: top | bottom | left | right)
#
# The bar reserves the space it occupies — its thickness plus its floating gap,
# or just its thickness when transparent — via its layer-shell exclusive zone.
# So the window gap on the bar's own edge must be 0 or it double-counts; the
# other three edges keep the standard gap. The shell fires this only when the
# bar changes edges, so it runs rarely.

standard_gap=10

position="${1:-top}"
top=$standard_gap right=$standard_gap bottom=$standard_gap left=$standard_gap
case "$position" in
  top)    top=0 ;;
  bottom) bottom=0 ;;
  left)   left=0 ;;
  right)  right=0 ;;
esac

# Reach the compositor even from a minimal hook environment.
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/" 2>/dev/null | head -1)
fi

# omarchy drives Hyprland with the Lua config parser, so `hyprctl keyword` is
# rejected; set the gap live through the same hl.config() API the config uses.
hyprctl eval "hl.config({ general = { gaps_out = { top = $top, right = $right, bottom = $bottom, left = $left } } })" >/dev/null 2>&1 || true
