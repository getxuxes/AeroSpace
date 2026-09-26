# CLAUDE.md

AeroSpace is an i3-like tiling window manager for macOS, written in Swift.
Deeper background lives in `dev-docs/architecture.md` and `dev-docs/development.md`.

## Architecture in one paragraph

- **Server:** `AeroSpace.app` (`Sources/AppBundle`) manages windows through the Accessibility API.
- **Client:** the `aerospace` CLI (`Sources/Cli`) talks to the server over a UNIX socket.
- **Request flow:**
  1. The client parses the args. On error it reports and exits; with `-h` it prints help.
  2. The client sends the args to the server.
  3. The server parses them again and runs the command.
  4. The server returns stdout, stderr and an exit code to the client.
- **Shared code:** `Sources/Common` holds the code both sides use, mostly args parsing (`cmdArgs/`) and utils.

## Layout

| Path | What |
|---|---|
| `Package.swift` | SPM package: `PrivateApi`, `Common`, `AppBundle`, `AeroSpaceApp`, `Cli`, `AppBundleTests` |
| `Sources/AppBundle/command/impl/` | One `<X>Command.swift` per command (server-side execution) |
| `Sources/AppBundle/{config,tree,layout,mouse,ui}/` | TOML config parsing, workspace/window tree model, tiling layout, mouse, UI |
| `Sources/Common/cmdArgs/impl/` | One `<X>CmdArgs.swift` per command (flags & positional args parser) |
| `Sources/AppBundleTests/` | XCTest tests, mirroring `AppBundle` structure (`command/`, `config/`, `tree/`, …) |
| `Sources/PrivateApi/` | C shim exposing private `_AXUIElementGetWindow` |
| `docs/` | AsciiDoc sources for the site and man pages (`aerospace-<cmd>.adoc`, `commands.adoc`, `guide.adoc`) |
| `grammar/commands-bnf-grammar.txt` | Shell completion grammar |
| `axDumps/` | Accessibility dumps of real apps, used by window-detection tests |
| `xcode/` | Generated Xcode project (xcodegen). Only used by release builds |
| `script/` | Helper scripts used by the top-level `*.sh` |
| `dev-tools/animations/` | Tools that measure what the WindowServer shows during window animations and moves (no screen capture), and what the measurements showed |

**Generated files:** don't edit `*Generated.swift` by hand. Regenerate them with `./generate.sh`.
- `Sources/Common/cmdHelpGenerated.swift` is generated from `docs/aerospace-*.adoc`.
- `Sources/Cli/subcommandDescriptionsGenerated.swift` comes from the `:manpurpose:` line in those docs.

## Development workflow

Toolchain: Xcode, plus `swiftly`, which picks the Swift version pinned in `.swift-version`.

| Task | Command |
|---|---|
| Debug build (SPM, output in `.debug/`) | `./build-debug.sh` |
| Run debug server (quit installed AeroSpace first) | `./run-debug.sh` |
| Send a command to the debug server | `./run-cli.sh <args>` |
| Unit tests only | `./swift-test.sh` |
| Format | `./format.sh` (SwiftFormat) |
| Lint | `./lint.sh` (format + SwiftLint + periphery dead-code scan) |
| Regenerate generated files | `./generate.sh` |
| **Full check before committing** | `./test.sh` |
| Docs (site + man, into `.site`/`.man`) | `./build-docs.sh` |
| Release `.app` (Xcode, needs `aerospace-codesign-certificate`) | `./build-release.sh` |

`./test.sh` does all of the following:
- builds with `-warnings-as-errors`
- runs the tests
- smoke-tests the CLI
- lints
- regenerates the generated files
- fails if any generated file ends up uncommitted

It must end with `✅ All tests have passed successfully`.

### Typical change cycle

1. Create a branch off `main`.
2. Edit the code under `Sources/`, and add or adjust tests in `Sources/AppBundleTests/`.
3. Iterate with `./build-debug.sh` and `./swift-test.sh`. If the change affects runtime behavior, also try it live with `./run-debug.sh` and `./run-cli.sh`.
4. Run `./test.sh` until it passes, then commit everything, including any regenerated files.
5. Match the repo's commit style: a short imperative subject with no prefix convention, e.g. `Fix new compiler warnings`. Split multi-step work into commits named `1/2 …` and `2/2 …`.

## Adding or changing a command

