import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Blur analysis pipeline + AppEnvironment flow
//
// This suite covers the M5B verification list end to end: honest bucketing and unavailable
// reasons, terminal progress, cancellation, the bounded worker width, admission-without-
// selection, explicit select/deselect, plan build and staleness (including the shared
// review pipeline staying safe), no duplicate run on reopen, and the blur pass never
// touching similarity analysis, the scanner, or the persisted snapshot.

@MainActor
struct BlurAnalysisFlowTests {
    // MARK: Engine pipeline

    @Test func engineBucketsEveryRecordHonestlyInInputOrder() async throws {
        let records = [
            blurRecord(id: "sharp-01"),
            blurRecord(id: "blur-01"),
            blurRecord(id: "flat-01"),
            blurRecord(id: "blur-02"),
            blurRecord(id: "sharp-02"),
            blurRecord(id: "dark-01"),
        ]
        let probe = BlurProbe()
        let engine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: probe,
            images: [
                "sharp-01": blurFixtureSharpChecker,
                "sharp-02": blurFixtureScene,
                "blur-01": blurFixtureBlurryScene,
                "blur-02": blurFixtureBlurryScene,
                "flat-01": blurFixtureFlat,
                "dark-01": blurFixtureDarkNoise,
            ]
        ))

        let result = try await engine.analyze(records: records)

        // Candidates keep input (catalog) order even though four workers raced through them.
        #expect(result.candidates.map(\.assetID) == ["blur-01", "blur-02"])
        #expect(result.candidates.allSatisfy { $0.verdict == .likelyBlurry })
        #expect(result.sharpCount == 2)
        #expect(result.insufficientInformationCount == 2)
        #expect(result.unavailableAssets.isEmpty)
        #expect(result.judgedCount == 6)
        #expect(result.totalRecordCount == 6)
        #expect(result.thresholdsUsed == .corpusCalibrated)
        #expect(probe.requestCount == 6)
        // Every rendition was the bounded verification thumbnail — never full-resolution pixels.
        #expect(probe.modes == [.sharpness])
    }

    @Test func refusalsIssueNoThumbnailRequest() async throws {
        let records = [
            blurRecord(id: "sharp-01"),
            blurRecord(id: "vid-01", mediaType: .video),
            blurRecord(id: "zero-01", width: 0, height: 0),
        ]
        let probe = BlurProbe()
        let engine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: probe,
            images: ["sharp-01": blurFixtureSharpChecker]
        ))

        let result = try await engine.analyze(records: records)

        #expect(result.unavailableAssets == [
            PhotoAnalysisUnavailable(assetID: "vid-01", reason: .notAnalyzable),
            PhotoAnalysisUnavailable(assetID: "zero-01", reason: .invalidDimensions),
        ])
        // The refused records never reached the loader; the analyzable one did, exactly once.
        #expect(probe.requestedIDs().sorted() == ["sharp-01"])
        #expect(result.sharpCount == 1)
        #expect(result.candidates.isEmpty)
        #expect(result.totalRecordCount == 3)
    }

    @Test func thumbnailFailuresBecomeHonestUnavailableReasons() async throws {
        let records = [
            blurRecord(id: "tmo-01"),
            blurRecord(id: "cloud-01"),
            blurRecord(id: "gone-01"),
            blurRecord(id: "dead-01"),
        ]
        let probe = BlurProbe()
        let engine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: probe,
            failures: [
                "cloud-01": .onlyInICloud,
                "gone-01": .assetNotFound,
                "dead-01": .unavailable,
            ],
            timeoutIDs: ["tmo-01"]
        ))

        let result = try await engine.analyze(records: records)

        #expect(result.unavailableAssets == [
            PhotoAnalysisUnavailable(assetID: "tmo-01", reason: .timedOut),
            PhotoAnalysisUnavailable(assetID: "cloud-01", reason: .contentOnlyInICloud),
            PhotoAnalysisUnavailable(assetID: "gone-01", reason: .assetNotFound),
            PhotoAnalysisUnavailable(assetID: "dead-01", reason: .imageUnavailable),
        ])
        // Failures are never folded into the verdict counts — the run is honest about gaps.
        #expect(result.judgedCount == 0)
        #expect(result.notJudgedCount == 4)
        #expect(result.sharpCount == 0)
        #expect(result.candidates.isEmpty)
        #expect(result.totalRecordCount == 4)
        #expect(probe.requestCount == 4)
    }

    @Test func progressFinishesCompleteAndTheResultArrivesLast() async throws {
        let records = (0..<8).map { blurRecord(id: String(format: "p-%02d", $0)) }
        let engine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: BlurProbe(),
            fallbackImage: blurFixtureSharpChecker
        ))

        var events: [BlurAnalysisEvent] = []
        for try await event in engine.makeAnalysisStream(records: records) {
            events.append(event)
        }

        guard let last = events.last, case .completed(let result) = last else {
            Issue.record("stream must end with .completed, got \(events.last.map(String.init(describing:)) as Any)")
            return
        }
        #expect(result.sharpCount == 8)
        #expect(result.totalRecordCount == 8)

        let progressEvents = events.dropLast().compactMap { event -> BlurAnalysisProgress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }
        #expect(events.count == progressEvents.count + 1)
        #expect(!progressEvents.isEmpty)
        // The first tick carries the total; the last tick is the *forced* terminal event
        // (never a throttle casualty), and counts never move backwards.
        #expect(progressEvents.first?.completedUnits == 0)
        #expect(progressEvents.last?.totalUnits == 8)
        #expect(progressEvents.last?.completedUnits == progressEvents.last?.totalUnits)
        let completed = progressEvents.map(\.completedUnits)
        #expect(completed == completed.sorted())
    }

    @Test func cancellingARunSurfacesTheCancelledFailure() async throws {
        let records = (0..<8).map { blurRecord(id: String(format: "cancel-%02d", $0)) }
        let engine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: BlurProbe(),
            fallbackImage: blurFixtureSharpChecker,
            delayNanos: 100_000_000
        ))

        let task = Task { try await engine.analyze(records: records) }
        // 40 ms lands inside the first 100 ms worker wave — the run cannot have finished.
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected the cancelled run to throw .cancelled")
        } catch let failure as BlurAnalysisFailure {
            #expect(failure == .cancelled)
        } catch {
            Issue.record("expected BlurAnalysisFailure.cancelled, got \(error)")
        }
    }

    @Test func workerWidthNeverExceedsTheConfiguredBound() async throws {
        let records = (0..<16).map { blurRecord(id: String(format: "w-%02d", $0)) }

        let wideProbe = BlurProbe()
        let wideEngine = BlurAnalysisEngine(thumbnailLoader: BlurEngineThumbnails(
            probe: wideProbe,
            fallbackImage: blurFixtureSharpChecker,
            delayNanos: 30_000_000
        ))
        _ = try await wideEngine.analyze(records: records)
        #expect(wideProbe.requestCount == 16)
        #expect(wideProbe.maxConcurrency <= 4)

        var configuration = BlurAnalysisConfiguration()
        configuration.maxConcurrentWorkers = 2
        let narrowProbe = BlurProbe()
        let narrowEngine = BlurAnalysisEngine(
            configuration: configuration,
            thumbnailLoader: BlurEngineThumbnails(
                probe: narrowProbe,
                fallbackImage: blurFixtureSharpChecker,
                delayNanos: 30_000_000
            )
        )
        _ = try await narrowEngine.analyze(records: records)
        #expect(narrowProbe.requestCount == 16)
        #expect(narrowProbe.maxConcurrency <= 2)
    }

    @Test func thermalPressureScalesTheEffectiveWorkerWidth() async throws {
        // Serious thermal pressure halves the configured bound: the width recorded by the
        // metrics is the *effective* width the run actually used, not the configured one.
        let records = (0..<8).map { blurRecord(id: String(format: "thermal-%02d", $0)) }
        var configuration = BlurAnalysisConfiguration()
        configuration.maxConcurrentWorkers = 4
        configuration.thermalState = { .serious }
        let metrics = BlurAnalysisMetrics()
        let engine = BlurAnalysisEngine(
            configuration: configuration,
            thumbnailLoader: BlurEngineThumbnails(
                probe: BlurProbe(),
                fallbackImage: blurFixtureSharpChecker,
                delayNanos: 10_000_000
            ),
            metrics: metrics
        )

        _ = try await engine.analyze(records: records)

        #expect(metrics.snapshot().counters[.workerWidth] == 2)
    }

    @Test func nominalThermalStateKeepsTheConfiguredWorkerWidth() async throws {
        // The policy is a no-op at nominal pressure — the pre-thermal behaviour, pinned.
        let records = (0..<8).map { blurRecord(id: String(format: "nominal-%02d", $0)) }
        var configuration = BlurAnalysisConfiguration()
        configuration.maxConcurrentWorkers = 4
        configuration.thermalState = { .nominal }
        let metrics = BlurAnalysisMetrics()
        let engine = BlurAnalysisEngine(
            configuration: configuration,
            thumbnailLoader: BlurEngineThumbnails(
                probe: BlurProbe(),
                fallbackImage: blurFixtureSharpChecker,
                delayNanos: 10_000_000
            ),
            metrics: metrics
        )

        _ = try await engine.analyze(records: records)

        #expect(metrics.snapshot().counters[.workerWidth] == 4)
    }

    @Test func instrumentationRecordsStagesCountersAndReasons() async throws {
        let records = [
            blurRecord(id: "sharp-01"),
            blurRecord(id: "blur-01"),
            blurRecord(id: "flat-01"),
            blurRecord(id: "vid-01", mediaType: .video),
            blurRecord(id: "cloud-01"),
        ]
        let metrics = BlurAnalysisMetrics()
        let engine = BlurAnalysisEngine(
            thumbnailLoader: BlurEngineThumbnails(
                probe: BlurProbe(),
                images: [
                    "sharp-01": blurFixtureSharpChecker,
                    "blur-01": blurFixtureBlurryScene,
                    "flat-01": blurFixtureFlat,
                ],
                failures: ["cloud-01": .onlyInICloud]
            ),
            metrics: metrics
        )

        let result = try await engine.analyze(records: records)
        let snapshot = metrics.snapshot()

        #expect(result.totalRecordCount == 5)
        // Wall clock of the whole run, recorded on the way out.
        #expect((snapshot.durations[.total] ?? 0) > 0)
        // Partition: five records in, one refused without a request, four attempted.
        #expect(snapshot.counters[.assetsConsidered] == 5)
        #expect(snapshot.counters[.refusedUpFront] == 1)
        #expect(snapshot.counters[.requestsAttempted] == 4)
        #expect(snapshot.counters[.requestsSucceeded] == 3)
        #expect(snapshot.counters[.requestsFailed] == 1)
        #expect(snapshot.counters[.requestsICloud] == 1)
        #expect(snapshot.counters[.requestsTimedOut, default: 0] == 0)
        // Two of the three fixtures are 128² — below the 256² analysis budget — so the
        // run had to upscale them. The counter exists to prove a real-device run doesn't.
        #expect(snapshot.counters[.renditionsBelowBudget] == 2)
        #expect(snapshot.counters[.workerWidth] == 4)
        // Stage timings: request wraps every attempt (stubbed loader → ~0 but recorded),
        // measure wraps real bitmap work, classify is arithmetic (>= 0 by construction).
        #expect(snapshot.durations[.request, default: -1] >= 0)
        #expect(snapshot.durations[.measure, default: 0] > 0)
        #expect(snapshot.durations[.classify, default: -1] >= 0)
        // Verdicts partition the judged assets.
        #expect(snapshot.counters[.judgedSharp] == 1)
        #expect(snapshot.counters[.judgedLikelyBlurry] == 1)
        #expect(snapshot.counters[.judgedInsufficient] == 1)
        #expect(snapshot.counters[.judgedBorderline, default: 0] == 0)
        // Progress: at least the unconditional start and terminal emissions.
        #expect(snapshot.counters[.progressTicks, default: 0] >= 2)
        // Unavailable reasons are a partition of the run's gaps, keyed by raw value.
        #expect(snapshot.reasons == [
            "notAnalyzable": 1,
            "contentOnlyInICloud": 1,
        ])
    }

    // MARK: Environment flow

    @Test func completionAdmitsCandidatesButNeverSelectsAnything() async {
        let (env, probe, _) = makeBlurEnv()
        env.startBlurAnalysis()
        await waitForBlurSettled(env)

        guard case .completed(let result) = env.blurAnalysisState else {
            Issue.record("expected completed, got \(env.blurAnalysisState)")
            return
        }
        #expect(result.candidates.map(\.assetID) == ["blur-01", "blur-02"])
        #expect(result.sharpCount == 4)
        #expect(result.insufficientInformationCount == 2)
        #expect(result.unavailableAssets == [
            PhotoAnalysisUnavailable(assetID: "vid-01", reason: .notAnalyzable),
            PhotoAnalysisUnavailable(assetID: "zero-01", reason: .invalidDimensions),
        ])
        #expect(result.totalRecordCount == 10)

        // Admission only: a completed pass marks nothing.
        #expect(env.blurSelection.selectedCount == 0)

        // Candidates are markable…
        env.blurSelection.setSelected(true, forAsset: "blur-01")
        #expect(env.blurSelection.selectedCount == 1)
        // …a photo outside the candidate set can never enter the selection, no matter what.
        env.blurSelection.setSelected(true, forAsset: "sharp-01")
        #expect(env.blurSelection.selectedCount == 1)
        env.blurSelection.setSelected(false, forAsset: "blur-01")
        #expect(env.blurSelection.selectedCount == 0)

        #expect(probe.modes == [.sharpness])
    }

    @Test func explicitSelectionBuildsAPlanAndDeselectionStalesIt() async {
        let (env, result) = await completedBlurEnv()

        env.mutateBlurSelection { $0.setSelected(true, forAsset: "blur-01") }
        #expect(env.blurSelection.selectedCount == 1)

        env.prepareDeletionPlan(from: .blurReview)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 1)
        #expect(plan.selectionSnapshot == ["blur-01"])
        // Blur review goes through the shared pipeline as plain items — never duplicate categories.
        #expect(plan.items.allSatisfy { $0.category == nil })
        #expect(plan.analysisSignature == BlurDataset.signature(in: result))
        #expect(plan.sessionToken == "session-1")

        env.mutateBlurSelection { $0.setSelected(false, forAsset: "blur-01") }
        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale after deselection, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.selectionChanged])
        #expect(env.blurSelection.selectedCount == 0)
    }

    @Test func resultChangeStalesThePlanWithoutTouchingTheSelection() async {
        let (env, result) = await completedBlurEnv()

        env.mutateBlurSelection { $0.setSelected(true, forAsset: "blur-01") }
        env.prepareDeletionPlan(from: .blurReview)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        // A different result (one more candidate than the plan was stamped with) supersedes
        // the dataset even though the selection itself never moved.
        let grown = BlurAnalysisResult(
            candidates: result.candidates + [
                BlurCandidate(assetID: "blur-04", verdict: .borderline, laplacianVariance: 0.005),
            ],
            unavailableAssets: result.unavailableAssets,
            sharpCount: result.sharpCount - 1,
            insufficientInformationCount: result.insufficientInformationCount,
            totalRecordCount: result.totalRecordCount,
            thresholdsUsed: result.thresholdsUsed
        )
        env.blurAnalysisState = .completed(grown)
        env.synchronizeBlurDataset()

        guard case .planStale(_, let reasons) = env.deletionState else {
            Issue.record("expected planStale after the result changed, got \(env.deletionState)")
            return
        }
        #expect(reasons == [.analysisChanged])
        #expect(env.blurSelection.selectedIDs == ["blur-01"])

        // The new candidate is now admitted (markable) — still not marked.
        env.blurSelection.setSelected(true, forAsset: "blur-04")
        #expect(env.blurSelection.selectedIDs == ["blur-01", "blur-04"])
    }

    @Test func startingAFreshPassSupersedesAnyPreparedPlan() async {
        let (env, _) = await completedBlurEnv()
        env.mutateBlurSelection { $0.setSelected(true, forAsset: "blur-01") }
        env.prepareDeletionPlan(from: .blurReview)
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }

        env.startBlurAnalysis()
        // The wipe is synchronous: a stale plan can never survive into a new pass.
        #expect(env.deletionState == .noSelection)
        #expect(env.blurSelection.selectedCount == 0)
        await waitForBlurSettled(env)
        #expect(env.blurSelection.selectedCount == 0)
    }

    /// P7: every progress tick re-fires the screen's state observation, which calls this —
    /// mid-run it must be a no-op (the run owns the dataset and its completion re-applies
    /// it once), never an O(catalog) reconcile against a dataset about to be superseded.
    @Test func syncingTheDatasetDuringARunIsANoOpUntilItSettles() {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        env.blurSelection.admitLibraryAssets(["blur-01"])
        env.blurSelection.setSelected(true, forAsset: "blur-01")

        env.synchronizeBlurDataset()

        #expect(env.blurSelection.selectedIDs == ["blur-01"])
    }

    @Test func refusingToBuildAPlanExplainsWhy() {
        // Sharpness analysis has not finished.
        let (running, _, _) = makeBlurEnv()
        running.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        running.blurSelection.admitLibraryAssets(["blur-01"])
        running.blurSelection.setSelected(true, forAsset: "blur-01")
        running.prepareDeletionPlan(from: .blurReview)
        #expect(running.deletionState == .failed(
            "Sharpness analysis has not finished. Analyze sharpness, then review again."
        ))

        // No completed catalog.
        let (noCatalog, _, _) = makeBlurEnv(state: .completed(blurCompletedResult))
        noCatalog.catalogState = .notStarted
        noCatalog.blurSelection.admitLibraryAssets(["blur-01"])
        noCatalog.blurSelection.setSelected(true, forAsset: "blur-01")
        noCatalog.prepareDeletionPlan(from: .blurReview)
        #expect(noCatalog.deletionState == .failed(
            "Your library scan has not finished. Scan your library, then review again."
        ))

        // Empty selection is the universal safe reset.
        let (empty, _, _) = makeBlurEnv(state: .completed(blurCompletedResult))
        empty.prepareDeletionPlan(from: .blurReview)
        #expect(empty.deletionState == .noSelection)
    }

    @Test func startingThePassWithoutPermissionOrCatalogFailsWithHonestMessages() {
        let (denied, _, _) = makeBlurEnv()
        denied.photoPermissionState = .denied
        denied.startBlurAnalysis()
        #expect(denied.blurAnalysisState == .failed(
            .underlying("Photos access is required to read your library.")
        ))

        let (noCatalog, _, _) = makeBlurEnv()
        noCatalog.catalogState = .notStarted
        noCatalog.startBlurAnalysis()
        #expect(noCatalog.blurAnalysisState == .failed(
            .underlying("Your library scan has not finished. Build your catalog, then try again.")
        ))
    }

    @Test func reopeningACompletedPassRunsNoSecondAnalysis() async {
        // Reopen with a completed result: reconcile only, measure nothing, admit again.
        let (env, probe, _) = makeBlurEnv(state: .completed(blurCompletedResult))

        let phase = PotentiallyBlurryPresentation.phase(
            permission: .authorized,
            catalog: env.catalogState,
            blur: env.blurAnalysisState
        )
        guard case .results(let shown) = phase else {
            Issue.record("expected results phase, got \(phase)")
            return
        }
        #expect(shown.candidates.map(\.assetID) == ["blur-01", "blur-02"])
        #expect(PotentiallyBlurryPresentation.showsAnalyzeButton(phase) == false)

        env.synchronizeBlurDataset() // exactly what the screen's onAppear does
        #expect(env.blurAnalysisState == .completed(blurCompletedResult))
        #expect(probe.requestCount == 0)
        env.blurSelection.setSelected(true, forAsset: "blur-01")
        #expect(env.blurSelection.selectedCount == 1)

        // A double-tap on Analyze cannot launch a second pass either.
        let (runningEnv, runningProbe, _) = makeBlurEnv()
        runningEnv.startBlurAnalysis()
        runningEnv.startBlurAnalysis() // second call meets the running guard
        await waitForBlurSettled(runningEnv)
        #expect(runningProbe.requestCount == 8) // one pass over the 8 analyzable records
    }

    @Test func reviewTabCountsAndFiltersAreDerivedFromTheResult() {
        let result = BlurFixture.result
        #expect(PotentiallyBlurryPresentation.tabCount(.all, result: result) == 5)
        #expect(PotentiallyBlurryPresentation.tabCount(.likelyBlurry, result: result) == 3)
        #expect(PotentiallyBlurryPresentation.tabCount(.borderline, result: result) == 2)

        #expect(BlurReviewTab.all.candidates(in: result).map(\.assetID)
            == ["blur-01", "blur-02", "blur-03", "blur-04", "blur-05"])
        #expect(BlurReviewTab.likelyBlurry.candidates(in: result).map(\.assetID)
            == ["blur-01", "blur-02", "blur-03"])
        #expect(BlurReviewTab.borderline.candidates(in: result).map(\.assetID)
            == ["blur-04", "blur-05"])

        // The empty result keeps every tab at zero — no crash, no phantom rows.
        let empty = BlurFixture.emptyResult
        #expect(PotentiallyBlurryPresentation.tabCount(.all, result: empty) == 0)
        #expect(PotentiallyBlurryPresentation.tabCount(.likelyBlurry, result: empty) == 0)
        #expect(PotentiallyBlurryPresentation.tabCount(.borderline, result: empty) == 0)
    }

    @Test func theBlurPassLeavesSimilarityAndTheScannerUntouched() async {
        let (env, probe, store) = makeBlurEnv()
        let analysisBefore = env.analysisState
        let catalogBefore = env.catalogState

        env.startBlurAnalysis()
        await waitForBlurSettled(env)

        // Similar Photos results are read-only input the blur pass never consumes…
        #expect(env.analysisState == analysisBefore)
        // …the catalog is neither rebuilt nor rewritten…
        #expect(env.catalogState == catalogBefore)
        #expect(store.saveCount == 0)
        // …every request stayed on the bounded verification rendition…
        #expect(probe.modes == [.sharpness])
        // …and the deletion pipeline was not entered.
        #expect(env.deletionState == .noSelection)
    }

    @Test func confirmedDeletionPrunesCandidatesInPlace() {
        let pruned = blurCompletedResult.removingAssets(["blur-01"])
        #expect(pruned.candidates.map(\.assetID) == ["blur-02"])
        #expect(pruned.unavailableAssets == blurCompletedResult.unavailableAssets)
        #expect(pruned.sharpCount == blurCompletedResult.sharpCount)
        #expect(pruned.insufficientInformationCount == blurCompletedResult.insufficientInformationCount)
        #expect(pruned.totalRecordCount == blurCompletedResult.totalRecordCount)
        #expect(blurCompletedResult.removingAssets([]) == blurCompletedResult)
    }

    /// A confirmed deletion can originate from another feature and carry identifiers the
    /// sharpness pass judged sharp — never candidates, so they fall out of nothing. This
    /// path used to fire a DEBUG assertion on exactly that shape; the result must come
    /// through byte-identical and the unrelated verdicts must stand.
    @Test func deletingASharpAssetFromAnotherFeatureLeavesTheBlurResultIntact() async {
        let (env, _, _) = makeBlurEnv(state: .completed(blurCompletedResult))
        env.selection.admitLibraryAssets(["sharp-01"])
        env.selection.setSelected(true, forAsset: "sharp-01")
        #expect(env.selection.selectedIDs == ["sharp-01"])

        env.prepareDeletionPlan(from: .similarPhotos)
        await waitForPlanReady(env)
        guard case .readyForReview(let plan) = env.deletionState else {
            Issue.record("expected readyForReview, got \(env.deletionState)")
            return
        }
        #expect(plan.count == 1)
        #expect(plan.selectionSnapshot == ["sharp-01"])

        env.beginConfirmation()
        await env.confirmDeletion()

        #expect(env.deletionState == .succeeded(DeletionSuccess(
            plannedCount: 1,
            verifiedRemovedCount: 1,
            remainingIDs: []
        )))
        // The sharpness result is untouched: sharp-01 was never in it, and the candidates,
        // unavailable reasons, and counters all stand as measured.
        guard case .completed(let blur) = env.blurAnalysisState else {
            Issue.record("expected blur to stay completed, got \(env.blurAnalysisState)")
            return
        }
        #expect(blur == blurCompletedResult)
        #expect(blur.candidates.map(\.assetID) == ["blur-01", "blur-02"])
        // The rest of the pipeline still took the confirmed removal.
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected catalog to stay completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.records.contains { $0.localIdentifier == "sharp-01" } == false)
        #expect(env.selection.selectedIDs.isEmpty)
    }

    // MARK: M14 — concurrent, independent photo analysis (no queue, no cancel-and-switch)

    /// The recording regression (M13B → M14): with the sharpness pass running alone and the
    /// completed catalog standing, a Similar Photos request starts **immediately over that
    /// catalog** — concurrently with the running pass. It never queues behind the pass,
    /// never cancels it, and never re-enumerates the library.
    @Test func similarityStartsConcurrentlyWhileTheSharpnessPassIsRunning() {
        let (env, _, _) = makeBlurEnv()
        let running = BlurAnalysisProgress(completedUnits: 1, totalUnits: 4)
        env.blurAnalysisState = .running(running)
        let catalogBefore = env.catalogState

        env.startSimilarityAnalysis()

        // Admitted immediately: the pass is running — not queued, not failed, not dropped.
        #expect(env.analysisState.isRunning)
        // The sharpness pass is untouched — concurrent, never cancelled by the start.
        #expect(env.blurAnalysisState == .running(running))
        // The standing catalog is adopted as-is: the same snapshot the pass stands on.
        #expect(env.catalogState == catalogBefore)
    }

    /// The concurrent similarity pass over the standing catalog actually runs Stage B and
    /// lands a real result — admission without a queue, verified to completion.
    @Test func theConcurrentSimilarityRunOverTheStandingCatalogCompletes() async {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))

        env.startSimilarityAnalysis()
        await waitForSimilaritySettled(env)

        guard case .completed = env.analysisState else {
            Issue.record("expected the concurrent similarity run to complete, got \(env.analysisState)")
            return
        }
        // The sharpness pass was never cancelled by the concurrent start.
        #expect(env.blurAnalysisState.isRunning)
    }

    /// Adopting the standing catalog never re-enumerates the library: the reader factory is
    /// not called again — the concurrent pass analyzes the same snapshot, one read total.
    @Test func concurrentSimilarityAdoptionNeverReEnumeratesTheLibrary() {
        let probe = BlurProbe()
        let store = InMemoryScanSnapshotStore()
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            photoPermission: FakePermissionService(.authorized),
            makePhotoLibrary: { FakeLibrary(records: blurFixtureRecords) },
            thumbnailLoader: BlurEngineThumbnails(probe: probe, fallbackImage: blurFixtureSharpChecker),
            sizeProvider: FakeSizeProvider(sizes: [:]),
            deletionService: RecordingDeletionService(outcome: .succeeded(DeletionSuccess(
                plannedCount: 1,
                verifiedRemovedCount: 1,
                remainingIDs: []
            ))),
            scanSnapshotStore: store,
            sessionToken: "session-1"
        )
        env.photoPermissionState = .authorized
        env.catalogState = .completed(CatalogScanResult(
            records: blurFixtureRecords,
            libraryAssetCount: blurFixtureRecords.count,
            accessLevel: .authorized
        ))
        env.analysisState = .completed(similarPhotosFixtureResult)
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))

        env.startSimilarityAnalysis()

        // Adopted the standing catalog — running without any new enumeration (the factory
        // above would have to be called again for a second read).
        #expect(env.analysisState.isRunning)
        #expect(env.catalogState == .completed(CatalogScanResult(
            records: blurFixtureRecords,
            libraryAssetCount: blurFixtureRecords.count,
            accessLevel: .authorized
        )))
    }

    /// The admission rule is symmetric: while a similarity run is mid-enumeration (no
    /// completed catalog yet), a sharpness request is admitted **immediately** into a
    /// bounded wait for that read — it never queues, never fails the tap away, and starts
    /// the moment the catalog stands.
    @Test func sharpnessPassStartsOnceTheConcurrentlyReadCatalogLands() async {
        let (env, _, _) = makeBlurEnv()
        // The similarity pass is mid Stage A: running, with no completed catalog standing.
        env.catalogState = .notStarted
        env.analysisState = .notStarted
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)
        if case .completed = env.catalogState {
            Issue.record("catalog should still be mid-read, not completed")
        }

        env.startBlurAnalysis()

        // Admitted into the bounded wait — running, not queued, not failed.
        #expect(env.blurAnalysisState.isRunning)
        // The similarity pass keeps its pipeline — the wait never cancels it.
        #expect(env.analysisState.isRunning)

        // The read lands: the waiting pass starts over that catalog and both settle.
        await waitForBlurSettled(env)
        await waitForSimilaritySettled(env)
        guard case .completed = env.blurAnalysisState else {
            Issue.record("expected the waiting sharpness pass to complete over the landed catalog, got \(env.blurAnalysisState)")
            return
        }
        guard case .completed = env.analysisState else {
            Issue.record("expected the similarity pass to complete, got \(env.analysisState)")
            return
        }
        guard case .completed = env.catalogState else {
            Issue.record("expected the shared catalog to stand, got \(env.catalogState)")
            return
        }
    }

    /// With the completed catalog already standing and a similarity pass running, a
    /// sharpness request starts immediately over that snapshot — concurrent, never queued.
    @Test func sharpnessPassStartsConcurrentlyWhileSimilarityIsRunning() {
        let (env, _, _) = makeBlurEnv()
        let similarityRunning = PhotoAnalysisProgress(stage: .comparing, completedUnits: 1, totalUnits: 4)
        env.analysisState = .running(similarityRunning)
        let catalogBefore = env.catalogState

        env.startBlurAnalysis()

        #expect(env.blurAnalysisState.isRunning)
        // The similarity pass is untouched.
        #expect(env.analysisState == .running(similarityRunning))
        // Adopted the standing catalog — no second enumeration, no failed substitution.
        #expect(env.catalogState == catalogBefore)
    }

    /// THE unified-entry recording scenario: `startImageAnalysis()` with exactly one
    /// pipeline running (sharpness alone) starts the idle similarity pass **concurrently**
    /// over the running pass's catalog — it never queues the request (M10's behavior) and
    /// never cancels the pass still doing work.
    @Test func startImageAnalysisWithExactlyOnePipelineRunningStartsTheIdleOneConcurrently() {
        let (env, _, _) = makeBlurEnv()
        let running = BlurAnalysisProgress(completedUnits: 1, totalUnits: 4)
        env.blurAnalysisState = .running(running)

        env.startImageAnalysis()

        // The idle pipeline starts immediately — concurrently, not queued.
        #expect(env.analysisState.isRunning)
        // The running pipeline is never cancelled or superseded.
        #expect(env.blurAnalysisState == .running(running))
    }

    /// Symmetric unified-entry scenario: with similarity alone running (mid-enumeration),
    /// the Analyze tap admits the sharpness pass into the bounded wait — both run to
    /// completion, neither is cancelled by the other.
    @Test func startImageAnalysisWhileSimilarityIsMidEnumerationAdmitsBlurConcurrently() async {
        let (env, _, _) = makeBlurEnv()
        env.catalogState = .notStarted
        env.analysisState = .notStarted
        env.startImageAnalysis()

        // Both pipelines are running: similarity over the shared read, blur boundedly
        // waiting for it — concurrent admission, no queue, no cancel-and-switch.
        #expect(env.analysisState.isRunning)
        #expect(env.blurAnalysisState.isRunning)

        await waitForBlurSettled(env)
        await waitForSimilaritySettled(env)
        guard case .completed = env.blurAnalysisState else {
            Issue.record("expected the sharpness pass to complete, got \(env.blurAnalysisState)")
            return
        }
        guard case .completed = env.analysisState else {
            Issue.record("expected the similarity pass to complete, got \(env.analysisState)")
            return
        }
    }

    /// Cancelling the sharpness pass is its own business: the concurrently admitted
    /// similarity pass keeps running and completes — the cancel path is scoped per kind.
    @Test func cancellingTheSharpnessPassLeavesTheConcurrentSimilarityPassRunning() async {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)

        env.cancelBlurAnalysis()

        #expect(env.blurAnalysisState == .cancelled)
        #expect(env.analysisState.isRunning)
        await waitForSimilaritySettled(env)
        guard case .completed = env.analysisState else {
            Issue.record("expected the concurrent similarity pass to complete after the blur cancel, got \(env.analysisState)")
            return
        }
    }

    /// The symmetric cancel: cancelling the similarity pass leaves the concurrently
    /// running sharpness pass untouched.
    @Test func cancellingTheSimilarityPassLeavesTheConcurrentSharpnessPassRunning() {
        let (env, _, _) = makeBlurEnv()
        env.analysisState = .running(PhotoAnalysisProgress(stage: .comparing, completedUnits: 1, totalUnits: 4))
        env.startBlurAnalysis()
        #expect(env.blurAnalysisState.isRunning)

        env.cancelSimilarityAnalysis()

        #expect(env.analysisState == .cancelled)
        #expect(env.blurAnalysisState.isRunning)
    }

    /// Failing one concurrent pass never touches the other: the surfaces are independent.
    @Test func failingOneConcurrentPassLeavesTheOtherRunning() {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)

        env.blurAnalysisState = .failed(.cancelled)

        #expect(env.analysisState.isRunning)
    }

    /// Repeated Analyze taps while both pipelines already run are idempotent — the session
    /// already satisfies the request; nothing restarts or is double-admitted.
    @Test func repeatTapsWhileBothPipelinesRunAreIdempotent() {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        env.startSimilarityAnalysis()
        let similarityState = env.analysisState
        let blurState = env.blurAnalysisState

        env.startSimilarityAnalysis()
        env.startBlurAnalysis()
        env.startImageAnalysis()

        #expect(env.analysisState == similarityState)
        #expect(env.blurAnalysisState == blurState)
    }

    /// A same-kind repeat start while the pass is running is a guarded no-op — never a
    /// second job, never a state reset underneath the in-flight run.
    @Test func repeatedStartsOfTheSamePassAreGuardedNoOps() {
        let (env, _, _) = makeBlurEnv()
        env.blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 1, totalUnits: 4))
        env.startSimilarityAnalysis()
        let running = env.analysisState

        env.startSimilarityAnalysis()
        env.startSimilarityAnalysis()

        #expect(env.analysisState == running)
        #expect(env.blurAnalysisState.isRunning)
    }

    /// The bounded wait fails honestly when the catalog never lands: cancelling the
    /// similarity pass mid-read leaves no catalog coming, and the waiting sharpness pass
    /// reports "Your library scan has not finished" rather than hanging or queueing.
    @Test func theWaitingSharpnessPassFailsHonestlyWhenTheCatalogNeverLands() async {
        let (env, _, _) = makeBlurEnv()
        env.catalogState = .notStarted
        env.analysisState = .notStarted
        env.startSimilarityAnalysis()
        env.startBlurAnalysis()
        #expect(env.blurAnalysisState.isRunning)

        // The only read that could produce the catalog is cancelled: no standing catalog
        // is coming.
        env.cancelSimilarityAnalysis()

        // The bounded wait observes the honest terminal within its poll interval.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while env.blurAnalysisState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(env.blurAnalysisState == .failed(
            .underlying("Your library scan has not finished. Build your catalog, then try again.")
        ))
        #expect(env.analysisState == .cancelled)
    }

    /// Deletion reconciliation survives concurrent admission (M13 → M14): starting the
    /// second pipeline over the running pass's catalog never restarts or supersedes the
    /// running pass — its in-flight stage and progress are untouched.
    @Test func concurrentAdmissionNeverCancelsOrRestartsTheOtherPass() {
        let (env, _, _) = makeBlurEnv()
        // Similarity mid-run (comparing, mid-progress); the sharpness pass is admitted
        // concurrently over its catalog.
        let midRun = PhotoAnalysisProgress(stage: .comparing, completedUnits: 2, totalUnits: 4)
        env.analysisState = .running(midRun)

        env.startBlurAnalysis()
        #expect(env.blurAnalysisState.isRunning)

        // The similarity pass keeps its exact stage and progress: a restart would have
        // flipped it back to `preparing`, a cancel would have flipped it to `.cancelled`.
        #expect(env.analysisState == .running(midRun))
    }

    /// M13 → M14: a confirmed deletion that lands while BOTH passes run is recorded and
    /// reconciled out of *both* results when they land — and admitting the second pass
    /// concurrently (which sets up its own run while the first is mid-flight) must never
    /// clear the first pass's recorded removals. The deleted photo therefore appears in
    /// neither completed result, and no pass is cancelled or restarted by the mutation.
    @Test func aDeletionDuringConcurrentPassesReconcilesBothResults() async {
        // Slow thumbnails so both real passes are still in flight when the deletion lands.
        let (env, _, _) = makeBlurEnv(thumbnailDelayNanos: 250_000_000)
        env.startBlurAnalysis()
        #expect(env.blurAnalysisState.isRunning)
        // Concurrent admission (M14): the similarity pass adopts the standing catalog and
        // starts over the same snapshot while the sharpness pass runs.
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)

        // Delete blur-01 (a photo both passes will report) through the real pipeline.
        env.mutateSelection {
            $0.admitLibraryAssets(["blur-01"])
            $0.setSelected(true, forAsset: "blur-01")
        }
        env.prepareDeletionPlan()
        await waitForPlanReady(env)
        guard case .readyForReview = env.deletionState else {
            Issue.record("expected readyForReview while both passes run, got \(env.deletionState)")
            return
        }
        env.beginConfirmation()
        await env.confirmDeletion()
        guard case .succeeded = env.deletionState else {
            Issue.record("expected succeeded, got \(env.deletionState)")
            return
        }
        // The mutation cancelled neither pass (M13): both are still finishing their work.
        #expect(env.blurAnalysisState.isRunning)
        #expect(env.analysisState.isRunning)

        await waitForBlurSettled(env)
        await waitForSimilaritySettled(env)

        guard case .completed(let blur) = env.blurAnalysisState else {
            Issue.record("expected the sharpness pass to complete, got \(env.blurAnalysisState)")
            return
        }
        // The deleted photo is reconciled out of the sharpness result — its work for the
        // surviving photo stands (no full re-run).
        #expect(blur.candidates.map(\.assetID) == ["blur-02"])
        #expect(blur.unavailableAssets.allSatisfy { $0.assetID != "blur-01" })

        guard case .completed(let similarity) = env.analysisState else {
            Issue.record("expected the similarity pass to complete, got \(env.analysisState)")
            return
        }
        let grouped = Set(
            (similarity.exactGroups + similarity.similarGroups).flatMap(\.memberAssetIDs)
        )
        #expect(!grouped.contains("blur-01"))
    }

    // MARK: Derived-cache correctness (the grid's record cache)

    @Test func blurDatasetRecordsAreCatalogOrderedAndInputValidated() async {
        let (env, result) = await completedBlurEnv()
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("fixture env did not complete its catalog")
            return
        }
        #expect(!result.candidates.isEmpty)

        // Exactly the reference filter, in catalog order — cached, but never wrong.
        let candidateIDs = Set(result.candidates.map(\.assetID))
        let reference = catalog.records.filter { candidateIDs.contains($0.localIdentifier) }
        #expect(env.blurDatasetRecords == reference)
        // Reading again serves the same content — the cache-hit path.
        #expect(env.blurDatasetRecords == reference)

        // A pruned catalog drops the removed candidate on the next read.
        let removedID = result.candidates[0].assetID
        env.catalogState = .completed(catalog.removingAssetIDs([removedID]))
        #expect(!env.blurDatasetRecords.contains { $0.localIdentifier == removedID })

        // Either input leaving its completed state empties the cache…
        env.blurAnalysisState = .notStarted
        #expect(env.blurDatasetRecords.isEmpty)
        // …a completed analysis over no catalog stays empty…
        env.blurAnalysisState = .completed(result)
        env.catalogState = .notStarted
        #expect(env.blurDatasetRecords.isEmpty)
        // …and restoring both inputs rebuilds the full dataset.
        env.catalogState = .completed(catalog)
        #expect(env.blurDatasetRecords == reference)
    }
}

