import CoreGraphics
import Foundation

struct PhotoAnalysisConfiguration: Sendable, Equatable {
    /// Metadata bucketing rules (aspect tolerance, temporal gap, bucket size cap, video
    /// duration quantum).
    var bucketing: CandidateBucketsConfiguration = .default
    /// L2 threshold for near-duplicate grouping. `nil` → the descriptor family's provisional
    /// default (`FeaturePrintKind.defaultSimilarityThreshold`), which is calibrated only on
    /// synthetic images and flagged for real-device recalibration.
    var similarityThreshold: Float?
    /// Fixed worker width for fingerprinting and extraction. Never one task per asset.
    var maxConcurrentWorkers: Int = 4
    /// Requests in flight during the cheap perceptual pass. That pass is network-bound: an
    /// asset that is not local waits on Photos' make-available path for seconds each, so at
    /// `maxConcurrentWorkers` the cheap stage alone would take hours on a non-local library.
    /// Bounded and explicit — never one task per asset (64 ≪ library size).
    var fingerprintThumbnailConcurrency: Int = 64
    /// Longest thumbnail side for the cheap perceptual gate. Small on purpose: this pass only
    /// decides which pairs are worth a descriptor, and it runs for every multi-bucket image.
    var perceptualThumbnailMaxPixelSize: Int = 96
    /// Longest thumbnail side for descriptor input — the pixels the near-duplicate decision
    /// rests on, so this one is exact.
    var verificationThumbnailMaxPixelSize: Int = 256
    /// Hamming distance (of 64) within which two same-bucket images still earn a descriptor
    /// comparison. Deliberately generous: a false positive costs one small thumbnail and one
    /// descriptor; a false negative silently loses a candidate pair.
    var perceptualCandidateMaxHamming: Int = 16
    /// Where the run reads the device's thermal state (`ScanConcurrencyPolicy`). A policy
    /// source, not a tuning value — excluded from `==` (see below). Tests pin it to a fixed
    /// state; production reads `ProcessInfo` fresh at every decision.
    var thermalState: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }

    init() {}

    /// Equality over the tuning values only: the thermal source is a function, and two
    /// configs with the same widths/thresholds are the same configuration no matter where
    /// the thermal reading comes from.
    static func == (lhs: PhotoAnalysisConfiguration, rhs: PhotoAnalysisConfiguration) -> Bool {
        lhs.bucketing == rhs.bucketing
            && lhs.similarityThreshold == rhs.similarityThreshold
            && lhs.maxConcurrentWorkers == rhs.maxConcurrentWorkers
            && lhs.fingerprintThumbnailConcurrency == rhs.fingerprintThumbnailConcurrency
            && lhs.perceptualThumbnailMaxPixelSize == rhs.perceptualThumbnailMaxPixelSize
            && lhs.verificationThumbnailMaxPixelSize == rhs.verificationThumbnailMaxPixelSize
            && lhs.perceptualCandidateMaxHamming == rhs.perceptualCandidateMaxHamming
    }
}

