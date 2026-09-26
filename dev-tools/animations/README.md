# Measuring window animations

Tools for measuring what the WindowServer shows while AeroSpace animates windows (`[animations]` in the config,
`Sources/AppBundle/layout/WindowAnimator.swift`).

They don't capture the screen and need no Screen Recording permission. They read window bounds with
`CGWindowListCreateDescriptionFromArray`, which reflects the WindowServer's state. They time the samples against the
vsync with `CVDisplayLink`. `probe` also writes frames over the Accessibility API, so the terminal that runs it needs
the Accessibility permission.

Judging by eye doesn't work: the artifacts last a frame or two, and they vary from run to run. Measure, repeat each case
at least 3 times, and compare against a baseline built the same way.

## Tools

```sh
dev-tools/animations/build.sh     # compiles into dev-tools/animations/.bin (git-ignored)
```

| Tool | What it does |
|---|---|
| `.bin/trace <ids\|all> <seconds> [h\|v] [managed ids]` | Passive observer at every vsync. Prints every frame in which a window changed and ends with a `STATS` line (metrics below). `all` follows every on-screen window, including new ones. With `TRACE_RAW=<file>` it also dumps the raw samples for `lag`. Safe to run against a real AeroSpace session |
| `.bin/lag <raw> <server log> <managed ids>` | Splits the gaps of one trace into planned and unexpected, with the frames the animator sent (`LAG` line), and measures velocity jumps between ticks |
| `summarize.sh <trace output>` | Old 1D summary: `gapFrames>=10pt=N worst=Mpt` |
| `scenario-example.sh <cli> <label>` | Traces real actions: a key binding sent as a key event, and moves between monitors. Adapt the window ids at the top |
| `.bin/probe <id> <experiment> [screen]` | Writes frames over AX in a controlled way and samples the bounds every ~0.2 ms. It fights AeroSpace, so run `aerospace enable off` first and `aerospace enable on` afterwards. The experiments are listed below |
| `.bin/levers <id> <experiment>` | Measures AX primitives on one window: `axframe` (is AXFrame writable), `writedur` (setPos/setSize p50/p95), `enhui` (toggle-per-frame vs hold AXEnhancedUserInterface off), `settle` (write→WindowServer latency), `vsync` (CADisplayLink vs a timer loop; needs no window), `focus` (what nativeFocus costs, and whether a setPos from another thread waits for a raise). Needs the terminal's Accessibility permission |
| `.bin/sls <id> <dx> [steps] [async\|sync\|direct]` | Tries to move another app's window through SkyLight (private `SLSTransaction*` / `SLSMoveWindow`). On macOS 27 nothing moves (see below) |
| `.bin/native <id> "Window/Move & Resize/Left"` | Presses a menu item over AX and records macOS's own tiling animation: WindowServer bounds per vsync and, with ScreenCaptureKit (Screen Recording permission), the size of the window's surface per frame |
| `.bin/geom <name=id,…>` / `--screens` | Each window's WindowServer bounds as `name x y w h v\|h` (v: mostly on a screen); `--screens` lists the screens. No Accessibility needed |
| `.bin/mouse drag x1 y1 x2 y2 ms` | Posts a real mouse drag (for border and window drags) |
| `benchmark.sh <cli> <out-dir> <suites> [reps] [stats-log]` | Runs the scenario suites (`core layouts apps lifecycle mouse mon real`) against one running server, `reps` times each from a deterministic reset, with windows found by app and role (2 Ghostty, 2 Zen, 2 TextEdit, Discord, Finder or a 3rd Ghostty). `BENCH_ONLY='regex'` runs a subset |
| `.bin/report <dirA> <dirB> [labelA] [labelB]` | Markdown tables per scenario (see Metrics), final state of the visible windows repetition by repetition, and the server's AX writes, ticks and other AX thread jobs |
| `ab-compare.sh [suites] [reps]` | One-shot: builds this branch and a main worktree (main gets `main-instrumentation.patch`, measurement only, applied for the build and removed), quits the installed AeroSpace, runs `benchmark.sh` against each build, reopens AeroSpace, and writes everything to `out/<date>-ab/`. `off` also runs `core` with animations disabled on both. `AB_B=branch AB_B_ANIMATIONS="curve = 'spring'"` compares the branch against itself with other settings. Moves your windows and sends keys and mouse events; don't touch input while it runs |