// MARK: - Fixtures

private func blurRecord(
    id: String,
    mediaType: PhotoMediaType = .image,
    width: Int = 1290,
    height: Int = 2796
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: [],
        pixelWidth: width,
        pixelHeight: height,
        creationDate: Date(timeIntervalSince1970: 1_760_000_000),
        modificationDate: nil,
        duration: 0,
        isFavorite: false,
        isHidden: false,
        sourceType: [.library],
        hasAdjustments: false,
        representsBurst: false,
        burstIdentifier: nil
    )
}

/// The catalog every environment fixture runs over: four sharp images, two blurry ones, a
/// flat frame, a low-light frame, a video, and an image with zero dimensions — ten records,
/// eight of them analyzable.
private let blurFixtureRecords: [PhotoAssetRecord] = [
    blurRecord(id: "sharp-01"),
    blurRecord(id: "blur-01"),
    blurRecord(id: "flat-01"),
    blurRecord(id: "blur-02"),
    blurRecord(id: "sharp-02"),
    blurRecord(id: "dark-01"),
    blurRecord(id: "sharp-03"),
    blurRecord(id: "blur-04"),
    blurRecord(id: "vid-01", mediaType: .video),
    blurRecord(id: "zero-01", width: 0, height: 0),
]

/// The exact result a real pass over `blurFixtureRecords` produces (verdict-level; the
/// variance values here are documentation, not asserted against measurement).
private let blurCompletedResult = BlurAnalysisResult(
    candidates: [
        BlurCandidate(assetID: "blur-01", verdict: .likelyBlurry, laplacianVariance: 0.000_014),
        BlurCandidate(assetID: "blur-02", verdict: .likelyBlurry, laplacianVariance: 0.000_014),
    ],
    unavailableAssets: [
        PhotoAnalysisUnavailable(assetID: "vid-01", reason: .notAnalyzable),
        PhotoAnalysisUnavailable(assetID: "zero-01", reason: .invalidDimensions),
    ],
    sharpCount: 4,
    insufficientInformationCount: 2,
    totalRecordCount: 10,
    thresholdsUsed: .corpusCalibrated,
    scannedAt: blurScanDate
)

