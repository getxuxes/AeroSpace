// Trace: passive observer. Samples the WindowServer bounds of the given windows (CGWindowList, no screen capture) at
// every vsync, and prints every frame where something changed, with the uncovered ranges ("GAPS") along one axis.
// It doesn't write anything, so it can watch real AeroSpace animations. See README.md next to this file.
//
// Usage: trace <windowId,windowId,...> <seconds> [h|v]
//   h (default): x ranges across the monitors of the top row that contain a traced window. Only windows that are
//                nearly as tall as their monitor (tiles in a horizontal layout) count as covering. Trace all the tiles
//                of those monitors, otherwise the space of the untraced ones shows up as a gap.
//   v:           y ranges of the monitor with the most windows. Only windows that are nearly as wide as the monitor count.
import AppKit
import CoreVideo

func windowIdArray(_ ids: [CGWindowID]) -> CFArray {
    var pointers: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    return CFArrayCreate(nil, &pointers, ids.count, nil)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: trace <windowId,windowId,...> <seconds> [h|v]")
    exit(1)
}
let ids = args[1].split(separator: ",").compactMap { CGWindowID($0) }
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
let lock = NSLock()
var link: CVDisplayLink?
let fastest = screens.max { $0.screen.maximumFramesPerSecond < $1.screen.maximumFramesPerSecond }!.screen
let displayId = fastest.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
CVDisplayLinkCreateWithCGDisplay(displayId, &link)
CVDisplayLinkSetOutputHandler(link!) { _, _, _, _, _ in
    let sample = bounds(ids)
    lock.lock()
    frames.append(sample)
    lock.unlock()
    return kCVReturnSuccess
}
CVDisplayLinkStart(link!)
Thread.sleep(forTimeInterval: seconds)
CVDisplayLinkStop(link!)

lock.lock()
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
lock.unlock()
