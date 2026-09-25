import AppKit
import Common

struct LayoutCommand: Command {
    let args: LayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let node: ConventionalWindowParentCases
        switch args.root ? nil : target.windowOrNil {
            case let window?:
                switch window.windowParentCases {
                    case .floatingWindowsContainer(let it):
                        node = .floatingWindowsContainer(it)
                    case .tilingContainer(let it):
                        node = .tilingContainer(it)
                    case .macosFullscreenWindowsContainer,
                         .macosHiddenAppsWindowsContainer,
                         .macosMinimizedWindowsContainer:
                        let msg = "Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. " +
                            "This behavior is subject to change"
                        return .fail(io.err(msg))
                    case .unbound, .macosPopupWindowsContainer:
                        return .fail(io.err(bugPrompt()))
                }
            case nil:
                node = .tilingContainer(target.workspace.rootTilingContainer)
        }

        let targetDescription = args.toggleBetween.val.first(where: { !node.matchesDescription($0) })
            ?? args.toggleBetween.val.first.orDie()
        if node.matchesDescription(targetDescription) {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = "Already in the requested \(targetDescription.rawValue) mode. " +
                        "Tip: use --fail-if-noop to exit with non-zero exit code"
                    return .succ(io.err(msg))
            }
        }
        switch targetDescription {
            case .h_tiles, .horizontal:
                return changeTilingLayout(io, targetOrientation: .h, node: node)
            case .v_tiles, .vertical:
                return changeTilingLayout(io, targetOrientation: .v, node: node)
            case .tiles:
                return changeTilingLayout(io, targetOrientation: nil, node: node)
            case .tiling:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                switch node {
                    case .tilingContainer:
                        return .succ // Nothing to do
                    case .floatingWindowsContainer(let container):
                        let floatingRect = try? await window.getAxRect(.nonCancellable)
                        window.lastFloatingSize = floatingRect?.size ?? window.lastFloatingSize
                        window.lastAppliedLayoutPhysicalRect = floatingRect // Animate from the floating position
                        guard let workspace = container.nodeWorkspace else { return .fail(io.err(bugPrompt())) }
                        if window.restoreTilingPosition(on: workspace) { return .succ }
                        do {
                            try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
                        } catch {
                            return .fail(io.err(bugPrompt()))
                        }
                        return .succ
                }
            case .floating:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                let workspace = target.workspace
                window.rememberTilingPosition()
                window.bindAsFloatingWindow(to: workspace)
                if let size = window.lastFloatingSize {
                    if let prevRect = window.lastAppliedLayoutPhysicalRect {
                        let target = Rect(topLeftX: prevRect.topLeftX, topLeftY: prevRect.topLeftY, width: size.width, height: size.height)
                        WindowAnimator.shared.setFrame(window, from: prevRect, to: target)
                    } else {
                        window.setAxFrame(nil, size)
                    }
                }
                return .succ
        }
    }
}

@MainActor private func changeTilingLayout(
    _ io: CmdIo,
    targetOrientation: Orientation?,
    node: ConventionalWindowParentCases,
) -> BinaryExitCode {
    switch node {
        case .floatingWindowsContainer:
            return .fail(io.err("The window is non-tiling"))
        case .tilingContainer(let parent):
            parent.changeOrientation(targetOrientation ?? parent.orientation)
            return .succ
    }
}

extension ConventionalWindowParentCases {
    fileprivate func matchesDescription(_ layout: LayoutCmdArgs.LayoutDescription) -> Bool {
        return switch layout {
            case .tiles, .tiling:       tilingContainerOrNil != nil
            case .horizontal, .h_tiles: tilingContainerOrNil?.orientation == .h
            case .vertical, .v_tiles:   tilingContainerOrNil?.orientation == .v
            case .floating:             floatingWindowsContainerOrNil != nil
        }
    }
}
