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

`WindowAnimator.swift` animates windows by writing frames over AX, ticked by one display link per screen. Every
window gets the same writes on every frame (`setFrame`: size, position, size), through a latest-frame mailbox per window
on its app's AX thread (`MacApp.setAxFrameAnimated`). Keep it that way: general rules, no special cases.

What AX allows, measured on macOS 27:
- There is no atomic frame write. `AXPosition` and `AXSize` are separate, and `AXFrame` isn't writable.
- A move reaches the screen in about 1 vsync. A resize waits for the app to redraw, 1–3 vsyncs later (Zen 5–17 ms,
  Ghostty ~8, TextEdit ~9). A window growing to the left or up can uncover what is behind it for a frame or two.
  Gaps between tiles are a slow app lagging behind. That's the ceiling: macOS's own tiling animation has it too.
- Each app has one AX thread in AeroSpace. A slow AX call (e.g. focusing a window) delays that app's animation.

Rejected, don't propose again:
- per-direction or per-edge tricks (pushing a window a few points past the monitor edge, a special write order at the
  edge);
- SkyLight window moves (nothing moves from our process);
- pushing windows off-screen;
- animating screenshots, or an opaque backdrop;
- tiles that jump, or moving now and resizing at the end;
- triggering macOS's Move & Resize.

With `[animations] enabled = false` behavior must stay identical to `main`: guard every change behind the setting. Try
changes with the user's real key bindings, in vertical and horizontal layouts, and when moving between monitors.

## Conventions and gotchas

- Never use `Task { }` or `Task.init` directly. Use `Task.startUnstructured` (`lint.sh` enforces this).
- Swift 6 strict concurrency is on (`NonisolatedNonsendingByDefault`, strict memory safety). Server code is mostly `@MainActor`.
- Unused code fails the periphery scan in `lint.sh`, so delete dead code instead of leaving it.
- `.gitignore` ignores all root-level entries by default. A new top-level file or directory must be whitelisted in `.gitignore` or added with `git add -f`.
- Follow `CONTRIBUTING.md` and "read the room": make patches, tests and commit messages look like the existing ones.
