// sls: can this process move another app's window through a WindowServer transaction (SkyLight, private API), with SIP
// on? Moves the window step by step at vsync, one transaction per step, and checks each step against the WindowServer
// (CGWindowList) and what the app itself reports over AX. Puts the window back over AX at the end.
//
// The idea (from OmniWM, which does this from its own process): SLSTransactionCreate + SLSTransactionMoveWindowWithGroup
// + SLSTransactionCommit. Written from scratch here; the signatures are the usual reverse-engineered ones.
//
// Usage: sls <windowId> <dx> [steps] [async|sync|direct]   (direct: SLSMoveWindow, no transaction) (run `aerospace enable off` first, or the window manager moves it back)
import AppKit
import ApplicationServices
import QuartzCore

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ e: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

typealias MainConnectionID = @convention(c) () -> Int32
typealias TransactionCreate = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
// The transaction calls don't return a status (what comes back is whatever is left in the register)
typealias TransactionMoveWindowWithGroup = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
typealias TransactionCommit = @convention(c) (CFTypeRef, Int32) -> Void
typealias MoveWindow = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32

guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
    print("SkyLight: dlopen failed"); exit(1)
}
func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(skyLight, name).map { unsafeBitCast($0, to: T.self) } }
guard let mainConnectionID = symbol("SLSMainConnectionID", MainConnectionID.self),
      let transactionCreate = symbol("SLSTransactionCreate", TransactionCreate.self),
      let moveWindowWithGroup = symbol("SLSTransactionMoveWindowWithGroup", TransactionMoveWindowWithGroup.self),
      let transactionCommit = symbol("SLSTransactionCommit", TransactionCommit.self),
      let moveWindow = symbol("SLSMoveWindow", MoveWindow.self)
else { print("SkyLight: a symbol is missing on this macOS"); exit(1) }

let args = CommandLine.arguments
guard args.count >= 3, let wid = CGWindowID(args[1]), let dx = Double(args[2]) else { print("Usage: sls <windowId> <dx> [steps]"); exit(1) }
let steps = args.count > 3 ? Int(args[3]) ?? 17 : 17
let mode = args.count > 4 ? args[4] : "async"
// A full app connection, like an app bundle's (in case the WindowServer treats a bare command line tool differently)
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.finishLaunching()

func wsBounds() -> CGRect? {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(wid))
    guard let arr = CGWindowListCreateDescriptionFromArray(CFArrayCreate(nil, &ptr, 1, nil)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: b)
}
func axWindow() -> (AXUIElement, String)? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    for w in (value as? [AXUIElement]) ?? [] {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(w, &id) == .success, id == wid { return (w, info[kCGWindowOwnerName as String] as? String ?? "?") }
    }
    return nil
}
func axPosition(_ w: AXUIElement) -> CGPoint {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &v)
    var p = CGPoint.zero
    if let v { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    return p
}

guard let start = wsBounds(), let (ax, appName) = axWindow() else { print("window \(wid) not found"); exit(1) }
let cid = mainConnectionID()
print("app=\(appName) window=\(wid) start=\(start) connection=\(cid) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

var commitMs: [Double] = []
var landed = 0
var errors: [Int32: Int] = [:]
for step in 1 ... steps {
    let target = CGPoint(x: start.minX + dx * Double(step) / Double(steps), y: start.minY)
    let t = CACurrentMediaTime()
    if mode == "direct" {
        var p = target
        let error = moveWindow(cid, wid, &p)
        if error != 0 { errors[error, default: 0] += 1 }
    } else {
        guard let tx = transactionCreate(cid)?.takeRetainedValue() else { print("SLSTransactionCreate returned nil"); exit(1) }
        moveWindowWithGroup(tx, wid, target)
        transactionCommit(tx, mode == "sync" ? 1 : 0)
    }
    commitMs.append((CACurrentMediaTime() - t) * 1000)
    usleep(6944) // one 144Hz frame
    if let b = wsBounds(), abs(b.minX - target.x) < 1 { landed += 1 }
}
usleep(300_000)
let end = wsBounds()
let axEnd = axPosition(ax)
let expected = start.minX + dx
commitMs.sort()
print(String(format: "mode=\(mode) steps=%d landed=%d commit p50=%.3fms max=%.3fms errors=%@", steps, landed, commitMs[commitMs.count / 2], commitMs.last!, errors.description))
print("WindowServer end x=\(end.map { "\($0.minX)" } ?? "?") (expected \(expected)); app's AX position x=\(axEnd.x)")
print(landed == steps && end.map { abs($0.minX - expected) < 1 } == true
    ? "RESULT works: the WindowServer moved the window" + (abs(axEnd.x - expected) < 1 ? " and the app knows" : ", the app's AX position is stale")
    : "RESULT doesn't work for this window")
// Back where it was, over AX, so the app and the WindowServer agree again
var origin = start.origin
AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
