import Foundation
import Testing
@testable import Netto

// MARK: - AppEnvironment large-videos orchestration
//
// Videos are a media-type filter over the catalog: every plan test here runs with
// `analysisState` `.notStarted`, proving the feature never waits on — or is invalidated by —
// similarity analysis. Size *measurement* for the list is separate from size *resolution* at
// plan time: measurement is read-only orchestration with its own generation guard, plan sizes
// are resolved fresh for the reviewed subset through the same `AssetSizeProviding` seam.

@MainActor
struct VideosFlowTests {
    // MARK: Plan preparation

    @Test func videosPrepareWorksWithoutCompletedAnalysis() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01", "video-02"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 2)
        #expect(plan.selectionSnapshot == ["video-01", "video-02"])
        #expect(plan.items.allSatisfy { $0.category == nil })
        #expect(plan.items.allSatisfy { $0.mediaType == .video })
        #expect(plan.analysisSignature == VideoDataset.signature(in: VideosFixture.completed))
        #expect(plan.sessionToken == "session-1")
    }

    @Test func emptyVideoSelectionNeverLeavesNoSelection() {
        let env = makeVideoEnv().env
        env.prepareDeletionPlan(from: .videos)
        #expect(env.deletionState == .noSelection)
    }

    @Test func prepareFailsCleanlyWithoutCompletedCatalog() {
        let env = makeVideoEnv().env
        selectVideos(["video-01"], in: env)
        env.catalogState = .notStarted
        env.prepareDeletionPlan(from: .videos)

        guard case .failed = env.deletionState else {
            Issue.record("expected failed without catalog, got \(env.deletionState)")
            return
        }
    }

    @Test func selectAllCoversExactlyTheVideoDataset() {
        let env = makeVideoEnv().env
        env.videoSelection.selectAll()

        #expect(env.videoSelection.selectedCount == VideosFixture.videos.count)
        #expect(env.videoSelection.datasetCount == VideosFixture.videos.count)
        // The catalog itself is bigger — videos are a subset, not the whole library.
        #expect(env.videoSelection.selectedCount < VideosFixture.records.count)
        #expect(env.videoSelection.isAllSelected)
    }

    @Test func togglingNonVideoIdentifiersIsIgnored() {
        let env = makeVideoEnv().env
        env.videoSelection.toggle("photo-01")
        env.videoSelection.toggle("shot-01")
        #expect(env.videoSelection.selectedCount == 0)

        env.videoSelection.toggle("video-01")
        #expect(env.videoSelection.selectedIDs == ["video-01"])
    }

    @Test func planContainsExactlyTheSelectionInDeterministicOrder() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-05", "video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.items.map(\.localIdentifier) == ["video-01", "video-05"])
        #expect(plan.schemaVersion == DeletionPlan.currentVersion)
    }

    @Test func partialAndMissingSizesStayUnresolvedNeverZero() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01", "video-06"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.items.first { $0.localIdentifier == "video-01" }?.sizeInBytes == 240_000_000)
        #expect(plan.items.first { $0.localIdentifier == "video-06" }?.sizeInBytes == nil)
        #expect(plan.sizeSummary.unresolvedCount == 1)
        #expect(!plan.sizeSummary.isExact)
    }

    // MARK: Selection → staleness (source-gated)

    @Test func videoSelectionChangeMakesVideoPlanStale() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        env.mutateVideoSelection { $0.toggle("video-02") }

        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    @Test func otherSelectionChangesDoNotStaleVideoPlan() async {
        let (env, _) = makeVideoEnv(analysis: .completed(Fixtures.analysisResult))
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateScreenshotSelection { $0.toggle("shot-01") }
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.mutateSelection { $0.toggle("photo-01") }
        // The similar-photos selection really did change…
        #expect(env.selection.selectedIDs.contains("photo-01"))

        // …but only a plan built from that source would care; the video plan is untouched.
        guard case .readyForReview = env.deletionState else {
            Issue.record("foreign selection change staled the video plan, got \(env.deletionState)")
            return
        }
    }

    @Test func videoSelectionChangeDoesNotStaleOtherPlans() async {
        let (env, _) = makeVideoEnv(analysis: .completed(Fixtures.analysisResult))
        env.mutateScreenshotSelection { $0.selectAll() }
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected a ready screenshot plan, got \(env.deletionState)")
            return
        }

        env.mutateVideoSelection { $0.toggle("video-01") }

        guard case .readyForReview = env.deletionState else {
            Issue.record("video mutation staled the screenshot plan, got \(env.deletionState)")
            return
        }
    }

    // MARK: Cross-source review entry

    @Test func videosReviewDropsAScreenshotPlanAndPreparesItsOwn() async {
        let (env, _) = makeVideoEnv()
        env.mutateScreenshotSelection { $0.selectAll() }
        env.prepareDeletionPlan(from: .screenshots)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected a ready screenshot plan, got \(env.deletionState)")
            return
        }

        selectVideos(["video-03", "video-04"], in: env)
        env.reviewDidAppear(from: .videos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready video plan, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["video-03", "video-04"])
        #expect(plan.analysisSignature == VideoDataset.signature(in: VideosFixture.completed))
    }

    @Test func screenshotReviewDropsAVideoPlan() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.mutateScreenshotSelection { $0.toggle("shot-01") }
        env.reviewDidAppear(from: .screenshots)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready screenshot plan, got \(env.deletionState)")
            return
        }
        #expect(plan.analysisSignature == ScreenshotDataset.signature(in: VideosFixture.completed))
        #expect(plan.selectionSnapshot == ["shot-01"])
    }

    @Test func videosReviewKeepsItsOwnReadyPlan() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-02"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)
        guard case .readyForReview(let before) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.reviewDidAppear(from: .videos)

        guard case .readyForReview(let after) = env.deletionState else {
            Issue.record("same-source review dropped the plan, got \(env.deletionState)")
            return
        }
        #expect(after.selectionSnapshot == before.selectionSnapshot)
        #expect(after.analysisSignature == before.analysisSignature)
    }

    @Test func foreignReviewAppearDiscardsAnInFlightVideoBuild() async {
        let (env, _) = makeVideoEnv(analysis: .completed(Fixtures.analysisResult))
        env.selection = PhotoSelectionModel(groups: [Fixtures.photoGroup])
        env.selection.toggle("photo-01")
        env.selection.toggle("photo-02")
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos) // still building when the other review opens

        env.reviewDidAppear(from: .similarPhotos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected a ready similar-photos plan, got \(env.deletionState)")
            return
        }
        #expect(plan.analysisSignature == DeletionPlanner.analysisSignature(for: Fixtures.analysisResult))
        #expect(plan.selectionSnapshot != ["video-01"])
    }

    // MARK: Dataset invalidation

    @Test func datasetChangeDroppingASelectedVideoInvalidatesSelectionAndPlan() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01", "video-02"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        // The library changed: video-02 no longer exists in a rebuilt catalog.
        let rebuilt = CatalogScanResult(
            records: VideosFixture.records.filter { $0.localIdentifier != "video-02" },
            libraryAssetCount: VideosFixture.records.count - 1,
            accessLevel: .authorized
        )
        env.catalogState = .completed(rebuilt)
        env.synchronizeVideoDataset()

        #expect(env.videoSelection.selectedIDs == ["video-01"])
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
    }

    @Test func datasetChangeOutsideTheSelectionStalesBySignatureNotSelection() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        // The library grew a video the user never touched: selection identical,
        // dataset fingerprint different.
        let grew = CatalogScanResult(
            records: VideosFixture.records + [Fixtures.extraVideo],
            libraryAssetCount: VideosFixture.records.count + 1,
            accessLevel: .authorized
        )
        env.catalogState = .completed(grew)
        env.synchronizeVideoDataset()

        #expect(env.videoSelection.selectedIDs == ["video-01"])
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.analysisChanged])
    }

    @Test func catalogGoneResetsTheVideoSelection() {
        let env = makeVideoEnv().env
        env.videoSelection.selectAll()

        env.catalogState = .notStarted
        env.synchronizeVideoDataset()

        #expect(env.videoSelection.datasetIDs.isEmpty)
        #expect(env.videoSelection.selectedIDs.isEmpty)
    }

    // MARK: Confirmation gating

    @Test func confirmWithoutConfirmationNeverReachesTheService() async {
        let (env, service) = makeVideoEnv()
        selectVideos(["video-01", "video-02"], in: env)
        env.prepareDeletionPlan(from: .videos)
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

    @Test func confirmedDeletionExecutesWithVideoDatasetContext() async {
        let (env, service) = makeVideoEnv()
        selectVideos(["video-01", "video-03"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(service.callCount == 1)
        #expect(service.lastPlanCount == 2)
        guard let context = service.lastContext else {
            Issue.record("expected the service to receive a plan context")
            return
        }
        #expect(context.selectionIDs == ["video-01", "video-03"])
        #expect(context.sessionToken == "session-1")
        #expect(context.analysisSignature == VideoDataset.signature(in: VideosFixture.completed))
        guard case .succeeded = env.deletionState else {
            Issue.record("expected succeeded, got \(env.deletionState)")
            return
        }
    }

    @Test func destructiveCopyNamesVideosNotPhotos() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01", "video-02"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        #expect(DeletionPresentation.destructiveTitle(for: plan) == "Delete 2 Videos")
        #expect(DeletionPresentation.noun(for: plan).many == "Videos")
    }

    @Test func deletionSuccessResetsVideoSelectionMeasurementAndCatalog() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        env.beginConfirmation()
        await env.confirmDeletion()

        // The library changed: every dataset-derived fact is dropped.
        #expect(env.videoSelection.datasetIDs.isEmpty)
        #expect(env.videoSelection.selectedIDs.isEmpty)
        #expect(env.videoSizeResolution == .idle)
        #expect(env.catalogState == .notStarted)
        #expect(env.analysisState == .notStarted)
    }

    @Test func staleVideoPlanCanBeRepreparedFromTheStaleState() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)
        env.mutateVideoSelection { $0.toggle("video-02") }
        guard case .planStale = env.deletionState else {
            Issue.record("expected planStale, got \(env.deletionState)")
            return
        }

        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview after re-prepare, got \(env.deletionState)")
            return
        }
        #expect(plan.selectionSnapshot == ["video-01", "video-02"])
    }

    // MARK: Size measurement (bounded, cancellable, read-only)

    @Test func measurementRunsInBoundedSequentialBatchesAndSettlesComplete() async {
        // 70 videos → three sequential batches of at most `measurementBatchSize` — never one
        // unbounded fan-out, and every identifier is measured exactly once.
        let catalog = makeCatalog(videoRecords(count: 70))
        let provider = RecordingSizeProvider(sizes: syntheticSizes(count: 70))
        let env = makeVideoEnv(catalog: catalog, sizeProvider: provider).env

        env.startVideoSizeResolution()
        await waitForSettled(env)

        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.total == 70)
        #expect(measurement.measuredCount == 70)
        #expect(!measurement.isPartial)
        #expect(provider.callCount == 3)
        #expect(provider.batches.map(\.count) == [32, 32, 6])
        let served = provider.batches.flatMap { $0 }
        #expect(Set(served).count == 70) // each id exactly once
        // Measurement is read-only: it never touched the selection or the deletion machine.
        #expect(env.videoSelection.selectedIDs.isEmpty)
        #expect(env.deletionState == .noSelection)
    }

    @Test func measurementSettlesPartialWhenProviderCannotResolveSomeVideos() async {
        let env = makeVideoEnv().env // provider knows 5 of the 6 fixture videos

        env.startVideoSizeResolution()
        await waitForSettled(env)

        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.measuredCount == 5)
        #expect(measurement.total == 6)
        #expect(measurement.isPartial)
        #expect(measurement.bytes["video-06"] == nil) // unknown, never zero
    }

    @Test func cancelKeepsWhatWasMeasuredAndLateBatchesCannotOverwrite() async {
        let catalog = makeCatalog(videoRecords(count: 70))
        let provider = RecordingSizeProvider(
            sizes: syntheticSizes(count: 70),
            delayNanoseconds: 80_000_000 // 80 ms per batch
        )
        let env = makeVideoEnv(catalog: catalog, sizeProvider: provider).env

        env.startVideoSizeResolution()
        // Wait until the first batch has actually landed (32 of 70 measured), then cancel.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while env.videoSizeResolution.measurement?.bytes.isEmpty ?? true,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let inFlight = env.videoSizeResolution.measurement, !inFlight.bytes.isEmpty else {
            Issue.record("first measurement batch never landed")
            return
        }
        env.cancelVideoSizeResolution()

        guard case .settled(let afterCancel) = env.videoSizeResolution else {
            Issue.record("cancel must settle as partial, got \(env.videoSizeResolution)")
            return
        }
        #expect(afterCancel.bytes == inFlight.bytes)
        let bytesAtCancel = afterCancel.bytes

        // Let every late batch land: the generation guard must discard them all.
        try? await Task.sleep(for: .milliseconds(400))
        guard case .settled(let afterGrace) = env.videoSizeResolution else {
            Issue.record("late batch flipped the state back to measuring")
            return
        }
        #expect(afterGrace.bytes == bytesAtCancel)
        #expect(afterGrace.measuredCount < 70)
        #expect(afterGrace.isPartial)
    }

    @Test func resumeOnlyMeasuresWhatIsStillUnknown() async {
        let provider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes) // never knows video-06
        let env = makeVideoEnv(sizeProvider: provider).env

        env.startVideoSizeResolution()
        await waitForSettled(env)
        let firstCalls = provider.callCount
        guard case .settled(let partial) = env.videoSizeResolution, partial.isPartial else {
            Issue.record("expected a partial settled state, got \(env.videoSizeResolution)")
            return
        }

        env.resumeVideoSizeMeasurement()
        await waitForSettled(env)

        #expect(provider.callCount == firstCalls + 1)
        #expect(provider.batches.last == ["video-06"]) // only the unknown one
        guard case .settled(let stillPartial) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(stillPartial.measuredCount == 5)
        #expect(stillPartial.bytes["video-06"] == nil)
    }

    @Test func startFromSettledDoesNothingWithoutExplicitResume() async {
        let provider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes)
        let env = makeVideoEnv(sizeProvider: provider).env
        env.startVideoSizeResolution()
        await waitForSettled(env)
        let callsAfterSettle = provider.callCount

        env.startVideoSizeResolution() // settled → no-op by design
        #expect(provider.callCount == callsAfterSettle)
        #expect(env.videoSizeResolution.isMeasuring == false)
    }

    @Test func measurementNeverStartsWithoutPermissionOrVideos() {
        let denied = makeVideoEnv().env
        denied.photoPermissionState = .denied
        denied.startVideoSizeResolution()
        #expect(denied.videoSizeResolution == .idle)

        let empty = makeVideoEnv(catalog: VideosFixture.noVideosResult).env
        empty.startVideoSizeResolution()
        #expect(empty.videoSizeResolution == .idle)
    }

    @Test func measurementNeedsCompletedCatalog() {
        let env = makeVideoEnv().env
        env.catalogState = .cancelled
        env.startVideoSizeResolution()
        #expect(env.videoSizeResolution == .idle)
    }

    @Test func catalogRebuildDropsAPreviousMeasurementBySignature() async {
        let (env, _) = makeVideoEnv()
        env.startVideoSizeResolution()
        await waitForSettled(env)
        guard case .settled = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }

        // Same dataset again → the measurement survives.
        env.synchronizeVideoDataset()
        guard case .settled = env.videoSizeResolution else {
            Issue.record("identical dataset dropped the measurement")
            return
        }

        // A rebuilt dataset with one more video → old bytes are dropped, never mixed in.
        env.catalogState = .completed(
            CatalogScanResult(
                records: VideosFixture.records + [Fixtures.extraVideo],
                libraryAssetCount: VideosFixture.records.count + 1,
                accessLevel: .authorized
            )
        )
        env.synchronizeVideoDataset()
        #expect(env.videoSizeResolution == .idle)
    }

    @Test func inFlightMeasurementIsDroppedOnCatalogRebuild() async {
        let catalog = makeCatalog(videoRecords(count: 70))
        let provider = RecordingSizeProvider(
            sizes: syntheticSizes(count: 70),
            delayNanoseconds: 80_000_000
        )
        let env = makeVideoEnv(catalog: catalog, sizeProvider: provider).env

        env.startVideoSizeResolution()
        while !env.videoSizeResolution.isMeasuring {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Rebuild lands mid-measurement: sync cancels + resets, and the generation guard
        // discards every batch the old run still has in flight.
        env.catalogState = .completed(
            CatalogScanResult(
                records: videoRecords(count: 71),
                libraryAssetCount: 71,
                accessLevel: .authorized
            )
        )
        env.synchronizeVideoDataset()
        #expect(env.videoSizeResolution == .idle)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(env.videoSizeResolution == .idle)
    }
}

