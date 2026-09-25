// geom: prints the WindowServer bounds of the given windows, one per line, as "id x y w h" (integers).
// No screen capture and no Accessibility permission: reads CGWindowList, which reflects the WindowServer's state.
// Used by benchmark.sh to capture the settled final layout and compare it against main (must be identical).
//
// Usage: geom <id,id,...>
import CoreGraphics
import Foundation

func widArray(_ id: CGWindowID) -> CFArray {
    var ptr: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
    return CFArrayCreate(nil, &ptr, 1, nil)
}

let ids = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "")
    .split(separator: ",").compactMap { CGWindowID($0) }

for id in ids {
    guard let arr = CGWindowListCreateDescriptionFromArray(widArray(id)) as? [[String: Any]],
          let b = arr.first?[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b) else {
        print("\(id) MISSING")
        continue
    }
    print("\(id) \(Int(r.origin.x.rounded())) \(Int(r.origin.y.rounded())) \(Int(r.size.width.rounded())) \(Int(r.size.height.rounded()))")
}
