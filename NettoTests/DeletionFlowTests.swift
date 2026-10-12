import Foundation
import Testing
@testable import Netto

// MARK: - AppEnvironment deletion orchestration

@MainActor
struct DeletionFlowTests {
    // MARK: Plan preparation

    @Test func nothingSelectedNeverLeavesNoSelection() async {
        let (env, _) = makeEnv()
        env.prepareDeletionPlan()
        #expect(env.deletionState == .noSelection)
    }

    @Test func prepareBuildsAPlanOverTheCurrentSelection() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 2)
        #expect(plan.selectionSnapshot == ["a", "b"])
        #expect(plan.sizeSummary.measuredBytes == 500)
        #expect(plan.sizeSummary.unresolvedCount == 1)
        #expect(plan.sessionToken == "session-1")
    }

    @Test func partialSizesStayUnresolvedInThePlan() async {
        let (env, _) = makeEnv(sizeProvider: FakeSizeProvider(sizes: ["b": 500]))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.localIdentifier, $0.sizeInBytes) })
        #expect(byID["a"] ?? Optional<Int64>.none == nil)
        #expect(byID["b"] == 500)
        #expect(!plan.sizeSummary.isExact)
    }

    /// U1 (behavior change, justified): a missing similarity *analysis* is no longer a
    /// dead end — Swipe Review's marks live in this same selection and its deck is the
    /// scanned catalog, so its "Review Cleanup" must open on a library that was never
    /// analysed instead of behind an error screen the user cannot act on. The plan falls
    /// back to the empty result exactly as the catalog-only sources do; the catalog gate
    /// below still fail-closes, and records, sizes, confirmation, and staleness are
    /// unchanged. The old test's analysis-gate half is replaced by
    /// `prepareOpensReviewWhenTheAnalysisHasNotRun`, pinning the new intent.
    @Test func prepareFailsCleanlyWithoutCompletedCatalog() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.catalogState = .notStarted
        env.prepareDeletionPlan()
        guard case .failed = env.deletionState else {
            Issue.record("expected failed without catalog, got \(env.deletionState)")
            return
        }
    }

    @Test func prepareOpensReviewWhenTheAnalysisHasNotRun() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.analysisState = .notStarted
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview without analysis, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 2)
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: .empty))
    }

    @Test func selectionChangeMakesAPreparedPlanStale() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateSelection { $0.toggle("b") }

        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    /// S1: only a change to *what is marked* may stale the plan. Admission-only mutations
    /// (Swipe Review re-admitting its whole deck on appear, for example) provably cannot
    /// alter the plan's selection snapshot — staling on them told the user their prepared
    /// review was out of date when nothing they chose had changed.
    @Test func aMutationThatChangesNoMarksKeepsThePlanReady() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateSelection { $0.admitLibraryAssets(["a", "b", "c"]) }

        guard case .readyForReview = env.deletionState else {
            Issue.record("expected the plan to stay ready for a no-op mark mutation, got \(env.deletionState)")
            return
        }
        #expect(env.selection.selectedCount == 2)
    }

    @Test func prepareIsGuardedWhileDeleting() async {
        let (env, _) = makeEnv()
        let plan = makePlan(ids: ["a", "b"])
        env.deletionState = .deleting(plan)
        env.prepareDeletionPlan()
        #expect(env.deletionState == .deleting(plan))
    }

    // MARK: Confirmation gating

    @Test func beginConfirmationOnlyMovesAReadyPlan() async {
        let (env, _) = makeEnv()
        env.beginConfirmation()
        #expect(env.deletionState == .noSelection)

        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)

        env.beginConfirmation()
        guard case .awaitingConfirmation = env.deletionState else {
            Issue.record("expected awaitingConfirmation, got \(env.deletionState)")
            return
        }
    }

    @Test func cancelConfirmationReturnsToReviewWithoutSideEffects() async {
        let (env, service) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()

        env.cancelConfirmation()

        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(service.callCount == 0)
    }

    @Test func confirmDeletionWithoutConfirmationNeverReachesTheService() async {
        let (env, service) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        // State is .readyForReview — confirmation never happened.
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        await env.confirmDeletion()

        #expect(service.callCount == 0)
        #expect(env.deletionState.plan != nil)
        if case .deleting = env.deletionState {
            Issue.record("must never enter .deleting without confirmation")
        }
    }

    // MARK: Outcomes

    @Test func successfulDeletionPreservesTheCompletedResultAndRefreshesStorage() async {
        let (env, service) = makeEnv(outcome: .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: []
        )))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: []
        )))
        #expect(service.callCount == 1)

        // The completed scan stands: only the confirmed removals are applied — the sole
        // two-member group dissolves, nothing is left selected, and no rescan is started.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.isEmpty)
        #expect(result.similarGroups.isEmpty)
        #expect(result.totalRecordCount == DeletionFlowFixtures.result.totalRecordCount)
        #expect(env.selection.selectedCount == 0)
        #expect(env.analysisState.isRunning == false)

        // The catalog is pruned in place, never dropped back to "start analysis".
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.isEmpty)
        #expect(env.storageSnapshot != nil)
    }

    @Test func serviceReceivesTheCurrentSelectionAndSession() async {
        let (env, service) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(service.callCount == 1)
        #expect(service.lastContext?.sessionToken == "session-1")
        #expect(service.lastContext?.selectionIDs == ["a", "b"])
        #expect(service.lastPlanCount == 2)
    }

    @Test func staleOutcomeLandsBackInPlanStale() async {
        let (env, _) = makeEnv(outcome: .stale([.selectionChanged]))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard let prepared = env.deletionState.plan else {
            Issue.record("expected a prepared plan")
            return
        }
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .planStale(let plan, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(plan == prepared)
        #expect(reasons == [.selectionChanged])
    }

    @Test func permissionDeniedOutcomeLandsInPermissionRequired() async {
        let (env, _) = makeEnv(outcome: .permissionDenied(.denied))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .permissionRequired(.denied))
        #expect(env.analysisState.isRunning == false)
    }

    @Test func mutationFailureShowsAFriendlyMessageNeverRawErrorText() async {
        let (env, _) = makeEnv(outcome: .mutationFailed("PHPhotosErrorDomain Code=-1 dump"))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .failed(let message) = env.deletionState else {
            Issue.record("expected failed, got \(env.deletionState)")
            return
        }
        #expect(!message.contains("PHPhotosErrorDomain"))
        #expect(!message.contains("dump"))
        #expect(message == DeletionPresentation.userFacingFailure(
            for: .mutationFailed("PHPhotosErrorDomain Code=-1 dump")
        ))
    }

    @Test func partialRemovalLandsInNeedsReview() async {
        let (env, _) = makeEnv(outcome: .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 1,
            remainingIDs: ["b"]
        )))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .needsReview(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 1,
            remainingIDs: ["b"]
        )))
        // Partial outcome: only the confirmed removal leaves the completed result — "a" is
        // gone from the groups and the catalog, "b" (which the service reports as still
        // present) is untouched.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.isEmpty)
        #expect(env.selection.selectedCount == 0)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.map(\.localIdentifier) == ["b"])
    }

    @Test func cancelledOutcomeReturnsToReviewForRetry() async {
        let (env, _) = makeEnv(outcome: .cancelled)
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard let prepared = env.deletionState.plan else {
            Issue.record("expected a prepared plan")
            return
        }
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .readyForReview(prepared))
    }

    @Test func verificationFailureIsReportedAsFailureNotSuccess() async {
        let (env, _) = makeEnv(outcome: .verificationFailed(
            "The deletion was requested, but the result could not be verified. Check Recently Deleted."
        ))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .failed(let message) = env.deletionState else {
            Issue.record("expected failed, got \(env.deletionState)")
            return
        }
        #expect(message.contains("could not be verified"))
        // Requested-but-unverified: nothing is confirmed removed, so every completed result,
        // the selection, and the catalog stand exactly as they were.
        #expect(env.analysisState == .completed(DeletionFlowFixtures.result))
        #expect(env.selection.selectedCount == 2)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stand after an unverified deletion, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.map(\.localIdentifier) == ["a", "b"])
    }

    @Test func deletingOneMemberKeepsTheGroupAndItsRecommendation() async {
        let (env, _) = makeEnv(
            records: ["c", "d", "e"].map { makeRecord(id: $0) },
            outcome: .succeeded(DeletionSuccess(
                plannedCount: 1,
                verifiedRemovedCount: 1,
                remainingIDs: []
            )),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(groups: [DeletionFlowFixtures.threeMemberGroup])
        env.mutateSelection {
            $0.deselectAll()
            $0.toggle("d")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.similarGroups.count == 1)
        let group = result.similarGroups[0]
        #expect(group.memberAssetIDs == ["c", "e"])
        #expect(group.recommendedBestAssetID == "c")
        #expect(env.selection.selectedCount == 0)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.map(\.localIdentifier) == ["c", "e"])
    }

    @Test func deletingTheRecommendedKeepPromotesARemainingMember() async {
        let (env, _) = makeEnv(
            records: ["c", "d", "e"].map { makeRecord(id: $0) },
            outcome: .succeeded(DeletionSuccess(
                plannedCount: 1,
                verifiedRemovedCount: 1,
                remainingIDs: []
            )),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(groups: [DeletionFlowFixtures.threeMemberGroup])
        env.mutateSelection {
            $0.deselectAll()
            $0.toggle("c")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.similarGroups.count == 1)
        let group = result.similarGroups[0]
        #expect(group.memberAssetIDs == ["d", "e"])
        #expect(group.recommendedBestAssetID == "d")
        #expect(env.selection.selectedCount == 0)
    }

    @Test func mutationFailureLeavesTheResultSelectionAndSnapshotUntouched() async {
        let store = InMemoryScanSnapshotStore()
        let completedAt = Date(timeIntervalSince1970: 1_758_999_000)
        try? store.save(ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "original-scan",
            completedAt: completedAt,
            result: DeletionFlowFixtures.result
        ))
        let (env, _) = makeEnv(outcome: .mutationFailed("PHPhotosErrorDomain Code=-1"), snapshotStore: store)
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .failed = env.deletionState else {
            Issue.record("expected failed, got \(env.deletionState)")
            return
        }
        // Nothing changed, so nothing moves: the completed result, the selection, the
        // catalog, and the persisted snapshot are all exactly as they were.
        #expect(env.analysisState == .completed(DeletionFlowFixtures.result))
        #expect(env.selection.selectedCount == 2)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stand after a failed deletion, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.map(\.localIdentifier) == ["a", "b"])
        #expect(store.saveCount == 1)
        #expect(store.loadLatest()?.scanID == "original-scan")
        #expect(store.loadLatest()?.result == DeletionFlowFixtures.result)
    }

    @Test func successfulDeletionPersistsAnUpdatedSnapshotOfTheSameScan() async {
        let store = InMemoryScanSnapshotStore()
        let completedAt = Date(timeIntervalSince1970: 1_758_999_000)
        try? store.save(ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "original-scan",
            completedAt: completedAt,
            result: DeletionFlowFixtures.result
        ))
        let (env, _) = makeEnv(snapshotStore: store)
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .completed(let updated) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        // Same completed scan, updated result: the identity is preserved, only the
        // confirmed removals are applied.
        guard let persisted = store.loadLatest() else {
            Issue.record("expected the updated snapshot to persist")
            return
        }
        #expect(persisted.scanID == "original-scan")
        #expect(persisted.completedAt == completedAt)
        #expect(persisted.result == updated)
        #expect(persisted.result.exactGroups.isEmpty)
        #expect(env.lastScanCompletedAt == completedAt)

        // A fresh launch restores the updated result, not the pre-deletion one.
        let restored = makeEnv(snapshotStore: store).env
        await restored.bootstrap()
        #expect(restored.analysisState == .completed(updated))
        #expect(restored.lastScanCompletedAt == completedAt)
        #expect(restored.selection.selectedCount == 0)
    }

    // MARK: Cross-feature invalidation

    @Test func startingAnalysisInvalidatesAPreparedPlan() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.startSimilarityAnalysis()

        #expect(env.deletionState == .noSelection)
        env.cancelSimilarityAnalysis()
    }

    @Test func analysisCannotStartWhileADeletionIsExecuting() async {
        let (env, _) = makeEnv()
        let plan = makePlan(ids: ["a"])
        env.deletionState = .deleting(plan)
        let before = env.analysisState

        env.startSimilarityAnalysis()

        #expect(env.analysisState == before)
        #expect(env.deletionState == .deleting(plan))
    }

    /// D1 (M13 behavior change, justified): a confirmed deletion during an in-flight analysis
    /// used to cancel and generation-supersede the run, stranding the state at `.running`
    /// forever (both scan entry points refuse to start over `.running`, bricking the feature
    /// until relaunch). The old fix wrote `.cancelled`. M13 instead *preserves* the running
    /// pass: its work for every asset that survived the mutation is valid, so cancelling it
    /// would throw that away and force a full re-run. The pass keeps its generation and runs
    /// to completion; the confirmed removals are reconciled out of its result when it lands
    /// (`deletionsDuringRunningPasses`), so it can never strand and never describes a deleted
    /// asset. Immediately after the deletion the state is therefore still `.running` — not
    /// `.cancelled`, not stranded (a real in-flight task completes it).
    @Test func deletionDuringAnAnalysisPreservesItInsteadOfStrandingOrCancelling() async {
        let (env, _) = makeEnv()
        env.analysisState = .running(PhotoAnalysisProgress(
            stage: .comparing, completedUnits: 1, totalUnits: 4
        ))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview over a running analysis, got \(env.deletionState)")
            return
        }

        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .succeeded = env.deletionState else {
            Issue.record("expected succeeded, got \(env.deletionState)")
            return
        }
        // The pass was neither cancelled nor stranded: it is still running (M13 lets it
        // finish and reconcile), and it was never flipped to a terminal state by the
        // deletion — which is exactly what used to brick the feature.
        guard case .running(let progress) = env.analysisState else {
            Issue.record("expected the running pass to be preserved, got \(env.analysisState)")
            return
        }
        #expect(progress.stage == .comparing)
    }

    @Test func reviewDidAppearDuringADeletionIsANoOp() {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        let plan = makePlan(ids: ["a"])
        env.deletionState = .deleting(plan)

        // A foreign review screen appearing mid-mutation must not run its universal reset:
        // `noSelection` is legal from `.deleting`, so without the guard the in-flight state
        // was silently wiped (the outcome then landed outside `.deleting` and tripped the
        // state machine) and a second plan could be prepared over a changing library.
        env.reviewDidAppear(from: .screenshots)

        #expect(env.deletionState == .deleting(plan))
        #expect(env.selection.selectedCount == 2)
    }

    @Test func reviewDidAppearDuringADeletionAlsoRefusesSameSourceEntry() {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        let plan = makePlan(ids: ["a"])
        env.deletionState = .deleting(plan)

        env.reviewDidAppear(from: .similarPhotos)

        #expect(env.deletionState == .deleting(plan))
    }

    @Test func standaloneCatalogRebuildInvalidatesACompletedAnalysis() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        guard case .completed = env.analysisState else {
            Issue.record("setup: expected a completed analysis, got \(env.analysisState)")
            return
        }

        env.startCatalogBuild()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(5_000))
        while env.catalogState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard case .completed = env.catalogState else {
            Issue.record("expected the rebuild to complete, got \(env.catalogState)")
            return
        }

        // Groups, selection, and any prepared plan were computed from the previous catalog —
        // a rebuilt catalog must never keep presenting them as current.
        #expect(env.analysisState == .notStarted)
        #expect(env.selection.selectedCount == 0)
        #expect(env.deletionState == .noSelection)
    }

    @Test func dismissReturnsEveryTerminalStateToNoSelection() async {
        let (env, _) = makeEnv()
        let success = DeletionSuccess(plannedCount: 1, verifiedRemovedCount: 1, remainingIDs: [])
        for state: DeletionState in [
            .succeeded(success),
            .needsReview(success),
            .failed("x"),
            .permissionRequired(.denied)
        ] {
            env.deletionState = state
            env.dismissDeletionResult()
            #expect(env.deletionState == .noSelection)
        }
    }

    // MARK: Deselect All (global)

    @Test func deselectAllStalesAPreparedPlanWithoutDeleting() async {
        let (env, service) = makeEnv()
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateSelection { $0.deselectAll() }

        // Stale plan, not deletion — Review reopens empty and the deletion engine
        // is never invoked.
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons.contains(.selectionChanged))
        #expect(env.selection.selectedCount == 0)
        #expect(service.callCount == 0)
    }

    // MARK: M13 — unified session coordination and shared worker budget

    /// The single Analyze tap starts both pipelines as one session (M13): immediately after
    /// `startImageAnalysis()`, similarity reports `.running` (its `preparing` stage, over the
    /// shared enumeration) and the sharpness pass reports `.running` too. Neither waits for
    /// the other to be admitted.
    @Test func oneAnalyzeTapStartsBothPipelinesConcurrently() {
        let (env, _) = makeEnv()
        env.startImageAnalysis()

        guard case .running(let progress) = env.analysisState else {
            Issue.record("expected similarity running, got \(env.analysisState)")
            return
        }
        #expect(progress.stage == .preparing)
        guard case .running = env.blurAnalysisState else {
            Issue.record("expected sharpness pass running, got \(env.blurAnalysisState)")
            return
        }
        // Repeated taps are idempotent for the active session: starting over would discard
        // in-flight work.
        env.startImageAnalysis()
        guard case .running(let sameProgress) = env.analysisState else {
            Issue.record("expected similarity still running after a repeat tap, got \(env.analysisState)")
            return
        }
        #expect(sameProgress.stage == .preparing)
        env.cancelSimilarityAnalysis()
        env.cancelBlurAnalysis()
    }

    /// Cancelling one pipeline of a unified session never touches the other (M13): the
    /// cancelled surface flips to `.cancelled` while the other stays `.running`. The two
    /// pipelines are independent tasks over one catalog, not a serialized queue.
    @Test func cancellingOnePipelineLeavesTheOtherRunning() {
        let (env, _) = makeEnv()
        env.startImageAnalysis()

        env.cancelSimilarityAnalysis()
        #expect(env.analysisState == .cancelled)
        guard case .running = env.blurAnalysisState else {
            Issue.record("cancelling similarity must not touch the sharpness pass, got \(env.blurAnalysisState)")
            return
        }

        env.cancelBlurAnalysis()
        #expect(env.blurAnalysisState == .cancelled)
    }

    /// The shared worker-width budget counts each heavy pass once and is idempotent per kind
    /// (M13): a duplicate `begin` for the same pass never double-counts, and a duplicate `end`
    /// never drives the count negative. Terminal flips (which call `end`) can therefore fire
    /// freely without corrupting the combined-width calculation.
    @Test func concurrencyBudgetIsIdempotentPerKind() {
        let budget = AnalysisConcurrencyBudget()
        #expect(budget.activePassCount == 0)

        budget.begin(.similarity)
        budget.begin(.similarity) // idempotent — a progress tick must not double-count
        #expect(budget.activePassCount == 1)

        budget.begin(.blur)
        #expect(budget.activePassCount == 2)

        budget.end(.blur)
        budget.end(.blur) // idempotent — a terminal flip may fire more than once
        #expect(budget.activePassCount == 1)

        budget.end(.similarity)
        #expect(budget.activePassCount == 0)
    }

    /// Two concurrent passes split the effective worker width so their combined footprint
    /// never exceeds what one pass used alone (M13). One pass keeps the full thermal width;
    /// two each get half.
    @Test func sharedWidthHalvesTheBudgetAcrossTwoPasses() {
        let policy = ScanConcurrencyPolicy(thermalState: { .nominal })
        #expect(policy.sharedWidth(base: 4, activePasses: 1) == 4)
        #expect(policy.sharedWidth(base: 4, activePasses: 2) == 2)
        #expect(policy.sharedWidth(base: 4, activePasses: 3) == 1) // floor of 1
    }

    // MARK: M13B — deletion → return → reuse review (no forced re-analysis)

    /// The reported regression: analyze, select, delete, return, select again, delete again.
    /// The second review must open READY over the unaffected remaining groups — never
    /// "Review out of date" — and must never require re-running the analysis to get there.
    @Test func deleteReturnSelectDeleteAgainKeepsUnaffectedGroupsReviewable() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, service) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500, "d": 100, "e": 200]),
            outcome: .succeeded(DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])),
            result: DeletionFlowFixtures.threeMemberResult
        )
        // The scan presented its groups; the deterministic default excludes each group's KEEP.
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        #expect(env.selection.selectedIDs == ["b", "d", "e"])

        // Round 1 — mark the exact pair (a, b) and delete it.
        env.mutateSelection {
            $0.toggle("a") // a is the protected keep; mark it explicitly
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        #expect(env.selection.selectedIDs == ["a", "b"])
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("round 1 expected readyForReview, got \(env.deletionState)")
            return
        }
        env.beginConfirmation()
        await env.confirmDeletion()
        #expect(service.callCount == 1)

        // Only the confirmed pair left the result; the near group stands untouched.
        guard case .completed(let afterRound1) = env.analysisState else {
            Issue.record("analysis must stay completed after deletion, got \(env.analysisState)")
            return
        }
        #expect(afterRound1.exactGroups.isEmpty)
        #expect(afterRound1.similarGroups.map(\.memberAssetIDs) == [["c", "d", "e"]])
        env.dismissDeletionResult()
        #expect(env.deletionState == .noSelection)

        // Round 2 — the unaffected group must back a fresh, READY review with no re-analysis.
        env.mutateSelection {
            $0.setSelected(true, forAsset: "d")
            $0.setSelected(true, forAsset: "e")
        }
        #expect(env.selection.selectedIDs == ["d", "e"])
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("round 2 expected readyForReview over the unaffected group, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["d", "e"])
        // Still one recorded deletion — reaching a ready plan required no extra mutation run.
        #expect(service.callCount == 1)

        // The second delete also completes and leaves an (empty) completed scan, never a reset.
        env.beginConfirmation()
        await env.confirmDeletion()
        #expect(service.callCount == 2)
        guard case .completed(let afterRound2) = env.analysisState else {
            Issue.record("analysis must stay completed after the second deletion, got \(env.analysisState)")
            return
        }
        #expect(afterRound2.exactGroups.isEmpty)
        #expect(afterRound2.similarGroups.isEmpty)
        #expect(afterRound2.totalRecordCount == DeletionFlowFixtures.threeMemberResult.totalRecordCount)
    }

    /// A deletion while the *other* pipeline is live (M13) must neither cancel that pass nor
    /// invalidate the similarity result: the unaffected group still backs a READY review and
    /// no re-analysis is forced.
    @Test func deletionWhileTheOtherPipelineRunsKeepsReviewReusableWithoutForcingReanalysis() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, service) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500, "d": 100, "e": 200]),
            outcome: .succeeded(DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        env.mutateSelection {
            $0.toggle("a")
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        #expect(env.selection.selectedIDs == ["a", "b"])

        // Bring the sharpness pass up so an unrelated pipeline is live during the deletion.
        env.startBlurAnalysis()
        guard case .running = env.blurAnalysisState else {
            Issue.record("setup: expected the sharpness pass running, got \(env.blurAnalysisState)")
            return
        }

        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview while the other pipeline runs, got \(env.deletionState)")
            return
        }
        env.beginConfirmation()
        await env.confirmDeletion()
        guard case .succeeded = env.deletionState else {
            Issue.record("expected succeeded, got \(env.deletionState)")
            return
        }
        // The deletion must not cancel or strand the unrelated sharpness pass.
        if case .cancelled = env.blurAnalysisState {
            Issue.record("deletion must not cancel the running sharpness pass")
        }
        // The similarity result stands (pruned in place) with the unaffected group intact.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("similarity must stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.similarGroups.map(\.memberAssetIDs) == [["c", "d", "e"]])

        env.dismissDeletionResult()
        // The review is reusable over the surviving group with no re-analysis.
        env.mutateSelection {
            $0.setSelected(true, forAsset: "d")
            $0.setSelected(true, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("review must be reusable over unaffected results, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["d", "e"])
        env.cancelBlurAnalysis()
    }

    /// A partial removal (some planned IDs survived) lands in `.needsReview`; the surviving
    /// results must stay reviewable and the re-review must reconcile only the removed IDs.
    @Test func partialRemovalKeepsReviewReusableOverTheRemainingResults() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, _) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500]),
            outcome: .succeeded(DeletionSuccess(
                plannedCount: 2,
                verifiedRemovedCount: 1,
                remainingIDs: ["b"] // only a was actually removed
            )),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        env.mutateSelection {
            $0.toggle("a")
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .needsReview = env.deletionState else {
            Issue.record("expected needsReview for a partial removal, got \(env.deletionState)")
            return
        }
        // Only the confirmed removal (a) left the result; b survives inside a now-single
        // member exact group that dissolves, and the near group is untouched.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("analysis must stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.isEmpty) // (a, b) with a gone leaves b alone → dissolves
        #expect(result.similarGroups.map(\.memberAssetIDs) == [["c", "d", "e"]])

        env.dismissDeletionResult()
        env.mutateSelection {
            $0.setSelected(true, forAsset: "d")
            $0.setSelected(true, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("review must stay reusable after a partial removal, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["d", "e"])
    }

    /// Identifiers that vanish between planning and execution are revalidated and refuse the
    /// mutation (`.stale([.assetsMissing])`) — never a silent shrink, never a stranded state —
    /// and the completed results stand so the user can re-review the survivors.
    @Test func planFailsClosedWhenAPlannedAssetWentMissingBeforeDeletion() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, _) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500]),
            // The backing reports b missing at revalidation time.
            outcome: .stale([.assetsMissing(["b"])]),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        env.mutateSelection {
            $0.toggle("a")
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale for a missing asset, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.assetsMissing(["b"])])
        // Nothing was removed: the completed results and the full selection stand.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("analysis must stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.map(\.memberAssetIDs) == [["a", "b"]])
        #expect(result.similarGroups.map(\.memberAssetIDs) == [["c", "d", "e"]])

        // The survivors remain reviewable: dismissing the stale plan and re-preparing over
        // the still-valid group opens a READY review without re-analysis.
        env.dismissDeletionResult()
        env.mutateSelection {
            $0.setSelected(false, forAsset: "a")
            $0.setSelected(false, forAsset: "b")
            $0.setSelected(true, forAsset: "d")
            $0.setSelected(true, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("survivors must stay reviewable, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["d", "e"])
    }

    /// Backing out of the review after a deletion without tapping "Done" leaves the terminal
    /// outcome on the state machine. Re-entering the review with a fresh selection must drop
    /// that leftover and prepare a fresh plan over the preserved results — never show the old
    /// outcome or a stale "Review out of date".
    @Test func reenteringReviewAfterADeletionWithoutDismissingPreparesAFreshPlan() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, _) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500, "d": 100, "e": 200]),
            outcome: .succeeded(DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        env.mutateSelection {
            $0.toggle("a")
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()
        guard case .succeeded = env.deletionState else {
            Issue.record("setup: expected succeeded, got \(env.deletionState)")
            return
        }
        // Deliberately NOT dismissed — the user backed out of the review instead.

        // A fresh selection over the unaffected group, then re-enter the review.
        env.mutateSelection {
            $0.setSelected(true, forAsset: "d")
            $0.setSelected(true, forAsset: "e")
        }
        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("re-entering after a deletion must prepare a fresh plan, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["d", "e"])
        // The plan is stamped over the *preserved* (pruned) result, not the pre-deletion one.
        guard case .completed(let pruned) = env.analysisState else {
            Issue.record("expected the pruned result to stand, got \(env.analysisState)")
            return
        }
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: pruned))
    }

    /// A leftover stale record from an earlier selection change must not stick: re-entering
    /// the review with a valid selection re-prepares over the current results, so the screen
    /// is reusable instead of parking on "Review out of date".
    @Test func reenteringReviewAfterAStaleRecordRepreparesOverTheCurrentResults() async {
        let records = ["a", "b", "c", "d", "e"].map { makeRecord(id: $0) }
        let (env, _) = makeEnv(
            records: records,
            sizeProvider: FakeSizeProvider(sizes: ["b": 500, "d": 100, "e": 200]),
            result: DeletionFlowFixtures.threeMemberResult
        )
        env.selection = PhotoSelectionModel(result: DeletionFlowFixtures.threeMemberResult)
        env.mutateSelection {
            $0.toggle("a")
            $0.setSelected(false, forAsset: "d")
            $0.setSelected(false, forAsset: "e")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("setup: expected readyForReview, got \(env.deletionState)")
            return
        }
        // Back out (Change Selection) and change the marks — the prepared plan goes stale.
        env.mutateSelection {
            $0.setSelected(false, forAsset: "a")
            $0.setSelected(true, forAsset: "d")
        }
        guard case .planStale = env.deletionState else {
            Issue.record("setup: expected the selection change to stale the plan, got \(env.deletionState)")
            return
        }

        // Re-entering re-prepares over the current marks instead of parking on the stale record.
        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("re-entering must re-prepare over the current results, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["b", "d"])
    }

    // MARK: Helpers

    private func makeEnv(
        records: [PhotoAssetRecord] = [makeRecord(id: "a"), makeRecord(id: "b")],
        sizeProvider: FakeSizeProvider = FakeSizeProvider(sizes: ["b": 500]),
        outcome: DeletionOutcome = .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: []
        )),
        result: PhotoAnalysisResult = DeletionFlowFixtures.result,
        snapshotStore: InMemoryScanSnapshotStore = InMemoryScanSnapshotStore(),
        checkpointStore: any ScanCheckpointStore = InMemoryScanCheckpointStore()
    ) -> (env: AppEnvironment, service: RecordingDeletionService) {
        let service = RecordingDeletionService(outcome: outcome)
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            photoPermission: FakePermissionService(.authorized),
            makePhotoLibrary: { FakeLibrary(records: records) },
            sizeProvider: sizeProvider,
            deletionService: service,
            // Completions in this suite must never touch the app's real persisted snapshot.
            scanSnapshotStore: snapshotStore,
            // The M13 unified-session tests actually start analyses, which claim checkpoint
            // channels; keep those writes in memory, never in the app's real support dir.
            checkpointStore: checkpointStore,
            sessionToken: "session-1"
        )
        env.photoPermissionState = .authorized
        env.catalogState = .completed(CatalogScanResult(
            records: records,
            libraryAssetCount: records.count,
            accessLevel: .authorized
        ))
        env.analysisState = .completed(result)
        return (env, service)
    }

    /// `a` is the recommended keep (unselected by default); toggling marks both members.
    private func selectBoth(in env: AppEnvironment) {
        env.selection = PhotoSelectionModel(groups: [DeletionFlowFixtures.group])
        env.selection.toggle("a")
        precondition(env.selection.selectedCount == 2)
    }

    private func waitForPlanReady(
        _ env: AppEnvironment,
        timeoutMilliseconds: Int = 5_000
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while env.deletionState.isBuildingPlan, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePlan(ids: [String]) -> DeletionPlan {
        DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: ids.sorted().map {
                DeletionPlanItem(localIdentifier: $0, mediaType: .image, sizeInBytes: 1, category: .exactDuplicates)
            },
            authorization: .authorized,
            sessionToken: "session-1",
            analysisSignature: DeletionPlanner.analysisSignature(for: DeletionFlowFixtures.result)
        )
    }
}

