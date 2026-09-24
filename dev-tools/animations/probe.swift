// Probe: writes a window frame over AX in a controlled way and samples the WindowServer bounds of the window
// (CGWindowList, no screen capture) every ~0.2 ms, timed against the vsync of the screen (CVDisplayLink).
// See README.md next to this file.
//
// Usage: probe <windowId> <experiment> [screenIndex]
//   Run `aerospace enable off` first, otherwise AeroSpace fights the probe. `aerospace enable on` afterwards.
//   screenIndex is the index in NSScreen.screens (0 = main). Experiments use a region of that screen.
import AppKit
import ApplicationServices
import CoreVideo
import Foundation
import QuartzCore

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
func widArray(_ id: CGWindowID) -> CFArray {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
    return CFArrayCreate(nil, &ptr, 1, nil)
}

let args = CommandLine.arguments
let wid = CGWindowID(args[1])!
let experiment = args[2]

// MARK: time
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func hostToSec(_ h: UInt64) -> Double { Double(h) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
func now() -> Double { CACurrentMediaTime() }

// MARK: WindowServer bounds
func wsBounds() -> CGRect? {
    guard let arr = CGWindowListCreateDescriptionFromArray(widArray(wid)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b) else { return nil }
    return r
}

// MARK: find AX window
func findAxWindow() -> (AXUIElement, AXUIElement, pid_t)? {
    guard let info = (CGWindowListCreateDescriptionFromArray(widArray(wid)) as? [[String: Any]])?.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    for w in (value as? [AXUIElement]) ?? [] {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w, &id) == .success, id == wid { return (w, app, pid) }
    }
    return nil
}
guard let (axWin, axApp, _) = findAxWindow() else { print("window not found"); exit(1) }
AXUIElementSetMessagingTimeout(axWin, 1)
// AeroSpace disables it while it writes frames (see disableAnimations in MacApp.swift). Restored at the end
var enhancedUi: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, &enhancedUi)
AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
_ = NSApplication.shared // Without it, NSScreen.screensHaveSeparateSpaces always returns false

func setPos(_ p: CGPoint) {
    var p = p
    AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}
func setSize(_ s: CGSize) {
    var s = s
    AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}
func axFrame() -> CGRect {
    var pv: CFTypeRef?, sv: CFTypeRef?
    AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &pv)
    AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sv)
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func setFrameNow(_ r: CGRect) { setSize(r.size); setPos(r.origin); setSize(r.size) }

// MARK: event log
final class Log: @unchecked Sendable {
    let lock = NSLock()
    var vsyncs: [Double] = []
    var samples: [(Double, CGRect)] = []
    var marks: [(Double, String)] = []
    var sampling = false
    func vsync(_ t: Double) { lock.lock(); vsyncs.append(t); lock.unlock() }
    func sample(_ t: Double, _ r: CGRect) {
        lock.lock(); defer { lock.unlock() }
        if samples.last?.1 != r { samples.append((t, r)) }
    }
    func mark(_ s: String) { lock.lock(); marks.append((now(), s)); lock.unlock() }
    func reset() { lock.lock(); vsyncs = []; samples = []; marks = []; lock.unlock() }
    func snapshot() -> ([Double], [(Double, CGRect)], [(Double, String)]) {
        lock.lock(); defer { lock.unlock() }; return (vsyncs, samples, marks)
    }
}
let log = Log()

// Sampler thread
let sampler = Thread {
    while true {
        if log.sampling, let r = wsBounds() { log.sample(now(), r) }
        usleep(200)
    }
}
sampler.qualityOfService = .userInteractive
sampler.start()

// Vsync via CVDisplayLink
let vsyncCond = NSCondition()
var vsyncCount = 0
var displayLink: CVDisplayLink?
let screenIndex = args.count > 3 ? Int(args[3])! : 1
let screen = NSScreen.screens[screenIndex]
let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
CVDisplayLinkCreateWithCGDisplay(displayId, &displayLink)
CVDisplayLinkSetOutputHandler(displayLink!) { _, inNow, _, _, _ in
    log.vsync(hostToSec(inNow.pointee.hostTime))
    vsyncCond.lock(); vsyncCount += 1; vsyncCond.broadcast(); vsyncCond.unlock()
    return kCVReturnSuccess
}
CVDisplayLinkStart(displayLink!)
func waitVsync() {
    vsyncCond.lock(); let c = vsyncCount
    while vsyncCount == c { vsyncCond.wait() }
    vsyncCond.unlock()
}
func sleepMs(_ ms: Double) { usleep(UInt32(ms * 1000)) }

// Screen geometry in AX (top-left) coordinates. All screens here share y=0 top
let sf = screen.frame
let E = sf.maxX // outer right edge when screenIndex is the rightmost
let top: CGFloat = 60
let height: CGFloat = 1200
print("screen \(screenIndex): \(sf) fps=\(screen.maximumFramesPerSecond) E=\(E)")