// MARK: - Fixtures

private enum Fixtures {
    /// A photo group, for proving video plans never wait on analysis.
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
        totalRecordCount: VideosFixture.records.count,
        candidateBucketCount: 1,
        candidatePairCount: 1
    )

    /// A video not present in `VideosFixture` — used to grow the dataset.
    static let extraVideo = PhotoAssetRecord(
        localIdentifier: "video-99",
        mediaType: .video,
        mediaSubtypes: [],
        pixelWidth: 1920,
        pixelHeight: 1080,
        creationDate: Date(timeIntervalSince1970: 1_760_000_000),
        modificationDate: nil,
        duration: 30,
        isFavorite: false,
        isHidden: false,
        sourceType: .library,
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

@MainActor
private func makeVideoEnv(
    catalog: CatalogScanResult = VideosFixture.completed,
    analysis: PhotoAnalysisState = .notStarted,
    sizeProvider: RecordingSizeProvider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes),
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
        makePhotoLibrary: { FakeLibrary(records: catalog.records) },
        sizeProvider: sizeProvider,
        deletionService: service,
        sessionToken: "session-1"
    )
    env.photoPermissionState = .authorized
    env.catalogState = .completed(catalog)
    env.analysisState = analysis
    // Tests set `catalogState` directly (bypassing the catalog-build writer), so reconcile
    // both catalog-filter selections exactly as the real completion path would.
    env.synchronizeScreenshotDataset()
    env.synchronizeVideoDataset()
    precondition(env.videoSelection.datasetCount == VideoDataset.identifiers(in: catalog).count)
    return (env, service)
}

