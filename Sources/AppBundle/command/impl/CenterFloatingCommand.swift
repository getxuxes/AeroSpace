import AppKit
import Common

struct CenterFloatingCommand: Command {
    let args: CenterFloatingCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        guard case .floatingWindowsContainer = window.windowParentCases else {
            return .fail(io.err("The window is not floating. Tip: use 'layout floating' first"))
        }
        guard let workspace = window.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
        let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps

        let currentSize = (try? await window.getAxSize(.nonCancellable)) ?? window.lastFloatingSize
        guard let width = resolve(args.width, area.width) ?? currentSize?.width,
              let height = resolve(args.height, area.height) ?? currentSize?.height
        else {
            return .fail(io.err("Can't determine the window size. Specify both --width and --height"))
        }
        let size = CGSize(width: min(width, area.width), height: min(height, area.height))
        let topLeft = CGPoint(
            x: area.topLeftX + (area.width - size.width) / 2,
            y: area.topLeftY + (area.height - size.height) / 2,
        )
        window.setAxFrame(topLeft, size)
        window.lastFloatingSize = size
        return .succ
    }
}

private func resolve(_ size: CenterFloatingCmdArgs.FloatingSize?, _ available: CGFloat) -> CGFloat? {
    switch size {
        case .percent(let percent): available * CGFloat(percent) / 100
        case .points(let points): CGFloat(points)
        case nil: nil
    }
}
