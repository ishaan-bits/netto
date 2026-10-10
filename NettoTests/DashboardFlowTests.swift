import Foundation
import Testing
@testable import Netto

// MARK: Dashboard presentation derivations
//
// The dashboard's hero values and primary action are derived from real state — never
// measured or invented in the view. These tests pin the derivations, especially the
// all-zeros failed storage read, which must never surface as a real measurement.

struct DashboardFlowTests {
    private let runningProgress = PhotoAnalysisProgress(
        stage: .fingerprinting,
        completedUnits: 12,
        totalUnits: 48
    )

    @Test func notDeterminedPermissionAsksFirst() {
        let action = DashboardPresentation.libraryAction(
            permission: .notDetermined,
            catalog: .notStarted,
            analysis: .notStarted
        )
        #expect(action == .requestAccess)
    }

    @Test func deniedAndRestrictedPointAtSettings() {
        for permission in [PermissionState.denied, .restricted] {
            let action = DashboardPresentation.libraryAction(
                permission: permission,
                catalog: .notStarted,
                analysis: .notStarted
            )
            #expect(action == .openSettings)
        }
    }

    @Test func usablePermissionOffersAnalysis() {
        for permission in [PermissionState.authorized, .limited] {
            let action = DashboardPresentation.libraryAction(
                permission: permission,
                catalog: .notStarted,
                analysis: .notStarted
            )
            #expect(action == .analyze)
        }
    }

    @Test func runningAnalysisShowsStageAndFraction() {
        let action = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .running(runningProgress)
        )
        #expect(
            action == .analyzing(
                stage: SimilarPhotosPresentation.stageMessage(for: runningProgress),
                fraction: 0.25
            )
        )
    }

    @Test func failedAnalysisOffersRetryWithItsMessage() {
        let failure = PhotoAnalysisFailure.underlying("Could not read your library.")
        let action = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .failed(failure)
        )
        #expect(action == .retry(message: failure.userMessage))
    }

    @Test func completedOrCancelledRunOffersAnalysisAgain() {
        let completed = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.sampleResult)
        )
        #expect(completed == .analyze)

        let cancelled = DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .cancelled
        )
        #expect(cancelled == .analyze)
    }

    @Test func leftoverCatalogStateStillOffersAnalysis() {
        let catalogStates: [CatalogScanState] = [
            .completed(CatalogScanResult(records: [], libraryAssetCount: 0, accessLevel: .authorized)),
            .cancelled
        ]
        for catalog in catalogStates {
            let action = DashboardPresentation.libraryAction(
                permission: .authorized,
                catalog: catalog,
                analysis: .notStarted
            )
            #expect(action == .analyze)
        }
    }

    @Test func heroFractionIsNilBeforeTheRead() {
        #expect(DashboardPresentation.heroFraction(nil) == nil)
    }

    @Test func heroFractionIsNilForAFailedRead() {
        let failedRead = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
        #expect(DashboardPresentation.heroFraction(failedRead) == nil)
    }

    @Test func heroFractionMatchesTheRealMeasurement() {
        let snapshot = StorageSnapshot(
            totalCapacity: 128_000_000_000,
            availableCapacity: 32_000_000_000
        )
        #expect(DashboardPresentation.heroFraction(snapshot) == 0.75)
    }

    // MARK: - Scan ETA presentation

    @Test func scanStatusForwardsTheETAIntoTheScanningState() {
        let status = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .running(PhotoAnalysisProgress(
                stage: .extractingFeatures,
                completedUnits: 5_397,
                totalUnits: 41_036
            )),
            eta: .remaining(seconds: 120)
        )
        guard case .scanning(_, let fraction, let eta) = status else {
            Issue.record("expected scanning, got \(status)")
            return
        }
        #expect(eta == .remaining(seconds: 120))
        #expect(fraction != nil)
    }

    @Test func scanningCopyShowsStageCountsThenTimeRemaining() {
        let stage = "Analyzing 5397 of 41036 images…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: 0.13,
            eta: .remaining(seconds: 120)
        ))
        #expect(copy.title == "Scanning your library")
        #expect(copy.body == stage + "\n~2 min remaining")
        #expect(copy.buttonTitle == "Cancel")
    }

    @Test func calculatingLineShowsBeforeEnoughThroughputSamples() {
        let stage = "Fingerprinting…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: nil,
            eta: .calculating
        ))
        #expect(copy.body == stage + "\nCalculating time remaining…")
    }

    @Test func finishingLineWinsOverAUntrustworthyCountdown() {
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: "Comparing 40 of 41 groups…",
            fraction: 0.98,
            eta: .finishing
        ))
        #expect(copy.body.contains("Finishing analysis…"))
        #expect(!copy.body.contains("sec remaining"))
        #expect(!copy.body.contains("min remaining"))
        #expect(!copy.body.contains("Calculating"))
    }

    @Test func indeterminateStageAddsNoTimeLine() {
        let stage = "Counting assets…"
        let copy = DashboardPresentation.scanCopy(for: .scanning(
            stage: stage,
            fraction: nil,
            eta: .indeterminate
        ))
        #expect(copy.body == stage)
    }

    @Test func completedAndCancelledStatesCarryNoETA() {
        let completed = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .completed(Self.sampleResult),
            eta: .remaining(seconds: 120)
        )
        #expect(completed == .finished(analyzed: 4, total: 4, groups: 0, lastScannedAt: nil))

        let cancelled = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .cancelled,
            eta: .calculating
        )
        #expect(cancelled == .cancelled)
    }

    private static let sampleResult = PhotoAnalysisResult(
        exactGroups: [],
        similarGroups: [],
        unavailableAssets: [],
        descriptorKind: nil,
        visionAvailable: false,
        similarityThreshold: nil,
        totalRecordCount: 4,
        candidateBucketCount: 0,
        candidatePairCount: 0
    )
}

