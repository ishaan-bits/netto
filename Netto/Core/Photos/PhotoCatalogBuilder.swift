import Foundation

/// Chunked, cancellable, metadata-only enumeration of the photo library.
///
/// The catalog stage is the first step of the scan pipeline: it turns PhotoKit into an ordered
/// array of `PhotoAssetRecord` values. It deliberately does *no* analysis and requests *no*
/// image bytes — no thumbnails, no resource data, no content editing inputs — and it never
/// writes `sizeInBytes`.
///
/// Enumeration runs on a detached producer task; `makeScanStream` only exposes an ordered event
/// stream so a MainActor consumer can stay responsive while the heavy loop runs off-main.
struct PhotoCatalogBuilder: Sendable {
    static let defaultChunkSize = 512

    /// Assets read per batch. Batching bounds peak memory (one `PHFetchResult` index range at a
    /// time) and gives cancellation and progress a predictable tick.
    let chunkSize: Int

    init(chunkSize: Int = PhotoCatalogBuilder.defaultChunkSize) {
        self.chunkSize = max(1, chunkSize)
    }

    /// Primary API. Progress events are yielded from the single enumeration loop, so they arrive
    /// in order, and `.completed` is always the final event on success.
    ///
    /// Cancelling the consuming task terminates the stream, which cancels the producer; the
    /// producer then observes `Task.isCancelled` between chunks and stops.
    func makeScanStream(reading: any PhotoLibraryReading) -> AsyncThrowingStream<CatalogScanEvent, Error> {
        let chunkSize = self.chunkSize
        return AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    let result = try await Self.collect(reading: reading, chunkSize: chunkSize) { progress in
                        continuation.yield(.progress(progress))
                    }
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    /// Convenience wrapper for callers that only want the final result.
    func build(
        reading: any PhotoLibraryReading,
        onProgress: @escaping @Sendable (CatalogScanProgress) -> Void = { _ in }
    ) async throws -> CatalogScanResult {
        var finalResult: CatalogScanResult?
        do {
            for try await event in makeScanStream(reading: reading) {
                switch event {
                case .progress(let progress):
                    onProgress(progress)
                case .completed(let result):
                    finalResult = result
                }
            }
        } catch is CancellationError {
            throw CatalogScanFailure.cancelled
        } catch let failure as CatalogScanFailure {
            throw failure
        } catch let failure as PhotoLibraryReadError {
            throw failure.catalogFailure
        }

        guard let finalResult else { throw CatalogScanFailure.cancelled }
        return finalResult
    }

    private static func collect(
        reading: any PhotoLibraryReading,
        chunkSize: Int,
        report: @escaping @Sendable (CatalogScanProgress) -> Void
    ) async throws -> CatalogScanResult {
        let total: Int
        do {
            total = try reading.assetCount()
        } catch let failure as PhotoLibraryReadError {
            throw failure.catalogFailure
        }

        report(CatalogScanProgress(enumeratedCount: 0, totalCount: total))

        guard total > 0 else {
            return CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: reading.accessLevel)
        }

        var records: [PhotoAssetRecord] = []
        records.reserveCapacity(min(total, 10_000))

        do {
            var start = 0
            while start < total {
                try checkCancellation()
                let end = min(start + chunkSize, total)
                let chunk = try reading.records(in: start..<end)
                try checkCancellation()
                records.append(contentsOf: chunk)
                start = end
                report(CatalogScanProgress(enumeratedCount: records.count, totalCount: total))
                await Task.yield()
            }
        } catch let failure as PhotoLibraryReadError {
            throw failure.catalogFailure
        }

        return CatalogScanResult(records: records, libraryAssetCount: total, accessLevel: reading.accessLevel)
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw CatalogScanFailure.cancelled }
    }
}