@MainActor
private func selectVideos(_ ids: [String], in env: AppEnvironment) {
    env.mutateVideoSelection { selection in
        for id in ids {
            selection.toggle(id)
        }
    }
    precondition(env.videoSelection.selectedCount == ids.count)
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

@MainActor
private func waitForSettled(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 5_000
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while !isSettled(env.videoSizeResolution), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func isSettled(_ resolution: VideoSizeResolution) -> Bool {
    if case .settled = resolution { return true }
    return false
}

private func makeCatalog(_ records: [PhotoAssetRecord]) -> CatalogScanResult {
    CatalogScanResult(
        records: records,
        libraryAssetCount: records.count,
        accessLevel: .authorized
    )
}

/// `count` synthetic video records, newest first, with distinct ids.
private func videoRecords(count: Int) -> [PhotoAssetRecord] {
    let base = Date(timeIntervalSince1970: 1_760_000_000)
    return (0..<count).map { index in
        PhotoAssetRecord(
            localIdentifier: "bulk-video-\(index)",
            mediaType: .video,
            mediaSubtypes: [],
            pixelWidth: 1920,
            pixelHeight: 1080,
            creationDate: base.addingTimeInterval(-Double(index) * 60),
            modificationDate: nil,
            duration: TimeInterval(index % 300),
            isFavorite: false,
            isHidden: false,
            sourceType: .library,
            hasAdjustments: false,
            representsBurst: false,
            burstIdentifier: nil
        )
    }
}

private func syntheticSizes(count: Int) -> [String: Int64] {
    (0..<count).reduce(into: [:]) { sizes, index in
        sizes["bulk-video-\(index)"] = Int64(1_000_000 + index)
    }
}

// MARK: - Test doubles

/// Size provider that records every batch it is asked to measure, optionally slow, so tests
/// can prove batching, targeting, and cancellation behaviour without a photo library.
private final class RecordingSizeProvider: AssetSizeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let sizes: [String: Int64]
    private let delayNanoseconds: UInt64
    private var recordedBatches: [[String]] = []

    init(sizes: [String: Int64], delayNanoseconds: UInt64 = 0) {
        self.sizes = sizes
        self.delayNanoseconds = delayNanoseconds
    }

    func sizes(for localIdentifiers: [String]) async -> [String: Int64] {
        // NSLock is unavailable in async contexts, so the recorded batch append is sync.
        record(localIdentifiers)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let requested = Set(localIdentifiers)
        return sizes.filter { requested.contains($0.key) }
    }

    private func record(_ localIdentifiers: [String]) {
        lock.lock()
        recordedBatches.append(localIdentifiers)
        lock.unlock()
    }

    var batches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBatches
    }

    var callCount: Int { batches.count }
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
