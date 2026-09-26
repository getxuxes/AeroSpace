// mouse: posts real mouse events (CGEvent), for benchmark scenarios that resize or move windows with the mouse.
// Needs the Accessibility permission of the terminal. Coordinates are global top-left points, like CGWindowList.
//
// Usage: mouse drag <x1> <y1> <x2> <y2> <ms>   press at (x1,y1), move to (x2,y2) in <ms> (one step per ~7ms), release
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 7, args[1] == "drag", let values = Optional(args[2...].compactMap(Double.init)), values.count == 5 else {
    print("Usage: mouse drag <x1> <y1> <x2> <y2> <ms>")
    exit(1)
}
let from = CGPoint(x: values[0], y: values[1])
let to = CGPoint(x: values[2], y: values[3])
let steps = max(1, Int(values[4] / 7))

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, from)
usleep(50000)
post(.leftMouseDown, from)
usleep(50000)
for step in 1 ... steps {
    let t = Double(step) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    usleep(7000)
}
usleep(30000)
post(.leftMouseUp, to)
