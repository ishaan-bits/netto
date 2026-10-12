import CoreGraphics
import Foundation
import Testing
@testable import Netto

// MARK: - Presentation (pure mapping)

struct SimilarPhotosPresentationTests {
    private let fixture: PhotoAnalysisResult = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 42,
        candidateBucketCount: 3,
        candidatePairCount: 6
    )

    private let zeroRecordRun = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 0,
        candidateBucketCount: 0,
        candidatePairCount: 0
    )

    @Test func analyzedCountExcludesAssetsThatWereNeverAnalyzed() {
        let partial = PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [],
            unavailableAssets: [
                PhotoAnalysisUnavailable(assetID: "x", reason: .contentOnlyInICloud),
                PhotoAnalysisUnavailable(assetID: "y", reason: .assetNotFound),
            ],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 42,
            candidateBucketCount: 3,
            candidatePairCount: 6
        )
        let summary = SimilarPhotosSummary(result: partial)
        #expect(summary.unavailableCount == 2)
        #expect(summary.analyzedCount == 40)
        #expect(SimilarPhotosPresentation.noDuplicatesMessage(result: partial)
            .contains("Analyzed 40 items"))

        // Everything unavailable: no "Analyzed 0 items" claim is made at all.
        let nothingAnalyzed = PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [],
            unavailableAssets: [PhotoAnalysisUnavailable(assetID: "x", reason: .permissionUnavailable)],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 1,
            candidateBucketCount: 0,
            candidatePairCount: 0
        )
        #expect(SimilarPhotosSummary(result: nothingAnalyzed).analyzedCount == 0)
        #expect(SimilarPhotosPresentation.noDuplicatesMessage(result: nothingAnalyzed)
            == "None of the items in this scan could be analyzed, so there is nothing marked for cleanup.")

        // A fully analyzed run keeps the original wording.
        #expect(SimilarPhotosSummary(result: fixture).analyzedCount == 42)
        #expect(SimilarPhotosPresentation.noDuplicatesMessage(result: fixture)
            == "Analyzed 42 items — every one is distinct, so there is nothing marked for cleanup.")
    }

    @Test func skippedAssetsAreReportedButNeverClaimedAsAnalyzed() {
        // Cheap-first runs skip singletons (no partner could exist). They are neither
        // analyzed nor failed — the summary must keep the three counts disjoint and the
        // no-duplicates message must say what happened rather than quietly omit it.
        let partial = PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [],
            unavailableAssets: [],
            descriptorKind: .cpuGrid,
            visionAvailable: false,
            similarityThreshold: 0.15,
            totalRecordCount: 10,
            candidateBucketCount: 2,
            candidatePairCount: 1,
            analyzedAssetCount: 4,
            skippedNoCandidateCount: 6
        )
        let summary = SimilarPhotosSummary(result: partial)
        #expect(summary.analyzedCount == 4)
        #expect(summary.skippedCount == 6)
        #expect(summary.notAnalyzedCount == 6)
        let message = SimilarPhotosPresentation.noDuplicatesMessage(result: partial)
        #expect(message.contains("Analyzed 4 items"))
        #expect(message.contains("6 more had no similar candidates to compare."))

        // Every item skipped: nothing was analyzed, but nothing failed either — the message
        // must distinguish "no partners" from "could not be analyzed".
        let allSkipped = PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 10,
            candidateBucketCount: 10,
            candidatePairCount: 0,
            analyzedAssetCount: 0,
            skippedNoCandidateCount: 10
        )
        let allSkippedSummary = SimilarPhotosSummary(result: allSkipped)
        #expect(allSkippedSummary.analyzedCount == 0)
        #expect(allSkippedSummary.notAnalyzedCount == 10)
        #expect(SimilarPhotosPresentation.noDuplicatesMessage(result: allSkipped)
            == "Every item was the only candidate in its group, so there is nothing marked for cleanup.")
    }

    // MARK: - Queue acknowledgement (M10)

    @Test func permissionGatesEvenAFinishedResult() {
        let completed = PhotoAnalysisState.completed(fixture)

        #expect(
            SimilarPhotosPresentation.phase(
                permission: .notDetermined,
                catalog: .completed(CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)),
                analysis: completed
            ) == .permissionRequired
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .denied,
                catalog: .notStarted,
                analysis: completed
            ) == .permissionDenied
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .restricted,
                catalog: .notStarted,
                analysis: completed
            ) == .permissionDenied
        )
    }

    @Test func runningAnalysisOutranksEveryOtherState() {
        let progress = PhotoAnalysisProgress(stage: .comparing, completedUnits: 2, totalUnits: 8)
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .limited,
                catalog: .running(CatalogScanProgress(enumeratedCount: 5, totalCount: 10)),
                analysis: .running(progress)
            ) == .analyzing(progress)
        )
    }

    @Test func runningCatalogWithoutAnalysisIsTheBuildPhase() {
        let scan = CatalogScanProgress(enumeratedCount: 5, totalCount: 10)
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .running(scan),
                analysis: .notStarted
            ) == .buildingCatalog(scan)
        )
    }

    @Test func finishedRunMapsToResults() {
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .completed(emptyCatalog),
                analysis: .completed(fixture)
            ) == .results(fixture)
        )
    }

    @Test func runOverZeroRecordsIsAnEmptyLibraryNotEmptyResults() {
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .completed(emptyCatalog),
                analysis: .completed(zeroRecordRun)
            ) == .emptyLibrary
        )
    }

    @Test func catalogCompletedStates() {
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .completed(emptyCatalog),
                analysis: .notStarted
            ) == .emptyLibrary
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .completed(nonEmptyCatalog),
                analysis: .notStarted
            ) == .idle
        )
    }

    @Test func failuresSurfaceTheirUserMessage() {
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .notStarted,
                analysis: .failed(.underlying("boom"))
            ) == .failed("boom")
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .failed(.photoLibraryUnavailable),
                analysis: .notStarted
            ) == .failed(CatalogScanFailure.photoLibraryUnavailable.userMessage)
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .failed(.underlying("disk went away")),
                analysis: .notStarted
            ) == .failed("disk went away")
        )
    }

    @Test func cancelledStates() {
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .notStarted,
                analysis: .cancelled
            ) == .cancelled
        )
        #expect(
            SimilarPhotosPresentation.phase(
                permission: .authorized,
                catalog: .cancelled,
                analysis: .notStarted
            ) == .cancelled
        )
    }

    @Test func limitedNoticeIsOnlyForLimitedAccess() {
        #expect(SimilarPhotosPresentation.showsLimitedAccessNotice(permission: .limited))
        #expect(!SimilarPhotosPresentation.showsLimitedAccessNotice(permission: .authorized))
        #expect(!SimilarPhotosPresentation.showsLimitedAccessNotice(permission: .denied))
        #expect(!SimilarPhotosPresentation.showsLimitedAccessNotice(permission: .notDetermined))
    }

    @Test func barFractionIsClampedAndAbsentForIndeterminateStages() {
        let determinate = PhotoAnalysisProgress(stage: .fingerprinting, completedUnits: 5, totalUnits: 10)
        #expect(SimilarPhotosPresentation.barFraction(for: determinate) == 0.5)

        let over = PhotoAnalysisProgress(stage: .fingerprinting, completedUnits: 12, totalUnits: 10)
        #expect(SimilarPhotosPresentation.barFraction(for: over) == 1.0)

        let indeterminate = PhotoAnalysisProgress(stage: .generatingCandidates, completedUnits: 0, totalUnits: 0)
        #expect(SimilarPhotosPresentation.barFraction(for: indeterminate) == nil)
    }

    @Test func everyStageHasUsableCopy() {
        for stage in PhotoAnalysisStage.allCases {
            let message = SimilarPhotosPresentation.stageMessage(
                for: PhotoAnalysisProgress(stage: stage, completedUnits: 0, totalUnits: 0)
            )
            #expect(!message.isEmpty)
            let counting = SimilarPhotosPresentation.stageMessage(
                for: PhotoAnalysisProgress(stage: stage, completedUnits: 3, totalUnits: 9)
            )
            #expect(!counting.isEmpty)
        }
    }

    @Test func summaryCountsFromResult() {
        let summary = SimilarPhotosSummary(result: fixture)
        #expect(summary.hasNoGroups)
        #expect(summary.unavailableCount == 0)
        #expect(summary.exactGroupCount == 0 && summary.similarGroupCount == 0)

        let exact = PhotoSimilarityGroup(
            kind: .exactDuplicates,
            memberAssetIDs: ["a", "b", "c"],
            evidence: .exactContent(fingerprint: "f", byteLength: 1),
            recommendedBestAssetID: "a",
            memberScores: [:]
        )
        let withGroups = PhotoAnalysisResult(
            exactGroups: [exact],
            similarGroups: [],
            unavailableAssets: [PhotoAnalysisUnavailable(assetID: "z", reason: .contentOnlyInICloud)],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: 0.15,
            totalRecordCount: 42,
            candidateBucketCount: 3,
            candidatePairCount: 6
        )
        let rich = SimilarPhotosSummary(result: withGroups)
        #expect(rich.exactGroupCount == 1)
        #expect(rich.groupedAssetCount == 3)
        #expect(rich.unavailableCount == 1)
        #expect(!rich.hasNoGroups)
    }

    // MARK: Top selection toolbar (M4H)

    @Test func menuLabelIsSelectionNotActionsAndReviewStaysThePrimaryAction() {
        #expect(SimilarPhotosPresentation.selectionToolbarMenuLabel == "Selection")
        #expect(SimilarPhotosPresentation.selectionToolbarMenuLabel != "Actions")
        // The bottom primary action is unchanged and can never be confused with the menu.
        #expect(SimilarPhotosPresentation.primaryReviewActionLabel == "Review")
        #expect(SimilarPhotosPresentation.selectionToolbarMenuLabel != SimilarPhotosPresentation.primaryReviewActionLabel)
    }

    @Test func selectionMenuCarriesAClearAccessibilityValue() {
        #expect(SimilarPhotosPresentation.selectionToolbarAccessibilityValue(selectedCount: 0) == "0 photos selected")
        #expect(SimilarPhotosPresentation.selectionToolbarAccessibilityValue(selectedCount: 1) == "1 photo selected")
        #expect(SimilarPhotosPresentation.selectionToolbarAccessibilityValue(selectedCount: 234) == "234 photos selected")
    }

    // MARK: Top selection toolbar (M4G)

    @Test func topToolbarExposesOnlyDeselectAllAndResetToRecommended() {
        // The exact menu the view builds from: two actions, exact labels, no Select All.
        let labels = SimilarPhotosPresentation.selectionToolbarActions.map(\.rawValue)
        #expect(labels == ["Deselect All", "Reset to Recommended"])
        #expect(!labels.contains("Select All"))

        // Deselect All hides at zero (nothing to clear); Reset stays available always.
        #expect(SimilarPhotosPresentation.shows(.deselectAll, selectedCount: 3))
        #expect(!SimilarPhotosPresentation.shows(.deselectAll, selectedCount: 0))
        #expect(SimilarPhotosPresentation.shows(.resetToRecommended, selectedCount: 0))
        #expect(SimilarPhotosPresentation.shows(.resetToRecommended, selectedCount: 3))

        // Stable identifiers the toolbar ships with.
        #expect(SimilarPhotosPresentation.selectionActionIdentifier(.deselectAll) == "deselectAllButton")
        #expect(SimilarPhotosPresentation.selectionActionIdentifier(.resetToRecommended) == "resetToRecommendedButton")
    }

    // MARK: Fixtures

    private var emptyCatalog: CatalogScanResult {
        CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)
    }

    private var nonEmptyCatalog: CatalogScanResult {
        CatalogScanResult(records: [makeRecord(id: "one")], libraryAssetCount: 1, accessLevel: .authorized)
    }
}