Take `echo` as the reference: `EchoCmdArgs.swift`, `EchoCommand.swift`, `EchoCommandTest.swift`.

1. **Args:** add `Sources/Common/cmdArgs/impl/<X>CmdArgs.swift`.
   - It defines a `CmdParser` with its flags and posArgs.
   - Use `help: <x>_help_generated` for the help text.
2. **Register the args:**
   - Add a `case` to `CmdKind`.
   - Add it to the switch in `Sources/Common/cmdArgs/cmdArgsManifest.swift`.
3. **Execution:** add `Sources/AppBundle/command/impl/<X>Command.swift`.
   - It must conform to `Command` and implement `run(_ env: CmdEnv, _ io: CmdIo)`.
   - Register it in `Sources/AppBundle/command/cmdManifest.swift`.
4. **Docs:** add `docs/aerospace-<x>.adoc` (it needs a `:manpurpose:` line) and list it in `docs/commands.adoc`.
5. **Regenerate:** run `./generate.sh` to produce the help text and CLI descriptions.
6. **Shell completion:** update `grammar/commands-bnf-grammar.txt`.
7. **Test:** add `Sources/AppBundleTests/command/<X>CommandTest.swift`.
   - Cover parsing with `testParseSingleCommandSucc` / `testParseCommandFail`.
   - Cover behavior with `setUpWorkspacesForTests()` and test windows.
8. **Flags:** decide whether `--window-id` and/or `--workspace` make sense for the command.

## Window animations and window behavior

`WindowAnimator.swift` animates windows by writing frames over AX, ticked by one display link per screen, and the
WindowServer applies moves and resizes at different times. Before you change animations, or debug anything visual (gaps,
flicker, windows that jump), read `dev-tools/animations/README.md`.
- It records the facts already measured (why a window that grows to the left uncovers what is behind it, when macOS
  trims a resize, separate Spaces, the 3pt push, the per-app AX thread). It also lists what was tried and rejected.
- Measured ceilings: moves reach every vsync (p50 ~7 ms at 144Hz); a resize can't be faster than the app redraws (Zen
  5–17 ms, Ghostty ~8, TextEdit ~9), and gaps between tiles are a slow neighbour lagging behind. macOS's own tiling
  animation has the same limits.
- Rejected, don't propose again: SkyLight window moves (nothing moves from our process on macOS 27), AXFrame (not
  writable), pushing windows off-screen, animating screenshots, an opaque backdrop, tiles that jump, moving now and
  resizing at the end, triggering macOS's Move & Resize.
- With `[animations] enabled = false` behavior must stay identical to `main`: guard every change behind the setting.

Measure with its tools, not by eye:
- `dev-tools/animations/ab-compare.sh [suites] [reps]` builds this branch and a `main` worktree, quits the installed
  AeroSpace, runs `benchmark.sh` against each build, reopens AeroSpace and writes `out/<date>-ab/report.md`: frame time,
  dropped frames, total and unexpected gaps, resize share, velocity jumps, monitor flips, final state per scenario.
  `BENCH_ONLY='regex'` runs a subset; `AB_B=branch AB_B_ANIMATIONS="…"` compares two configs of the branch.
- It needs the windows it acts on open (2 Ghostty, 2 Zen, 2 TextEdit, Discord, Finder) and nobody touching the input.
  Don't build or edit its scripts while it runs.
- Servers log with `AEROSPACE_ANIMATION_STATS=<file>` (`AnimationStats.swift`); `main` gets the same logs from
  `main-instrumentation.patch` during the build only.
- Repeat a suspicious case ≥10 times on both builds before calling it a regression: 2/3 vs 0/3 isn't a difference.
- Test the user's real key bindings (their commands run in one batch), vertical and horizontal layouts, and moves
  between monitors.

## Conventions and gotchas

- Never use `Task { }` or `Task.init` directly. Use `Task.startUnstructured` (`lint.sh` enforces this).
- Swift 6 strict concurrency is on (`NonisolatedNonsendingByDefault`, strict memory safety). Server code is mostly `@MainActor`.
- Unused code fails the periphery scan in `lint.sh`, so delete dead code instead of leaving it.
- `.gitignore` ignores all root-level entries by default. A new top-level file or directory must be whitelisted in `.gitignore` or added with `git add -f`.
- Follow `CONTRIBUTING.md` and "read the room": make patches, tests and commit messages look like the existing ones.
