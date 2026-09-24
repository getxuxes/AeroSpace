import AppKit
import Common

/// Experimental. Animates tiled windows between their old and new layout frames. See `[animations]` in the config
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()
    private var animations: [UInt32: FrameAnimation] = [:]
    private var tickTask: Task<(), Never>? = nil

    private init() {}

    func setFrame(_ window: Window, from prevRect: Rect?, to target: Rect) {
        let settings = config.animations
        let now = CACurrentMediaTime()
        let running = animations[window.windowId]
        // The same command usually causes several layout passes. Don't restart the animation on every pass
        if let running, running.to.isClose(to: target) { return }
        guard settings.enabled, settings.durationMs > 0, let macWindow = window as? MacWindow,
              let from = running?.frame(at: now) ?? prevRect, !from.isClose(to: target)
        else {
            window.setAxFrame(target.topLeftCorner, target.size)
            return
        }
        animations[window.windowId] = FrameAnimation(
            window: macWindow,
            from: from,
            to: target,
            // Start one tick ahead. Otherwise, the first frame is sent at the start position and doesn't move anything
            startTime: now - frameInterval(target),
            duration: Double(settings.durationMs) / 1000,
            lastSentSize: running?.lastSentSize ?? from.size,
            stickOutLimit: stickOutLimit(
                from: from,
                to: target,
                monitors: monitorInfos.map(\.rect),
                separateSpaces: NSScreen.screensHaveSeparateSpaces,
            ),
            positionFirst: shrinksAtMonitorEdge(
                from: from,
                to: target,
                monitors: monitorInfos.map(\.rect),
                separateSpaces: NSScreen.screensHaveSeparateSpaces,
            ),
        )
        tick()
        startTickingIfNeeded()
    }

    /// The frame where the running animation ends, nil if the window isn't animating
    func targetFrame(_ windowId: UInt32) -> Rect? {
        animations[windowId]?.to
    }

    /// Called when somebody else sets the window frame directly. The last writer wins.
    /// Returns the size to restore if the animation left the window bigger than it looks
    func cancel(_ windowId: UInt32) -> CGSize? {
        guard let animation = animations.removeValue(forKey: windowId), animation.isSetUp, animation.sticksOut else { return nil }
        return animation.frame(at: CACurrentMediaTime()).size
    }

    private func startTickingIfNeeded() {
        if tickTask != nil { return }
        tickTask = Task.startUnstructured { @MainActor in
            while !self.animations.isEmpty {
                // Tick as often as the fastest screen with an animated window refreshes (60Hz, 120Hz, 144Hz, …)
                let interval = self.animations.values.map { frameInterval($0.to) }.min() ?? frameInterval(nil)
                try? await Task.sleep(for: .seconds(interval))
                self.tick()
            }
            self.tickTask = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        for (windowId, animation) in animations {
            if windowId == currentlyManipulatedWithMouseWindowId {
                animations.removeValue(forKey: windowId)
                continue
            }
            let isFinished = animation.progress(at: now) >= 1
            let frame = animation.frame(at: now)
            if !isFinished && !animation.isSetUp && animation.sticksOut {
                let size = animation.sizeToSend(frame)
                // Apps round the frame to whole points: 3 points are enough to stick out for sure
                let pushedTo = CGPoint(
                    x: animation.from.topLeftX + (animation.stickOutLimit.x != nil ? 3 : 0),
                    y: animation.from.topLeftY + (animation.stickOutLimit.y != nil ? 3 : 0),
                )
                animation.window.macApp.setAxFrameStickingOut(windowId, pushedTo: pushedTo, frame.topLeftCorner, size)
                animations[windowId]?.isSetUp = true
                animations[windowId]?.lastSentSize = size
                continue
            }
            let sizeToSend = isFinished ? frame.size : animation.sizeToSend(frame)
            // Resizing is expensive for apps (they have to re-layout). Don't resize if the size barely changed
            let sizeChanged = abs(sizeToSend.width - animation.lastSentSize.width) >= 1 || abs(sizeToSend.height - animation.lastSentSize.height) >= 1
            let size: CGSize? = isFinished || sizeChanged ? sizeToSend : nil
            animation.window.macApp.setAxFrameAnimated(windowId, frame.topLeftCorner, size, positionFirst: animation.positionFirst)
            if isFinished {
                animations.removeValue(forKey: windowId)
            } else if let size {
                animations[windowId]?.lastSentSize = size
            }
        }
    }
}

/// Refresh interval of the screen that contains the rect. Ticking that often doesn't flood apps with AX requests:
/// a not yet applied frame is cancelled by the next one in MacApp.setAxFrame
@MainActor
private func frameInterval(_ rect: Rect?) -> CFTimeInterval {
    let screen = rect.flatMap { rect in NSScreen.screens.first { $0.frame.monitorFrameNormalized().contains(rect.center) } }
    let fps = screen?.maximumFramesPerSecond ?? 60
    return 1.0 / Double(max(fps, 30))
}

private struct FrameAnimation {
    let window: MacWindow
    let from: Rect
    let to: Rect
    let startTime: CFTimeInterval
    let duration: CFTimeInterval
    var lastSentSize: CGSize
    let stickOutLimit: (x: CGFloat?, y: CGFloat?)
    let positionFirst: Bool
    var isSetUp = false

    var sticksOut: Bool { stickOutLimit.x != nil || stickOutLimit.y != nil }