// MARK: - AppEnvironment orchestration

@MainActor
struct SimilarPhotosFlowTests {
    @Test func permissionDeniedFailsFastWithoutTouchingTheLibrary() {
        let env = makeEnv(permission: .denied) {
            throw PhotoLibraryReadError.underlying("FACTORY_WAS_CALLED")
        }
        env.startSimilarityAnalysis()
        expectFailureMessage(env, equals: "Photos access is required to read your library.")
        #expect(!env.analysisState.isRunning)
    }

    @Test func notDeterminedPermissionAlsoFailsFast() {
        let env = makeEnv(permission: .notDetermined) {
            throw PhotoLibraryReadError.underlying("FACTORY_WAS_CALLED")
        }
        env.startSimilarityAnalysis()
        expectFailureMessage(env, equals: "Photos access is required to read your library.")
    }

    @Test func factoryFailureSurfacesItsOwnMessage() async {
        let env = makeEnv(permission: .authorized) {
            throw PhotoLibraryReadError.underlying("boom")
        }
        env.startSimilarityAnalysis()
        // Reader creation happens inside the task now — wait for it to fail.
        _ = await waitForAnalysis(env)
        expectFailureMessage(env, equals: "boom")
    }

    @Test func accessDeniedFromFactoryMapsToThePermissionMessage() async {
        let env = makeEnv(permission: .authorized) {
            throw PhotoLibraryReadError.accessDenied
        }
        env.startSimilarityAnalysis()
        _ = await waitForAnalysis(env)
        expectFailureMessage(env, equals: "Photos access is required to read your library.")
    }

