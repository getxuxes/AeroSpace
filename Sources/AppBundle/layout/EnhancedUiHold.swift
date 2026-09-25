import AppKit
import Common
import Foundation

/// Holds `AXEnhancedUserInterface` **off** for the whole duration of an animation of an app's windows, instead of
/// toggling it around every single frame write (measured 1.7–3.4× cheaper p95 per frame, see dev-tools/animations).
///
/// - Reference-counted per app (the attribute is app-wide): the first window of an app that starts animating disables
///   it, the last one to finish restores it. Only apps where it was originally on are touched.
/// - Crash-safe: every app we turn it off for is written to disk (`EnhancedUiRestoreStore`). If AeroSpace dies mid
///   animation without restoring, `restoreAllOnStartup()` puts every recorded app back on the next launch, so no app is
///   ever left with enhanced accessibility disabled.
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
                EnhancedUiRestoreStore.shared.remove(pid)
                return
            }
            state.pending = false
            if wasEnabled {
                state.disabled = true
                EnhancedUiRestoreStore.shared.add(pid: pid, bundleId: app.rawAppBundleId)
            }
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
        if state.disabled {
            state.app.restoreEnhancedUiAfterAnimation()
            EnhancedUiRestoreStore.shared.remove(pid)
        }
    }
}

/// The on-disk list of apps whose `AXEnhancedUserInterface` AeroSpace turned off and hasn't restored yet. Used only to
/// recover from a crash: on a clean animation end the entry is removed before the restore is even needed.
@MainActor
final class EnhancedUiRestoreStore {
    static let shared = EnhancedUiRestoreStore()

    private struct Record: Codable, Equatable {
        let pid: pid_t
        let bundleId: String?
    }
    private let url = URL(filePath: "/tmp/bobko.aerospace/enhanced-ui-restore.json")
    private var records: [Record] = []

    private init() {
        records = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    func add(pid: pid_t, bundleId: String?) {
        let record = Record(pid: pid, bundleId: bundleId)
        if !records.contains(record) {
            records.append(record)
            flush()
        }
    }

    func remove(_ pid: pid_t) {
        let before = records.count
        records.removeAll { $0.pid == pid }
        if records.count != before { flush() }
    }

    private func flush() {
        _ = Result {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
        }.getIgnoringErrorsOrNil()
    }

    /// Called once at startup, before any animation can run. Restores `AXEnhancedUserInterface` on every recorded app
    /// that is still running, then clears the list. A crash-safe net for a server that died mid animation.
    func restoreAllOnStartup() {
        defer { records = []; try? FileManager.default.removeItem(at: url) }
        let running = NSWorkspace.shared.runningApplications
        for record in records {
            let app = running.first { $0.processIdentifier == record.pid }
                ?? record.bundleId.flatMap { id in running.first { $0.bundleIdentifier == id } }
            guard let app, !app.isTerminated else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