/// The pinned clock every completed engine run in this suite is stamped with, so a
/// result equals the fixture exactly — dates included.
private let blurScanDate = Date(timeIntervalSince1970: 1_760_000_500)

/// Similarity results the blur pass must leave completely alone.
private let similarPhotosFixtureResult = PhotoAnalysisResult(
    exactGroups: [],
    similarGroups: [],
    unavailableAssets: [],
    descriptorKind: nil,
    visionAvailable: false,
    similarityThreshold: nil,
    totalRecordCount: 10,
    candidateBucketCount: 0,
    candidatePairCount: 0
)

// MARK: - Environment

@MainActor
private func makeBlurEnv(
    state: BlurAnalysisState = .notStarted,
    thumbnailDelayNanos: UInt64 = 0
) -> (env: AppEnvironment, probe: BlurProbe, store: InMemoryScanSnapshotStore) {
    let probe = BlurProbe()
    let store = InMemoryScanSnapshotStore()
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        makePhotoLibrary: { FakeLibrary(records: blurFixtureRecords) },
        thumbnailLoader: BlurEngineThumbnails(
            probe: probe,
            images: [
                "sharp-01": blurFixtureSharpChecker,
                "sharp-02": blurFixtureScene,
                "sharp-03": blurFixtureWideChecker,
                "blur-04": blurFixtureStrongNoise, // textured on the first pass → sharp
                "blur-01": blurFixtureBlurryScene,
                "blur-02": blurFixtureBlurryScene,
                "flat-01": blurFixtureFlat,
                "dark-01": blurFixtureDarkNoise,
            ],
            delayNanos: thumbnailDelayNanos
        ),
        sizeProvider: FakeSizeProvider(sizes: [
            "blur-01": 700,
            "blur-02": 800,
            "blur-04": 900,
        ]),
        deletionService: RecordingDeletionService(outcome: .succeeded(DeletionSuccess(
            plannedCount: 1,
            verifiedRemovedCount: 1,
            remainingIDs: []
        ))),
        // Completions in this suite must never touch the app's real persisted snapshot.
        scanSnapshotStore: store,
        sessionToken: "session-1"
    )
    env.photoPermissionState = .authorized
    env.blurAnalysisClock = { blurScanDate }
    env.catalogState = .completed(CatalogScanResult(
        records: blurFixtureRecords,
        libraryAssetCount: blurFixtureRecords.count,
        accessLevel: .authorized
    ))
    env.analysisState = .completed(similarPhotosFixtureResult)
    env.blurAnalysisState = state
    return (env, probe, store)
}

