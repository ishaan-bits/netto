import Observation
import SwiftUI

/// Which selection produced a deletion plan. Every source shares the one plan → confirmation →
/// mutation → verification pipeline — the source only decides which selection model a plan is
/// built from and which dataset fingerprint it is validated against.
enum DeletionSelectionSource: Sendable, Equatable {
    case similarPhotos
    case screenshots
    case videos
    case blurReview
}

/// `@Observable` rather than `ObservableObject`: every view tracks only the properties it
/// actually reads, so a selection toggle no longer invalidates the dashboard (and a progress
/// tick no longer re-renders screens that never read progress).
@MainActor
@Observable
final class AppEnvironment {
    let storageProvider: any StorageProviding
    let photoPermission: any PhotoLibraryPermissionServicing
    let contactsPermission: any ContactsPermissionServicing
    /// Review thumbnails: bounded, coalesced, pixel-capped (never full-resolution pixels).
    let thumbnails: ThumbnailStore
    /// The raw thumbnail loader behind the cache. The Photo Details large preview loads
    /// through this directly: its request is the explicitly user-requested preview policy
    /// (network allowed, degraded frames surfaced), and its bitmap is released with the screen
    /// instead of being pinned in the strip cache. Scanner passes never see this path — they
    /// go through `thumbnails` / the engine's own loader with the local-only options.
    let thumbnailLoader: any PhotoThumbnailLoading
    /// Real byte measurement for the reviewed selection (bounded, never during enumeration).
    let sizeProvider: any AssetSizeProviding
    /// The deletion boundary — the only path from this app to Photos mutation.
    let deletionService: any PhotoDeleting
    /// Last completed scan, persisted so a relaunch restores results without a new scan.
    /// Injected so tests use temporary storage instead of the app's real snapshot file.
    let scanSnapshotStore: any ScanSnapshotStore
    /// The shared App Group summary the home screen widget renders. Injected so tests
    /// record writes (and reload requests) instead of touching the real container.
    let widgetSummaryStore: any WidgetSummaryStoring

    var flowState: AppFlowState = .launching
    var prompt: PermissionPrompt = .none
    var photoPermissionState: PermissionState = .notDetermined
    var contactsPermissionState: PermissionState = .notDetermined
    var storageSnapshot: StorageSnapshot?
    var catalogState: CatalogScanState = .notStarted {
        didSet { blurDatasetGeneration &+= 1 }
    }
    var analysisState: PhotoAnalysisState = .notStarted
    /// When the current completed result reached its terminal state — from the restored
    /// snapshot on launch, or `Date()` on a fresh completion. `nil` before any scan has
    /// completed; drives the dashboard's dynamic "Last scanned …" text.
    var lastScanCompletedAt: Date?
    var selection = PhotoSelectionModel()
    /// Screenshots marked for cleanup — a filter over the catalog, not a second enumeration.
    var screenshotSelection = ScreenshotSelectionModel()
    /// Videos marked for cleanup — a filter over the catalog, not a second enumeration.
    var videoSelection = DatasetSelectionModel()
    /// The sharpness pass over the catalog's images (milestone 5B). In-memory only —
    /// unlike the similarity snapshot it is never persisted, so a verdict can never
    /// outlive the catalog it was computed over.
    var blurAnalysisState: BlurAnalysisState = .notStarted {
        didSet { blurDatasetGeneration &+= 1 }
    }
    /// Injected clock stamped into a completed result's `scannedAt`. Production uses the
    /// default (`Date()`); tests pin it so a completed run is exactly reproducible.
    var blurAnalysisClock: @Sendable () -> Date = { Date() }
    /// Photos marked for cleanup from the Potentially Blurry grid. A *separate*
    /// `PhotoSelectionModel` from `selection` (never the same instance): candidates are
    /// admitted through `admitLibraryAssets` — admission alone never selects anything —
    /// and sharing a model would let one feature's toggles mark photos in another.
    var blurSelection = PhotoSelectionModel()
    /// Measured bytes for the video list: explicit resolution state the photo flows don't need
    /// (they resolve sizes only at review time), so the largest-first ordering can be honest.
    var videoSizeResolution: VideoSizeResolution = .idle
    /// The deletion state machine (§16). Every change goes through `applyDeletion`.
    var deletionState: DeletionState = .noSelection
    /// The space-freed summary for a completed deletion — set exactly once per outcome, in
    /// `handleDeletionOutcome`, together with `flowState == .deletionCompleted`, and only
    /// when at least one item was verified removed. Cleared the moment that result is
    /// dismissed; never set from the view layer, never persisted.
    var spaceFreedSummary: SpaceFreedSummary?
    /// Duplicate Contacts: read + local duplicate detection state.
    var contactScanState: ContactScanState = .notStarted
    /// Selection over the duplicate group currently open.
    var contactSelection = ContactGroupSelection()
    /// The contacts action state machine (§16). Every change goes through `applyContactAction`.
    var contactActionState: ContactActionState = .noSelection

    private let makePhotoLibrary: @Sendable () throws -> any PhotoLibraryReading
    /// Contact enumeration seam (real store by default; fixtures in DEBUG/preview/tests).
    let makeContactReader: @Sendable () -> any ContactReading
    /// The contacts mutation boundary — the only path from this app to Contacts writes.
    let contactMutationService: any ContactMutating
    /// Identity of this app session; plans from another session can never execute.
    let deletionSessionToken: String
    private var catalogTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// In-flight sharpness pass, if any.
    private var blurAnalysisTask: Task<Void, Never>?
    /// Bumped on every sharpness start and cancel. An in-flight run compares it before
    /// each state write, so a cancelled run can never overwrite a newer one's state.
    private var blurAnalysisGeneration = 0
    /// Bumped on every catalog start, cancel, and supersede. An in-flight catalog task compares
    /// it before each state write, so a cancelled run can never overwrite a newer one's state.
    private var catalogGeneration = 0
    /// Bumped on every start and cancel. An in-flight run compares it before each state write,
    /// so a cancelled run can never overwrite a newer one's state.
    private var analysisGeneration = 0
    /// Progress coalescing (milestone 4C): the engine already throttles emissions, but every
    /// event still lands in observed storage — on a long scan the resulting update stream
    /// starves the main actor and delays the terminal state by minutes (measured: ~18 min of
    /// drain after the pre-4C engine finished its own ~20 min). Apply a progress event only when the stage
    /// changes, a stage reaches its terminal count, or `progressCoalesceInterval` has passed
    /// since the last applied event; unapplied events are not lost — the next applied event
    /// carries the newest counters, and completion is its own unconditional event.
    private var lastAppliedProgressAt: TimeInterval = 0
    private var lastAppliedStage: PhotoAnalysisStage?
    private let progressCoalesceInterval: TimeInterval = 0.25
    /// Rolling-throughput ETA for the active scan. Fed only at the coalesced progress points
    /// below (analysis and catalog), read on demand by the dashboard — no extra observation
    /// traffic per asset, no second progress system.
    private var scanETAEstimator = ScanETAEstimator()
    /// Bumped on every plan build; a superseded build discards its result instead of writing it.
    private var planBuildGeneration = 0
    /// In-flight video size measurement, if any (bounded sequential batches).
    private var videoSizeTask: Task<Void, Never>?
    /// Bumped on every measurement start and cancel. Each batch compares it before writing, so
    /// a cancelled run can never overwrite newer state.
    private var videoSizeGeneration = 0
    /// In-flight contacts scan (read + duplicate detection), if any.
    var contactScanTask: Task<Void, Never>?
    /// Bumped on every contacts scan start and cancel. A late completion compares it before
    /// writing, so a cancelled scan can never overwrite newer state.
    var contactScanGeneration = 0
    /// Which action (delete/merge) the current/last contact review was opened with; a stale
    /// review re-prepares the same choice, never a different one.
    var contactReviewChoice: ContactActionChoice?
    /// Which source the current/last plan was built from; confirmation validates against it.
    private var planSource: DeletionSelectionSource = .similarPhotos
    /// Bumped by the `didSet`s on `catalogState` and `blurAnalysisState` — the two inputs of
    /// the blur-candidate record cache. Selection and progress-unrelated writes never bump it.
    @ObservationIgnored private var blurDatasetGeneration: UInt64 = 0
    /// What `blurDatasetGeneration` the cache below reflects; starts as `UInt64.max` so the
    /// first read always builds.
    @ObservationIgnored private var builtBlurDatasetGeneration: UInt64 = .max
    /// The cached blur-candidate records. Ignored by observation: it is written *during* the
    /// read that misses, and mutating observed state inside a view update would re-invalidate
    /// the very reader that is asking.
    @ObservationIgnored private var builtBlurDatasetRecords: [PhotoAssetRecord] = []

