import Foundation
import Testing
@testable import Netto

// MARK: - Fixtures

private func makeRecord(
    id: String,
    isFavorite: Bool = false,
    pixelWidth: Int = 4032,
    pixelHeight: Int = 3024,
    creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    hasAdjustments: Bool = false,
    representsBurst: Bool = false
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        creationDate: creationDate,
        modificationDate: nil,
        duration: 0,
        isFavorite: isFavorite,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: hasAdjustments,
        representsBurst: representsBurst,
        burstIdentifier: nil
    )
}

private func fingerprint(_ tag: String, bytes: Int64 = 100) -> ContentFingerprint {
    ContentFingerprint(
        imageBytes: bytes,
        videoBytes: 0,
        imageDigestHex: tag,
        videoDigestHex: nil
    )
}

private func records(_ ids: [String]) -> [String: PhotoAssetRecord] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, makeRecord(id: $0)) })
}

// MARK: - Exact grouping

struct ExactGroupingTests {
    @Test func twoAssetsWithOneFingerprintFormOneExactGroup() {
        let fingerprints = [
            "a": fingerprint("same"),
            "b": fingerprint("same"),
        ]
        let groups = SimilarityGrouping.exactGroups(
            fingerprints: fingerprints,
            records: records(["a", "b", "c"])
        )
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.kind == .exactDuplicates)
        #expect(group.memberAssetIDs == ["a", "b"])
        #expect(group.recommendedBestAssetID == "a")
        if case .exactContent(let tag, let bytes) = group.evidence {
            #expect(tag == "same/-")
            #expect(bytes == 100)
        } else {
            Issue.record("expected exactContent evidence")
        }
    }

    @Test func threeWayExactDuplicateIsOneGroup() {
        let fingerprints = [
            "x": fingerprint("triple", bytes: 50),
            "y": fingerprint("triple", bytes: 50),
            "z": fingerprint("triple", bytes: 50),
        ]
        let groups = SimilarityGrouping.exactGroups(
            fingerprints: fingerprints,
            records: records(["x", "y", "z"])
        )
        #expect(groups.count == 1)
        #expect(groups[0].memberAssetIDs == ["x", "y", "z"])
        #expect(groups[0].count == 3)
    }

    @Test func distinctFingerprintsStaySeparate() {
        let fingerprints = [
            "a": fingerprint("first"),
            "b": fingerprint("first"),
            "c": fingerprint("second"),
            "d": fingerprint("third"),
        ]
        let groups = SimilarityGrouping.exactGroups(
            fingerprints: fingerprints,
            records: records(["a", "b", "c", "d"])
        )
        #expect(groups.count == 1)
        #expect(groups[0].memberAssetIDs == ["a", "b"])
    }

    @Test func fingerprintWithoutCatalogRecordIsDropped() {
        let groups = SimilarityGrouping.exactGroups(
            fingerprints: ["ghost": fingerprint("same"), "a": fingerprint("same")],
            records: records(["a"])
        )
        #expect(groups.isEmpty)
    }

    @Test func singleFingerprintYieldsNoGroup() {
        let groups = SimilarityGrouping.exactGroups(
            fingerprints: ["only": fingerprint("unique")],
            records: records(["only"])
        )
        #expect(groups.isEmpty)
    }
}

// MARK: - Near grouping

struct NearGroupingTests {
    @Test func relatedPairFormsGroupAndThirdStaysOut() {
        let relations = [PairRelation(assetA: "a", assetB: "b", distance: 0.1)]
        let groups = SimilarityGrouping.nearGroups(
            relations: relations,
            threshold: 0.2,
            records: records(["a", "b", "c"])
        )
        #expect(groups.count == 1)
        #expect(groups[0].kind == .nearDuplicates)
        #expect(groups[0].memberAssetIDs == ["a", "b"])
        if case .visualSimilarity(let min, let max, let threshold) = groups[0].evidence {
            #expect(min == 0.1)
            #expect(max == 0.1)
            #expect(threshold == 0.2)
        } else {
            Issue.record("expected visualSimilarity evidence")
        }
    }

