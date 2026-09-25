#!/usr/bin/env bash
# One-shot A/B: builds this branch and a main worktree (both debug), runs the animation benchmark against each (one
# server at a time), and diffs the final layout. The whole run takes a couple of minutes and MOVES YOUR WINDOWS around
# on the focused workspace, so DON'T touch the mouse or keyboard until it prints DONE.
#
# Preconditions (the script checks them and aborts with instructions if not met):
#   - The installed AeroSpace.app is quit (two servers must never run at once).
#   - The debug build has the Accessibility permission (grant it once via System Settings if a run manages no windows).
#   - Your config has animations on, e.g.  [animations]\n  enabled = true\n  duration-ms = 120
#
# Usage: ab-compare.sh [h|v]
set -uo pipefail
axis="${1:-h}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
wt="$repo/../aerospace-main-wt"
sock="/tmp/bobko.aerospace-$(id -un).sock"
cd "$repo"

if pgrep -f 'AeroSpace.app/Contents/MacOS/AeroSpace' >/dev/null; then
  echo "The installed AeroSpace.app is running. Quit it first:  osascript -e 'quit app \"AeroSpace\"'"; exit 1
fi

echo "== Building tools, this branch, and a main worktree (debug) =="
./dev-tools/animations/build.sh
./build-debug.sh >/dev/null
git worktree add "$wt" main 2>/dev/null || true
(cd "$wt" && ./build-debug.sh >/dev/null)

srvpid=""
stop_server() { [ -n "$srvpid" ] && kill "$srvpid" 2>/dev/null; for _ in $(seq 1 40); do kill -0 "$srvpid" 2>/dev/null || break; sleep 0.1; done; srvpid=""; }
trap stop_server EXIT

run_side() { # label, repoDir
  local label="$1" root="$2"
  echo "== $label: starting debug server =="
  "$root/.debug/AeroSpaceApp" >/dev/null 2>&1 &
  srvpid=$!
  for _ in $(seq 1 60); do [ -S "$sock" ] && "$repo/.debug/aerospace" list-windows --workspace focused >/dev/null 2>&1 && break; sleep 0.25; done
  if ! "$repo/.debug/aerospace" list-windows --workspace focused >/dev/null 2>&1; then
    echo "  server did not come up (Accessibility permission for the debug build?)"; stop_server; return 1
  fi
  echo "  !!! DON'T TOUCH THE MOUSE OR KEYBOARD for ~1 min ($label) !!!"
  "$repo/dev-tools/animations/benchmark.sh" "$repo/.debug/aerospace" "$label" "$axis"
  stop_server
  sleep 1
}

run_side branch "$repo"
run_side main "$wt"

echo "== Final-state comparison (branch vs main, must be identical) =="
"$repo/dev-tools/animations/compare-final.sh" branch main || true
echo "DONE. You can use the mouse/keyboard again. Restart your normal AeroSpace when ready."