// MARK: - Fixtures

private enum DeletionFlowFixtures {
    static let group = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["a", "b"],
        evidence: .exactContent(fingerprint: "f", byteLength: 100),
        recommendedBestAssetID: "a",
        memberScores: [:]
    )

    static let result = PhotoAnalysisResult(
        exactGroups: [group],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 2,
        candidateBucketCount: 1,
        candidatePairCount: 1
    )

    static let threeMemberGroup = PhotoSimilarityGroup(
        kind: .nearDuplicates,
        memberAssetIDs: ["c", "d", "e"],
        evidence: .visualSimilarity(minDistance: 0.1, maxDistance: 0.4, threshold: 0.6),
        recommendedBestAssetID: "c",
        memberScores: [:]
    )

    static let threeMemberResult = PhotoAnalysisResult(
        exactGroups: [group],
        similarGroups: [threeMemberGroup],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: 0.6,
        totalRecordCount: 5,
        candidateBucketCount: 2,
        candidatePairCount: 4
    )
}

private struct FakeSizeProvider: AssetSizeProviding {
    let sizes: [String: Int64]

    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        sizes.filter { localIdentifiers.contains($0.key) }
    }
}

private final class FakePermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PermissionState
    private var reads = 0

    init(_ state: PermissionState) {
        self.state = state
    }

    func currentStatus() -> PermissionState {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return state
    }

    func requestAccess() async -> PermissionState {
        currentStatus()
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

private final class RecordingDeletionService: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private let scriptedOutcome: DeletionOutcome
    private var calls = 0
    private var context: PlanExecutionContext?
    private var planCount: Int?

    init(outcome: DeletionOutcome) {
        scriptedOutcome = outcome
    }

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        recordCall(confirmed: confirmed, context: context)
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func recordCall(
        confirmed: ConfirmedDeletionPlan,
        context: PlanExecutionContext
    ) -> DeletionOutcome {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        self.context = context
        planCount = confirmed.plan.count
        return scriptedOutcome
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var lastContext: PlanExecutionContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    var lastPlanCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return planCount
    }
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
