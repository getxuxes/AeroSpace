#!/usr/bin/env bash
# Runs animation scenarios against ONE running AeroSpace server. For every scenario and repetition it traces the
# WindowServer (trace all: frame times, dropped frames, 2D gaps, monitor flips) and snapshots the settled final layout
# (geom, by role name). If the server was started with AEROSPACE_ANIMATION_STATS=<file>, the part of that log written
# during each scenario (display link ticks, AX write durations) is saved next to it. report.swift makes the tables.
#
# Usage: [BENCH_ONLY='regex'] benchmark.sh <aerospace-cli> <out-dir> <suites> [repetitions] [stats-log]
#   suites: comma-separated, any of: core layouts apps lifecycle mouse mon
#   BENCH_ONLY: run only the scenarios whose name matches, e.g. 'lifecycle.close|mouse.drag-.*' 
#
# Windows it needs (it finds them by app, and creates the TextEdit documents itself; within an app, roles go by window id,
# so every server gets the same windows in the same roles):
#   G1 G2 Ghostty, Z1 Z2 Zen, T1 T2 TextEdit, D Discord, F Finder (or a 3rd Ghostty window)
# It works on workspaces B1 (the focused monitor), B2 (the other monitor, only F), B3 and B9 (hidden). Windows of other
# workspaces stay where they are. It moves windows and sends key and mouse events: DON'T touch the mouse or keyboard.
set -uo pipefail
cli="$1"
out="$2"
suites=",$3,"
reps="${4:-3}"
stats_log="${5:-}"
dir="$(cd "$(dirname "$0")" && pwd)"
bin="$dir/.bin"
mkdir -p "$out"
for tool in trace geom mouse; do [ -x "$bin/$tool" ] || { echo "Build the tools first: $dir/build.sh"; exit 1; }; done

c() { "$cli" "$@" >/dev/null 2>&1; }
has_suite() { [[ "$suites" == *",$1,"* ]]; }

# ---------------------------------------------------------------- windows (roles)
declare -A role
find_windows() { # app-name, roles...
    local app="$1"; shift
    mapfile -t found < <("$cli" list-windows --all --format '%{window-id}|%{app-name}' | awk -F'|' -v app="$app" 'tolower($2) ~ "^"tolower(app) {print $1}' | tr -d ' ' | sort -n)
    local i=0
    for r in "$@"; do
        [ -n "${found[$i]:-}" ] && role[$r]="${found[$i]}"
        i=$((i + 1))
    done
}
new_textedit_doc() { osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1; }
textedit_pid() { pgrep -x TextEdit | head -1; }

# TextEdit documents: create the missing ones (empty documents close without asking to save)
find_windows TextEdit T1 T2
for r in T1 T2; do
    if [ -z "${role[$r]:-}" ]; then new_textedit_doc; sleep 1.5; find_windows TextEdit T1 T2; fi
done
find_windows Ghostty G1 G2
find_windows Zen Z1 Z2
find_windows Discord D
find_windows Finder F
# Without a Finder window, a third Ghostty window is the static one on the other monitor
[ -n "${role[F]:-}" ] || find_windows Ghostty G1 G2 F
missing=""
for r in G1 G2 Z1 Z2 T1 T2 D F; do [ -n "${role[$r]:-}" ] || missing="$missing $r"; done
if [ -n "$missing" ]; then
    echo "Missing windows:$missing  (need 2 Ghostty, 2 Zen, 1 Discord, and 1 Finder or a 3rd Ghostty window; TextEdit is created)"
    exit 1
fi
for r in G1 G2 Z1 Z2 T1 T2 D F; do echo "$r=${role[$r]}"; done > "$out/roles.txt"
"$cli" list-windows --all --format '%{window-id} | %{app-name} | %{workspace} | %{monitor-name}' > "$out/windows.txt"

