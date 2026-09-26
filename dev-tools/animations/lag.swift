// lag: splits the gaps of one traced animation into the ones the animation opens on purpose (windows that cross or
// leave) and the unexpected ones (a window lags behind the frame the animator already sent).
//
// Inputs: the raw samples of `trace` (TRACE_RAW) and the server's stats log of the same run (AEROSPACE_ANIMATION_STATS),
// which has the interpolated frame the animator sent on every tick ("frame <time> <windowId> x y w h").
// Both use CACurrentMediaTime(), the same clock across processes.
//
// For every sample at time t, the intended frame of a window is the last frame sent at or before t - 1 vsync (a frame
// can't reach the screen sooner). Windows without a frame in flight are intended where they are.
//   gap_total        largest square of a monitor's visible frame that no window covers (as trace's gap_max, without
//                    subtracting the settled gaps)
//   gap_unexpected   largest square that the intended frames cover and the real windows don't
//   gap_planned      largest square that not even the intended frames cover
// Each is reported as the max over the samples minus the same in the settled first and last samples, like trace.
//
// Usage: lag <trace-raw> <server-log> <managedId,managedId,...>
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else { print("Usage: lag <trace-raw> <server-log> <managedIds>"); exit(1) }
let managed = Set(args[3].split(separator: ",").compactMap { UInt32($0) })
_ = NSApplication.shared
let mainHeight = NSScreen.screens[0].frame.height
let screens = NSScreen.screens.map { s in
    (frame: CGRect(x: s.frame.minX, y: mainHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height),
     visible: CGRect(x: s.visibleFrame.minX, y: mainHeight - s.visibleFrame.maxY, width: s.visibleFrame.width, height: s.visibleFrame.height))
}
let period = 1.0 / Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
let separateSpaces = NSScreen.screensHaveSeparateSpaces

// Samples: "S <time>" then "<id> x y w h" lines
var samples: [(time: Double, rects: [UInt32: CGRect])] = []
for line in ((try? String(contentsOfFile: args[1], encoding: .utf8)) ?? "").split(separator: "\n") {
    let f = line.split(separator: " ")
    if f.first == "S", f.count == 2, let t = Double(f[1]) {
        samples.append((t, [:]))
    } else if f.count == 5, let id = UInt32(f[0]), !samples.isEmpty {
        let v = f[1...].compactMap { Double($0) }
        if v.count == 4 { samples[samples.count - 1].rects[id] = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
    }
}
// Frames sent by the animator, per window, in time order; "end" closes a window's animation
var sent: [UInt32: [(time: Double, rect: CGRect?)]] = [:]
for line in ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "").split(separator: "\n") {
    let f = line.split(separator: " ")
    if f.first == "frame", f.count == 7, let t = Double(f[1]), let id = UInt32(f[2]) {
        let v = f[3...].compactMap { Double($0) }
        if v.count == 4 { sent[id, default: []].append((t, CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))) }
    } else if f.first == "end", f.count == 3, let t = Double(f[1]), let id = UInt32(f[2]) {
        sent[id, default: []].append((t, nil))
    }
}
guard let firstSample = samples.first, let lastSample = samples.last else { print("LAG none"); exit(0) }

func majorityMonitor(_ r: CGRect) -> Int? {
    let areas = screens.map { s -> CGFloat in let i = s.frame.intersection(r); return i.isNull ? 0 : i.width * i.height }
    guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
    return best
}
func clipped(_ rects: [CGRect], _ monitor: Int) -> [CGRect] {
    let area = screens[monitor].visible
    return rects.filter { !separateSpaces || majorityMonitor($0) == monitor }
        .map { $0.intersection(area) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
}
/// Largest square of the monitor's visible frame that is in `inside` (or anywhere when nil) and not in `covered`
func largestSquare(_ monitor: Int, inside: [CGRect]?, covered: [CGRect]) -> CGFloat {
    let area = screens[monitor].visible
    let all = covered + (inside ?? [])
    let xs = Array(Set([area.minX, area.maxX] + all.flatMap { [$0.minX, $0.maxX] })).sorted()
    let ys = Array(Set([area.minY, area.maxY] + all.flatMap { [$0.minY, $0.maxY] })).sorted()
    let nx = xs.count - 1, ny = ys.count - 1
    var prefix = Array(repeating: Array(repeating: 0, count: nx + 1), count: ny + 1)
    for j in 0 ..< ny {
        for i in 0 ..< nx {
            let c = CGPoint(x: (xs[i] + xs[i + 1]) / 2, y: (ys[j] + ys[j + 1]) / 2)
            let wanted = (inside.map { r in r.contains { $0.contains(c) } } ?? true) && !covered.contains { $0.contains(c) }
            prefix[j + 1][i + 1] = (wanted ? 0 : 1) + prefix[j][i + 1] + prefix[j + 1][i] - prefix[j][i]
        }
    }
    var best: CGFloat = 0
    for x0 in 0 ..< nx {
        for x1 in x0 + 1 ... nx where xs[x1] - xs[x0] > best {
            for y0 in 0 ..< ny {
                for y1 in y0 + 1 ... ny {
                    let side = min(xs[x1] - xs[x0], ys[y1] - ys[y0])
                    if side <= best { continue }
                    if prefix[y1][x1] - prefix[y0][x1] - prefix[y1][x0] + prefix[y0][x0] > 0 { break }
                    best = side
                }
            }
        }
    }
    return best
}
func intended(_ id: UInt32, at t: Double, actual: CGRect) -> CGRect {
    guard let frames = sent[id], let last = frames.last(where: { $0.time <= t - period }) else { return actual }
    return last.rect ?? actual // after "end" the window is meant to be where it is
}

var monitors = Set<Int>()
for sample in [firstSample, lastSample] {
    for (id, r) in sample.rects where managed.contains(id) { if let m = majorityMonitor(r) { monitors.insert(m) } }
}
func gaps(_ sample: (time: Double, rects: [UInt32: CGRect])) -> (total: CGFloat, unexpected: CGFloat, planned: CGFloat) {
    let actual = Array(sample.rects.values)
    let meant = sample.rects.map { id, r in managed.contains(id) ? intended(id, at: sample.time, actual: r) : r }
    var result: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
    for m in monitors {
        let a = clipped(actual, m), i = clipped(meant, m)
        result.0 = max(result.0, largestSquare(m, inside: nil, covered: a))
        result.1 = max(result.1, largestSquare(m, inside: i, covered: a))
        result.2 = max(result.2, largestSquare(m, inside: nil, covered: i))
    }
    return result
}
let settledFirst = gaps(firstSample), settledLast = gaps(lastSample)
let settledTotal = max(settledFirst.total, settledLast.total)
var total: CGFloat = 0, unexpected: CGFloat = 0, planned: CGFloat = 0, unexpectedFrames = 0
var previous: [UInt32: CGRect]? = nil
for sample in samples where sample.rects != previous {
    previous = sample.rects
    let g = gaps(sample)
    total = max(total, g.total - settledTotal)
    planned = max(planned, g.planned - settledTotal)
    unexpected = max(unexpected, g.unexpected)
    if g.unexpected >= 2 { unexpectedFrames += 1 }
}
print(String(format: "LAG gap_total=%.0f gap_planned=%.0f gap_unexpected=%.0f unexpected_frames=%d has_frames=%d",
             max(0, total), max(0, planned), unexpected, unexpectedFrames, sent.isEmpty ? 0 : 1))
