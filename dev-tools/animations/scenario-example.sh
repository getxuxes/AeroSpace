#!/usr/bin/env bash
# Example: traces the actions of a real session and summarizes the gaps. Adapt the variables to your windows.
# Run it against two servers (e.g. this branch and main, both built the same way) and compare the summaries.
#
# Usage: scenario-example.sh <aerospace CLI of the running server> <label>
set -uo pipefail
cli="$1"
label="$2"
dir="$(cd "$(dirname "$0")" && pwd)"
out="$dir/.bin/out"
mkdir -p "$out"

# Three tiles side by side on the focused workspace of a monitor, left to right (aerospace list-windows --workspace …)
left=12135
middle=12203
right=12055
# All the tiles of the other monitor: windows move there, and untraced tiles would show up as gaps
other_monitor="11289,12304"
windows="$left,$middle,$right,$other_monitor"

# A key binding, sent as a real key event: the commands of a binding run in one batch, unlike separate CLI calls.
# Here alt-shift-space = 'layout floating && center-floating --width 70% --height 80%' (and back to tiling)
toggle_floating() { osascript -e 'tell application "System Events" to key code 49 using {option down, shift down}'; }

trace() { # name, command...
    local name="$1"
    shift
    "$dir/.bin/trace" "$windows" 0.9 > "$out/$label-$name.txt" &
    sleep 0.1
    "$@"
    wait
    echo "$label $name: $("$dir/summarize.sh" "$out/$label-$name.txt")"
    sleep 0.4
}

"$cli" focus --window-id "$left"
sleep 0.3
trace to-floating toggle_floating
"$cli" focus --window-id "$left"
sleep 0.3
trace to-tiling toggle_floating
trace to-left-monitor "$cli" move --window-id "$left" --boundaries all-monitors-outer-frame left
trace to-right-monitor "$cli" move --window-id "$left" --boundaries all-monitors-outer-frame right
