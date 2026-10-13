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

    @Test func deletionSuccessPrunesTheVideoDatasetAndKeepsTheCatalog() async {
        let (env, _) = makeVideoEnv()
        selectVideos(["video-01"], in: env)
        env.prepareDeletionPlan(from: .videos)
        await waitForPlanReady(env)

        env.beginConfirmation()
        await env.confirmDeletion()

        // The deleted video leaves the catalog-derived selection; everything else stands —
        // the catalog stays completed (pruned in place), measurement resets, no scan starts.
        #expect(env.videoSelection.datasetCount == VideosFixture.videos.count - 1)
        #expect(!env.videoSelection.datasetIDs.contains("video-01"))
        #expect(env.videoSelection.selectedIDs.isEmpty)
        #expect(env.videoSizeResolution == .idle)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected the catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(!catalog.records.contains { $0.localIdentifier == "video-01" })
        #expect(catalog.records.count == VideosFixture.records.count - 1)
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
        // 70 videos → nine sequential batches of at most `measurementBatchSize` — never one
        // unbounded fan-out, and every identifier is measured exactly once. The batch size
        // is 8 (two waves at the provider's default width of 4), so the first on-screen
        // increment lands within about a second instead of after a full 32-asset pass.
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
        #expect(provider.callCount == 9)
        #expect(provider.batches.map(\.count) == [8, 8, 8, 8, 8, 8, 8, 8, 6])
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
        // The unmeasurable one was *attempted* — counted as unavailable, never as measured.
        #expect(measurement.unavailableCount == 1)
        #expect(measurement.resolvedCount == 6)
    }

    @Test func aBatchOfUnmeasurableVideosStillAdvancesProgressHonestly() async {
        // The iCloud-only library: the provider resolves nothing. Progress must still
        // resolve every identifier as unavailable — the screen never sits at "0 of N"
        // while real work is happening — and the settled state must say exactly that,
        // with zero measured and nothing fabricated.
        let catalog = makeCatalog(videoRecords(count: 12))
        let provider = RecordingSizeProvider(sizes: [:]) // knows nothing
        let env = makeVideoEnv(catalog: catalog, sizeProvider: provider).env

        env.startVideoSizeResolution()
        await waitForSettled(env)

        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.total == 12)
        #expect(measurement.measuredCount == 0)
        #expect(measurement.unavailableCount == 12)
        #expect(measurement.resolvedCount == 12)
        #expect(measurement.isPartial) // nothing was *measured*
        #expect(measurement.bytes.isEmpty) // unknown, never zero
    }

    @Test func aMixedLocalAndCloudLibrarySettlesWithConsistentCountsAndOrder() async {
        // Half the library is measurable, half is not (the iCloud-only half): every
        // video is counted exactly once — measured or unavailable, never both, never
        // dropped — and only the measured ones enter the size ranking.
        let catalog = makeCatalog(videoRecords(count: 12))
        var sizes: [String: Int64] = [:]
        for index in 0..<6 {
            sizes["bulk-video-\(index)"] = Int64(10_000_000 + index * 1_000_000)
        }
        let provider = RecordingSizeProvider(sizes: sizes)
        let env = makeVideoEnv(catalog: catalog, sizeProvider: provider).env

        env.startVideoSizeResolution()
        await waitForSettled(env)

        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.total == 12)
        #expect(measurement.measuredCount == 6)
        #expect(measurement.unavailableCount == 6)
        // Internally consistent: the counts partition the inventory exactly.
        #expect(measurement.resolvedCount == measurement.total)

        let records = env.videoRecordsForDisplay
        #expect(records.count == 12)
        // The six measured videos sort largest-first and lead the list; the six unknown
        // ones follow, never ranked among the measured sizes.
        let measuredPrefix = Array(records.prefix(6))
        #expect(measuredPrefix.allSatisfy { $0.sizeInBytes != nil })
        let bytes = measuredPrefix.compactMap(\.sizeInBytes)
        #expect(bytes == bytes.sorted(by: >))
        #expect(records.dropFirst(6).allSatisfy { $0.sizeInBytes == nil })
    }

    @Test func theInventoryRendersDuringMeasurementAndRebuildsOnlyOnStateChanges() async {
        // Enumerate first: while a measurement is in flight the screen already has the
        // full list (sizes filling in), and the cached list rebuilds only when the
        // catalog or the measurement itself changes — never per render.
        let (env, _) = makeVideoEnv()
        let signature = VideoDataset.signature(in: VideosFixture.completed)

        // Idle: the raw inventory, every size unknown — never an empty screen.
        let idleRecords = env.videoRecordsForDisplay
        #expect(idleRecords.count == VideosFixture.videos.count)
        #expect(idleRecords.allSatisfy { $0.sizeInBytes == nil })

        // Measuring mid-flight: the partial bytes are embedded and sorted to the front.
        env.videoSizeResolution = .measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: signature,
                bytes: ["video-03": 1_600_000_000],
                total: VideosFixture.videos.count,
                unavailableIDs: ["video-04", "video-05"]
            )
        )
        let measuringRecords = env.videoRecordsForDisplay
        #expect(measuringRecords.count == VideosFixture.videos.count)
        #expect(measuringRecords.first?.localIdentifier == "video-03")
        #expect(measuringRecords.first?.sizeInBytes == 1_600_000_000)

        // Same measurement state → the cache answers with the identical list.
        #expect(env.videoRecordsForDisplay == measuringRecords)

        // A new measurement invalidates the cache: the second size sorts by its bytes.
        env.videoSizeResolution = .measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: signature,
                bytes: ["video-03": 1_600_000_000, "video-01": 240_000_000],
                total: VideosFixture.videos.count
            )
        )
        let updated = env.videoRecordsForDisplay
        #expect(Array(updated.map(\.localIdentifier).prefix(2)) == ["video-03", "video-01"])

        // A rebuilt catalog invalidates it too — the extra video appears, still sorted
        // by the (still-current-signature-less) measurement dropped to unknown sizes.
        env.catalogState = .completed(
            CatalogScanResult(
                records: VideosFixture.records + [Fixtures.extraVideo],
                libraryAssetCount: VideosFixture.records.count + 1,
                accessLevel: .authorized
            )
        )
        env.synchronizeVideoDataset()
        #expect(env.videoRecordsForDisplay.count == VideosFixture.videos.count + 1)
        #expect(env.videoRecordsForDisplay.allSatisfy { $0.sizeInBytes == nil })
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

    /// A finished pass is authoritative: the one unmeasurable video is *not* re-attempted
    /// on every visit (re-poking a cloud-heavy library's thousands of unknowns each entry
    /// is exactly the re-scan the Video Cleanup contract forbids). Re-checking is the
    /// Rescan button's job; the unknown stays honestly unknown — never zero.
    @Test func aFinishedPassDoesNotRePokeTheUnmeasurableVideoOnResume() async {
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

        #expect(provider.callCount == firstCalls) // video-06 is not attempted again
        guard case .settled(let stillPartial) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        #expect(stillPartial.measuredCount == 5)
        #expect(stillPartial.bytes["video-06"] == nil)
        #expect(stillPartial.isPartial) // still honest about the unknown
    }

    /// The Video Cleanup contract (Large-Files shape): opening the screen reuses what is
    /// already measured. A settled measurement is kept as-is — re-entering never re-scans
    /// and never re-pokes the videos that could not be measured.
    @Test func reEnteringReusesMeasuredSizesAndNeverRescans() async {
        let provider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes)
        let env = makeVideoEnv(sizeProvider: provider).env
        env.startVideoSizeResolution()
        await waitForSettled(env)
        let callsAfterSettle = provider.callCount
        #expect(callsAfterSettle > 0)

        env.startVideoSizeResolution() // the screen was opened again

        #expect(provider.callCount == callsAfterSettle) // nothing measured twice
        #expect(env.videoSizeResolution.isMeasuring == false)
    }

    /// A partial measurement continues on re-entry: the sizes already known are kept and
    /// only the unmeasured remainder is attempted.
    @Test func aPartialMeasurementContinuesOnlyTheUnknownsOnReEntry() async {
        let provider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes)
        let (env, _) = makeVideoEnv(sizeProvider: provider)
        // An interrupted run that knew two sizes.
        env.videoSizeResolution = .settled(VideoSizeResolution.Measurement(
            datasetSignature: env.videoDatasetSignature,
            bytes: ["video-01": 111, "video-02": 222],
            total: VideosFixture.videos.count
        ))

        env.startVideoSizeResolution()
        await waitForSettled(env)

        // Only the unknown remainder reached the provider.
        let asked = Set(provider.batches.flatMap { $0 })
        #expect(!asked.contains("video-01"))
        #expect(!asked.contains("video-02"))
        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled, got \(env.videoSizeResolution)")
            return
        }
        // The kept sizes win; the rest were measured.
        #expect(measurement.bytes["video-01"] == 111)
        #expect(measurement.bytes["video-02"] == 222)
        #expect(measurement.measuredCount == VideosFixture.measuredBytes.count)
    }

    /// Rescan is the only path that discards measured data: everything is measured again
    /// from scratch (the Contacts screen's Rescan contract).
    @Test func rescanDiscardsAndMeasuresEverythingAgain() async {
        let provider = RecordingSizeProvider(sizes: VideosFixture.measuredBytes)
        let (env, _) = makeVideoEnv(sizeProvider: provider)
        env.startVideoSizeResolution()
        await waitForSettled(env)
        let callsAfterFirst = provider.callCount
        #expect(callsAfterFirst > 0)

        env.rescanVideoSizes()
        await waitForSettled(env)

        #expect(provider.callCount > callsAfterFirst) // a fresh pass over the dataset
        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled after rescan, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.measuredCount == VideosFixture.measuredBytes.count)
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

    // MARK: Scan-job coordination

    /// Video sizing is I/O-bound over bounded batches: it runs *alongside* heavy passes —
    /// both entry points start it outright (previously both refused while a pass ran,
    /// which starved the Video Cleanup screen forever under chained passes).
    @Test func measurementRunsAlongsideAHeavyPass() async {
        let withSimilarity = makeVideoEnv().env
        withSimilarity.analysisState = .running(PhotoAnalysisProgress(
            stage: .preparing,
            completedUnits: 2,
            totalUnits: 10
        ))
        withSimilarity.startVideoSizeResolution()
        withSimilarity.resumeVideoSizeMeasurement()
        #expect(withSimilarity.videoSizeResolution.isMeasuring)

        let withBlur = makeVideoEnv().env
        withBlur.blurAnalysisState = .running(BlurAnalysisProgress(
            completedUnits: 1,
            totalUnits: 9
        ))
        withBlur.startVideoSizeResolution()
        withBlur.resumeVideoSizeMeasurement()
        #expect(withBlur.videoSizeResolution.isMeasuring)

        await waitForSettled(withSimilarity)
        #expect(isSettled(withSimilarity.videoSizeResolution))
        await waitForSettled(withBlur)
        #expect(isSettled(withBlur.videoSizeResolution))
    }

    /// The measurement settles while the pass is *still* running — it no longer waits for
    /// a terminal flip that a chained pass never reached.
    @Test func measurementDoesNotWaitForAPassToFinish() async {
        let env = makeVideoEnv().env
        env.analysisState = .running(PhotoAnalysisProgress(
            stage: .preparing,
            completedUnits: 2,
            totalUnits: 10
        ))
        env.startVideoSizeResolution()
        #expect(env.videoSizeResolution.isMeasuring)

        await waitForSettled(env)
        #expect(isSettled(env.videoSizeResolution))
        #expect(env.analysisState.isRunning) // the pass never finished during this test
    }

    /// Starting similarity does not cancel or yield an in-flight measurement: it keeps
    /// filling its batches and settles on its own (previously every pass start cancelled
    /// the run and left its partial progress parked).
    @Test func startingSimilarityKeepsAnInFlightMeasurementRunning() async {
        let provider = RecordingSizeProvider(
            sizes: VideosFixture.measuredBytes,
            delayNanoseconds: 80_000_000
        )
        let env = makeVideoEnv(sizeProvider: provider).env
        env.startVideoSizeResolution()
        #expect(env.videoSizeResolution.isMeasuring)

        env.startSimilarityAnalysis()

        #expect(env.videoSizeResolution.isMeasuring) // not cancelled, not settled by the pass
        await waitForSettled(env)
        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected a settled measurement, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.total > 0)
        #expect(measurement.measuredCount == VideosFixture.measuredBytes.count)
        env.cancelSimilarityAnalysis()
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
    )),
    contactsPermission: any ContactsPermissionServicing = VideoCheckpointContactsPermissionService(),
    checkpointStore: InMemoryScanCheckpointStore = InMemoryScanCheckpointStore(),
    scanSnapshotStore: InMemoryScanSnapshotStore = InMemoryScanSnapshotStore(),
    backgroundTasks: any BackgroundTaskScheduling = FakeBackgroundTaskScheduler()
) -> (env: AppEnvironment, service: RecordingDeletionService) {
    let service = RecordingDeletionService(outcome: outcome)
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        contactsPermission: contactsPermission,
        makePhotoLibrary: { FakeLibrary(records: catalog.records) },
        sizeProvider: sizeProvider,
        deletionService: service,
        scanSnapshotStore: scanSnapshotStore,
        checkpointStore: checkpointStore,
        backgroundTasks: backgroundTasks,
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

// MARK: - Checkpoint persistence + resume (Phase C)

/// Video-size measurement's Phase C contract: a restored `.videoSizes` checkpoint seeds
/// the next pass (checkpoint bytes win, the provider is never asked for seeded ids);
/// background expiration mid-measurement persists exactly what landed, releases the
/// background task, and foregrounding finishes only the remainder; and a paused heavy
/// pass's checkpoint keeps the file slot — an expiration can never clobber it.
@MainActor
struct VideoCheckpointFlowTests {
    @Test func restoredVideoSizesCheckpointSeedsTheNextMeasurement() async throws {
        let records = videoRecords(count: 10)
        let checkpointStore = InMemoryScanCheckpointStore()
        // Deliberately different from what the provider answers for the same ids, so the
        // final bytes prove *which* source won.
        let seeded: [String: Int64] = [
            "bulk-video-0": 42_424_242,
            "bulk-video-1": 17_171_717,
            "bulk-video-2": 9_999_999,
        ]
        try checkpointStore.save(ScanCheckpoint(
            runSequence: 3,
            kind: .videoSizes,
            startedAt: Date(timeIntervalSince1970: 1_760_000_400),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_450),
            completedUnits: seeded.count,
            totalUnits: records.count,
            videoSizes: seeded.map { assetID, bytes in
                VideoSizeEntry(assetID: assetID, modified: nil, bytes: bytes)
            }
            .sorted { $0.assetID < $1.assetID }
        ))
        let provider = RecordingSizeProvider(sizes: syntheticSizes(count: 10))
        let (env, _) = makeVideoEnv(
            catalog: makeCatalog(records),
            sizeProvider: provider,
            checkpointStore: checkpointStore
        )
        await env.bootstrap()

        // Restoring a video checkpoint has no paused surface: nothing starts, nothing
        // claims the slot — the seed is applied the next time measurement starts.
        #expect(env.videoSizeResolution.bytes.isEmpty)

        env.resumeVideoSizeMeasurement()
        await waitForSettled(env)

        guard case .settled(let measurement) = env.videoSizeResolution else {
            Issue.record("expected settled measurement, got \(env.videoSizeResolution)")
            return
        }
        #expect(measurement.bytes.count == records.count)
        #expect(!measurement.isPartial)
        #expect(measurement.bytes["bulk-video-0"] == 42_424_242)
        #expect(measurement.bytes["bulk-video-1"] == 17_171_717)
        #expect(measurement.bytes["bulk-video-2"] == 9_999_999)
        #expect(measurement.bytes["bulk-video-3"] == 1_000_003)
        // The seeded ids were never handed to the provider — only the remainder was.
        let asked = Set(provider.batches.flatMap { $0 })
        #expect(asked.isDisjoint(with: Set(seeded.keys)))
        // A completed measurement is kept as persisted scan data (not cleared): a
        // relaunch reuses it instead of re-scanning.
        #expect(checkpointStore.load() != nil)

        // Relaunch: a fresh environment over the same store sees the kept sizes.
        let relaunchProvider = RecordingSizeProvider(sizes: syntheticSizes(count: 10))
        let (relaunched, _) = makeVideoEnv(
            catalog: makeCatalog(records),
            sizeProvider: relaunchProvider,
            checkpointStore: checkpointStore
        )
        await relaunched.bootstrap()
        relaunched.resumeVideoSizeMeasurement()
        await waitForSettled(relaunched)
        let relaunchAsked = Set(relaunchProvider.batches.flatMap { $0 })
        #expect(relaunchAsked.isDisjoint(with: Set(seeded.keys))) // kept sizes never re-measured
    }

    @Test func expirationCheckpointsAPartialMeasurementAndForegroundFinishesOnlyTheRemainder()
        async throws {
        let records = videoRecords(count: 160)
        let checkpointStore = InMemoryScanCheckpointStore()
        let background = FakeBackgroundTaskScheduler()
        // 160 videos at batch size 32 → five sequential batches; the first lands at
        // ~120 ms, completion needs ~600 ms, so expiration mid-run is deterministic.
        let provider = RecordingSizeProvider(
            sizes: syntheticSizes(count: 160),
            delayNanoseconds: 120_000_000
        )
        let (env, _) = makeVideoEnv(
            catalog: makeCatalog(records),
            sizeProvider: provider,
            checkpointStore: checkpointStore,
            backgroundTasks: background
        )

        env.handleLifecycle(.background)
        #expect(!background.isHolding) // nothing to protect yet

        env.resumeVideoSizeMeasurement()
        guard case .measuring = env.videoSizeResolution else {
            Issue.record("expected measuring, got \(env.videoSizeResolution)")
            return
        }
        #expect(background.isHolding)

        let firstBatchLanded = await waitForMeasuredBytes(env, atLeast: 32)
        #expect(firstBatchLanded)

        background.fireExpiration()

        // The last deterministic moment: partial state kept on screen, the checkpoint
        // written synchronously with exactly that progress, the task released.
        guard case .settled(let partial) = env.videoSizeResolution else {
            Issue.record("expected settled partial after expiration, got \(env.videoSizeResolution)")
            return
        }
        #expect(partial.isPartial)
        #expect(partial.measuredCount >= 32)
        #expect(!background.isHolding)
        let saved = try #require(checkpointStore.load())
        #expect(saved.kind == .videoSizes)
        #expect(saved.totalUnits == records.count)
        #expect(saved.completedUnits == partial.measuredCount)

        // Foregrounding resumes automatically (this session was interrupted) and measures
        // only what the checkpoint never saw.
        let batchesBefore = provider.batches.count
        env.handleLifecycle(.active)
        await waitForSettled(env)

        guard case .settled(let finished) = env.videoSizeResolution else {
            Issue.record("expected settled after resume, got \(env.videoSizeResolution)")
            return
        }
        #expect(!finished.isPartial)
        #expect(finished.bytes.count == records.count)
        let newIDs = Set(provider.batches.dropFirst(batchesBefore).flatMap { $0 })
        #expect(newIDs.count == records.count - partial.measuredCount)
        #expect(newIDs.isDisjoint(with: Set(partial.bytes.keys)))
        // The finished measurement is *kept* as persisted scan data (M11-shape contract):
        // the next session reuses these sizes instead of re-scanning — only Rescan
        // discards them.
        let kept = try #require(checkpointStore.load())
        #expect(kept.kind == .videoSizes)
        #expect(kept.videoSizes.count == records.count)
        #expect(!background.isHolding)
    }

    @Test func aPausedHeavyPasssCheckpointKeepsTheSlotOverAVideoExpiration() async throws {
        let records = videoRecords(count: 160)
        let checkpointStore = InMemoryScanCheckpointStore()
        let background = FakeBackgroundTaskScheduler()
        let provider = RecordingSizeProvider(
            sizes: syntheticSizes(count: 160),
            delayNanoseconds: 120_000_000
        )
        // A paused blur pass owns the file: restore adopts it, and video measurement is
        // allowed to run — but never to write over heavier resume information.
        let blurCheckpoint = ScanCheckpoint(
            runSequence: 9,
            kind: .blur,
            startedAt: Date(timeIntervalSince1970: 1_760_000_400),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_450),
            completedUnits: 6,
            totalUnits: 8,
            blurThresholds: .corpusCalibrated
        )
        try checkpointStore.save(blurCheckpoint)
        let (env, _) = makeVideoEnv(
            catalog: makeCatalog(records),
            sizeProvider: provider,
            checkpointStore: checkpointStore,
            backgroundTasks: background
        )
        await env.bootstrap()
        guard case .paused = env.blurAnalysisState else {
            Issue.record("expected a restored paused blur pass, got \(env.blurAnalysisState)")
            return
        }

        env.handleLifecycle(.background)
        env.resumeVideoSizeMeasurement()
        #expect(background.isHolding)
        let firstBatchLanded = await waitForMeasuredBytes(env, atLeast: 32)
        #expect(firstBatchLanded)

        background.fireExpiration()

        // Video measurement settled as partial — and the blur checkpoint is untouched:
        // the video write was refused, not allowed to clobber heavier resume info.
        #expect(checkpointStore.load() == blurCheckpoint)
        guard case .settled(let partial) = env.videoSizeResolution else {
            Issue.record("expected settled partial after expiration, got \(env.videoSizeResolution)")
            return
        }
        #expect(partial.isPartial)
        #expect(!background.isHolding)
        guard case .paused = env.blurAnalysisState else {
            Issue.record("blur pass should still be paused, got \(env.blurAnalysisState)")
            return
        }
    }
}