/// Runs a fresh pass to completion and hands back the environment with its result.
@MainActor
private func completedBlurEnv() async -> (env: AppEnvironment, result: BlurAnalysisResult) {
    let (env, _, _) = makeBlurEnv()
    env.startBlurAnalysis()
    await waitForBlurSettled(env)
    guard case .completed(let result) = env.blurAnalysisState else {
        Issue.record("blur run did not settle into completed: \(env.blurAnalysisState)")
        return (env, .empty)
    }
    return (env, result)
}

@MainActor
private func waitForBlurSettled(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 5_000
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while env.blurAnalysisState.isRunning, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    if env.blurAnalysisState.isRunning {
        Issue.record("blur analysis still running after timeout: \(env.blurAnalysisState)")
    }
}

@MainActor
private func waitForSimilaritySettled(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 5_000
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while env.analysisState.isRunning, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    if env.analysisState.isRunning {
        Issue.record("similarity analysis still running after timeout: \(env.analysisState)")
    }
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

/// Records every thumbnail request (id + mode) and the maximum number of in-flight
/// requests observed — the two facts the pipeline tests must prove: the bounded rendition
/// policy, and the fixed worker width.
private final class BlurProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var peakInFlight = 0
    private var log: [(assetID: String, mode: PhotoThumbnailRequestMode)] = []

    func beginRequest(_ assetID: String, mode: PhotoThumbnailRequestMode) {
        lock.lock()
        log.append((assetID, mode))
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        lock.unlock()
    }

    func endRequest() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return log.count
    }

    var maxConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakInFlight
    }

    var modes: Set<PhotoThumbnailRequestMode> {
        lock.lock()
        defer { lock.unlock() }
        return Set(log.map(\.mode))
    }

    func requestedIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log.map(\.assetID)
    }
}

