import Foundation
import Photos

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
/// - The continuation resumes exactly once, whether resolution, failure, or cancellation wins.
/// - Cancelling the surrounding task invokes the PhotoKit cancel handle and resumes with
///   `CancellationError`.
/// - If the task is cancelled before the request starts, the request never starts at all.
enum PendingPhotoRequest {
    /// Runs `start`, which must launch the PhotoKit call and return a handle that aborts it.
    /// `resolve` must be called exactly once by PhotoKit's handler (extra calls are ignored).
    /// `start` may throw (e.g. the asset fetch fails); the error then fails the request.
    static func run<Value: Sendable>(
        _ start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void)
            throws -> (@Sendable () -> Void)
    ) async throws -> Value {
        let bridge = Bridge<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.begin(continuation: continuation, start: start)
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

    func begin(
        continuation: CheckedContinuation<Value, any Error>,
        start: (@escaping @Sendable (Result<Value, any Error>) -> Void) throws
            -> (@Sendable () -> Void)
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
        lock.unlock()

        cancel?()
        settle(.failure(CancellationError()))
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
        lock.unlock()

        continuation?.resume(with: result)
    }
}
