import Foundation
import QuartzCore

/// Measurement hook for dev-tools/animations (benchmark.sh). Only active when the server is started with
/// `AEROSPACE_ANIMATION_STATS=<file>`: then it appends one line per animation tick and per animated AX write to that file.
/// Otherwise `shared` is nil and nothing is recorded. Times are CACurrentMediaTime() seconds.
///
/// - `link+ <time> <displayId> <fps>` / `link- <time> <displayId>`: a screen's display link started/stopped
/// - `tick <time> <displayId> <vsyncTimestamp>`: a display link tick on the main thread
/// - `ax <queuedAt> <start> <end> <windowId> <p|ps|so>`: an animated AX write on the app's AX thread. `p`: position only,
///   `ps`: position and size, `so`: the stick-out setup (push, size, move)
final class AnimationStats: Sendable {
    static let shared: AnimationStats? = ProcessInfo.processInfo.environment["AEROSPACE_ANIMATION_STATS"]
        .flatMap(AnimationStats.init(path:))

    private let lock = NSLock()
    private let file: FileHandle

    private init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path)
        else { return nil }
        self.file = file
    }

    func log(_ line: String) {
        let data = Data((line + "\n").utf8)
        lock.withLock { file.write(data) }
    }

    /// Runs one animated AX write. When measuring, logs how long it waited on the app's AX thread and how long it took
    static func timeAxWrite(queuedAt: CFTimeInterval, _ windowId: UInt32, _ kind: String, _ body: () throws -> ()) rethrows {
        guard let shared else { return try body() }
        let start = CACurrentMediaTime()
        try body()
        shared.log("ax \(queuedAt) \(start) \(CACurrentMediaTime()) \(windowId) \(kind)")
    }
}