# ---------------------------------------------------------------- monitors
M1=$("$cli" list-monitors --focused --format '%{monitor-id}' | tr -d ' ')
M2=$("$cli" list-monitors --format '%{monitor-id}' | tr -d ' ' | grep -vx "$M1" | head -1)
screen_of() { "$cli" list-monitors --format '%{monitor-id} %{monitor-appkit-nsscreen-screens-id}' | awk -v m="$1" '$1==m {print $2-1}'; }
"$bin/geom" --screens > "$out/screens.txt"
dir_to_other=""
if [ -n "$M2" ]; then
    dir_to_other=$(awk -v a="$(screen_of "$M1")" -v b="$(screen_of "$M2")" '
        $1==a {ax=$2+$4/2; ay=$3+$5/2} $1==b {bx=$2+$4/2; by=$3+$5/2}
        END { dx=bx-ax; dy=by-ay; adx=dx<0?-dx:dx; ady=dy<0?-dy:dy
              if (adx>=ady) print (dx>0?"right":"left"); else print (dy>0?"down":"up") }' "$out/screens.txt")
fi
opposite() { case "$1" in left) echo right;; right) echo left;; up) echo down;; down) echo up;; esac; }
echo "monitors: acting=$M1 other=${M2:-none} direction-to-other=${dir_to_other:-none}" | tee "$out/monitors.txt"
if [ -n "$M2" ]; then
    c focus-monitor "$M2"; c workspace B2
    c move-node-to-workspace --window-id "${role[F]}" B2
fi
c focus-monitor "$M1"; c workspace B1

# ---------------------------------------------------------------- helpers
NEW="" # a window created by the scenario (lifecycle)
tracked_csv() { # name=id of every role, and NEW
    local items=()
    for r in G1 G2 Z1 Z2 T1 T2 D F; do items+=("$r=${role[$r]}"); done
    [ -n "$NEW" ] && items+=("NEW=$NEW")
    (IFS=,; echo "${items[*]}")
}
managed_csv() { local r ids=(); for r in G1 G2 Z1 Z2 T1 T2 D F; do ids+=("${role[$r]}"); done; (IFS=,; echo "${ids[*]}"); }
# Waits until no window moved for 3 samples in a row (50ms apart), at most ~4s
wait_settled() {
    local previous="" same=0 current csv
    csv=$(tracked_csv)
    for _ in $(seq 1 80); do
        current=$("$bin/geom" "$csv")
        if [ "$current" = "$previous" ]; then same=$((same + 1)); [ "$same" -ge 3 ] && return 0; else same=0; fi
        previous="$current"
        sleep 0.05
    done
    echo "  (warning: windows didn't settle)"
}
ws_windows() { "$cli" list-windows --workspace "$1" --format '%{window-id}' 2>/dev/null | tr -d ' '; }
contains() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
key() { # key code, modifiers ("option down, shift down")
    osascript -e "tell application \"System Events\" to key code $1 using {$2}" >/dev/null 2>&1
}
keycode() { case "$1" in left) echo 4;; down) echo 38;; up) echo 40;; right) echo 37;; esac; } # h j k l