    @Test func emptyLibraryRunCompletesWithNoGroupsAndAnEmptySelection() async {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)

        let state = await waitForAnalysis(env)

        guard case .completed(let result) = state else {
            Issue.record("expected a completed empty run, got \(state)")
            return
        }
        #expect(result.exactGroups.isEmpty)
        #expect(result.similarGroups.isEmpty)
        #expect(result.totalRecordCount == 0)
        #expect(env.selection.selectedCount == 0)
        guard case .completed(let catalog) = env.catalogState else {
            Issue.record("catalog should be completed, got \(env.catalogState)")
            return
        }
        #expect(catalog.isEmpty)
    }

    @Test func distinctLibraryRunCompletesWithoutGroups() async {
        // Six images that never share a bucket (wildly different aspect ratios, years apart):
        // no candidate pairs form, so the real engine completes without descriptors or network.
        let records = [
            makeRecord(id: "sq-1", width: 1000, height: 1000, daysAgo: 0),
            makeRecord(id: "pano-1", width: 4000, height: 1000, daysAgo: 30),
            makeRecord(id: "sq-2", width: 1000, height: 1000, daysAgo: 800),
            makeRecord(id: "pano-2", width: 4000, height: 1000, daysAgo: 900),
            makeRecord(id: "sq-3", width: 1000, height: 1000, daysAgo: 1600),
            makeRecord(id: "pano-3", width: 4000, height: 1000, daysAgo: 1700)
        ]
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: records) }
        env.startSimilarityAnalysis()

        let state = await waitForAnalysis(env)

        guard case .completed(let result) = state else {
            Issue.record("expected completion, got \(state)")
            return
        }
        #expect(result.totalRecordCount == 6)
        #expect(result.exactGroups.isEmpty)
        #expect(result.similarGroups.isEmpty)
        #expect(env.selection.selectedCount == 0)
    }

    @Test func startingAResetClearsThePreviousSelection() {
        let group = PhotoSimilarityGroup(
            kind: .nearDuplicates,
            memberAssetIDs: ["a", "b"],
            evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15),
            recommendedBestAssetID: "a",
            memberScores: [:]
        )
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        env.selection = PhotoSelectionModel(groups: [group])
        #expect(env.selection.selectedCount == 1)

        env.startSimilarityAnalysis()
        #expect(env.selection.selectedCount == 0)
        #expect(env.analysisState.isRunning)
    }

    @Test func selectionSurvivesUnrelatedStateChanges() async {
        let group = PhotoSimilarityGroup(
            kind: .nearDuplicates,
            memberAssetIDs: ["a", "b"],
            evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15),
            recommendedBestAssetID: "a",
            memberScores: [:]
        )
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        env.selection = PhotoSelectionModel(groups: [group])
        // Default keeps the recommendation ("a") out; toggling it marks both members.
        env.selection.toggle("a")

        await env.refreshStorage()
        env.refreshPermissions()
        env.analysisState = .completed(PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 10,
            candidateBucketCount: 1,
            candidatePairCount: 1
        ))

        #expect(env.selection.selectedCount == 2)
        #expect(env.selection.isSelected("a"))
        #expect(env.selection.isSelected("b"))
    }

    @Test func cancelWinsOverALateCompletion() async {
        // The library read stalls on its first chunk, so the cancellation issued immediately
        // after `start` is guaranteed to land first; the stale run must then be unable to
        // write catalog or analysis state.
        let env = makeEnv(permission: .authorized) {
            FakeLibrary(records: [makeRecord(id: "slow-1")], chunkDelay: 0.25)
        }
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)

        env.cancelSimilarityAnalysis()
        #expect(env.analysisState == .cancelled)

        try? await Task.sleep(for: .milliseconds(800))
        #expect(env.analysisState == .cancelled)
        if case .completed = env.catalogState {
            Issue.record("a cancelled run must not complete the catalog")
        }
    }

    @Test func catalogBuildUsesTheInjectedFactoryAndMapsDeniedAccess() async {
        let env = makeEnv(permission: .denied) {
            throw PhotoLibraryReadError.accessDenied
        }
        env.startCatalogBuild()
        // The run commits as `.running` first; the reader (created inside the task) then
        // fails with the mapped PhotoKit error.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while case .running = env.catalogState, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(env.catalogState == .failed(.photoLibraryUnavailable))
    }

    @Test func startingWhileRunningIsIgnored() async {
        let calls = FactoryCallBox()
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            makePhotoLibrary: {
                calls.record()
                return FakeLibrary(
                    records: [makeRecord(id: "x", width: 4000, height: 1000)],
                    chunkDelay: 0.3
                )
            },
            scanSnapshotStore: InMemoryScanSnapshotStore()
        )
        env.photoPermissionState = .authorized
        env.startSimilarityAnalysis()
        // The factory runs inside the analysis task now — wait for its first call.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while calls.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(calls.count == 1)

        // A second start is refused synchronously: no second factory call ever happens.
        env.startSimilarityAnalysis()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(calls.count == 1)
        #expect(env.analysisState.isRunning)
        env.cancelSimilarityAnalysis()
    }

    // MARK: Deselect All (global)

    private func deselectAllFixtureResult() -> PhotoAnalysisResult {
        PhotoAnalysisResult(
            exactGroups: [],
            similarGroups: [
                PhotoSimilarityGroup(
                    kind: .nearDuplicates,
                    memberAssetIDs: ["n1", "n2", "n3"],
                    evidence: .visualSimilarity(minDistance: 0.01, maxDistance: 0.02, threshold: 0.15),
                    recommendedBestAssetID: "n2",
                    memberScores: [:]
                )
            ],
            unavailableAssets: [],
            descriptorKind: nil,
            visionAvailable: false,
            similarityThreshold: nil,
            totalRecordCount: 10,
            candidateBucketCount: 1,
            candidatePairCount: 3
        )
    }

    @Test func globalDeselectAllLeavesResultsGroupsAndReviewAtZero() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        #expect(env.selection.selectedCount == 2)

        env.mutateSelection { $0.deselectAll() }

        // Review reads the same selection and now sees nothing to review.
        #expect(env.selection.selectedCount == 0)
        #expect(env.selection.selectedIDs.isEmpty)
        #expect(env.selectionCount(for: .similarPhotos) == 0)
        #expect(env.selectionCount(for: .screenshots) == 0)
        #expect(env.selectionCount(for: .videos) == 0)
        // Results, groups, and recommendations are a different layer — untouched.
        #expect(env.analysisState == .completed(result))
        #expect(Set(env.selection.memberIDs(inGroup: result.similarGroups[0].id)) == ["n1", "n2", "n3"])
        #expect(env.selection.selectionState(inGroup: result.similarGroups[0].id) == .none)
        // Nothing was deleted along the way.
        #expect(env.deletionState == .noSelection)
    }

    @Test func manualSelectionStillWorksAfterGlobalDeselectAll() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        env.selection = PhotoSelectionModel(result: deselectAllFixtureResult())

        env.mutateSelection { $0.deselectAll() }
        #expect(env.selectionCount(for: .similarPhotos) == 0)

        env.mutateSelection { $0.setSelected(true, forAsset: "n1") }
        #expect(env.selection.selectedCount == 1)
        #expect(env.selectionCount(for: .similarPhotos) == 1)

        env.mutateSelection { $0.setSelected(false, forAsset: "n1") }
        #expect(env.selectionCount(for: .similarPhotos) == 0)
    }

    // MARK: Reset to Recommended (M4F)

    @Test func deselectAllThenResetToRecommendedRestoresTheOriginalSelection() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)
        #expect(env.selection.selectedCount == 2)

        env.mutateSelection { $0.deselectAll() }
        #expect(env.selection.selectedCount == 0)
        // Deselect All touches only the selection: groups, membership, and the result layer
        // (which carries the KEEP labels) are exactly as presented.
        #expect(env.selection.selectionState(inGroup: result.similarGroups[0].id) == .none)
        #expect(Set(env.selection.memberIDs(inGroup: result.similarGroups[0].id)) == ["n1", "n2", "n3"])
        #expect(env.analysisState == .completed(result))

        env.mutateSelection { $0.resetToRecommended() }
        #expect(env.selection.selectedCount == 2)
        #expect(env.selection.isSelected("n1"))
        #expect(env.selection.isSelected("n3"))
        #expect(!env.selection.isSelected("n2")) // KEEP back out
        #expect(env.analysisState == .completed(result)) // still no rescan, still no recompute
    }

    @Test func manualSelectionChangesThenResetToRecommendedRestoreTheOriginalSelection() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)

        env.mutateSelection { $0.setSelected(false, forAsset: "n1") }
        env.mutateSelection { $0.setSelected(true, forAsset: "n2") }
        env.mutateSelection { $0.toggle("n3") }
        #expect(env.selection.selectedCount == 1) // {n2} — far from the presented selection
        #expect(env.selection.isSelected("n2"))

        env.mutateSelection { $0.resetToRecommended() }
        #expect(env.selection == PhotoSelectionModel(result: result))
        #expect(env.selection.selectedCount == 2)
        #expect(!env.selection.isSelected("n2"))
    }

    @Test func selectAllThenResetToRecommendedRestoreTheOriginalSelection() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)

        env.mutateSelection { $0.selectAll() }
        #expect(env.selection.selectedCount == 3) // all members, KEEP included
        #expect(env.selection.isSelected("n2"))

        env.mutateSelection { $0.resetToRecommended() }
        #expect(env.selection.selectedCount == 2)
        #expect(!env.selection.isSelected("n2"))
        #expect(env.selection.isSelected("n1"))
        #expect(env.selection.isSelected("n3"))
    }

    @Test func selectionActionsTriggerNeitherScanningNorDeletion() {
        let calls = FactoryCallBox()
        let env = makeEnv(permission: .authorized) {
            calls.record()
            return FakeLibrary(records: [])
        }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)

        // The two toolbar actions, plus a manual change — none of them may start a scan or
        // enter the deletion pipeline.
        env.mutateSelection { $0.deselectAll() }
        env.mutateSelection { $0.setSelected(true, forAsset: "n1") }
        env.mutateSelection { $0.setSelected(false, forAsset: "n3") }
        env.mutateSelection { $0.resetToRecommended() }

        // No rescan (the library factory was never invoked), the analysis result is
        // byte-identical, and the deletion pipeline was never entered.
        #expect(calls.count == 0)
        #expect(env.analysisState == .completed(result))
        #expect(env.deletionState == .noSelection)
    }

    @Test func reviewUsesTheCurrentSelectionAfterEachOperation() {
        let env = makeEnv(permission: .authorized) { FakeLibrary(records: []) }
        let result = deselectAllFixtureResult()
        env.analysisState = .completed(result)
        env.selection = PhotoSelectionModel(result: result)

        #expect(env.selectionCount(for: .similarPhotos) == 2) // as presented

        env.mutateSelection { $0.deselectAll() }
        #expect(env.selectionCount(for: .similarPhotos) == 0)

        env.mutateSelection { $0.resetToRecommended() }
        #expect(env.selectionCount(for: .similarPhotos) == 2)

        env.mutateSelection { $0.selectAll() }
        #expect(env.selectionCount(for: .similarPhotos) == 3)

        env.mutateSelection { $0.setSelected(false, forAsset: "n1") }
        #expect(env.selectionCount(for: .similarPhotos) == 2)

        env.mutateSelection { $0.resetToRecommended() }
        #expect(env.selectionCount(for: .similarPhotos) == 2)
        #expect(env.selectionCount(for: .similarPhotos) == env.selection.selectedCount)
    }

    // MARK: Helpers

    private func expectFailureMessage(_ env: AppEnvironment, equals expected: String) {
        guard case .failed(let failure) = env.analysisState else {
            Issue.record("expected failure, got \(env.analysisState)")
            return
        }
        guard case .underlying(let message) = failure else {
            Issue.record("expected underlying failure, got \(failure)")
            return
        }
        #expect(message == expected)
    }

    private func makeEnv(
        permission: PermissionState,
        factory: @escaping @Sendable () throws -> any PhotoLibraryReading
    ) -> AppEnvironment {
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            makePhotoLibrary: factory,
            // Completions in this suite must never touch the app's real persisted snapshot.
            scanSnapshotStore: InMemoryScanSnapshotStore()
        )
        env.photoPermissionState = permission
        return env
    }

    private func waitForAnalysis(
        _ env: AppEnvironment,
        timeoutMilliseconds: Int = 20_000
    ) async -> PhotoAnalysisState {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while env.analysisState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return env.analysisState
    }
}

