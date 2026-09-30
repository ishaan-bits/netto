import CoreGraphics
import Foundation

struct PhotoAnalysisConfiguration: Sendable, Equatable {
    /// Metadata bucketing rules (aspect tolerance, temporal gap, bucket size cap).
    var bucketing: CandidateBucketsConfiguration = .default
    /// L2 threshold for near-duplicate grouping. `nil` → the descriptor family's provisional
    /// default (`FeaturePrintKind.defaultSimilarityThreshold`), which is calibrated only on
    /// synthetic images and flagged for real-device recalibration.
    var similarityThreshold: Float?
    /// Fixed worker width for fingerprinting and extraction. Never one task per asset.
    var maxConcurrentWorkers: Int = 4
    /// Longest thumbnail side requested from PhotoKit. Full-resolution pixels are never decoded.
    var thumbnailMaxPixelSize: Int = 256

    init() {}
}

/// The photo similarity analysis engine: exact duplicates by content fingerprint, near
/// duplicates by visual descriptor, over a catalog of `PhotoAssetRecord`s.
///
/// Contract:
/// - **Analysis only.** Reads metadata, thumbnails, and (for length collisions) content bytes.
///   Never mutates the photo library, never requests network access, never retains full-
///   resolution pixels or `UIImage`s.
/// - **Bounded work.** Two independent complexity bounds: exact detection costs one stat per
///   asset plus SHA-256 only for byte-length collisions; near detection compares only inside
///   candidate buckets (`Σ size(size-1)/2`, never `n(n-1)/2`), with a fixed-width worker pool.
/// - **Cancellable end to end.** Stream termination cancels the producer; every stage boundary
///   and worker loop checks cancellation; in-flight PhotoKit requests are cancelled through
///   `PendingPhotoRequest`.
/// - **Honest about gaps.** Assets that cannot be analyzed are reported with a reason, never
///   silently classified as duplicates or as clean.
struct PhotoSimilarityEngine: Sendable {
    let configuration: PhotoAnalysisConfiguration
    let fingerprinter: any ContentFingerprinting
    let thumbnailLoader: any PhotoThumbnailLoading
    let featureExtractor: any PhotoFeatureExtracting
    let stageObserver: any PhotoAnalysisStageObserving
    /// Device-validation hooks; `nil` (the default) records nothing. Tests inject one and read
    /// `snapshot()` — see `AnalysisMetrics`.
    let metrics: AnalysisMetrics?

    init(
        configuration: PhotoAnalysisConfiguration = PhotoAnalysisConfiguration(),
        fingerprinter: any ContentFingerprinting = PhotoKitContentFingerprinter(),
        thumbnailLoader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader(),
        featureExtractor: any PhotoFeatureExtracting = VisionPhotoFeatureExtractor(),
        stageObserver: any PhotoAnalysisStageObserving = NoopStageObserver(),
        metrics: AnalysisMetrics? = nil
    ) {
        self.configuration = configuration
        self.fingerprinter = fingerprinter
        self.thumbnailLoader = thumbnailLoader
        self.featureExtractor = featureExtractor
        self.stageObserver = stageObserver
        self.metrics = metrics
    }

