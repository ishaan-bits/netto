import Foundation

/// Pure metadata partitioning: turns the flat catalog into buckets small enough that pairwise
/// comparison inside a bucket is cheap, while keeping the candidate contract explicit.
///
/// Why this replaces naive O(n²): two photos can only be near-duplicates if they share an aspect
/// ratio and were captured close together. Bucketing on those keys collapses the pair space from
/// `n(n-1)/2` to roughly `n × maxBucketSize / 2` — bounded by `maxBucketSize`, not library size.
/// The output is a true partition: every eligible record lands in exactly one bucket, so nothing
/// is dropped silently. The *candidate contract* is "pairs that share a bucket" — documented,
/// tested, and the only pairs compared.
///
/// Under cheap-first, buckets also scope the *content* work: single-record buckets are skipped
/// entirely (no partner can exist inside them), videos get their own aspect+duration buckets so
/// a byte-length stat runs only for clips plausibly sharing content, and image exact detection is
/// confirmed only for perceptually identical pairs (see `PhotoSimilarityEngine`). The trade-off
/// this buys is bounded: a byte-identical pair whose creation dates differ by more than
/// `maxTemporalGap` (or whose aspect rounds differently) lands in different buckets and is not
/// confirmed — narrow, because identical files share dimensions and nearly always share a date.
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
    /// Video durations are quantised to this many seconds for content bucketing: clips whose
    /// durations round to the same quantum and share an aspect ratio are the ones plausibly
    /// byte-identical, so only they cost a content-length stat.
    var videoDurationTolerance: TimeInterval = 0.1

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
    /// All eligible image records, each in exactly one bucket (the partition).
    let buckets: [CandidateBucket]
    /// Video records partitioned by aspect + duration quantum with the same temporal chain
    /// rules. Videos have no visual descriptor; these buckets scope *content* work (length
    /// stat, SHA on collision) so a run never stats a video nobody could duplicate.
    let videoBuckets: [CandidateBucket]
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
        var videoEligible: [PhotoAssetRecord] = []
        var exclusions: [BucketingExclusion] = []

        for record in records {
            if record.isVideo {
                // Videos have no visual descriptor, so dimensions never disqualify them —
                // their buckets only decide which clips cost a content-length stat.
                videoEligible.append(record)
                continue
            }
            guard record.isImage else { continue }
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
        buckets.sort(by: bucketOrder)

        var videoBuckets: [CandidateBucket] = []
        var byVideoKey: [VideoKey: [PhotoAssetRecord]] = [:]
        for record in videoEligible {
            byVideoKey[
                VideoKey(
                    aspect: aspectKey(for: record, tolerance: config.aspectTolerance),
                    durationBucket: durationKey(for: record, tolerance: config.videoDurationTolerance)
                ),
                default: []
            ].append(record)
        }
        for (key, group) in byVideoKey {
            let sorted = group.sorted(by: sortKey)
            for (index, chunk) in chain(sorted, configuration: config).enumerated() {
                videoBuckets.append(
                    CandidateBucket(
                        id: "v\(key.aspect)-d\(key.durationBucket)-b\(index)-\(chunk.first?.localIdentifier ?? "")",
                        records: chunk
                    )
                )
            }
        }
        videoBuckets.sort(by: bucketOrder)

        exclusions.sort { $0.assetID < $1.assetID }
        return BucketingOutput(buckets: buckets, videoBuckets: videoBuckets, exclusions: exclusions)
    }

    /// Pairs that `records.count` records would require with no bucketing at all. Exposed so
    /// tests (and the docs) can state the reduction as a number.
    static func unboundedPairCount(records: Int) -> Int {
        guard records > 1 else { return 0 }
        return records * (records - 1) / 2
    }

    // MARK: - Internals

    /// Grouping key for videos: aspect ratio plus a duration quantum. Two clips land together
    /// only when both agree — the worst case of a wrong grouping is one wasted length stat.
    struct VideoKey: Hashable, Sendable {
        let aspect: Int
        let durationBucket: Int
    }

    /// Duration quantum: `round(duration / tolerance)`. Equal durations always share a key;
    /// clips within half a quantum round together (a 0.1 s quantum covers re-export jitter).
    static func durationKey(for record: PhotoAssetRecord, tolerance: TimeInterval) -> Int {
        Int((record.duration / max(tolerance, 1e-9)).rounded())
    }

    /// Largest buckets first (bounds work under the task group early), ties broken by id so
    /// iteration order is deterministic regardless of input order.
    static func bucketOrder(_ lhs: CandidateBucket, _ rhs: CandidateBucket) -> Bool {
        if lhs.records.count != rhs.records.count {
            return lhs.records.count > rhs.records.count
        }
        return lhs.id < rhs.id
    }

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