// MARK: - Interrupted-run checkpoints (Phase C)
//
// Evidence for these tests is captured through the real engine and its checkpoint sink —
// exactly what an interrupted run would have saved — then replayed through the restore →
// paused → resume path. The loader counts every request, which is what makes "resume
// skips what the checkpoint already earned" observable.

@MainActor
struct SimilarityCheckpointFlowTests {
    private let records = checkpointRecords()

    @Test func restoredCheckpointPresentsPausedStateWithoutStartingAnything() async throws {
        let counter = RequestCounter()
        let checkpoint = try await capturedSimilarityCheckpoint(records: records, counter: counter)
        let (env, store, factoryCalls) = makeCheckpointEnv(
            records: records,
            counter: RequestCounter(),
            checkpoint: checkpoint
        )

        await env.bootstrap()

        guard case .paused(let progress) = env.analysisState else {
            Issue.record("expected paused analysis, got \(env.analysisState)")
            return
        }
        #expect(progress.stage == .fingerprinting)
        #expect(progress.completedUnits == checkpoint.perceptualHashes.count)
        #expect(progress.totalUnits == records.count)
        // A relaunch presents the checkpoint and waits: no reader, no requests, no ETA.
        #expect(factoryCalls.count == 0)
        #expect(store.load() == checkpoint)
        #expect(env.scanETA() == .calculating)
    }

