import Foundation
import os
import os.signpost

/// Signpost-backed stage observer: one point event per stage transition plus one interval per
/// distinct stage visit, so Instruments (or `log stream`) can measure where a real-device
/// analysis run actually spends its time. This is the measurement story for the on-device
/// performance matrix — Netto promises no time estimates, only measurements.
final class SignpostStageObserver: PhotoAnalysisStageObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let signposter: OSSignposter
    private var current: (stage: PhotoAnalysisStage, state: OSSignpostIntervalState)?

    init(subsystem: String = "com.netto.analysis", category: String = "SimilarityAnalysis") {
        signposter = OSSignposter(subsystem: subsystem, category: .init(category))
    }

    func analysisStageWillBegin(_ stage: PhotoAnalysisStage) {
        lock.lock()
        defer { lock.unlock() }

        signposter.emitEvent(stage.signpostName)
        if let current, current.stage == stage { return }
        if let current {
            signposter.endInterval("analysis-stage", current.state)
        }
        let state = signposter.beginInterval("analysis-stage", id: signposter.makeSignpostID())
        current = (stage, state)
    }

    func analysisDidFinish() {
        lock.lock()
        defer { lock.unlock() }
        guard let current else { return }
        signposter.endInterval("analysis-stage", current.state)
        self.current = nil
    }
}

/// Cumulative timing/counter metrics for one analysis run — the device-validation hooks.
///
/// Stage signposts answer "which stage cost how long"; this answers the finer questions a real
/// iPhone validation needs: how long thumbnail requests took, how long descriptor extraction
/// took, how long content fingerprinting took, and how many assets were processed versus
/// unavailable. Two rules keep it cheap enough to leave on:
/// - **One summary line per run, never per asset.** `emitSummary()` logs a single `os.Logger`
///   line (plus one static signpost event) when the run finishes — cancelled runs included,
///   because cancellation timings are exactly what a device-validation session wants to see.
/// - **One lock, monotonic clock reads, no allocation in the hot path.** Recording is a dict
///   add under an uncontended lock; it cannot materially move any of the durations it measures.
///
/// Tests inject an instance, run the engine, and read `snapshot()` — no signpost parsing.
final class AnalysisMetrics: @unchecked Sendable {
    enum Duration: String, Sendable, CaseIterable {
        /// Metadata candidate generation (bucketing).
        case candidates
        /// Content length/hashing work (both fingerprint phases, summed over assets — every
        /// attempt, successful or not).
        case fingerprint
        /// Subset of `fingerprint`: attempts that ended unavailable. `fingerprint - contentFailed`
        /// is therefore the time spent on requests that produced usable bytes.
        case contentFailed
        /// PhotoKit thumbnail requests (summed over requests — every attempt, successful or not).
        case thumbnail
        /// Subset of `thumbnail`: requests that ended unavailable. Failures dominate a run whose
        /// library is iCloud-only or file-less, so this split is the "wasted work" measurement.
        case thumbnailFailed
        /// Descriptor extraction, Vision or CPU (summed over successes).
        case descriptor
        /// In-bucket pair distance computation (summed over buckets).
        case comparison
        /// Exact + near grouping.
        case grouping
        /// Wall clock of the whole fingerprinting stage (both content phases), as opposed to the
        /// summed-over-assets `fingerprint`.
        case fingerprintWall
        /// Wall clock of the extraction + comparison stages (including backend preparation).
        case extractionWall
        /// Whole run, start to result (or cancellation).
        case total
    }

    enum Counter: String, Sendable, CaseIterable {
        /// Records handed to analysis (total input size).
        case assetsConsidered
        /// Assets whose content length was successfully stat'ed (exact path reached phase 1).
        case assetsFingerprinted
        /// Content-resolution requests issued (phase 1 + phase 2 attempts).
        case contentRequestsAttempted
        /// Content-resolution requests that ended unavailable.
        case contentRequestsFailed
        /// Thumbnail requests issued.
        case thumbnailsRequested
        /// Thumbnail requests that returned a bitmap.
        case thumbnailsSucceeded
        /// Thumbnail requests that ended unavailable.
        case thumbnailsFailed
        /// Thumbnails never requested because the image had no candidate partner (cheap-first
        /// skip stage): the number the skip saved, shown next to `thumbTried`.
        case thumbnailsSkipped
        /// Thumbnails successfully turned into descriptors (near path).
        case descriptorsExtracted
        /// Assets reported with an unavailable reason.
        case assetsUnavailable
        /// Buckets produced by the metadata partition.
        case bucketCount
        /// Buckets holding exactly one record (no pair work; skipped under cheap-first).
        case bucketSingletons
        /// Buckets holding two or more records.
        case bucketMulti
        /// Assets that live in a multi-record bucket (thumbnail-eligible under cheap-first).
        case bucketMultiAssets
        /// Video buckets formed by the aspect + duration partition.
        case videoBuckets
        /// Pairs the engine will consider (`Σ size(size-1)/2`).
        case candidatePairs
        /// Pairs that survived the perceptual hamming gate — the only pairs that cost a
        /// descriptor. `candidatePairs - perceptualCandidates` is the cheap-first saving.
        case perceptualCandidates
        /// Assets never requested because no candidate partner could exist (singletons).
        case assetsSkipped
        /// Assets with visual/content evidence this run, no unavailable reason.
        case assetsAnalyzed
        case exactGroups
        case similarGroups
    }