func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let e = CGFloat(ease(t))
    return CGRect(x: a.minX + (b.minX - a.minX) * e, y: a.minY + (b.minY - a.minY) * e,
                  width: a.width + (b.width - a.width) * e, height: a.height + (b.height - a.height) * e)
}

// MARK: analysis
/// For an animation from `from` to `to` over [t0, t0+dur]: the WS right edge vs the ideal right edge at each vsync
func analyzeRightEdge(_ name: String, from: CGRect, to: CGRect, t0: Double, dur: Double) {
    let (vs, samples, _) = log.snapshot()
    var worstRetreat: CGFloat = 0, worstOvershoot: CGFloat = 0, retreatFrames = 0, frames = 0
    var line = ""
    for v in vs where v >= t0 && v <= t0 + dur + 0.05 {
        guard let s = samples.last(where: { $0.0 <= v })?.1 else { continue }
        frames += 1
        // The far edge must never be left of where it was, and never left of the target's far edge (it only grows here)
        let ideal = lerp(from, to, ((v - t0) / dur).clamped()).maxX
        let d = s.maxX - ideal
        let visibleMaxX = min(s.maxX, E) // the part beyond the outer screen edge isn't visible
        let retreat = min(ideal, E) - visibleMaxX
        if retreat > 1 { retreatFrames += 1 }
        worstRetreat = max(worstRetreat, retreat)
        worstOvershoot = max(worstOvershoot, d)
        line += String(format: " [x=%.0f w=%.0f r=%.0f ideal=%.0f]", s.minX, s.width, s.maxX, ideal)
    }
    print(String(format: "%@: frames=%d retreatFrames(>1pt)=%d worstRetreat=%.1f worstOvershoot=%.1f", name, frames, retreatFrames, worstRetreat, worstOvershoot))
    print("   " + line)
}

extension Double { func clamped() -> Double { min(max(self, 0), 1) } }

/// Runs an animation, calling `write(frameIndex, frame, prevFrame, isLast)` right after each vsync
func animate(from: CGRect, to: CGRect, durMs: Double, write: (Int, CGRect, CGRect, Bool) -> Void) -> Double {
    setFrameNow(from); sleepMs(150)
    log.reset(); log.sampling = true
    waitVsync()
    let t0 = now()
    var prev = from
    var i = 0
    while true {
        let t = now()
        let p = ((t - t0) / (durMs / 1000) + 1.0 / Double(screen.maximumFramesPerSecond) / (durMs / 1000)).clamped()
        let f = lerp(from, to, p)
        write(i, f, prev, p >= 1)
        prev = f
        i += 1
        if p >= 1 { break }
        waitVsync()
    }
    sleepMs(120)
    log.sampling = false
    return t0
}

// Scenarios
let growLeftEdge = (from: CGRect(x: sf.minX + sf.width / 2, y: top, width: sf.width / 2, height: height),
                    to: CGRect(x: sf.minX, y: top, width: sf.width, height: height))
let growLeftInterior = (from: CGRect(x: sf.minX + sf.width / 2, y: top, width: sf.width / 4, height: height),
                        to: CGRect(x: sf.minX, y: top, width: sf.width * 3 / 4, height: height))

let original = axFrame()
defer {
    setFrameNow(original)
    if let enhancedUi { AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, enhancedUi) }
}

