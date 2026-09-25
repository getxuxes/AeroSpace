#!/usr/bin/env bash
# One-shot A/B: builds this branch and a main worktree (both debug), runs benchmark.sh against each (one server at a
# time) and writes the tables (report.swift). Everything, including this script's own output, goes to
# dev-tools/animations/out/<date>-ab/ (report.md is the result). It MOVES YOUR WINDOWS on the focused workspace:
# DON'T touch the mouse or keyboard until it prints DONE (~6 min with 3 repetitions).
#
# Preconditions (checked, it aborts with instructions otherwise):
#   - No other AeroSpace server runs (the installed app is quit). Two servers fight over the windows.
#   - Exactly 3 windows on the focused workspace.
#   - The debug builds have the Accessibility permission, and the terminal too (the key-binding scenarios send keys).
#   - Animations are on in the config, e.g.  [animations]  enabled = true  duration-ms = 120
#
# Usage: ab-compare.sh [repetitions]
set -uo pipefail
reps="${1:-3}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tools="$repo/dev-tools/animations"
wt="$repo/../aerospace-main-wt"
sock="/tmp/bobko.aerospace-$(id -un).sock"
run="$tools/out/$(date +%Y-%m-%d-%H%M%S)-ab"
mkdir -p "$run"
exec > >(tee "$run/ab-compare.log") 2>&1
cd "$repo"

if pgrep -f 'AeroSpace.app/Contents/MacOS/AeroSpace|\.debug/AeroSpaceApp' >/dev/null; then
    echo "Another AeroSpace server is running. Quit it first:  osascript -e 'quit app \"AeroSpace\"'  (and stop debug servers)"
    pgrep -fl 'AeroSpace.app/Contents/MacOS/AeroSpace|\.debug/AeroSpaceApp'
    exit 1
fi

{
    echo "date: $(date)"
    echo "branch: $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD) (dirty files: $(git status --porcelain | wc -l | tr -d ' '))"
    echo "main: $(git rev-parse --short main)"
    sw_vers | tr '\n' ' '; echo
    system_profiler SPDisplaysDataType 2>/dev/null | grep -E '^\s+[A-Za-z0-9 ]+:$|Resolution|Refresh|Main Display|Mirror' | sed 's/^ *//'
    config="${XDG_CONFIG_HOME:-$HOME/.config}/aerospace/aerospace.toml"
    [ -f "$config" ] || config="$HOME/.aerospace.toml"
    echo "config: $config"
    grep -A3 '^\[animations\]' "$config"
    grep -E '^\s*gaps\.' "$config"
} > "$run/environment.txt"
cat "$run/environment.txt"

echo "== Building tools, this branch, and a main worktree (debug) =="
./dev-tools/animations/build.sh || exit 1
./build-debug.sh >/dev/null || { echo "branch build failed"; exit 1; }
[ -d "$wt" ] || git worktree add --detach "$wt" main
git -C "$wt" checkout -q --detach main || exit 1
echo "main worktree at $(git -C "$wt" rev-parse --short HEAD)"
(cd "$wt" && ./build-debug.sh >/dev/null) || { echo "main build failed"; exit 1; }

srvpid=""
stop_server() {
    [ -n "$srvpid" ] || return 0
    kill "$srvpid" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$srvpid" 2>/dev/null || break; sleep 0.1; done
    srvpid=""
}
trap stop_server EXIT

run_side() { # label, repoDir
    local label="$1" root="$2"
    echo "== $label: starting debug server =="
    AEROSPACE_ANIMATION_STATS="$run/$label.server.log" "$root/.debug/AeroSpaceApp" >"$run/$label.server.stdout" 2>&1 &
    srvpid=$!
    for _ in $(seq 1 60); do
        [ -S "$sock" ] && "$repo/.debug/aerospace" list-windows --workspace focused >/dev/null 2>&1 && break
        sleep 0.25
    done
    if ! "$repo/.debug/aerospace" list-windows --workspace focused >/dev/null 2>&1; then
        echo "  server did not come up (Accessibility permission for the debug build?)"; stop_server; return 1
    fi
    sleep 1 # let the server finish its first layout
    # The server creates the log at its first animation. main has no AnimationStats and never creates it
    "$tools/benchmark.sh" "$repo/.debug/aerospace" "$run/$label" "$reps" "$run/$label.server.log"
    stop_server
    sleep 1
}

echo "!!! DON'T TOUCH THE MOUSE OR KEYBOARD until DONE !!!"
run_side branch "$repo" || exit 1
run_side main "$wt" || exit 1

echo "== Report =="
"$tools/.bin/report" "$run/branch" "$run/main" rama main > "$run/report.md"
cat "$run/report.md"
echo "DONE: $run/report.md. You can use the mouse/keyboard again. Restart your normal AeroSpace when ready."