    struct Snapshot: Sendable, Equatable {
        var durations: [Duration: Double] = [:]
        var counters: [Counter: Int] = [:]
        /// Final `PhotoAnalysisUnavailableReason` counts for the run, keyed by raw value.
        var reasons: [String: Int] = [:]
        /// Raw PhotoKit failure codes seen during the run (`domain:code`, plus synthetic
        /// markers for failures PhotoKit reported without an error object).
        var failCodes: [String: Int] = [:]
    }

    private static let logger = Logger(
        subsystem: "com.netto.analysis",
        category: "SimilarityAnalysis"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.netto.analysis",
        category: "SimilarityAnalysis"
    )

    private let lock = NSLock()
    private var durations: [Duration: Double] = [:]
    private var counters: [Counter: Int] = [:]
    private var reasons: [String: Int] = [:]

    func record(_ category: Duration, seconds: Double) {
        lock.lock()
        durations[category, default: 0] += seconds
        lock.unlock()
    }

    func set(_ counter: Counter, to value: Int) {
        lock.lock()
        counters[counter] = value
        lock.unlock()
    }

    func increment(_ counter: Counter) {
        lock.lock()
        counters[counter, default: 0] += 1
        lock.unlock()
    }

    /// Tallies one unavailable reason. Called once per *final* unavailable asset (at result
    /// build time), so the breakdown is a partition of `assetsUnavailable`, not a running log.
    func incrementReason(_ reason: PhotoAnalysisUnavailableReason) {
        lock.lock()
        reasons[reason.rawValue, default: 0] += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            durations: durations,
            counters: counters,
            reasons: reasons,
            failCodes: PhotoKitFailureTally.snapshot()
        )
    }

    /// One line per run. `privacy: .public` on the numbers so a device-validation `log stream`
    /// session shows them without a private-data unmask; they are counts and seconds, never
    /// asset content.
    func emitSummary() {
        let values = snapshot()
        func seconds(_ category: Duration) -> String {
            String(format: "%.4f", values.durations[category] ?? 0)
        }
        func count(_ counter: Counter) -> Int { values.counters[counter] ?? 0 }
        func breakdown(_ entries: [String: Int], limit: Int) -> String {
            entries
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
                }
                .prefix(limit)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        Self.signposter.emitEvent("analysis-summary")
        Self.logger.info(
            """
            analysis-summary \
            total=\(seconds(.total), privacy: .public)s \
            candidates=\(seconds(.candidates), privacy: .public)s \
            fingerprint=\(seconds(.fingerprint), privacy: .public)s \
            fingerprintWall=\(seconds(.fingerprintWall), privacy: .public)s \
            contentFailed=\(seconds(.contentFailed), privacy: .public)s \
            thumbnail=\(seconds(.thumbnail), privacy: .public)s \
            thumbnailFailed=\(seconds(.thumbnailFailed), privacy: .public)s \
            descriptor=\(seconds(.descriptor), privacy: .public)s \
            comparison=\(seconds(.comparison), privacy: .public)s \
            grouping=\(seconds(.grouping), privacy: .public)s \
            extractionWall=\(seconds(.extractionWall), privacy: .public)s \
            considered=\(count(.assetsConsidered), privacy: .public) \
            fingerprinted=\(count(.assetsFingerprinted), privacy: .public) \
            contentTried=\(count(.contentRequestsAttempted), privacy: .public) \
            contentFail=\(count(.contentRequestsFailed), privacy: .public) \
            thumbTried=\(count(.thumbnailsRequested), privacy: .public) \
            thumbOK=\(count(.thumbnailsSucceeded), privacy: .public) \
            thumbFail=\(count(.thumbnailsFailed), privacy: .public) \
            thumbSkip=\(count(.thumbnailsSkipped), privacy: .public) \
            described=\(count(.descriptorsExtracted), privacy: .public) \
            unavailable=\(count(.assetsUnavailable), privacy: .public) \
            analyzed=\(count(.assetsAnalyzed), privacy: .public) \
            skipped=\(count(.assetsSkipped), privacy: .public) \
            buckets=\(count(.bucketCount), privacy: .public) \
            singles=\(count(.bucketSingletons), privacy: .public) \
            multi=\(count(.bucketMulti), privacy: .public) \
            multiAssets=\(count(.bucketMultiAssets), privacy: .public) \
            videoBuckets=\(count(.videoBuckets), privacy: .public) \
            pairs=\(count(.candidatePairs), privacy: .public) \
            perceptualPairs=\(count(.perceptualCandidates), privacy: .public) \
            exactGroups=\(count(.exactGroups), privacy: .public) \
            similarGroups=\(count(.similarGroups), privacy: .public) \
            reasons=\(breakdown(values.reasons, limit: 10), privacy: .public) \
            failCodes=\(breakdown(values.failCodes, limit: 6), privacy: .public)
            """
        )
    }
}

