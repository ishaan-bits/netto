import Foundation
import Testing
@testable import Netto

// MARK: - Test doubles

private struct TestFailure: Error, Equatable {
    let message: String
}

/// `@unchecked Sendable`: every access goes through `lock`.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            // All locking happens inside the synchronous closure: `NSLock` calls are
            // unavailable directly from async contexts.
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        signalled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - State machine

/// Focused tests for the exactly-once / cancellation bridge that every live PhotoKit request
/// runs through. No photo library involved: `start` is injected, so these pin down the state
/// machine itself — the failure modes the contract in `PendingPhotoRequest` promises to close.
struct PendingPhotoRequestTests {
    @Test func startDeliversAValueExactlyOnce() async throws {
        let value = try await PendingPhotoRequest.run { resolve in
            resolve(.success(7))
            return {}
        }
        #expect(value == 7)
    }

    @Test func aThrowingStartFailsTheRun() async {
        await #expect(throws: TestFailure(message: "start failed")) {
            // `_: Int` gives the generic `Value` its contextual type; without it the always-
            // throwing closure has nothing to infer from.
            let _: Int = try await PendingPhotoRequest.run { _ in
                throw TestFailure(message: "start failed")
            }
        }
    }

    @Test func onlyTheFirstCallbackWins() async throws {
        // PhotoKit may legally invoke its handler more than once (degraded + final under
        // `.opportunistic` delivery). The continuation must resume exactly once — a second
        // resume would trap, so surviving this run is the assertion.
        let value = try await PendingPhotoRequest.run { resolve in
            resolve(.success(1))
            resolve(.success(2))
            return {}
        }
        #expect(value == 1)
    }

    @Test func cancellationResumesWithCancellationErrorAndInvokesCancelActionOnce() async {
        let started = Signal()
        let resolveBox = Box<(@Sendable (Result<Int, any Error>) -> Void)?>(nil)
        let cancelCount = Box(0)

        let task = Task { () throws -> Int in
            try await PendingPhotoRequest.run { resolve in
                resolveBox.write(resolve)
                started.signal()
                return {
                    cancelCount.write(cancelCount.read() + 1)
                }
            }
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("run should not have produced a value after cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancelCount.read() == 1)

        // A callback arriving *after* logical cancellation must be swallowed, not trap.
        resolveBox.read()?(.success(99))
        #expect(cancelCount.read() == 1)
    }

    @Test func anAlreadyCancelledTaskFailsTheRunWithoutHanging() async {
        // Whether the pre-cancel is observed before or after `start` runs, the run must fail
        // with `CancellationError` and never hang — a suspended continuation here would leak.
        let task = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PendingPhotoRequest.run { _ in
                return {}
            }
        }
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func aLateCallbackAfterSuccessfulCompletionIsIgnored() async throws {
        let resolveBox = Box<(@Sendable (Result<Int, any Error>) -> Void)?>(nil)
        let value = try await PendingPhotoRequest.run { resolve in
            resolveBox.write(resolve)
            resolve(.success(5))
            return {}
        }
        #expect(value == 5)

        // The settle latch must already be closed: a stale PhotoKit callback after success
        // publishes nothing and cannot double-resume.
        resolveBox.read()?(.success(6))
        resolveBox.read()?(.failure(TestFailure(message: "late")))
        #expect(value == 5)
    }

    @Test func cancellationBeforeTheRequestStartsNeverStartsIt() async {
        // Race window: cancellation can land between `begin` reading the flag and calling
        // `start`. Either order is legal; the invariant is that the run never *succeeds* and
        // the cancel action is never invoked twice.
        for _ in 0..<50 {
            let started = Signal()
            let cancelCount = Box(0)
            let task = Task { () throws -> Int in
                try await PendingPhotoRequest.run { _ in
                    started.signal()
                    return { cancelCount.write(cancelCount.read() + 1) }
                }
            }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("cancelled run must not succeed")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(cancelCount.read() <= 1)
        }
    }

    // MARK: - Timeout failsafe

    @Test func aHungRequestTimesOutAndAbortsThroughTheCancelAction() async {
        // The scan-stall regression this pins: PhotoKit may legally never call the handler.
        // The bridge must fail the request with `PhotoRequestTimeoutError`, invoke the PhotoKit
        // cancel handle exactly once, and swallow any callback that finally arrives later.
        let resolveBox = Box<(@Sendable (Result<Int, any Error>) -> Void)?>(nil)
        let cancelCount = Box(0)

        do {
            _ = try await PendingPhotoRequest.run(timeoutNanos: 50_000_000) { resolve in
                resolveBox.write(resolve)
                return { cancelCount.write(cancelCount.read() + 1) }
            }
            Issue.record("expected the hung request to time out")
        } catch is PhotoRequestTimeoutError {
            // expected
        } catch {
            Issue.record("wrong error from a timed-out request: \(error)")
        }
        #expect(cancelCount.read() == 1)

        // A late callback after the deadline is swallowed, not delivered and not a double resume.
        resolveBox.read()?(.success(99))
        #expect(cancelCount.read() == 1)
    }

    @Test func aSettledRequestNeverFiresItsTimeout() async throws {
        // Once resolution wins, the deadline task must be cancelled: a stray timeout firing
        // after success would abort a completed request and invoke the cancel handle.
        let cancelCount = Box(0)
        let value = try await PendingPhotoRequest.run(timeoutNanos: 30_000_000) { resolve in
            resolve(.success(3))
            return { cancelCount.write(cancelCount.read() + 1) }
        }
        #expect(value == 3)

        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(cancelCount.read() == 0)
    }
}