    @Test func resumeReusesTheSavedEvidenceAndCompletesWithFewerRequests() async throws {
        let fresh = try await freshBaseline()

        let counter = RequestCounter()
        let checkpoint = try await capturedSimilarityCheckpoint(records: records, counter: RequestCounter())
        let (env, store, _) = makeCheckpointEnv(
            records: records,
            counter: counter,
            checkpoint: checkpoint
        )
        await env.bootstrap()
        env.resumeInterruptedWork()

        let state = await waitForAnalysis(env)
        guard case .completed(let resumed) = state else {
            Issue.record("resumed run did not complete: \(state)")
            return
        }
        // Same library, same loader, same engine — a resumed run's result must match a
        // fresh one, and the saved perceptual hashes cost no thumbnail requests.
        expectSameAnalysisOutcome(resumed, fresh.result)
        #expect(counter.count < fresh.requestCount)
        // Completion released the checkpoint kind-aware: nothing left to resume.
        #expect(store.load() == nil)
    }

    @Test func changedModificationDatesInvalidateTheSavedEvidence() async throws {
        let fresh = try await freshBaseline()
        let captured = try await capturedSimilarityCheckpoint(records: records, counter: RequestCounter())
        // Every saved entry now belongs to a different version of its asset: resume must
        // recompute all of it instead of trusting stale evidence.
        let stale = ScanCheckpoint(
            runSequence: captured.runSequence,
            kind: .similarity,
            startedAt: captured.startedAt,
            updatedAt: captured.updatedAt,
            stage: captured.stage,
            completedUnits: captured.completedUnits,
            totalUnits: captured.totalUnits,
            perceptualHashes: captured.perceptualHashes.map {
                PerceptualHashEntry(
                    assetID: $0.assetID,
                    modified: Date(timeIntervalSince1970: 1_000),
                    bits: $0.bits
                )
            }
        )
        let counter = RequestCounter()
        let (env, _, _) = makeCheckpointEnv(
            records: records,
            counter: counter,
            checkpoint: stale
        )
        await env.bootstrap()
        env.resumeInterruptedWork()

        let state = await waitForAnalysis(env)
        guard case .completed(let resumed) = state else {
            Issue.record("run with stale evidence did not complete: \(state)")
            return
        }
        expectSameAnalysisOutcome(resumed, fresh.result)
        // Full price: every hash recomputed, exactly as a fresh run pays.
        #expect(counter.count == fresh.requestCount)
    }

