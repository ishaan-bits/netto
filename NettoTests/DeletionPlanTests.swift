import Foundation
import Testing
@testable import Netto

// MARK: - Planner: selection → immutable plan

struct DeletionPlannerTests {
    private let planner = DeletionPlanner()

    @Test func emptySelectionCanNeverProduceAPlan() {
        #expect(throws: DeletionPlannerError.self) {
            try planner.makePlan(
                selectedIDs: [],
                recordsByID: recordsByID("a", "b"),
                result: result,
                resolvedSizes: [:],
                authorization: .authorized,
                sessionToken: "s1"
            )
        }
    }

    @Test func selectedIDsWithoutRecordsFailTheWholePlanInsteadOfShrinkingIt() {
        do {
            _ = try planner.makePlan(
                selectedIDs: ["a", "missing-1", "missing-2"],
                recordsByID: recordsByID("a"),
                result: result,
                resolvedSizes: [:],
                authorization: .authorized,
                sessionToken: "s1"
            )
            Issue.record("expected missingRecords")
        } catch let error as DeletionPlannerError {
            guard case .missingRecords(let missing) = error else {
                Issue.record("expected missingRecords, got \(error)")
                return
            }
            #expect(missing == ["missing-1", "missing-2"])
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func planItemsAreExactlyTheSelectionSortedAndDeduplicated() {
        // Set input: insertion order and duplicates cannot affect the plan.
        let plan = try! planner.makePlan(
            selectedIDs: ["c", "a", "b", "a"],
            recordsByID: recordsByID("a", "b", "c"),
            result: result,
            resolvedSizes: ["a": 10, "b": 20, "c": 30],
            authorization: .authorized,
            sessionToken: "s1"
        )
        #expect(plan.count == 3)
        #expect(plan.items.map(\.localIdentifier) == ["a", "b", "c"])
        #expect(plan.selectionSnapshot == ["a", "b", "c"])
        #expect(plan.items.map(\.sizeInBytes) == [10, 20, 30])
        #expect(plan.schemaVersion == DeletionPlan.currentVersion)
        #expect(plan.authorization == .authorized)
        #expect(plan.sessionToken == "s1")
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: result))
    }

    @Test func missingSizeStaysNilAndIsNeverFabricatedAsZero() {
        let plan = try! planner.makePlan(
            selectedIDs: ["a", "b"],
            recordsByID: recordsByID("a", "b"),
            result: result,
            resolvedSizes: ["a": 100],
            authorization: .authorized,
            sessionToken: "s1"
        )
        #expect(plan.items[0].sizeInBytes == 100)
        #expect(plan.items[1].sizeInBytes == nil)

        let summary = plan.sizeSummary
        #expect(summary.measuredBytes == 100)
        #expect(summary.measuredCount == 1)
        #expect(summary.unresolvedCount == 1)
        #expect(!summary.isExact)
        #expect(!summary.isFullyUnresolved)
    }

    @Test func fullyUnresolvedSummaryIsDistinctFromZeroBytes() {
        let plan = try! planner.makePlan(
            selectedIDs: ["a", "b"],
            recordsByID: recordsByID("a", "b"),
            result: result,
            resolvedSizes: [:],
            authorization: .authorized,
            sessionToken: "s1"
        )
        let summary = plan.sizeSummary
        #expect(summary.isFullyUnresolved)
        #expect(summary.measuredBytes == 0)
        #expect(summary.unresolvedCount == 2)
        #expect(!summary.isExact)
    }

    @Test func exactSummaryMeansEveryItemWasMeasured() {
        let plan = try! planner.makePlan(
            selectedIDs: ["a", "b"],
            recordsByID: recordsByID("a", "b"),
            result: result,
            resolvedSizes: ["a": 1, "b": 2],
            authorization: .authorized,
            sessionToken: "s1"
        )
        #expect(plan.sizeSummary.isExact)
        #expect(plan.sizeSummary.measuredBytes == 3)
        #expect(plan.sizeSummary.unresolvedCount == 0)
    }

    @Test func categoriesComeFromAnalysisAndExactWinsOverSimilar() {
        // "b" is in both an exact and a similar group: exact wins for a deterministic label.
        let exact = PhotoSimilarityGroup(
            kind: .exactDuplicates,
            memberAssetIDs: ["a", "b"],
            evidence: .exactContent(fingerprint: "f1", byteLength: 10),
            recommendedBestAssetID: "a",
            memberScores: [:]
        )
        let near = PhotoSimilarityGroup(
            kind: .nearDuplicates,
            memberAssetIDs: ["b", "c"],
            evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15),
            recommendedBestAssetID: "c",
            memberScores: [:]
        )
        let mixed = PhotoAnalysisResult(
            exactGroups: [exact],
            similarGroups: [near],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: 0.15,
            totalRecordCount: 6,
            candidateBucketCount: 2,
            candidatePairCount: 4
        )

        let plan = try! planner.makePlan(
            selectedIDs: ["a", "b", "c"],
            recordsByID: recordsByID("a", "b", "c"),
            result: mixed,
            resolvedSizes: [:],
            authorization: .authorized,
            sessionToken: "s1"
        )
        #expect(plan.items[0].category == .exactDuplicates)
        #expect(plan.items[1].category == .exactDuplicates)
        #expect(plan.items[2].category == .nearDuplicates)
    }

    @Test func analysisSignatureIsStableForSameShapeAndChangesWithMembership() {
        let base = DeletionPlanner.analysisSignature(for: result)

        let sameGroupsDifferentOrder = PhotoAnalysisResult(
            exactGroups: result.exactGroups.reversed(),
            similarGroups: result.similarGroups,
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: result.totalRecordCount,
            candidateBucketCount: 1,
            candidatePairCount: 1
        )
        #expect(DeletionPlanner.analysisSignature(for: sameGroupsDifferentOrder) == base)

        let changed = PhotoAnalysisResult(
            exactGroups: [PhotoSimilarityGroup(
                kind: .exactDuplicates,
                memberAssetIDs: ["a", "z"],
                evidence: .exactContent(fingerprint: "f1", byteLength: 10),
                recommendedBestAssetID: "a",
                memberScores: [:]
            )],
            similarGroups: result.similarGroups,
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: result.totalRecordCount,
            candidateBucketCount: 1,
            candidatePairCount: 1
        )
        #expect(DeletionPlanner.analysisSignature(for: changed) != base)
    }

    @Test func mediaTypeAndCategoryLandOnEveryItem() {
        let videoRecord = makeRecord(id: "v", mediaType: .video)
        var byID = recordsByID("a")
        byID["v"] = videoRecord
        let plan = try! planner.makePlan(
            selectedIDs: ["a", "v"],
            recordsByID: byID,
            result: result,
            resolvedSizes: [:],
            authorization: .limited,
            sessionToken: "s1"
        )
        #expect(plan.items[0].mediaType == .image)
        #expect(plan.items[1].mediaType == .video)
        #expect(plan.items[1].sizeInBytes == nil)
        #expect(plan.authorization == .limited)
    }

    // MARK: Fixtures

    private var result: PhotoAnalysisResult {
        PhotoAnalysisResult(
            exactGroups: [
                PhotoSimilarityGroup(
                    kind: .exactDuplicates,
                    memberAssetIDs: ["a", "b"],
                    evidence: .exactContent(fingerprint: "f1", byteLength: 10),
                    recommendedBestAssetID: "a",
                    memberScores: [:]
                )
            ],
            similarGroups: [],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 6,
            candidateBucketCount: 1,
            candidatePairCount: 1
        )
    }

    private func recordsByID(_ ids: String...) -> [String: PhotoAssetRecord] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, makeRecord(id: $0)) })
    }
}