    @Test func chainWithoutCompleteCliqueDoesNotSwallowTheThird() {
        // a≈b and b≈c, but a and c are NOT related: a complete-linkage group of all three
        // would be a lie. The clique {a, b} wins; c stays out.
        let relations = [
            PairRelation(assetA: "a", assetB: "b", distance: 0.10),
            PairRelation(assetA: "b", assetB: "c", distance: 0.10),
        ]
        let groups = SimilarityGrouping.nearGroups(
            relations: relations,
            threshold: 0.2,
            records: records(["a", "b", "c"])
        )
        #expect(groups.count == 1)
        #expect(groups[0].memberAssetIDs == ["a", "b"])
    }

    @Test func fullCliqueMergesAllThree() {
        let relations = [
            PairRelation(assetA: "a", assetB: "b", distance: 0.10),
            PairRelation(assetA: "b", assetB: "c", distance: 0.12),
            PairRelation(assetA: "a", assetB: "c", distance: 0.15),
        ]
        let groups = SimilarityGrouping.nearGroups(
            relations: relations,
            threshold: 0.2,
            records: records(["a", "b", "c"])
        )
        #expect(groups.count == 1)
        #expect(groups[0].memberAssetIDs == ["a", "b", "c"])
        if case .visualSimilarity(let min, let max, _) = groups[0].evidence {
            #expect(min == 0.10)
            #expect(max == 0.15)
        } else {
            Issue.record("expected visualSimilarity evidence")
        }
    }

    @Test func disjointRelationsProduceSeparateGroups() {
        let relations = [
            PairRelation(assetA: "a", assetB: "b", distance: 0.05),
            PairRelation(assetA: "m", assetB: "n", distance: 0.09),
        ]
        let groups = SimilarityGrouping.nearGroups(
            relations: relations,
            threshold: 0.2,
            records: records(["a", "b", "m", "n", "lonely"])
        )
        #expect(groups.count == 2)
        #expect(groups.map(\.memberAssetIDs) == [["a", "b"], ["m", "n"]])
    }

    @Test func relationOrderDoesNotChangeTheOutcome() {
        let relations = [
            PairRelation(assetA: "a", assetB: "b", distance: 0.10),
            PairRelation(assetA: "b", assetB: "c", distance: 0.11),
            PairRelation(assetA: "a", assetB: "c", distance: 0.12),
            PairRelation(assetA: "x", assetB: "y", distance: 0.05),
        ]
        let all = records(["a", "b", "c", "x", "y"])

        let forward = SimilarityGrouping.nearGroups(relations: relations, threshold: 0.2, records: all)
        let reversed = SimilarityGrouping.nearGroups(
            relations: relations.reversed(),
            threshold: 0.2,
            records: all
        )
        #expect(forward == reversed)
        #expect(forward.map(\.memberAssetIDs) == [["a", "b", "c"], ["x", "y"]])
    }

    @Test func missingRecordDropsTheGroupRatherThanRecommendBlindly() {
        let relations = [PairRelation(assetA: "a", assetB: "ghost", distance: 0.1)]
        let groups = SimilarityGrouping.nearGroups(
            relations: relations,
            threshold: 0.2,
            records: records(["a"])
        )
        // "ghost" has no catalog record, so neither member can be scored.
        #expect(groups.isEmpty)
    }

    @Test func pairRelationCanonicalizesOrder() {
        let relation = PairRelation(assetA: "zeta", assetB: "alpha", distance: 0.3)
        #expect(relation.assetA == "alpha")
        #expect(relation.assetB == "zeta")
        #expect(
            relation == PairRelation(assetA: "alpha", assetB: "zeta", distance: 0.3)
        )
    }

    @Test func emptyRelationsProduceNoGroups() {
        let groups = SimilarityGrouping.nearGroups(relations: [], threshold: 0.2, records: [:])
        #expect(groups.isEmpty)
    }
}