    @Test func checkpointEntriesForDeletedAssetsAreIgnored() async throws {
        let fresh = try await freshBaseline()
        let captured = try await capturedSimilarityCheckpoint(records: records, counter: RequestCounter())
        // One valid entry (reused) plus one for an asset that no longer exists (dropped
        // by reconciliation — missing is never treated as analyzed).
        var valid = captured.perceptualHashes
        let reused = valid.removeFirst()
        let mixed = ScanCheckpoint(
            runSequence: captured.runSequence,
            kind: .similarity,
            startedAt: captured.startedAt,
            updatedAt: captured.updatedAt,
            stage: captured.stage,
            completedUnits: captured.completedUnits,
            totalUnits: captured.totalUnits,
            perceptualHashes: valid + [
                PerceptualHashEntry(assetID: "deleted-asset", modified: nil, bits: 0xF00D),
                reused,
            ]
        )
        let counter = RequestCounter()
        let (env, _, _) = makeCheckpointEnv(
            records: records,
            counter: counter,
            checkpoint: mixed
        )
        await env.bootstrap()
        env.resumeInterruptedWork()

        let state = await waitForAnalysis(env)
        guard case .completed(let resumed) = state else {
            Issue.record("run with a deleted entry did not complete: \(state)")
            return
        }
        expectSameAnalysisOutcome(resumed, fresh.result)
        #expect(!resumed.unavailableAssets.map(\.assetID).contains("deleted-asset"))
        // The valid entry was reused; the ghost contributed nothing (and was never counted).
        #expect(counter.count < fresh.requestCount)
    }

