import Foundation
import Testing
@testable import Netto

// MARK: - AppEnvironment screenshot deletion orchestration
//
// Screenshots are a filter over the catalog: every test here runs with `analysisState`
// `.notStarted` unless the test explicitly needs a similar-photos plan, proving the feature
// never waits on — or is invalidated by — similarity analysis.

@MainActor
struct ScreenshotsFlowTests {
    // MARK: Plan preparation

    @Test func screenshotsPrepareWorksWithoutCompletedAnalysis() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 2)
        #expect(plan.selectionSnapshot == ["shot-01", "shot-02"])
        // Screenshot plans carry no duplicate-group category — the review labels them "items".
        #expect(plan.items.allSatisfy { $0.category == nil })
        #expect(
            plan.analysisSignature == ScreenshotDataset.signature(in: ScreenshotsFixture.completed)
        )
        #expect(plan.sessionToken == "session-1")
    }

    @Test func similarPhotosPrepareStillRequiresCompletedAnalysis() {
        let env = makeScreenshotEnv().env
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        precondition(env.selection.selectedCount > 0)

        env.prepareDeletionPlan(from: .similarPhotos)

        guard case .failed = env.deletionState else {
            Issue.record("expected failed without analysis, got \(env.deletionState)")
            return
        }
    }

    @Test func emptyScreenshotSelectionNeverLeavesNoSelection() {
        let env = makeScreenshotEnv().env
        env.prepareDeletionPlan(from: .screenshots)
        #expect(env.deletionState == .noSelection)
    }

    @Test func prepareFailsCleanlyWithoutCompletedCatalog() {
        let env = makeScreenshotEnv().env
        selectScreenshots(["shot-01"], in: env)
        env.catalogState = .notStarted
        env.prepareDeletionPlan(from: .screenshots)

        guard case .failed = env.deletionState else {
            Issue.record("expected failed without catalog, got \(env.deletionState)")
            return
        }
    }

    @Test func selectAllCoversExactlyTheScreenshotDataset() {
        let env = makeScreenshotEnv().env
        env.screenshotSelection.selectAll()

        #expect(env.screenshotSelection.selectedCount == 6)
        #expect(env.screenshotSelection.datasetCount == 6)
        // The catalog itself is bigger — screenshots are a subset, not the whole library.
        #expect(env.screenshotSelection.selectedCount < ScreenshotsFixture.records.count)
        #expect(env.screenshotSelection.isAllSelected)
    }

    @Test func planContainsExactlyTheSelectionInDeterministicOrder() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-03", "shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.items.map(\.localIdentifier) == ["shot-01", "shot-03"])
        #expect(plan.schemaVersion == DeletionPlan.currentVersion)
    }

    @Test func partialAndMissingSizesStayUnresolvedNeverZero() async {
        let (env, _) = makeScreenshotEnv(sizeProvider: FakeSizeProvider(sizes: ["shot-01": 500]))
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        let measured = Dictionary(
            plan.items.compactMap { item in item.sizeInBytes.map { (item.localIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let unresolvedIDs = plan.items.filter { $0.sizeInBytes == nil }.map(\.localIdentifier)
        #expect(measured["shot-01"] == 500)
        #expect(unresolvedIDs == ["shot-02"])
        #expect(plan.sizeSummary.unresolvedCount == 1)
        #expect(!plan.sizeSummary.isExact)

        // Nothing measured at all → fully unresolved, never "0 bytes".
        let (unresolvedEnv, _) = makeScreenshotEnv(sizeProvider: FakeSizeProvider(sizes: [:]))
        selectScreenshots(["shot-01"], in: unresolvedEnv)
        unresolvedEnv.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(unresolvedEnv)
        guard case .readyForReview(let unresolvedPlan) = unresolvedEnv.deletionState else {
            Issue.record("expected readyForReview, got \(unresolvedEnv.deletionState)")
            return
        }
        #expect(unresolvedPlan.sizeSummary.isFullyUnresolved)
        #expect(unresolvedPlan.sizeSummary.measuredBytes == 0)
    }

    // MARK: Selection → staleness (source-gated)

    @Test func screenshotSelectionChangeMakesScreenshotPlanStale() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        env.mutateScreenshotSelection { $0.toggle("shot-03") }

        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    @Test func similarSelectionChangeDoesNotStaleScreenshotPlan() async {
        let (env, _) = makeScreenshotEnv(analysis: .completed(Fixtures.analysisResult))
        selectScreenshots(["shot-01"], in: env)
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        // The similar-photos selection actually changes (the recommended keep is not selected
        // by default, so toggling it adds it)…
        #expect(!env.selection.selectedIDs.contains("photo-01"))
        env.mutateSelection { $0.toggle("photo-01") }
        #expect(env.selection.selectedIDs.contains("photo-01"))

        // …but only the *similar-photos* plan would care; the screenshot plan is untouched.
        guard case .readyForReview = env.deletionState else {
            Issue.record("screenshot plan was staled by a similar-photos mutation, got \(env.deletionState)")
            return
        }
    }

    @Test func screenshotSelectionChangeDoesNotStaleSimilarPlan() async {
        let (env, _) = makeScreenshotEnv(analysis: .completed(Fixtures.analysisResult))
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        env.selection.toggle("photo-02")
        env.prepareDeletionPlan(from: .similarPhotos)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateScreenshotSelection { $0.toggle("shot-01") }

        guard case .readyForReview = env.deletionState else {
            Issue.record("similar plan was staled by a screenshot mutation, got \(env.deletionState)")
            return
        }
    }

    // MARK: Cross-source review entry

    @Test func screenshotsReviewDropsASimilarPhotosPlanAndPreparesItsOwn() async {
        let (env, _) = makeScreenshotEnv(analysis: .completed(Fixtures.analysisResult))
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        env.selection.toggle("photo-02")
        env.prepareDeletionPlan(from: .similarPhotos)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected a ready similar-photos plan, got \(env.deletionState)")
            return
        }

        // The user leaves that review and opens the screenshots review: the foreign plan must
        // never be shown or confirmed under this screen.
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.reviewDidAppear(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready screenshot plan, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["shot-01", "shot-02"])
        #expect(plan.analysisSignature == ScreenshotDataset.signature(in: ScreenshotsFixture.completed))
    }

    @Test func similarPhotosReviewDropsAScreenshotPlan() async {
        let (env, _) = makeScreenshotEnv(analysis: .completed(Fixtures.analysisResult))
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        env.selection.toggle("photo-02")
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected a ready screenshot plan, got \(env.deletionState)")
            return
        }

        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready similar-photos plan, got \(env.deletionState)")
            return
        }
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: Fixtures.analysisResult))
        #expect(plan.selectionSnapshot != ["shot-01"])
    }

    @Test func screenshotsReviewKeepsItsOwnReadyPlan() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview(let before) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        // Re-entering the same source's review must not rebuild or drop the live plan.
        env.reviewDidAppear(from: .screenshots)

        guard case .readyForReview(let after) = env.deletionState else {
            Issue.record("same-source review dropped the plan, got \(env.deletionState)")
            return
        }
        #expect(after.selectionSnapshot == before.selectionSnapshot)
        #expect(after.analysisSignature == before.analysisSignature)
    }

    @Test func foreignReviewAppearDiscardsAnInFlightBuild() async {
        let (env, _) = makeScreenshotEnv(analysis: .completed(Fixtures.analysisResult))
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        env.selection.toggle("photo-02")
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots) // still building when the other review opens

        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        // The discarded screenshot build must never land on the similar-photos review.
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready similar-photos plan, got \(env.deletionState)")
            return
        }
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: Fixtures.analysisResult))
        #expect(plan.selectionSnapshot != ["shot-01"])
    }

    // MARK: Dataset invalidation

    @Test func datasetChangeDroppingASelectedScreenshotInvalidatesSelectionAndPlan() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        // The library changed: shot-02 no longer exists in a rebuilt catalog.
        let rebuilt = CatalogScanResult(
            records: ScreenshotsFixture.records.filter { $0.localIdentifier != "shot-02" },
            libraryAssetCount: ScreenshotsFixture.records.count - 1,
            accessLevel: .authorized
        )
        env.catalogState = .completed(rebuilt)
        env.synchronizeScreenshotDataset()

        #expect(env.screenshotSelection.selectedIDs == ["shot-01"])
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    @Test func datasetChangeOutsideTheSelectionStalesBySignatureNotSelection() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        // The library grew a screenshot the user never touched: selection identical,
        // dataset fingerprint different.
        let grew = CatalogScanResult(
            records: ScreenshotsFixture.records + [Fixtures.extraScreenshot],
            libraryAssetCount: ScreenshotsFixture.records.count + 1,
            accessLevel: .authorized
        )
        env.catalogState = .completed(grew)
        env.synchronizeScreenshotDataset()

        #expect(env.screenshotSelection.selectedIDs == ["shot-01"])
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.analysisChanged])
    }

    @Test func catalogGoneResetsTheScreenshotSelection() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)

        env.catalogState = .notStarted
        env.synchronizeScreenshotDataset()

        #expect(env.screenshotSelection.datasetIDs.isEmpty)
        #expect(env.screenshotSelection.selectedIDs.isEmpty)
    }

    // MARK: Confirmation gating

    @Test func confirmWithoutConfirmationNeverReachesTheService() async {
        let (env, service) = makeScreenshotEnv()
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        await env.confirmDeletion()
        #expect(service.callCount == 0)

        env.beginConfirmation()
        env.cancelConfirmation()
        await env.confirmDeletion()
        #expect(service.callCount == 0)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview after cancel, got \(env.deletionState)")
            return
        }
    }

    @Test func confirmedDeletionExecutesWithScreenshotDatasetContext() async {
        let (env, service) = makeScreenshotEnv()
        selectScreenshots(["shot-01", "shot-02"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(service.callCount == 1)
        #expect(service.lastPlanCount == 2)
        guard let context = service.lastContext else {
            Issue.record("expected the service to receive a plan context")
            return
        }
        #expect(context.selectionIDs == ["shot-01", "shot-02"])
        #expect(context.sessionToken == "session-1")
        #expect(
            context.analysisSignature == ScreenshotDataset.signature(in: ScreenshotsFixture.completed)
        )
        guard case .succeeded = env.deletionState else {
            Issue.record("expected succeeded, got \(env.deletionState)")
            return
        }
    }

    @Test func deletionSuccessResetsScreenshotSelectionAndCatalog() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        env.beginConfirmation()
        await env.confirmDeletion()

        // The library changed: every dataset-derived fact is dropped.
        #expect(env.screenshotSelection.datasetIDs.isEmpty)
        #expect(env.screenshotSelection.selectedIDs.isEmpty)
        #expect(env.catalogState == .notStarted)
        #expect(env.analysisState == .notStarted)
    }

    // MARK: Superseded builds

    @Test func startingAnalysisDiscardsAnInFlightScreenshotPlanBuild() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        // Bumps the plan-build generation before the async build can write its result.
        env.startSimilarityAnalysis()

        try? await Task.sleep(for: .milliseconds(150))

        #expect(env.deletionState == .noSelection)
    }

    @Test func staleScreenshotPlanCanBeRepreparedFromTheStaleState() async {
        let (env, _) = makeScreenshotEnv()
        selectScreenshots(["shot-01"], in: env)
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        env.mutateScreenshotSelection { $0.toggle("shot-02") }
        guard case .planStale = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }

        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview after re-prepare, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["shot-01", "shot-02"])
    }
}

