import Foundation
import Testing
@testable import Netto

// MARK: - Fixture

private func makeRecord(
    id: String,
    mediaType: PhotoMediaType = .image,
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: [],
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        creationDate: creationDate,
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

/// Total records across all buckets must equal the input — the partition is complete.
private func expectPartition(
    _ output: BucketingOutput,
    records: [PhotoAssetRecord],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let bucketed = output.buckets.flatMap(\.records).map(\.localIdentifier).sorted()
    let input = records
        .filter { $0.isImage && $0.pixelWidth > 0 && $0.pixelHeight > 0 }
        .map(\.localIdentifier)
        .sorted()
    #expect(bucketed == input, sourceLocation: sourceLocation)
}

struct CandidateBucketsTests {
    @Test func emptyInputYieldsEmptyBuckets() {
        let output = CandidateBuckets.make(records: [])
        #expect(output.buckets.isEmpty)
        #expect(output.exclusions.isEmpty)
        #expect(output.candidatePairCount == 0)
    }

    @Test func sameAspectAndCloseInTimeShareOneBucket() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(id: "a", creationDate: base),
            makeRecord(id: "b", creationDate: base.addingTimeInterval(5)),
            makeRecord(id: "c", creationDate: base.addingTimeInterval(60)),
        ]
        let output = CandidateBuckets.make(records: records)
        #expect(output.buckets.count == 1)
        #expect(output.buckets[0].records.count == 3)
        #expect(output.candidatePairCount == 3)
    }

    @Test func gapBeyondMaxTemporalGapSplitsChains() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxTemporalGap = 600

        let records = [
            makeRecord(id: "early", creationDate: base),
            makeRecord(id: "alsoEarly", creationDate: base.addingTimeInterval(30)),
            makeRecord(id: "late", creationDate: base.addingTimeInterval(30 + 601)),
        ]
        let output = CandidateBuckets.make(records: records, configuration: configuration)
        #expect(output.buckets.count == 2)
        #expect(Set(output.buckets.map { $0.records.map(\.localIdentifier) }) == Set([
            ["early", "alsoEarly"],
            ["late"],
        ]))
        expectPartition(output, records: records)
    }

    @Test func differentAspectRatiosNeverShareABucket() {
        // Note: 4:3 portrait and 4:3 landscape normalize to the same ratio (max/min) and are
        // deliberately candidates for each other; genuinely different shapes must not mix.
        let records = [
            makeRecord(id: "fourByThree", pixelWidth: 4032, pixelHeight: 3024),
            makeRecord(id: "sixteenByNine", pixelWidth: 1920, pixelHeight: 1080),
            makeRecord(id: "square", pixelWidth: 3000, pixelHeight: 3000),
        ]
        let output = CandidateBuckets.make(records: records)
        #expect(output.buckets.count == 3)
        #expect(output.candidatePairCount == 0)
    }

    @Test func equalDimensionsAlwaysLandOnTheSameAspectKeyEvenAtGridBoundaries() {
        // 4:3 = 1.3333… and 3:2 = 1.5 straddle different grid cells under 0.01 tolerance; equal
        // dimensions are what matter in practice and must never split.
        let records = (0..<4).map { makeRecord(id: "same-\($0)") }
        let keys = Set(
            records.map { CandidateBuckets.aspectKey(for: $0, tolerance: CandidateBucketsConfiguration.default.aspectTolerance) }
        )
        #expect(keys.count == 1)
    }

    @Test func oversizedClusterIsSplitAtItsLargestGapDeterministically() {
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxBucketSize = 4
        configuration.maxTemporalGap = 100_000

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // One long chain of 10, with a pronounced gap between index 5 and 6.
        let records = (0..<10).map { index -> PhotoAssetRecord in
            let offset: TimeInterval = index <= 5 ? TimeInterval(index) : 1000 + TimeInterval(index)
            return makeRecord(id: String(format: "r%02d", index), creationDate: base.addingTimeInterval(offset))
        }

        let output = CandidateBuckets.make(records: records, configuration: configuration)
        let sizes = output.buckets.map { $0.records.count }
        #expect(sizes.allSatisfy { $0 <= configuration.maxBucketSize })
        #expect(sizes.reduce(0, +) == 10)
        #expect(sizes.count >= 3)
        // The pronounced gap must end up as a boundary: r05 and r06 sit in different buckets.
        let r05Bucket = output.buckets.first { $0.records.contains { $0.localIdentifier == "r05" } }
        let r06Bucket = output.buckets.first { $0.records.contains { $0.localIdentifier == "r06" } }
        #expect(r05Bucket != nil)
        #expect(r06Bucket != nil)
        #expect(r05Bucket?.id != r06Bucket?.id)
        expectPartition(output, records: records)
    }

    @Test func clusterLargerThanMaxSplitsEvenWithIdenticalTimestamps() {
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxBucketSize = 4

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<10).map { makeRecord(id: "t\($0)", creationDate: base) }

        let output = CandidateBuckets.make(records: records, configuration: configuration)
        #expect(output.buckets.count >= 3)
        #expect(output.buckets.allSatisfy { $0.records.count <= 4 })
        #expect(output.buckets.reduce(0) { $0 + $1.records.count } == 10)
        expectPartition(output, records: records)
    }

    @Test func invalidDimensionsAreExcludedWithReason() {
        let records = [
            makeRecord(id: "good"),
            makeRecord(id: "zero", pixelWidth: 0, pixelHeight: 100),
            makeRecord(id: "negative", pixelWidth: -5, pixelHeight: 100),
        ]
        let output = CandidateBuckets.make(records: records)
        #expect(output.exclusions.count == 2)
        #expect(Set(output.exclusions.map(\.assetID)) == ["zero", "negative"])
        #expect(output.exclusions.allSatisfy { $0.reason == .invalidDimensions })
        #expect(output.buckets.flatMap(\.records).count == 1)
    }

    @Test func nonImageRecordsAreLeftOutOfBucketsEntirely() {
        let records = [
            makeRecord(id: "photo"),
            makeRecord(id: "movie", mediaType: .video),
            makeRecord(id: "clip", mediaType: .audio),
        ]
        let output = CandidateBuckets.make(records: records)
        #expect(output.buckets.flatMap(\.records).map(\.localIdentifier) == ["photo"])
        // Videos are fingerprinted elsewhere, not bucketed; exclusions only cover invalid dims.
        #expect(output.exclusions.isEmpty)
    }

    @Test func shuffledInputProducesIdenticalBuckets() {
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxBucketSize = 3

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<20).map { index in
            makeRecord(
                id: String(format: "s%02d", index),
                creationDate: base.addingTimeInterval(Double(index) * 30)
            )
        }

        let first = CandidateBuckets.make(records: records, configuration: configuration)
        let shuffled = CandidateBuckets.make(records: records.reversed(), configuration: configuration)
        let identity: (BucketingOutput) -> [[String]] = { output in
            output.buckets.map { bucket in
                [bucket.id] + bucket.records.map(\.localIdentifier)
            }
        }
        #expect(identity(first) == identity(shuffled))
    }

    @Test func candidatePairsAreFarBelowUnboundedPairCount() {
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxBucketSize = 64

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 3000 same-aspect photos captured within one hour → chained, then capped at 64.
        let records = (0..<3000).map { index in
            makeRecord(
                id: String(format: "p%05d", index),
                creationDate: base.addingTimeInterval(Double(index) * 12)
            )
        }

        let output = CandidateBuckets.make(records: records, configuration: configuration)
        let bounded = output.candidatePairCount
        let unbounded = CandidateBuckets.unboundedPairCount(records: records.count)

        #expect(records.count == 3000)
        #expect(unbounded == 3000 * 2999 / 2)
        // The complexity guarantee: comparisons bounded by bucket size, not library size.
        #expect(bounded <= records.count * configuration.maxBucketSize)
        #expect(bounded * 20 < unbounded)
        // Largest bucket really is capped.
        #expect(output.buckets.allSatisfy { $0.records.count <= configuration.maxBucketSize })
        expectPartition(output, records: records)
    }

    @Test func bucketOrderIsDeterministicLargestFirst() {
        var configuration = CandidateBucketsConfiguration.default
        configuration.maxBucketSize = 4

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [PhotoAssetRecord] = []
        records.append(contentsOf: (0..<8).map { makeRecord(id: "big-\($0)", pixelWidth: 4032, pixelHeight: 3024, creationDate: base.addingTimeInterval(Double($0))) })
        records.append(contentsOf: (0..<2).map { makeRecord(id: "small-\($0)", pixelWidth: 3000, pixelHeight: 3000, creationDate: base.addingTimeInterval(Double($0))) })

        let output = CandidateBuckets.make(records: records, configuration: configuration)
        #expect(output.buckets.first!.records.count >= output.buckets.last!.records.count)
        #expect(output.buckets.first!.records.count == 4)
    }
}