// MARK: - Paused-state presentation
//
// A run interrupted by backgrounding/expiration/termination must read as *paused* — its
// saved stage and position, never a live scan and never a countdown (the estimator's
// anchors were dropped with the pause; a ticking ETA would be fiction).

struct DashboardPausedPresentationTests {
    private let savedProgress = PhotoAnalysisProgress(
        stage: .extractingFeatures,
        completedUnits: 2_048,
        totalUnits: 8_192
    )

    @Test func pausedAnalysisPresentsSavedProgressWithoutAnETA() {
        let status = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .paused(savedProgress),
            eta: .remaining(seconds: 120)
        )
        guard case .paused(let stage, let fraction) = status else {
            Issue.record("expected paused, got \(status)")
            return
        }
        #expect(stage == SimilarPhotosPresentation.stageMessage(for: savedProgress))
        #expect(fraction == 0.25)

        let copy = DashboardPresentation.scanCopy(for: status)
        #expect(copy.title == "Scan paused")
        #expect(copy.buttonTitle == "Resume")
        #expect(copy.body == stage)
        #expect(!copy.body.contains("remaining"))
    }

    @Test func pausedCatalogPresentsTheSavedEnumerationCounts() {
        let progress = CatalogScanProgress(enumeratedCount: 1_024, totalCount: 4_096)
        let status = DashboardPresentation.scanStatus(
            permission: .authorized,
            catalog: .paused(progress),
            analysis: .notStarted,
            eta: .calculating
        )
        guard case .paused(let stage, let fraction) = status else {
            Issue.record("expected paused, got \(status)")
            return
        }
        #expect(stage == DashboardPresentation.catalogStage(progress))
        #expect(fraction == 0.25)
        #expect(DashboardPresentation.scanCopy(for: status).buttonTitle == "Resume")
    }

    @Test func pausedStateIsNotRunningButCarriesItsProgress() {
        let analysis = PhotoAnalysisState.paused(savedProgress)
        #expect(!analysis.isRunning)
        #expect(analysis.pausedProgress == savedProgress)

        let catalog = CatalogScanState.paused(CatalogScanProgress(
            enumeratedCount: 10,
            totalCount: 100
        ))
        #expect(!catalog.isRunning)
        #expect(catalog.pausedProgress == CatalogScanProgress(enumeratedCount: 10, totalCount: 100))

        let blur = BlurAnalysisState.paused(BlurAnalysisProgress(
            completedUnits: 5,
            totalUnits: 50
        ))
        #expect(!blur.isRunning)
        #expect(blur.pausedProgress == BlurAnalysisProgress(completedUnits: 5, totalUnits: 50))
    }

    @Test func theLibraryCTAStillOffersAnalysisWhilePaused() {
        // Deliberate split: the CTA derivation keeps saying "analyze" (a paused run is not
        // running), and the scan card's paused branch owns the Resume action instead.
        #expect(DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .notStarted,
            analysis: .paused(savedProgress)
        ) == .analyze)
        #expect(DashboardPresentation.libraryAction(
            permission: .authorized,
            catalog: .paused(CatalogScanProgress(enumeratedCount: 1, totalCount: 2)),
            analysis: .notStarted
        ) == .analyze)
    }
}