/// Scriptable thumbnail delivery over synthetic images. `@unchecked Sendable` because the
/// fixture `CGImage`s are immutable and every mutable byte lives behind `BlurProbe`'s lock.
private struct BlurEngineThumbnails: PhotoThumbnailLoading, @unchecked Sendable {
    let probe: BlurProbe
    var images: [String: CGImage] = [:]
    var fallbackImage: CGImage?
    var failures: [String: PhotoContentError] = [:]
    var timeoutIDs: Set<String> = []
    var delayNanos: UInt64 = 0

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        probe.beginRequest(assetID, mode: mode)
        defer { probe.endRequest() }
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        if timeoutIDs.contains(assetID) {
            throw PhotoRequestTimeoutError()
        }
        if let failure = failures[assetID] {
            throw failure
        }
        if let image = images[assetID] {
            return image
        }
        if let fallback = fallbackImage {
            return fallback
        }
        throw PhotoContentError.unavailable
    }
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

/// The sharpness pass's Phase C contract: a restored checkpoint presents a paused card
/// without issuing a single request; resume reuses the saved verdicts (measured at
/// engine level through the sink, so the evidence is real rather than fabricated);
/// a calibration mismatch refuses the verdicts outright; a candidate without its score
/// re-measures (review must be able to explain itself); and a blur resume with no fresh
/// catalog chains a rebuild first and still completes with the carried payload.
@MainActor
struct BlurCheckpointFlowTests {
    @Test func restoredCheckpointPresentsPausedBlurStateWithoutAnyRequest() async throws {
        let checkpoint = try await capturedBlurCheckpoint()
        let (env, probe, store) = makeCheckpointBlurEnv(checkpoint: checkpoint)

        await env.bootstrap()

        guard case .paused(let progress) = env.blurAnalysisState else {
            Issue.record("expected paused after restore, got \(env.blurAnalysisState)")
            return
        }
        #expect(progress.completedUnits == checkpoint.completedUnits)
        #expect(progress.totalUnits == checkpoint.totalUnits)
        #expect(probe.requestCount == 0)
        #expect(store.load() == checkpoint)
    }

