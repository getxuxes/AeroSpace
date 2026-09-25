import AppKit
import Common

struct MoveCommand: Command {
    let args: MoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        if await shouldFailBecauseFullscreen_nonCancellable(
            window: currentWindow,
            failIfFullscreen: args.failIfFullscreen,
            failIfMacosNativeFullscreen: args.failIfMacosNativeFullscreen,
        ) {
            return .fail
        }
        switch currentWindow.windowParentCases {
            case .unbound: return .fail
            case .tilingContainer(let parent):
                guard let indexOfCurrent = currentWindow.ownIndex else { return .fail(io.err(bugPrompt())) }
                let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
                if parent.orientation == direction.orientation && parent.children.indices.contains(indexOfSiblingTarget) {
                    switch parent.children[indexOfSiblingTarget].tilingTreeNodeCasesOrDie() {
                        case .tilingContainer(let topLevelSiblingTargetContainer):
                            return deepMoveIn(window: currentWindow, into: topLevelSiblingTargetContainer, moveDirection: direction, io)
                        case .window: // "swap windows"
                            let prevBinding = currentWindow.unbindFromParent()
                            currentWindow.bind(to: parent, adaptiveWeight: prevBinding.adaptiveWeight, index: indexOfSiblingTarget)
                            return .succ
                    }
                } else {
                    return moveOut(tilingWindow: currentWindow, direction: direction, io, args, env)
                }
            case .floatingWindowsContainer:
                return await moveFloatingWindowToMonitor(currentWindow, direction, io, args)
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err(moveOutMacosUnconventionalWindow))
            case .macosPopupWindowsContainer:
                return .fail(io.err(bugPrompt())) // Impossible
        }
    }
}