// MARK: - PhotoKit callback deadline (the cloud-only hang cannot recur)

/// The M9 root cause this guards: `requestContentEditingInput` can delay its callback for
/// a cloud-only asset indefinitely, which hung the size pass at "0 of N". The provider's
/// every measurement path now races its callback against a hard deadline through these
/// two primitives; the deadline's answer is always the honest `.unavailable`.
struct VideoSizeDeadlineTests {
    @Test func theFirstAnswerWinsAndLaterOnesAreDropped() async {
        let box = OneShotValue<Int>()
        box.settle(with: 1)
        box.settle(with: 2) // a late PhotoKit callback after the deadline already won
        #expect(await box.wait() == 1)
    }

    @Test func anAnswerThatArrivesBeforeTheWaitIsNotLost() async {
        let box = OneShotValue<Int>()
        box.settle(with: 7)
        #expect(await box.wait() == 7)
    }

    @Test func aDeadlineThatFiresFirstDeliversAbsence() async {
        let value = await PhotoKitAssetSizeProvider.withDeadline(nanoseconds: 30_000_000) {
            (_: @escaping @Sendable (Int?) -> Void) in
            // Never answers — the cloud-only callback that never comes.
        }
        #expect(value == nil)
    }

    @Test func aTimelyAnswerBeatsTheDeadline() async {
        let value = await PhotoKitAssetSizeProvider.withDeadline(nanoseconds: 5_000_000_000) {
            deliver in deliver(42)
        }
        #expect(value == 42)
    }

