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

    @Test func factoryFailureSurfacesItsOwnMessage() {
        let env = makeEnv(permission: .authorized) {
            throw PhotoLibraryReadError.underlying("boom")
        }
        env.startSimilarityAnalysis()
        expectFailureMessage(env, equals: "boom")
    }

    @Test func accessDeniedFromFactoryMapsToThePermissionMessage() {
        let env = makeEnv(permission: .authorized) {
            throw PhotoLibraryReadError.accessDenied
        }
        env.startSimilarityAnalysis()
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

    @Test func catalogBuildUsesTheInjectedFactoryAndMapsDeniedAccess() {
        let env = makeEnv(permission: .denied) {
            throw PhotoLibraryReadError.accessDenied
        }
        env.startCatalogBuild()
        #expect(env.catalogState == .failed(.photoLibraryUnavailable))
    }

    @Test func startingWhileRunningIsIgnored() {
        let calls = FactoryCallBox()
        let env = AppEnvironment(
            storageProvider: FakeStorage(),
            makePhotoLibrary: {
                calls.record()
                return FakeLibrary(
                    records: [makeRecord(id: "x", width: 4000, height: 1000)],
                    chunkDelay: 0.3
                )
            }
        )
        env.photoPermissionState = .authorized
        env.startSimilarityAnalysis()
        #expect(calls.count == 1)

        env.startSimilarityAnalysis()
        #expect(calls.count == 1)
        #expect(env.analysisState.isRunning)
        env.cancelSimilarityAnalysis()
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
            makePhotoLibrary: factory
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

// MARK: - Fixtures

/// Call counter for the injected library factory. `record()` and `count` are only ever touched
/// from the main actor (the factory is invoked synchronously inside `AppEnvironment`), which is
/// why an unchecked box is safe here.
private final class FactoryCallBox: @unchecked Sendable {
    private var calls = 0

    func record() { calls += 1 }
    var count: Int { calls }
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