Window ids come from `aerospace list-windows --all`.

### Metrics

`trace` ends with a `STATS` line (definitions in `trace.swift`, `printStats`) and `lag` adds a `LAG` line:

- **Frame time**: the interval between two changes of a moving window's bounds, as the WindowServer shows them. At
  144Hz a smooth animation is 6.94 ms. An interval over 250 ms is a pause between two animations, not a frame.
- **Dropped frames**: vsyncs without a change while the window was still visibly moving (the next step is ≥ 2pt). The
  sub-point tail of the easing doesn't count.
- **Gaps**, 2D: the side of the largest square of a monitor's visible frame that no window covers. With separate Spaces
  a window only covers the monitor that has most of it. `lag` splits it: **planned** (not covered even by the frames the
  animator sent, e.g. windows that cross or leave) and **unexpected** (covered by the frames sent at least 1 vsync
  earlier, but not by the real windows: a window lags behind). Both servers log the frame they meant on every tick.
- **Resize %**: of the frames with a change, those where some window changed size (the rest only moved).
- **Velocity jump**: how much a window's step (pt per 144Hz frame) changes between two consecutive animator ticks. An
  interrupted animation that restarts at another speed shows up here.
- **Monitor flips / wrong monitor**: how often a managed window's majority monitor changed (1 for a move between
  monitors), and frames where it was mostly on a monitor that is neither its start nor its end.

The server logs its side when started with `AEROSPACE_ANIMATION_STATS=<file>` (`AnimationStats.swift`): display link
ticks, the intended frames, every animated AX write (queue wait and duration) and every other job on the apps' AX
threads with the function that queued it.

Measure with nothing else going on: a build or an edit to a running script (bash reads scripts as it goes) ruins a run.

## How to compare two builds

1. Build both the same way, because debug and release timings differ. To get a debug build of `main`, use a worktree:
   `git worktree add ../aerospace-main-wt main && (cd ../aerospace-main-wt && ./build-debug.sh)`.
2. Run **exactly one** server. Quit the installed app (`osascript -e 'quit app "AeroSpace"'`), stop debug servers by
   PID, and check with `ps -axo pid,command | grep -i aerospaceapp`. Two servers fight over the windows, and the
   measurement becomes garbage.
3. Put the windows in the same tree before every run: `flatten-workspace-tree`, then `move --window-id …` until the
   order is right.
4. Reproduce what the user actually does. A key binding runs its commands in one batch
   (`layout floating && center-floating`), which is not the same as separate CLI calls. Send the binding as a key event
   (`osascript -e 'tell application "System Events" to key code 49 using {option down, shift down}'`) right after
   `focus --window-id`, because focus may have moved. Remember moves between monitors.
5. Compare summaries across ≥3 runs. Then read the raw trace of the interesting case. A window that jumps (for example
   `203:[3413..]` followed directly by `203:[2560..]`) or an edge that goes backwards is what the eye sees.

The `GAPS` include space that an animation uncovers on purpose, for example where a window left. Only a difference
against the baseline, or a far edge that goes backwards, is an artifact.

## What the measurements showed

The code relies on these facts; don't re-derive them.

- **There is no atomic frame write.** `AXPosition` and `AXSize` are separate writes. `AXFrame` exists, but no app
  lets you write it (Ghostty, Zed, Helium, Finder).
