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

    @Test func prepareFailsCleanlyWithoutCompletedInputs() async {
        let (env, _) = makeEnv()
        selectBoth(in: env)
        env.analysisState = .notStarted
        env.prepareDeletionPlan()
        guard case .failed = env.deletionState else {
            Issue.record("expected failed without analysis, got \(env.deletionState)")
            return
        }

        let (second, _) = makeEnv()
        selectBoth(in: second)
        second.catalogState = .notStarted
        second.prepareDeletionPlan()
        guard case .failed = second.deletionState else {
            Issue.record("expected failed without catalog, got \(second.deletionState)")
            return
        }
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

    @Test func successfulDeletionResetsLibraryStateAndRefreshesStorage() async {
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
        #expect(env.selection.selectedCount == 0)
        #expect(env.analysisState == .notStarted)
        #expect(env.catalogState == .notStarted)
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
        // Even a partial result changed Photos: the dataset is still invalidated.
        #expect(env.analysisState == .notStarted)
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

    // MARK: Helpers

    private func makeEnv(
        sizeProvider: FakeSizeProvider = FakeSizeProvider(sizes: ["b": 500]),
        outcome: DeletionOutcome = .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: []
        ))
    ) -> (env: AppEnvironment, service: RecordingDeletionService) {
        let records = [makeRecord(id: "a"), makeRecord(id: "b")]
        let service = RecordingDeletionService(outcome: outcome)
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            photoPermission: FakePermissionService(.authorized),
            makePhotoLibrary: { FakeLibrary(records: records) },
            sizeProvider: sizeProvider,
            deletionService: service,
            sessionToken: "session-1"
        )
        env.photoPermissionState = .authorized
        env.catalogState = .completed(CatalogScanResult(
            records: records,
            libraryAssetCount: records.count,
            accessLevel: .authorized
        ))
        env.analysisState = .completed(DeletionFlowFixtures.result)
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
