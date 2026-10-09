import Foundation
import Testing
@testable import Netto

// MARK: - M5A: the Space Freed Summary

/// What the summary counts, what it refuses to show, and proof that presenting it never
/// disturbs the deletion pipeline, the persisted scan snapshot, or the shared selection.
///
/// Every scenario runs against deterministic fixtures and fakes: the scripted deletion
/// service, an in-memory snapshot store, and fixed sizes. No real photo library, no real
/// contacts store, no network.
@MainActor
struct SpaceFreedSummaryTests {
    // MARK: 1. Full success — accurate count and size

    @Test func fullSuccessShowsTheAccurateCountAndMeasuredSize() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let (env, service, _) = makeEnv(outcome: .succeeded(success))

        // Nothing may exist before the operation has even been confirmed — success is never
        // displayed ahead of the deletion completing.
        #expect(env.spaceFreedSummary == nil)
        #expect(env.flowState != .deletionCompleted)

        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(service.callCount == 1)
        #expect(env.flowState == .deletionCompleted)
        guard let summary = env.spaceFreedSummary else {
            Issue.record("expected a space-freed summary after full success")
            return
        }
        #expect(summary.confirmedCount == 2)
        #expect(summary.confirmedCount == success.verifiedRemovedCount)
        #expect(summary.measuredBytes == 3_000)
        #expect(summary.measuredCount == 2)
        #expect(summary.unresolvedCount == 0)
        #expect(summary.isByteFigureComplete)
        #expect(!summary.isPartial)
        #expect(summary.breakdown == [
            SpaceFreedSummary.CategoryCount(category: .exactDuplicates, count: 2)
        ])
        // The screen's figures are exactly this data, honestly labeled.
        #expect(SpaceFreedSummaryPresentation.metricValue(summary) == ByteFormat.string(3_000))
        #expect(SpaceFreedSummaryPresentation.metricLabel(summary) == "Estimated space freed")
        #expect(SpaceFreedSummaryPresentation.itemsRemovedLine(summary) == "2 items removed")
        #expect(SpaceFreedSummaryPresentation.failureDisclosure(summary) == nil)
        #expect(SpaceFreedSummaryPresentation.sizeNote(summary) == nil)
    }

    // MARK: 2. Partial success — only confirmed deletions

    @Test func partialSuccessCountsOnlyConfirmedDeletions() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 1, remainingIDs: ["b"])
        let (env, _, _) = makeEnv(outcome: .succeeded(success))

        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .needsReview(success))
        #expect(env.flowState == .deletionCompleted)
        guard let summary = env.spaceFreedSummary else {
            Issue.record("expected a summary for a partial success with one confirmed removal")
            return
        }
        // Only `a` was verified removed: `b` contributes nothing to any count or figure.
        #expect(summary.confirmedCount == 1)
        #expect(summary.measuredBytes == 1_000)
        #expect(summary.measuredCount == 1)
        #expect(summary.notRemovedCount == 1)
        #expect(summary.isPartial)
        #expect(summary.breakdown == [
            SpaceFreedSummary.CategoryCount(category: .exactDuplicates, count: 1)
        ])
        #expect(SpaceFreedSummaryPresentation.failureDisclosure(summary) == "1 item could not be removed.")
        #expect(SpaceFreedSummaryPresentation.itemsRemovedLine(summary) == "1 item removed")
    }

    // MARK: 3. Failed / cancelled deletion is never reported as success

    @Test func failedDeletionNeverShowsASuccessSummary() async {
        let (env, service, store) = makeEnv(outcome: .mutationFailed("boom"))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(service.callCount == 1)
        #expect(env.spaceFreedSummary == nil)
        #expect(env.flowState != .deletionCompleted)
        guard case .failed = env.deletionState else {
            Issue.record("expected the existing failure flow, got \(env.deletionState)")
            return
        }
        // Nothing was confirmed removed: results stand untouched and no snapshot write happened.
        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.count == 1)
        #expect(store.saveCount == 0)

        // Cancellation keeps its existing retry flow and never presents success either.
        let (cancelledEnv, cancelledService, _) = makeEnv(outcome: .cancelled)
        selectBoth(in: cancelledEnv)
        cancelledEnv.prepareDeletionPlan()
        await waitForPlanReady(cancelledEnv)
        cancelledEnv.beginConfirmation()
        await cancelledEnv.confirmDeletion()

        #expect(cancelledService.callCount == 1)
        #expect(cancelledEnv.spaceFreedSummary == nil)
        #expect(cancelledEnv.flowState != .deletionCompleted)
        guard case .readyForReview = cancelledEnv.deletionState else {
            Issue.record("expected the existing cancellation flow, got \(cancelledEnv.deletionState)")
            return
        }
    }

    // MARK: 4. Zero confirmed deletions — no success summary

    @Test func zeroConfirmedDeletionsNeverShowASuccessSummary() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 0, remainingIDs: ["a", "b"])
        let (env, _, _) = makeEnv(outcome: .succeeded(success))

        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .needsReview(success))
        #expect(env.spaceFreedSummary == nil)
        #expect(env.flowState != .deletionCompleted)

        // The gate is the builder itself: with zero confirmed removals no summary can exist.
        let plan = makePlan(items: [
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: nil, category: nil),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: nil, category: nil)
        ])
        #expect(SpaceFreedSummary(plan: plan, success: success) == nil)
    }

    // MARK: 5. Unknown size — represented honestly, never fabricated

    @Test func unknownSizeIsShownAsItemCountWithoutAFabricatedEstimate() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let (env, _, _) = makeEnv(
            sizeProvider: FakeSizeProvider(sizes: [:]),
            outcome: .succeeded(success)
        )
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard let summary = env.spaceFreedSummary else {
            Issue.record("expected a summary even when no size was measurable")
            return
        }
        #expect(summary.confirmedCount == 2)
        #expect(!summary.hasSpaceFigure)
        #expect(summary.measuredCount == 0)
        #expect(summary.measuredBytes == 0)
        #expect(summary.unresolvedCount == 2)

        // The verified count stands alone: no byte unit, no invented amount.
        #expect(SpaceFreedSummaryPresentation.metricValue(summary) == "2")
        #expect(SpaceFreedSummaryPresentation.metricLabel(summary) == "Items removed")
        #expect(SpaceFreedSummaryPresentation.itemsRemovedLine(summary) == nil)
        #expect(!SpaceFreedSummaryPresentation.metricValue(summary).contains("GB"))
        #expect(!SpaceFreedSummaryPresentation.metricValue(summary).contains("MB"))
        #expect(SpaceFreedSummaryPresentation.sizeNote(summary) == SpaceFreedSummaryPresentation.unknownSizeNote)
        #expect(SpaceFreedSummaryPresentation.sizeNote(summary)?.contains("no space estimate") == true)

        // Partial measurement: the figure exists, explicitly marked a lower bound.
        let plan = makePlan(items: [
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: 1_000, category: nil),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: nil, category: nil)
        ])
        guard let lowerBound = SpaceFreedSummary(plan: plan, success: success) else {
            Issue.record("expected a summary for a partially measured plan")
            return
        }
        #expect(lowerBound.hasSpaceFigure)
        #expect(!lowerBound.isByteFigureComplete)
        #expect(lowerBound.measuredBytes == 1_000)
        #expect(lowerBound.unresolvedCount == 1)
        #expect(SpaceFreedSummaryPresentation.metricLabel(lowerBound) == "Estimated space freed")
        #expect(SpaceFreedSummaryPresentation.sizeNote(lowerBound)?.contains("lower bound") == true)
    }

    // MARK: 6. Duplicate assets are never double-counted

    @Test func duplicateAssetsAreNeverDoubleCounted() {
        let plan = makePlan(items: [
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: 1_000, category: .exactDuplicates),
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: 1_000, category: .exactDuplicates),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: 2_000, category: .nearDuplicates)
        ])
        let success = DeletionSuccess(plannedCount: 3, verifiedRemovedCount: 3, remainingIDs: [])
        guard let summary = SpaceFreedSummary(plan: plan, success: success) else {
            Issue.record("expected a summary for a plan with repeated entries")
            return
        }
        // Three plan entries, two assets: `a` counts once for the total, the bytes, and its bucket.
        #expect(summary.confirmedCount == 2)
        #expect(summary.measuredBytes == 3_000)
        #expect(summary.measuredCount == 2)
        #expect(summary.breakdown == [
            SpaceFreedSummary.CategoryCount(category: .exactDuplicates, count: 1),
            SpaceFreedSummary.CategoryCount(category: .similarPhotos, count: 1)
        ])
        #expect(summary.breakdown.reduce(0) { $0 + $1.count } == summary.confirmedCount)

        // Repeated surviving identifiers de-duplicate the subtraction as well.
        let pair = makePlan(items: [
            DeletionPlanItem(localIdentifier: "a", mediaType: .image, sizeInBytes: 1_000, category: .exactDuplicates),
            DeletionPlanItem(localIdentifier: "b", mediaType: .image, sizeInBytes: 2_000, category: .exactDuplicates)
        ])
        let surviving = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 1, remainingIDs: ["b", "b"])
        guard let partial = SpaceFreedSummary(plan: pair, success: surviving) else {
            Issue.record("expected a summary when only `a` was removed")
            return
        }
        #expect(partial.confirmedCount == 1)
        #expect(partial.notRemovedCount == 1)
        #expect(partial.measuredBytes == 1_000)
    }

    // MARK: 7. Dismissal returns to the dashboard

    @Test func dismissingTheSummaryReturnsToTheDashboardWithoutTouchingResults() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let (env, service, store) = makeEnv(outcome: .succeeded(success))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard env.spaceFreedSummary != nil else {
            Issue.record("expected the summary before dismissal")
            return
        }
        #expect(env.flowState == .deletionCompleted)
        let savesAfterDeletion = store.saveCount

        env.finishSpaceFreedSummary()

        #expect(env.flowState == .dashboard)
        #expect(env.spaceFreedSummary == nil)
        #expect(env.deletionState == .noSelection)
        // The pruned results, the emptied selection, and the snapshot stand exactly as the
        // deletion left them — dismissal writes nothing and starts nothing.
        guard case .completed(let pruned) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(pruned.exactGroups.isEmpty)
        #expect(env.selection.selectedCount == 0)
        #expect(store.saveCount == savesAfterDeletion)
        #expect(service.callCount == 1)
        #expect(env.analysisState.isRunning == false)

        // Repeated taps are harmless no-ops.
        env.finishSpaceFreedSummary()
        env.finishSpaceFreedSummary()
        #expect(env.flowState == .dashboard)
        #expect(env.spaceFreedSummary == nil)
        #expect(env.deletionState == .noSelection)
        #expect(store.saveCount == savesAfterDeletion)
        #expect(service.callCount == 1)
    }

    // MARK: 8. Recreating the screen repeats nothing

    @Test func recreatingTheSummaryNeverRepeatsDeletionOrTheSuccessEvent() async {
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let (env, service, store) = makeEnv(outcome: .succeeded(success))
        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard let presented = env.spaceFreedSummary else {
            Issue.record("expected the summary before recreation")
            return
        }
        let saves = store.saveCount

        // Tear the screen down and rebuild it (backgrounding, re-navigation): the view layer
        // holds no state of consequence, so only the presentation pair churns.
        env.flowState = .dashboard
        env.flowState = .deletionCompleted

        #expect(env.spaceFreedSummary == presented)
        #expect(service.callCount == 1)
        #expect(store.saveCount == saves)
        #expect(env.deletionState == .succeeded(success))
        guard case .completed(let result) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        #expect(result.exactGroups.isEmpty)
        #expect(result.totalRecordCount == SummaryFixtures.result.totalRecordCount)

        // A later destructive operation cannot start from the summary state either.
        env.beginConfirmation()
        #expect(service.callCount == 1)
        #expect(env.deletionState == .succeeded(success))
        #expect(env.spaceFreedSummary == presented)
    }

    // MARK: 9. Scan-result persistence and selection remain intact

    @Test func scanResultPersistenceAndSelectionRemainIntactAlongsideTheSummary() async {
        let store = InMemoryScanSnapshotStore()
        let completedAt = Date(timeIntervalSince1970: 1_758_999_000)
        try? store.save(ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: "original-scan",
            completedAt: completedAt,
            result: SummaryFixtures.result
        ))
        let success = DeletionSuccess(plannedCount: 2, verifiedRemovedCount: 2, remainingIDs: [])
        let (env, _, _) = makeEnv(outcome: .succeeded(success), snapshotStore: store)

        selectBoth(in: env)
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        env.beginConfirmation()
        await env.confirmDeletion()

        guard env.spaceFreedSummary != nil else {
            Issue.record("expected the summary alongside the persisted result")
            return
        }
        guard case .completed(let updated) = env.analysisState else {
            Issue.record("expected the analysis to stay completed, got \(env.analysisState)")
            return
        }
        guard let persisted = store.loadLatest() else {
            Issue.record("expected the updated snapshot to persist")
            return
        }
        // M4I behavior is unchanged: same scan identity, pruned result, one write — the
        // summary added none of its own.
        #expect(persisted.scanID == "original-scan")
        #expect(persisted.completedAt == completedAt)
        #expect(persisted.result == updated)
        #expect(persisted.result.exactGroups.isEmpty)
        #expect(store.saveCount == 2)
        #expect(env.lastScanCompletedAt == completedAt)
        #expect(env.selection.selectedCount == 0)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.isEmpty)
        #expect(env.storageSnapshot != nil)
    }

    // MARK: - Harness

    private func makeEnv(
        records: [PhotoAssetRecord] = [makeRecord(id: "a"), makeRecord(id: "b")],
        sizeProvider: FakeSizeProvider = FakeSizeProvider(sizes: ["a": 1_000, "b": 2_000]),
        outcome: DeletionOutcome = .succeeded(DeletionSuccess(
            plannedCount: 2,
            verifiedRemovedCount: 2,
            remainingIDs: []
        )),
        snapshotStore: InMemoryScanSnapshotStore = InMemoryScanSnapshotStore()
    ) -> (env: AppEnvironment, service: RecordingDeletionService, store: InMemoryScanSnapshotStore) {
        let service = RecordingDeletionService(outcome: outcome)
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            photoPermission: FakePermissionService(.authorized),
            makePhotoLibrary: { FakeLibrary(records: records) },
            sizeProvider: sizeProvider,
            deletionService: service,
            scanSnapshotStore: snapshotStore,
            sessionToken: "session-1"
        )
        env.photoPermissionState = .authorized
        env.catalogState = .completed(CatalogScanResult(
            records: records,
            libraryAssetCount: records.count,
            accessLevel: .authorized
        ))
        env.analysisState = .completed(SummaryFixtures.result)
        return (env, service, snapshotStore)
    }

    /// `a` is the recommended keep (unselected by default); toggling marks both members.
    private func selectBoth(in env: AppEnvironment) {
        env.selection = PhotoSelectionModel(groups: [SummaryFixtures.group])
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

    private func makePlan(items: [DeletionPlanItem]) -> DeletionPlan {
        DeletionPlan(
            schemaVersion: DeletionPlan.currentVersion,
            items: items,
            authorization: .authorized,
            sessionToken: "session-1",
            analysisSignature: DeletionPlanner.analysisSignature(for: SummaryFixtures.result)
        )
    }
}

// MARK: - Fixtures

private enum SummaryFixtures {
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

    init(outcome: DeletionOutcome) {
        scriptedOutcome = outcome
    }

    func execute(
        _ confirmed: ConfirmedDeletionPlan,
        in context: PlanExecutionContext
    ) async -> DeletionOutcome {
        _ = confirmed
        _ = context
        return recordCall()
    }

    // Synchronous so `NSLock` (unavailable in async contexts) can be used safely.
    private func recordCall() -> DeletionOutcome {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return scriptedOutcome
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
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