    init(
        storageProvider: any StorageProviding = SystemStorageProvider(),
        photoPermission: any PhotoLibraryPermissionServicing = PhotoLibraryPermissionService(),
        contactsPermission: any ContactsPermissionServicing = ContactsPermissionService(),
        makePhotoLibrary: @escaping @Sendable () throws -> any PhotoLibraryReading = {
            try SystemPhotoLibrary()
        },
        makeContactReader: @escaping @Sendable () -> any ContactReading = {
            ContactStoreReader()
        },
        thumbnailLoader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader(),
        sizeProvider: any AssetSizeProviding = PhotoKitAssetSizeProvider(),
        deletionService: any PhotoDeleting = PhotoDeletionService(),
        contactMutationService: any ContactMutating = ContactMutationService(),
        scanSnapshotStore: any ScanSnapshotStore = FileScanSnapshotStore(),
        widgetSummaryStore: any WidgetSummaryStoring = FileWidgetSummaryStore(),
        sessionToken: String = UUID().uuidString
    ) {
        self.storageProvider = storageProvider
        self.photoPermission = photoPermission
        self.contactsPermission = contactsPermission
        self.makePhotoLibrary = makePhotoLibrary
        self.makeContactReader = makeContactReader
        self.thumbnailLoader = thumbnailLoader
        self.thumbnails = ThumbnailStore(loader: thumbnailLoader)
        self.sizeProvider = sizeProvider
        self.deletionService = deletionService
        self.contactMutationService = contactMutationService
        self.scanSnapshotStore = scanSnapshotStore
        self.widgetSummaryStore = widgetSummaryStore
        self.deletionSessionToken = sessionToken
    }

    /// Blur-candidate records in catalog order, cached across renders.
    ///
    /// `BlurDataset.records` filters the *entire* catalog on every call — O(library) work
    /// that used to run inside the blurry grid's render. Both inputs are read first (which
    /// registers them with whatever observer is asking, so a change to either still
    /// invalidates the reader), then the filter runs only when a `didSet` generation bump
    /// says the cached build is stale. A progress tick never re-filters: the grid is not on
    /// screen while the pass runs, and reads are what build the cache.
    var blurDatasetRecords: [PhotoAssetRecord] {
        guard case .completed(let catalog) = catalogState, !catalog.isEmpty else {
            builtBlurDatasetRecords = []
            builtBlurDatasetGeneration = blurDatasetGeneration
            return []
        }
        guard case .completed(let blurResult) = blurAnalysisState else {
            builtBlurDatasetRecords = []
            builtBlurDatasetGeneration = blurDatasetGeneration
            return []
        }
        if builtBlurDatasetGeneration != blurDatasetGeneration {
            builtBlurDatasetRecords = BlurDataset.records(in: blurResult, catalog: catalog)
            builtBlurDatasetGeneration = blurDatasetGeneration
        }
        return builtBlurDatasetRecords
    }

    func bootstrap() async {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
        storageSnapshot = await storageProvider.deviceStorage()
        // Restore the last completed scan (if any) into the same state path a fresh
        // completion writes. No PhotoKit work is started: a missing, corrupt, or
        // incompatible snapshot simply leaves the existing first-run state untouched.
        let restoredSnapshot = scanSnapshotStore.loadLatest()
        if let restoredSnapshot {
            restoreCompletedScan(restoredSnapshot)
        }
        // One widget-summary write per launch, and only when none exists yet: a launch
        // never overwrites what a scan or cleanup wrote since — it only repairs absence
        // (first run, wiped container, corrupt file).
        await writeWidgetSummaryOnLaunch(snapshot: restoredSnapshot)
        flowState = .dashboard
    }

    /// Applies a persisted snapshot exactly as a fresh `.completed` write would: results into
    /// `analysisState`, the deterministic default selection over the restored groups, and the
    /// persisted completion date. Best-effort by design — an unusable snapshot never crashes
    /// and never triggers analysis.
    private func restoreCompletedScan(_ snapshot: ScanSnapshot) {
        analysisState = .completed(snapshot.result)
        selection = PhotoSelectionModel(result: snapshot.result)
        lastScanCompletedAt = snapshot.completedAt
    }

