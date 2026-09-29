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
        /// Content length/hashing work (both fingerprint phases, summed over assets).
        case fingerprint
        /// PhotoKit thumbnail requests (summed over assets).
        case thumbnail
        /// Descriptor extraction, Vision or CPU (summed over assets).
        case descriptor
        /// In-bucket pair distance computation (summed over buckets).
        case comparison
        /// Exact + near grouping.
        case grouping
        /// Whole run, start to result (or cancellation).
        case total
    }

    enum Counter: String, Sendable, CaseIterable {
        /// Records handed to analysis (total input size).
        case assetsConsidered
        /// Assets whose content length was successfully stat'ed (exact path reached phase 1).
        case assetsFingerprinted
        /// Thumbnails successfully turned into descriptors (near path).
        case descriptorsExtracted
        /// Assets reported with an unavailable reason.
        case assetsUnavailable
        case exactGroups
        case similarGroups
    }

    struct Snapshot: Sendable, Equatable {
        var durations: [Duration: Double] = [:]
        var counters: [Counter: Int] = [:]
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

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(durations: durations, counters: counters)
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
        Self.signposter.emitEvent("analysis-summary")
        Self.logger.info(
            """
            analysis-summary \
            total=\(seconds(.total), privacy: .public)s \
            candidates=\(seconds(.candidates), privacy: .public)s \
            fingerprint=\(seconds(.fingerprint), privacy: .public)s \
            thumbnail=\(seconds(.thumbnail), privacy: .public)s \
            descriptor=\(seconds(.descriptor), privacy: .public)s \
            comparison=\(seconds(.comparison), privacy: .public)s \
            grouping=\(seconds(.grouping), privacy: .public)s \
            considered=\(count(.assetsConsidered), privacy: .public) \
            fingerprinted=\(count(.assetsFingerprinted), privacy: .public) \
            described=\(count(.descriptorsExtracted), privacy: .public) \
            unavailable=\(count(.assetsUnavailable), privacy: .public) \
            exactGroups=\(count(.exactGroups), privacy: .public) \
            similarGroups=\(count(.similarGroups), privacy: .public)
            """
        )
    }
}
