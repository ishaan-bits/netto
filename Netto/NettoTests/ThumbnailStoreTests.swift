import CoreGraphics
import Foundation
import Testing
@testable import Netto

/// Call counter shared with the stub loader. The loader runs inside `ThumbnailStore`'s actor
/// context (and in test tasks); the lock makes the counts race-free regardless of where the
/// increments land.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

private struct StubLoader: PhotoThumbnailLoading {
    let log: CallLog
    var delayNanoseconds: UInt64 = 0
    var failures: Set<String> = []
    var cancellations: Set<String> = []

    func thumbnail(for assetID: String, targetPixelSize: Int) async throws -> CGImage {
        log.increment(assetID)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if cancellations.contains(assetID) {
            throw CancellationError()
        }
        if failures.contains(assetID) {
            throw PhotoContentError.assetNotFound
        }
        return Self.solidImage(side: targetPixelSize)
    }

    static func solidImage(side: Int) -> CGImage {
        let dimension = max(1, side)
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("test image context must be creatable")
        }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let image = context.makeImage() else {
            preconditionFailure("test image must render")
        }
        return image
    }
}

struct ThumbnailStoreTests {
    @Test func successfulLoadsAreCached() async throws {
        let log = CallLog()
        let store = ThumbnailStore(loader: StubLoader(log: log), capacity: 8)

        _ = try await store.image(for: "a", targetPixelSize: 96)
        _ = try await store.image(for: "a", targetPixelSize: 96)
        _ = try await store.image(for: "a", targetPixelSize: 96)

        #expect(log.count("a") == 1)
    }

    @Test func pixelSizesArePartOfTheCacheKey() async throws {
        let log = CallLog()
        let store = ThumbnailStore(loader: StubLoader(log: log), capacity: 8)

        let strip = try await store.image(for: "a", targetPixelSize: 96)
        let detail = try await store.image(for: "a", targetPixelSize: 300)
        _ = try await store.image(for: "a", targetPixelSize: 96)

        #expect(log.count("a") == 2)
        #expect(strip.width <= 300)
        #expect(detail.width <= 300)
        #expect(detail.width >= strip.width)
    }

    @Test func failuresAreCachedAndTheFirstCallerGetsTheOriginalError() async {
        let log = CallLog()
        let store = ThumbnailStore(loader: StubLoader(log: log, failures: ["gone"]), capacity: 8)

        var firstError: PhotoContentError?
        do {
            _ = try await store.image(for: "gone", targetPixelSize: 96)
            Issue.record("expected the first load to throw")
        } catch let error as PhotoContentError {
            firstError = error
        } catch {
            Issue.record("expected PhotoContentError, got \(error)")
        }
        #expect(firstError == .assetNotFound)

        var secondError: PhotoContentError?
        do {
            _ = try await store.image(for: "gone", targetPixelSize: 96)
            Issue.record("expected the cached failure to throw")
        } catch let error as PhotoContentError {
            secondError = error
        } catch {
            Issue.record("expected PhotoContentError, got \(error)")
        }
        #expect(secondError == .assetNotFound)
        #expect(log.count("gone") == 1)
    }

    @Test func cancellationIsNeverCached() async {
        let log = CallLog()
        let store = ThumbnailStore(
            loader: StubLoader(log: log, cancellations: ["flaky"]),
            capacity: 8
        )

        do {
            _ = try await store.image(for: "flaky", targetPixelSize: 96)
            Issue.record("expected the load to throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        do {
            _ = try await store.image(for: "flaky", targetPixelSize: 96)
            Issue.record("expected the retry to throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(log.count("flaky") == 2)
    }

    @Test func leastRecentlyUsedEntriesAreEvictedAtCapacity() async throws {
        let log = CallLog()
        let store = ThumbnailStore(loader: StubLoader(log: log), capacity: 2)

        _ = try await store.image(for: "a", targetPixelSize: 96)
        _ = try await store.image(for: "b", targetPixelSize: 96)
        _ = try await store.image(for: "c", targetPixelSize: 96) // evicts "a"

        _ = try await store.image(for: "a", targetPixelSize: 96) // loads again
        #expect(log.count("a") == 2)

        _ = try await store.image(for: "c", targetPixelSize: 96) // still resident
        #expect(log.count("c") == 1)
    }

    @Test func concurrentRequestsForOneKeyCoalesceIntoOneLoad() async throws {
        let log = CallLog()
        let store = ThumbnailStore(
            loader: StubLoader(log: log, delayNanoseconds: 300_000_000),
            capacity: 8
        )

        async let first = store.image(for: "shared", targetPixelSize: 96)
        async let second = store.image(for: "shared", targetPixelSize: 96)
        _ = try await (first, second)

        #expect(log.count("shared") == 1)
    }

    @Test func residentBytesAreBoundedByTheBudget() async throws {
        let log = CallLog()
        // Budget smaller than two of these images: entries must be evicted to stay under it.
        let bytesPerImage = 96 * 96 * 4
        let store = ThumbnailStore(
            loader: StubLoader(log: log),
            capacity: 64,
            byteLimit: bytesPerImage + 1
        )

        _ = try await store.image(for: "one", targetPixelSize: 96)
        _ = try await store.image(for: "two", targetPixelSize: 96)
        _ = try await store.image(for: "one", targetPixelSize: 96) // "two" was evicted by budget

        #expect(log.count("one") == 2)
        #expect(log.count("two") == 1)
    }
}