/// Cumulative timing/counter metrics for one sharpness (blur) run — the same
/// one-summary-line-per-run rules as `AnalysisMetrics`, with the stage set the sharpness
/// performance matrix needs: how much of a run is PhotoKit request latency versus
/// measurement, and how many requests ended each way.
///
/// Tests and the simulator benchmark inject an instance, run the engine, and read
/// `snapshot()` — no log parsing. `RootView` emits the summary line only when
/// `NETTO_SCAN_METRICS=1` is present in the environment (debug builds), mirroring the
/// similarity pass.
final class BlurAnalysisMetrics: @unchecked Sendable {
    enum Duration: String, Sendable, CaseIterable {
        /// PhotoKit thumbnail requests (summed over attempts — every attempt, successful
        /// or not; includes queued time inside the loader's bounded request).
        case request
        /// Bitmap render + metric calculation (summed over successes).
        case measure
        /// Classification of a produced score (summed over successes; arithmetic only —
        /// exists to prove it is negligible, not to optimize it).
        case classify
        /// Whole run, start to result (or cancellation).
        case total
    }

    enum Counter: String, Sendable, CaseIterable {
        /// Records handed to analysis (total input size).
        case assetsConsidered
        /// Records refused up front (non-image or zero dimensions) — no request issued.
        case refusedUpFront
        /// Thumbnail requests issued.
        case requestsAttempted
        /// Thumbnail requests that returned a bitmap.
        case requestsSucceeded
        /// Thumbnail requests that ended unavailable (any reason).
        case requestsFailed
        /// Requests that hit the bounded-request failsafe.
        case requestsTimedOut
        /// Requests PhotoKit reported as local-only-miss (iCloud rendition, network disabled).
        case requestsICloud
        /// Renditions whose shortest side was below the analysis budget — the upscale
        /// path. Never expected after the aspect-fill 256² request mode; a non-zero count
        /// on a device run is the signal that PhotoKit did not honor the budget.
        case renditionsBelowBudget
        /// Progress events actually published to the consumer (after throttling).
        case progressTicks
        /// Worker width the run used.
        case workerWidth
        /// Assets judged sharp by the thresholds.
        case judgedSharp
        /// Assets judged borderline.
        case judgedBorderline
        /// Assets judged likely blurry.
        case judgedLikelyBlurry
        /// Assets judged insufficient-information by the threshold gates.
        case judgedInsufficient
    }

    struct Snapshot: Sendable, Equatable {
        var durations: [Duration: Double] = [:]
        var counters: [Counter: Int] = [:]
        /// Final `PhotoAnalysisUnavailableReason` counts for the run, keyed by raw value.
        var reasons: [String: Int] = [:]
        /// Raw PhotoKit failure codes seen during the run (shared process-wide tally —
        /// recorded by the thumbnail loader on failure paths).
        var failCodes: [String: Int] = [:]
    }

    private static let logger = Logger(
        subsystem: "com.netto.analysis",
        category: "BlurAnalysis"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.netto.analysis",
        category: .init("BlurAnalysis")
    )

