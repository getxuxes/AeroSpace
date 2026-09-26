import AppKit
import Common
import Foundation

/// Holds `AXEnhancedUserInterface` **off** for the whole duration of an animation of an app's windows, instead of
/// toggling it around every single frame write (measured 1.7–3.4× cheaper p95 per frame, see dev-tools/animations).
///
/// - Reference-counted per app (the attribute is app-wide): the first window of an app that starts animating disables
///   it, the last one to finish restores it. Only apps where it was originally on are touched.
@MainActor
final class EnhancedUiHold {
    static let shared = EnhancedUiHold()
    private init() {}

    private struct AppState {
        let app: MacApp
        var windowIds: Set<UInt32> = []
        var disabled = false // we turned it off and owe a restore
        var pending = false // the disable request is in flight on the AX thread
    }
    private var byPid: [pid_t: AppState] = [:]

    /// A window of `app` started (or is continuing) an animation.
    func retain(_ app: MacApp, _ windowId: UInt32) {
        var state = byPid[app.pid] ?? AppState(app: app)
        let wasEmpty = state.windowIds.isEmpty
        state.windowIds.insert(windowId)
        byPid[app.pid] = state
        guard wasEmpty, !state.disabled, !state.pending else { return }
        byPid[app.pid]?.pending = true
        let pid = app.pid
        app.disableEnhancedUiForAnimation { [weak self] wasEnabled in
            guard let self else { return }
            guard var state = self.byPid[pid] else {
                // The animation ended before the disable landed. Make sure we don't leave the app off
                if wasEnabled { app.restoreEnhancedUiAfterAnimation() }
                return
            }
            state.pending = false
            if wasEnabled { state.disabled = true }
            self.byPid[pid] = state
            if state.windowIds.isEmpty { self.finish(pid) } // everything finished while we were disabling
        }
    }

    /// A window of `app` finished animating (completed, cancelled, or taken over by the mouse).
    func release(_ app: MacApp, _ windowId: UInt32) {
        guard var state = byPid[app.pid] else { return }
        state.windowIds.remove(windowId)
        byPid[app.pid] = state
        if state.windowIds.isEmpty && !state.pending { finish(app.pid) }
    }

    private func finish(_ pid: pid_t) {
        guard let state = byPid.removeValue(forKey: pid) else { return }
        if state.disabled { state.app.restoreEnhancedUiAfterAnimation() }
    }
}
