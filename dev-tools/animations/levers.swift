// Levers: measures the AX primitives that decide the animation-smoothness design, per lever of the Phase 1 plan.
// Standalone, no SIP, public + AX APIs only. Reuses the scaffolding of probe.swift.
// See README.md next to this file.
//
// Usage: levers <windowId> <experiment> [screenIndex]
//   The terminal that runs it needs the Accessibility permission.
//   For animation-like experiments run `aerospace enable off` first and `aerospace enable on` afterwards.
//
// Experiments:
//   axframe   Is the private "AXFrame" attribute settable on this window? Try to write pos+size in one call. (Lever 1)
//   writedur  Duration of a setPos vs a setSize AX call, N times, p50/p95. App idle. (Levers 4, 5)
//   enhui     Cost of toggling AXEnhancedUserInterface, and hold-off-once vs toggle-per-write over an animation. (Lever 2)
//   settle    After one size write, how long until the WindowServer bounds reach the target. Per app. (Lever 4)
//   vsync     Jitter of a CVDisplayLink loop vs a usleep(1/fps) timer loop vs true vsync. No window needed. (Lever 3)
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
guard args.count >= 3 else { print("usage: levers <windowId> <experiment> [screenIndex]"); exit(1) }
let experiment = args[2]

// MARK: time
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func hostToSec(_ h: UInt64) -> Double { Double(h) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }
func now() -> Double { CACurrentMediaTime() }
func pctl(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let i = Int((Double(s.count - 1) * p).rounded())
    return s[i]
}
func stats(_ name: String, _ xs: [Double]) -> String {
    String(format: "%@ n=%d p50=%.2fms p95=%.2fms max=%.2fms", name, xs.count, pctl(xs, 0.5), pctl(xs, 0.95), xs.max() ?? .nan)
}

// MARK: WindowServer bounds
func wsBounds(_ wid: CGWindowID) -> CGRect? {
    guard let arr = CGWindowListCreateDescriptionFromArray(widArray(wid)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b) else { return nil }
    return r
}

// MARK: find AX window
func findAxWindow(_ wid: CGWindowID) -> (AXUIElement, AXUIElement, pid_t)? {
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

_ = NSApplication.shared // Without it, NSScreen.screensHaveSeparateSpaces always returns false

func setPos(_ w: AXUIElement, _ p: CGPoint) {
    var p = p
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}
func setSize(_ w: AXUIElement, _ s: CGSize) {
    var s = s
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
}
func axFrame(_ w: AXUIElement) -> CGRect {
    var pv: CFTypeRef?, sv: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv)
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv)
    var p = CGPoint.zero, s = CGSize.zero
    if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func sleepMs(_ ms: Double) { usleep(UInt32(ms * 1000)) }