// MARK: - Fixtures

private enum Fixtures {
    /// An exact-duplicate group over two *photos* (not screenshots), for source-gating tests.
    static let photoGroup = PhotoSimilarityGroup(
        kind: .exactDuplicates,
        memberAssetIDs: ["photo-01", "photo-02"],
        evidence: .exactContent(fingerprint: "f", byteLength: 100),
        recommendedBestAssetID: "photo-01",
        memberScores: [:]
    )

    static let analysisResult = PhotoAnalysisResult(
        exactGroups: [photoGroup],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: ScreenshotsFixture.records.count,
        candidateBucketCount: 1,
        candidatePairCount: 1
    )

    /// A screenshot not present in `ScreenshotsFixture` — used to grow the dataset.
    static let extraScreenshot = PhotoAssetRecord(
        localIdentifier: "shot-99",
        mediaType: .image,
        mediaSubtypes: [.screenshot],
        pixelWidth: 1290,
        pixelHeight: 2796,
        creationDate: Date(timeIntervalSince1970: 1_760_000_000),
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

@MainActor
private func makeScreenshotEnv(
    analysis: PhotoAnalysisState = .notStarted,
    sizeProvider: FakeSizeProvider = FakeSizeProvider(sizes: ["shot-01": 500, "shot-02": 400]),
    outcome: DeletionOutcome = .succeeded(DeletionSuccess(
        plannedCount: 2,
        verifiedRemovedCount: 2,
        remainingIDs: []
    ))
) -> (env: AppEnvironment, service: RecordingDeletionService) {
    let service = RecordingDeletionService(outcome: outcome)
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        makePhotoLibrary: { FakeLibrary(records: ScreenshotsFixture.records) },
        sizeProvider: sizeProvider,
        deletionService: service,
        sessionToken: "session-1"
    )
    env.photoPermissionState = .authorized
    env.catalogState = .completed(ScreenshotsFixture.completed)
    env.analysisState = analysis
    // Tests set `catalogState` directly (bypassing the catalog-build writer), so reconcile the
    // screenshot dataset exactly as the real completion path would.
    env.synchronizeScreenshotDataset()
    precondition(env.screenshotSelection.datasetCount == ScreenshotsFixture.screenshots.count)
    return (env, service)
}

@MainActor
private func selectScreenshots(_ ids: [String], in env: AppEnvironment) {
    env.mutateScreenshotSelection { selection in
        for id in ids {
            selection.toggle(id)
        }
    }
    precondition(env.screenshotSelection.selectedCount == ids.count)
}

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

// MARK: - Test doubles

private struct FakeSizeProvider: AssetSizeProviding {
    let sizes: [String: Int64]

    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        sizes.filter { localIdentifiers.contains($0.key) }
    }
}

private final class FakePermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PermissionState

    init(_ state: PermissionState) {
        self.state = state
    }

    func currentStatus() -> PermissionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func requestAccess() async -> PermissionState {
        currentStatus()
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

    /// Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
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
