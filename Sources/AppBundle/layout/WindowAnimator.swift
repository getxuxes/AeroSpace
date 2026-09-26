import AppKit
import Common

/// Experimental. Animates tiled windows between their old and new layout frames. See `[animations]` in the config
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()
    private var animations: [UInt32: FrameAnimation] = [:]
    /// One CADisplayLink per screen that has an animating window. Each fires on the main run loop at that screen's
    /// refresh rate and ticks only the windows on it, so writes are phase-locked to each monitor's vsync.
    private var displayLinks: [CGDirectDisplayID: (link: CADisplayLink, ticker: DisplayTicker)] = [:]
    /// Where each fullscreen window was laid out. A fullscreen window keeps lastAppliedLayoutPhysicalRect nil (other code
    /// reads it as the tile rect), so without this, leaving fullscreen would have no frame to animate from
    private var fullscreenFrames: [UInt32: Rect] = [:]

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
        let screen = NSScreen.screens.first { $0.frame.monitorFrameNormalized().contains(target.center) }
        let frameInterval = 1.0 / Double(max(screen?.maximumFramesPerSecond ?? 60, 30))
        animations[window.windowId] = FrameAnimation(
            window: macWindow,
            displayId: screen?.displayId ?? CGMainDisplayID(),
            from: from,
            to: target,
            // Start one tick ahead. Otherwise, the first frame is sent at the start position and doesn't move anything
            startTime: now - frameInterval,
            duration: Double(settings.durationMs) / 1000,
            curve: settings.curve,
            // An interrupted animation continues with the velocity it had (only the spring can take it)
            startVelocity: running?.velocity(at: now) ?? .zero,
            lastSentSize: running?.lastSentSize ?? from.size,
        )
        EnhancedUiHold.shared.retain(macWindow.macApp, window.windowId)
        step(window.windowId, at: now)
        reconcileDisplayLinks()
    }

    func setFullscreenFrame(_ window: Window, from prevRect: Rect?, to target: Rect) {
        fullscreenFrames[window.windowId] = target
        setFrame(window, from: prevRect, to: target)
    }

    /// The frame of a window that leaves fullscreen, to animate from. Nil if it wasn't fullscreen
    func takeFullscreenFrame(_ windowId: UInt32) -> Rect? {
        fullscreenFrames.removeValue(forKey: windowId)
    }

    /// The frame where the running animation ends, nil if the window isn't animating
    func targetFrame(_ windowId: UInt32) -> Rect? {
        animations[windowId]?.to
    }

    /// Called when somebody else sets the window frame directly. The last writer wins
    func cancel(_ windowId: UInt32) {
        guard let animation = animations.removeValue(forKey: windowId) else { return }
        EnhancedUiHold.shared.release(animation.window.macApp, windowId)
        reconcileDisplayLinks()
    }

    /// Fired by a screen's CADisplayLink on the main run loop. Ticks only the windows on that screen.
    fileprivate func displayTick(_ displayId: CGDirectDisplayID) {
        let now = CACurrentMediaTime()
        var anyEnded = false
        for (windowId, animation) in animations where animation.displayId == displayId {
            if !step(windowId, at: now) { anyEnded = true }
        }
        if anyEnded { reconcileDisplayLinks() }
    }

    /// Ensures exactly one running CADisplayLink per screen that currently has an animating window, and none for the rest.
    private func reconcileDisplayLinks() {
        var active = Set<CGDirectDisplayID>()
        for (_, animation) in animations { active.insert(animation.displayId) }
        for (id, entry) in displayLinks where !active.contains(id) {
            entry.link.invalidate()
            displayLinks.removeValue(forKey: id)
        }
        for id in active where displayLinks[id] == nil {
            guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else { continue }
            let ticker = DisplayTicker(displayId: id, animator: self)
            let link = screen.displayLink(target: ticker, selector: #selector(DisplayTicker.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLinks[id] = (link, ticker)
        }
    }

    /// Sends the window's frame for `time`. Returns false if the animation ended
    @discardableResult
    private func step(_ windowId: UInt32, at time: CFTimeInterval) -> Bool {
        guard let animation = animations[windowId] else { return false }
        if windowId == currentlyManipulatedWithMouseWindowId {
            animations.removeValue(forKey: windowId)
            EnhancedUiHold.shared.release(animation.window.macApp, windowId)
            return false
        }
        let isFinished = animation.isFinished(at: time)
        let frame = animation.frame(at: time)
        // Resizing is expensive for apps (they have to re-layout). Don't resize if the size barely changed
        let sizeChanged = abs(frame.width - animation.lastSentSize.width) >= 1 || abs(frame.height - animation.lastSentSize.height) >= 1
        let size: CGSize? = isFinished || sizeChanged ? frame.size : nil
        let grows = frame.width > animation.lastSentSize.width || frame.height > animation.lastSentSize.height
        animation.window.macApp.setAxFrameAnimated(windowId, frame.topLeftCorner, size, grows: grows, isLast: isFinished)
        if isFinished {
            animations.removeValue(forKey: windowId)
            EnhancedUiHold.shared.release(animation.window.macApp, windowId)
            return false
        }
        if let size { animations[windowId]?.lastSentSize = size }
        return true
    }
}

/// An @objc target for a screen's CADisplayLink. The link needs an NSObject target/selector, WindowAnimator is a plain
/// actor-isolated class. One per screen, carrying the screen's display id so the tick knows which windows to advance.
@MainActor
private final class DisplayTicker: NSObject {
    private let displayId: CGDirectDisplayID
    private weak var animator: WindowAnimator?
    init(displayId: CGDirectDisplayID, animator: WindowAnimator) {
        self.displayId = displayId
        self.animator = animator
    }
    @objc func tick(_: CADisplayLink) { animator?.displayTick(displayId) }
}

