import Foundation
import Testing
@testable import Netto

// MARK: - Swipe Review (M4K): session semantics over the existing PhotoSelectionModel
//
// The swipe session is pure cursor/history logic; every decision is written through the
// *shared* selection exactly as the view does (`env.mutateSelection { model.decide(…) }`),
// so these tests prove the contract the screen depends on: keep deselects, delete selects,
// undo is an exact restore, decisions outlive the session, completion counts are honest —
// and none of it can reach the scanner or the deletion pipeline. No photo library, no
// network: the loader and PhotoKit are never touched.

@MainActor
struct SwipeReviewTests {
    // MARK: Session order (presentation, pure)

    @Test func itemsFollowGroupAndMemberOrderWithoutDuplicates() {
        let items = SwipeReviewPresentation.items(from: fixtureResult())

        // Exact groups first, then similar — the order the results list renders — each
        // group's members in their declared order; `e2` belongs to both groups and is
        // presented exactly once (first group wins), so a session can never repeat a photo.
        #expect(items.map(\.assetID) == ["e1", "e2", "e3", "n1"])
        #expect(items.map(\.groupOrdinal) == [1, 1, 1, 2])
        #expect(items.map(\.groupKind) == [
            .exactDuplicates, .exactDuplicates, .exactDuplicates, .nearDuplicates,
        ])
        // Recommended KEEPs are part of the session — swipe mode reaches the same selection
        // the grid does, not a filtered subset of it.
        #expect(items.map(\.isRecommended) == [true, false, false, true])
        // Only photos that exist in the analysis result — nothing else can enter the deck.
        #expect(Set(items.map(\.assetID)).isSubset(of: ["e1", "e2", "e3", "n1"]))
    }

    @Test func positionAndCountCopyIsExact() {
        #expect(SwipeReviewPresentation.positionText(current: 12, total: 47) == "12 of 47")
        #expect(SwipeReviewPresentation.positionAccessibilityLabel(current: 12, total: 47) == "Photo 12 of 47")
        #expect(SwipeReviewPresentation.reviewedCountText(47) == "47 photos reviewed")
        #expect(SwipeReviewPresentation.reviewedCountText(1) == "1 photo reviewed")
        #expect(SwipeReviewPresentation.selectedForCleanupText(5) == "5 photos selected for cleanup")
        #expect(SwipeReviewPresentation.selectedForCleanupText(1) == "1 photo selected for cleanup")
        #expect(SwipeReviewPresentation.groupContext(
            for: SwipeReviewItem(assetID: "x", groupKind: .nearDuplicates, groupOrdinal: 3, isRecommended: false)
        ) == "Similar photo · group 3")
        #expect(SwipeReviewPresentation.entryLabel == "Swipe Review")
        #expect(SwipeReviewPresentation.completionTitle == "You're all caught up.")
    }

    // MARK: Swipe semantics (spec 1–4)

    @Test func swipeRightKeepsASelectedPhotoByDeselectingIt() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(env.selection.isSelected("e2")) // default selection (e2 is not the KEEP)

        // Swipe right past the first photo (keep — already unselected, stays that way), then
        // right on the selected one: it leaves the cleanup set.
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(!env.selection.isSelected("e1"))
        env.mutateSelection { model.decide(.keep, selection: &$0) }

        #expect(!env.selection.isSelected("e2"))
        #expect(model.cursor == 2)
    }

    @Test func swipeLeftMarksAnUnselectedPhotoForCleanup() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(!env.selection.isSelected("e1")) // the recommended KEEP starts unselected

        env.mutateSelection { model.decide(.delete, selection: &$0) }

        #expect(env.selection.isSelected("e1"))
        #expect(env.selection.selectedCount == 3)
    }

    @Test func keepOnAPhotoTheUserAlreadyDeselectedLeavesItDeselected() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        env.mutateSelection { $0.setSelected(false, forAsset: "e2") } // user cleared it in the grid
        let model = SwipeReviewModel(items: [item("e2")])

        env.mutateSelection { model.decide(.keep, selection: &$0) }

        #expect(!env.selection.isSelected("e2"))
    }

    @Test func deleteOnAPhotoTheUserAlreadySelectedKeepsItSelected() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        env.mutateSelection { $0.setSelected(false, forAsset: "e3") } // user cleared it…
        env.mutateSelection { $0.setSelected(true, forAsset: "e3") }  // …then re-marked it
        let model = SwipeReviewModel(items: [item("e3")])

        env.mutateSelection { model.decide(.delete, selection: &$0) }

        #expect(env.selection.isSelected("e3"))
        #expect(env.selection.selectedCount == 2) // {e2, e3}: delete is a no-op on e3
    }

    // MARK: Undo (spec 5)

    @Test func undoRestoresThePreviousSelectionAndPosition() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        let before = env.selection

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(env.selection.isSelected("e1"))
        #expect(model.cursor == 1)
        #expect(model.canUndo)

        env.mutateSelection { model.undo(selection: &$0) }

        #expect(model.cursor == 0)
        #expect(model.currentItem?.assetID == "e1") // back on the swiped photo
        #expect(env.selection == before) // exact restore, not a re-derivation
        #expect(!env.selection.isSelected("e1"))
        #expect(!model.canUndo)
    }

    @Test func undoAtTheStartAndDecideAtTheEndAreBoundaryNoOps() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: [item("e1")])
        let before = env.selection

        env.mutateSelection { model.undo(selection: &$0) } // nothing to undo yet
        #expect(env.selection == before)
        #expect(model.cursor == 0)

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        let afterSwipe = env.selection
        env.mutateSelection { model.decide(.keep, selection: &$0) } // deck is finished
        #expect(env.selection == afterSwipe)
        #expect(model.cursor == 1)
        #expect(model.isComplete)
    }

    // MARK: Multiple swipes & exit (spec 6–7)

    @Test func multipleSwipesPreserveEveryDecision() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 → marked
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e2 → cleared
        env.mutateSelection { model.decide(.delete, selection: &$0) } // e3 → marked

        #expect(model.cursor == 3)
        #expect(env.selection.isSelected("e1"))
        #expect(!env.selection.isSelected("e2"))
        #expect(env.selection.isSelected("e3"))
        #expect(!env.selection.isSelected("n1")) // untouched so far
        #expect(env.selection.selectedCount == 2)
    }

    @Test func exitingSwipeReviewPreservesEveryDecision() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        let decidedSelection = env.selection

        // Exit the screen (the session object goes away with it) and read the selection
        // exactly as Similar Photos does on return: every decision survived, no reset.
        let survived = env.selection
        #expect(survived == decidedSelection)
        #expect(env.selectionCount(for: .similarPhotos) == env.selection.selectedCount)
        #expect(env.selection.isSelected("e1"))
        #expect(!env.selection.isSelected("e2"))

        // Re-entering starts a fresh cursor over the same, preserved selection.
        let fresh = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))
        #expect(fresh.cursor == 0)
        #expect(fresh.history.isEmpty)
        #expect(env.selection == decidedSelection)
    }

    // MARK: Completion (spec 8)

    @Test func completionCountsAreExact() {
        let env = makeEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) } // e1 marked
        env.mutateSelection { model.decide(.delete, selection: &$0) } // e2 marked (already was)
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // e3 cleared
        env.mutateSelection { model.decide(.keep, selection: &$0) }   // n1 cleared (already was)

        #expect(model.isComplete)
        #expect(model.currentItem == nil)
        #expect(model.reviewedCount == 4)
        #expect(SwipeReviewPresentation.reviewedCountText(model.reviewedCount) == "4 photos reviewed")
        // Selected = e1 + e2 (e3 cleared, n1 protected) — the live shared selection, not a
        // count owned by the session.
        #expect(env.selection.selectedCount == 2)
        #expect(SwipeReviewPresentation.selectedForCleanupText(env.selection.selectedCount)
                == "2 photos selected for cleanup")
        #expect(SwipeReviewPresentation.positionText(current: 4, total: 4) == "4 of 4")
    }

    // MARK: Review destination (spec 9)

    @Test func completionHandsOffToTheExistingReviewFlow() async {
        let env = makeReviewReadyEnv()
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        env.mutateSelection { model.decide(.delete, selection: &$0) }
        #expect(model.isComplete == false)
        #expect(model.reviewedCount == 1)

        // The completion state's primary action targets the existing review flow — the same
        // `ReviewSelectionView` entry the bottom Review button uses (`reviewDidAppear` →
        // plan preparation from the shared selection). Swipe mode builds no destination of
        // its own.
        #expect(SwipeReviewPresentation.completionPrimaryDestination == .existingReviewFlow)
        #expect(SwipeReviewPresentation.completionPrimaryTitle == "Review Cleanup")
        #expect(SwipeReviewPresentation.completionSecondaryDestination == .dismissToSimilarPhotos)

        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == env.selection.selectedCount)
        #expect(plan.selectionSnapshot == env.selection.selectedIDs)
    }

    // MARK: Scanner & deletion safety (spec 10–11)

    @Test func swipingNeverInvokesTheScanner() {
        let calls = CallCounter()
        let env = makeEnv(calls: calls)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        for decision in [SwipeReviewModel.Decision.delete, .keep, .delete, .keep] {
            env.mutateSelection { model.decide(decision, selection: &$0) }
        }
        env.mutateSelection { model.undo(selection: &$0) }

        #expect(calls.count == 0)
        #expect(env.analysisState == .completed(result)) // result byte-identical, no rescan
        #expect(env.analysisState.isRunning == false)
    }

    @Test func swipingNeverReachesTheDeletionPipeline() {
        let deletion = CountingDeletionService()
        let env = makeEnv(deletionService: deletion)
        let result = fixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: SwipeReviewPresentation.items(from: result))

        for decision in [SwipeReviewModel.Decision.delete, .keep, .delete, .keep] {
            env.mutateSelection { model.decide(decision, selection: &$0) }
        }

        // Selection-only: the deletion state machine was never entered, the PhotoKit-backed
        // service was never called, and the analysis result is untouched.
        #expect(deletion.callCount == 0)
        #expect(env.deletionState == .noSelection)
        #expect(env.analysisState == .completed(result))
        #expect(Set(env.selection.memberIDs(inGroup: result.exactGroups[0].id)) == ["e1", "e2", "e3"])
    }

    // MARK: Single source of truth (spec 12)

    @Test func historySnapshotsTheSharedSelectionRatherThanShadowingIt() {
        let env = makeEnv()
        let result = fixtureResult()
        env.selection = PhotoSelectionModel(result: result)
        let model = SwipeReviewModel(items: [item("e1")])

        // The photo is unselected when swiped (keep leaves it unselected)…
        env.mutateSelection { model.decide(.keep, selection: &$0) }
        #expect(model.history == [SwipeReviewModel.HistoryEntry(assetID: "e1", wasSelected: false)])

        // …the grid changes the same shared selection while the session is still open…
        env.mutateSelection { $0.setSelected(true, forAsset: "e1") }
        #expect(env.selection.isSelected("e1"))

        // …and Undo restores what the *shared model* recorded at swipe time: the session
        // holds no selection of its own — it only ever reads and writes through the inout
        // selection the environment passes in.
        env.mutateSelection { model.undo(selection: &$0) }
        #expect(!env.selection.isSelected("e1"))
        #expect(model.cursor == 0)
    }
}