    @Test func aFreshStartSupersedesTheInterruptedRunAndCancelNeverResurrectsIt() async throws {
        let counter = RequestCounter()
        let checkpoint = try await capturedSimilarityCheckpoint(records: records, counter: counter)
        let (env, store, _) = makeCheckpointEnv(
            records: records,
            counter: RequestCounter(),
            checkpoint: checkpoint
        )
        await env.bootstrap()
        #expect(store.load() == checkpoint)

        // An explicit new Analyze supersedes resumable work: the checkpoint is gone the
        // moment the fresh run claims the slot.
        env.startSimilarityAnalysis()
        #expect(env.analysisState.isRunning)
        #expect(store.load() == nil)

        env.cancelSimilarityAnalysis()
        #expect(env.analysisState == .cancelled)
        // Explicit cancel abandons resumable work too — Resume has nothing to continue.
        #expect(store.load() == nil)
        env.resumeInterruptedWork()
        #expect(env.analysisState == .cancelled)
    }

    @Test func completionReleasesTheCheckpoint() async {
        let (env, store, _) = makeCheckpointEnv(
            records: records,
            counter: RequestCounter()
        )
        env.startSimilarityAnalysis()
        let state = await waitForAnalysis(env)
        guard case .completed = state else {
            Issue.record("fresh run did not complete: \(state)")
            return
        }
        #expect(store.load() == nil)
    }

    // MARK: Helpers

    private struct Baseline {
        let result: PhotoAnalysisResult
        let requestCount: Int
    }

    private func freshBaseline() async throws -> Baseline {
        let counter = RequestCounter()
        let (env, _, _) = makeCheckpointEnv(records: records, counter: counter)
        env.startSimilarityAnalysis()
        let state = await waitForAnalysis(env)
        guard case .completed(let result) = state else {
            throw CheckpointTestError.didNotComplete("\(state)")
        }
        return Baseline(result: result, requestCount: counter.count)
    }

    private func waitForAnalysis(
        _ env: AppEnvironment,
        timeoutMilliseconds: Int = 20_000
    ) async -> PhotoAnalysisState {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while env.analysisState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return env.analysisState
    }
}

private enum CheckpointTestError: Error {
    case didNotComplete(String)
}

/// Cross-run comparison on the stable projections: group structure and counts must match,
/// while unavailable entries compare as a set (their emission order follows parallel
/// worker timing, which is not part of the contract).
private func expectSameAnalysisOutcome(_ lhs: PhotoAnalysisResult, _ rhs: PhotoAnalysisResult) {
    #expect(lhs.totalRecordCount == rhs.totalRecordCount)
    #expect(lhs.analyzedAssetCount == rhs.analyzedAssetCount)
    #expect(lhs.skippedNoCandidateCount == rhs.skippedNoCandidateCount)
    #expect(lhs.exactGroups == rhs.exactGroups)
    #expect(lhs.similarGroups == rhs.similarGroups)
    #expect(lhs.descriptorKind == rhs.descriptorKind)
    #expect(lhs.visionAvailable == rhs.visionAvailable)
    #expect(
        Set(lhs.unavailableAssets.map { "\($0.assetID):\($0.reason.rawValue)" })
            == Set(rhs.unavailableAssets.map { "\($0.assetID):\($0.reason.rawValue)" })
    )
}

