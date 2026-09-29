import Foundation

/// Pure metadata partitioning: turns the flat catalog into buckets small enough that pairwise
/// comparison inside a bucket is cheap, while keeping the candidate contract explicit.
///
/// Why this replaces naive O(n²): two photos can only be near-duplicates if they share an aspect
/// ratio and were captured close together. Bucketing on those keys collapses the pair space from
/// `n(n-1)/2` to roughly `n × maxBucketSize / 2` — bounded by `maxBucketSize`, not library size.
/// The output is a true partition: every eligible record lands in exactly one bucket, so nothing
/// is dropped silently. The *candidate contract* is "pairs that share a bucket" — documented,
/// tested, and the only pairs compared. Exact-duplicate detection does not depend on buckets at
/// all: byte-identical content is found by the fingerprint path regardless of aspect or date, so
/// metadata can never exclude a true exact duplicate from being reported.
struct CandidateBucketsConfiguration: Sendable, Equatable {
    /// Width/height ratios that round to the same key are treated as the same aspect. 0.01 means
    /// photos whose aspect ratios differ by under ~1% can still match (small crops).
    var aspectTolerance: Double = 0.01
    /// Creation dates further apart than this cannot be duplicates. Burst frames, Live Photo
    /// stills, and accidental double-shoots all sit well inside ten minutes.
    var maxTemporalGap: TimeInterval = 600
    /// Upper bound on bucket size, which bounds comparisons per bucket to `size(size-1)/2`.
    var maxBucketSize: Int = 64
    /// Pixel dimensions at or below this are treated as invalid metadata.
    var minPixelDimension: Int = 1

    static let `default` = CandidateBucketsConfiguration()
}

/// One bucket: a set of same-aspect, temporally-chained records that will be compared pairwise.
struct CandidateBucket: Sendable, Equatable {
    let id: String
    /// Sorted by `(creationDate ?? distantPast, localIdentifier)` for deterministic iteration.
    let records: [PhotoAssetRecord]

    var pairCount: Int { records.count * (records.count - 1) / 2 }
}

/// Records that cannot participate in bucketing, paired with the reason they are excluded.
struct BucketingExclusion: Sendable, Equatable {
    let assetID: String
    let reason: PhotoAnalysisUnavailableReason
}

struct BucketingOutput: Sendable, Equatable {
    /// All eligible records, each in exactly one bucket (the partition).
    let buckets: [CandidateBucket]
    /// Records excluded from bucketing, with reasons. Fingerprinting still runs for non-image
    /// exclusions of video type; these drive `PhotoAnalysisResult.unavailableAssets`.
    let exclusions: [BucketingExclusion]

    /// Pairs the engine will actually consider. The core complexity guarantee lives here:
    /// `candidatePairCount(records:)` is `Σ size(size-1)/2`, never `n(n-1)/2`.
    var candidatePairCount: Int {
        buckets.reduce(0) { $0 + $1.pairCount }
    }
}

enum CandidateBuckets {
    /// Builds the bucket partition. Pure and deterministic: shuffling the input records yields
    /// byte-identical output.
    static func make(
        records: [PhotoAssetRecord],
        configuration: CandidateBucketsConfiguration = .default
    ) -> BucketingOutput {
        let config = configuration
        let minDimension = max(1, config.minPixelDimension)

        var eligible: [PhotoAssetRecord] = []
        var exclusions: [BucketingExclusion] = []

        for record in records {
            guard record.isImage else {
                // Videos are fingerprinted (exact duplicates) but have no visual descriptor, so
                // they never enter a bucket.
                continue
            }
            guard record.pixelWidth >= minDimension, record.pixelHeight >= minDimension else {
                exclusions.append(
                    BucketingExclusion(assetID: record.localIdentifier, reason: .invalidDimensions)
                )
                continue
            }
            eligible.append(record)
        }

        // Group by aspect key first — aspect is a hard partition (dimensions must match).
        var byAspect: [Int: [PhotoAssetRecord]] = [:]
        for record in eligible {
            byAspect[aspectKey(for: record, tolerance: config.aspectTolerance), default: []]
                .append(record)
        }

        var buckets: [CandidateBucket] = []
        for (aspect, group) in byAspect {
            let sorted = group.sorted(by: sortKey)
            for (index, chunk) in chain(sorted, configuration: config).enumerated() {
                buckets.append(
                    CandidateBucket(
                        id: "a\(aspect)-b\(index)-\(chunk.count)-\(chunk.first?.localIdentifier ?? "")",
                        records: chunk
                    )
                )
            }
        }

        // Largest buckets first: bounds work under the task group early and makes progress
        // reach the interesting comparisons quickly. Ties broken by id for determinism.
        buckets.sort { lhs, rhs in
            if lhs.records.count != rhs.records.count {
                return lhs.records.count > rhs.records.count
            }
            return lhs.id < rhs.id
        }

        exclusions.sort { $0.assetID < $1.assetID }
        return BucketingOutput(buckets: buckets, exclusions: exclusions)
    }