// MARK: - Helpers

@MainActor
private func waitForPlanReady(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 5_000
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while env.deletionState.isBuildingPlan, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Two groups with one shared member (`e2`), so ordering, deduplication, and per-group
/// context all have something real to operate on. Default selection: everything except the
/// protected KEEPs (`e1`, `n1`) → `{e2, e3}`.
private func fixtureResult() -> PhotoAnalysisResult {
    PhotoAnalysisResult(
        exactGroups: [
            PhotoSimilarityGroup(
                kind: .exactDuplicates,
                memberAssetIDs: ["e1", "e2", "e3"],
                evidence: .exactContent(fingerprint: "f", byteLength: 100),
                recommendedBestAssetID: "e1",
                memberScores: [:]
            ),
        ],
        similarGroups: [
            PhotoSimilarityGroup(
                kind: .nearDuplicates,
                memberAssetIDs: ["e2", "n1"],
                evidence: .visualSimilarity(minDistance: 0.1, maxDistance: 0.4, threshold: 0.6),
                recommendedBestAssetID: "n1",
                memberScores: [:]
            ),
        ],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: 0.6,
        totalRecordCount: 4,
        candidateBucketCount: 2,
        candidatePairCount: 4
    )
}

private func item(_ assetID: String) -> SwipeReviewItem {
    SwipeReviewItem(assetID: assetID, groupKind: .exactDuplicates, groupOrdinal: 1, isRecommended: false)
}

@MainActor
private func makeEnv(
    calls: CallCounter? = nil,
    deletionService: any PhotoDeleting = CountingDeletionService()
) -> AppEnvironment {
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        makePhotoLibrary: {
            calls?.increment()
            return FakeLibrary(records: [])
        },
        deletionService: deletionService,
        // Completions in this suite must never touch the app's real persisted snapshot.
        scanSnapshotStore: InMemoryScanSnapshotStore()
    )
    env.photoPermissionState = .authorized
    return env
}