    /// M13: a relaunch restores *every* interrupted pass, each from its own checkpoint file.
    /// The two concurrent pipelines own independent channels, so a similarity interruption
    /// and a sharpness interruption survive together — both surfaces present paused, and the
    /// stored files stay kind-addressed (one does not clobber the other).
    @Test func aRelaunchRestoresBothInterruptedPipelinesIndependently() async throws {
        let similarity = ScanCheckpoint(
            runSequence: 1,
            kind: .similarity,
            startedAt: Date(),
            updatedAt: Date(),
            stage: PhotoAnalysisStage.fingerprinting.rawValue,
            completedUnits: 3,
            totalUnits: 10
        )
        let blur = try await capturedBlurCheckpoint()
        let store = InMemoryScanCheckpointStore()
        try store.save(similarity)
        try store.save(blur)

        let probe = BlurProbe()
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            photoPermission: FakePermissionService(.authorized),
            contactsPermission: BlurCheckpointContactsPermissionService(),
            makePhotoLibrary: { FakeLibrary(records: blurFixtureRecords) },
            thumbnailLoader: BlurEngineThumbnails(probe: probe, images: blurCheckpointImages),
            sizeProvider: FakeSizeProvider(sizes: [:]),
            deletionService: RecordingDeletionService(outcome: .succeeded(DeletionSuccess(
                plannedCount: 1,
                verifiedRemovedCount: 1,
                remainingIDs: []
            ))),
            scanSnapshotStore: InMemoryScanSnapshotStore(),
            checkpointStore: store,
            sessionToken: "session-1"
        )
        env.photoPermissionState = .authorized
        env.blurAnalysisClock = { blurScanDate }

