// report: turns the benchmark.sh output of two runs (e.g. this branch and main) into Markdown tables.
// Pools the frame times of every repetition of a scenario, and reads the server's stats log (AX write durations, display
// link ticks) if the run has one. Compares the settled final layout of every repetition with the first one of the
// baseline: the final state must be identical (tolerance 1pt).
//
// Usage: report <run-dir-A> <run-dir-B> [labelA] [labelB]     (e.g. out/<date>/branch out/<date>/main branch main)
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("Usage: report <run-dir-A> <run-dir-B> [labelA] [labelB]"); exit(1) }
let dirA = URL(filePath: args[1])
let dirB = URL(filePath: args[2])
let labelA = args.count > 3 ? args[3] : "A"
let labelB = args.count > 4 ? args[4] : "B"

func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func files(_ dir: URL, _ ext: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []).filter { $0.hasSuffix(ext) }.sorted()
}
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}
func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }
func fmt(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }

struct TraceRun {
    var stats: [String: Double] = [:]
    var frameTimes: [Double] = []
}

/// scenario -> repetitions
func traces(_ dir: URL) -> [String: [TraceRun]] {
    var result: [String: [TraceRun]] = [:]
    for file in files(dir, ".trace") {
        let name = String(file.dropLast(".trace".count).split(separator: "-").dropLast().joined(separator: "-"))
        var run = TraceRun()
        for line in (read(dir.appending(path: file)) ?? "").split(separator: "\n") {
            if line.hasPrefix("STATS ") {
                for pair in line.dropFirst(6).split(separator: " ") {
                    let kv = pair.split(separator: "=")
                    if kv.count == 2, let v = Double(kv[1]) { run.stats[String(kv[0])] = v }
                }
            } else if line.hasPrefix("FT ") {
                run.frameTimes = line.dropFirst(3).split(separator: ",").compactMap { Double($0) }
            }
        }
        result[name, default: []].append(run)
    }
    return result
}

struct AxStats {
    var writeMs: [Double] = [] // pos and size
    var posMs: [Double] = [] // pos only
    var waitMs: [Double] = []
    var stickOut = 0
    var tickMs: [Double] = []
    var tickMissed = 0
    var ticks = 0
}

func axStats(_ url: URL) -> AxStats? {
    guard let text = read(url) else { return nil }
    var s = AxStats()
    var lastTick: [String: Double] = [:]
    var period: [String: Double] = [:]
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ").map(String.init)
        switch f.first {
            case "link+" where f.count >= 4:
                period[f[2]] = 1 / (Double(f[3]) ?? 60)
                lastTick[f[2]] = nil
            case "link-" where f.count >= 3:
                lastTick[f[2]] = nil
            case "tick" where f.count >= 3:
                let t = Double(f[1]) ?? 0
                s.ticks += 1
                if let previous = lastTick[f[2]], let p = period[f[2]] {
                    let dt = t - previous
                    s.tickMs.append(dt * 1000)
                    let vsyncs = Int((dt / p).rounded())
                    if vsyncs > 1 { s.tickMissed += vsyncs - 1 }
                }
                lastTick[f[2]] = t
            case "ax" where f.count >= 6:
                let queued = Double(f[1]) ?? 0, start = Double(f[2]) ?? 0, end = Double(f[3]) ?? 0
                s.waitMs.append((start - queued) * 1000)
                switch f[5] {
                    case "p": s.posMs.append((end - start) * 1000)
                    case "ps": s.writeMs.append((end - start) * 1000)
                    default: s.stickOut += 1
                }
            default: break
        }
    }
    return s
}