switch experiment {
    case "E0": // baseline: the writes AeroSpace used before (size, pos, size every frame). Far edge retreat per vsync
        for (name, sc) in [("edge", growLeftEdge), ("interior", growLeftInterior)] {
            let t0 = animate(from: sc.from, to: sc.to, durMs: 120) { _, f, _, _ in setFrameNow(f) }
            analyzeRightEdge("E0 main \(name)", from: sc.from, to: sc.to, t0: t0, dur: 0.12)
        }
    case "E1": // where macOS trims a resize or a move
        let base = growLeftEdge.from
        setFrameNow(base); sleepMs(200)
        setSize(CGSize(width: base.width + 200, height: base.height)); sleepMs(200)
        print("E1a size past outer right edge: ax=\(axFrame()) ws=\(wsBounds()!)")
        setFrameNow(base); sleepMs(200)
        setPos(CGPoint(x: base.minX + 300, y: base.minY)); sleepMs(200)
        print("E1b pos past outer right edge:  ax=\(axFrame()) ws=\(wsBounds()!)")
        setSize(CGSize(width: base.width + 100, height: base.height)); sleepMs(200)
        print("E1c size while already overflowing: ax=\(axFrame()) ws=\(wsBounds()!)")
        setFrameNow(base); sleepMs(200)
        setSize(CGSize(width: base.width, height: 1440)); sleepMs(200)
        print("E1d size past bottom edge:       ax=\(axFrame()) ws=\(wsBounds()!)")
        setFrameNow(CGRect(x: base.minX, y: top, width: base.width, height: height)); sleepMs(200)
        setPos(CGPoint(x: base.minX, y: 600)); sleepMs(200)
        print("E1e pos past bottom edge:        ax=\(axFrame()) ws=\(wsBounds()!)")
        // Interior monitor edge: left edge of this screen touches the other monitor
        setFrameNow(CGRect(x: sf.minX, y: top, width: 1000, height: height)); sleepMs(200)
        setPos(CGPoint(x: sf.minX - 300, y: top)); sleepMs(200)
        print("E1f pos across into other monitor: ax=\(axFrame()) ws=\(wsBounds()!)")
    case "E1n": // push the window 1 (0.5) point past the edge, then set the final size: is it still trimmed?
        let (from, to) = growLeftEdge
        for nudge in [CGFloat(1), 0.5] {
            setFrameNow(from); sleepMs(200)
            setPos(CGPoint(x: from.minX + nudge, y: from.minY)); setSize(to.size); sleepMs(200)
            print("E1n nudge=\(nudge) then final size: ax=\(axFrame()) ws=\(wsBounds()!)")
        }
        // Bottom edge, grow-up analog
        let b = CGRect(x: from.minX, y: 700, width: from.width, height: 740)
        setFrameNow(b); sleepMs(200)
        setSize(CGSize(width: b.width, height: 900)); sleepMs(200)
        print("E1v size past bottom from inside: ax=\(axFrame()) ws=\(wsBounds()!)")
        setFrameNow(b); sleepMs(200)
        setPos(CGPoint(x: b.minX, y: b.minY + 1)); setSize(CGSize(width: b.width, height: 900)); sleepMs(200)
        print("E1v nudge then size past bottom: ax=\(axFrame()) ws=\(wsBounds()!)")
    case "E1i": // the same at an edge between two monitors. Use the screen whose right edge touches another monitor
        let (from, to) = growLeftEdge
        setFrameNow(from); sleepMs(250)
        setSize(to.size); sleepMs(250)
        print("E1i size, no push:      ax=\(axFrame()) ws=\(wsBounds()!)")
        for push in [CGFloat(1), 3] {
            setFrameNow(from); sleepMs(250)
            setPos(CGPoint(x: from.minX + push, y: from.minY)); setSize(to.size); sleepMs(250)
            print("E1i push=\(push) then size: ax=\(axFrame()) ws=\(wsBounds()!)")
        }
        // Half of the growth: the window stays mostly on its monitor
        let half = CGSize(width: from.width * 1.5, height: from.height)
        setFrameNow(from); sleepMs(250)
        setPos(CGPoint(x: from.minX + 3, y: from.minY)); setSize(half); sleepMs(250)
        print("E1i push=3 then 1.5x:   ax=\(axFrame()) ws=\(wsBounds()!)")
    case "VIS": // visual check by a human: after 8 s, sticks 1/3 and then 1/2 of the window into the monitor on the right
        let (from, _) = growLeftEdge
        setFrameNow(from); sleepMs(8000)
        print("A \(Date())"); setPos(CGPoint(x: from.minX + 3, y: from.minY)); setSize(CGSize(width: 1920, height: from.height)); sleepMs(4000)
        print("B \(Date())"); setSize(CGSize(width: 2560, height: from.height)); sleepMs(4000)
        print("done: ax=\(axFrame())")
    case "E2": // how long an isolated move / resize takes to reach the WindowServer, in ms and vsyncs
        let base = growLeftInterior.from
        for kind in ["pos", "size"] {
            var lat: [Double] = [], vsLat: [Int] = []
            for i in 0 ..< 20 {
                setFrameNow(base); sleepMs(100)
                log.reset(); log.sampling = true
                waitVsync()
                let t = now()
                let d: CGFloat = i % 2 == 0 ? 100 : 60
                if kind == "pos" { setPos(CGPoint(x: base.minX - d, y: base.minY)) } else { setSize(CGSize(width: base.width + d, height: base.height)) }
                sleepMs(80)
                log.sampling = false
                let (vs, samples, _) = log.snapshot()
                if let change = samples.first(where: { $0.0 > t && $0.1 != base }) {
                    lat.append((change.0 - t) * 1000)
                    vsLat.append(vs.count(where: { $0 > t && $0 <= change.0 }))
                }
            }
            print("E2 \(kind): latency ms=\(lat.map { String(format: "%.1f", $0) }) vsyncs=\(vsLat)")
        }
    case "E3": // pos and size from two threads at once: do they land together? (no)
        let base = growLeftInterior.from
        var same = 0, total = 0
        var details: [String] = []
        for _ in 0 ..< 20 {
            setFrameNow(base); sleepMs(100)
            log.reset(); log.sampling = true
            waitVsync()
            let target = CGRect(x: base.minX - 120, y: base.minY, width: base.width + 120, height: base.height)
            let g = DispatchGroup()
            DispatchQueue.global(qos: .userInteractive).async(group: g) { setPos(target.origin) }
            usleep(50)
            DispatchQueue.global(qos: .userInteractive).async(group: g) { setSize(target.size) }
            g.wait()
            sleepMs(80)
            log.sampling = false
            let (_, samples, _) = log.snapshot()
            let posT = samples.first { $0.1.minX == target.minX }?.0
            let sizeT = samples.first { $0.1.width == target.width }?.0
            total += 1
            if let posT, let sizeT {
                if abs(posT - sizeT) < 0.0003 { same += 1 }
                details.append(String(format: "%.1f", (sizeT - posT) * 1000))
            }
            let path = samples.map { String(format: "(%.0f,%.0f)", $0.1.minX, $0.1.width) }.joined(separator: " ")
            if total <= 3 { print("   path: \(path)") }
        }
        print("E3 coalesced: sameSample=\(same)/\(total) sizeAfterPos ms=\(details)")
    case "E4": // sticking-out setup (push, size, move back): does the in-between state survive a vsync? ("jump" arg: old approach)
        let from = growLeftEdge.from, to = growLeftEdge.to
        var ok = 0, durs: [String] = [], bad: [String] = []
        for i in 0 ..< 50 {
            setFrameNow(from); sleepMs(120)
            log.reset(); log.sampling = true
            waitVsync()
            let t0 = now()
            let jump = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "jump"
            if jump { setPos(to.origin) } else { setPos(CGPoint(x: from.minX + 3, y: from.minY)) }
            let t1 = now()
            setSize(to.size)
            let t2 = now()
            setPos(from.origin)
            let t3 = now()
            sleepMs(60)
            log.sampling = false
            let (vs, samples, _) = log.snapshot()
            // Intermediate: WS origin at P_final, i.e. the window is visibly shifted left with a gap on its right
            let inter = samples.filter { abs($0.1.minX - to.minX) < 1 }
            let interStart = inter.first?.0
            let interEnd = interStart.flatMap { s in samples.first { $0.0 > s && abs($0.1.minX - to.minX) >= 1 }?.0 }
            let crossed = interStart.map { s in vs.contains { $0 > s && $0 < (interEnd ?? .infinity) } } ?? false
            if !crossed { ok += 1 } else { bad.append("#\(i)") }
            durs.append(String(format: "%.1f/%.1f/%.1f", (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
            if i == 0 {
                print("   path: " + samples.map { String(format: "%.1fms(%.0f,%.0f)", ($0.0 - t0) * 1000, $0.1.minX, $0.1.width) }.joined(separator: " "))
                print("   vsyncs: " + vs.map { String(format: "%.1f", ($0 - t0) * 1000) }.joined(separator: " "))
                print("   final ax=\(axFrame()) ws=\(wsBounds()!)")
            }
        }
        print("E4 setup: noVsyncDuringIntermediate=\(ok)/50 bad=\(bad)")
        print("   call ms pos/size/pos: \(durs.prefix(15))")
    case "E5": // a whole grow-left animation sticking out, and the rejected "pipelined" alternative
        do {
            let (from, to) = growLeftEdge
            let t0 = animate(from: from, to: to, durMs: 120) { i, f, _, isLast in
                if i == 0 { setPos(CGPoint(x: from.minX + 3, y: from.minY)); setSize(to.size); setPos(f.origin) } else if isLast { setFrameNow(f) } else { setPos(f.origin) }
            }
            analyzeRightEdge("E5 overflow edge", from: from, to: to, t0: t0, dur: 0.12)
        }
        do {
            let (from, to) = growLeftInterior
            let t0 = animate(from: from, to: to, durMs: 120) { _, f, prev, isLast in
                if isLast { setPos(prev.origin); setFrameNow(f) } else { setPos(prev.origin); setSize(f.size) }
            }
            analyzeRightEdge("E5 pipelined interior", from: from, to: to, t0: t0, dur: 0.12)
        }
        do {
            let (from, to) = growLeftEdge
            let t0 = animate(from: from, to: to, durMs: 120) { _, f, prev, isLast in
                if isLast { setPos(prev.origin); setFrameNow(f) } else { setPos(prev.origin); setSize(f.size) }
            }
            analyzeRightEdge("E5 pipelined edge", from: from, to: to, t0: t0, dur: 0.12)
        }
    default: print("unknown experiment")
}
