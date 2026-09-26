// Trace: passive observer. Samples the WindowServer bounds of the given windows (CGWindowList, no screen capture) at
// every vsync, and prints every frame where something changed, with the uncovered ranges ("GAPS") along one axis.
// It doesn't write anything, so it can watch real AeroSpace animations. See README.md next to this file.
//
// Usage: trace <windowId,windowId,...|all> <seconds> [h|v]
//   all:         every on-screen window of the normal level, including windows that appear while tracing
//   h (default): x ranges across the monitors of the top row that contain a traced window. Only windows that are
//                nearly as tall as their monitor (tiles in a horizontal layout) count as covering. Trace all the tiles
//                of those monitors, otherwise the space of the untraced ones shows up as a gap.
//   v:           y ranges of the monitor with the most windows. Only windows that are nearly as wide as the monitor count.
import AppKit
import CoreVideo
import QuartzCore

func windowIdArray(_ ids: [CGWindowID]) -> CFArray {
    var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    return CFArrayCreate(nil, &pointers, ids.count, nil)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: trace <windowId,windowId,...> <seconds> [h|v]")
    exit(1)
}
let traceAll = args[1] == "all"
var ids = args[1].split(separator: ",").compactMap { CGWindowID($0) }
let seconds = Double(args[2]) ?? 1
let vertical = args.count > 3 && args[3] == "v"
_ = NSApplication.shared

// Screens in the top-left coordinates of CGWindowList
let mainHeight = NSScreen.screens[0].frame.height
func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
let screens = NSScreen.screens.map { (frame: topLeft($0.frame), visible: topLeft($0.visibleFrame), screen: $0) }

func bounds(_ ids: [CGWindowID]) -> [CGWindowID: CGRect] {
    guard let list = CGWindowListCreateDescriptionFromArray(windowIdArray(ids)) as? [[String: Any]] else { return [:] }
    var result: [CGWindowID: CGRect] = [:]
    for info in list {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { continue }
        result[id] = rect
    }
    return result
}

func allOnScreen() -> [CGWindowID: CGRect] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
    var result: [CGWindowID: CGRect] = [:]
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { continue }
        result[id] = rect
    }
    return result
}
func sample() -> [CGWindowID: CGRect] { traceAll ? allOnScreen() : bounds(ids) }
if traceAll { ids = allOnScreen().keys.sorted() }

// The monitors to watch and the range of the axis they cover
typealias Screen = (frame: CGRect, visible: CGRect, screen: NSScreen)
let initial = bounds(ids)
func windowCount(_ screen: Screen) -> Int {
    initial.values.count { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }
}
let watched: [Screen] = vertical
    ? [screens.max { windowCount($0) < windowCount($1) }!]
    : screens.filter { $0.frame.minY == screens[0].frame.minY && windowCount($0) > 0 }
let lo = vertical ? watched[0].visible.minY : watched.map { $0.frame.minX }.min()!
let hi = vertical ? watched[0].visible.maxY : watched.map { $0.frame.maxX }.max()!
func start(_ r: CGRect) -> CGFloat { vertical ? r.minY : r.minX }
func end(_ r: CGRect) -> CGFloat { vertical ? r.maxY : r.maxX }
/// Tiles: windows that span (nearly) the whole visible cross-axis of their monitor. A floating window doesn't count
func isTile(_ r: CGRect) -> Bool {
    guard let monitor = watched.first(where: { $0.frame.intersects(r) }) else { return false }
    return vertical ? r.width > monitor.visible.width * 0.9 : r.height > monitor.visible.height * 0.9
}

var frames: [[CGWindowID: CGRect]] = []
var times: [CFTimeInterval] = [] // CACurrentMediaTime() of each sample
let lock = NSLock()
var link: CVDisplayLink?
let fastest = screens.max { $0.screen.maximumFramesPerSecond < $1.screen.maximumFramesPerSecond }!.screen
let displayId = fastest.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
CVDisplayLinkCreateWithCGDisplay(displayId, &link)
CVDisplayLinkSetOutputHandler(link!) { _, _, _, _, _ in
    let bounds = sample()
    let time = CACurrentMediaTime()
    lock.lock()
    frames.append(bounds)
    times.append(time)
    lock.unlock()
    return kCVReturnSuccess
}
CVDisplayLinkStart(link!)
Thread.sleep(forTimeInterval: seconds)
CVDisplayLinkStop(link!)