    /// Primary API. Ordered event stream: every progress update, then `.completed` last on
    /// success. Cancelling the consuming task terminates the stream and cancels the producer,
    /// which then unwinds through its cancellation checks — never a hung continuation.
    func makeAnalysisStream(
        records: [PhotoAssetRecord]
    ) -> AsyncThrowingStream<PhotoAnalysisEvent, Error> {
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

    /// Convenience wrapper for callers that only want progress callbacks and the final result.
    func analyze(
        records: [PhotoAssetRecord],
        onProgress: @escaping @Sendable (PhotoAnalysisProgress) -> Void = { _ in }
    ) async throws -> PhotoAnalysisResult {
        var finalResult: PhotoAnalysisResult?
        do {
            for try await event in makeAnalysisStream(records: records) {
                switch event {
                case .progress(let progress):
                    onProgress(progress)
                case .completed(let result):
                    finalResult = result
                }
            }
        } catch let failure as PhotoAnalysisFailure {
            throw failure
        } catch is CancellationError {
            throw PhotoAnalysisFailure.cancelled
        } catch {
            // System error descriptions never reach the user verbatim.
            throw PhotoAnalysisFailure.underlying("Similarity analysis could not finish. Please try again.")
        }
        guard let finalResult else { throw PhotoAnalysisFailure.cancelled }
        return finalResult
    }

    // MARK: - Pipeline

    private static func run(
        engine: PhotoSimilarityEngine,
        records: [PhotoAssetRecord],
        report: @escaping @Sendable (PhotoAnalysisProgress) -> Void
    ) async throws -> PhotoAnalysisResult {
        let runStart = DispatchTime.now().uptimeNanoseconds
        let metrics = engine.metrics
        defer {
            engine.stageObserver.analysisDidFinish()
            // Total is recorded on every exit path — cancelled runs included, because a
            // device-validation session measures cancellation exactly as much as success.
            metrics?.record(.total, seconds: secondsSince(runStart))
            metrics?.emitSummary()
        }
        let reporter = AnalysisProgressReporter(observer: engine.stageObserver, report: report)
        let config = engine.configuration
        let workerWidth = max(1, config.maxConcurrentWorkers)

        // Stage 1: preparing — index records by id (first occurrence wins; ids are unique from
        // PhotoKit, but a hostile input must not trap).
        try reporter.enter(.preparing, total: 1)
        try checkCancellation()
        let recordsByID = Dictionary(
            records.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        try reporter.complete(.preparing, total: 1)

        // Stage 2: generatingCandidates — pure metadata bucketing. Total is 0 (indeterminate):
        // a single synchronous pass has no meaningful sub-unit tick to report.
        try reporter.enter(.generatingCandidates, total: 0)
        try checkCancellation()
        let candidatesStart = DispatchTime.now().uptimeNanoseconds
        let bucketing = CandidateBuckets.make(
            records: records,
            configuration: config.bucketing
        )
        metrics?.record(.candidates, seconds: secondsSince(candidatesStart))
        try reporter.complete(.generatingCandidates, total: 0)

        let unavailable = LockedBox<[String: PhotoAnalysisUnavailableReason]>([:])
        for exclusion in bucketing.exclusions {
            unavailable.insert(exclusion.assetID, reason: exclusion.reason)
        }
        for record in records where !record.isImage && !record.isVideo {
            unavailable.insert(record.localIdentifier, reason: .notAnalyzable)
        }

        // Stage 3: fingerprinting — exact-duplicate detection, two phases.
        // Phase 1 stats content lengths for every image/video asset (no content read) and
        // ticks progress per asset, so the longest phase of the scan shows real movement
        // instead of sitting at 0 of N. Phase 2 hashes only byte-length collisions; the total
        // grows by the collision count so each hash pass ticks too, and the stage ends at
        // completed == total either way.
        let eligible = records.filter { $0.isImage || $0.isVideo }
        try reporter.enter(.fingerprinting, total: eligible.count)

        let byteKeys = LockedBox<[String: ContentByteKey]>([:])
        try await BoundedWorkers.run(items: eligible, width: workerWidth) { record in
            guard !Task.isCancelled else { return }
            do {
                try Task.checkCancellation()
                let phaseStart = DispatchTime.now().uptimeNanoseconds
                let outcome = try await engine.fingerprinter.byteKey(for: record)
                metrics?.record(.fingerprint, seconds: secondsSince(phaseStart))
                switch outcome {
                case .key(let key):
                    byteKeys.write(record.localIdentifier, key)
                case .unavailable(let reason):
                    unavailable.insert(record.localIdentifier, reason: reason)
                }
            } catch is CancellationError {
                return
            } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                return
            } catch {
                unavailable.insert(record.localIdentifier, reason: .contentUnreadable)
            }
            // Every eligible asset ticks exactly once, on the outcome — key, unavailable, or
            // error — including timed-out requests, so phase 1 can never appear frozen.
            try reporter.advance(.fingerprinting, total: eligible.count)
        }
        try checkCancellation()

        var byKey: [ContentByteKey: [String]] = [:]
        for (assetID, key) in byteKeys.read() {
            byKey[key, default: []].append(assetID)
        }
        let collidingIDs = byKey.values
            .filter { $0.count > 1 }
            .flatMap { $0 }
            .sorted()
        // Completed is already `eligible.count` (phase 1 ticked every asset). The total grows
        // by the collision count so phase 2's hashes are counted units — progress stays
        // monotonic and the stage still ends exactly at completed == total.
        try reporter.setCount(
            .fingerprinting,
            completed: eligible.count,
            total: eligible.count + collidingIDs.count
        )

        let fingerprints = LockedBox<[String: ContentFingerprint]>([:])
        let collidingRecords = collidingIDs.compactMap { recordsByID[$0] }
        try await BoundedWorkers.run(items: collidingRecords, width: workerWidth) { record in
            guard !Task.isCancelled else { return }
            do {
                try Task.checkCancellation()
                let phaseStart = DispatchTime.now().uptimeNanoseconds
                let outcome = try await engine.fingerprinter.fingerprint(for: record)
                metrics?.record(.fingerprint, seconds: secondsSince(phaseStart))
                switch outcome {
                case .fingerprinted(let fingerprint):
                    fingerprints.write(record.localIdentifier, fingerprint)
                case .unavailable(let reason):
                    unavailable.insert(record.localIdentifier, reason: reason)
                }
            } catch is CancellationError {
                return
            } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                return
            } catch {
                unavailable.insert(record.localIdentifier, reason: .contentUnreadable)
            }
            try reporter.advance(.fingerprinting, total: eligible.count + collidingIDs.count)
        }
        try checkCancellation()

        // Stages 4+5: extractingFeatures ↔ comparing — interleaved per bucket. Each bucket's
        // prints are extracted, compared, and released before the next bucket starts, so at most
        // `workerWidth × maxBucketSize` prints (a few hundred KB) are alive at once.
        let bucketedAssetCount = bucketing.buckets.reduce(0) { $0 + $1.records.count }
        let descriptorKind: FeaturePrintKind?
        if bucketedAssetCount > 0 {
            await engine.featureExtractor.prepare()
            descriptorKind = engine.featureExtractor.kind
        } else {
            descriptorKind = nil
        }
        let workerThreshold = descriptorKind.map {
            config.similarityThreshold ?? $0.defaultSimilarityThreshold
        } ?? FeaturePrintKind.cpuGrid.defaultSimilarityThreshold

        try reporter.enter(.extractingFeatures, total: bucketedAssetCount)
        let extractionTotal = bucketedAssetCount
        let comparisonTotal = bucketing.buckets.count
        let relations = LockedBox<[PairRelation]>([])

        try await BoundedWorkers.run(items: bucketing.buckets, width: workerWidth) { bucket in
            guard !Task.isCancelled else { return }

            var prints: [(assetID: String, print: FeaturePrint)] = []
            prints.reserveCapacity(bucket.records.count)
            for record in bucket.records {
                if Task.isCancelled { return }
                do {
                    try Task.checkCancellation()
                    let thumbnailStart = DispatchTime.now().uptimeNanoseconds
                    let thumbnail = try await engine.thumbnailLoader.thumbnail(
                        for: record.localIdentifier,
                        targetPixelSize: config.thumbnailMaxPixelSize
                    )
                    metrics?.record(.thumbnail, seconds: secondsSince(thumbnailStart))
                    let descriptorStart = DispatchTime.now().uptimeNanoseconds
                    let featurePrint = try await engine.featureExtractor.featurePrint(
                        for: thumbnail
                    )
                    metrics?.record(.descriptor, seconds: secondsSince(descriptorStart))
                    metrics?.increment(.descriptorsExtracted)
                    prints.append((record.localIdentifier, featurePrint))
                } catch is CancellationError {
                    return
                } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                    return
                } catch {
                    unavailable.insert(
                        record.localIdentifier,
                        reason: unavailableReason(for: error, kind: descriptorKind)
                    )
                }
                try reporter.advance(.extractingFeatures, total: extractionTotal)
            }

            // Compare every pair inside the bucket (bucket ≤ maxBucketSize, so this is a small
            // constant, not library-scale work).
            let knownFingerprints = fingerprints.read()
            var bucketRelations: [PairRelation] = []
            if prints.count > 1 {
                let compareStart = DispatchTime.now().uptimeNanoseconds
                for firstIndex in 0..<prints.count {
                    for secondIndex in (firstIndex + 1)..<prints.count {
                        let lhs = prints[firstIndex]
                        let rhs = prints[secondIndex]
                        guard let distance = try? lhs.print.distance(to: rhs.print),
                              distance <= workerThreshold else { continue }
                        // Byte-identical pairs belong to the exact group; reporting them as
                        // "near" too would double-count one piece of content.
                        if let leftPrint = knownFingerprints[lhs.assetID],
                           let rightPrint = knownFingerprints[rhs.assetID],
                           leftPrint == rightPrint {
                            continue
                        }
                        bucketRelations.append(
                            PairRelation(
                                assetA: lhs.assetID,
                                assetB: rhs.assetID,
                                distance: distance
                            )
                        )
                    }
                }
                metrics?.record(.comparison, seconds: secondsSince(compareStart))
            }
            if !bucketRelations.isEmpty {
                relations.append(bucketRelations)
            }
            try reporter.advance(.comparing, total: comparisonTotal)
        }
        try checkCancellation()
        try reporter.complete(.extractingFeatures, total: extractionTotal)
        try reporter.complete(.comparing, total: comparisonTotal)

