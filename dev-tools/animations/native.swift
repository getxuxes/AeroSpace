// native: how does macOS animate its own window tiling (Window > Move & Resize)? Presses a menu item of the window's app
// over AX, then for ~1s records, at every vsync, the window's WindowServer bounds (CGWindowList) and, with
// ScreenCaptureKit, the size of the window's content buffer. If the bounds change every frame while the buffer size
// changes rarely, the compositor scales the old content; if the buffer follows the bounds, the app redraws every step.
//
// Needs Accessibility (to press the menu) and Screen Recording (ScreenCaptureKit). Run `aerospace enable off` first.
// Usage: native <windowId> "<Menu>/<Item>/<Subitem>"      e.g. native 1234 "Window/Move & Resize/Left"
import AppKit
import ApplicationServices
import CoreVideo
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let args = CommandLine.arguments
guard args.count == 3, let wid = CGWindowID(args[1]) else { print("Usage: native <windowId> \"Menu/Item/Subitem\""); exit(1) }
let menuPath = args[2].split(separator: "/").map(String.init)
_ = NSApplication.shared

func wsBounds() -> CGRect? {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(wid))
    guard let arr = CGWindowListCreateDescriptionFromArray(CFArrayCreate(nil, &ptr, 1, nil)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: b)
}
guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first,
      let pid = info[kCGWindowOwnerPID as String] as? pid_t else { print("window \(wid) not found"); exit(1) }
let appName = info[kCGWindowOwnerName as String] as? String ?? "?"
let axApp = AXUIElementCreateApplication(pid)

func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}
func title(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &v)
    return (v as? String) ?? ""
}
/// Menu bar > "Window" > (menu) > "Move & Resize" > (menu) > "Left"
func findMenuItem(_ path: [String]) -> AXUIElement? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &v)
    guard var current = v.map({ $0 as! AXUIElement }) else { return nil }
    for name in path {
        let candidates = children(current).flatMap { title($0).isEmpty ? children($0) : [$0] }
        guard let next = candidates.first(where: { title($0) == name }) else {
            print("menu item '\(name)' not found; there are: \(candidates.map(title).filter { !$0.isEmpty })")
            return nil
        }
        current = next
    }
    return current
}

// Make the window the app's main one and the app active, so the menu command applies to it
var windowsValue: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
for w in (windowsValue as? [AXUIElement]) ?? [] {
    var id: CGWindowID = 0
    if _AXUIElementGetWindow(w, &id) == .success, id == wid {
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }
}
NSRunningApplication(processIdentifier: pid)?.activate()
usleep(400_000)
guard let item = findMenuItem(menuPath) else { exit(1) }

// Content buffer sizes from ScreenCaptureKit, with their arrival time
final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var sizes: [(time: Double, width: Int, height: Int)] = []
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete, // .idle: nothing changed
              let rectDict = info[.contentRect] as? NSDictionary,
              let contentRect = CGRect(dictionaryRepresentation: rectDict)
        else { return }
        // The window's own surface, in points: the content rect in the (scaled) output buffer, divided by the scale that
        // ScreenCaptureKit applied to fit it and by the display's pixels per point
        let contentScale = (info[.contentScale] as? CGFloat) ?? 1
        let pixelsPerPoint = (info[.scaleFactor] as? CGFloat) ?? 1
        let w = Int((contentRect.width / contentScale / pixelsPerPoint).rounded())
        let h = Int((contentRect.height / contentScale / pixelsPerPoint).rounded())
        lock.withLock { sizes.append((CACurrentMediaTime(), w, h)) }
    }
}
let capture = Capture()
var stream: SCStream? = nil
let captureReady = DispatchSemaphore(value: 0)
Task {
    defer { captureReady.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == wid }) else { print("ScreenCaptureKit: window not shareable"); return }
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 144)
        config.width = 4096; config.height = 4096 // the buffer follows the window; this is only the upper bound
        config.queueDepth = 8
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try s.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        try await s.startCapture()
        stream = s
    } catch {
        print("ScreenCaptureKit unavailable (Screen Recording permission?): \(error)")
    }
}
captureReady.wait()
usleep(200_000)

// WindowServer bounds at every vsync
var samples: [(time: Double, rect: CGRect)] = []
let lock = NSLock()
var link: CVDisplayLink?
CVDisplayLinkCreateWithActiveCGDisplays(&link)
CVDisplayLinkSetOutputHandler(link!) { _, _, _, _, _ in
    if let r = wsBounds() { let t = CACurrentMediaTime(); lock.withLock { samples.append((t, r)) } }
    return kCVReturnSuccess
}
CVDisplayLinkStart(link!)
usleep(100_000)
let pressedAt = CACurrentMediaTime()
let pressError = AXUIElementPerformAction(item, kAXPressAction as CFString)
usleep(1_000_000)
CVDisplayLinkStop(link!)
let stopped = DispatchSemaphore(value: 0)
Task { try? await stream?.stopCapture(); stopped.signal() }
stopped.wait()

lock.lock()
let changes = zip(samples.dropFirst(), samples).filter { $0.0.rect != $0.1.rect }.map(\.0)
let first = samples.first!.rect, last = samples.last!.rect
print("app=\(appName) window=\(wid) menu=\(menuPath.joined(separator: " > ")) press=\(pressError.rawValue)")
print("bounds \(first) -> \(last)")
guard let start = changes.first, let end = changes.last else { print("RESULT the window didn't move"); exit(0) }
let sizes = Set(changes.map { "\(Int($0.rect.width))x\(Int($0.rect.height))" })
print(String(format: "latency press->first change %.1fms, duration first->last change %.1fms, frames with a change %d, distinct sizes %d",
             (start.time - pressedAt) * 1000, (end.time - start.time) * 1000, changes.count, sizes.count))
// The curve: progress of the left edge (or width) per changed frame, against normalized time
let total = max(abs(last.minX - first.minX), abs(last.width - first.width), abs(last.minY - first.minY), abs(last.height - first.height))
print("curve (t 0..1 -> progress 0..1):")
for c in changes {
    let moved = max(abs(c.rect.minX - first.minX), abs(c.rect.width - first.width), abs(c.rect.minY - first.minY), abs(c.rect.height - first.height))
    let t = end.time > start.time ? (c.time - start.time) / (end.time - start.time) : 1
    print(String(format: "  %.3f %.3f  %@", t, total > 0 ? moved / total : 1, NSStringFromRect(c.rect)))
}
capture.lock.lock()
let during = capture.sizes.filter { $0.time >= start.time - 0.02 && $0.time <= end.time + 0.05 }
let bufferSizes = Set(during.map { "\($0.width)x\($0.height)" })
print("window surface (points) per captured frame during the animation: \(during.count) frames, distinct sizes \(bufferSizes.count):")
print("  " + during.map { "\($0.width)x\($0.height)" }.joined(separator: " "))
print(bufferSizes.count <= 2 && sizes.count > 2
    ? "RESULT the WindowServer frame changes \(sizes.count) times while the surface keeps \(bufferSizes.count) size(s): macOS scales the content"
    : "RESULT surface sizes \(bufferSizes.count) vs frame sizes \(sizes.count): the app redraws at (about) every size")