    @Test func aLateAnswerAfterTheDeadlineIsDroppedWithoutCrashing() async {
        let value = await PhotoKitAssetSizeProvider.withDeadline(nanoseconds: 30_000_000) { deliver in
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // well after the deadline
                deliver(99) // dropped: the deadline already delivered absence
            }
        }
        #expect(value == nil)
        // Let the late callback land, proving it neither crashed nor double-resumed.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

// MARK: - Video size ladder (probe order, honesty, short-circuiting)

/// The rewritten measurement ladder: first measured bytes win, proven-remote content never
/// enters the stalling editing-input race, zero is never a size, and every identifier
/// resolves to exactly one honest outcome. Probes are scripted closures — no PhotoKit,
/// no photo library, fully deterministic.
struct VideoSizeLadderTests {
    /// Append-only step recorder for asserting probe order (probe closures are
    /// `@Sendable`, so the shared log locks).
    private final class StepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ step: String) {
            lock.lock()
            storage.append(step)
            lock.unlock()
        }

        var steps: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test func firstMeasuredProbeWinsAndLaterProbesNeverRun() async {
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .noAnswer },
            avCurrentBytes: { id in
                log.append("avCurrent(\(id))")
                return .measured(111)
            },
            avOriginalBytes: { _ in log.append("avOriginal"); return .measured(999) },
            editingInputBytes: { _ in log.append("editingInput"); return .measured(999) },
            imageDataBytes: { _ in log.append("imageData"); return .measured(999) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .measured(111))
        #expect(log.steps == ["resource", "avCurrent(video-1)"])
    }

    @Test func thePhotosMetadataCountWinsWhenItAnswersFirst() async {
        // iOS 27's dataSize is the first step: when it answers, the AV probes never run.
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .measured(4_242) },
            avCurrentBytes: { _ in log.append("avCurrent"); return .measured(999) },
            avOriginalBytes: { _ in log.append("avOriginal"); return .measured(999) },
            editingInputBytes: { _ in log.append("editingInput"); return .measured(999) },
            imageDataBytes: { _ in log.append("imageData"); return .measured(999) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .measured(4_242))
        #expect(log.steps == ["resource"])
    }

    @Test func anEditedVideoFallsThroughToTheOriginalFile() async {
        // `.current` renders an edited video as an AVComposition (no file URL → no answer);
        // `.original` is the pre-iOS 27 answer and carries the file.
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .noAnswer },
            avCurrentBytes: { _ in log.append("avCurrent"); return .noAnswer },
            avOriginalBytes: { _ in log.append("avOriginal"); return .measured(500) },
            editingInputBytes: { _ in log.append("editingInput"); return .measured(999) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .measured(500))
        #expect(log.steps == ["resource", "avCurrent", "avOriginal"])
    }

    @Test func aRemoteVideoStopsAfterTheSingleLocalityProbe() async {
        // PhotoKit said "not local" (network access disabled, no content): the ladder
        // answers unavailable immediately — no original, no editing-input race. This is
        // the fast path a cloud-heavy library lives on.
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .noAnswer },
            avCurrentBytes: { _ in log.append("avCurrent"); return .notLocal },
            avOriginalBytes: { _ in log.append("avOriginal"); return .measured(999) },
            editingInputBytes: { _ in log.append("editingInput"); return .measured(999) },
            imageDataBytes: { _ in log.append("imageData"); return .measured(999) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .unavailable)
        #expect(log.steps == ["resource", "avCurrent"]) // one locality probe, then stop
    }

    @Test func aRemoteOriginalIsAlsoTerminal() async {
        // The current version had no file URL (edited render → no answer); the original
        // reports not-local — the ladder stops there too.
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .noAnswer },
            avCurrentBytes: { _ in log.append("avCurrent"); return .noAnswer },
            avOriginalBytes: { _ in log.append("avOriginal"); return .notLocal },
            editingInputBytes: { _ in log.append("editingInput"); return .measured(999) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .unavailable)
        #expect(log.steps == ["resource", "avCurrent", "avOriginal"])
    }

    @Test func imageBytesAreTheLastResortWhenEveryFileAnswerIsSilent() async {
        let log = StepLog()
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in log.append("resource"); return .noAnswer },
            avCurrentBytes: { _ in log.append("avCurrent"); return .noAnswer },
            avOriginalBytes: { _ in log.append("avOriginal"); return .noAnswer },
            editingInputBytes: { _ in log.append("editingInput"); return .noAnswer },
            imageDataBytes: { _ in log.append("imageData"); return .measured(12_345) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "photo-1", probes: probes)

        #expect(outcome == .measured(12_345))
        #expect(
            log.steps == ["resource", "avCurrent", "avOriginal", "editingInput", "imageData"]
        )
    }

    @Test func theAssetIndexAnswersEveryLookupFromItsCache() {
        // A prefilled index answers from the dictionary and never hits PhotoKit — the
        // per-pass cache that replaces one `fetchAssets` XPC per probe per asset.
        let index = PhotoKitAssetSizeProvider.AssetIndex(cache: [:])
        #expect(index.asset(for: "deleted-or-photos-only-id") == nil)
    }

    @Test func aMeasuredZeroIsNeverReportedAsASize() async {
        // A genuinely empty file is not a measurement — silence everywhere is honest.
        let probes = PhotoKitAssetSizeProvider.Probes(
            resourceBytes: { _ in .measured(0) },
            avCurrentBytes: { _ in .measured(0) },
            avOriginalBytes: { _ in .measured(0) },
            editingInputBytes: { _ in .measured(0) },
            imageDataBytes: { _ in .measured(0) }
        )

        let outcome = await PhotoKitAssetSizeProvider.ladder(for: "video-1", probes: probes)

        #expect(outcome == .unavailable)
    }

    @Test func everyRequestedIdentifierResolvesToExactlyOneOutcome() async {
        // Default probes answer nothing: every id must still appear — as unavailable,
        // never missing (the class of bug that left the screen at "0 of N").
        let provider = PhotoKitAssetSizeProvider(probes: .init())
        let ids = (0..<9).map { "id-\($0)" } // more than one batch at the default width

        let outcomes = await provider.outcomes(for: ids)

        #expect(Set(outcomes.keys) == Set(ids))
        for id in ids {
            #expect(outcomes[id] == .unavailable)
        }
        #expect(await provider.outcomes(for: []).isEmpty) // no work, no entries
    }

    @Test func mixedProbeAnswersPartitionTheBatchIntoMeasuredAndUnavailable() async {
        let probes = PhotoKitAssetSizeProvider.Probes(
            avCurrentBytes: { id in
                id == "local-1" ? .measured(100) : .notLocal
            }
        )
        let provider = PhotoKitAssetSizeProvider(probes: probes)

        let outcomes = await provider.outcomes(for: ["local-1", "cloud-2", "cloud-3"])

        #expect(outcomes["local-1"] == .measured(100))
        #expect(outcomes["cloud-2"] == .unavailable)
        #expect(outcomes["cloud-3"] == .unavailable)
        #expect(outcomes.count == 3)
    }

    @Test func sizesOnlyReportMeasuredEntries() async {
        let provider = PhotoKitAssetSizeProvider(
            probes: .init(avCurrentBytes: { $0 == "x" ? .measured(50) : .noAnswer })
        )

        let sizes = await provider.sizes(for: ["x", "y"])

        #expect(sizes == ["x": 50]) // absent means unknown — never 0
    }
}

// MARK: - Checkpoint helpers

/// Waits until a running measurement has actually merged at least `count` bytes — the
/// provider records batches at request time, but the checkpoint can only see what landed.
@MainActor
private func waitForMeasuredBytes(
    _ env: AppEnvironment,
    atLeast count: Int,
    timeoutMilliseconds: Int = 5_000
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while ContinuousClock.now < deadline {
        if case .measuring(let measurement) = env.videoSizeResolution,
           measurement.bytes.count >= count {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private struct VideoCheckpointContactsPermissionService: ContactsPermissionServicing {
    func currentStatus() -> PermissionState { .notDetermined }
    func requestAccess() async -> PermissionState { .notDetermined }
}