    private let lock = NSLock()
    private var durations: [Duration: Double] = [:]
    private var counters: [Counter: Int] = [:]
    private var reasons: [String: Int] = [:]

    func record(_ category: Duration, seconds: Double) {
        lock.lock()
        durations[category, default: 0] += seconds
        lock.unlock()
    }

    func set(_ counter: Counter, to value: Int) {
        lock.lock()
        counters[counter] = value
        lock.unlock()
    }

    func increment(_ counter: Counter) {
        lock.lock()
        counters[counter, default: 0] += 1
        lock.unlock()
    }

    /// Tallies one unavailable reason at result-build time — a partition of the run's
    /// unavailable assets, not a running log.
    func incrementReason(_ reason: PhotoAnalysisUnavailableReason) {
        lock.lock()
        reasons[reason.rawValue, default: 0] += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            durations: durations,
            counters: counters,
            reasons: reasons,
            failCodes: PhotoKitFailureTally.snapshot()
        )
    }

    /// One line per run (cancelled runs included — their timings are exactly what a
    /// validation session wants). Counts and seconds are `privacy: .public`; they never
    /// contain asset content.
    func emitSummary() {
        let values = snapshot()
        func seconds(_ category: Duration) -> String {
            String(format: "%.4f", values.durations[category] ?? 0)
        }
        func count(_ counter: Counter) -> Int { values.counters[counter] ?? 0 }
        func breakdown(_ entries: [String: Int], limit: Int) -> String {
            entries
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
                }
                .prefix(limit)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        Self.signposter.emitEvent("blur-summary")
        Self.logger.info(
            """
            blur-summary \
            total=\(seconds(.total), privacy: .public)s \
            request=\(seconds(.request), privacy: .public)s \
            measure=\(seconds(.measure), privacy: .public)s \
            classify=\(seconds(.classify), privacy: .public)s \
            considered=\(count(.assetsConsidered), privacy: .public) \
            refused=\(count(.refusedUpFront), privacy: .public) \
            tried=\(count(.requestsAttempted), privacy: .public) \
            ok=\(count(.requestsSucceeded), privacy: .public) \
            fail=\(count(.requestsFailed), privacy: .public) \
            timeout=\(count(.requestsTimedOut), privacy: .public) \
            icloud=\(count(.requestsICloud), privacy: .public) \
            belowBudget=\(count(.renditionsBelowBudget), privacy: .public) \
            ticks=\(count(.progressTicks), privacy: .public) \
            workers=\(count(.workerWidth), privacy: .public) \
            sharp=\(count(.judgedSharp), privacy: .public) \
            borderline=\(count(.judgedBorderline), privacy: .public) \
            likelyBlurry=\(count(.judgedLikelyBlurry), privacy: .public) \
            insufficient=\(count(.judgedInsufficient), privacy: .public) \
            reasons=\(breakdown(values.reasons, limit: 10), privacy: .public) \
            failCodes=\(breakdown(values.failCodes, limit: 6), privacy: .public)
            """
        )
    }
}

/// Process-wide tally of the *raw* PhotoKit errors seen while resolving content or thumbnails.
///
/// Why this exists: the analysis vocabulary intentionally collapses raw NSError codes into a
/// handful of honest reasons (`.contentUnreadable` covers several distinct underlying causes),
/// which is right for the UI but hides exactly what a device-validation session needs to know —
/// *why* a request failed. Recording `domain:code` at the two mapping sites costs one locked
/// dictionary insert on a failure path only, and `AnalysisMetrics.emitSummary()` prints the top
/// entries next to the reason breakdown.
///
/// Reset at the start of every engine run so one run's summary never includes another run's
/// failures (the harness runs two analyses in one process: cancel test, then full scan).
/// Bounded by the number of distinct failure codes — a few entries, not one per asset.
enum PhotoKitFailureTally {
    /// `@unchecked Sendable`: every access goes through `lock`.
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
    }

    private static let store = Store()

    static func record(_ error: any Error) {
        let nsError = error as NSError
        record(code: "\(nsError.domain):\(nsError.code)")
    }

    /// Synthetic marker for a failure PhotoKit reported *without* an error object
    /// (nil image/URL, in-cloud flag without error, …).
    static func record(code: String) {
        store.lock.lock()
        store.counts[code, default: 0] += 1
        store.lock.unlock()
    }

    static func reset() {
        store.lock.lock()
        store.counts = [:]
        store.lock.unlock()
    }

    static func snapshot() -> [String: Int] {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.counts
    }
}
