#!/usr/bin/env bash
# One-shot A/B: builds this branch and a main worktree (both debug), runs benchmark.sh against each (one server at a
# time) and writes the tables (report.swift). Everything, including this script's own output, goes to
# dev-tools/animations/out/<date>-ab/ (report.md is the result). It MOVES YOUR WINDOWS and sends key and mouse events:
# DON'T touch the mouse or keyboard until it prints DONE.
#
# Suites (comma-separated): core layouts apps lifecycle mouse mon (see benchmark.sh), and "off": core again on both
# builds with [animations] enabled = false (a generated copy of your config), which must behave identically.
#
# Preconditions (checked, it aborts with instructions otherwise):
#   - No debug AeroSpace server runs. The installed app is quit automatically and reopened at the end.
#   - The windows benchmark.sh needs are open (2 Ghostty, 2 Zen, 2 TextEdit documents, 1 Discord, 1 Finder).
#   - The debug builds have the Accessibility permission, and the terminal too (key and mouse events).
#   - Animations are on in your config.
#
# Usage: ab-compare.sh [suites] [repetitions]      (default: all suites, 3 repetitions)
#   AB_B=branch AB_B_ANIMATIONS="curve = 'spring'" ab-compare.sh ...   compares this branch against itself with extra
#   [animations] lines on side B (e.g. to compare curves); the report calls the sides "rama" and "rama-b"
set -uo pipefail
suites="${1:-core,layouts,apps,lifecycle,mouse,mon,real,off}"
reps="${2:-3}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
tools="$repo/dev-tools/animations"
wt="$repo/../aerospace-main-wt"
sock="/tmp/bobko.aerospace-$(id -un).sock"
run="$tools/out/$(date +%Y-%m-%d-%H%M%S)-ab"
mkdir -p "$run"
exec > >(tee "$run/ab-compare.log") 2>&1
cd "$repo"

if pgrep -f '\.debug/AeroSpaceApp' >/dev/null; then
    echo "A debug AeroSpace server is running. Stop it first:"
    pgrep -fl '\.debug/AeroSpaceApp'
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
b_side="${AB_B:-main}"
[ "$b_side" = branch ] || [ "$b_side" = main ] || { echo "AB_B must be main or branch"; exit 1; }
[ -d "$wt" ] || git worktree add --detach "$wt" main
git -C "$wt" checkout -q --detach main || exit 1
echo "main worktree at $(git -C "$wt" rev-parse --short HEAD)"
# Measurement only: main logs the same frames/ticks as this branch (AEROSPACE_ANIMATION_STATS). Removed after the build
git -C "$wt" apply "$tools/main-instrumentation.patch" || { echo "main-instrumentation.patch doesn't apply to main"; exit 1; }
(cd "$wt" && ./build-debug.sh >/dev/null) || { echo "main build failed"; git -C "$wt" checkout -q . ; git -C "$wt" clean -fdq; exit 1; }
git -C "$wt" checkout -q . && git -C "$wt" clean -fdq

srvpid=""
stop_server() {
    [ -n "$srvpid" ] || return 0
    kill "$srvpid" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$srvpid" 2>/dev/null || break; sleep 0.1; done
    srvpid=""
}
# The installed app is quit for the benchmark (two servers fight over the windows) and reopened at the end, even if the
# run fails: it puts back the windows that the benchmark left hidden in a corner
reopen_installed=0
finish() {
    stop_server
    if [ "$reopen_installed" -eq 1 ]; then
        echo "Reopening the installed AeroSpace"
        open -a AeroSpace
    fi
}
trap finish EXIT
if pgrep -f 'AeroSpace.app/Contents/MacOS/AeroSpace' >/dev/null; then
    echo "Quitting the installed AeroSpace (reopened at the end)"
    reopen_installed=1
    osascript -e 'quit app "AeroSpace"'
    for _ in $(seq 1 50); do pgrep -f 'AeroSpace.app/Contents/MacOS/AeroSpace' >/dev/null || break; sleep 0.1; done
    if pgrep -f 'AeroSpace.app/Contents/MacOS/AeroSpace' >/dev/null; then echo "The installed AeroSpace didn't quit"; exit 1; fi
fi

off_config="$run/aerospace-animations-off.toml"
awk '/^\[/{section=$0} section=="[animations]" && /^[[:space:]]*enabled[[:space:]]*=/ {sub(/true/, "false")} {print}' "$config" > "$off_config"
grep -A2 '^\[animations\]' "$off_config" | grep -q 'enabled = false' || { echo "Couldn't turn animations off in $off_config"; exit 1; }

run_side() { # label, repoDir, suites, configPath
    local label="$1" root="$2" side_suites="$3" cfg="$4"
    echo "== $label ($side_suites): starting debug server =="
    AEROSPACE_ANIMATION_STATS="$run/$label.server.log" "$root/.debug/AeroSpaceApp" --config-path "$cfg" >"$run/$label.server.stdout" 2>&1 &
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
    "$tools/benchmark.sh" "$repo/.debug/aerospace" "$run/$label" "$side_suites" "$reps" "$run/$label.server.log" || { stop_server; return 1; }
    stop_server
    sleep 1
}

b_config="$config"
if [ -n "${AB_B_ANIMATIONS:-}" ]; then
    b_config="$run/aerospace-b.toml"
    awk -v extra="$AB_B_ANIMATIONS" '{print} /^\[animations\]/ {print "    " extra}' "$config" > "$b_config"
    echo "side B config: [animations] + $AB_B_ANIMATIONS"
fi
b_root="$wt"; b_label=main
[ "$b_side" = branch ] && { b_root="$repo"; b_label=branch-b; }
on_suites=$(echo ",$suites," | sed 's/,off,/,/g; s/^,//; s/,$//')
echo "!!! DON'T TOUCH THE MOUSE OR KEYBOARD until DONE !!!"
if [ -n "$on_suites" ]; then
    run_side branch "$repo" "$on_suites" "$config" || exit 1
    run_side "$b_label" "$b_root" "$on_suites" "$b_config" || exit 1
fi
if [[ ",$suites," == *",off,"* ]]; then
    run_side branch-off "$repo" core "$off_config" || exit 1
    run_side main-off "$wt" core "$off_config" || exit 1
fi

echo "== Report =="
: > "$run/report.md"
[ -d "$run/branch" ] && "$tools/.bin/report" "$run/branch" "$run/$b_label" rama "$([ "$b_label" = main ] && echo main || echo rama-b)" >> "$run/report.md"
if [ -d "$run/branch-off" ]; then
    printf '\n# Animaciones desactivadas\n\n' >> "$run/report.md"
    "$tools/.bin/report" "$run/branch-off" "$run/main-off" rama-off main-off >> "$run/report.md"
fi
cat "$run/report.md"
echo "DONE: $run/report.md. You can use the mouse/keyboard again."