        await env.bootstrap()

        // Each surface is paused from its own file — neither restore cancels or overwrites
        // the other.
        guard case .paused(let similarityProgress) = env.analysisState else {
            Issue.record("expected paused similarity, got \(env.analysisState)")
            return
        }
        #expect(similarityProgress.stage == .fingerprinting)
        #expect(similarityProgress.completedUnits == 3)
        guard case .paused(let blurProgress) = env.blurAnalysisState else {
            Issue.record("expected paused sharpness pass, got \(env.blurAnalysisState)")
            return
        }
        #expect(blurProgress.completedUnits == blur.completedUnits)
        #expect(probe.requestCount == 0)
        // Both files are still present and kind-addressed after the restore.
        #expect(store.load(kind: .similarity) == similarity)
        #expect(store.load(kind: .blur) == blur)
    }

    @Test func resumeReusesSavedVerdictsAndCompletesWithoutRequestingThem() async throws {
        let baseline = await freshBlurBaseline()
        #expect(baseline.requests == 8)

        let checkpoint = try await capturedBlurCheckpoint()
        let (env, probe, store) = makeCheckpointBlurEnv(checkpoint: checkpoint)
        await env.bootstrap()
        guard case .paused = env.blurAnalysisState else {
            Issue.record("expected paused after restore, got \(env.blurAnalysisState)")
            return
        }

        env.resumeInterruptedWork()
        guard let resumed = await resumedBlurResult(env) else { return }

        #expect(probe.requestCount == 0)
        #expect(resumed == baseline.result)
        #expect(store.load() == nil)
    }

    @Test func thresholdsMismatchRefusesSavedVerdictsAndMeasuresEverythingAgain() async throws {
        let baseline = await freshBlurBaseline()

        let captured = try await capturedBlurCheckpoint()
        // Same shape, different calibration: `blurSeed` refuses the payload before the
        // engine ever sees it, so the pass is a full fresh measurement — never a mix.
        let mismatched = ScanCheckpoint(
            runSequence: captured.runSequence,
            kind: captured.kind,
            startedAt: captured.startedAt,
            updatedAt: captured.updatedAt,
            stage: captured.stage,
            completedUnits: captured.completedUnits,
            totalUnits: captured.totalUnits,
            blurVerdicts: captured.blurVerdicts,
            blurThresholds: BlurThresholds(
                sharpMinVariance: 0.015,
                blurryMaxVariance: 5e-4,
                blurryMaxTenengrad: 5.0e-2,
                minLuma: 0.08,
                minTextureStdDev: 0.015
            )
        )
        let (env, probe, store) = makeCheckpointBlurEnv(checkpoint: mismatched)
        await env.bootstrap()
        guard case .paused = env.blurAnalysisState else {
            Issue.record("expected paused after restore, got \(env.blurAnalysisState)")
            return
        }

        env.resumeInterruptedWork()
        guard let resumed = await resumedBlurResult(env) else { return }

        #expect(probe.requestCount == baseline.requests)
        #expect(resumed == baseline.result)
        #expect(store.load() == nil)
    }

    @Test func aCandidateWithoutItsScoreIsMeasuredAgainOnResume() async throws {
        let baseline = await freshBlurBaseline()

        let captured = try await capturedBlurCheckpoint()
        // Review shows a candidate's score — an entry without one cannot explain itself,
        // so those specific verdicts are dropped from the seed and re-measured; every
        // other verdict (sharp, insufficient) is still reused.
        let partial = ScanCheckpoint(
            runSequence: captured.runSequence,
            kind: captured.kind,
            startedAt: captured.startedAt,
            updatedAt: captured.updatedAt,
            stage: captured.stage,
            completedUnits: captured.completedUnits,
            totalUnits: captured.totalUnits,
            blurVerdicts: captured.blurVerdicts.map { entry in
                guard entry.verdict.isCandidate else { return entry }
                return BlurVerdictEntry(
                    assetID: entry.assetID,
                    modified: entry.modified,
                    verdict: entry.verdict,
                    laplacianVariance: nil
                )
            },
            blurThresholds: captured.blurThresholds
        )
        let (env, probe, store) = makeCheckpointBlurEnv(checkpoint: partial)
        await env.bootstrap()
        guard case .paused = env.blurAnalysisState else {
            Issue.record("expected paused after restore, got \(env.blurAnalysisState)")
            return
        }

        env.resumeInterruptedWork()
        guard let resumed = await resumedBlurResult(env) else { return }

        // Exactly the two candidates came back for measurement — nothing else.
        #expect(Set(probe.requestedIDs()) == ["blur-01", "blur-02"])
        #expect(probe.requestCount == 2)
        #expect(resumed == baseline.result)
        #expect(store.load() == nil)
    }

    @Test func resumeWithoutACompletedCatalogRebuildsFirstThenCompletesTheBlurPass() async throws {
        let baseline = await freshBlurBaseline()

        let checkpoint = try await capturedBlurCheckpoint()
        let (env, probe, store) = makeCheckpointBlurEnv(
            checkpoint: checkpoint,
            catalogCompleted: false
        )
        await env.bootstrap()
        guard case .paused = env.blurAnalysisState else {
            Issue.record("expected paused after restore, got \(env.blurAnalysisState)")
            return
        }
        #expect(probe.requestCount == 0)

        env.resumeInterruptedWork()

        // The chained rebuild reads through the library fixture, never the blur probe —
        // and the blur pass itself starts only after the catalog lands.
        #expect(probe.requestCount == 0)
        guard let resumed = await resumedBlurResult(env) else { return }
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("expected a completed chained catalog, got \(env.catalogState)")
            return
        }

        #expect(catalog.records.count == blurFixtureRecords.count)
        #expect(probe.requestCount == 0)
        #expect(resumed == baseline.result)
        #expect(store.load() == nil)
    }
}