        // Stage 6: grouping — cliques from relations, groups from fingerprints.
        try reporter.enter(.grouping, total: 1)
        try checkCancellation()
        let groupingStart = DispatchTime.now().uptimeNanoseconds
        let exactGroups = SimilarityGrouping.exactGroups(
            fingerprints: fingerprints.read(),
            records: recordsByID
        )
        let similarGroups = SimilarityGrouping.nearGroups(
            relations: relations.read(),
            threshold: workerThreshold,
            records: recordsByID
        )
        metrics?.record(.grouping, seconds: secondsSince(groupingStart))
        try reporter.complete(.grouping, total: 1)

        // Stage 7: finalizing — deterministic ordering and the result envelope.
        try reporter.enter(.finalizing, total: 1)
        try checkCancellation()
        let unavailableList = unavailable.read()
            .map { PhotoAnalysisUnavailable(assetID: $0.key, reason: $0.value) }
            .sorted { $0.assetID < $1.assetID }

        metrics?.set(.assetsConsidered, to: records.count)
        metrics?.set(.assetsFingerprinted, to: byteKeys.read().count)
        metrics?.set(.assetsUnavailable, to: unavailableList.count)
        metrics?.set(.exactGroups, to: exactGroups.count)
        metrics?.set(.similarGroups, to: similarGroups.count)