    func progress(at time: CFTimeInterval) -> Double {
        duration <= 0 ? 1 : ((time - startTime) / duration).coerce(in: 0 ... 1)
    }

    func frame(at time: CFTimeInterval) -> Rect {
        let t = progress(at: time)
        let eased = 1 - pow(1 - t, 3) // ease-out cubic
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return Rect(
            topLeftX: lerp(from.topLeftX, to.topLeftX),
            topLeftY: lerp(from.topLeftY, to.topLeftY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height),
        )
    }

    /// A window that sticks out is bigger than it looks, then it only moves
    func sizeToSend(_ frame: Rect) -> CGSize {
        CGSize(
            width: stuckOutLength(visible: frame.width, target: to.width, lastSent: lastSentSize.width, limit: stickOutLimit.x),
            height: stuckOutLength(visible: frame.height, target: to.height, lastSent: lastSentSize.height, limit: stickOutLimit.y),
        )
    }
}

/// Moves reach the screen about a frame before the app redraws the new size. A window that grows to the left (or up)
/// would pull back its right (bottom) edge on every frame and uncover what is behind it. If that edge is at the edge of
/// the monitor, the window can be bigger than it looks and stick out of the monitor instead: then it mostly moves, and
/// moving doesn't need a redraw.
///
/// Returns how long the window can be, as a multiple of its visible width (height), nil if it can't stick out:
/// - `.infinity` if nothing is beyond the edge. The window takes its final size right away
/// - Less than 2 if another monitor is beyond the edge and monitors have separate Spaces. macOS doesn't show the part
///   that sticks out, but the window jumps to the other monitor if most of it is there
func stickOutLimit(from: Rect, to: Rect, monitors: [Rect], separateSpaces: Bool) -> (x: CGFloat?, y: CGFloat?) {
    func limit(_ stickingOut: Rect) -> CGFloat? {
        stickOutLimit(of: stickingOut, ownMonitor: monitors.first { $0.contains(to.center) }, monitors, separateSpaces)
    }
    let minY = min(from.minY, to.minY)
    let minX = min(from.minX, to.minX)
    // The window is never bigger than that while it sticks out
    let maxWidth = max(from.width, to.width)
    let maxHeight = max(from.height, to.height)
    let x = to.minX < from.minX - 0.5 && to.width > from.width + 0.5
        ? limit(Rect(
            topLeftX: min(from.maxX, to.maxX),
            topLeftY: minY,
            width: from.minX + to.width - min(from.maxX, to.maxX),
            height: max(from.minY, to.minY) + maxHeight - minY,
        ))
        : nil
    let y = to.minY < from.minY - 0.5 && to.height > from.height + 0.5
        ? limit(Rect(
            topLeftX: minX,
            topLeftY: min(from.maxY, to.maxY),
            width: max(from.minX, to.minX) + maxWidth - minX,
            height: from.minY + to.height - min(from.maxY, to.maxY),
        ))
        : nil
    return (x, y)
}

/// A window that shrinks from the left (top) while its right (bottom) edge stays at the edge of the monitor. The resize
/// reaches the screen before the move, so that edge would go back for a frame. Moving first makes the window stick out
/// by the distance of one frame instead. The window still resizes on every frame, like the others
func shrinksAtMonitorEdge(from: Rect, to: Rect, monitors: [Rect], separateSpaces: Bool) -> Bool {
    let ownMonitor = monitors.first { $0.contains(to.center) }
    // Where the window is after the move and before the resize
    let movedFirst = Rect(topLeftX: to.minX, topLeftY: to.minY, width: from.width, height: from.height)
    let x = to.minX > from.minX + 0.5 && to.width < from.width - 0.5 &&
        stickOutLimit(of: movedFirst.copy(\.topLeftX, to.maxX).copy(\.width, movedFirst.maxX - to.maxX), ownMonitor: ownMonitor, monitors, separateSpaces) != nil
    let y = to.minY > from.minY + 0.5 && to.height < from.height - 0.5 &&
        stickOutLimit(of: movedFirst.copy(\.topLeftY, to.maxY).copy(\.height, movedFirst.maxY - to.maxY), ownMonitor: ownMonitor, monitors, separateSpaces) != nil
    return x || y
}

/// See stickOutLimit(from:to:monitors:separateSpaces:)
private func stickOutLimit(of stickingOut: Rect, ownMonitor: Rect?, _ monitors: [Rect], _ separateSpaces: Bool) -> CGFloat? {
    let covered = monitors.filter { $0.overlaps(stickingOut) }
    if covered.isEmpty { return .infinity }
    if ownMonitor.map({ $0.overlaps(stickingOut) }) != false { return nil }
    // Leave room for the resize that reaches the screen a frame before the move
    return separateSpaces ? 1.7 : nil
}

/// Resizes only when the part that sticks out gets short: the app redraws on every resize
func stuckOutLength(visible: CGFloat, target: CGFloat, lastSent: CGFloat, limit: CGFloat?) -> CGFloat {
    guard let limit else { return visible }
    if lastSent >= min(target, visible * min(limit, 1.4)) { return lastSent }
    return min(target, visible * limit)
}

extension Rect {
    fileprivate func isClose(to other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 0.5 && abs(topLeftY - other.topLeftY) < 0.5 &&
            abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }

    fileprivate func overlaps(_ other: Rect) -> Bool {
        min(maxX, other.maxX) - max(minX, other.minX) > 0.5 && min(maxY, other.maxY) - max(minY, other.minY) > 0.5
    }
}