switch experiment {
    case "vsync":
        // No window needed: compare a CVDisplayLink loop and a usleep(1/fps) timer loop against true vsync timestamps.
        let screenIndex = args.count > 3 ? Int(args[3])! : 0
        let screen = NSScreen.screens[screenIndex]
        let fps = screen.maximumFramesPerSecond
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        print("screen \(screenIndex) fps=\(fps) interval=\(String(format: "%.3f", 1000.0 / Double(fps)))ms")

        // 1) True vsync cadence from CVDisplayLink timestamps
        final class VLog: @unchecked Sendable { let l = NSLock(); var ts: [Double] = []; func add(_ t: Double) { l.lock(); ts.append(t); l.unlock() } }
        let vlog = VLog()
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithCGDisplay(displayId, &dl)
        CVDisplayLinkSetOutputHandler(dl!) { _, inNow, _, _, _ in vlog.add(hostToSec(inNow.pointee.hostTime)); return kCVReturnSuccess }
        CVDisplayLinkStart(dl!)
        sleepMs(1500)
        CVDisplayLinkStop(dl!)
        let vd = zip(vlog.ts.dropFirst(), vlog.ts).map { ($0 - $1) * 1000 }
        print(stats("true-vsync   inter-tick", vd))

        // 2) usleep(1/fps) timer loop (proxy for the current Task.sleep(for: 1/fps) animator tick)
        var timerTicks: [Double] = []
        let interval = 1.0 / Double(fps)
        var last = now()
        let tEnd = now() + 1.5
        while now() < tEnd { usleep(UInt32(interval * 1_000_000)); let t = now(); timerTicks.append((t - last) * 1000); last = t }
        print(stats("usleep-timer inter-tick", timerTicks))
        let ideal = 1000.0 / Double(fps)
        let missTimer = timerTicks.count(where: { $0 > ideal * 1.5 })
        print("usleep-timer frames >1.5x interval (dropped): \(missTimer)/\(timerTicks.count)")

        // 3) CVDisplayLink-driven loop: wake on each vsync (what a CADisplayLink-style animator would do)
        let cond = NSCondition(); var cnt = 0
        var dl2: CVDisplayLink?
        CVDisplayLinkCreateWithCGDisplay(displayId, &dl2)
        var cbTimes: [Double] = []
        var lastCb = now()
        CVDisplayLinkSetOutputHandler(dl2!) { _, _, _, _, _ in
            let t = now(); cbTimes.append((t - lastCb) * 1000); lastCb = t
            cond.lock(); cnt += 1; cond.broadcast(); cond.unlock(); return kCVReturnSuccess
        }
        lastCb = now(); CVDisplayLinkStart(dl2!); sleepMs(1500); CVDisplayLinkStop(dl2!)
        let cb = Array(cbTimes.dropFirst())
        print(stats("displaylink  inter-tick", cb))
        let missDl = cb.count(where: { $0 > ideal * 1.5 })
        print("displaylink frames >1.5x interval (dropped): \(missDl)/\(cb.count)")

    case "axframe":
        let wid = CGWindowID(args[1])!
        guard let (w, _, pid) = findAxWindow(wid) else { print("window not found"); exit(1) }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        AXUIElementSetMessagingTimeout(w, 2)
        var settable: DarwinBoolean = false
        let sErr = AXUIElementIsAttributeSettable(w, "AXFrame" as CFString, &settable)
        let before = axFrame(w)
        // Try writing AXFrame as a cgRect AXValue: move+grow by a known delta in one attribute write
        var target = CGRect(x: before.minX + 40, y: before.minY + 30, width: before.width + 60, height: before.height + 50)
        let wErr = AXUIElementSetAttributeValue(w, "AXFrame" as CFString, AXValueCreate(.cgRect, &target)!)
        sleepMs(250)
        let after = axFrame(w)
        let applied = abs(after.minX - target.minX) < 2 && abs(after.minY - target.minY) < 2 &&
            abs(after.width - target.width) < 2 && abs(after.height - target.height) < 2
        setSize(w, before.size); setPos(w, before.origin); setSize(w, before.size) // restore
        print("app=\(appName) pid=\(pid)")
        print("  IsAttributeSettable(AXFrame) err=\(sErr.rawValue) settable=\(settable.boolValue)")
        print("  SetAttributeValue(AXFrame) err=\(wErr.rawValue)")
        print("  target=\(target) after=\(after)")
        print("  => AXFrame WRITABLE: \(applied)")

    case "writedur":
        let wid = CGWindowID(args[1])!
        guard let (w, _, _) = findAxWindow(wid) else { print("window not found"); exit(1) }
        AXUIElementSetMessagingTimeout(w, 2)
        let base = axFrame(w)
        var posDur: [Double] = [], sizeDur: [Double] = []
        for i in 0 ..< 60 {
            let d: CGFloat = i % 2 == 0 ? 80 : 50
            var t = now(); setPos(w, CGPoint(x: base.minX - d, y: base.minY)); posDur.append((now() - t) * 1000)
            sleepMs(30)
            setPos(w, base.origin); sleepMs(30)
            t = now(); setSize(w, CGSize(width: base.width - d, height: base.height)); sizeDur.append((now() - t) * 1000)
            sleepMs(30)
            setSize(w, base.size); sleepMs(30)
        }
        setSize(w, base.size); setPos(w, base.origin); setSize(w, base.size)
        print(stats("setPos  call", posDur))
        print(stats("setSize call", sizeDur))

    case "enhui":
        let wid = CGWindowID(args[1])!
        guard let (w, app, _) = findAxWindow(wid) else { print("window not found"); exit(1) }
        AXUIElementSetMessagingTimeout(w, 2)
        // Cost of one get and one set of AXEnhancedUserInterface
        var getD: [Double] = [], setD: [Double] = []
        for _ in 0 ..< 40 {
            var v: CFTypeRef?
            var t = now(); AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &v); getD.append((now() - t) * 1000)
            t = now(); AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse); setD.append((now() - t) * 1000)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        print(stats("get AXEnhancedUserInterface", getD))
        print(stats("set AXEnhancedUserInterface", setD))
        // Per-frame cost: current (get+set false, write, set true) vs proposed (write only, toggled once outside)
        let base = axFrame(w)
        func writeFrame(_ f: CGRect) { setSize(w, f.size); setPos(w, f.origin); setSize(w, f.size) }
        var perFrameToggle: [Double] = [], perFrameHold: [Double] = []
        for i in 0 ..< 40 {
            let f = CGRect(x: base.minX - CGFloat(i % 10) * 4, y: base.minY, width: base.width - CGFloat(i % 10) * 4, height: base.height)
            var v: CFTypeRef?
            let t = now()
            AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &v)
            let wasOn = (v as? Bool) == true
            if wasOn { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            writeFrame(f)
            if wasOn { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            perFrameToggle.append((now() - t) * 1000)
            sleepMs(20)
        }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) // hold off once
        for i in 0 ..< 40 {
            let f = CGRect(x: base.minX - CGFloat(i % 10) * 4, y: base.minY, width: base.width - CGFloat(i % 10) * 4, height: base.height)
            let t = now(); writeFrame(f); perFrameHold.append((now() - t) * 1000)
            sleepMs(20)
        }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) // restore
        setSize(w, base.size); setPos(w, base.origin); setSize(w, base.size)
        print(stats("per-frame TOGGLE (get+setFalse+write+setTrue)", perFrameToggle))
        print(stats("per-frame HOLD   (write only)               ", perFrameHold))

    case "settle":
        let wid = CGWindowID(args[1])!
        guard let (w, app, _) = findAxWindow(wid) else { print("window not found"); exit(1) }
        AXUIElementSetMessagingTimeout(w, 2)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        let base = axFrame(w)
        var settle: [Double] = []
        for i in 0 ..< 30 {
            let target = CGSize(width: base.width - (i % 2 == 0 ? 200 : 120), height: base.height)
            setSize(w, base.size); sleepMs(120)
            let t = now()
            setSize(w, target)
            // Poll WS bounds until width reaches target (within 2pt) or 200ms timeout
            var reached = Double.nan
            while now() - t < 0.2 {
                if let b = wsBounds(wid), abs(b.width - target.width) < 2 { reached = (now() - t) * 1000; break }
                usleep(200)
            }
            settle.append(reached)
        }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        setSize(w, base.size); setPos(w, base.origin); setSize(w, base.size)
        let ok = settle.filter { !$0.isNaN }
        print(stats("size settle (write -> WS shows new width)", ok))
        print("timeouts(>200ms): \(settle.count(where: { $0.isNaN }))/\(settle.count)")

    default:
        print("unknown experiment. Use: axframe | writedur | enhui | settle | vsync")
}
