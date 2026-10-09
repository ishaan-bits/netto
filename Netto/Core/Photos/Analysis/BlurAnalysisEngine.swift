import CoreGraphics
import Foundation

struct BlurAnalysisConfiguration: Sendable, Equatable {
    /// Fixed worker width. Never one task per asset: peak memory (bounded thumbnails) and
    /// CPU utilization stay fixed regardless of library size. Kept at half the similarity
    /// engine's default so a user who runs both passes concurrently still gets both
    /// finished without oversubscribing the main cores.
    var maxConcurrentWorkers: Int = 4
    /// Longest thumbnail side requested from PhotoKit — the local-only, bounded analysis
    /// rendition (same pixel budget as the similarity engine's verification pass).
    var thumbnailMaxPixelSize: Int = 256
    /// Analysis bitmap side. Every score and every threshold is only meaningful at this
    /// exact size (see `BlurThresholds` calibration table).
    var analysisSide: Int = BlurSharpnessAnalyzer.defaultAnalysisSide
    /// Classification thresholds. Defaults to the synthetic-calibrated values.
    var thresholds: BlurThresholds = .corpusCalibrated

    init() {}
}

/// The blur analysis engine: one bounded, cancellable, local-only sharpness pass over the
/// image records of a completed catalog.
///
/// Contract:
/// - **Analysis only.** Reads bounded thumbnails (≤ `thumbnailMaxPixelSize`, local-only
///   through the injected `PhotoThumbnailLoading` seam — never the network, never
///   full-resolution pixels) and measures them with `BlurSharpnessAnalyzer`. Never mutates
///   the photo library, never touches selection or deletion, never persists anything.
/// - **Bounded.** A fixed-width worker pool (`maxConcurrentWorkers` strided tasks) — never
///   one task per asset. Every thumbnail is released as soon as its score is computed.
/// - **Cancellable end to end.** Worker loops check cancellation; a cancelled run unwinds
///   through `.cancelled` instead of hanging or landing a stale `.completed`.
/// - **Honest about gaps.** Every input record ends in exactly one bucket: judged (a
///   verdict was produced — sharp, blurry, or uncertain) or unavailable (refused or failed,
///   with a reason). A non-image record is refused as `.notAnalyzable`; a record whose
///   metadata reports no dimensions is refused as `.invalidDimensions` without issuing a
///   request; a failed or unmeasurable thumbnail is refused with the mapped reason.
///   Nothing is ever silently dropped or silently counted as sharp.
struct BlurAnalysisEngine: Sendable {
    let configuration: BlurAnalysisConfiguration
    let thumbnailLoader: any PhotoThumbnailLoading
    /// Optional stage instrumentation for one run (tests, benchmarks, device validation).
    /// Nil in production paths that do not ask for it; recording is a few locked adds per
    /// asset and cannot be observed by classification.
    let metrics: BlurAnalysisMetrics?
    /// Injected clock for the result's `scannedAt` — production passes `Date.init`;
    /// tests pin it so a completed result is exactly reproducible.
    let now: @Sendable () -> Date

    init(
        configuration: BlurAnalysisConfiguration = BlurAnalysisConfiguration(),
        thumbnailLoader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader(),
        metrics: BlurAnalysisMetrics? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.thumbnailLoader = thumbnailLoader
        self.metrics = metrics
        self.now = now
    }