        let result = PhotoAnalysisResult(
            exactGroups: exactGroups,
            similarGroups: similarGroups,
            unavailableAssets: unavailableList,
            descriptorKind: descriptorKind,
            visionAvailable: descriptorKind == .visionFeaturePrint,
            similarityThreshold: descriptorKind == nil ? nil : workerThreshold,
            totalRecordCount: records.count,
            candidateBucketCount: bucketing.buckets.count,
            candidatePairCount: bucketing.candidatePairCount
        )
        try reporter.complete(.finalizing, total: 1)
        return result
    }

    /// Maps an error from a live seam to the honest unavailable reason the UI will show. The
    /// vocabulary stays granular on purpose (permission off / asset deleted / iCloud-only /
    /// unreadable / thumbnail failed / Vision failed / CPU fallback failed) — see §10 of
    /// ARCHITECTURE.md — so "could not analyze" is never mistaken for "not a duplicate".
    private static func unavailableReason(
        for error: any Error,
        kind: FeaturePrintKind?
    ) -> PhotoAnalysisUnavailableReason {
        if let contentError = error as? PhotoContentError {
            switch contentError {
            case .onlyInICloud:
                return .contentOnlyInICloud
            case .permissionDenied:
                return .permissionUnavailable
            case .assetNotFound:
                return .assetNotFound
            case .unavailable:
                return .imageUnavailable
            }
        }
        if let extractionError = error as? FeatureExtractionError {
            switch extractionError {
            case .backendUnavailable, .invalidImage:
                // Which descriptor family the run latched decides whose failure this is: a
                // Vision-run failure is `.visionFailed`, a CPU-fallback failure is
                // `.cpuDescriptorFailed` — never one collapsed "image unavailable".
                switch kind {
                case .visionFeaturePrint: return .visionFailed
                case .cpuGrid: return .cpuDescriptorFailed
                case nil: return .imageUnavailable
                }
            }
        }
        if let reason = error as? PhotoAnalysisUnavailableReason {
            return reason
        }
        return .imageUnavailable
    }

    private static func secondsSince(_ startNanoseconds: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000_000
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw PhotoAnalysisFailure.cancelled }
    }
}

// MARK: - Concurrency helpers