typealias Geom = [String: [Double]]
func geom(_ url: URL) -> Geom {
    var g: Geom = [:]
    for line in (read(url) ?? "").split(separator: "\n") {
        let f = line.split(separator: " ").map(String.init)
        if f.count == 5 { g[f[0]] = f[1...].compactMap(Double.init) }
    }
    return g
}
/// Largest coordinate difference between two final layouts, nil if a window is missing in one of them
func maxDelta(_ a: Geom, _ b: Geom) -> Double? {
    guard Set(a.keys) == Set(b.keys) else { return nil }
    return a.keys.map { id in zip(a[id]!, b[id]!).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
}

let tracesA = traces(dirA)
let tracesB = traces(dirB)
let scenarios = Array(Set(tracesA.keys).union(tracesB.keys)).sorted()

func stat(_ runs: [TraceRun]?, _ key: String) -> [Double] { (runs ?? []).compactMap { $0.stats[key] } }
func pair(_ a: String, _ b: String) -> String { "\(a) / \(b)" }

print("## Por escenario: \(labelA) / \(labelB)\n")
print("Repeticiones agrupadas. Tiempo de frame = intervalo entre cambios visibles de una ventana en movimiento (WindowServer).")
print("Frames perdidos = media por repetición. Hueco = lado del mayor cuadrado sin cubrir, peor repetición (mediana entre paréntesis).\n")
print("| Escenario | Reps | Frame p50 ms | Frame p95 ms | Frame máx ms | Frames perdidos | Hueco máx pt | Frames con hueco | Cambio de monitor (flips/frames mal) | Duración ms | Estado final |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for name in scenarios {
    let a = tracesA[name], b = tracesB[name]
    let ftA = (a ?? []).flatMap(\.frameTimes), ftB = (b ?? []).flatMap(\.frameTimes)
    func dropped(_ runs: [TraceRun]?) -> String {
        let d = stat(runs, "dropped")
        return d.isEmpty ? "—" : fmt(d.reduce(0, +) / Double(d.count))
    }
    func gap(_ runs: [TraceRun]?) -> String {
        let g = stat(runs, "gap_max")
        return g.isEmpty ? "—" : "\(fmt(g.max(), 0)) (\(fmt(median(g), 0)))"
    }
    func gapFrames(_ runs: [TraceRun]?) -> String { fmt(median(stat(runs, "gap_frames")), 0) }
    func monitors(_ runs: [TraceRun]?) -> String {
        "\(fmt(stat(runs, "mon_flips").max(), 0))/\(fmt(stat(runs, "wrong_mon").max(), 0))"
    }
    // Final state: every repetition of both runs against the first repetition of B (the baseline)
    let baseline = geom(dirB.appending(path: "\(name)-1.geom"))
    var worst: Double? = 0
    for dir in [dirA, dirB] {
        for file in files(dir, ".geom") where file.hasPrefix("\(name)-") && Int(file.dropFirst(name.count + 1).dropLast(".geom".count)) != nil {
            let d = maxDelta(geom(dir.appending(path: file)), baseline)
            worst = d.flatMap { d in worst.map { max($0, d) } }
        }
    }
    let final = baseline.isEmpty ? "—" : worst.map { $0 <= 1 ? "idéntico" : String(format: "DIFIERE %.0fpt", $0) } ?? "DIFIERE (ventanas)"
    let reps = pair("\(a?.count ?? 0)", "\(b?.count ?? 0)")
    print("| \(name) | \(reps) | \(pair(fmt(percentile(ftA, 0.5), 2), fmt(percentile(ftB, 0.5), 2))) | \(pair(fmt(percentile(ftA, 0.95), 2), fmt(percentile(ftB, 0.95), 2))) | \(pair(fmt(ftA.max(), 1), fmt(ftB.max(), 1))) | \(pair(dropped(a), dropped(b))) | \(pair(gap(a), gap(b))) | \(pair(gapFrames(a), gapFrames(b))) | \(pair(monitors(a), monitors(b))) | \(pair(fmt(median(stat(a, "anim_ms")), 0), fmt(median(stat(b, "anim_ms")), 0))) | \(final) |")
}

for (label, dir) in [(labelA, dirA), (labelB, dirB)] {
    let axFiles = files(dir, ".ax")
    guard !axFiles.isEmpty else {
        print("\n## Servidor (\(label))\n\nSin log del servidor: esta build no tiene AnimationStats (main) o no se arrancó con AEROSPACE_ANIMATION_STATS.")
        continue
    }
    print("\n## Servidor (\(label)): llamadas AX y ticks del display link\n")
    print("Escritura AX = duración en el hilo AX de la app (pos+tamaño o solo pos). Espera = desde que se encola hasta que empieza.")
    print("Ticks perdidos = vsyncs sin tick en el hilo principal mientras había animación.\n")
    print("| Escenario | Escrituras pos+tam | pos+tam p50/p95 ms | Solo pos p50/p95 ms | Espera p50/p95/máx ms | Stick-out | Tick p50/p95 ms | Ticks perdidos |")
    print("|---|---|---|---|---|---|---|---|")
    for file in axFiles {
        guard let s = axStats(dir.appending(path: file)) else { continue }
        let name = String(file.dropLast(3))
        print("| \(name) | \(s.writeMs.count) | \(fmt(percentile(s.writeMs, 0.5), 2))/\(fmt(percentile(s.writeMs, 0.95), 2)) | \(fmt(percentile(s.posMs, 0.5), 2))/\(fmt(percentile(s.posMs, 0.95), 2)) | \(fmt(percentile(s.waitMs, 0.5), 2))/\(fmt(percentile(s.waitMs, 0.95), 2))/\(fmt(s.waitMs.max(), 1)) | \(s.stickOut) | \(fmt(percentile(s.tickMs, 0.5), 2))/\(fmt(percentile(s.tickMs, 0.95), 2)) | \(s.tickMissed) |")
    }
}