lock.lock()
if traceAll { ids = Array(Set(frames.flatMap(\.keys))).sorted() } // including the windows that appeared
print(String(format: "axis=%@ range=%.0f..%.0f fps=%d frames=%d", vertical ? "v" : "h", lo, hi, fastest.maximumFramesPerSecond, frames.count))
var previous: [CGWindowID: CGRect]? = nil
var unchanged = 0
for (index, frame) in frames.enumerated() {
    if frame == previous {
        unchanged += 1
        if unchanged == 1 { print("   ...") }
        continue
    }
    unchanged = 0
    previous = frame
    let intervals = frame.values.filter(isTile).map { (max(start($0), lo), min(end($0), hi)) }.sorted { $0.0 < $1.0 }
    var gaps: [String] = []
    var covered = lo
    for (a, b) in intervals {
        if a > covered + 1 { gaps.append(String(format: "%.0f-%.0f(%.0f)", covered, a, a - covered)) }
        covered = max(covered, b)
    }
    if hi > covered + 1 { gaps.append(String(format: "%.0f-%.0f(%.0f)", covered, hi, hi - covered)) }
    let windows = ids.map { id in
        frame[id].map { String(format: "%d:[%.0f..%.0f]%@", id, start($0), end($0), isTile($0) ? "" : "F") } ?? "\(id):-"
    }
    print(String(format: "f%03d %@  GAPS: %@", index, windows.joined(separator: " "), gaps.isEmpty ? "none" : gaps.joined(separator: " ")))
}
printStats()
lock.unlock()