/// Four same-bucket image records (identical dimensions and creation date) — the cheap
/// pass issues one perceptual request each, which is what resume must skip.
private func checkpointRecords() -> [PhotoAssetRecord] {
    let creation = Date(timeIntervalSince1970: 1_750_000_000)
    return ["ckpt-a", "ckpt-b", "ckpt-c", "ckpt-d"].map { id in
        PhotoAssetRecord(
            localIdentifier: id,
            mediaType: .image,
            mediaSubtypes: [],
            pixelWidth: 1000,
            pixelHeight: 1000,
            creationDate: creation,
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
}

/// Runs the real engine once over `records`, capturing the evidence its sink reports —
/// the same entries an interrupted run would have flushed to disk.
private func capturedSimilarityCheckpoint(
    records: [PhotoAssetRecord],
    counter: RequestCounter
) async throws -> ScanCheckpoint {
    let sink = EvidenceBox()
    let engine = PhotoSimilarityEngine(
        thumbnailLoader: CheckpointCountingLoader(images: checkpointImages(for: records), counter: counter),
        checkpointSink: { sink.append($0) }
    )
    for try await event in engine.makeAnalysisStream(records: records) {
        if case .completed = event { break }
    }
    let hashes = sink.entries.compactMap { evidence -> PerceptualHashEntry? in
        guard case .perceptualHash(let assetID, let modified, let bits) = evidence else { return nil }
        return PerceptualHashEntry(assetID: assetID, modified: modified, bits: bits)
    }
    guard hashes.count == records.count else {
        throw CheckpointTestError.didNotComplete("captured \(hashes.count) of \(records.count) hashes")
    }
    return ScanCheckpoint(
        runSequence: 7,
        kind: .similarity,
        startedAt: Date(timeIntervalSinceReferenceDate: 10),
        updatedAt: Date(timeIntervalSinceReferenceDate: 20),
        stage: PhotoAnalysisStage.fingerprinting.rawValue,
        completedUnits: hashes.count,
        totalUnits: records.count,
        perceptualHashes: hashes.sorted { $0.assetID < $1.assetID }
    )
}

@MainActor
private func makeCheckpointEnv(
    records: [PhotoAssetRecord],
    counter: RequestCounter,
    checkpoint: ScanCheckpoint? = nil,
    factoryCalls: FactoryCallBox = FactoryCallBox()
) -> (env: AppEnvironment, checkpointStore: InMemoryScanCheckpointStore, factoryCalls: FactoryCallBox) {
    let checkpointStore = InMemoryScanCheckpointStore()
    if let checkpoint {
        try? checkpointStore.save(checkpoint)
    }
    let env = AppEnvironment(
        storageProvider: FakeStorage(),
        photoPermission: CheckpointPermissionService(.authorized),
        contactsPermission: CheckpointContactsPermissionService(),
        makePhotoLibrary: {
            factoryCalls.record()
            return FakeLibrary(records: records)
        },
        thumbnailLoader: CheckpointCountingLoader(
            images: checkpointImages(for: records),
            counter: counter
        ),
        // Completions and restores in this suite must never touch the app's real files.
        scanSnapshotStore: InMemoryScanSnapshotStore(),
        checkpointStore: checkpointStore
    )
    env.photoPermissionState = .authorized
    return (env, checkpointStore, factoryCalls)
}

/// Distinct deterministic noise images — no accidental hamming-0 collisions, so neither
/// the content-length fingerprinter nor PhotoKit is ever reached with phantom ids.
private func checkpointImages(for records: [PhotoAssetRecord]) -> [String: CGImage] {
    var images: [String: CGImage] = [:]
    for (index, record) in records.enumerated() {
        images[record.localIdentifier] = blurTestNoise(
            size: 96,
            base: 48,
            spread: 160,
            seed: UInt64(index) + 1
        )
    }
    return images
}

/// Records every thumbnail request — the observable difference between a fresh run and a
/// resume seeded with checkpoint evidence.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(assetID: String, mode: PhotoThumbnailRequestMode)] = []

    func record(_ assetID: String, mode: PhotoThumbnailRequestMode) {
        lock.lock()
        log.append((assetID, mode))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return log.count
    }
}

private final class EvidenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CheckpointEvidence] = []

    func append(_ evidence: CheckpointEvidence) {
        lock.lock()
        items.append(evidence)
        lock.unlock()
    }

    var entries: [CheckpointEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private struct CheckpointCountingLoader: PhotoThumbnailLoading {
    let images: [String: CGImage]
    let counter: RequestCounter

    func thumbnail(
        for assetID: String,
        targetPixelSize: Int,
        mode: PhotoThumbnailRequestMode
    ) async throws -> CGImage {
        counter.record(assetID, mode: mode)
        guard let image = images[assetID] else {
            throw PhotoContentError.unavailable
        }
        return image
    }
}

private final class CheckpointPermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let state: PermissionState

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

private struct CheckpointContactsPermissionService: ContactsPermissionServicing {
    func currentStatus() -> PermissionState { .notDetermined }
    func requestAccess() async -> PermissionState { .notDetermined }
}

// MARK: - Fixtures

/// Call counter for the injected library factory. `record()` runs on the detached task that
/// creates the reader (off the main actor) while `count` is read from the test's actor — a
/// lock guards both.
private final class FactoryCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct FakeLibrary: PhotoLibraryReading {
    let accessLevel: PermissionState = .authorized
    let records: [PhotoAssetRecord]
    var chunkDelay: TimeInterval = 0

    func assetCount() throws -> Int {
        records.count
    }

    func records(in range: Range<Int>) throws -> [PhotoAssetRecord] {
        if chunkDelay > 0 {
            Thread.sleep(forTimeInterval: chunkDelay)
        }
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, records.count)
        guard lower < upper else { return [] }
        return Array(records[lower..<upper])
    }
}

private struct FakeStorage: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        StorageSnapshot(totalCapacity: 100, availableCapacity: 60)
    }
}

private func makeRecord(
    id: String,
    width: Int = 1000,
    height: Int = 1000,
    daysAgo: Double = 0
) -> PhotoAssetRecord {
    PhotoAssetRecord(
        localIdentifier: id,
        mediaType: .image,
        mediaSubtypes: [],
        pixelWidth: width,
        pixelHeight: height,
        creationDate: Date(timeIntervalSince1970: 1_750_000_000 - daysAgo * 86_400),
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
