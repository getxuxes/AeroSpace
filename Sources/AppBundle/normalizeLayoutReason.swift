import AppKit

@MainActor
func normalizeLayoutReason() async throws {
    let onScreen = OnScreenWindows()
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, onScreen)
    }
    try await _normalizeLayoutReason(
        workspace: focus.workspace,
        windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self),
        onScreen,
    )
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], _ onScreen: OnScreenWindows) async throws {
    // The tile a background tab leaves, per app. The tab that becomes the selected one takes it
    var tabSlots: [pid_t: BindingData] = [:]
    var windowsToRestore: [(window: Window, prevParentKind: NonLeafTreeNodeKind)] = []
    var tabCounts: [UInt32: Int] = [:]
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        let isBackgroundTab = !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp
            ? try await isBackgroundNativeTab(window, among: windows, onScreen, &tabCounts)
            : false
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isBackgroundTab:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        let slot = window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                        if parent is TilingContainer { tabSlots[window.app.pid] = slot }
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp && !isBackgroundTab {
                    windowsToRestore.append((window, prevParentKind))
                }
        }
    }
    for (window, prevParentKind) in windowsToRestore {
        if prevParentKind == .tilingContainer, let slot = tabSlots.removeValue(forKey: window.app.pid), slot.parent.parent != nil {
            window.layoutReason = .standard
            window.bind(to: slot.parent, adaptiveWeight: slot.adaptiveWeight, index: min(slot.index, slot.parent.children.count))
        } else {
            try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
        }
    }
}

/// macOS native tabs (Finder, Ghostty, "Prefer tabs" in System Settings) are separate windows, but only the selected tab
/// is drawn. A window is a background tab if the window server doesn't draw it while another window of its app on the
/// same workspace is drawn and has a tab bar with several tabs. The second condition rules out windows that aren't drawn
/// for other reasons (not yet shown, on another macOS Space)
@MainActor
func isBackgroundNativeTab(
    _ window: Window,
    among windows: [Window],
    _ onScreen: OnScreenWindows,
    _ tabCounts: inout [UInt32: Int],
) async throws -> Bool {
    let otherWindowsOfApp = windows.filter { $0 !== window && $0.app.pid == window.app.pid }
    if otherWindowsOfApp.isEmpty || window.isOnScreen(onScreen.ids) { return false }
    for selectedTab in otherWindowsOfApp where selectedTab.isOnScreen(onScreen.ids) && !(selectedTab.parent is MacosFullscreenWindowsContainer) {
        let tabCount: Int
        if let cached = tabCounts[selectedTab.windowId] {
            tabCount = cached
        } else {
            tabCount = try await selectedTab.getNativeTabCount(.cancellable)
            tabCounts[selectedTab.windowId] = tabCount
        }
        if tabCount > 1 { return true }
    }
    return false
}

/// Ids of the windows that the window server draws. Queried once per refresh, and only if needed
@MainActor
final class OnScreenWindows {
    lazy var ids: Set<UInt32> = {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value })
    }()
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