extension NSScreen {
    fileprivate var displayId: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private struct FrameAnimation {
    let window: MacWindow
    /// The screen whose display link ticks the animation: the one with the target frame
    let displayId: CGDirectDisplayID
    let from: Rect
    let to: Rect
    let startTime: CFTimeInterval
    let duration: CFTimeInterval
    let curve: AnimationCurve
    /// Points per second of (topLeftX, topLeftY, width, height)
    let startVelocity: RectVelocity
    var lastSentSize: CGSize

    func isFinished(at time: CFTimeInterval) -> Bool {
        switch curve {
            case .easeOut: easeOutProgress(at: time) >= 1
            case .spring: spring.isSettled(from: from, to: to, v0: startVelocity, time - startTime)
        }
    }

    func frame(at time: CFTimeInterval) -> Rect {
        switch curve {
            case .easeOut:
                let eased = 1 - pow(1 - easeOutProgress(at: time), 3) // ease-out cubic
                func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
                return Rect(
                    topLeftX: lerp(from.topLeftX, to.topLeftX),
                    topLeftY: lerp(from.topLeftY, to.topLeftY),
                    width: lerp(from.width, to.width),
                    height: lerp(from.height, to.height),
                )
            case .spring:
                return spring.frame(from: from, to: to, v0: startVelocity, time - startTime)
        }
    }

    /// The velocity of the frame, so that an animation that interrupts this one can start with it
    func velocity(at time: CFTimeInterval) -> RectVelocity {
        switch curve {
            case .easeOut:
                let t = easeOutProgress(at: time)
                if t >= 1 || duration <= 0 { return .zero }
                let speed = 3 * pow(1 - t, 2) / duration // d(eased)/dtime
                return RectVelocity(
                    x: (to.topLeftX - from.topLeftX) * speed,
                    y: (to.topLeftY - from.topLeftY) * speed,
                    width: (to.width - from.width) * speed,
                    height: (to.height - from.height) * speed,
                )
            case .spring:
                return spring.velocity(from: from, to: to, v0: startVelocity, time - startTime)
        }
    }

    private var spring: CriticallyDampedSpring { CriticallyDampedSpring(settleTime: duration) }

    private func easeOutProgress(at time: CFTimeInterval) -> Double {
        duration <= 0 ? 1 : ((time - startTime) / duration).coerce(in: 0 ... 1)
    }
}

struct RectVelocity: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    static let zero = RectVelocity(x: 0, y: 0, width: 0, height: 0)
}

/// x(t) = to + (x0 + (v0 + ωx0)·t)·e^(-ωt), x0 = from - to, per component: the fastest approach to the target without
/// oscillating. ω is picked so that a move from rest is within 1% of the distance after `settleTime` ((1 + ωt)e^(-ωt)
/// = 0.01 at ωt ≈ 6.64). Unlike a fixed-duration curve, it can start with any velocity, so interruptions don't jerk
struct CriticallyDampedSpring {
    let omega: Double

    init(settleTime: Double) { omega = 6.64 / max(settleTime, 0.001) }

    private func position(_ from: CGFloat, _ to: CGFloat, _ v0: CGFloat, _ t: Double) -> CGFloat {
        let x0 = Double(from - to)
        return to + CGFloat((x0 + (Double(v0) + omega * x0) * t) * exp(-omega * t))
    }

    private func speed(_ from: CGFloat, _ to: CGFloat, _ v0: CGFloat, _ t: Double) -> CGFloat {
        let x0 = Double(from - to)
        return CGFloat((Double(v0) - omega * (Double(v0) + omega * x0) * t) * exp(-omega * t))
    }

    func frame(from: Rect, to: Rect, v0: RectVelocity, _ t: Double) -> Rect {
        let t = max(0, t)
        return Rect(
            topLeftX: position(from.topLeftX, to.topLeftX, v0.x, t),
            topLeftY: position(from.topLeftY, to.topLeftY, v0.y, t),
            width: position(from.width, to.width, v0.width, t),
            height: position(from.height, to.height, v0.height, t),
        )
    }

    func velocity(from: Rect, to: Rect, v0: RectVelocity, _ t: Double) -> RectVelocity {
        let t = max(0, t)
        return RectVelocity(
            x: speed(from.topLeftX, to.topLeftX, v0.x, t),
            y: speed(from.topLeftY, to.topLeftY, v0.y, t),
            width: speed(from.width, to.width, v0.width, t),
            height: speed(from.height, to.height, v0.height, t),
        )
    }

    /// Within half a point of the target and moving less than half a point per 144Hz frame, or out of time
    func isSettled(from: Rect, to: Rect, v0: RectVelocity, _ t: Double) -> Bool {
        if t * omega >= 12 { return true } // e^-12: nothing left to see, whatever the start velocity
        let f = frame(from: from, to: to, v0: v0, t)
        let v = velocity(from: from, to: to, v0: v0, t)
        let offsets = [f.topLeftX - to.topLeftX, f.topLeftY - to.topLeftY, f.width - to.width, f.height - to.height]
        let speeds = [v.x, v.y, v.width, v.height]
        return offsets.allSatisfy { abs($0) < 0.5 } && speeds.allSatisfy { abs($0) < 0.5 * 144 }
    }
}

extension Rect {
    fileprivate func isClose(to other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) < 0.5 && abs(topLeftY - other.topLeftY) < 0.5 &&
            abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}
