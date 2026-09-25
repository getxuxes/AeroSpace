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
| `.bin/trace <ids> <seconds> [h\|v]` | Passive observer. It prints every frame in which a window changed, the ranges of the windows along the axis, and the uncovered ranges (`GAPS`). Only tiles count as covering; `F` marks a floating window. It is safe to run against a real AeroSpace session. |
| `summarize.sh <trace output>` | `gapFrames>=10pt=N worst=Mpt` for one trace |
| `scenario-example.sh <cli> <label>` | Traces real actions: a key binding sent as a key event, and moves between monitors. Adapt the window ids at the top |
| `.bin/probe <id> <experiment> [screen]` | Writes frames over AX in a controlled way and samples the bounds every ~0.2 ms. It fights AeroSpace, so run `aerospace enable off` first and `aerospace enable on` afterwards. The experiments are listed below |
| `.bin/levers <id> <experiment>` | Measures the AX primitives behind each smoothness lever on one window: `axframe` (is AXFrame writable), `writedur` (setPos/setSize p50/p95), `enhui` (toggle-per-frame vs hold AXEnhancedUserInterface off), `settle` (write→WindowServer latency), `vsync` (CADisplayLink vs a timer loop; needs no window). Needs the terminal's Accessibility permission |
| `.bin/geom <id,id,…>` | Prints each window's WindowServer bounds as `id x y w h`. No Accessibility needed. Used to capture the settled final layout |
| `benchmark.sh <cli> <out-dir> [reps] [stats-log]` | Runs a battery of scenarios (3 windows on the focused workspace) against one running server, `reps` times each from a deterministic reset. Per repetition: a trace and the settled final layout (`geom`). With a stats log, also the server's AX write and tick timings of each scenario (`<scenario>.ax`) |
| `.bin/report <dirA> <dirB> [labelA] [labelB]` | Markdown tables per scenario: frame time p50/p95/max, dropped frames, max gap, monitor flips, duration, final state vs B; and the server's AX write/wait durations and display link ticks |
| `ab-compare.sh [reps]` | One-shot: builds this branch and a main worktree, runs `benchmark.sh` against each (one server at a time) and writes everything to `out/<date>-ab/` (`report.md`, `ab-compare.log`, `environment.txt`). Moves your windows; don't touch input while it runs |

Window ids come from `aerospace list-windows --all`.

### Metrics

`trace` ends with a `STATS` line (definitions in `trace.swift`, `printStats`):

- **Frame time**: the interval between two changes of a moving window's bounds, as the WindowServer shows them. At
  144Hz a smooth animation is 6.94 ms.
- **Dropped frames**: vsyncs without a change while the window was still visibly moving (the next step is ≥ 2pt). The
  sub-point tail of the easing doesn't count.
- **Gap**: 2D. The side of the largest square of a monitor's visible frame that no traced window covers, minus the same
  in the settled first and last frames (the configured gaps). With separate Spaces a window only covers the monitor
  that has most of it. This replaces the 1D `GAPS` of `summarize.sh`, which counts a window that leaves the row (e.g.
  `move down`) as a gap.
- **Monitor flips / wrong monitor**: how often a window's majority monitor changed (1 for a move between monitors),
  and frames where it was mostly on a monitor that is neither its start nor its end.

The server logs its side when started with `AEROSPACE_ANIMATION_STATS=<file>` (`AnimationStats.swift`): display link
ticks and, per animated AX write, the time it waited on the app's AX thread and how long it took. `main` doesn't have
it.

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

## Open issues

- The 3pt push can be visible for a frame on the moving edge ("looks a bit odd"). A cleaner way to get the window
  sticking out without the push is still open.
- Apps that resize slowly (Ghostty) update each window every 3–4 frames when several of their windows animate at once.
  A gap then opens between a lagging window and a neighbour that follows the curve on time (e.g. 100–350pt between two
  tiles when a floating Ghostty goes back to tiling next to another Ghostty). `main` has it too, and worse.
