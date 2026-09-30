import Foundation
import Photos

/// Thrown when PhotoKit never invokes a request's callback before the failsafe deadline.
///
/// One bad asset must cost the pipeline one skipped asset (reported with a reason), never a
/// scan that sits at its current stage forever.
struct PhotoRequestTimeoutError: Error, Sendable, Equatable {}

/// Exactly-once, cancellation-safe bridge over PhotoKit's callback APIs.
///
/// Two hazards this exists to close, both verified from the SDK docs:
/// - `requestImage` invokes its handler on the main thread, possibly more than once, and — if the
///   request is cancelled — possibly *never*. A naive `withCheckedContinuation` therefore leaks a
///   suspended task forever.
/// - The analysis pipeline must stop promptly when its task is cancelled, including while a
///   PhotoKit request is in flight.
///
/// Contract:
/// - The continuation resumes exactly once, whether resolution, failure, cancellation, or the
///   timeout wins.
/// - Cancelling the surrounding task invokes the PhotoKit cancel handle and resumes with
///   `CancellationError`.
/// - If the task is cancelled before the request starts, the request never starts at all.
/// - If neither resolution nor cancellation arrives within `timeoutNanos`, the request is
///   aborted through its cancel handle and resumes with `PhotoRequestTimeoutError`. The
///   analysis engine maps that to an unavailable reason per asset and keeps the pool moving.
enum PendingPhotoRequest {
    /// Failsafe deadline for a single PhotoKit request. Deliberately generous (local-only
    /// requests answer in well under a second; a large edited-asset render can take seconds),
    /// but finite: a hung callback must never stall a worker slot for the rest of the scan.
    static let defaultTimeoutNanos: UInt64 = 30_000_000_000

    /// Runs `start`, which must launch the PhotoKit call and return a handle that aborts it.
    /// `resolve` must be called exactly once by PhotoKit's handler (extra calls are ignored).
    /// `start` may throw (e.g. the asset fetch fails); the error then fails the request.
    static func run<Value: Sendable>(
        timeoutNanos: UInt64 = PendingPhotoRequest.defaultTimeoutNanos,
        _ start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void)
            throws -> (@Sendable () -> Void)
    ) async throws -> Value {
        let bridge = Bridge<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.begin(continuation: continuation, start: start, timeoutNanos: timeoutNanos)
            }
        } onCancel: {
            bridge.cancel()
        }
    }
}

/// `@unchecked Sendable`: every stored property is guarded by `lock`.
private final class Bridge<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var settled = false
    private var cancelled = false
    private var cancelAction: (@Sendable () -> Void)?
    private var timeoutTask: Task<Void, Never>?

    func begin(
        continuation: CheckedContinuation<Value, any Error>,
        start: (@escaping @Sendable (Result<Value, any Error>) -> Void) throws
            -> (@Sendable () -> Void),
        timeoutNanos: UInt64
    ) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let alreadyCancelled = cancelled
        lock.unlock()

        guard !alreadyCancelled else {
            settle(.failure(CancellationError()))
            return
        }

        let cancel: @Sendable () -> Void
        do {
            cancel = try start { [self] result in
                settle(result)
            }
        } catch {
            settle(.failure(error))
            return
        }

        lock.lock()
        let cancelledDuringStart = cancelled
        if !cancelledDuringStart, !settled, cancelAction == nil {
            cancelAction = cancel
        }
        // Failsafe: armed only once the request is actually in flight; a synchronous resolve
        // (settled) or an already-cancelled task never needs it.
        if !settled, !cancelled {
            timeoutTask = Task { [self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                } catch {
                    return // cancelled by settlement — not a timeout
                }
                timeout()
            }
        }
        lock.unlock()

        if cancelledDuringStart {
            cancel()
            settle(.failure(CancellationError()))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let cancel = cancelAction
        cancelAction = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeout?.cancel()
        cancel?()
        settle(.failure(CancellationError()))
    }

    /// The request outlived its deadline: abort the PhotoKit request and fail the run with the
    /// timeout error. A callback that still arrives later is swallowed by `settle`.
    private func timeout() {
        lock.lock()
        let cancel = cancelAction
        cancelAction = nil
        timeoutTask = nil
        lock.unlock()

        cancel?()
        settle(.failure(PhotoRequestTimeoutError()))
    }

    private func settle(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeout?.cancel()
        continuation?.resume(with: result)
    }
}