/// Fixed-width strided worker pool: `width` tasks, each taking items `i, i + width, …`.
/// Never one task per asset — peak memory and CPU utilization stay bounded regardless of
/// library size.
enum BoundedWorkers {
    static func run<Item: Sendable>(
        items: [Item],
        width: Int,
        task: @escaping @Sendable (Item) async throws -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        let workerCount = max(1, min(width, items.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for start in 0..<workerCount {
                group.addTask {
                    var index = start
                    while index < items.count {
                        if Task.isCancelled { return }
                        try await task(items[index])
                        index += workerCount
                    }
                }
            }
            do {
                for try await _ in group {}
            } catch {
                // First failure (observer abort, cancellation) stops the remaining workers
                // immediately instead of draining the queue.
                group.cancelAll()
                throw error
            }
        }
    }
}

/// `@unchecked Sendable`: every access goes through `lock`.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
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

    func write(_ key: String, _ newValue: ContentByteKey) where Value == [String: ContentByteKey] {
        lock.lock()
        value[key] = newValue
        lock.unlock()
    }

    func write(_ key: String, _ newValue: ContentFingerprint) where Value == [String: ContentFingerprint] {
        lock.lock()
        value[key] = newValue
        lock.unlock()
    }

    func append(_ newValues: [PairRelation]) where Value == [PairRelation] {
        lock.lock()
        value.append(contentsOf: newValues)
        lock.unlock()
    }

    /// First reason wins: the earlier (usually more specific) failure is the one reported.
    func insert(_ key: String, reason: PhotoAnalysisUnavailableReason)
        where Value == [String: PhotoAnalysisUnavailableReason] {
        lock.lock()
        if value[key] == nil { value[key] = reason }
        lock.unlock()
    }
}

/// Serialized progress/stage reporting: counters, stage-transition detection, observer callback,
/// and stream yield all happen under one lock so concurrent workers can never emit an event
/// whose counters disagree with its stage. The report closure must be non-blocking (it is a
/// stream yield) and the observer must not re-enter the reporter.
///
/// Emission is throttled so a 40 000-asset phase costs the main actor a bounded number of
/// updates per second instead of one per asset: stage transitions, total changes, terminal
/// counts (`completed >= total`), and at most one intermediate tick per
/// `minEmitIntervalNanos` are published; anything between those is coalesced away. Counters
/// always keep moving, so the next published event carries the true state.
final class AnalysisProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [PhotoAnalysisStage: Int] = [:]
    private var lastStage: PhotoAnalysisStage?
    private var lastProgress: PhotoAnalysisProgress?
    private var lastEmitUptime: UInt64 = 0
    private let minEmitIntervalNanos: UInt64
    private let observer: any PhotoAnalysisStageObserving
    private let report: @Sendable (PhotoAnalysisProgress) -> Void

    init(
        observer: any PhotoAnalysisStageObserving,
        report: @escaping @Sendable (PhotoAnalysisProgress) -> Void,
        minEmitIntervalNanos: UInt64 = 100_000_000
    ) {
        self.observer = observer
        self.report = report
        self.minEmitIntervalNanos = minEmitIntervalNanos
    }

    func enter(_ stage: PhotoAnalysisStage, total: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try emitLocked(stage, completed: counts[stage] ?? 0, total: total)
    }

    func advance(_ stage: PhotoAnalysisStage, total: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        counts[stage, default: 0] += 1
        try emitLocked(stage, completed: counts[stage] ?? 0, total: total)
    }

    func setCount(_ stage: PhotoAnalysisStage, completed: Int, total: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        counts[stage] = completed
        try emitLocked(stage, completed: completed, total: total)
    }

    func complete(_ stage: PhotoAnalysisStage, total: Int) throws {
        try setCount(stage, completed: total, total: total)
    }

    private func emitLocked(_ stage: PhotoAnalysisStage, completed: Int, total: Int) throws {
        let stageChanged = lastStage != stage
        lastStage = stage
        if stageChanged {
            try observer.analysisStageWillBegin(stage)
        }

        let progress = PhotoAnalysisProgress(
            stage: stage,
            completedUnits: completed,
            totalUnits: total
        )
        let previous = lastProgress
        let totalChanged = previous?.stage == stage && previous?.totalUnits != total
        let terminal = completed >= total
        let now = DispatchTime.now().uptimeNanoseconds
        let intervalElapsed = now &- lastEmitUptime >= minEmitIntervalNanos
        guard stageChanged || totalChanged || terminal || intervalElapsed else { return }

        lastEmitUptime = now
        lastProgress = progress
        report(progress)
    }
}
