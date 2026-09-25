#!/usr/bin/env bash
# Runs a battery of animation scenarios against ONE running AeroSpace server, tracing each one (frame-time + gaps) and
# capturing the settled final layout. Run it once per build (this branch and a main worktree, both built the same way,
# with exactly one server running) and then diff with compare-final.sh.
#
# Usage: benchmark.sh <aerospace-cli> <label> [h|v]
#   <aerospace-cli>  the CLI of the running server, e.g. ./run-cli.sh or ~/aerospace-main-wt/.debug/aerospace
#   <label>          a name for this run, e.g. branch or main
#   [h|v]            layout axis to trace along (default h)
#
# It moves windows on the FOCUSED workspace. Don't touch the mouse or keyboard while it runs (~1-2 min).
set -uo pipefail
cli="$1"
label="$2"
axis="${3:-h}"
dir="$(cd "$(dirname "$0")" && pwd)"
bin="$dir/.bin"
out="$bin/bench/$label"
mkdir -p "$out"
[ -x "$bin/trace" ] && [ -x "$bin/geom" ] || { echo "Build the tools first: $dir/build.sh"; exit 1; }

# Windows on the focused workspace, in tree order
mapfile -t ids < <("$cli" list-windows --workspace focused --format '%{window-id}' | tr -d ' ')
n=${#ids[@]}
if [ "$n" -lt 2 ]; then echo "Need at least 2 windows on the focused workspace (have $n)"; exit 1; fi
csv=$(IFS=,; echo "${ids[*]}")
echo "$label: $n windows on focused workspace: $csv"

settle=0.35   # seconds to let the animation finish before snapshotting the final layout
trace_secs=1.0

reset() { # put the windows in a known left-to-right tiles layout every time
  "$cli" flatten-workspace-tree >/dev/null 2>&1
  "$cli" focus --window-id "${ids[0]}" >/dev/null 2>&1
  "$cli" layout tiles horizontal >/dev/null 2>&1
  sleep 0.4
}

run() { # name, command...
  local name="$1"; shift
  "$bin/trace" "$csv" "$trace_secs" "$axis" > "$out/$name.trace" 2>/dev/null &
  local tracepid=$!
  sleep 0.1
  "$@" >/dev/null 2>&1
  wait "$tracepid"
  sleep "$settle"
  "$bin/geom" "$csv" > "$out/$name.geom"
  echo "  $name: $("$dir/summarize.sh" "$out/$name.trace" 2>/dev/null || echo "-")"
  sleep 0.3
}

# ---- single-monitor scenarios (scriptable via the CLI) ----
reset; run move-right   "$cli" move right
reset; run move-left    "$cli" move left
reset; run move-up      "$cli" move up
reset; run move-down    "$cli" move down
reset; run swap-right   "$cli" swap right
reset; run orientation  "$cli" layout tiles vertical
reset; run resize-plus  "$cli" resize width +150
reset; run resize-minus "$cli" resize width -150
reset; run balance      "$cli" balance-sizes
reset; run fullscreen-on  "$cli" fullscreen on
reset; run float        "$cli" layout floating
reset; "$cli" layout floating >/dev/null 2>&1; sleep 0.4; run tile "$cli" layout tiling

# Rapid interruptions: five resizes back to back, and a command mid-animation
reset
"$bin/trace" "$csv" 1.6 "$axis" > "$out/rapid-resize.trace" 2>/dev/null & tracepid=$!
sleep 0.1
for _ in 1 2 3 4 5; do "$cli" resize width +80 >/dev/null 2>&1; done
wait "$tracepid"; sleep "$settle"; "$bin/geom" "$csv" > "$out/rapid-resize.geom"
echo "  rapid-resize: $("$dir/summarize.sh" "$out/rapid-resize.trace" 2>/dev/null || echo "-")"

reset
"$bin/trace" "$csv" 1.2 "$axis" > "$out/interrupt.trace" 2>/dev/null & tracepid=$!
sleep 0.1
"$cli" move right >/dev/null 2>&1
sleep 0.05   # interrupt the running animation with a new command
"$cli" move left >/dev/null 2>&1
wait "$tracepid"; sleep "$settle"; "$bin/geom" "$csv" > "$out/interrupt.geom"
echo "  interrupt: $("$dir/summarize.sh" "$out/interrupt.trace" 2>/dev/null || echo "-")"

reset
echo "Done. Traces and final-layout snapshots in $out"