- **Moves land before resizes.** A move reaches the WindowServer in about 1 vsync. A resize goes through the app's
  Core Animation commit and lands 1–3 vsyncs later (probe `E2`). A window growing to the left or up therefore shows,
  for a frame, its new position with its old size. Its right (bottom) edge goes back and uncovers what is behind it:
  59pt in Ghostty and 322pt in Zed at 2560pt wide on a 144Hz monitor. Helium shows none.
- **When macOS trims a resize.** macOS trims a resize only if the window fits entirely on its monitor and the new size
  would stick out of it. That includes the edge between two monitors. If the window already sticks out, even by 1pt,
  the resize is not trimmed (probe `E1`, `E1n`, `E1i`). A 0.5pt push rounds to 0 and gets trimmed. Moves are never
  trimmed. This rule is why "resize first, then move" leaves the window short at the screen edge.
- **Apps round frames to whole points.** AeroSpace's rects are fractional (4266.67 + 853.33), and the app turns them
  into 4266 + 853 = 5119. A 1pt push can therefore leave the window exactly at the edge, where it still gets trimmed.
  3pt is enough.
- **With "Displays have separate Spaces"**, macOS doesn't draw the part of a window that sticks into another monitor.
  Once most of the window is on the other monitor, the window jumps there (probe `VIS`, confirmed by eye). A command
  line tool must call `_ = NSApplication.shared` before `NSScreen.screensHaveSeparateSpaces`, otherwise it always
  gets `false`.
- **Coalescing doesn't make it atomic.** Sending the position and size writes from two threads so the app handles
  them in one run loop turn doesn't make them land together (probe `E3`, 2/20).
- **Each app has one AX thread in AeroSpace.** Ghostty needs ~7–10 ms per resize. When two windows of one app animate
  at once, they share that thread.
- **The display link fixes moves, not resizes** (ab-compare 2026-09-26). Moves and swaps go from p50 12–14 ms (main,
  1 change every 2 vsyncs) to ~7 ms (every vsync). With a resize, every window updates as fast as its app redraws: Zen
  5–17 ms per resize depending on the page, Ghostty ~8, TextEdit ~9, Messages ~70. That is the ceiling, and branch and
  main tie there.
- **Gaps between tiles are lag.** A neighbour that resizes slowly falls behind the frame it was sent (unexpected gap);
  hundreds of points in move/orientation, on main as much as on the branch.
- **A slow AX call blocks the app's animation.** Closing a window focuses the next one; `nativeFocus` (AXMain + AXRaise +
  activate) held Zen's AX thread for 219–313 ms in the benchmark (8–15 ms in isolation), the animated writes waited
  behind it and the window jumped at the end (853 pt unexpected gap in 3/10 closes on main, 5/10 on the branch).
- **SkyLight moves don't work from our process** (`sls`, macOS 27): `SLSTransactionMoveWindowWithGroup` and
  `SLSMoveWindow` return no error and move nothing, for Ghostty, Zen, TextEdit and Discord.