/// The photo similarity analysis engine: exact duplicates by content fingerprint, near
/// duplicates by visual descriptor, over a catalog of `PhotoAssetRecord`s.
///
/// Contract:
/// - **Analysis only.** Reads metadata, bounded thumbnails, and (for confirmed exact pairs)
///   content bytes. Never mutates the photo library, never requests network access (thumbnails
///   and content are both local-only — see `PhotoKitThumbnailLoader`), never retains
///   full-resolution pixels or `UIImage`s.
/// - **Cheap first.** Work is ordered so the expensive passes run only for assets that survive
///   the cheap ones: metadata buckets skip singletons outright; multi-bucket images cost one
///   96 px perceptual thumbnail (no Vision, no content); descriptors are extracted only for
///   pairs within `perceptualCandidateMaxHamming`; content bytes are read only to confirm
///   perceptually identical pairs (images) or length-colliding videos. Complexity stays
///   `Σ size(size-1)/2` inside buckets — never `n(n-1)/2` — with a fixed-width worker pool.
/// - **Cancellable end to end.** Stream termination cancels the producer; every stage boundary
///   and worker loop checks cancellation; in-flight PhotoKit requests are cancelled through
///   `PendingPhotoRequest`.
/// - **Honest about gaps.** Every asset ends in exactly one bucket: analyzed (evidence
///   produced), unavailable (a request failed, with a reason), or skipped (no candidate partner
///   could exist — reported as skipped, never as failed and never as analyzed).
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
        // Failure-code tally is per run: one summary must never include a previous run's
        // failures (the validation harness runs cancel-then-full in one process).
        PhotoKitFailureTally.reset()
        defer {
            engine.stageObserver.analysisDidFinish()
            // Total is recorded on every exit path — cancelled runs included, because a
            // device-validation session measures cancellation exactly as much as success.
            metrics?.record(.total, seconds: secondsSince(runStart))
            metrics?.emitSummary()
        }
        let reporter = AnalysisProgressReporter(observer: engine.stageObserver, report: report)
        let config = engine.configuration
        // Thermal-adaptive widths: the configured bounds above, scaled by the device's
        // current thermal state (nominal → unchanged). Read once for the width decisions;
        // the per-item `waitWhileCritical` calls below re-read it for pausing.
        let thermalPolicy = ScanConcurrencyPolicy(thermalState: config.thermalState)
        let workerWidth = thermalPolicy.width(base: config.maxConcurrentWorkers)

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
        // Partition shape, recorded once: how much of the library sits in singletons (skip
        // candidates under cheap-first) versus multi-record buckets (thumbnail-eligible).
        let bucketSizes = bucketing.buckets.map(\.records.count)
        metrics?.set(.bucketCount, to: bucketing.buckets.count)
        metrics?.set(.bucketSingletons, to: bucketSizes.filter { $0 == 1 }.count)
        metrics?.set(.bucketMulti, to: bucketSizes.filter { $0 > 1 }.count)
        metrics?.set(
            .bucketMultiAssets,
            to: bucketSizes.reduce(0) { $0 + ($1 > 1 ? $1 : 0) }
        )
        metrics?.set(.videoBuckets, to: bucketing.videoBuckets.count)
        metrics?.set(.candidatePairs, to: bucketing.candidatePairCount)
        try reporter.complete(.generatingCandidates, total: 0)

        let unavailable = LockedBox<[String: PhotoAnalysisUnavailableReason]>([:])
        for exclusion in bucketing.exclusions {
            unavailable.insert(exclusion.assetID, reason: exclusion.reason)
        }
        for record in records where !record.isImage && !record.isVideo {
            unavailable.insert(record.localIdentifier, reason: .notAnalyzable)
        }

        // Cheap-first work partition:
        // - multi-record image buckets → one 96 px perceptual thumbnail each (the candidate gate);
        // - multi-record video buckets → one content-length stat each (exact path);
        // - singletons (image and video) → skipped: no partner can exist inside their bucket,
        //   so no request is ever issued for them.
        let multiImageBuckets = bucketing.buckets.filter { $0.records.count > 1 }
        let multiVideoBuckets = bucketing.videoBuckets.filter { $0.records.count > 1 }
        let skippedImageCount = bucketing.buckets.filter { $0.records.count == 1 }.count
        let skippedVideoCount = bucketing.videoBuckets.filter { $0.records.count == 1 }.count
        metrics?.set(.thumbnailsSkipped, to: skippedImageCount)
        metrics?.set(.assetsSkipped, to: skippedImageCount + skippedVideoCount)

        var cheapWork: [AnalysisCheapWork] = []
        cheapWork.reserveCapacity(
            multiImageBuckets.reduce(0) { $0 + $1.records.count }
                + multiVideoBuckets.reduce(0) { $0 + $1.records.count }
        )
        for bucket in multiImageBuckets {
            for record in bucket.records { cheapWork.append(.perceptualHash(record)) }
        }
        for bucket in multiVideoBuckets {
            for record in bucket.records { cheapWork.append(.videoByteKey(record)) }
        }
        let cheapCount = cheapWork.count

        // Stage 3: fingerprinting — the cheap evidence pass. Images get a perceptual hash
        // (no Vision, no content bytes); videos get a length stat (no content bytes). The
        // total is the work-item count and grows by the video length-collision count so the
        // SHA pass is counted units too — the stage always ends at completed == total.
        let fingerprintWallStart = DispatchTime.now().uptimeNanoseconds
        try reporter.enter(.fingerprinting, total: cheapCount)

        let perceptualHashes = LockedBox<[String: PerceptualHash]>([:])
        let byteKeys = LockedBox<[String: ContentByteKey]>([:])
        let fingerprintWidth = max(
            workerWidth,
            thermalPolicy.width(base: config.fingerprintThumbnailConcurrency)
        )
        try await BoundedWorkers.run(items: cheapWork, width: fingerprintWidth) { work in
            guard !Task.isCancelled else { return }
            try await thermalPolicy.waitWhileCritical()
            switch work {
            case .perceptualHash(let record):
                let phaseStart = DispatchTime.now().uptimeNanoseconds
                metrics?.increment(.thumbnailsRequested)
                do {
                    try Task.checkCancellation()
                    let image = try await engine.thumbnailLoader.thumbnail(
                        for: record.localIdentifier,
                        targetPixelSize: config.perceptualThumbnailMaxPixelSize,
                        mode: .perceptual
                    )
                    let elapsed = secondsSince(phaseStart)
                    metrics?.record(.thumbnail, seconds: elapsed)
                    let hash = try PerceptualHasher.hash(of: image)
                    metrics?.increment(.thumbnailsSucceeded)
                    perceptualHashes.write(record.localIdentifier, hash)
                } catch is CancellationError {
                    return
                } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                    return
                } catch {
                    // Failed requests are timed and counted separately: on a non-local library
                    // they are the dominant cost, and the split is what the validation report
                    // reads. A hash failure after a successful fetch lands here too — the asset
                    // produced no usable visual evidence.
                    let elapsed = secondsSince(phaseStart)
                    metrics?.record(.thumbnail, seconds: elapsed)
                    metrics?.record(.thumbnailFailed, seconds: elapsed)
                    metrics?.increment(.thumbnailsFailed)
                    unavailable.insert(
                        record.localIdentifier,
                        reason: unavailableReason(for: error, kind: nil)
                    )
                }
            case .videoByteKey(let record):
                let phaseStart = DispatchTime.now().uptimeNanoseconds
                metrics?.increment(.contentRequestsAttempted)
                do {
                    try Task.checkCancellation()
                    let outcome = try await engine.fingerprinter.byteKey(for: record)
                    let elapsed = secondsSince(phaseStart)
                    metrics?.record(.fingerprint, seconds: elapsed)
                    switch outcome {
                    case .key(let key):
                        byteKeys.write(record.localIdentifier, key)
                    case .unavailable(let reason):
                        // Failures get their own duration bucket: a run whose library is not
                        // local is almost entirely `contentFailed` time, and the report needs
                        // that number separately from productive content work.
                        metrics?.record(.contentFailed, seconds: elapsed)
                        metrics?.increment(.contentRequestsFailed)
                        unavailable.insert(record.localIdentifier, reason: reason)
                    }
                } catch is CancellationError {
                    return
                } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                    return
                } catch {
                    metrics?.record(.contentFailed, seconds: secondsSince(phaseStart))
                    metrics?.increment(.contentRequestsFailed)
                    unavailable.insert(
                        record.localIdentifier,
                        reason: contentFailureReason(for: error)
                    )
                }
            }
            // Every work item ticks exactly once, on the outcome — success, unavailable, or
            // error — including timed-out requests, so the stage can never appear frozen.
            try reporter.advance(.fingerprinting, total: cheapCount)
        }
        try checkCancellation()

        // Phase 2: SHA-256 only for videos whose length pairs collided. The total grows by
        // the collision count so each hash pass ticks, and progress stays monotonic.
        var byKey: [ContentByteKey: [String]] = [:]
        for (assetID, key) in byteKeys.read() {
            byKey[key, default: []].append(assetID)
        }
        let collidingIDs = byKey.values
            .filter { $0.count > 1 }
            .flatMap { $0 }
            .sorted()
        try reporter.setCount(
            .fingerprinting,
            completed: cheapCount,
            total: cheapCount + collidingIDs.count
        )

        let fingerprints = LockedBox<[String: ContentFingerprint]>([:])
        let collidingRecords = collidingIDs.compactMap { recordsByID[$0] }
        try await BoundedWorkers.run(items: collidingRecords, width: workerWidth) { record in
            guard !Task.isCancelled else { return }
            try await thermalPolicy.waitWhileCritical()
            let phaseStart = DispatchTime.now().uptimeNanoseconds
            metrics?.increment(.contentRequestsAttempted)
            do {
                try Task.checkCancellation()
                let outcome = try await engine.fingerprinter.fingerprint(for: record)
                let elapsed = secondsSince(phaseStart)
                metrics?.record(.fingerprint, seconds: elapsed)
                switch outcome {
                case .fingerprinted(let fingerprint):
                    fingerprints.write(record.localIdentifier, fingerprint)
                case .unavailable(let reason):
                    metrics?.record(.contentFailed, seconds: elapsed)
                    metrics?.increment(.contentRequestsFailed)
                    unavailable.insert(record.localIdentifier, reason: reason)
                }
            } catch is CancellationError {
                return
            } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                return
            } catch {
                metrics?.record(.contentFailed, seconds: secondsSince(phaseStart))
                metrics?.increment(.contentRequestsFailed)
                unavailable.insert(
                    record.localIdentifier,
                    reason: contentFailureReason(for: error)
                )
            }
            try reporter.advance(.fingerprinting, total: cheapCount + collidingIDs.count)
        }
        try checkCancellation()
        metrics?.record(.fingerprintWall, seconds: secondsSince(fingerprintWallStart))

        // The perceptual gate: inside each multi-bucket, keep only pairs within hamming
        // tolerance. Everything else — including every singleton, which never reached stage 3 —
        // costs no thumbnail beyond its hash and no descriptor at all.
        let hashes = perceptualHashes.read()
        let maxHamming = config.perceptualCandidateMaxHamming
        var candidateWork: [CandidatePairWork] = []
        candidateWork.reserveCapacity(multiImageBuckets.count)
        for bucket in multiImageBuckets {
            let hashed = bucket.records.compactMap { record -> (PhotoAssetRecord, PerceptualHash)? in
                guard let hash = hashes[record.localIdentifier] else { return nil }
                return (record, hash)
            }
            guard hashed.count > 1 else { continue }
            var pairs: [(PhotoAssetRecord, PhotoAssetRecord)] = []
            for firstIndex in 0..<hashed.count {
                for secondIndex in (firstIndex + 1)..<hashed.count {
                    guard hashed[firstIndex].1.distance(to: hashed[secondIndex].1) <= maxHamming
                    else { continue }
                    pairs.append((hashed[firstIndex].0, hashed[secondIndex].0))
                }
            }
            guard !pairs.isEmpty else { continue }
            var memberIDs = Set<String>()
            for (left, right) in pairs {
                memberIDs.insert(left.localIdentifier)
                memberIDs.insert(right.localIdentifier)
            }
            let members = hashed.map(\.0).filter { memberIDs.contains($0.localIdentifier) }
            candidateWork.append(CandidatePairWork(members: members, pairs: pairs))
        }
        metrics?.set(
            .perceptualCandidates,
            to: candidateWork.reduce(0) { $0 + $1.pairs.count }
        )

        // Stages 4+5: extractingFeatures ↔ comparing — interleaved per candidate bucket. Each
        // bucket's prints are extracted, compared, and released before the next bucket starts,
        // so at most `workerWidth × maxBucketSize` prints (a few hundred KB) are alive at once.
        let extractionTotal = candidateWork.reduce(0) { $0 + $1.members.count }
        let comparisonTotal = candidateWork.count
        let extractionWallStart = DispatchTime.now().uptimeNanoseconds
        let descriptorKind: FeaturePrintKind?
        if extractionTotal > 0 {
            await engine.featureExtractor.prepare()
            descriptorKind = engine.featureExtractor.kind
        } else {
            descriptorKind = nil
        }
        let workerThreshold = descriptorKind.map {
            config.similarityThreshold ?? $0.defaultSimilarityThreshold
        } ?? FeaturePrintKind.cpuGrid.defaultSimilarityThreshold

        try reporter.enter(.extractingFeatures, total: extractionTotal)
        let relations = LockedBox<[PairRelation]>([])

        try await BoundedWorkers.run(items: candidateWork, width: workerWidth) { work in
            guard !Task.isCancelled else { return }
            try await thermalPolicy.waitWhileCritical()

            var prints: [(assetID: String, print: FeaturePrint)] = []
            prints.reserveCapacity(work.members.count)
            for record in work.members {
                if Task.isCancelled { return }
                metrics?.increment(.thumbnailsRequested)
                let thumbnailStart = DispatchTime.now().uptimeNanoseconds
                let thumbnail: CGImage
                do {
                    try Task.checkCancellation()
                    thumbnail = try await engine.thumbnailLoader.thumbnail(
                        for: record.localIdentifier,
                        targetPixelSize: config.verificationThumbnailMaxPixelSize,
                        mode: .verification
                    )
                } catch is CancellationError {
                    return
                } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
                    return
                } catch {
                    // Failed requests were previously invisible to the metrics (the record
                    // call sat in the success path only), which hid the dominant cost of a
                    // non-local library. They are now timed and counted separately.
                    let elapsed = secondsSince(thumbnailStart)
                    metrics?.record(.thumbnail, seconds: elapsed)
                    metrics?.record(.thumbnailFailed, seconds: elapsed)
                    metrics?.increment(.thumbnailsFailed)
                    unavailable.insert(
                        record.localIdentifier,
                        reason: unavailableReason(for: error, kind: descriptorKind)
                    )
                    try reporter.advance(.extractingFeatures, total: extractionTotal)
                    continue
                }
                metrics?.record(.thumbnail, seconds: secondsSince(thumbnailStart))
                metrics?.increment(.thumbnailsSucceeded)
                do {
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

            // Compare phase, two passes: content confirmation for perceptually identical
            // pairs (recorded as fingerprint time), then descriptor distances for everything
            // that is not byte-identical (recorded as comparison time). Both loops are inside
            // the bucket, so the pair count stays bounded by maxBucketSize — never library-scale.
            var nearCandidates: [(String, String)] = []
            nearCandidates.reserveCapacity(work.pairs.count)
            for (left, right) in work.pairs {
                if Task.isCancelled { return }
                if let leftHash = hashes[left.localIdentifier],
                   let rightHash = hashes[right.localIdentifier],
                   leftHash == rightHash,
                   try await confirmExactPair(
                       left: left,
                       right: right,
                       engine: engine,
                       byteKeys: byteKeys,
                       fingerprints: fingerprints,
                       unavailable: unavailable,
                       metrics: metrics
                   ) {
                    // Byte-identical: the exact group's job. Reporting them as "near" too
                    // would double-count one piece of content.
                    continue
                }
                nearCandidates.append((left.localIdentifier, right.localIdentifier))
            }

            let printByID = Dictionary(
                uniqueKeysWithValues: prints.map { ($0.assetID, $0.print) }
            )
            var bucketRelations: [PairRelation] = []
            if !nearCandidates.isEmpty {
                let compareStart = DispatchTime.now().uptimeNanoseconds
                for (leftID, rightID) in nearCandidates {
                    guard let leftPrint = printByID[leftID],
                          let rightPrint = printByID[rightID],
                          let distance = try? leftPrint.distance(to: rightPrint),
                          distance <= workerThreshold else { continue }
                    bucketRelations.append(
                        PairRelation(assetA: leftID, assetB: rightID, distance: distance)
                    )
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
        metrics?.record(.extractionWall, seconds: secondsSince(extractionWallStart))

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

        // Accounting invariant: analyzed + unavailable + skipped == totalRecordCount, and the
        // three sets are disjoint — an asset with evidence and no failure is analyzed, any
        // failure (including a confirm-stage content failure) is unavailable, a singleton is
        // skipped. Nothing is double-counted and nothing silently disappears.
        let skippedCount = skippedImageCount + skippedVideoCount
        let analyzedCount = max(
            0,
            records.count - unavailableList.count - skippedCount
        )

        metrics?.set(.assetsConsidered, to: records.count)
        metrics?.set(.assetsFingerprinted, to: byteKeys.read().count)
        metrics?.set(.assetsUnavailable, to: unavailableList.count)
        metrics?.set(.assetsAnalyzed, to: analyzedCount)
        metrics?.set(.exactGroups, to: exactGroups.count)
        metrics?.set(.similarGroups, to: similarGroups.count)
        // Final reason breakdown: a partition of `assetsUnavailable`, so the summary line
        // answers "why" (iCloud vs unreadable vs deleted vs permission), not just "how many".
        for asset in unavailableList {
            metrics?.incrementReason(asset.reason)
        }

        let result = PhotoAnalysisResult(
            exactGroups: exactGroups,
            similarGroups: similarGroups,
            unavailableAssets: unavailableList,
            descriptorKind: descriptorKind,
            visionAvailable: descriptorKind == .visionFeaturePrint,
            similarityThreshold: descriptorKind == nil ? nil : workerThreshold,
            totalRecordCount: records.count,
            candidateBucketCount: bucketing.buckets.count,
            candidatePairCount: bucketing.candidatePairCount,
            analyzedAssetCount: analyzedCount,
            skippedNoCandidateCount: skippedCount
        )
        try reporter.complete(.finalizing, total: 1)
        return result
    }

    /// Exact confirmation for a perceptually identical (hamming-0) image pair: resolve both
    /// byte keys (memoized across pairs), compare, and only then — on a length collision —
    /// SHA both. Returns `true` only when both fingerprints resolved and are equal; a content
    /// failure returns `false` (the pair stays a descriptor candidate) *and* records the
    /// asset as unavailable with the failure's reason, keeping it out of any "analyzed" claim.
    /// Cancellation is rethrown so a cancelled run never records a failure it did not cause.
    private static func confirmExactPair(
        left: PhotoAssetRecord,
        right: PhotoAssetRecord,
        engine: PhotoSimilarityEngine,
        byteKeys: LockedBox<[String: ContentByteKey]>,
        fingerprints: LockedBox<[String: ContentFingerprint]>,
        unavailable: LockedBox<[String: PhotoAnalysisUnavailableReason]>,
        metrics: AnalysisMetrics?
    ) async throws -> Bool {
        // Both sides resolve unconditionally — a `guard let a, let b` chain would stop at the
        // first unavailable member and never probe its partner, silently losing the partner's
        // failure reason (bucket order decides who short-circuits). Every pair member gets its
        // own memoized attempt; a member already recorded unavailable returns early inside
        // its own resolve without a second request.
        let leftKey = try await resolveByteKey(
            for: left, engine: engine, byteKeys: byteKeys,
            unavailable: unavailable, metrics: metrics
        )
        let rightKey = try await resolveByteKey(
            for: right, engine: engine, byteKeys: byteKeys,
            unavailable: unavailable, metrics: metrics
        )
        guard let leftKey, let rightKey, leftKey == rightKey else { return false }
        let leftPrint = try await resolveFingerprint(
            for: left, engine: engine, byteKeys: byteKeys,
            fingerprints: fingerprints, unavailable: unavailable, metrics: metrics
        )
        let rightPrint = try await resolveFingerprint(
            for: right, engine: engine, byteKeys: byteKeys,
            fingerprints: fingerprints, unavailable: unavailable, metrics: metrics
        )
        guard let leftPrint, let rightPrint else { return false }
        return leftPrint == rightPrint
    }

    /// Memoized content-length probe. One attempt per asset per run: pairs share the result,
    /// a previously failed asset returns `nil` without a second request, and a `nil` result
    /// means the failure was already recorded with its reason.
    private static func resolveByteKey(
        for record: PhotoAssetRecord,
        engine: PhotoSimilarityEngine,
        byteKeys: LockedBox<[String: ContentByteKey]>,
        unavailable: LockedBox<[String: PhotoAnalysisUnavailableReason]>,
        metrics: AnalysisMetrics?
    ) async throws -> ContentByteKey? {
        if let key = byteKeys.read()[record.localIdentifier] { return key }
        guard unavailable.read()[record.localIdentifier] == nil else { return nil }
        let phaseStart = DispatchTime.now().uptimeNanoseconds
        metrics?.increment(.contentRequestsAttempted)
        do {
            try Task.checkCancellation()
            let outcome = try await engine.fingerprinter.byteKey(for: record)
            let elapsed = secondsSince(phaseStart)
            metrics?.record(.fingerprint, seconds: elapsed)
            switch outcome {
            case .key(let key):
                byteKeys.write(record.localIdentifier, key)
                return key
            case .unavailable(let reason):
                metrics?.record(.contentFailed, seconds: elapsed)
                metrics?.increment(.contentRequestsFailed)
                unavailable.insert(record.localIdentifier, reason: reason)
                return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
            throw failure
        } catch {
            let elapsed = secondsSince(phaseStart)
            metrics?.record(.contentFailed, seconds: elapsed)
            metrics?.increment(.contentRequestsFailed)
            unavailable.insert(
                record.localIdentifier,
                reason: contentFailureReason(for: error)
            )
            return nil
        }
    }

    /// Memoized SHA-256 pass. Only ever called after both byte keys matched, so the expensive
    /// read happens at most twice per confirmed pair and never for a provably distinct asset.
    private static func resolveFingerprint(
        for record: PhotoAssetRecord,
        engine: PhotoSimilarityEngine,
        byteKeys: LockedBox<[String: ContentByteKey]>,
        fingerprints: LockedBox<[String: ContentFingerprint]>,
        unavailable: LockedBox<[String: PhotoAnalysisUnavailableReason]>,
        metrics: AnalysisMetrics?
    ) async throws -> ContentFingerprint? {
        if let fingerprint = fingerprints.read()[record.localIdentifier] { return fingerprint }
        guard unavailable.read()[record.localIdentifier] == nil else { return nil }
        let phaseStart = DispatchTime.now().uptimeNanoseconds
        metrics?.increment(.contentRequestsAttempted)
        do {
            try Task.checkCancellation()
            let outcome = try await engine.fingerprinter.fingerprint(for: record)
            let elapsed = secondsSince(phaseStart)
            metrics?.record(.fingerprint, seconds: elapsed)
            switch outcome {
            case .fingerprinted(let fingerprint):
                fingerprints.write(record.localIdentifier, fingerprint)
                return fingerprint
            case .unavailable(let reason):
                metrics?.record(.contentFailed, seconds: elapsed)
                metrics?.increment(.contentRequestsFailed)
                unavailable.insert(record.localIdentifier, reason: reason)
                return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PhotoAnalysisFailure where failure == .cancelled {
            throw failure
        } catch {
            let elapsed = secondsSince(phaseStart)
            metrics?.record(.contentFailed, seconds: elapsed)
            metrics?.increment(.contentRequestsFailed)
            unavailable.insert(
                record.localIdentifier,
                reason: contentFailureReason(for: error)
            )
            return nil
        }
    }

    /// Failure reason for a *content* probe that threw instead of resolving: a hung request
    /// is `.timedOut` (the failsafe fired), everything else is `.contentUnreadable`.
    private static func contentFailureReason(for error: any Error) -> PhotoAnalysisUnavailableReason {
        if error is PhotoRequestTimeoutError { return .timedOut }
        if let reason = error as? PhotoAnalysisUnavailableReason { return reason }
        return .contentUnreadable
    }

    /// Maps an error from a live seam to the honest unavailable reason the UI will show. The
    /// vocabulary stays granular on purpose (permission off / asset deleted / iCloud-only /
    /// unreadable / timed out / thumbnail failed / Vision failed / CPU fallback failed) — see
    /// §10 of ARCHITECTURE.md — so "could not analyze" is never mistaken for "not a duplicate".
    private static func unavailableReason(
        for error: any Error,
        kind: FeaturePrintKind?
    ) -> PhotoAnalysisUnavailableReason {
        if error is PhotoRequestTimeoutError {
            return .timedOut
        }
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

/// One unit of stage-3 (cheap) work: an image that earns a perceptual hash, or a video that
/// earns a content-length stat. Singletons never appear here — they are skipped, not failed.
private enum AnalysisCheapWork: Sendable {
    case perceptualHash(PhotoAssetRecord)
    case videoByteKey(PhotoAssetRecord)
}

/// One bucket of stage-4/5 work: the members that survived the perceptual gate (extract a
/// descriptor for each) and the pairs within hamming tolerance (confirm + compare each).
private struct CandidatePairWork: Sendable {
    let members: [PhotoAssetRecord]
    let pairs: [(PhotoAssetRecord, PhotoAssetRecord)]
}

/// Adaptive concurrency policy shared by every scan pass (similarity, sharpness, video
/// sizes): each engine keeps its configured upper bound, and this policy scales the
/// *effective* width down as the device heats up, pausing entirely at critical pressure.
///
/// Pure width arithmetic plus a cancellation-aware wait — no engine-specific knowledge, so
/// one policy and one test suite cover every pass. The thermal source is injected:
/// production reads `ProcessInfo.processInfo.thermalState` fresh at each decision (a run
/// picks up pressure changes between stages and between work items), tests pin a state.
///
/// Guarantees:
/// - The effective width is always in `1...base` — a run under any thermal state still
///   makes progress, and never exceeds the configured bound.
/// - `waitWhileCritical` returns immediately below `.critical`; at `.critical` it polls
///   until pressure eases (or the task is cancelled, which throws `CancellationError` — a
///   user cancel is never delayed by the pause). Work resumes exactly where it paused:
///   the worker's strided index is untouched.
struct ScanConcurrencyPolicy: Sendable {
    /// Thermal source — called fresh at every decision so pressure changes mid-run apply.
    var thermalState: @Sendable () -> ProcessInfo.ThermalState

    init(
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        }
    ) {
        self.thermalState = thermalState
    }

    /// The effective width for a configured base width under the current thermal state:
    /// nominal keeps the base; fair takes three quarters; serious halves it; critical cuts
    /// it to a quarter (floor of 1).
    func width(base: Int) -> Int {
        let base = max(1, base)
        switch thermalState() {
        case .nominal:
            return base
        case .fair:
            return max(1, (base * 3) / 4)
        case .serious:
            return max(1, base / 2)
        case .critical:
            return max(1, base / 4)
        @unknown default:
            return max(1, base / 2)
        }
    }

    /// Whether the next unit of work must wait: critical pressure pauses the pass, any
    /// other state lets it run at `width(base:)`.
    var isCriticallyPressed: Bool {
        thermalState() == .critical
    }

    /// Pauses while the device is in critical thermal pressure, polling at `pollInterval`.
    /// Returns as soon as pressure eases (or immediately if there was none). Throws
    /// `CancellationError` if the surrounding task is cancelled while waiting.
    func waitWhileCritical(pollInterval: Duration = .milliseconds(250)) async throws {
        while isCriticallyPressed {
            try await Task.sleep(for: pollInterval)
        }
    }
}

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

    /// Atomically transforms the wrapped value and returns whatever the closure produced.
    /// The generic counterpart to the typed `write`/`append`/`insert` helpers below: the
    /// blur engine accumulates a private tally struct that has no dedicated overload, and
    /// every read-modify-write must stay under the same lock.
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
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

    func write(_ key: String, _ newValue: PerceptualHash) where Value == [String: PerceptualHash] {
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