    /// Primary API. Ordered event stream: throttled progress updates, then `.completed`
    /// last on success. Cancelling the consuming task terminates the stream and cancels
    /// the producer — never a hung continuation.
    func makeAnalysisStream(
        records: [PhotoAssetRecord]
    ) -> AsyncThrowingStream<BlurAnalysisEvent, Error> {
        let engine = self
        return AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    let result = try await Self.run(engine: engine, records: records) { progress in
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

    /// Convenience wrapper for callers that only want progress callbacks and the final
    /// result (tests, validation harnesses).
    func analyze(
        records: [PhotoAssetRecord],
        onProgress: @escaping @Sendable (BlurAnalysisProgress) -> Void = { _ in }
    ) async throws -> BlurAnalysisResult {
        var finalResult: BlurAnalysisResult?
        do {
            for try await event in makeAnalysisStream(records: records) {
                switch event {
                case .progress(let progress):
                    onProgress(progress)
                case .completed(let result):
                    finalResult = result
                }
            }
        } catch let failure as BlurAnalysisFailure {
            throw failure
        } catch is CancellationError {
            throw BlurAnalysisFailure.cancelled
        } catch {
            // System error descriptions never reach the user verbatim.
            throw BlurAnalysisFailure.underlying("Sharpness analysis could not finish. Please try again.")
        }
        guard let finalResult else { throw BlurAnalysisFailure.cancelled }
        return finalResult
    }

    // MARK: - Pipeline

    /// One image queued for measurement: the work item carries its input position so
    /// candidates can be reassembled in catalog order after the workers finish.
    private struct WorkItem: Sendable {
        let index: Int
        let record: PhotoAssetRecord
    }

    /// Accumulated verdicts, appended by concurrent workers under one lock.
    private struct Tally: Sendable {
        var sharpCount = 0
        var insufficientInformationCount = 0
        var candidates: [(index: Int, candidate: BlurCandidate)] = []
    }

    private static func run(
        engine: BlurAnalysisEngine,
        records: [PhotoAssetRecord],
        report: @escaping @Sendable (BlurAnalysisProgress) -> Void
    ) async throws -> BlurAnalysisResult {
        let config = engine.configuration
        let workerWidth = max(1, config.maxConcurrentWorkers)
        let runStarted = DispatchTime.now().uptimeNanoseconds
        // Failure-code tally is per run: one summary must never include a previous run's
        // failures (the validation harness runs cancel-then-full in one process).
        PhotoKitFailureTally.reset()
        // Wall time + summary on every exit path — cancelled runs included, because a
        // validation session measures cancellation exactly as much as success.
        defer {
            engine.metrics?.record(.total, seconds: secondsSince(runStarted))
            engine.metrics?.emitSummary()
        }

        guard !Task.isCancelled else { throw BlurAnalysisFailure.cancelled }

        engine.metrics?.set(.assetsConsidered, to: records.count)
        engine.metrics?.set(.workerWidth, to: workerWidth)

        // Partition: every record lands in exactly one bucket up front — refused with a
        // reason, or queued for measurement. Refusals never issue a request.
        let unavailable = LockedBox<[String: PhotoAnalysisUnavailableReason]>([:])
        var work: [WorkItem] = []
        work.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if !record.isImage {
                unavailable.insert(record.localIdentifier, reason: .notAnalyzable)
                continue
            }
            if record.pixelWidth <= 0 || record.pixelHeight <= 0 {
                unavailable.insert(record.localIdentifier, reason: .invalidDimensions)
                continue
            }
            work.append(WorkItem(index: index, record: record))
        }
        engine.metrics?.set(.refusedUpFront, to: records.count - work.count)

        let reporter = BlurProgressReporter(total: work.count) { progress in
            // Emissions only (post-throttling): what the consumer actually saw.
            engine.metrics?.increment(.progressTicks)
            report(progress)
        }
        reporter.start()

        let tally = LockedBox<Tally>(Tally())
        try await BoundedWorkers.run(items: work, width: workerWidth) { item in
            guard !Task.isCancelled else { return }
            let assetID = item.record.localIdentifier
            do {
                try Task.checkCancellation()
                engine.metrics?.increment(.requestsAttempted)
                let requestStarted = DispatchTime.now().uptimeNanoseconds
                let image: CGImage
                do {
                    image = try await engine.thumbnailLoader.thumbnail(
                        for: assetID,
                        targetPixelSize: config.thumbnailMaxPixelSize,
                        mode: .sharpness
                    )
                    engine.metrics?.record(.request, seconds: secondsSince(requestStarted))
                    engine.metrics?.increment(.requestsSucceeded)
                    if min(image.width, image.height) < config.analysisSide {
                        engine.metrics?.increment(.renditionsBelowBudget)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    engine.metrics?.record(.request, seconds: secondsSince(requestStarted))
                    engine.metrics?.increment(.requestsFailed)
                    if error is PhotoRequestTimeoutError {
                        engine.metrics?.increment(.requestsTimedOut)
                    }
                    if let contentError = error as? PhotoContentError, case .onlyInICloud = contentError {
                        engine.metrics?.increment(.requestsICloud)
                    }
                    throw error
                }
                let measureStarted = DispatchTime.now().uptimeNanoseconds
                let score = try BlurSharpnessAnalyzer.measure(
                    of: image,
                    analysisSide: config.analysisSide
                )
                engine.metrics?.record(.measure, seconds: secondsSince(measureStarted))
                let classifyStarted = DispatchTime.now().uptimeNanoseconds
                let verdict = config.thresholds.classify(score)
                engine.metrics?.record(.classify, seconds: secondsSince(classifyStarted))
                try Task.checkCancellation()
                tally.mutate { state in
                    switch verdict {
                    case .sharp:
                        state.sharpCount += 1
                    case .insufficientInformation:
                        state.insufficientInformationCount += 1
                    case .likelyBlurry, .borderline:
                        state.candidates.append(
                            (
                                index: item.index,
                                candidate: BlurCandidate(
                                    assetID: assetID,
                                    verdict: verdict,
                                    laplacianVariance: score.laplacianVariance
                                )
                            )
                        )
                    }
                }
                switch verdict {
                case .sharp:
                    engine.metrics?.increment(.judgedSharp)
                case .insufficientInformation:
                    engine.metrics?.increment(.judgedInsufficient)
                case .likelyBlurry:
                    engine.metrics?.increment(.judgedLikelyBlurry)
                case .borderline:
                    engine.metrics?.increment(.judgedBorderline)
                }
                reporter.advance()
            } catch is CancellationError {
                // The user left: stop every worker instead of finishing their queues.
                throw CancellationError()
            } catch {
                // One unreadable asset costs one report, never the run.
                unavailable.insert(assetID, reason: unavailableReason(for: error))
                reporter.advance()
            }
        }

        guard !Task.isCancelled else { throw BlurAnalysisFailure.cancelled }
        // Terminal event on every success path, so the UI can rely on `completed == total`.
        reporter.finish()

        let finalTally = tally.read()
        let reasons = unavailable.read()
        for reason in reasons.values {
            engine.metrics?.incrementReason(reason)
        }

        // Unavailable assets in input order — deterministic regardless of worker timing.
        let unavailableAssets = records.compactMap { record -> PhotoAnalysisUnavailable? in
            guard let reason = reasons[record.localIdentifier] else { return nil }
            return PhotoAnalysisUnavailable(assetID: record.localIdentifier, reason: reason)
        }

        return BlurAnalysisResult(
            candidates: finalTally.candidates
                .sorted { $0.index < $1.index }
                .map(\.candidate),
            unavailableAssets: unavailableAssets,
            sharpCount: finalTally.sharpCount,
            insufficientInformationCount: finalTally.insufficientInformationCount,
            totalRecordCount: records.count,
            thresholdsUsed: config.thresholds,
            scannedAt: engine.now()
        )
    }

    /// Maps an error from the thumbnail or measurement seam to the honest unavailable
    /// reason the UI will show — the same granular vocabulary similarity analysis uses,
    /// so "could not measure" is never mistaken for "not blurry".
    static func unavailableReason(for error: any Error) -> PhotoAnalysisUnavailableReason {
        if error is PhotoRequestTimeoutError { return .timedOut }
        if let contentError = error as? PhotoContentError {
            switch contentError {
            case .permissionDenied:
                return .permissionUnavailable
            case .assetNotFound:
                return .assetNotFound
            case .onlyInICloud:
                return .contentOnlyInICloud
            case .unavailable:
                return .imageUnavailable
            }
        }
        if error is BlurSharpnessError { return .imageUnavailable }
        if let reason = error as? PhotoAnalysisUnavailableReason { return reason }
        return .imageUnavailable
    }

    /// Monotonic nanosecond delta to seconds — the timing unit every recorded stage uses.
    private static func secondsSince(_ startNanos: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000
    }
}

// MARK: - Progress reporting

/// Serialized, throttled progress for the blur pass: counters under one lock so concurrent
/// workers can never emit a disagreeing pair, at most one intermediate tick per
/// `minEmitIntervalNanos` (250 ms), and — unlike a merely-throttled tick — the *terminal*
/// event (`completed >= total`) is always published, so the final applied event before
/// `.completed` always carries the true counts. Counters keep moving between emissions,
/// so the next published event carries the true state.
final class BlurProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private let total: Int
    private var lastEmitUptime: UInt64 = 0
    private let minEmitIntervalNanos: UInt64
    private let report: @Sendable (BlurAnalysisProgress) -> Void

    init(
        total: Int,
        minEmitIntervalNanos: UInt64 = 250_000_000,
        report: @escaping @Sendable (BlurAnalysisProgress) -> Void
    ) {
        self.total = total
        self.minEmitIntervalNanos = minEmitIntervalNanos
        self.report = report
    }

    /// Emits the starting event (`0 / total`) unconditionally — the UI needs the total to
    /// show a fraction from the first frame.
    func start() {
        emit(BlurAnalysisProgress(completedUnits: 0, totalUnits: total))
    }

    /// One work item finished (judged or refused). Intermediate emissions are throttled;
    /// reaching `completed == total` is not.
    func advance() {
        lock.lock()
        completed += 1
        let current = completed
        lock.unlock()
        guard current >= total || throttled() else { return }
        emit(BlurAnalysisProgress(completedUnits: current, totalUnits: total))
    }

    /// Forces the terminal event on the success path, so `.completed` is always preceded
    /// by `completed == total` even when the last advance was coalesced away.
    func finish() {
        lock.lock()
        completed = max(completed, total)
        let current = completed
        lock.unlock()
        emit(BlurAnalysisProgress(completedUnits: current, totalUnits: total))
    }

    private func throttled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastEmitUptime >= minEmitIntervalNanos else { return false }
        lastEmitUptime = now
        return true
    }

    private func emit(_ progress: BlurAnalysisProgress) {
        lock.lock()
        lastEmitUptime = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        report(progress)
    }
}