// MARK: - Confirmation boundary

struct DeletionPlanConfirmationTests {
    @Test func nonEmptyPlanConfirmsWithTheSameContents() throws {
        let plan = makePlan(items: [
            makeItem(id: "a", size: 5),
            makeItem(id: "b", size: nil)
        ])
        let confirmed = try plan.confirmed()
        #expect(confirmed.plan == plan)
        #expect(confirmed.plan.count == 2)
    }

    @Test func emptyPlanCanNeverReachTheMutationType() {
        let plan = makePlan(items: [])
        #expect(plan.isEmpty)
        #expect(throws: DeletionRejection.self) {
            try plan.confirmed()
        }
    }

    private func makeItem(id: String, size: Int64?) -> DeletionPlanItem {
        DeletionPlanItem(localIdentifier: id, mediaType: .image, sizeInBytes: size, category: nil)
    }

    private func makePlan(items: [DeletionPlanItem]) -> DeletionPlan {
        DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: items,
            authorization: .authorized,
            sessionToken: "s",
            analysisSignature: "sig"
        )
    }
}

// MARK: - Staleness rules

struct DeletionPlanValidatorTests {
    private let plan = DeletionPlan(
        schemaVersion: DeletionPlan.currentVersion,
        items: [DeletionPlanItem(
            localIdentifier: "a",
            mediaType: .image,
            sizeInBytes: 1,
            category: nil
        )],
        authorization: .authorized,
        sessionToken: "session-1",
        analysisSignature: "sig-1"
    )

