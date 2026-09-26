import Common
import Foundation
import QuartzCore

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob,
        autoCheckCancelled: Bool = true,
        site: StaticString = #function,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, site: site, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(
        _ cm: CancellationMode,
        site: StaticString = #function,
        _ body: @Sendable @escaping (RunLoopJob) throws -> T,
    ) async throws -> T { // todo try to convert to typed throws
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // It's unsafe to implicitly cancel because cont.resume should be invoked exactly once
                self.runInLoopAsync(job: job, autoCheckCancelled: false, site: site) { job in
                    do {
                        try job.checkCancellation()
                        cont.resume(returning: try body(job))
                    } catch {
                        if cm == .nonCancellable { die() }
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    private let site: StaticString
    private let queuedAt: CFTimeInterval
    init(job: RunLoopJob, autoCheckCancelled: Bool, site: StaticString, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        self.site = site
        queuedAt = AnimationStats.shared != nil ? CACurrentMediaTime() : 0
        _action = action
        _refreshSessionEvent = refreshSessionEvent
    }
    @objc func action() {
        if autoCheckCancelled && job.isCancelled { return }
        let start = AnimationStats.shared != nil ? CACurrentMediaTime() : 0
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            _action(job)
        }
        AnimationStats.shared?.logJob(queuedAt: queuedAt, start: start, site: site)
    }
}

final class RunLoopJob: Sendable, AeroAny {
    // Alternative 1. In macOS 15, it's possible to use `Atomic<Bool>` from `Synchronization` module
    // Alternative 2. https://github.com/apple/swift-atomics/tree/main but I don't want to add one more dependency just for
    //                AtomicBool
    nonisolated(unsafe) private var _isCancelled: Int32 = 0
    var isCancelled: Bool { unsafe _isCancelled == 1 }
    func cancel() {
        if cm == .nonCancellable { return }
        while !isCancelled {
            unsafe OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    let cm: CancellationMode
    public init(_ cm: CancellationMode) { self.cm = cm }

    static let cancelled: RunLoopJob = RunLoopJob(.cancellable).also { $0.cancel() }

    func checkCancellation() throws {
        if cm == .cancellable && isCancelled {
            throw CancellationError()
        }
    }
}