// MARK: - Lifecycle: expiration, checkpoints, foreground resume
//
// Driven through the `BackgroundTaskScheduling` seam — a simulator test cannot reproduce
// iOS suspension, so expiration is fired deterministically and the pause/checkpoint path
// is exercised exactly as written.

@MainActor
struct LifecycleCheckpointFlowTests {
    @Test func expirationPausesSavesACheckpointAndForegroundResumesWithoutDuplicates() async throws {
        let checkpointStore = InMemoryScanCheckpointStore()
        let background = FakeBackgroundTaskScheduler()
        let env = makeLifecycleEnv(
            recordCount: 3_072,
            chunkDelay: 1.2,
            checkpointStore: checkpointStore,
            backgroundTasks: background
        )

        env.handleLifecycle(.background)
        env.startCatalogBuild()
        guard env.catalogState.isRunning else {
            Issue.record("catalog build did not start: \(env.catalogState)")
            return
        }
        // The background task is held only while backgrounded with work in flight.
        #expect(background.isHolding)

        // Wait for two real throughput observations (the estimator's minimum) so the
        // pre-pause ETA is an actual countdown, not a vacuous "calculating".
        // Wait until the estimator has a denominator *and* real throughput (`.calculating`
        // before samples, `.indeterminate` while the count is unknown) — the first state
        // where the countdown exists, so the pre-pause progress on screen has the real total.
        let etaDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        etaWait: while ContinuousClock.now < etaDeadline {
            switch env.scanETA() {
            case .calculating, .indeterminate:
                try? await Task.sleep(for: .milliseconds(20))
                continue etaWait
            case .remaining, .finishing:
                break etaWait
            }
        }
        switch env.scanETA() {
        case .remaining, .finishing:
            break
        default:
            Issue.record("expected a real ETA before pausing, got \(env.scanETA())")
        }

        background.fireExpiration()

        // Paused: the run stopped, the saved progress is on screen, and the checkpoint
        // carries exactly that progress — synchronously, before the task was released.
        guard case .paused(let paused) = env.catalogState else {
            Issue.record("expected paused catalog, got \(env.catalogState)")
            return
        }
        #expect(paused.totalCount == 3_072)
        #expect(paused.enumeratedCount > 0)
        #expect(!background.isHolding)
        // Estimator anchors were dropped with the pause: no live countdown survives.
        #expect(env.scanETA() == .calculating)

        let saved = try #require(checkpointStore.load())
        #expect(saved.kind == .catalog)
        #expect(saved.stage == "catalog")
        #expect(saved.completedUnits == paused.enumeratedCount)
        #expect(saved.totalUnits == 3_072)

        // Foregrounding resumes the saved run automatically (this session interrupted it).
        env.handleLifecycle(.active)
        guard env.catalogState.isRunning else {
            Issue.record("foreground did not resume the paused catalog: \(env.catalogState)")
            return
        }

        let finished = await waitForCatalog(env, timeoutSeconds: 30)
        guard case .completed(let result) = finished else {
            Issue.record("resumed catalog did not complete: \(finished)")
            return
        }
        // Full enumeration from zero (offsets are never persisted) with every asset
        // present exactly once — resume never duplicates records.
        #expect(result.records.count == 3_072)
        #expect(Set(result.records.map(\.localIdentifier)).count == 3_072)
        // Completion released the checkpoint kind-aware; nothing is left to resume.
        #expect(checkpointStore.load() == nil)
        #expect(!background.isHolding)
    }