    /// Persists a newly completed scan, replacing the previous snapshot only now — cancelled,
    /// failed, and interrupted runs never reach this point. Best-effort: a failed write is
    /// ignored (the fresh result is already on screen) and never fails the scan itself.
    /// Returns the completion date so the caller can publish it to the widget summary.
    @discardableResult
    private func persistCompletedScan(_ result: PhotoAnalysisResult) -> Date {
        let completedAt = Date()
        let snapshot = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: UUID().uuidString,
            completedAt: completedAt,
            result: result
        )
        try? scanSnapshotStore.save(snapshot)
        lastScanCompletedAt = completedAt
        return completedAt
    }

    /// Refreshes the widget's shared summary from a completed scan: the scan's own
    /// completion date is the truth for `.scanReady`, and a scan carries no byte figure —
    /// the widget shows the status, never a number, until a cleanup measures one.
    func writeWidgetSummaryAfterScanCompleted(at completedAt: Date) async {
        await writeWidgetSummary(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .scanReady,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: completedAt
        ))
    }

    /// Refreshes the widget's shared summary after a confirmed cleanup: only a measured
    /// figure becomes `.lastCleanup`. A cleanup with nothing measured writes nothing —
    /// there is no zero, no fallback, and no fabricated amount to show.
    func writeWidgetSummaryAfterCleanup(_ freed: SpaceFreedSummary) async {
        guard freed.hasSpaceFigure else { return }
        await writeWidgetSummary(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: .lastCleanup,
            estimateBytes: freed.measuredBytes,
            isEstimated: true,
            updatedAt: Date()
        ))
    }

    /// Write-if-absent used by `bootstrap`: repairs a missing widget file (first run,
    /// wiped container, corrupt or unsupported content) from the restored scan — and
    /// writes `.empty` when there is nothing to restore. Never replaces a figure a scan
    /// or cleanup wrote since the file was last read.
    private func writeWidgetSummaryOnLaunch(snapshot: ScanSnapshot?) async {
        if await widgetSummaryStore.load() != nil { return }
        await writeWidgetSummary(WidgetSummary(
            schemaVersion: WidgetSummary.currentSchemaVersion,
            status: snapshot == nil ? .empty : .scanReady,
            estimateBytes: nil,
            isEstimated: false,
            updatedAt: snapshot?.completedAt ?? Date()
        ))
    }

    /// The one save-and-reload path for the widget summary: one atomic write, then one
    /// WidgetKit reload request — only when the write actually happened. Best-effort by
    /// design: the app never depends on the widget file existing.
    private func writeWidgetSummary(_ summary: WidgetSummary?) async {
        guard let summary else { return }
        do {
            try await widgetSummaryStore.save(summary)
            widgetSummaryStore.requestWidgetReload()
        } catch {
            // Without a shared container the widget renders its empty state instead;
            // scanning, deletion, and every app flow are unaffected by this write.
        }
    }

    /// Handles a `netto://` deep link — today only from the home screen widget's tap.
    /// Navigational only: it never starts a scan, never touches analysis, selection, or
    /// deletion state, and is ignored outright while the launch or a deletion
    /// (including its summary screen) owns the flow. An unknown or malformed URL still
    /// lands on the dashboard — opening the app safely *is* the fallback.
    func handleDeepLink(_ url: URL) {
        guard flowState != .launching,
              flowState != .deletionCompleted,
              !deletionState.isDeleting
        else { return }
        switch WidgetDeepLink.route(from: url) {
        case .dashboard, .unknown:
            flowState = .dashboard
        }
    }

    func refreshStorage() async {
        storageSnapshot = await storageProvider.deviceStorage()
    }

    func refreshPermissions() {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
        reconcileContactReviewPermission()
    }

    func requestPhotoAccess() async {
        guard photoPermissionState == .notDetermined else {
            refreshPermissions()
            return
        }
        photoPermissionState = await photoPermission.requestAccess()
    }

    func requestContactsAccess() async {
        guard contactsPermissionState == .notDetermined else {
            refreshPermissions()
            return
        }
        contactsPermissionState = await contactsPermission.requestAccess()
        reconcileContactReviewPermission()
    }

    /// Builds the metadata catalog. Enumeration runs on a detached producer task; this loop only
    /// consumes ordered events, so the main actor stays responsive while the library is read.
    func startCatalogBuild() {
        // One library reader at a time: an analysis run owns its own catalog stage, and a
        // rebuild started underneath an in-flight deletion would complete with pre-mutation
        // data. A sharpness pass snapshots the catalog records it was started with, so a
        // rebuild landing mid-run would hand its results a catalog that no longer matches.
        // All three requests are explicit user actions, so dropping this one is honest.
        guard !analysisState.isRunning else { return }
        guard !blurAnalysisState.isRunning else { return }
        guard !deletionState.isDeleting else { return }
        catalogTask?.cancel()
        catalogGeneration += 1
        let generation = catalogGeneration

        let reading: any PhotoLibraryReading
        do {
            reading = try makePhotoLibrary()
        } catch let error as PhotoLibraryReadError {
            catalogState = .failed(error.catalogFailure)
            return
        } catch {
            catalogState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        let builder = PhotoCatalogBuilder()
        scanETAEstimator.reset()
        scanETAEstimator.record(
            stage: "catalog",
            completed: CatalogScanProgress.indeterminate.enumeratedCount,
            total: CatalogScanProgress.indeterminate.totalCount,
            at: ScanETAEstimator.monotonicNow()
        )
        catalogState = .running(.indeterminate)

        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in builder.makeScanStream(reading: reading) {
                    // A superseded run stops immediately: every write below would land data
                    // from an older read on top of newer state.
                    guard self.isCurrentCatalog(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        if self.catalogState.isRunning {
                            self.catalogState = .running(progress)
                            self.scanETAEstimator.record(
                                stage: "catalog",
                                completed: progress.enumeratedCount,
                                total: progress.totalCount,
                                at: ScanETAEstimator.monotonicNow()
                            )
                        }
                    case .completed(let result):
                        self.noteCatalogCompleted(result, standalone: true)
                    }
                }
            } catch is CancellationError {
                guard self.isCurrentCatalog(generation) else { return }
                self.catalogState = .cancelled
            } catch let failure as CatalogScanFailure {
                guard self.isCurrentCatalog(generation) else { return }
                self.catalogState = failure == .cancelled ? .cancelled : .failed(failure)
            } catch {
                guard self.isCurrentCatalog(generation) else { return }
                self.catalogState = .failed(.underlying("Photos access is required to read your library."))
            }
        }
    }

    func cancelCatalogBuild() {
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration += 1
        if catalogState.isRunning {
            catalogState = .cancelled
        }
    }

    private func isCurrentCatalog(_ generation: Int) -> Bool {
        catalogGeneration == generation
    }

    // MARK: - Similarity analysis

    /// Runs the full review pipeline: metadata catalog read, then similarity analysis over it.
    ///
    /// Analysis reads only — it never mutates the photo library. The catalog phase reports
    /// through `analysisState`'s `preparing` stage so the review screen shows one continuous
    /// run; `catalogState` is updated to `.completed` when the read finishes (never left
    /// running: a standalone build is cancelled first, because two concurrent reads of the same
    /// library would only double the work). Starting a new analysis also invalidates any
    /// prepared deletion review: plans are bound to the dataset they were built from.
    func startSimilarityAnalysis() {
        guard !analysisState.isRunning else { return }
        // Stage A below rebuilds the catalog, and a sharpness pass owns a snapshot of the
        // records it was started with — a rebuild landing mid-run would hand its results a
        // catalog that no longer matches (the same reason startCatalogBuild refuses). All
        // three requests are explicit user actions, so dropping this one is honest.
        guard !blurAnalysisState.isRunning else { return }
        // Never rebuild datasets underneath an in-flight Photos mutation.
        guard !deletionState.isDeleting else { return }
        guard photoPermissionState.isUsable else {
            analysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        // A fresh analysis supersedes any prepared plan.
        planBuildGeneration += 1
        applyDeletion(.noSelection)

        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        selection = PhotoSelectionModel()

        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration += 1
        if catalogState.isRunning {
            catalogState = .cancelled
        }

        let reading: any PhotoLibraryReading
        do {
            reading = try makePhotoLibrary()
        } catch let error as PhotoLibraryReadError {
            analysisState = .failed(Self.analysisFailure(for: error))
            return
        } catch {
            analysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }

        lastAppliedProgressAt = 0
        lastAppliedStage = nil
        scanETAEstimator.reset()
        analysisState = .running(
            PhotoAnalysisProgress(stage: .preparing, completedUnits: 0, totalUnits: 0)
        )

        let builder = PhotoCatalogBuilder()
        #if DEBUG
        // M4B validation hook: `NETTO_SCAN_METRICS=1` injects the signpost observer and the
        // metrics recorder so an end-to-end run can be measured from `log stream`. Production
        // never sets the variable; without it the engine is exactly as before (no telemetry).
        let engine: PhotoSimilarityEngine
        if ProcessInfo.processInfo.environment["NETTO_SCAN_METRICS"] == "1" {
            engine = PhotoSimilarityEngine(
                stageObserver: SignpostStageObserver(),
                metrics: AnalysisMetrics()
            )
        } else {
            engine = PhotoSimilarityEngine()
        }
        #else
        let engine = PhotoSimilarityEngine()
        #endif

        analysisTask = Task { [weak self] in
            guard let self else { return }

            // Stage A — metadata catalog read, reported as `preparing`.
            var built: CatalogScanResult?
            do {
                for try await event in builder.makeScanStream(reading: reading) {
                    guard self.isCurrentAnalysis(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        self.analysisState = .running(PhotoAnalysisProgress(
                            stage: .preparing,
                            completedUnits: progress.enumeratedCount,
                            totalUnits: progress.totalCount
                        ))
                        // Stage A of an analysis *is* a catalog build — feed the
                        // estimator the same standalone build does, or the dashboard's
                        // countdown sat un-updated for the whole enumeration phase.
                        self.scanETAEstimator.record(
                            stage: "catalog",
                            completed: progress.enumeratedCount,
                            total: progress.totalCount,
                            at: ScanETAEstimator.monotonicNow()
                        )
                    case .completed(let result):
                        built = result
                        self.noteCatalogCompleted(result)
                    }
                }
            } catch is CancellationError {
                self.finishAnalysis(generation, as: .cancelled)
                return
            } catch let failure as CatalogScanFailure {
                self.finishAnalysis(
                    generation,
                    as: failure == .cancelled
                        ? .cancelled
                        : .failed(.underlying(failure.userMessage))
                )
                return
            } catch let failure as PhotoLibraryReadError {
                self.finishAnalysis(generation, as: .failed(Self.analysisFailure(for: failure)))
                return
            } catch {
                self.finishAnalysis(
                    generation,
                    as: .failed(.underlying("Photos access is required to read your library."))
                )
                return
            }

            // The stream can finish without `.completed` when it was cancelled mid-read.
            guard let built else {
                self.finishAnalysis(generation, as: .cancelled)
                return
            }
            guard self.isCurrentAnalysis(generation) else { return }

            // Stage B — similarity analysis over the catalog.
            var sawCompletion = false
            do {
                for try await event in engine.makeAnalysisStream(records: built.records) {
                    guard self.isCurrentAnalysis(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        self.applyAnalysisProgress(progress)
                    case .completed(let result):
                        sawCompletion = true
                        self.selection = PhotoSelectionModel(result: result)
                        self.analysisState = .completed(result)
                        let completedAt = self.persistCompletedScan(result)
                        await self.writeWidgetSummaryAfterScanCompleted(at: completedAt)
                    }
                }
                if !sawCompletion {
                    self.finishAnalysis(generation, as: .cancelled)
                }
            } catch is CancellationError {
                self.finishAnalysis(generation, as: .cancelled)
            } catch let failure as PhotoAnalysisFailure {
                self.finishAnalysis(
                    generation,
                    as: failure == .cancelled ? .cancelled : .failed(failure)
                )
            } catch {
                // PhotoKit/underlying error descriptions never reach the user verbatim.
                self.finishAnalysis(
                    generation,
                    as: .failed(.underlying("Similarity analysis could not finish. Please try again."))
                )
            }
        }
    }

    /// Cancels the in-flight run. The generation bump makes any late write from the old run a
    /// no-op, so the state can never flip back after this returns.
    func cancelSimilarityAnalysis() {
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        if analysisState.isRunning {
            analysisState = .cancelled
        }
    }

    private func isCurrentAnalysis(_ generation: Int) -> Bool {
        analysisGeneration == generation
    }

    /// Applies one analysis progress event under the coalescing policy (see
    /// `progressCoalesceInterval`). Stage changes and stage-terminal counts always apply — they
    /// are the events a reader (and the validation harness) keys off — intermediate ticks apply
    /// at most once per interval. The producer is untouched; only the main-actor write rate is
    /// bounded, so cancellation, completion, and failure paths stay exactly as responsive.
    private func applyAnalysisProgress(_ progress: PhotoAnalysisProgress) {
        let now = Date().timeIntervalSinceReferenceDate
        let stageChanged = lastAppliedStage != progress.stage
        let stageTerminal = progress.isComplete
        guard stageChanged || stageTerminal || now - lastAppliedProgressAt >= progressCoalesceInterval
        else { return }
        lastAppliedStage = progress.stage
        lastAppliedProgressAt = now
        analysisState = .running(progress)
        // Sampled at the same coalesced cadence the state is written, with monotonic time —
        // the estimator's own minimum sample interval smooths it further.
        scanETAEstimator.record(
            stage: progress.stage.rawValue,
            completed: progress.completedUnits,
            total: progress.totalUnits,
            at: ScanETAEstimator.monotonicNow()
        )
    }

    /// The active scan's current-stage estimate. Computed on read from the rolling estimator
    /// — the view formats it; no arithmetic and no additional state writes live in SwiftUI.
    func scanETA() -> ScanETA {
        scanETAEstimator.estimate()
    }

    private func finishAnalysis(_ generation: Int, as state: PhotoAnalysisState) {
        guard isCurrentAnalysis(generation) else { return }
        analysisState = state
    }

    private static func analysisFailure(for error: PhotoLibraryReadError) -> PhotoAnalysisFailure {
        switch error {
        case .accessDenied:
            return .underlying("Photos access is required to read your library.")
        case .underlying(let detail):
            return .underlying(detail)
        }
    }

    // MARK: - Blur analysis (sharpness pass over the completed catalog)

    /// Runs the sharpness pass over the images of the *already completed* catalog.
    ///
    /// Read-only and local-only: it measures bounded thumbnails through the same loader
    /// seam every other pass uses, never touches the photo library, and never waits on
    /// similarity analysis (the two passes are independent reads of one catalog). Starting
    /// it also invalidates any prepared deletion review — plans are bound to the dataset
    /// they were built from — and resets the blur selection, so a fresh run always opens
    /// with nothing marked.
    func startBlurAnalysis() {
        guard !blurAnalysisState.isRunning else { return }
        // Never rebuild datasets underneath an in-flight Photos mutation.
        guard !deletionState.isDeleting else { return }
        guard photoPermissionState.isUsable else {
            blurAnalysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }
        guard case .completed(let catalog) = catalogState else {
            blurAnalysisState = .failed(.underlying("Your library scan has not finished. Build your catalog, then try again."))
            return
        }

        // A fresh pass supersedes any prepared plan.
        planBuildGeneration += 1
        applyDeletion(.noSelection)

        blurAnalysisGeneration += 1
        let generation = blurAnalysisGeneration
        blurSelection = PhotoSelectionModel()

        blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 0, totalUnits: 0))

        let records = catalog.records
        #if DEBUG
        // Same validation hook as the similarity pass: `NETTO_SCAN_METRICS=1` injects the
        // blur metrics recorder so an end-to-end run prints one `blur-summary` line at the
        // end (see `BlurAnalysisMetrics`). Without it the engine is exactly as before.
        let engine: BlurAnalysisEngine
        if ProcessInfo.processInfo.environment["NETTO_SCAN_METRICS"] == "1" {
            engine = BlurAnalysisEngine(
                thumbnailLoader: thumbnailLoader,
                metrics: BlurAnalysisMetrics(),
                now: blurAnalysisClock
            )
        } else {
            engine = BlurAnalysisEngine(thumbnailLoader: thumbnailLoader, now: blurAnalysisClock)
        }
        #else
        let engine = BlurAnalysisEngine(thumbnailLoader: thumbnailLoader, now: blurAnalysisClock)
        #endif

        blurAnalysisTask = Task { [weak self] in
            guard let self else { return }
            var sawCompletion = false
            do {
                for try await event in engine.makeAnalysisStream(records: records) {
                    guard self.isCurrentBlurAnalysis(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        self.blurAnalysisState = .running(progress)
                    case .completed(let result):
                        sawCompletion = true
                        self.blurAnalysisState = .completed(result)
                        // Admission only: candidates become markable, nothing is marked.
                        self.synchronizeBlurDataset()
                    }
                }
                if !sawCompletion {
                    self.finishBlurAnalysis(generation, as: .cancelled)
                }
            } catch is CancellationError {
                self.finishBlurAnalysis(generation, as: .cancelled)
            } catch let failure as BlurAnalysisFailure {
                self.finishBlurAnalysis(
                    generation,
                    as: failure == .cancelled ? .cancelled : .failed(failure)
                )
            } catch {
                // PhotoKit/underlying error descriptions never reach the user verbatim.
                self.finishBlurAnalysis(
                    generation,
                    as: .failed(.underlying("Sharpness analysis could not finish. Please try again."))
                )
            }
        }
    }

    /// Cancels the in-flight sharpness pass. The generation bump makes any late write
    /// from the old run a no-op, so the state can never flip back after this returns.
    func cancelBlurAnalysis() {
        blurAnalysisGeneration += 1
        blurAnalysisTask?.cancel()
        blurAnalysisTask = nil
        if blurAnalysisState.isRunning {
            blurAnalysisState = .cancelled
        }
    }

    private func isCurrentBlurAnalysis(_ generation: Int) -> Bool {
        blurAnalysisGeneration == generation
    }

    private func finishBlurAnalysis(_ generation: Int, as state: BlurAnalysisState) {
        guard isCurrentBlurAnalysis(generation) else { return }
        blurAnalysisState = state
    }

    /// Same, for the blur selection — only stales a plan built from that source.
    func mutateBlurSelection(_ mutation: (inout PhotoSelectionModel) -> Void) {
        mutation(&blurSelection)
        guard planSource == .blurReview else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            applyDeletion(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    /// Reconciles the blur selection with the current candidate set and stales any blur
    /// plan built over a previous dataset. Candidates are *admitted* — the selection only
    /// ever accepts an explicit user decision, so this can never mark anything.
    ///
    /// Called whenever the catalog completes, whenever the sharpness pass completes, and
    /// whenever the Potentially Blurry screen appears (previews and tests set
    /// `catalogState` / `blurAnalysisState` directly).
    func synchronizeBlurDataset() {
        // A run in flight owns the dataset: the grid is hidden behind the progress phase,
        // every progress tick re-fires the state observation, and reconciling on each one
        // was O(catalog) work against a dataset about to be superseded. Completion (or any
        // terminal transition) re-enters here through the same observation and applies the
        // final dataset exactly once.
        guard !blurAnalysisState.isRunning else { return }
        let candidates: Set<String>
        switch blurAnalysisState {
        case .completed(let result):
            candidates = result.candidateIDs
        case .notStarted, .running, .cancelled, .failed:
            candidates = []
        }
        // A candidate whose record left the catalog (rebuild, deletion) is no longer part
        // of the dataset: drop its selection first (while it is still admitted), then
        // admit the surviving set and restore the user's still-valid marks.
        let catalogImageIDs: Set<String>
        switch catalogState {
        case .completed(let result):
            catalogImageIDs = Set(result.records.lazy.filter(\.isImage).map(\.localIdentifier))
        case .notStarted, .cancelled, .failed:
            catalogImageIDs = []
        case .running:
            catalogImageIDs = [] // A rebuild is in flight; reconcile again when it completes.
        }
        let effective = candidates.intersection(catalogImageIDs)

        // Drop selections that left the dataset while they are still admitted (the guard
        // in `setSelected` only lets admitted assets change), then admit the surviving
        // set — admission alone never selects anything, so this can mark nothing new.
        for assetID in blurSelection.selectedIDs where !effective.contains(assetID) {
            blurSelection.setSelected(false, forAsset: assetID)
        }
        blurSelection.admitLibraryAssets(effective)

        guard planSource == .blurReview else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            if blurSelection.selectedIDs != plan.selectionSnapshot {
                applyDeletion(.planStale(plan, [.selectionChanged]))
            } else if currentDatasetSignature(for: .blurReview) != plan.analysisSignature {
                applyDeletion(.planStale(plan, [.analysisChanged]))
            }
        default:
            break
        }
    }

    // MARK: - Deletion (plan → confirmation → mutation → verification)

    /// Builds an immutable deletion plan from `source`'s current selection.
    ///
    /// Never runs while a build, a confirmed deletion, or a result is on screen; requires a
    /// completed catalog — the similar-photos source falls back to an empty analysis result
    /// when no scan has completed (screenshots and videos are filters recorded during
    /// enumeration, so they never wait on analysis); resolves real sizes through
    /// `sizeProvider` (never during enumeration); then validates the fresh plan against the
    /// *current* context before presenting it for review.
    func prepareDeletionPlan(from source: DeletionSelectionSource = .similarPhotos) {
        switch deletionState {
        case .preparingPlan, .resolvingSizes, .awaitingConfirmation, .deleting, .succeeded,
             .needsReview:
            return
        default:
            break
        }
        planSource = source

        let selectedIDs = selectionIDs(for: source)
        guard !selectedIDs.isEmpty else {
            applyDeletion(.noSelection)
            return
        }

        applyDeletion(.preparingPlan)

        guard case .completed(let catalogResult) = catalogState else {
            applyDeletion(.failed("Your library scan has not finished. Scan your library, then review again."))
            return
        }

        let analysisResult: PhotoAnalysisResult
        switch source {
        case .screenshots, .videos, .blurReview:
            // Screenshots, videos, and blur candidates are subsets recorded by their own
            // passes — none of them needs the similarity result, and the plan's category
            // comes from the empty result + the source's own dataset signature below.
            if source == .blurReview, blurAnalysisState.isRunning || blurAnalysisState.result == nil {
                applyDeletion(.failed("Sharpness analysis has not finished. Analyze sharpness, then review again."))
                return
            }
            analysisResult = .empty
        case .similarPhotos:
            // Swipe Review writes its marks into this same selection and never needs the
            // similarity result to open or run — its deck *is* the scanned catalog — so a
            // library that has not been analysed must not dead-end its "Review Cleanup".
            // Fall back to the empty result exactly as the catalog-only sources do: the
            // plan is record-driven (validation, sizes, confirmation are unchanged), and a
            // later analysis rebuilds the selection and stales any plan built without it.
            if case .completed(let completed) = analysisState {
                analysisResult = completed
            } else {
                analysisResult = .empty
            }
        }

        // The fingerprint is derived from the inputs captured *now*; the self-check below
        // compares it against the context as it is *then*, so a dataset change during size
        // resolution lands the plan in `.planStale`, never in `.readyForReview`.
        let datasetSignature = Self.datasetSignature(
            for: source,
            catalog: catalogResult,
            analysis: analysisResult,
            blur: blurAnalysisState.result
        )
        let recordsByID = Dictionary(
            catalogResult.records.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        applyDeletion(.resolvingSizes)
        planBuildGeneration += 1
        let generation = planBuildGeneration

        Task { [weak self] in
            guard let self else { return }

            // Sizes resolve for the reviewed subset only — bounded, after enumeration.
            let selectedRecords = selectedIDs.compactMap { recordsByID[$0] }
            let resolvedRecords = await selectedRecords.resolvingSizes(using: self.sizeProvider)
            let resolvedSizes: [String: Int64] = resolvedRecords.reduce(into: [:]) { partial, record in
                guard let bytes = record.sizeInBytes else { return }
                partial[record.localIdentifier] = bytes
            }
            guard self.isCurrentPlanBuild(generation) else { return }

            // Fresh authorization at the moment the plan is stamped.
            let authorization = self.photoPermission.currentStatus()
            let plan: DeletionPlan
            do {
                plan = try DeletionPlanner().makePlan(
                    selectedIDs: selectedIDs,
                    recordsByID: recordsByID,
                    result: analysisResult,
                    resolvedSizes: resolvedSizes,
                    authorization: authorization,
                    sessionToken: self.deletionSessionToken,
                    analysisSignature: datasetSignature
                )
            } catch {
                guard self.isCurrentPlanBuild(generation) else { return }
                self.applyDeletion(.failed("This selection could not be prepared for review. Select photos again."))
                return
            }

            guard self.isCurrentPlanBuild(generation) else { return }
            // Self-check against the context as it is *now*: a selection or dataset change
            // during size resolution lands the plan in `.planStale`, never in `.readyForReview`.
            let reasons = DeletionPlanValidator.stalenessReasons(
                plan: plan,
                context: PlanExecutionContext(
                    selectionIDs: self.selectionIDs(for: source),
                    sessionToken: self.deletionSessionToken,
                    analysisSignature: self.currentDatasetSignature(for: source)
                ),
                freshAuthorization: authorization
            )
            if reasons.isEmpty {
                self.applyDeletion(.readyForReview(plan))
            } else {
                self.applyDeletion(.planStale(plan, reasons))
            }
        }
    }

    /// Items currently marked in `source`'s selection (review-entry gating).
    func selectionCount(for source: DeletionSelectionSource) -> Int {
        selectionIDs(for: source).count
    }

    /// A review screen for `source` appeared. A live plan built from the *other* selection must
    /// never be shown or confirmed under this screen, so any foreign deletion state — plan,
    /// stale record, failure, permission notice, or in-flight build — is dropped via the
    /// universal `noSelection` reset (an in-flight build is discarded first so it cannot land
    /// afterwards), and this source prepares exactly as from the empty phase. A plan that
    /// already belongs to `source` is kept, so re-entering the same review never re-resolves
    /// sizes.
    ///
    /// An in-flight mutation is untouchable: `noSelection` is universally legal, so applying
    /// it during `.deleting` would silently wipe the executing state (the outcome would then
    /// land outside `.deleting` and trip the state machine) and could prepare a second plan
    /// over a library that is being changed right now.
    func reviewDidAppear(from source: DeletionSelectionSource) {
        guard !deletionState.isDeleting else { return }
        guard planSource != source else {
            if case .noSelection = deletionState, selectionCount(for: source) > 0 {
                prepareDeletionPlan(from: source)
            }
            return
        }
        if deletionState.isBuildingPlan {
            planBuildGeneration += 1 // the other source's build can never become current
        }
        if case .noSelection = deletionState {
            // Already empty; nothing foreign to drop.
        } else {
            applyDeletion(.noSelection)
        }
        if selectionCount(for: source) > 0 {
            prepareDeletionPlan(from: source)
        }
    }

    /// User changed the similar-photos selection after a plan was shown — the plan is
    /// immediately stale. Only plans built from that source are affected.
    func mutateSelection(_ mutation: (inout PhotoSelectionModel) -> Void) {
        let before = selection.selectedIDs
        mutation(&selection)
        guard planSource == .similarPhotos else { return }
        // Only a change to what is *marked* stales the plan: accepted-set mutations (e.g.
        // Swipe Review re-admitting its whole deck on appear) provably cannot alter the
        // plan's selection snapshot, and staling on them told the user their prepared
        // review was "out of date" when nothing they chose had changed.
        guard selection.selectedIDs != before else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            applyDeletion(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    /// Same, for the screenshot selection — only stales a plan built from that source.
    func mutateScreenshotSelection(_ mutation: (inout ScreenshotSelectionModel) -> Void) {
        mutation(&screenshotSelection)
        guard planSource == .screenshots else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            applyDeletion(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    /// Same, for the video selection — only stales a plan built from that source.
    func mutateVideoSelection(_ mutation: (inout DatasetSelectionModel) -> Void) {
        mutation(&videoSelection)
        guard planSource == .videos else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            applyDeletion(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    /// First step of the destructive confirmation — the only route to `.awaitingConfirmation`.
    func beginConfirmation() {
        guard case .readyForReview(let plan) = deletionState else { return }
        applyDeletion(.awaitingConfirmation(plan))
    }

    /// Second step: the confirmation dialog was cancelled. No mutation has happened.
    func cancelConfirmation() {
        guard case .awaitingConfirmation(let plan) = deletionState else { return }
        applyDeletion(.readyForReview(plan))
    }

    /// Executes a confirmed deletion. No confirmation ⇒ no mutation: the guard makes it
    /// impossible to reach the service from any state other than `.awaitingConfirmation`.
    func confirmDeletion() async {
        guard case .awaitingConfirmation(let plan) = deletionState else { return }
        applyDeletion(.deleting(plan))

        let confirmed: ConfirmedDeletionPlan
        do {
            confirmed = try plan.confirmed()
        } catch {
            await handleDeletionOutcome(.rejected(.emptyPlan))
            return
        }

        // The final context is read here — the same moment the service re-reads authorization —
        // so a selection/session/dataset change invalidates the plan before any mutation.
        let outcome = await deletionService.execute(
            confirmed,
            in: PlanExecutionContext(
                selectionIDs: selectionIDs(for: planSource),
                sessionToken: deletionSessionToken,
                analysisSignature: currentDatasetSignature(for: planSource)
            )
        )
        await handleDeletionOutcome(outcome)
    }

    /// Leaves a terminal result state (also used to leave `.planStale`). Dismissing also
    /// discards the presented space-freed summary: a summary exists only for the result it
    /// describes, so a stale one can never back a later deletion.
    func dismissDeletionResult() {
        spaceFreedSummary = nil
        applyDeletion(.noSelection)
    }

    /// Presents the space-freed summary for an outcome with at least one confirmed removal.
    /// Called only after the outcome was applied, the results were pruned, and storage was
    /// refreshed. `nil` plan, or a summary that would count zero removals, presents nothing —
    /// the failure/cancellation/no-op flows below are untouched by construction. After the
    /// screen is up, the confirmed figure (when one was measured) becomes the widget's
    /// shared summary; a cleanup without a measured figure writes nothing at all.
    private func presentSpaceFreedSummary(plan: DeletionPlan?, success: DeletionSuccess) async {
        guard let plan, let summary = SpaceFreedSummary(plan: plan, success: success) else { return }
        spaceFreedSummary = summary
        flowState = .deletionCompleted
        await writeWidgetSummaryAfterCleanup(summary)
    }

    /// The summary screen's Done: an idempotent return to the dashboard. It resets the
    /// deletion state machine exactly like the in-review Done button (via
    /// `dismissDeletionResult`, which also discards the summary) and starts nothing — no
    /// scan, no repeated mutation, no extra snapshot write. Repeated taps are no-ops.
    func finishSpaceFreedSummary() {
        guard spaceFreedSummary != nil || flowState == .deletionCompleted else { return }
        dismissDeletionResult()
        flowState = .dashboard
    }

    private func handleDeletionOutcome(_ outcome: DeletionOutcome) async {
        switch outcome {
        case .succeeded(let success):
            // The plan is the source of truth for what was attempted; capture it before the
            // state machine leaves `.deleting` — the summary needs its measured sizes and
            // categories while they are still reachable.
            let deletingPlan = deletionState.plan
            let plannedIDs = deletingPlanSelectionIDs()
            if success.isFullyRemoved {
                applyDeletion(.succeeded(success))
            } else {
                applyDeletion(.needsReview(success))
            }
            // Photos changed, the scan did not: apply only the confirmed removals to the
            // completed results instead of invalidating them back to "start analysis".
            preserveResultsAfterDeletion(removing: plannedIDs.subtracting(success.remainingIDs))
            await refreshStorage()
            // Only now — outcome applied, results pruned, storage refreshed — may a success
            // summary exist, so the UI can never show success before the operation finished.
            await presentSpaceFreedSummary(plan: deletingPlan, success: success)

        case .stale(let reasons):
            if case .deleting(let plan) = deletionState {
                applyDeletion(.planStale(plan, reasons))
            } else {
                assertionFailure("stale outcome outside .deleting")
            }

        case .permissionDenied(let state):
            applyDeletion(.permissionRequired(state))

        case .rejected:
            applyDeletion(.noSelection)

        case .mutationFailed:
            // PhotoKit error text never reaches the user verbatim.
            applyDeletion(.failed(DeletionPresentation.userFacingFailure(for: outcome)))

        case .verificationFailed(let message):
            applyDeletion(.failed(message))
            // Requested but unverified: nothing is confirmed removed, so the completed
            // results, their selection, and every dataset stand exactly as they were.
            await refreshStorage()

        case .revalidationFailed(let message):
            // Pre-mutation refusal: nothing changed, existing datasets stay valid.
            applyDeletion(.failed(message))

        case .cancelled:
            if case .deleting(let plan) = deletionState {
                applyDeletion(.readyForReview(plan))
            } else {
                assertionFailure("cancelled outcome outside .deleting")
            }
        }
    }

    /// Reviewed identifiers of the execution in flight (empty outside `.deleting`).
    private func deletingPlanSelectionIDs() -> Set<String> {
        if case .deleting(let plan) = deletionState { return plan.selectionSnapshot }
        return []
    }

    /// Photos changed, but the completed scan did not: every derived view is pruned in place
    /// — the analysis result loses only the confirmed removals (and so does its selection and
    /// the persisted snapshot, which keeps the original scan's identity), the catalog loses
    /// only the removed records, and the screenshot/video filters reconcile against that
    /// pruned catalog. No rescan is started; failure outcomes never reach here.
    private func preserveResultsAfterDeletion(removing deletedAssetIDs: Set<String>) {
        planBuildGeneration += 1
        // `planSource` is deliberately left at the source that produced this deletion:
        // overwriting it here made a foreign outcome (screenshots/videos/blur) look like a
        // similar-photos result on the next review appearance, so that screen showed the
        // wrong deletion's summary instead of preparing its own plan.
        cancelVideoSizeResolution()
        videoSizeResolution = .idle

        // A read started before the mutation would complete with pre-mutation data: cancel
        // it and supersede any late write so it can never overwrite the pruned results.
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        if analysisState.isRunning {
            // Interrupted by the mutation — cancelled, never left "running" over data that
            // just changed underneath it (the same terminal write the sharpness pass below
            // gets). Without it the state froze at `.running` forever: every later write is
            // generation-guarded off, and both scan entry points refuse to start.
            analysisState = .cancelled
        }
        // The sharpness pass sampled the pre-mutation catalog: cancel it the same way, and
        // supersede any late write, so its result can only ever describe the current data.
        blurAnalysisGeneration += 1
        blurAnalysisTask?.cancel()
        blurAnalysisTask = nil
        if blurAnalysisState.isRunning {
            // Interrupted by the mutation — cancelled, never "completed" over data that
            // just changed underneath it.
            blurAnalysisState = .cancelled
        }
        let catalogWasRunning = catalogTask != nil
        catalogTask?.cancel()
        catalogTask = nil
        if catalogWasRunning { catalogGeneration += 1 }

        // Whatever state the analysis is in, confirmed removals must leave the shared
        // selection: otherwise marks on a catalog-only library (Swipe Review without an
        // analysis) would keep referencing deleted assets — a wrong count and a plan
        // guaranteed to fail closed on the next review.
        if !deletedAssetIDs.isEmpty {
            selection.prune(removing: deletedAssetIDs)
        }

        if case .completed(let result) = analysisState, !deletedAssetIDs.isEmpty {
            let recordsByID: [String: PhotoAssetRecord] = {
                guard case .completed(let catalog) = catalogState else { return [:] }
                return Dictionary(
                    catalog.records.map { ($0.localIdentifier, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }()
            let updated = result.removingAssets(deletedAssetIDs, catalogRecords: recordsByID)
            analysisState = .completed(updated)
            selection = PhotoSelectionModel(result: updated, preserving: selection, removing: deletedAssetIDs)
            persistUpdatedScanResult(updated)
        }

        // In-place prune of the sharpness result — the confirmed removals leave it, the
        // verdicts for everything else stand (no rescan, no re-measurement).
        if case .completed(let blurResult) = blurAnalysisState, !deletedAssetIDs.isEmpty {
            blurAnalysisState = .completed(blurResult.removingAssets(deletedAssetIDs))
        }

        if case .completed(let catalog) = catalogState {
            if !deletedAssetIDs.isEmpty {
                catalogState = .completed(catalog.removingAssetIDs(deletedAssetIDs))
                synchronizeScreenshotDataset()
                synchronizeVideoDataset()
                synchronizeBlurDataset()
            }
        } else if catalogWasRunning, case .running = catalogState {
            // The in-flight build carried pre-mutation records and can never finish now.
            catalogState = .notStarted
            synchronizeScreenshotDataset()
            synchronizeVideoDataset()
            synchronizeBlurDataset()
        }
    }

    /// Replaces the persisted snapshot after a confirmed deletion without pretending a new
    /// scan happened: same `scanID` and `completedAt` as the snapshot this result came from,
    /// so the store keeps describing one completed scan. A fresh snapshot is written only
    /// when nothing was persisted yet (tests set results directly).
    private func persistUpdatedScanResult(_ result: PhotoAnalysisResult) {
        if let existing = scanSnapshotStore.loadLatest() {
            let snapshot = ScanSnapshot(
                schemaVersion: ScanSnapshot.currentSchemaVersion,
                scanID: existing.scanID,
                completedAt: existing.completedAt,
                result: result
            )
            try? scanSnapshotStore.save(snapshot)
            lastScanCompletedAt = existing.completedAt
        } else {
            persistCompletedScan(result)
        }
    }

    private func isCurrentPlanBuild(_ generation: Int) -> Bool {
        planBuildGeneration == generation
    }

    // MARK: - Dataset synchronization (screenshot subset of the catalog)

    /// Stores a completed catalog and reconciles both catalog-filter selections against it, so
    /// a rebuilt dataset can never leave a selection pointing at vanished assets.
    private func noteCatalogCompleted(_ result: CatalogScanResult, standalone: Bool = false) {
        catalogState = .completed(result)
        synchronizeScreenshotDataset()
        synchronizeVideoDataset()
        synchronizeBlurDataset()
        if standalone {
            invalidateAnalysisAfterRebuild()
        }
    }

    /// A standalone rebuild supersedes every fact derived from the previous catalog: groups,
    /// the photo selection, the sharpness results, and any prepared plan were all computed
    /// over data that no longer exists. The photo flows have no per-dataset signature check
    /// (screenshots and videos reconcile themselves above), so the invalidation is explicit
    /// here. Cannot run during an analysis, a sharpness pass (a standalone build is refused
    /// while either is running) or a deletion (same).
    private func invalidateAnalysisAfterRebuild() {
        guard !analysisState.isRunning, !deletionState.isDeleting else { return }
        let blurIsClean: Bool = {
            if case .notStarted = blurAnalysisState { return blurSelection.selectedIDs.isEmpty }
            return false
        }()
        if case .notStarted = analysisState, selection.selectedIDs.isEmpty, blurIsClean { return }
        planBuildGeneration += 1
        selection = PhotoSelectionModel()
        applyDeletion(.noSelection)
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        analysisState = .notStarted
        // The sharpness pass is in-memory only: with no catalog to stand on, its state
        // resets to "not started" — it can never show results from a superseded catalog.
        blurAnalysisGeneration += 1
        blurAnalysisTask?.cancel()
        blurAnalysisTask = nil
        blurSelection = PhotoSelectionModel()
        blurAnalysisState = .notStarted
    }

    /// Reconciles the screenshot selection with the current catalog and stales any screenshot
    /// plan built over a previous dataset. Called whenever the catalog completes and whenever
    /// the screenshots screen appears (previews and tests set `catalogState` directly).
    func synchronizeScreenshotDataset() {
        switch catalogState {
        case .completed(let result):
            screenshotSelection.reconcile(with: ScreenshotDataset.identifiers(in: result))
        case .notStarted, .cancelled, .failed:
            screenshotSelection.reset()
        case .running:
            break // A rebuild is in flight; reconcile again when it completes.
        }

        guard planSource == .screenshots else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            if screenshotSelection.selectedIDs != plan.selectionSnapshot {
                applyDeletion(.planStale(plan, [.selectionChanged]))
            } else if currentDatasetSignature(for: .screenshots) != plan.analysisSignature {
                applyDeletion(.planStale(plan, [.analysisChanged]))
            }
        default:
            break
        }
    }

    /// Reconciles the video selection with the current catalog, drops size measurements that
    /// belong to a previous dataset, and stales any video plan built over a previous dataset.
    /// Called whenever the catalog completes and whenever the videos screen appears (previews
    /// and tests set `catalogState` directly).
    func synchronizeVideoDataset() {
        switch catalogState {
        case .completed(let result):
            videoSelection.reconcile(with: VideoDataset.identifiers(in: result))
            let signature = VideoDataset.signature(in: result)
            if !videoSizeResolution.isCurrent(for: signature) {
                // Bytes measured against another dataset are dropped, never mixed in.
                cancelVideoSizeResolution()
                videoSizeResolution = .idle
            }
        case .notStarted, .cancelled, .failed:
            videoSelection.reset()
            cancelVideoSizeResolution()
            videoSizeResolution = .idle
        case .running:
            break // A rebuild is in flight; reconcile again when it completes.
        }

        guard planSource == .videos else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            if videoSelection.selectedIDs != plan.selectionSnapshot {
                applyDeletion(.planStale(plan, [.selectionChanged]))
            } else if currentDatasetSignature(for: .videos) != plan.analysisSignature {
                applyDeletion(.planStale(plan, [.analysisChanged]))
            }
        default:
            break
        }
    }

    /// The identifiers `source`'s selection is drawn from right now.
    private func selectionIDs(for source: DeletionSelectionSource) -> Set<String> {
        switch source {
        case .similarPhotos: return selection.selectedIDs
        case .screenshots: return screenshotSelection.selectedIDs
        case .videos: return videoSelection.selectedIDs
        case .blurReview: return blurSelection.selectedIDs
        }
    }

    /// Dataset fingerprint a plan of `source` must match at execution time; `""` when there is
    /// no dataset (never matches a real plan's stamp, so such a plan is stale).
    private func currentDatasetSignature(for source: DeletionSelectionSource) -> String {
        switch source {
        case .similarPhotos:
            if case .completed(let result) = analysisState {
                return DeletionPlanner.analysisSignature(for: result)
            }
            // Mirror `prepareDeletionPlan`'s empty-result fallback: a plan built over a
            // catalog-only library stamps `.empty`'s signature, so the context check must
            // answer with the same value instead of `""` (which would flag the plan stale
            // the instant it was built). Any *real* analysis result still differs from the
            // empty signature, so completion/invalidation stales the plan as it should.
            return DeletionPlanner.analysisSignature(for: .empty)
        case .screenshots:
            guard case .completed(let result) = catalogState else { return "" }
            return ScreenshotDataset.signature(in: result)
        case .videos:
            guard case .completed(let result) = catalogState else { return "" }
            return VideoDataset.signature(in: result)
        case .blurReview:
            guard let result = blurAnalysisState.result else { return "" }
            return BlurDataset.signature(in: result)
        }
    }

    /// The fingerprint stamped at build time, derived from the inputs captured with the plan.
    /// `blur` carries the sharpness result *as it was when the plan was built*; sources that
    /// do not derive their dataset from it ignore the parameter (and a `.blurReview` plan
    /// built with no result gets `""`, which can never match a real stamp).
    private static func datasetSignature(
        for source: DeletionSelectionSource,
        catalog: CatalogScanResult,
        analysis: PhotoAnalysisResult,
        blur: BlurAnalysisResult?
    ) -> String {
        switch source {
        case .similarPhotos: return DeletionPlanner.analysisSignature(for: analysis)
        case .screenshots: return ScreenshotDataset.signature(in: catalog)
        case .videos: return VideoDataset.signature(in: catalog)
        case .blurReview:
            guard let blur else { return "" }
            return BlurDataset.signature(in: blur)
        }
    }

    // MARK: - Video size resolution (measure once, largest-first honestly)

    /// Starts measuring the current video dataset from scratch. Only starts from `.idle` —
    /// an in-flight or already-settled measurement is left exactly as it is.
    func startVideoSizeResolution() {
        guard case .idle = videoSizeResolution else { return }
        resumeVideoSizeMeasurement()
    }

    /// Measures the videos whose sizes are still unknown (all of them when idle), in bounded
    /// sequential batches. Read-only: it never touches the selection or a prepared plan — plan
    /// sizes are resolved separately for the reviewed subset at prepare time. Safe to call
    /// repeatedly: while a run is in flight nothing restarts, and a fully measured dataset
    /// settles again without calling the provider.
    func resumeVideoSizeMeasurement() {
        guard !videoSizeResolution.isMeasuring else { return }
        guard photoPermissionState.isUsable else { return }
        guard case .completed(let catalog) = catalogState else { return }

        let videos = VideoDataset.records(in: catalog)
        guard !videos.isEmpty else {
            videoSizeResolution = .idle
            return
        }

        let signature = VideoDataset.signature(in: catalog)
        var bytes: [String: Int64]
        if videoSizeResolution.isCurrent(for: signature) {
            bytes = videoSizeResolution.bytes // resume: keep what this dataset already measured
        } else {
            bytes = [:] // another dataset's bytes are never mixed into this one
        }
        let total = videos.count
        let targets = videos.lazy.map(\.localIdentifier).filter { bytes[$0] == nil }

        guard !targets.isEmpty else {
            videoSizeResolution = .settled(
                VideoSizeResolution.Measurement(
                    datasetSignature: signature,
                    bytes: bytes,
                    total: total
                )
            )
            return
        }

        videoSizeGeneration += 1
        let generation = videoSizeGeneration
        videoSizeTask?.cancel()
        videoSizeResolution = .measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: signature,
                bytes: bytes,
                total: total
            )
        )

        let provider = sizeProvider
        videoSizeTask = Task { [weak self] in
            guard let self else { return }
            let batchSize = VideoSizeResolution.measurementBatchSize
            var pending = Array(targets)
            while !pending.isEmpty {
                let batch = Array(pending.prefix(batchSize))
                pending.removeFirst(batch.count)
                let landed = await provider.sizes(for: batch)
                // Each batch re-checks the generation, so a cancelled run's remaining batches
                // are discarding no-ops — they can never overwrite newer state.
                guard self.videoSizeGeneration == generation else { return }
                bytes.merge(landed) { _, new in new }
                self.videoSizeResolution = .measuring(
                    VideoSizeResolution.Measurement(
                        datasetSignature: signature,
                        bytes: bytes,
                        total: total
                    )
                )
            }
            guard self.videoSizeGeneration == generation else { return }
            self.videoSizeResolution = .settled(
                VideoSizeResolution.Measurement(
                    datasetSignature: signature,
                    bytes: bytes,
                    total: total
                )
            )
            self.videoSizeTask = nil
        }
    }

    /// Cancels an in-flight measurement. Everything measured so far is kept as a settled
    /// (possibly partial) state — never discarded — and the generation bump makes the
    /// cancelled run's remaining batches no-ops.
    func cancelVideoSizeResolution() {
        videoSizeGeneration += 1
        videoSizeTask?.cancel()
        videoSizeTask = nil
        if case .measuring(let measurement) = videoSizeResolution {
            videoSizeResolution = .settled(measurement)
        }
    }

    /// Single gate for every deletion state change: legal transitions are applied, illegal ones
    /// trip an assertion in debug instead of silently corrupting the machine.
    private func applyDeletion(_ target: DeletionState) {
        guard DeletionState.canTransition(from: deletionState, to: target) else {
            assertionFailure("Illegal deletion transition \(deletionState) -> \(target)")
            return
        }
        deletionState = target
    }
}

extension AppEnvironment {
    /// Production environment.
    ///
    /// A DEBUG build launched with `-fixtureLibrary` swaps the PhotoKit reader for a synthetic
    /// fixture library (with synthesized thumbnails and deterministic sizes), so the whole
    /// flow can be exercised in Simulator — where the real library contains no screenshot-flagged
    /// assets. Fixture identifiers do not exist in Photos, so a deletion attempt over them is
    /// stopped by the service's existence revalidation with zero mutation. Release builds, and
    /// DEBUG runs without the argument, always use the real library.
    ///
    /// `-fixtureContacts` serves synthetic contact fixtures instead of the store (reads only —
    /// a mutation over fixture identifiers is refused by existence revalidation). 
    /// `-seedFixtureContacts` (DEBUG Simulator builds only) seeds the *simulator's* store with
    /// those fixtures so the full contacts pipeline can be validated against a real
    /// `CNContactStore`; `-wipeFixtureContacts` removes them again. None of these exist in
    /// Release builds.
    static func live() -> AppEnvironment {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // UI tests wipe the persisted scan so every launch starts from the first-run state —
        // the startup condition every existing dashboard UI test was written against.
        if arguments.contains("-resetScanSnapshot") {
            FileScanSnapshotStore().clear()
        }
        if arguments.contains("-fixtureLibrary") {
            return AppEnvironment(
                makePhotoLibrary: { FixturePhotoLibrary() },
                thumbnailLoader: PreviewData.ThumbnailLoader(),
                sizeProvider: FixtureSizeProvider()
            )
        }
        if arguments.contains("-fixtureContacts") {
            return AppEnvironment(
                makeContactReader: { FixtureContactReader() }
            )
        }
        #if targetEnvironment(simulator)
        if arguments.contains("-seedFixtureContacts") {
            try? ContactFixtureSeeder.seed()
        } else if arguments.contains("-wipeFixtureContacts") {
            try? ContactFixtureSeeder.wipe()
        }
        #endif
        #endif
        return AppEnvironment()
    }
}

struct RootView: View {
    @State private var env = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch env.flowState {
            case .launching:
                ProgressView("Starting Netto…")
            case .deletionCompleted:
                // The summary and this state are set together in `presentSpaceFreedSummary`
                // and cleared together in `finishSpaceFreedSummary`. If they ever desync,
                // fall back to the dashboard rather than an empty screen.
                if let summary = env.spaceFreedSummary {
                    SpaceFreedSummaryView(summary: summary, onDone: env.finishSpaceFreedSummary)
                } else {
                    DashboardView()
                        .environment(env)
                }
            case .dashboard, .scanning, .resultsAvailable, .review,
                 .deleting, .deletionFailed:
                DashboardView()
                    .environment(env)
            }
        }
        .task {
            await env.bootstrap()
        }
        .onOpenURL { url in
            env.handleDeepLink(url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from Settings (or the app being foregrounded) is the only moment a
            // permission granted elsewhere becomes visible here — without this, both
            // permission screens read the boot-time status forever.
            guard newPhase == .active else { return }
            env.refreshPermissions()
            Task { await env.refreshStorage() }
        }
    }
}
