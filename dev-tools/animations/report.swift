// report: turns the benchmark.sh output of two runs (e.g. this branch and main) into Markdown tables.
// Pools the frame times of every repetition of a scenario, and reads the server's stats log (AX write durations, display
// link ticks) if the run has one. Compares the settled final layout of every repetition with the first one of the
// baseline: the final state must be identical (tolerance 1pt).
//
// Usage: report <run-dir-A> <run-dir-B> [labelA] [labelB]     (e.g. out/<date>/branch out/<date>/main branch main)
import CoreGraphics
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
            if line.hasPrefix("STATS ") || line.hasPrefix("LAG ") {
                for pair in line.split(separator: " ").dropFirst() {
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
    var jobs: [(ms: Double, site: String, thread: String)] = []
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
            case "job" where f.count >= 6:
                let start = Double(f[2]) ?? 0, end = Double(f[3]) ?? 0
                if !f[5].hasPrefix("setAxFrameAnimated") && !f[5].hasPrefix("setAxFrameStickingOut") {
                    s.jobs.append(((end - start) * 1000, f[5], f[4]))
                }
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

/// The visible windows of a final layout. Windows hidden in a corner don't count: their size is whatever they had when
/// they were hidden
typealias Geom = [String: [Double]]
func geom(_ url: URL) -> Geom {
    // Older runs have no v|h column: work it out from the screens the benchmark saved next to it
    let screens: [CGRect] = (read(url.deletingLastPathComponent().appending(path: "screens.txt")) ?? "").split(separator: "\n").compactMap {
        let f = $0.split(separator: " ").compactMap { Double($0) }
        return f.count >= 5 ? CGRect(x: f[1], y: f[2], width: f[3], height: f[4]) : nil
    }
    func visible(_ r: [Double]) -> Bool {
        let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        return screens.map { rect.intersection($0) }.filter { !$0.isNull }.map { $0.width * $0.height }.reduce(0, +) > rect.width * rect.height / 2
    }
    var g: Geom = [:]
    for line in (read(url) ?? "").split(separator: "\n") {
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 5 else { continue }
        let rect = f[1 ... 4].compactMap(Double.init)
        guard rect.count == 4 else { continue }
        if f.count == 6 ? f[5] == "v" : visible(rect) { g[f[0]] = rect }
    }
    return g
}
/// Largest coordinate difference between two final layouts, nil if the visible windows differ
func maxDelta(_ a: Geom, _ b: Geom) -> Double? {
    guard Set(a.keys) == Set(b.keys) else { return nil }
    return a.keys.map { id in zip(a[id]!, b[id]!).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
}
func describe(_ delta: Double?) -> String { delta.map { $0 <= 1 ? "idéntico" : String(format: "difiere %.0fpt", $0) } ?? "difiere (ventanas visibles)" }

let tracesA = traces(dirA)
let tracesB = traces(dirB)
let scenarios = Array(Set(tracesA.keys).union(tracesB.keys)).sorted()

func stat(_ runs: [TraceRun]?, _ key: String) -> [Double] { (runs ?? []).compactMap { $0.stats[key] } }
func pair(_ a: String, _ b: String) -> String { "\(a) / \(b)" }

print("## Por escenario: \(labelA) / \(labelB)\n")
print("Repeticiones agrupadas. Tiempo de frame = intervalo entre cambios visibles de una ventana en movimiento (WindowServer).")
print("Frames perdidos = media por repetición. Hueco = lado del mayor cuadrado sin cubrir, peor repetición (mediana entre paréntesis).")
print("Hueco total: todo lo que se ve detrás. Hueco no previsto: lo que los marcos interpolados cubrían (enviados hace ≥ 1 vsync) y la ventana real no, porque va con retraso.")
print("Resize %: de los frames con cambios, en cuántos cambió el tamaño de alguna ventana (el resto solo movieron).\n")
print("| Escenario | Reps | Frame p50 ms | Frame p95 ms | Frame máx ms | Frames perdidos | Hueco total pt | Hueco no previsto pt | Resize % | Paso máx pt | Cambio de monitor (flips/frames mal) | Duración ms | Estado final |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for name in scenarios {
    let a = tracesA[name], b = tracesB[name]
    let ftA = (a ?? []).flatMap(\.frameTimes), ftB = (b ?? []).flatMap(\.frameTimes)
    func dropped(_ runs: [TraceRun]?) -> String {
        let d = stat(runs, "dropped")
        return d.isEmpty ? "—" : fmt(d.reduce(0, +) / Double(d.count))
    }
    func lagGap(_ runs: [TraceRun]?, _ key: String) -> String {
        let g = stat(runs, key)
        return g.isEmpty ? "—" : "\(fmt(g.max(), 0)) (\(fmt(median(g), 0)))"
    }
    func resizeShare(_ runs: [TraceRun]?) -> String {
        let r = stat(runs, "resize_frames").reduce(0, +), m = stat(runs, "move_frames").reduce(0, +)
        return r + m == 0 ? "—" : fmt(100 * r / (r + m), 0)
    }
    func monitors(_ runs: [TraceRun]?) -> String {
        "\(fmt(stat(runs, "mon_flips").max(), 0))/\(fmt(stat(runs, "wrong_mon").max(), 0))"
    }
    // Final state: repetition i of A against repetition i of B. If B's repetitions differ among themselves, the scenario
    // isn't deterministic on B either, and a difference doesn't point at A
    var deltas: [Double?] = []
    var baselineSpread: Double? = 0
    let firstB = geom(dirB.appending(path: "\(name)-1.geom"))
    for rep in 1 ... max(a?.count ?? 0, b?.count ?? 0) {
        let ga = geom(dirA.appending(path: "\(name)-\(rep).geom"))
        let gb = geom(dirB.appending(path: "\(name)-\(rep).geom"))
        if ga.isEmpty || gb.isEmpty { continue }
        deltas.append(maxDelta(ga, gb))
        let spread = maxDelta(gb, firstB)
        baselineSpread = spread.flatMap { s in baselineSpread.map { max($0, s) } }
    }
    let differing = deltas.count(where: { $0.map { $0 > 1 } ?? true })
    var final = deltas.isEmpty ? "—" : differing == 0 ? "idéntico" : "\(differing)/\(deltas.count) " + describe(deltas.contains { $0 == nil } ? nil : deltas.compactMap { $0 }.max())
    if baselineSpread.map({ $0 > 1 }) ?? true { final += " (\(labelB) no determinista: \(describe(baselineSpread)))" }
    let reps = pair("\(a?.count ?? 0)", "\(b?.count ?? 0)")
    print("| \(name) | \(reps) | \(pair(fmt(percentile(ftA, 0.5), 2), fmt(percentile(ftB, 0.5), 2))) | \(pair(fmt(percentile(ftA, 0.95), 2), fmt(percentile(ftB, 0.95), 2))) | \(pair(fmt(ftA.max(), 1), fmt(ftB.max(), 1))) | \(pair(dropped(a), dropped(b))) | \(pair(lagGap(a, "gap_total"), lagGap(b, "gap_total"))) | \(pair(lagGap(a, "gap_unexpected"), lagGap(b, "gap_unexpected"))) | \(pair(resizeShare(a), resizeShare(b))) | \(pair(fmt(stat(a, "max_step").max(), 0), fmt(stat(b, "max_step").max(), 0))) | \(pair(monitors(a), monitors(b))) | \(pair(fmt(median(stat(a, "anim_ms")), 0), fmt(median(stat(b, "anim_ms")), 0))) | \(final) |")
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
    var axJobRows: [(String, AxStats)] = []
    defer {
        print("\nOtros trabajos en los hilos AX (no son escrituras animadas): el más largo y el que más esperó otra cosa.\n")
        print("| Escenario | Trabajos | Más largo ms | Función (hilo) |")
        print("|---|---|---|---|")
        for (name, s) in axJobRows {
            let top = s.jobs.max { $0.ms < $1.ms }
            print("| \(name) | \(s.jobs.count) | \(fmt(top?.ms, 1)) | \(top.map { "\($0.site) (\($0.thread))" } ?? "—") |")
        }
    }
    print("| Escenario | Escrituras pos+tam | pos+tam p50/p95 ms | Solo pos p50/p95 ms | Espera p50/p95/máx ms | Stick-out | Tick p50/p95 ms | Ticks perdidos |")
    print("|---|---|---|---|---|---|---|---|")
    for file in axFiles {
        guard let s = axStats(dir.appending(path: file)) else { continue }
        axJobRows.append((String(file.dropLast(3)), s))
        let name = String(file.dropLast(3))
        print("| \(name) | \(s.writeMs.count) | \(fmt(percentile(s.writeMs, 0.5), 2))/\(fmt(percentile(s.writeMs, 0.95), 2)) | \(fmt(percentile(s.posMs, 0.5), 2))/\(fmt(percentile(s.posMs, 0.95), 2)) | \(fmt(percentile(s.waitMs, 0.5), 2))/\(fmt(percentile(s.waitMs, 0.95), 2))/\(fmt(s.waitMs.max(), 1)) | \(s.stickOut) | \(fmt(percentile(s.tickMs, 0.5), 2))/\(fmt(percentile(s.tickMs, 0.95), 2)) | \(s.tickMissed) |")
    }
}
