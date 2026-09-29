import Testing
@testable import Netto

private func makeGroup(
    members: [String],
    best: String,
    kind: PhotoSimilarityGroupKind = .nearDuplicates
) -> PhotoSimilarityGroup {
    var scores: [String: PhotoAssetQualityScore] = [:]
    for member in members {
        scores[member] = PhotoAssetQualityScore(
            localIdentifier: member,
            isFavorite: false,
            representsBurst: false,
            pixelCount: 12_000_000,
            hasAdjustments: false,
            creationDate: nil
        )
    }
    let evidence: PhotoAnalysisEvidence = kind == .exactDuplicates
        ? .exactContent(fingerprint: "fp:" + members.joined(separator: ","), byteLength: 1024)
        : .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15)
    return PhotoSimilarityGroup(
        kind: kind,
        memberAssetIDs: members,
        evidence: evidence,
        recommendedBestAssetID: best,
        memberScores: scores
    )
}

struct PhotoSelectionModelTests {
    @Test func defaultSelectsEveryMemberExceptRecommendations() {
        let group = makeGroup(members: ["a", "b", "c"], best: "b")
        let model = PhotoSelectionModel(groups: [group])

        #expect(model.isSelected("a"))
        #expect(!model.isSelected("b"))
        #expect(model.isSelected("c"))
        #expect(model.selectedCount == 2)
        #expect(model.selectedCount(inGroup: group.id) == 2)
    }

    @Test func recommendationIsProtectedAcrossEveryGroupItBelongsTo() {
        // "x" is the best of group 1 but also a plain member of group 2: still protected.
        let group1 = makeGroup(members: ["x", "a"], best: "x")
        let group2 = makeGroup(members: ["x", "b", "c"], best: "b")
        let model = PhotoSelectionModel(groups: [group1, group2])

        #expect(!model.isSelected("x"))
        #expect(model.isSelected("a"))
        #expect(model.isSelected("c"))
        #expect(model.selectedCount == 2)
        #expect(model.groupIDs(containing: "x") == Set([group1.id, group2.id]))
    }

    @Test func togglingTwiceRestoresTheExactPreviousState() {
        let group = makeGroup(members: ["a", "b"], best: "a")
        var model = PhotoSelectionModel(groups: [group])
        let before = model

        model.toggle("b")
        #expect(!model.isSelected("b"))
        model.toggle("b")
        #expect(model == before)
    }

    @Test func unknownAssetsAreNeverEnteredIntoTheSelection() {
        let group = makeGroup(members: ["a", "b"], best: "a")
        var model = PhotoSelectionModel(groups: [group])

        model.setSelected(true, forAsset: "not-a-member")
        model.toggle("not-a-member")
        #expect(!model.isSelected("not-a-member"))
        #expect(model.selectedCount == 1)
        #expect(!model.contains("not-a-member"))
        #expect(model.contains("b"))
    }

    @Test func selectAllExceptRecommendedIsExactEvenAfterOverride() {
        let group = makeGroup(members: ["a", "b", "c"], best: "b")
        var model = PhotoSelectionModel(groups: [group])

        // User explicitly marks the recommendation for cleanup…
        model.setSelected(true, forAsset: "b")
        #expect(model.selectionState(inGroup: group.id) == .all)

        // …then invokes the labelled action: its outcome is exactly its label.
        model.selectAllExceptRecommended(inGroup: group.id)
        #expect(model.selectionState(inGroup: group.id) == .some(selected: 2, total: 3))
        #expect(!model.isSelected("b"))
        #expect(model.isSelected("a"))
        #expect(model.isSelected("c"))
    }

    @Test func clearGroupTouchesOnlyThatGroup() {
        let group1 = makeGroup(members: ["a", "b"], best: "a")
        let group2 = makeGroup(members: ["c", "d"], best: "c")
        var model = PhotoSelectionModel(groups: [group1, group2])
        model.clearGroup(group1.id)

        #expect(model.selectionState(inGroup: group1.id) == .none)
        #expect(model.selectedCount == 1)
        // group2's defaults are untouched: "c" is its protected recommendation, "d" stays selected.
        #expect(!model.isSelected("c"))
        #expect(model.isSelected("d"))
        #expect(model.selectedCount(inGroup: group2.id) == 1)
    }

    @Test func keepRecommendedDeselectsOnlyTheRecommendation() {
        let group = makeGroup(members: ["a", "b", "c"], best: "a")
        var model = PhotoSelectionModel(groups: [group])

        // Default keeps the recommendation out: b and c are selected.
        #expect(model.selectionState(inGroup: group.id) == .some(selected: 2, total: 3))

        // User overrides and marks the recommendation for cleanup…
        model.setSelected(true, forAsset: "a")
        #expect(model.selectionState(inGroup: group.id) == .all)

        // …then invokes "Keep Recommended": only "a" is affected.
        model.keepRecommended(inGroup: group.id)
        #expect(model.selectionState(inGroup: group.id) == .some(selected: 2, total: 3))
        #expect(!model.isSelected("a"))
        #expect(model.isSelected("b"))
        #expect(model.isSelected("c"))
    }

    @Test func selectionStateCoversAllThreeCases() {
        let group = makeGroup(members: ["a", "b", "c"], best: "a")
        var model = PhotoSelectionModel(groups: [group])

        model.clearGroup(group.id)
        #expect(model.selectionState(inGroup: group.id) == .none)

        model.setSelected(true, forAsset: "c")
        #expect(model.selectionState(inGroup: group.id) == .some(selected: 1, total: 3))

        model.selectAllExceptRecommended(inGroup: group.id)
        model.setSelected(true, forAsset: "a")
        #expect(model.selectionState(inGroup: group.id) == .all)
    }

    @Test func emptyModelIsInertButValid() {
        var model = PhotoSelectionModel()
        model.toggle("ghost")
        model.setSelected(true, forAsset: "ghost")
        model.selectAllExceptRecommended(inGroup: "ghost-group")
        model.clearGroup("ghost-group")
        model.keepRecommended(inGroup: "ghost-group")

        #expect(model.selectedCount == 0)
        #expect(model.selectedIDs.isEmpty)
        #expect(model.memberIDs(inGroup: "ghost-group").isEmpty)
        #expect(model.selectionState(inGroup: "ghost-group") == .none)
        #expect(model.selectedCount(inGroup: "ghost-group") == 0)
    }

    @Test func initFromResultCoversExactAndSimilarGroups() {
        let exact = makeGroup(members: ["e1", "e2"], best: "e1", kind: .exactDuplicates)
        let near = makeGroup(members: ["n1", "n2", "n3"], best: "n2")
        let result = PhotoAnalysisResult(
            exactGroups: [exact],
            similarGroups: [near],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: 0.15,
            totalRecordCount: 3,
            candidateBucketCount: 1,
            candidatePairCount: 3
        )

        let model = PhotoSelectionModel(result: result)
        #expect(model.selectedCount == 3)
        #expect(!model.isSelected("e1"))
        #expect(!model.isSelected("n2"))
        #expect(model.isSelected("e2"))
        #expect(model.isSelected("n1"))
        #expect(model.isSelected("n3"))
        #expect(model.selectedCount(inGroup: exact.id) == 1)
        #expect(model.selectedCount(inGroup: near.id) == 2)
    }
}