    private var matchingContext: PlanExecutionContext {
        PlanExecutionContext(
            selectionIDs: ["a"],
            sessionToken: "session-1",
            analysisSignature: "sig-1"
        )
    }

    @Test func matchingContextAndAuthorizationIsClean() {
        #expect(DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: matchingContext,
            freshAuthorization: .authorized
        ).isEmpty)
    }

    @Test func selectionDriftIsDetected() {
        let reasons = DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: PlanExecutionContext(
                selectionIDs: ["a", "b"],
                sessionToken: "session-1",
                analysisSignature: "sig-1"
            ),
            freshAuthorization: .authorized
        )
        #expect(reasons == [.selectionChanged])
    }

    @Test func authorizationChangeIsDetectedInBothDirections() {
        let downgraded = DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: matchingContext,
            freshAuthorization: .limited
        )
        #expect(downgraded == [.authorizationChanged(from: .authorized, to: .limited)])

        let upgradedPlan = DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: plan.items,
            authorization: .limited,
            sessionToken: "session-1",
            analysisSignature: "sig-1"
        )
        let upgraded = DeletionPlanValidator.stalenessReasons(
            plan: upgradedPlan,
            context: matchingContext,
            freshAuthorization: .authorized
        )
        #expect(upgraded == [.authorizationChanged(from: .limited, to: .authorized)])
    }

    @Test func sessionAndAnalysisDriftAreDetected() {
        let reasons = DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: PlanExecutionContext(
                selectionIDs: ["a"],
                sessionToken: "session-2",
                analysisSignature: "sig-2"
            ),
            freshAuthorization: .authorized
        )
        #expect(reasons == [.sessionChanged, .analysisChanged])
    }

    @Test func reasonOrderIsDeterministicSessionFirst() {
        let reasons = DeletionPlanValidator.stalenessReasons(
            plan: plan,
            context: PlanExecutionContext(
                selectionIDs: [],
                sessionToken: "session-2",
                analysisSignature: "sig-2"
            ),
            freshAuthorization: .denied
        )
        #expect(reasons == [
            .sessionChanged,
            .analysisChanged,
            .selectionChanged,
            .authorizationChanged(from: .authorized, to: .denied)
        ])
    }
}

// MARK: - Fixtures

private func makeRecord(id: String, mediaType: PhotoMediaType = .image) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: [],
        pixelWidth: 1000,
        pixelHeight: 1000,
        creationDate: nil,
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: .library,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}
