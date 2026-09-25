#!/usr/bin/env bash
# Runs a battery of animation scenarios against ONE running AeroSpace server. For every scenario and repetition it
# traces the WindowServer (trace: frame times, dropped frames, 2D gaps, monitor flips) and snapshots the settled final
# layout (geom). If the server was started with AEROSPACE_ANIMATION_STATS=<file>, the part of that log written during
# each scenario (display link ticks, AX write durations) is saved next to it. report.swift turns the result into tables.
#
# Usage: benchmark.sh <aerospace-cli> <out-dir> [repetitions] [stats-log]
#
# Needs 3 windows on the focused workspace (the first 3 in tree order are used; move any others away). Windows of the
# other visible workspaces are traced too, so gaps on the other monitor count. It moves windows around: DON'T touch
# the mouse or keyboard while it runs (~2-3 min with 3 repetitions).
set -uo pipefail
cli="$1"
out="$2"
reps="${3:-3}"
stats_log="${4:-}"
dir="$(cd "$(dirname "$0")" && pwd)"
bin="$dir/.bin"
mkdir -p "$out"
[ -x "$bin/trace" ] && [ -x "$bin/geom" ] || { echo "Build the tools first: $dir/build.sh"; exit 1; }

mapfile -t ws_ids < <("$cli" list-windows --workspace focused --format '%{window-id}' | tr -d ' ')
if [ "${#ws_ids[@]}" -ne 3 ]; then
    echo "Need exactly 3 windows on the focused workspace (have ${#ws_ids[@]}). Move the others to another workspace."
    exit 1
fi
mapfile -t all_ids < <("$cli" list-windows --workspace visible --format '%{window-id}' | tr -d ' ')
trace_ids=$(IFS=,; echo "${all_ids[*]}")
ws_csv=$(IFS=,; echo "${ws_ids[*]}")
"$cli" list-windows --workspace visible --format '%{window-id} | %{app-name} | %{workspace} | %{monitor-name}' > "$out/windows.txt"

geom_all() { "$bin/geom" "$trace_ids"; }
# Waits until no traced window moved for 3 samples in a row (50ms apart), at most ~3s
wait_settled() {
    local previous="" same=0 current
    for _ in $(seq 1 60); do
        current=$(geom_all)
        if [ "$current" = "$previous" ]; then same=$((same + 1)); [ "$same" -ge 3 ] && return 0; else same=0; fi
        previous="$current"
        sleep 0.05
    done
    echo "  (warning: windows didn't settle)"
}
x_of() { "$bin/geom" "$1" | awk '{print $2}'; }

# The same starting point for every scenario: the 3 windows tiled left to right in their original order (A, B, C),
# flat horizontal tree, balanced sizes, nothing fullscreen or floating, A focused
reset() {
    for id in "${ws_ids[@]}"; do
        "$cli" fullscreen off --window-id "$id" >/dev/null 2>&1
        "$cli" layout tiling --window-id "$id" >/dev/null 2>&1
    done
    "$cli" flatten-workspace-tree >/dev/null 2>&1
    "$cli" focus --window-id "${ws_ids[0]}" >/dev/null 2>&1
    "$cli" layout tiles horizontal >/dev/null 2>&1
    wait_settled
    # Restore the left-to-right order (scenarios swap and move windows)
    for _ in 1 2 3; do
        local sorted=1
        for i in 0 1; do
            local a="${ws_ids[$i]}" b="${ws_ids[$((i + 1))]}"
            if [ "$(x_of "$a")" -gt "$(x_of "$b")" ]; then
                "$cli" swap --window-id "$a" right >/dev/null 2>&1 || "$cli" swap --window-id "$b" left >/dev/null 2>&1
                wait_settled
                sorted=0
            fi
        done
        [ "$sorted" -eq 1 ] && break
    done
    "$cli" balance-sizes >/dev/null 2>&1
    "$cli" focus --window-id "${ws_ids[0]}" >/dev/null 2>&1
    wait_settled
}

log_size() { [ -n "$stats_log" ] && [ -f "$stats_log" ] && stat -f%z "$stats_log" || echo 0; }

# run <name> <trace seconds> <setup function> <action function>
run() {
    local name="$1" secs="$2" setup="$3" action="$4"
    for rep in $(seq 1 "$reps"); do
        reset
        "$setup"
        wait_settled
        local before; before=$(log_size)
        "$bin/trace" "$trace_ids" "$secs" > "$out/$name-$rep.trace" 2>/dev/null &
        local tracepid=$!
        sleep 0.1
        "$action"
        wait "$tracepid"
        wait_settled
        geom_all > "$out/$name-$rep.geom"
        if [ -n "$stats_log" ] && [ -f "$stats_log" ]; then tail -c +$((before + 1)) "$stats_log" >> "$out/$name.ax"; fi
        echo "  $name #$rep: $(grep '^STATS' "$out/$name-$rep.trace" | cut -c7-)"
    done
}

A="${ws_ids[0]}"
B="${ws_ids[1]}"
C="${ws_ids[2]}"
c() { "$cli" "$@" >/dev/null 2>&1; }
none() { :; }
# The user's alt-shift-space binding, sent as a key event: a binding runs its commands in one batch
# ('layout floating && center-floating --width 70% --height 80%', and back to tiling)
key_toggle_floating() { osascript -e 'tell application "System Events" to key code 49 using {option down, shift down}'; }

a_move_right() { c move --window-id "$A" right; }
a_move_left() { c move --window-id "$C" left; }
a_move_up() { c move --window-id "$B" up; }
a_move_down() { c move --window-id "$B" down; }
a_swap_right() { c swap --window-id "$A" right; }
a_orientation() { c layout tiles vertical; }
a_resize_plus() { c resize --window-id "$B" width +150; }
a_resize_minus() { c resize --window-id "$B" width -150; }
s_unbalance() { c resize --window-id "$A" width +300; }
a_balance() { c balance-sizes; }
a_fullscreen_on() { c fullscreen on --window-id "$B"; }
s_fullscreen() { c fullscreen on --window-id "$B"; }
a_fullscreen_off() { c fullscreen off --window-id "$B"; }
a_float() { c layout floating --window-id "$B"; }
s_float() { c layout floating --window-id "$B"; }
a_tile() { c layout tiling --window-id "$B"; }
s_focus_b() { c focus --window-id "$B"; }
s_float_focus_b() { c layout floating --window-id "$B"; c focus --window-id "$B"; }
a_rapid_resize() { for _ in 1 2 3 4 5; do c resize --window-id "$B" width +80; done; }
a_interrupt() {
    c move --window-id "$A" right
    sleep 0.05 # a new command 50ms into the running animation
    c move --window-id "$A" left
}

echo "Windows (A B C = $ws_csv), traced: $trace_ids, $reps repetitions"
run move-right 0.8 none a_move_right
run move-left 0.8 none a_move_left
run move-up 0.8 none a_move_up
run move-down 0.8 none a_move_down
run swap-right 0.8 none a_swap_right
run orientation 0.8 none a_orientation
run resize-plus 0.8 none a_resize_plus
run resize-minus 0.8 none a_resize_minus
run balance 0.8 s_unbalance a_balance
run fullscreen-on 0.8 none a_fullscreen_on
run fullscreen-off 0.8 s_fullscreen a_fullscreen_off
run float 0.8 none a_float
run tile 0.8 s_float a_tile
run float-binding 0.8 s_focus_b key_toggle_floating
run tile-binding 0.8 s_float_focus_b key_toggle_floating
run rapid-resize 1.2 none a_rapid_resize
run interrupt 1.0 none a_interrupt
reset
echo "Done: $out"