- **macOS's own tiling animation isn't smoother** (`native`): Window > Move & Resize also redraws the app at every size
  (the window's surface follows the frame; Zen: 15 changes in 376 ms), even its pure moves change on 50–63% of the
  vsyncs, and it lasts 310–430 ms. Its curve is a critically damped spring (rms 0.012–0.046 vs 0.09–0.15 for ease-out
  cubic).

## How the animator uses them

- **Sticking out** (`stickOutLimit`, `stuckOutLength`, `MacApp.setAxFrameStickingOut`): a window that grows to the
  left (up) while its right (bottom) edge is at the edge of a monitor becomes bigger than it looks.
  1. It is pushed 3pt past the edge, gets its size, and is moved back, all in one non-cancellable AX job.
  2. From then on it mostly moves, and moving doesn't need a redraw, so the far edge stays in place.
     - Nothing beyond the edge: the window takes its final size right away (limit `.infinity`).
     - Another monitor beyond the edge, with separate Spaces: the window is at most 1.7× its visible length, so that
       most of it stays on its monitor. It resizes again when the margin drops below 1.4×.
     - Another monitor beyond the edge, without separate Spaces: no sticking out, because it would show on the other
       monitor.
  3. Interior edges between tiles don't need it: "resize first" only overshoots there, and doesn't uncover anything.
- **Position first at the monitor edge** (`shrinksAtMonitorEdge`): a window that shrinks from the left (top) while its
  right (bottom) edge stays at the edge of the monitor is moved first and resized second, on every frame. The move lands
  first, so the window sticks out by one frame's distance instead of pulling its far edge back. On `main` that edge went
  back 87–181pt when a window arrived on the left from the other monitor or from floating. The window still resizes on
  every frame, like the others. The same rule about the other monitor applies (`stickOutLimit`).
- **Latest-frame mailbox** (`MacApp.setAxFrameAnimated`): animation writes are never cancelled. Previously, every frame
  cancelled the window's pending job. When the app's AX thread was busy with another window (e.g. a Ghostty window
  resizing to floating), the job never started, and the window jumped at the end of the animation, uncovering up to
  ~850pt. Now a queued job takes the latest frame when it runs.

- **Display link tick** (`WindowAnimator`, `DisplayTicker`): one `NSScreen.displayLink` per screen with an animating
  window, so writes are in phase with each monitor's vsync. A `Task.sleep` timer ran at ~119 fps and off phase.
- **AXEnhancedUserInterface held off** (`EnhancedUiHold`): turned off once per app for the whole animation instead of
  around every write (p95 per write 1.7–3.4× lower), restored at the end, and after a crash on the next start
  (`EnhancedUiRestoreStore`).
- **Fullscreen** is animated: the animator remembers the fullscreen frame, because a fullscreen window keeps
  `lastAppliedLayoutPhysicalRect` nil.
- **Curves** (`[animations] curve`): `ease-out` (default) and `spring`, a critically damped spring that keeps the
  velocity of the animation it interrupts (velocity jump p95 at an interruption 155 → 45 pt/frame), at the cost of a
  longer tail (moves p95 14.5 → 20.8 ms).

## Tried and rejected

- **Position first for every window that shrinks from the left.** The middle tile's left edge ran ahead of the window
  that was coming in, which uncovered up to 469pt when a floating window went back to the leftmost tile. Only the window
  at the monitor edge gets the new order now.
- **Keeping the size of a shrinking window and resizing at the end.** No gap, but the content slides off the screen
  instead of re-laying out. The user found it worse.
- **Skipping the second resize (size, pos, size) on in-between frames** to lighten slow apps. No measurable difference.
- **Sending the position one frame after the size ("pipelined").** At the screen edge the resize gets trimmed.
- **Asking the app for a size a few ms ahead, and ease-in-out.** They flicker, and don't help.
- **A cover window behind the animated windows.** Not tried: its color can't match the window without capturing the
  screen.
- **SkyLight transactions to move windows without AX** (the idea from OmniWM). Nothing moves on macOS 27 from our process.
- **Triggering macOS's own tiling animation** (pressing Window > Move & Resize over AX). It works, but only for fixed
  halves/quarters, one window at a time, it activates the app (focus changes), lasts 300–430 ms and isn't smoother.
- **A second AX thread per app for animation writes**, so that a slow `nativeFocus` doesn't block them. Not done: a
  bigger change, and it isn't shown that the app answers while it's busy; the case is on main too.

## Open issues

- The 3pt push can be visible for a frame on the moving edge ("looks a bit odd"). A cleaner way to get the window
  sticking out without the push is still open.
- Apps that resize slowly (Ghostty) update each window every 3–4 frames when several of their windows animate at once.
  A gap then opens between a lagging window and a neighbour that follows the curve on time (e.g. 100–350pt between two
  tiles when a floating Ghostty goes back to tiling next to another Ghostty). `main` has it too, and worse.
