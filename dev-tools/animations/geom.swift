// geom: prints the WindowServer bounds of the given windows, one per line, as "name x y w h" (integers).
// No screen capture and no Accessibility permission: reads CGWindowList, which reflects the WindowServer's state.
// Used by benchmark.sh to capture the settled final layout and compare it against main (must be identical).
//
// Usage: geom <id,id,...>             names are the ids
//        geom <name=id,name=id,...>   names are given, so windows created during a run compare across runs
//        geom --screens               "index x y w h visibleX visibleY visibleW visibleH scale fps" per screen, top-left
//                                     coordinates like CGWindowList, NSScreen.screens order (index 0 is the main one)
import AppKit
import CoreGraphics
import Foundation

func widArray(_ id: CGWindowID) -> CFArray {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
    return CFArrayCreate(nil, &ptr, 1, nil)
}

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

if arg == "--screens" {
    _ = NSApplication.shared
    let mainHeight = NSScreen.screens[0].frame.height
    func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
    for (index, screen) in NSScreen.screens.enumerated() {
        let f = topLeft(screen.frame)
        let v = topLeft(screen.visibleFrame)
        print([index, Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), Int(v.minX), Int(v.minY), Int(v.width), Int(v.height)]
            .map(String.init).joined(separator: " ") + " \(screen.backingScaleFactor) \(screen.maximumFramesPerSecond)")
    }
    exit(0)
}

for item in arg.split(separator: ",") {
    let parts = item.split(separator: "=")
    let name = String(parts[0])
    guard let id = CGWindowID(parts.last!),
          let arr = CGWindowListCreateDescriptionFromArray(widArray(id)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b)
    else {
        print("\(name) MISSING")
        continue
    }
    print("\(name) \(Int(r.origin.x.rounded())) \(Int(r.origin.y.rounded())) \(Int(r.size.width.rounded())) \(Int(r.size.height.rounded()))")
}