# B1 on the acting monitor with exactly the given roles, tiled left to right in that order, flat, balanced, focused on
# the first; B2 on the other monitor with only F. The same starting point for every repetition
layout_roles() {
    local want=() r
    for r in "$@"; do want+=("${role[$r]}"); done
    # B1 back on its monitor (after mon-move-ws) and B2 on the other one
    if [ -n "$M2" ]; then
        local b1mon
        b1mon=$("$cli" list-workspaces --all --format '%{workspace} %{monitor-id}' | awk '$1=="B1" {print $2}')
        if [ -n "$b1mon" ] && [ "$b1mon" != "$M1" ]; then
            c move-workspace-to-monitor --workspace B1 "$M1" || c move-workspace-to-monitor --workspace B1 "$(opposite "$dir_to_other")"
        fi
        c focus-monitor "$M2"; c workspace B2
        for id in $(ws_windows B2); do [ "$id" = "${role[F]}" ] || c move-node-to-workspace --window-id "$id" B9; done
        c move-node-to-workspace --window-id "${role[F]}" B2
        c fullscreen off --window-id "${role[F]}"; c layout tiling --window-id "${role[F]}"
    fi
    c focus-monitor "$M1"; c workspace B1
    for id in $(ws_windows B1); do contains "$id" "${want[@]}" || c move-node-to-workspace --window-id "$id" B9; done
    for id in "${want[@]}"; do
        c move-node-to-workspace --window-id "$id" B1
        c fullscreen off --window-id "$id"
        c layout tiling --window-id "$id"
    done
    c flatten-workspace-tree --workspace B1
    c focus --window-id "${want[0]}"
    c layout tiles horizontal
    wait_settled
    # Order: bring each window left until it is at its index
    local i n=${#want[@]}
    for ((i = 0; i < n; i++)); do
        for _ in $(seq 1 "$n"); do
            local order rank
            order=$("$bin/geom" "$(IFS=,; echo "${want[*]}")" | sort -k2 -n | awk '{print $1}')
            rank=$(echo "$order" | grep -nx "${want[$i]}" | cut -d: -f1)
            [ "$((rank - 1))" -le "$i" ] && break
            c swap --window-id "${want[$i]}" left
            wait_settled
        done
    done
    c balance-sizes --workspace B1
    c focus --window-id "${want[0]}"
    wait_settled
}

log_size() { [ -n "$stats_log" ] && [ -f "$stats_log" ] && stat -f%z "$stats_log" || echo 0; }

# run <name> <trace seconds> "<roles>" <setup> <action> [teardown]
run() {
    local name="$1" secs="$2" roles="$3" setup="$4" action="$5" teardown="${6:-none}"
    if [ -n "${BENCH_ONLY:-}" ] && ! [[ "$name" =~ ^($BENCH_ONLY)$ ]]; then return; fi
    # shellcheck disable=SC2086
    for rep in $(seq 1 "$reps"); do
        NEW=""
        layout_roles $roles
        "$setup"
        wait_settled
        local before; before=$(log_size)
        "$bin/trace" all "$secs" h "$(managed_csv)" > "$out/$name-$rep.trace" 2>/dev/null &
        local tracepid=$!
        sleep 0.1
        "$action"
        wait "$tracepid"
        wait_settled
        "$bin/geom" "$(tracked_csv)" > "$out/$name-$rep.geom"
        if [ -n "$stats_log" ] && [ -f "$stats_log" ]; then tail -c +$((before + 1)) "$stats_log" >> "$out/$name.ax"; fi
        "$teardown"
        echo "  $name #$rep: $(grep '^STATS' "$out/$name-$rep.trace" | cut -c7-)"
    done
}
none() { :; }
x() { "$bin/geom" "$1" | awk '{print $2 + 0}'; }
y() { "$bin/geom" "$1" | awk '{print $3 + 0}'; }
w() { "$bin/geom" "$1" | awk '{print $4 + 0}'; }
h() { "$bin/geom" "$1" | awk '{print $5 + 0}'; }

# ---------------------------------------------------------------- prime
# lastFloatingSize comes from the size a window had when the server registered it, i.e. from whatever ran before.
# Give every window the same floating size so floating scenarios start equal on both servers
layout_roles G1 Z1 T1 G2 Z2 T2 D
for r in G1 Z1 T1 G2 Z2 T2 D; do
    c layout floating --window-id "${role[$r]}"
    c center-floating --window-id "${role[$r]}" --width 50% --height 50%
    wait_settled
    c layout tiling --window-id "${role[$r]}"
    wait_settled
done

# ---------------------------------------------------------------- core: 3 tiles G1 Z1 T1 (A B C)
if has_suite core; then
    echo "== core"
    A=${role[G1]}; B=${role[Z1]}; C=${role[T1]}
    a_move_right() { c move --window-id "$A" right; }
    a_move_left() { c move --window-id "$C" left; }
    a_move_up() { c move --window-id "$B" up; }
    a_move_down() { c move --window-id "$B" down; }
    a_swap_right() { c swap --window-id "$A" right; }
    a_orientation() { c layout tiles vertical; }
    a_resize_plus() { c resize --window-id "$B" width +150; }
    a_resize_minus() { c resize --window-id "$B" width -150; }
    s_unbalance() { c resize --window-id "$A" width +300; }
    a_balance() { c balance-sizes --workspace B1; }
    a_fullscreen_on() { c fullscreen on --window-id "$B"; }
    s_fullscreen() { c fullscreen on --window-id "$B"; }
    a_fullscreen_off() { c fullscreen off --window-id "$B"; }
    a_float() { c layout floating --window-id "$B"; }
    s_float() { c layout floating --window-id "$B"; }
    a_tile() { c layout tiling --window-id "$B"; }
    s_focus_b() { c focus --window-id "$B"; }
    s_float_focus_b() { c layout floating --window-id "$B"; c focus --window-id "$B"; }
    # The user's alt-shift-space binding as a key event: a binding runs its commands in one batch
    # ('layout floating && center-floating --width 70% --height 80%', and back to tiling)
    a_key_toggle_floating() { key 49 "option down, shift down"; }
    a_rapid_resize() { for _ in 1 2 3 4 5; do c resize --window-id "$B" width +80; done; }
    a_interrupt() {
        c move --window-id "$A" right
        sleep 0.05 # a new command 50ms into the running animation
        c move --window-id "$A" left
    }
    run core.move-right 0.8 "G1 Z1 T1" none a_move_right
    run core.move-left 0.8 "G1 Z1 T1" none a_move_left
    run core.move-up 0.8 "G1 Z1 T1" none a_move_up
    run core.move-down 0.8 "G1 Z1 T1" none a_move_down
    run core.swap-right 0.8 "G1 Z1 T1" none a_swap_right
    run core.orientation 0.8 "G1 Z1 T1" none a_orientation
    run core.resize-plus 0.8 "G1 Z1 T1" none a_resize_plus
    run core.resize-minus 0.8 "G1 Z1 T1" none a_resize_minus
    run core.balance 0.8 "G1 Z1 T1" s_unbalance a_balance
    run core.fullscreen-on 0.8 "G1 Z1 T1" none a_fullscreen_on
    run core.fullscreen-off 0.8 "G1 Z1 T1" s_fullscreen a_fullscreen_off
    run core.float 0.8 "G1 Z1 T1" none a_float
    run core.tile 0.8 "G1 Z1 T1" s_float a_tile
    run core.float-binding 0.8 "G1 Z1 T1" s_focus_b a_key_toggle_floating
    run core.tile-binding 0.8 "G1 Z1 T1" s_float_focus_b a_key_toggle_floating
    run core.rapid-resize 1.2 "G1 Z1 T1" none a_rapid_resize
    run core.interrupt 1.0 "G1 Z1 T1" none a_interrupt
fi

# ---------------------------------------------------------------- layouts: 1, 2, 3, 4, 6 tiles and nested containers
if has_suite layouts; then
    echo "== layouts"
    s_float_g1() { c layout floating --window-id "${role[G1]}"; }
    a_tile_g1() { c layout tiling --window-id "${role[G1]}"; }
    a_move_first() { c move --window-id "${role[G1]}" right; }
    a_resize_second() { c resize --window-id "${role[Z1]}" width +150; }
    a_vertical() { c layout tiles vertical; }
    run layouts.t1-tile 0.8 "G1" s_float_g1 a_tile_g1
    for n in 2 3 4 6; do
        roles=$(echo "G1 Z1 T1 G2 Z2 T2" | cut -d' ' -f1-"$n")
        run "layouts.t$n-move" 0.8 "$roles" none a_move_first
        run "layouts.t$n-resize" 0.8 "$roles" none a_resize_second
        run "layouts.t$n-orientation" 0.8 "$roles" none a_vertical
    done
    # h[G1, v[Z1, T1], G2]
    s_nest() { c join-with --window-id "${role[T1]}" left; }
    a_nested_resize_v() { c resize --window-id "${role[Z1]}" height +200; }
    a_nested_resize_h() { c resize --window-id "${role[Z1]}" width +200; }
    a_nested_move_in() { c move --window-id "${role[G1]}" right; }
    a_nested_move_out() { c move --window-id "${role[T1]}" right; }
    a_nested_orientation() { c layout tiles horizontal --window-id "${role[Z1]}"; }
    run layouts.nested-resize-v 0.8 "G1 Z1 T1 G2" s_nest a_nested_resize_v
    run layouts.nested-resize-h 0.8 "G1 Z1 T1 G2" s_nest a_nested_resize_h
    run layouts.nested-move-in 0.8 "G1 Z1 T1 G2" s_nest a_nested_move_in
    run layouts.nested-move-out 0.8 "G1 Z1 T1 G2" s_nest a_nested_move_out
    run layouts.nested-orientation 0.8 "G1 Z1 T1 G2" s_nest a_nested_orientation
fi

# ---------------------------------------------------------------- apps: Electron, minimum size, a hung app
if has_suite apps; then
    echo "== apps"
    a_grow_d() { c resize --window-id "${role[D]}" width +150; }
    # Discord can't be narrower than ~940pt: this asks for 780
    a_squeeze_d() { c resize --window-id "${role[G1]}" width +500; }
    tpid=""
    trap '[ -n "$tpid" ] && kill -CONT "$tpid" 2>/dev/null' EXIT
    # TextEdit stops answering (SIGSTOP) for 0.8s while its neighbours animate
    a_hung() {
        tpid=$(textedit_pid)
        kill -STOP "$tpid"
        c resize --window-id "${role[G1]}" width +300
        sleep 0.8
        kill -CONT "$tpid"
    }
    run apps.electron-resize 0.8 "G1 D" none a_grow_d
    run apps.min-size 0.8 "G1 D" none a_squeeze_d
    run apps.hung 2.0 "G1 T1 Z1" none a_hung
fi

# ---------------------------------------------------------------- lifecycle: open/close windows, workspace switch
if has_suite lifecycle; then
    echo "== lifecycle"
    known_textedit() { "$cli" list-windows --all --format '%{window-id}|%{app-name}' | awk -F'|' '$2 ~ /TextEdit/ {print $1}' | tr -d ' '; }
    wait_new_window() { # sets NEW to the TextEdit window that isn't a role
        for _ in $(seq 1 40); do
            for id in $(known_textedit); do
                if [ "$id" != "${role[T1]}" ] && [ "$id" != "${role[T2]}" ]; then NEW="$id"; return 0; fi
            done
            sleep 0.1
        done
    }
    a_open() { c focus --window-id "${role[G1]}"; new_textedit_doc; wait_new_window; }
    t_close_new() { [ -n "$NEW" ] && c close --window-id "$NEW"; sleep 0.5; NEW=""; }
    s_open() { c focus --window-id "${role[G1]}"; new_textedit_doc; wait_new_window; c move-node-to-workspace --window-id "$NEW" B1; }
    a_close() { c close --window-id "$NEW"; }
    s_b3() {
        c move-node-to-workspace --window-id "${role[G2]}" B3
        c move-node-to-workspace --window-id "${role[Z2]}" B3
    }
    a_to_b3() { c workspace B3; }
    t_to_b1() { c workspace B1; }
    s_on_b3() { s_b3; c workspace B3; }
    a_to_b1() { c workspace B1; }
    run lifecycle.open 1.0 "G1 Z1" none a_open t_close_new
    run lifecycle.close 0.8 "G1 Z1" s_open a_close t_close_new
    run lifecycle.workspace-switch 0.8 "G1 Z1" s_b3 a_to_b3 t_to_b1
    run lifecycle.workspace-back 0.8 "G1 Z1" s_on_b3 a_to_b1
fi

# ---------------------------------------------------------------- mouse: drag a border, drag a window mid-animation
if has_suite mouse; then
    echo "== mouse"
    a_drag_border() {
        local g="${role[G1]}"
        local bx=$(($(x "$g") + $(w "$g"))) by=$(($(y "$g") + $(h "$g") / 2))
        "$bin/mouse" drag $((bx - 1)) "$by" $((bx + 199)) "$by" 300
    }
    a_drag_during_animation() {
        local t="${role[T1]}"
        local tx=$(($(x "$t") + $(w "$t") / 2)) ty=$(($(y "$t") + 12))
        c resize --window-id "${role[Z1]}" width +300
        "$bin/mouse" drag "$tx" "$ty" $((tx - 400)) "$ty" 300
    }
    run mouse.drag-border 1.0 "G1 Z1 T1" none a_drag_border
    run mouse.drag-during-animation 1.2 "G1 Z1 T1" none a_drag_during_animation
fi

# ---------------------------------------------------------------- mon: between monitors
if has_suite mon && [ -n "$M2" ]; then
    echo "== mon ($dir_to_other)"
    d="$dir_to_other"
    back=$(opposite "$d")
    # The tile nearest the other monitor
    case "$d" in right) E=${role[T1]};; *) E=${role[G1]};; esac
    s_focus_e() { c focus --window-id "$E"; }
    # The user's bindings: alt-shift-hjkl = move --boundaries all-monitors-outer-frame + move-mouse, alt-hjkl = focus
    a_key_move() { key "$(keycode "$d")" "option down, shift down"; }
    a_key_move_back() { key "$(keycode "$back")" "option down, shift down"; }
    s_moved() { c move --window-id "$E" --boundaries all-monitors-outer-frame "$d"; wait_settled; c focus --window-id "$E"; }
    a_move_node() { c move-node-to-monitor --window-id "$E" "$d"; }
    a_focus_during() {
        key "$(keycode "$d")" "option down, shift down"
        sleep 0.03 # focus back 30ms into the animation
        key "$(keycode "$back")" "option down"
    }
    a_move_ws() { c move-workspace-to-monitor --workspace B1 "$d"; }
    run mon.move-key 0.8 "G1 Z1 T1" s_focus_e a_key_move
    run mon.move-back-key 0.8 "G1 Z1 T1" s_moved a_key_move_back
    run mon.move-node 0.8 "G1 Z1 T1" none a_move_node
    run mon.focus-during 1.0 "G1 Z1 T1" s_focus_e a_focus_during
    run mon.move-workspace 1.0 "G1 Z1 T1" none a_move_ws
fi

layout_roles G1 Z1 T1
echo "Done: $out"
