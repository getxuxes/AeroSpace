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
        )
        tick()
        startTickingIfNeeded()
    }

    /// The frame where the running animation ends, nil if the window isn't animating
    func targetFrame(_ windowId: UInt32) -> Rect? {
        animations[windowId]?.to
    }

    /// Called when somebody else sets the window frame directly. The last writer wins
    func cancel(_ windowId: UInt32) {
        animations.removeValue(forKey: windowId)
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
            // Resizing is expensive for apps (they have to re-layout). Don't resize if the size barely changed
            let sizeChanged = abs(frame.width - animation.lastSentSize.width) >= 1 || abs(frame.height - animation.lastSentSize.height) >= 1
            let size: CGSize? = isFinished || sizeChanged ? frame.size : nil
            animation.window.macApp.setAxFrame(windowId, frame.topLeftCorner, size)
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
}

extension Rect {
    fileprivate func isClose(to other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 0.5 && abs(topLeftY - other.topLeftY) < 0.5 &&
            abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}