    /// Pairs that `records.count` records would require with no bucketing at all. Exposed so
    /// tests (and the docs) can state the reduction as a number.
    static func unboundedPairCount(records: Int) -> Int {
        guard records > 1 else { return 0 }
        return records * (records - 1) / 2
    }

    // MARK: - Internals

    /// Aspect key: `round((longer / shorter) / tolerance)`. Equal pixel dimensions always land on
    /// the same key; near-equal aspect ratios match when they round together. The rounding grid is
    /// the documented candidate contract (a pair straddling a grid line is not a candidate), which
    /// is acceptable because shots from one camera share exact dimensions, and byte-identical
    /// duplicates are found by fingerprinting independently of any bucket.
    static func aspectKey(for record: PhotoAssetRecord, tolerance: Double) -> Int {
        let width = Double(record.pixelWidth)
        let height = Double(record.pixelHeight)
        let longer = max(width, height)
        let shorter = min(width, height)
        guard shorter > 0 else { return Int.max }
        let ratio = longer / shorter
        return Int((ratio / max(tolerance, 1e-9)).rounded())
    }

    static func sortKey(_ lhs: PhotoAssetRecord, _ rhs: PhotoAssetRecord) -> Bool {
        let lhsDate = lhs.creationDate ?? .distantPast
        let rhsDate = rhs.creationDate ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// Splits a time-sorted group into chains no wider than `maxTemporalGap`, then deterministically
    /// splits any chain that exceeds `maxBucketSize` — always at a large internal gap when one is
    /// available, but always within the cap (the cap wins over gap preference).
    static func chain(
        _ sorted: [PhotoAssetRecord],
        configuration: CandidateBucketsConfiguration
    ) -> [[PhotoAssetRecord]] {
        guard !sorted.isEmpty else { return [] }

        var chains: [[PhotoAssetRecord]] = []
        var current: [PhotoAssetRecord] = [sorted[0]]
        for record in sorted.dropFirst() {
            let previousDate = current.last?.creationDate ?? .distantPast
            let date = record.creationDate ?? .distantPast
            if date.timeIntervalSince(previousDate) > configuration.maxTemporalGap {
                chains.append(current)
                current = [record]
            } else {
                current.append(record)
            }
        }
        chains.append(current)

        var result: [[PhotoAssetRecord]] = []
        for chain in chains {
            result.append(contentsOf: splitOversized(chain, maxBucketSize: max(2, configuration.maxBucketSize)))
        }
        return result
    }

    static func splitOversized(_ records: [PhotoAssetRecord], maxBucketSize: Int) -> [[PhotoAssetRecord]] {
        guard records.count > maxBucketSize else { return [records] }

        var pieces: [[PhotoAssetRecord]] = []
        var remaining = records
        while remaining.count > 2 * maxBucketSize {
            // Too big to split once: cut a full-size piece off the front, choosing the largest
            // gap inside the range that keeps the piece within the cap.
            let allowed = 1...maxBucketSize
            let cut = gapAwareSplitIndex(in: remaining, allowing: allowed)
            pieces.append(Array(remaining[..<cut]))
            remaining = Array(remaining[cut...])
        }
        // One split now suffices; the allowed range guarantees both sides fit the cap.
        let allowed = (remaining.count - maxBucketSize)...maxBucketSize
        let cut = gapAwareSplitIndex(in: remaining, allowing: allowed)
        pieces.append(Array(remaining[..<cut]))
        pieces.append(Array(remaining[cut...]))
        return pieces
    }

    /// Index at which to cut: the largest gap between neighbours whose index falls inside
    /// `allowing` (ties resolved toward the midpoint), so the cap always wins over gap
    /// preference. When every candidate gap is zero — identical timestamps — the midpoint of the
    /// allowed range keeps the split balanced and still deterministic.
    static func gapAwareSplitIndex(
        in records: [PhotoAssetRecord],
        allowing: ClosedRange<Int>
    ) -> Int {
        precondition(!records.isEmpty, "need records to split")
        let lower = max(allowing.lowerBound, 1)
        let upper = min(allowing.upperBound, records.count - 1)
        precondition(lower <= upper, "no valid split index")

        func gap(at index: Int) -> TimeInterval {
            let previous = records[index - 1].creationDate ?? .distantPast
            let date = records[index].creationDate ?? .distantPast
            return date.timeIntervalSince(previous)
        }

        var bestGap: TimeInterval = -1
        for index in lower...upper {
            bestGap = max(bestGap, gap(at: index))
        }
        guard bestGap > 0 else {
            return min(max(records.count / 2, lower), upper)
        }

        let midpoint = records.count / 2
        var chosen = lower
        var chosenDistance = Int.max
        for index in lower...upper where gap(at: index) == bestGap {
            let distance = abs(index - midpoint)
            if distance < chosenDistance {
                chosenDistance = distance
                chosen = index
            }
        }
        return chosen
    }
}