    @Test func relaunchRestoresACatalogCheckpointAsPausedWithoutAutoStarting() async {
        let checkpointStore = InMemoryScanCheckpointStore()
        try? checkpointStore.save(makeCatalogCheckpoint(
            runSequence: 5,
            completedUnits: 1_024,
            totalUnits: 4_096
        ))
        let background = FakeBackgroundTaskScheduler()
        let factoryCalls = FactoryCallBox()
        let env = makeLifecycleEnv(
            recordCount: 600,
            chunkDelay: 0,
            checkpointStore: checkpointStore,
            backgroundTasks: background,
            factoryCalls: factoryCalls
        )

        await env.bootstrap()

        // Restored as paused with the saved counts — and a relaunch never auto-starts:
        // resuming a previous session's run is always an explicit tap.
        #expect(env.catalogState == .paused(CatalogScanProgress(
            enumeratedCount: 1_024,
            totalCount: 4_096
        )))
        #expect(factoryCalls.count == 0)
        #expect(checkpointStore.load() != nil)
        #expect(env.scanETA() == .calculating)

        env.resumeInterruptedWork()
        let finished = await waitForCatalog(env, timeoutSeconds: 20)
        guard case .completed(let result) = finished else {
            Issue.record("explicit resume did not complete: \(finished)")
            return
        }
        #expect(result.records.count == 600)
        #expect(checkpointStore.load() == nil)
        #expect(factoryCalls.count == 1)
    }

    @Test func anUnusableSimilarityCheckpointIsDroppedInsteadOfResumed() async {
        let checkpointStore = InMemoryScanCheckpointStore()
        try? checkpointStore.save(ScanCheckpoint(
            runSequence: 9,
            kind: .similarity,
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            stage: "not-a-real-stage",
            completedUnits: 3,
            totalUnits: 9
        ))
        let background = FakeBackgroundTaskScheduler()
        let factoryCalls = FactoryCallBox()
        let env = makeLifecycleEnv(
            recordCount: 50,
            chunkDelay: 0,
            checkpointStore: checkpointStore,
            backgroundTasks: background,
            factoryCalls: factoryCalls
        )

        await env.bootstrap()

        // A paused card that can never show an honest stage is worse than no card: the
        // file is cleared, the state stays fresh, and Resume has nothing to act on.
        #expect(env.analysisState == .notStarted)
        #expect(checkpointStore.load() == nil)
        #expect(checkpointStore.clearCount == 1)
        env.resumeInterruptedWork()
        #expect(env.analysisState == .notStarted)
        #expect(factoryCalls.count == 0)
    }

    @Test func backgroundWithNoWorkInFlightNeverHoldsATask() {
        let background = FakeBackgroundTaskScheduler()
        let env = makeLifecycleEnv(
            recordCount: 10,
            chunkDelay: 0,
            checkpointStore: InMemoryScanCheckpointStore(),
            backgroundTasks: background
        )

        env.handleLifecycle(.background)
        #expect(!background.isHolding)
        #expect(background.beginCount == 0)

        env.handleLifecycle(.active)
        #expect(!background.isHolding)
        #expect(background.beginCount == 0)
    }

    @Test func goingInactiveFlushesButNeitherPausesNorHolds() async {
        let checkpointStore = InMemoryScanCheckpointStore()
        let background = FakeBackgroundTaskScheduler()
        let env = makeLifecycleEnv(
            recordCount: 2_048,
            chunkDelay: 1.0,
            checkpointStore: checkpointStore,
            backgroundTasks: background
        )

        env.startCatalogBuild()
        guard env.catalogState.isRunning else {
            Issue.record("catalog build did not start: \(env.catalogState)")
            return
        }
        env.handleLifecycle(.inactive)

        // `.inactive` is a best-effort flush only: the app may come straight back, so the
        // run keeps running and no task is claimed.
        #expect(env.catalogState.isRunning)
        #expect(!background.isHolding)

        env.cancelCatalogBuild()
        #expect(env.catalogState == .cancelled)
        #expect(checkpointStore.load() == nil)
    }

    // MARK: Helpers

    @MainActor
    private func waitForCatalog(
        _ env: AppEnvironment,
        timeoutSeconds: Double
    ) async -> CatalogScanState {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while env.catalogState.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return env.catalogState
    }
}