// MARK: - Checkpoint fixtures and helpers

/// The same eight analyzable fixture images `makeBlurEnv` serves — one map so an
/// engine-level capture and an environment-level resume classify identically.
private let blurCheckpointImages: [String: CGImage] = [
    "sharp-01": blurFixtureSharpChecker,
    "sharp-02": blurFixtureScene,
    "sharp-03": blurFixtureWideChecker,
    "blur-04": blurFixtureStrongNoise,
    "blur-01": blurFixtureBlurryScene,
    "blur-02": blurFixtureBlurryScene,
    "flat-01": blurFixtureFlat,
    "dark-01": blurFixtureDarkNoise,
]

/// Runs one real sharpness pass over the fixture records at engine level and returns
/// exactly what an interruption at completion would have persisted: the verdicts the
/// sink produced (variances included), under the default calibration.
private func capturedBlurCheckpoint() async throws -> ScanCheckpoint {
    let probe = BlurProbe()
    let sink = BlurEvidenceBox()
    let engine = BlurAnalysisEngine(
        configuration: BlurAnalysisConfiguration(),
        thumbnailLoader: BlurEngineThumbnails(probe: probe, images: blurCheckpointImages),
        now: { blurScanDate },
        checkpointSink: { sink.append($0) }
    )
    for try await event in engine.makeAnalysisStream(records: blurFixtureRecords) {
        if case .completed = event { break }
    }
    let entries = sink.evidence.compactMap { evidence -> BlurVerdictEntry? in
        guard case .blurVerdict(let assetID, let modified, let verdict, let variance) = evidence
        else { return nil }
        return BlurVerdictEntry(
            assetID: assetID,
            modified: modified,
            verdict: verdict,
            laplacianVariance: variance
        )
    }
    try #require(entries.count == 8, "expected one verdict per analyzable record, got \(entries.count)")
    return ScanCheckpoint(
        runSequence: 7,
        kind: .blur,
        startedAt: Date(timeIntervalSince1970: 1_760_000_400),
        updatedAt: Date(timeIntervalSince1970: 1_760_000_450),
        completedUnits: entries.count,
        totalUnits: blurFixtureRecords.count,
        blurVerdicts: entries.sorted { $0.assetID < $1.assetID },
        blurThresholds: BlurAnalysisConfiguration().thresholds
    )
}

/// Environment over the same fixture images, optionally pre-loaded with an interrupted
/// checkpoint (and optionally without a completed catalog, to exercise the chained path).
@MainActor
private func makeCheckpointBlurEnv(
    checkpoint: ScanCheckpoint? = nil,
    catalogCompleted: Bool = true
) -> (env: AppEnvironment, probe: BlurProbe, store: InMemoryScanCheckpointStore) {
    let probe = BlurProbe()
    let checkpointStore = InMemoryScanCheckpointStore()
    if let checkpoint {
        try? checkpointStore.save(checkpoint)
    }
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: FakePermissionService(.authorized),
        contactsPermission: BlurCheckpointContactsPermissionService(),
        makePhotoLibrary: { FakeLibrary(records: blurFixtureRecords) },
        thumbnailLoader: BlurEngineThumbnails(probe: probe, images: blurCheckpointImages),
        sizeProvider: FakeSizeProvider(sizes: [
            "blur-01": 700,
            "blur-02": 800,
            "blur-04": 900,
        ]),
        deletionService: RecordingDeletionService(outcome: .succeeded(DeletionSuccess(
            plannedCount: 1,
            verifiedRemovedCount: 1,
            remainingIDs: []
        ))),
        scanSnapshotStore: InMemoryScanSnapshotStore(),
        checkpointStore: checkpointStore,
        sessionToken: "session-1"
    )
    env.photoPermissionState = .authorized
    env.blurAnalysisClock = { blurScanDate }
    if catalogCompleted {
        env.catalogState = .completed(CatalogScanResult(
            records: blurFixtureRecords,
            libraryAssetCount: blurFixtureRecords.count,
            accessLevel: .authorized
        ))
    }
    return (env, probe, checkpointStore)
}

/// One fresh pass to completion — the result every resumed run must equal, and the
/// request count every resumed run must beat.
@MainActor
private func freshBlurBaseline() async -> (result: BlurAnalysisResult, requests: Int) {
    let (env, probe, _) = makeBlurEnv()
    env.startBlurAnalysis()
    await waitForBlurSettled(env)
    guard case .completed(let result) = env.blurAnalysisState else {
        Issue.record("fresh blur run did not complete: \(env.blurAnalysisState)")
        return (.empty, probe.requestCount)
    }
    return (result, probe.requestCount)
}

/// Waits for a resumed blur pass to reach a terminal state — `.paused` is a legal
/// interim state (a chained catalog rebuild is still running), so the poll cannot key
/// off `isRunning` alone.
@MainActor
private func resumedBlurResult(
    _ env: AppEnvironment,
    timeoutMilliseconds: Int = 15_000
) async -> BlurAnalysisResult? {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while ContinuousClock.now < deadline {
        switch env.blurAnalysisState {
        case .completed, .failed, .cancelled:
            break
        default:
            try? await Task.sleep(for: .milliseconds(20))
            continue
        }
        break
    }
    guard case .completed(let result) = env.blurAnalysisState else {
        Issue.record("resumed blur run did not complete: \(env.blurAnalysisState)")
        return nil
    }
    return result
}

private final class BlurEvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CheckpointEvidence] = []

    func append(_ evidence: CheckpointEvidence) {
        lock.lock()
        storage.append(evidence)
        lock.unlock()
    }

    var evidence: [CheckpointEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct BlurCheckpointContactsPermissionService: ContactsPermissionServicing {
    func currentStatus() -> PermissionState { .notDetermined }
    func requestAccess() async -> PermissionState { .notDetermined }
}