/// An environment whose catalog and permissions are complete enough for the existing review
/// flow to prepare a plan — the handoff target of the completion state's "Review Cleanup".
@MainActor
private func makeReviewReadyEnv() -> AppEnvironment {
    let records = ["e1", "e2", "e3", "n1"].map { makeRecord(id: $0) }
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        sizeProvider: FakeSizeProvider(),
        scanSnapshotStore: InMemoryScanSnapshotStore()
    )
    env.photoPermissionState = .authorized
    env.catalogState = .completed(CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    ))
    return env
}

/// Call counter for the injected library factory. Only ever touched from the main actor
/// (the factory is invoked synchronously inside `AppEnvironment`), so an unchecked box is
/// safe here.
private final class CallCounter: @unchecked Sendable {
    private var calls = 0

    func increment() { calls += 1 }
    var count: Int { calls }
}

/// Counts executions so "no PhotoKit deletion from Swipe Review" is an assertion, not an
/// inference from state alone.
private final class CountingDeletionService: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        recordCall()
        return .succeeded(DeletionSuccess(plannedCount: 0, verifiedRemovedCount: 0, remainingIDs: []))
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class FakePermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
    private let state: PermissionState

    init(_ state: PermissionState) {
        self.state = state
    }

    func currentStatus() -> PermissionState { state }
    func requestAccess() async -> PermissionState { state }
}

private struct FakeSizeProvider: AssetSizeProviding {
    func sizes(for localIdentifiers: [String]) async -> [String: Int64] { [:] }
}

private struct FakeStorage: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        StorageSnapshot(totalCapacity: 100, availableCapacity: 60)
    }
}

private struct FakeLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState = .authorized
    let records: [PhotoAssetRecord]

    func assetCount() throws -> Int {
        records.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, records.count)
        guard lower < upper else { return [] }
        return Array(records[lower..<upper])
    }
}

private func makeRecord(id: String) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: 1000,
        pixelHeight: 1000,
        creationDate: Date(timeIntervalSince1970: 1_750_000_000),
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