@MainActor private func hitWorkspaceBoundaries(
    _ window: Window,
    _ workspace: Workspace,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
    _ env: CmdEnv,
) -> BinaryExitCode {
    switch args.boundaries {
        case .workspace:
            switch args.boundariesAction {
                case .stop: return .succ
                case .fail: return .fail
                case .createImplicitContainer:
                    createImplicitContainerAndMoveWindow(window, workspace, direction)
                    return .succ
            }
        case .allMonitorsOuterFrame:
            guard let (monitors, index) = window.nodeMonitor?.findRelativeMonitor(inDirection: direction) else {
                return .fail(io.err("Should never happen. Can't find the current monitor"))
            }

            if monitors.indices.contains(index) {
                let moveNodeToMonitorArgs = MoveNodeToMonitorCmdArgs(target: .direction(direction))
                    .copy(\.windowId, window.windowId)
                    .copy(\.focusFollowsWindow, focus.windowOrNil == window)

                return MoveNodeToMonitorCommand(args: moveNodeToMonitorArgs).run(env, io)
            } else {
                return hitAllMonitorsOuterFrameBoundaries(window, workspace, args, direction)
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ window: Window,
    _ workspace: Workspace,
    _ args: MoveCmdArgs,
    _ direction: CardinalDirection,
) -> BinaryExitCode {
    switch args.boundariesAction {
        case .stop: return .succ
        case .fail: return .fail
        case .createImplicitContainer:
            createImplicitContainerAndMoveWindow(window, workspace, direction)
            return .succ
    }
}

/// Moves the floating window to the neighbor monitor, keeping its relative position and size
@MainActor private func moveFloatingWindowToMonitor(
    _ window: Window,
    _ direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
) async -> BinaryExitCode {
    guard args.boundaries == .allMonitorsOuterFrame else {
        return .fail(io.err("moving floating windows is only supported with --boundaries all-monitors-outer-frame"))
    }
    guard let sourceMonitor = window.nodeMonitor,
          let (monitors, index) = sourceMonitor.findRelativeMonitor(inDirection: direction)
    else {
        return .fail(io.err("Should never happen. Can't find the current monitor"))
    }
    guard let targetMonitor = monitors.getOrNil(atIndex: index) else {
        return switch args.boundariesAction {
            case .fail: .fail
            case .stop, .createImplicitContainer: .succ
        }
    }
    // If the window is still animating, map its final frame, not the intermediate one
    let axRect = WindowAnimator.shared.targetFrame(window.windowId) == nil ? try? await window.getAxRect(.nonCancellable) : nil
    let prevRect = WindowAnimator.shared.targetFrame(window.windowId) ?? axRect
    let result = moveWindowToWorkspace(
        window,
        targetMonitor.activeWorkspace,
        io,
        focusFollowsWindow: focus.windowOrNil == window,
        failIfNoop: false,
    )
    if let prevRect {
        let target = prevRect.mapped(
            from: sourceMonitor.visibleRectPaddedByOuterGaps,
            to: targetMonitor.visibleRectPaddedByOuterGaps,
        )
        WindowAnimator.shared.setFrame(window, from: axRect ?? prevRect, to: target)
    }
    return result
}

extension Rect {
    /// Keeps the relative position and size inside the areas
    fileprivate func mapped(from source: Rect, to target: Rect) -> Rect {
        let scaleX = source.width > 0 ? target.width / source.width : 1
        let scaleY = source.height > 0 ? target.height / source.height : 1
        let newWidth = min(width * scaleX, target.width)
        let newHeight = min(height * scaleY, target.height)
        return Rect(
            topLeftX: (target.minX + (topLeftX - source.minX) * scaleX).coerce(in: target.minX ... target.maxX - newWidth),
            topLeftY: (target.minY + (topLeftY - source.minY) * scaleY).coerce(in: target.minY ... target.maxY - newHeight),
            width: newWidth,
            height: newHeight,
        )
    }
}

private let moveOutMacosUnconventionalWindow = "moving macOS fullscreen, minimized windows and windows of hidden apps isn't yet supported. This behavior is subject to change"

@MainActor private func moveOut(
    tilingWindow window: Window,
    direction: CardinalDirection,
    _ io: CmdIo,
    _ args: MoveCmdArgs,
    _ env: CmdEnv,
) -> BinaryExitCode {
    let innerMostTilingContainer = window.parents.first(where: {
        return switch $0.parent?.cases {
            case .tilingContainer(let parent): parent.orientation == direction.orientation
            // Stop searching: we have hit the workspace
            case nil, .workspace: true
            // Impossible: tilingContainer's parent can only be a workspace or tilingContainer
            case .floatingWindowsContainer,
                 .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosPopupWindowsContainer: true
        }
    }) as? TilingContainer
    guard let innerMostTilingContainer else { return .fail(io.err(bugPrompt())) } // Impossible
    switch innerMostTilingContainer.tilingContainerParentCases {
        case .unbound: return .fail
        case .tilingContainer(let parent):
            check(parent.orientation == direction.orientation)
            guard let ownIndex = innerMostTilingContainer.ownIndex else { return .fail(io.err(bugPrompt())) }
            window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: ownIndex + direction.insertionOffset)
            return .succ
        case .workspace(let parent):
            return hitWorkspaceBoundaries(window, parent, io, args, direction, env)
    }
}

@MainActor private func createImplicitContainerAndMoveWindow(
    _ window: Window,
    _ workspace: Workspace,
    _ direction: CardinalDirection,
) {
    let prevRoot = workspace.rootTilingContainer
    prevRoot.unbindFromParent()
    // Force tiles layout
    _ = TilingContainer(parent: workspace, adaptiveWeight: WEIGHT_AUTO, direction.orientation, index: 0)
    check(prevRoot != workspace.rootTilingContainer)
    prevRoot.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: 0)
    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: direction.insertionOffset)
}

@MainActor private func deepMoveIn(window: Window, into container: TilingContainer, moveDirection: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
    let deepTarget = container.tilingTreeNodeCasesOrDie().findDeepMoveInTargetRecursive(moveDirection.orientation)
    switch deepTarget {
        case .tilingContainer(let deepTarget):
            window.bind(to: deepTarget, adaptiveWeight: WEIGHT_AUTO, index: 0)
        case .window(let deepTarget):
            guard let parent = deepTarget.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
            guard let deepTargetIndex = deepTarget.ownIndex else { return .fail(io.err(bugPrompt())) }
            window.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: deepTargetIndex + 1)
    }
    return .succ
}

extension TilingTreeNodeCases {
    @MainActor fileprivate func findDeepMoveInTargetRecursive(_ orientation: Orientation) -> TilingTreeNodeCases {
        switch self {
            case .window:
                self
            case .tilingContainer(let container) where container.orientation == orientation:
                .tilingContainer(container)
            case .tilingContainer(let container):
                container.mostRecentChild.orDie("Empty containers must be detached during normalization")
                    .tilingTreeNodeCasesOrDie()
                    .findDeepMoveInTargetRecursive(orientation)
        }
    }
}

func shouldFailBecauseFullscreen_nonCancellable(
    window: Window,
    failIfFullscreen: Bool,
    failIfMacosNativeFullscreen: Bool,
) async -> Bool {
    if failIfFullscreen && window.isFullscreen {
        return true
    }
    if failIfMacosNativeFullscreen {
        if true == (try? await window.isMacosFullscreen(.nonCancellable)) {
            return true
        }
    }
    return false
}