// MARK: - Lifecycle fixtures

private func makeCatalogCheckpoint(
    runSequence: Int,
    completedUnits: Int,
    totalUnits: Int
) -> ScanCheckpoint {
    ScanCheckpoint(
        runSequence: runSequence,
        kind: .catalog,
        startedAt: Date(timeIntervalSinceReferenceDate: 10),
        updatedAt: Date(timeIntervalSinceReferenceDate: 20),
        stage: "catalog",
        completedUnits: completedUnits,
        totalUnits: totalUnits
    )
}

@MainActor
private func makeLifecycleEnv(
    recordCount: Int,
    chunkDelay: TimeInterval,
    checkpointStore: InMemoryScanCheckpointStore,
    backgroundTasks: FakeBackgroundTaskScheduler,
    factoryCalls: FactoryCallBox = FactoryCallBox()
) -> AppEnvironment {
    let env = AppEnvironment(
        storageProvider: LifecycleStorage(),
        photoPermission: LifecyclePermissionService(.authorized),
        contactsPermission: LifecycleContactsPermissionService(),
        makePhotoLibrary: {
            factoryCalls.record()
            return LifecycleLibrary(
                records: lifecycleRecords(count: recordCount),
                chunkDelay: chunkDelay
            )
        },
        // Completions and restores in this suite must never touch the app's real files.
        scanSnapshotStore: InMemoryScanSnapshotStore(),
        checkpointStore: checkpointStore,
        backgroundTasks: backgroundTasks
    )
    env.photoPermissionState = .authorized
    return env
}

/// `count` same-bucket image records with distinct ids — enough enumeration (with a
/// per-chunk delay) for two real ETA observations before expiration fires.
private func lifecycleRecords(count: Int) -> [PhotoAssetRecord] {
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    return (0..<count).map { index in
        PhotoAssetRecord(
            localIdentifier: "catalog-\(index)",
            mediaType: .image,
            mediaSubtypes: [],
            pixelWidth: 1000,
            pixelHeight: 1000,
            creationDate: base.addingTimeInterval(-Double(index)),
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

/// Call counter for the injected library factory. `record()` runs on the detached task
/// that creates the reader (off the main actor) while `count` is read from the test's
/// actor — a lock guards both.
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

private struct LifecycleLibrary: PhotoLibraryReading {
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

private struct LifecycleStorage: StorageProviding {
    func deviceStorage() async -> StorageSnapshot {
        StorageSnapshot(totalCapacity: 100, availableCapacity: 60)
    }
}

private final class LifecyclePermissionService: PhotoLibraryPermissionServicing, @unchecked Sendable {
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

private struct LifecycleContactsPermissionService: ContactsPermissionServicing {
    func currentStatus() -> PermissionState { .notDetermined }
    func requestAccess() async -> PermissionState { .notDetermined }
}