// ---- Machine-readable summary (benchmark.sh, report.sh) ----
//
// STATS line:
//   anim_ms       from the first to the last change of any window
//   ft_p50/p95/max  frame time: interval between consecutive changes of a moving window, pooled over the windows (ms)
//   dropped       vsyncs without a change while a window was still visibly moving: an interval of k vsyncs followed by a
//                 step of >= 2pt counts k-1. The sub-point tail of the easing doesn't count
//   gap_max       largest uncovered square (pt) on a watched monitor in any frame, minus the same in the settled first
//                 and last frames (the configured gaps). "Uncovered" is 2D: the monitor's visible frame minus every traced
//                 window, each clipped to the monitor that shows it (the one with most of it when Spaces are separate)
//   gap_frames    frames with gap >= 2pt
//   mon_flips     most times one window's majority monitor changed (1 for a move between monitors, more is a bounce)
//   wrong_mon     frames where a window was mostly on a monitor that is neither where it started nor where it ended
//   max_step      largest move of any edge between two consecutive frames (pt), for windows on a monitor in both. A
//                 window that jumps instead of sliding shows the whole distance here
//   trace_missed  vsyncs the tracer itself missed (the measurement is less precise if > 0)
// FT line: every frame time (ms), for pooling across repetitions
func printStats() {
    let period = 1.0 / Double(fastest.maximumFramesPerSecond)
    let separateSpaces = NSScreen.screensHaveSeparateSpaces
    guard let first = frames.first, let last = frames.last else { print("STATS none"); return }

    func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }
    func majorityMonitor(_ r: CGRect) -> Int? {
        let areas = screens.map { overlapArea($0.frame, r) }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }
    // Side of the largest square of the monitor's visible frame that no window covers
    func largestUncoveredSquare(_ monitor: Int, _ frame: [CGWindowID: CGRect]) -> CGFloat {
        let area = screens[monitor].visible
        let covering = frame.values
            .filter { !separateSpaces || majorityMonitor($0) == monitor }
            .map { $0.intersection(area) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let xs = Array(Set([area.minX, area.maxX] + covering.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([area.minY, area.maxY] + covering.flatMap { [$0.minY, $0.maxY] })).sorted()
        let nx = xs.count - 1, ny = ys.count - 1
        // prefix[j][i]: covered cells in the compressed grid above and left of (i, j)
        var prefix = Array(repeating: Array(repeating: 0, count: nx + 1), count: ny + 1)
        for j in 0 ..< ny {
            for i in 0 ..< nx {
                let center = CGPoint(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2)
                let covered = covering.contains { $0.contains(center) } ? 1 : 0
                prefix[j + 1][i + 1] = covered + prefix[j][i + 1] + prefix[j + 1][i] - prefix[j][i]
            }
        }
        var best: CGFloat = 0
        for x0 in 0 ..< nx {
            for x1 in x0 + 1 ... nx where xs[x1] - xs[x0] > best {
                for y0 in 0 ..< ny {
                    for y1 in y0 + 1 ... ny {
                        let side = min(xs[x1] - xs[x0], ys[y1] - ys[y0])
                        if side <= best { continue }
                        let covered = prefix[y1][x1] - prefix[y0][x1] - prefix[y1][x0] + prefix[y0][x0]
                        if covered > 0 { break } // taller intervals contain this one
                        best = side
                    }
                }
            }
        }
        return best
    }

    // Frame times and dropped frames, per window
    var frameTimes: [Double] = []
    var dropped = 0
    var firstChange: Int? = nil
    var lastChange: Int? = nil
    var maxStep: CGFloat = 0
    var monFlips = 0
    var wrongMon = 0
    for id in ids {
        var previousChange: Int? = nil
        for index in 1 ..< frames.count {
            guard let now = frames[index][id], let before = frames[index - 1][id], now != before else { continue }
            let step = max(abs(now.minX - before.minX), abs(now.maxX - before.maxX), abs(now.minY - before.minY), abs(now.maxY - before.maxY))
            // A window that appears or hides (workspace switch) jumps by design; count the steps of windows on screen
            if majorityMonitor(now) != nil && majorityMonitor(before) != nil { maxStep = max(maxStep, step) }
            firstChange = min(firstChange ?? index, index)
            lastChange = max(lastChange ?? index, index)
            if let previousChange {
                let dt = times[index] - times[previousChange]
                frameTimes.append(dt * 1000)
                let vsyncs = Int((dt / period).rounded())
                if vsyncs > 1 && step >= 2 { dropped += vsyncs - 1 }
            }
            previousChange = index
        }
        // Monitors
        let monitors = frames.map { $0[id].flatMap(majorityMonitor) }
        let startMon = first[id].flatMap(majorityMonitor)
        let endMon = last[id].flatMap(majorityMonitor)
        var flips = 0
        for index in 1 ..< monitors.count where monitors[index] != nil && monitors[index - 1] != nil && monitors[index] != monitors[index - 1] {
            flips += 1
        }
        monFlips = max(monFlips, flips)
        wrongMon += monitors.count { $0 != nil && $0 != startMon && $0 != endMon }
    }

    // Gaps on the monitors that have a traced window in the first or last frame
    var watchedMonitors = Set<Int>()
    for frame in [first, last] {
        for r in frame.values { if let m = majorityMonitor(r) { watchedMonitors.insert(m) } }
    }
    var gapMax: CGFloat = 0
    var gapFrames = 0
    let steady = Dictionary(uniqueKeysWithValues: watchedMonitors.map {
        ($0, max(largestUncoveredSquare($0, first), largestUncoveredSquare($0, last)))
    })
    var previous: [CGWindowID: CGRect]? = nil
    for frame in frames where frame != previous {
        previous = frame
        let gap = watchedMonitors.map { max(0, largestUncoveredSquare($0, frame) - steady[$0]!) }.max() ?? 0
        gapMax = max(gapMax, gap)
        if gap >= 2 { gapFrames += 1 }
    }

    var traceMissed = 0
    for index in 1 ..< max(1, times.count) {
        let vsyncs = Int(((times[index] - times[index - 1]) / period).rounded())
        if vsyncs > 1 { traceMissed += vsyncs - 1 }
    }

    frameTimes.sort()
    func percentile(_ p: Double) -> Double {
        frameTimes.isEmpty ? 0 : frameTimes[min(frameTimes.count - 1, Int((Double(frameTimes.count - 1) * p).rounded()))]
    }
    let animMs = firstChange.flatMap { a in lastChange.map { b in (times[b] - times[a]) * 1000 } } ?? 0
    print(String(
        format: "STATS anim_ms=%.1f changes=%d ft_p50=%.2f ft_p95=%.2f ft_max=%.2f dropped=%d gap_max=%.0f gap_frames=%d mon_flips=%d wrong_mon=%d max_step=%.0f trace_missed=%d",
        animMs, frameTimes.count, percentile(0.5), percentile(0.95), frameTimes.last ?? 0, dropped, gapMax, gapFrames, monFlips, wrongMon, maxStep, traceMissed,
    ))
    print("FT " + frameTimes.map { String(format: "%.2f", $0) }.joined(separator: ","))
}
