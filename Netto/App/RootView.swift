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
    /// Swipe Review's editable cleanup: a *scoped subset* of the shared selection (this
    /// session's checked Delete marks), validated against both the checked set and the live
    /// selection at build and at execution.
    case swipeReview
}

/// The app's lifecycle phase as the environment reasons about it — mapped from `ScenePhase`
/// in `RootView`, deliberately distinct from it so the interruption logic can be driven by
/// tests without a scene.
enum AppLifecyclePhase: Sendable, Equatable {
    case active
    case inactive
    case background
}

/// Seam over the OS background task. Tests drive expiration deterministically instead of
/// racing the system clock, which is the only way the pause-and-checkpoint path can be
/// tested as written (a simulator test cannot reproduce iOS's real suspension anyway).
@MainActor
protocol BackgroundTaskScheduling: Sendable {
    /// Arms a background task; `onExpiration` runs on the main actor if the system
    /// reclaims it before the work finishes. A second `begin` while held is a no-op.
    func begin(onExpiration: @escaping @MainActor () -> Void)
    /// Releases the task (completion, cancel, pause, foreground). No-op when unheld.
    func end()
    var isHolding: Bool { get }
}

/// Production seam: `UIApplication`'s named background task. Main-actor isolated (as
/// `UIApplication` itself is), which also serializes `begin`/`end`/expiration — the
/// expiration handler hops back onto the main actor before touching any state.
@MainActor
final class SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expiration: (@MainActor () -> Void)?

    var isHolding: Bool { identifier != .invalid }

    func begin(onExpiration: @escaping @MainActor () -> Void) {
        guard identifier == .invalid else { return }
        expiration = onExpiration
        let assigned = UIApplication.shared.beginBackgroundTask(
            withName: "netto.scan.checkpoint"
        ) { [weak self] in
            // Called off the main actor by the system; all state lives on it.
            Task { @MainActor [weak self] in
                self?.handleExpiration()
            }
        }
        identifier = assigned
    }

    func end() {
        let current = identifier
        identifier = .invalid
        expiration = nil
        guard current != .invalid else { return }
        UIApplication.shared.endBackgroundTask(current)
    }

    private func handleExpiration() {
        // Only the owner ends the task: `end()` may have won the race after the system
        // decided to reclaim it, and a double end is a real (logged) bug.
        guard identifier != .invalid else { return }
        let handler = expiration
        let current = identifier
        identifier = .invalid
        expiration = nil
        UIApplication.shared.endBackgroundTask(current)
        handler?()
    }
}

/// The heavy pass a queued request will start — the coordinator's one-slot queue (M10).
/// Same-request taps are no-ops; a different request replaces the slot, so the latest
/// user intent is what runs next.
enum PendingAnalysisRequest: Equatable, Sendable {
    case similarity
    case blur
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
    /// Persistence seam for Swipe Review sessions (deck order, cursor, undo, decisions).
    /// Injected so tests use temporary storage instead of the app's real session file.
    let swipeSessionStore: any SwipeReviewSessionStore

    var flowState: AppFlowState = .launching
    var prompt: PermissionPrompt = .none
    var photoPermissionState: PermissionState = .notDetermined
    var contactsPermissionState: PermissionState = .notDetermined
    var storageSnapshot: StorageSnapshot?
    var catalogState: CatalogScanState = .notStarted {
        didSet {
            blurDatasetGeneration &+= 1
            videoSignatureGeneration &+= 1
        }
    }
    var analysisState: PhotoAnalysisState = .notStarted {
        didSet {
            // Shared worker-width budget (M13): the similarity pass is active exactly while
            // its state is running. Idempotent per-kind, so progress ticks, pause, resume,
            // and every terminal flip are all safe.
            if analysisState.isRunning {
                analysisConcurrencyBudget.begin(.similarity)
            } else if oldValue.isRunning {
                analysisConcurrencyBudget.end(.similarity)
            }
            // A running pass releasing the pipeline (completion, failure, or cancel) is
            // exactly when a queued pass may start (M10). Paused is not running but still
            // owns the slot — `drivePendingAnalysis` refuses while a pause stands.
            if oldValue.isRunning, !analysisState.isRunning {
                drivePendingAnalysis()
            }
        }
    }
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
        didSet {
            blurDatasetGeneration &+= 1
            // Shared worker-width budget (M13): the sharpness pass is active exactly while
            // its state is running — same idempotent per-kind contract as `analysisState`.
            if blurAnalysisState.isRunning {
                analysisConcurrencyBudget.begin(.blur)
            } else if oldValue.isRunning {
                analysisConcurrencyBudget.end(.blur)
            }
            // Same coordination hook as `analysisState` (M10): a terminal flip may hand
            // the pipeline to the queued pass.
            if oldValue.isRunning, !blurAnalysisState.isRunning {
                drivePendingAnalysis()
            }
        }
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
    var deletionState: DeletionState = .noSelection {
        didSet {
            // A deletion leaving `.deleting` releases the pipeline the mutation owned;
            // a pass queued during the mutation starts now (M10). Entering `.deleting`
            // never drives — `drivePendingAnalysis` refuses while a deletion is in flight.
            if oldValue.isDeleting, !deletionState.isDeleting {
                drivePendingAnalysis()
            }
        }
    }
    /// The one queued heavy-analysis request — the coordinator's single queue slot (M10).
    /// Set when the user asks for the pass that is not currently running; cleared when
    /// that pass starts, when the queue is removed, or when an explicit cancel-and-switch
    /// claims it. In-memory only: an app kill drops the queue with the unstarted request.
    private(set) var pendingAnalysisRequest: PendingAnalysisRequest?
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
    /// True while a unified session's shared catalog enumeration is in flight (M13). The
    /// read lives in `catalogTask` so cancelling or pausing one pipeline's *work* cannot
    /// abort the read the other still needs; because the enumeration reports through
    /// similarity's `preparing` stage rather than `catalogState`, the pause/cancel paths
    /// need this flag to recognize the read as in-flight.
    private var sharedEnumerationInFlight = false
    /// Shared worker-width budget for the concurrent image-analysis pipelines (M13). Both
    /// engines read it at every width decision; while both pipelines run their combined
    /// width never exceeds what one pipeline used alone. Idempotent per-kind begin/end, so
    /// terminal transitions and cancel paths can call `end` freely.
    private let analysisConcurrencyBudget = AnalysisConcurrencyBudget()
    /// Confirmed asset removals that landed while a pipeline was still running (M13). A
    /// running pass sampled the pre-mutation catalog, so its result may still describe
    /// assets that no longer exist. Cancelling the pass would throw away the valid work it
    /// did for every asset that *survived*; instead the confirmed removals are recorded
    /// here and reconciled out of the result the moment it lands (see
    /// `reconcileDeletionDuringRun`). Cleared once no pipeline is running, so a later run
    /// never inherits a stale set.
    private var deletionsDuringRunningPasses: Set<String> = []
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
    /// Catalog progress coalescing — the same policy as above, tracked separately for the
    /// catalog writes (a standalone build's `catalogState` and an analysis's `preparing`
    /// stage): last applied write + last applied denominator. Reset at every run start.
    /// The producer is untouched; only the main-actor write rate is bounded (≤ 4/s), and a
    /// changed denominator or a terminal count always applies immediately.
    private var lastAppliedCatalogProgressAt: TimeInterval = 0
    private var lastAppliedCatalogTotal: Int = -1
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

    // MARK: Editable swipe-cleanup selection (Phase D)

    /// The current review session's Delete-marked candidates, in deck order — refreshed from
    /// `SwipeCleanupSelectionView` on appear (and only there: never per render).
    private(set) var swipeCleanupCandidates: [SwipeReviewItem] = []
    /// Explicit per-candidate choices made inside the cleanup flow, keyed by asset. Absent =
    /// still on the default (selected). Lives in the environment — not in view state — so
    /// checks and unchecks survive every navigation *within* the review flow; a candidate
    /// that appears later (a new Delete mark) joins selected unless the user already chose
    /// otherwise for that asset.
    private var swipeCleanupChoices: [String: Bool] = [:]

    /// The checked subset the plan is built from: candidates still checked. Read through
    /// `selectionIDs(for: .swipeReview)` at plan build *and* at execution, so a change to
    /// either the checks or the shared selection stale/refuse the plan.
    var swipeCleanupCheckedIDs: Set<String> {
        Set(swipeCleanupCandidates.lazy.map(\.assetID).filter {
            self.swipeCleanupChoices[$0] ?? true
        })
    }

    /// O(candidates) count of the checked subset — candidates are only ever the session's
    /// Delete marks (bounded by what the user swiped), and the cleanup screen renders every
    /// one of them anyway.
    var swipeCleanupCheckedCount: Int {
        swipeCleanupCandidates.reduce(0) { partial, item in
            partial + ((self.swipeCleanupChoices[item.assetID] ?? true) ? 1 : 0)
        }
    }

    /// Installs the candidate list when the cleanup screen appears. Choices are kept: a
    /// still-present candidate stays whatever the user last set, a vanished one is filtered
    /// out of the checked set by definition, and a newly marked photo joins selected.
    func enterSwipeCleanup(_ candidates: [SwipeReviewItem]) {
        swipeCleanupCandidates = candidates
        staleSwipeCleanupPlanIfCurrent()
    }

    func setSwipeCleanupChecked(_ assetID: String, checked: Bool) {
        guard swipeCleanupCandidates.contains(where: { $0.assetID == assetID }) else { return }
        swipeCleanupChoices[assetID] = checked
        staleSwipeCleanupPlanIfCurrent()
    }

    func selectAllSwipeCleanup() {
        for candidate in swipeCleanupCandidates {
            swipeCleanupChoices[candidate.assetID] = true
        }
        staleSwipeCleanupPlanIfCurrent()
    }

    func deselectAllSwipeCleanup() {
        for candidate in swipeCleanupCandidates {
            swipeCleanupChoices[candidate.assetID] = false
        }
        staleSwipeCleanupPlanIfCurrent()
    }

    /// A prepared swipe-review plan no longer matches the checked ∩ selected set it was
    /// built from — exactly the `selectionChanged` staleness every other source uses. A plan
    /// that still matches is left alone, so merely re-entering the screen never fakes a
    /// "out of date" state.
    private func staleSwipeCleanupPlanIfCurrent() {
        guard planSource == .swipeReview else { return }
        switch deletionState {
        case .readyForReview(let plan), .awaitingConfirmation(let plan):
            guard plan.selectionSnapshot != selectionIDs(for: .swipeReview) else { return }
            applyDeletion(.planStale(plan, [.selectionChanged]))
        default:
            break
        }
    }

    // MARK: Session persistence (Phase D)

    /// Persists the session after every mutation. The store's file implementation drains
    /// off the main actor and coalesces bursts; the in-memory test store is synchronous.
    func saveSwipeSession(from model: SwipeReviewModel) {
        let snapshot = model.sessionSnapshot()
        cachedSwipeSession = .some(snapshot)
        swipeSessionStore.save(snapshot)
    }

    /// The persisted session, loaded once per process. Double-optional: `nil` (outer) means
    /// "not loaded yet", `.some(nil)` means "loaded — no session" (so a fresh launch does not
    /// re-read the file on every call). Callers treat both as "no session".
    func restoreSwipeSession() -> SwipeReviewSessionSnapshot? {
        if let cached = cachedSwipeSession { return cached }
        let loaded = swipeSessionStore.load()
        cachedSwipeSession = .some(loaded)
        return loaded
    }

    /// Load-once cache for `restoreSwipeSession()`; `nil` = not loaded yet.
    @ObservationIgnored private var cachedSwipeSession: SwipeReviewSessionSnapshot??
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
    /// Bumped by `catalogState`'s `didSet` — the video signature's only input.
    @ObservationIgnored private var videoSignatureGeneration: UInt64 = 0
    /// What `videoSignatureGeneration` the cached signature below reflects.
    @ObservationIgnored private var builtVideoSignatureGeneration: UInt64 = .max
    /// The cached video-dataset fingerprint (see `videoDatasetSignature`).
    @ObservationIgnored private var builtVideoSignature: String = ""
    /// What `videoSignatureGeneration` + resolution the cached display records reflect.
    @ObservationIgnored private var builtVideoRecordsGeneration: UInt64 = .max
    @ObservationIgnored private var builtVideoRecordsResolution: VideoSizeResolution?
    /// The cached, resolved, largest-first video inventory (see `videoRecordsForDisplay`).
    @ObservationIgnored private var builtVideoRecords: [PhotoAssetRecord] = []
    @ObservationIgnored private var builtVideoSourceGeneration: UInt64 = .max
    @ObservationIgnored private var builtRecordedVideos: [PhotoAssetRecord] = []
    @ObservationIgnored private var builtDownloadedVideos: [PhotoAssetRecord] = []
    @ObservationIgnored private var builtOtherVideosCount: Int = 0
    @ObservationIgnored private var builtOldScreenshotGeneration: UInt64 = .max
    @ObservationIgnored private var builtOldScreenshotRecords: [PhotoAssetRecord] = []
    @ObservationIgnored private var builtOldScreenshotUnknownDateCount: Int = 0

    // MARK: Interrupted-run state (Phase C)

    /// Persistence seam for interrupted-run checkpoints. Injected so tests use temporary
    /// storage instead of the app's real file (same rule as `scanSnapshotStore`).
    let checkpointStore: any ScanCheckpointStore
    /// Per-kind checkpoint channels (M13): one writer + accumulator per pass kind, so the
    /// similarity and sharpness pipelines run — and are interrupted — concurrently without
    /// contending for a single checkpoint slot. Each scopes the injected store to its kind.
    private let checkpointChannels: CheckpointChannels
    /// Background-task seam: tests drive expiration deterministically instead of racing
    /// the system clock.
    private let backgroundTasks: any BackgroundTaskScheduling

    /// The checkpoints that exist to be resumed: loaded at bootstrap (one per interrupted
    /// pass kind), or written by an in-session interruption. Each is carried into its own
    /// channel's accumulator when that pass resumes; the video-size seed reads its entry
    /// directly (it resumes without beginning an accumulator run).
    private var resumableCheckpoints: [ScanCheckpoint.Kind: ScanCheckpoint] = [:]
    /// A resume waiting for the catalog rebuild its seed needs (blur and video sizes both
    /// require fresh records to reconcile against).
    private var pendingResume: ScanCheckpoint?
    /// Monotonic run sequence for checkpoints — seeded past the restored file at bootstrap
    /// so this session's runs always order after the previous session's writes.
    private var nextRunSequence = 0
    /// Sequence of the last video-size checkpoint written this session, for its completion
    /// clear (kind-aware: never removes another pass's file).
    private var lastVideoCheckpointSequence: Int?
    /// True while *this session* interrupted work — gates same-session auto-resume on
    /// foreground. A relaunch restores the checkpoint but never auto-starts: resume from a
    /// previous session is always an explicit tap.
    private var pausedThisSession = false
    /// The last lifecycle phase reported by the view.
    private var lifecyclePhase: AppLifecyclePhase = .active

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
        checkpointStore: any ScanCheckpointStore = FileScanCheckpointStore(),
        backgroundTasks: any BackgroundTaskScheduling = SystemBackgroundTaskScheduler(),
        widgetSummaryStore: any WidgetSummaryStoring = FileWidgetSummaryStore(),
        swipeSessionStore: any SwipeReviewSessionStore = FileSwipeReviewSessionStore(),
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
        self.checkpointStore = checkpointStore
        self.checkpointChannels = CheckpointChannels(store: checkpointStore)
        self.backgroundTasks = backgroundTasks
        self.widgetSummaryStore = widgetSummaryStore
        self.swipeSessionStore = swipeSessionStore
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

    /// The current video dataset's fingerprint, cached across renders.
    ///
    /// `VideoDataset.signature` is O(videos log videos) with a large joined-string build —
    /// it used to run inside every Videos screen and dashboard render (and once more per
    /// size-measurement tick, which for a 7k-video library is a multi-hundred-KB string
    /// built on the main actor). The fingerprint only changes when the catalog does, so
    /// it is built once per catalog and reused; observation still tracks `catalogState`
    /// directly (read first below), so a rebuild re-renders exactly the readers that ask.
    var videoDatasetSignature: String {
        guard case .completed(let result) = catalogState else {
            builtVideoSignature = ""
            builtVideoSignatureGeneration = videoSignatureGeneration
            return ""
        }
        if builtVideoSignatureGeneration != videoSignatureGeneration {
            builtVideoSignature = VideoDataset.signature(in: result)
            builtVideoSignatureGeneration = videoSignatureGeneration
        }
        return builtVideoSignature
    }

    /// The current video inventory for display — cached across renders.
    ///
    /// Every completed catalog's videos, resolved with whatever the current measurement has
    /// produced (measured bytes embedded; unknown stays unknown) and sorted largest-first —
    /// or the raw sorted inventory when no current measurement exists. The Videos screen
    /// renders this in every completed-catalog state, so enumeration completes first and
    /// measurement only fills sizes in; it never gates the list.
    ///
    /// The resolve + sort is O(videos log videos) and used to run in every Videos screen
    /// render (every selection toggle, every thumbnail state change, every progress tick).
    /// It now rebuilds only when the catalog or the measurement changes, so a screen full
    /// of selection toggles costs no sorts at all. Observation still tracks `catalogState`
    /// and `videoSizeResolution` directly (read first below), so a change re-renders
    /// exactly the readers that ask.
    var videoRecordsForDisplay: [PhotoAssetRecord] {
        let resolution = videoSizeResolution
        let signature = videoDatasetSignature // reads + registers catalogState
        guard case .completed(let catalog) = catalogState, !signature.isEmpty else {
            builtVideoRecords = []
            builtVideoRecordsGeneration = videoSignatureGeneration
            builtVideoRecordsResolution = resolution
            return []
        }
        if builtVideoRecordsGeneration == videoSignatureGeneration,
           builtVideoRecordsResolution == resolution {
            return builtVideoRecords
        }
        let videos = VideoDataset.records(in: catalog)
        let records: [PhotoAssetRecord]
        if let measurement = resolution.measurement,
           measurement.datasetSignature == signature {
            records = VideoDataset.sorted(
                VideoDataset.resolved(videos, with: measurement.bytes)
            )
        } else {
            // No current measurement (idle, or another dataset's): the inventory still
            // renders, every size unknown — never an empty screen waiting on measurement.
            records = VideoDataset.sorted(videos)
        }
        builtVideoRecords = records
        builtVideoRecordsGeneration = videoSignatureGeneration
        builtVideoRecordsResolution = resolution
        return records
    }

    /// The source-classified video inventories, cached across renders. Rebuilds only when the
    /// catalog changes (classification depends on `sourceType`, not on measured sizes), so a
    /// screen full of selection toggles costs no re-classification.
    var recordedVideosForDisplay: [PhotoAssetRecord] {
        ensureVideoSourceSplit()
        return builtRecordedVideos
    }

    var downloadedVideosForDisplay: [PhotoAssetRecord] {
        ensureVideoSourceSplit()
        return builtDownloadedVideos
    }

    /// Videos whose source evidence is neither a synced import nor a plain library asset
    /// (e.g. shared). Never folded into either bucket — reported as its own count.
    var otherVideosCount: Int {
        ensureVideoSourceSplit()
        return builtOtherVideosCount
    }

    private func ensureVideoSourceSplit() {
        guard builtVideoSourceGeneration != videoSignatureGeneration else { return }
        var recorded: [PhotoAssetRecord] = []
        var downloaded: [PhotoAssetRecord] = []
        var other = 0
        for record in videoRecordsForDisplay {
            switch VideoSourceClassification.of(record) {
            case .recorded: recorded.append(record)
            case .downloaded: downloaded.append(record)
            case .other: other += 1
            }
        }
        builtRecordedVideos = recorded
        builtDownloadedVideos = downloaded
        builtOtherVideosCount = other
        builtVideoSourceGeneration = videoSignatureGeneration
    }

    /// The age-thresholded screenshots (oldest first) for the Old Screenshots screen —
    /// cached; rebuilds only when the catalog changes.
    var oldScreenshotRecords: [PhotoAssetRecord] {
        ensureOldScreenshotCache()
        return builtOldScreenshotRecords
    }

    /// Screenshots excluded from the eligible list only because their creation date is
    /// unknown — reported honestly, never guessed to be old or young.
    var oldScreenshotUnknownDateCount: Int {
        ensureOldScreenshotCache()
        return builtOldScreenshotUnknownDateCount
    }

    private func ensureOldScreenshotCache() {
        guard builtOldScreenshotGeneration != videoSignatureGeneration else { return }
        guard case .completed(let catalog) = catalogState else {
            builtOldScreenshotRecords = []
            builtOldScreenshotUnknownDateCount = 0
            builtOldScreenshotGeneration = videoSignatureGeneration
            return
        }
        builtOldScreenshotRecords = OldScreenshotsPresentation.eligibleRecords(
            in: catalog,
            now: Date()
        )
        builtOldScreenshotUnknownDateCount = OldScreenshotsPresentation
            .unknownDateRecords(in: catalog).count
        builtOldScreenshotGeneration = videoSignatureGeneration
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
        // Restore an interrupted run's checkpoint as a resumable paused state (Phase C).
        // Nothing starts: no PhotoKit request, no enumeration. A missing, corrupt, or
        // incompatible checkpoint behaves exactly like a missing snapshot — first run.
        await restoreInterruptedCheckpoint()
        flowState = .dashboard
    }

    /// Loads every interrupted-run checkpoint a relaunch would find and represents each as
    /// the paused state its surface shows (M13: concurrent passes restore independently).
    /// Best-effort by design: an unusable checkpoint is cleared, never crashed on, never
    /// resumed.
    private func restoreInterruptedCheckpoint() async {
        let store = checkpointStore
        let restored = await Task.detached(priority: .utility) { store.loadAll() }.value
        guard !restored.isEmpty else { return }
        // Future writes from this session must order after every restored file's run, even
        // if a checkpoint turns out to be unusable below.
        for checkpoint in restored {
            nextRunSequence = max(nextRunSequence, checkpoint.runSequence + 1)
            checkpointChannels.adopt(checkpoint)
        }
        for checkpoint in restored {
            if checkpoint.kind == .similarity, PhotoAnalysisStage(rawValue: checkpoint.stage) == nil {
                // A similarity checkpoint without a recognizable stage cannot be shown or
                // resumed honestly — drop it rather than present a dead paused card.
                let writer = checkpointChannels.writer(for: .similarity)
                let sequence = checkpoint.runSequence
                await Task.detached(priority: .utility) { writer.clear(through: sequence) }.value
                continue
            }
            resumableCheckpoints[checkpoint.kind] = checkpoint
            representInterrupted(checkpoint)
        }
    }

    /// Represents one restored or deferred checkpoint as the paused state its surface shows.
    /// A video-size checkpoint has no paused surface (its seed applies the next time
    /// measurement starts, reconciled against the fresh catalog then), so it is stored as
    /// resumable but never represented.
    private func representInterrupted(_ checkpoint: ScanCheckpoint) {
        switch checkpoint.kind {
        case .similarity:
            let stage = PhotoAnalysisStage(rawValue: checkpoint.stage) ?? .preparing
            analysisState = .paused(PhotoAnalysisProgress(
                stage: stage,
                completedUnits: checkpoint.completedUnits,
                totalUnits: checkpoint.totalUnits
            ))
        case .catalog:
            catalogState = .paused(CatalogScanProgress(
                enumeratedCount: checkpoint.completedUnits,
                totalCount: checkpoint.totalUnits
            ))
        case .blur:
            blurAnalysisState = .paused(BlurAnalysisProgress(
                completedUnits: checkpoint.completedUnits,
                totalUnits: checkpoint.totalUnits
            ))
        case .videoSizes:
            break
        }
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
    private func persistCompletedScan(_ result: PhotoAnalysisResult) async -> Date {
        let completedAt = Date()
        let snapshot = ScanSnapshot(
            schemaVersion: ScanSnapshot.currentSchemaVersion,
            scanID: UUID().uuidString,
            completedAt: completedAt,
            result: result
        )
        let store = scanSnapshotStore
        // The snapshot write is file IO over potentially megabytes — keep it off the main
        // actor. It is awaited (so callers and tests still observe the persisted state
        // deterministically) but it no longer blocks main-actor progress: the result is
        // already on screen as `.completed` before this returns. Best-effort as before:
        // a failed write is ignored and never fails the scan.
        await Task.detached(priority: .utility) {
            try? store.save(snapshot)
        }.value
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
    ///
    /// `resuming` continues an interrupted build's checkpoint (progress display + run
    /// identity — enumeration itself restarts, because partial offsets cannot be
    /// reconstructed without persisting the whole catalog, which checkpoints deliberately
    /// never do).
    func startCatalogBuild(resuming checkpoint: ScanCheckpoint? = nil) {
        // One library reader at a time: an analysis run owns its own catalog stage, and a
        // rebuild started underneath an in-flight deletion would complete with pre-mutation
        // data. A sharpness pass snapshots the catalog records it was started with, so a
        // rebuild landing mid-run would hand its results a catalog that no longer matches.
        // All three requests are explicit user actions, so dropping this one is honest.
        guard !analysisState.isRunning else { return }
        guard !blurAnalysisState.isRunning else { return }
        guard !deletionState.isDeleting else { return }
        // A chained prerequisite (a blur/video resume rebuilding the catalog its seed
        // reconciles against) owns no checkpoint of its own: it must neither begin one nor
        // discard the checkpoint it is rebuilding for.
        let isChainedPrerequisite = pendingResume != nil && checkpoint == nil
        catalogTask?.cancel()
        catalogGeneration += 1
        let generation = catalogGeneration
        if !isChainedPrerequisite {
            beginCheckpointRun(kind: .catalog, carrying: checkpoint)
        }

        // A fresh run starts from no applied sample and an unknown denominator, so the
        // first event of each kind applies immediately instead of waiting out the interval.
        lastAppliedCatalogProgressAt = 0
        lastAppliedCatalogTotal = -1

        let builder = PhotoCatalogBuilder()
        scanETAEstimator.reset()
        scanETAEstimator.record(
            stage: "catalog",
            completed: CatalogScanProgress.indeterminate.enumeratedCount,
            total: CatalogScanProgress.indeterminate.totalCount,
            at: ScanETAEstimator.monotonicNow()
        )
        // Committed before the reader exists: creating it (a `PHAsset.fetchAssets` round
        // trip that materializes the whole library) now runs inside the task on the
        // cooperative pool, so this method returns immediately either way — a reader
        // failure lands in the task's catch below instead of synchronously here.
        catalogState = .running(.indeterminate)

        catalogTask = Task { [weak self] in
            guard let self else { return }
            let factory = self.makePhotoLibrary
            do {
                let reading = try await Task.detached(priority: .userInitiated) {
                    try factory()
                }.value
                for try await event in builder.makeScanStream(reading: reading) {
                    // A superseded run stops immediately: every write below would land data
                    // from an older read on top of newer state.
                    guard self.isCurrentCatalog(generation) else { return }
                    switch event {
                    case .progress(let progress):
                        if self.catalogState.isRunning,
                           self.shouldApplyCatalogProgress(
                                totalCount: progress.totalCount,
                                isComplete: progress.isComplete
                           ) {
                            self.catalogState = .running(progress)
                            self.checkpointChannels.accumulator(for: .catalog).setProgress(
                                kind: .catalog,
                                stage: "catalog",
                                completed: progress.enumeratedCount,
                                total: progress.totalCount
                            )
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
            } catch let error as PhotoLibraryReadError {
                guard self.isCurrentCatalog(generation) else { return }
                self.finishCatalogAttempt(.failed(error.catalogFailure))
            } catch is CancellationError {
                guard self.isCurrentCatalog(generation) else { return }
                self.finishCatalogAttempt(.cancelled)
            } catch let failure as CatalogScanFailure {
                guard self.isCurrentCatalog(generation) else { return }
                self.finishCatalogAttempt(failure == .cancelled ? .cancelled : .failed(failure))
            } catch {
                guard self.isCurrentCatalog(generation) else { return }
                self.finishCatalogAttempt(.failed(.underlying("Photos access is required to read your library.")))
            }
        }
        syncBackgroundTask()
    }

    /// Terminal transition for a catalog build that did not complete. Releases this run's
    /// checkpoint (kind-aware — never another pass's file) and drops any chained resume:
    /// a blur/video resume whose prerequisite failed keeps its own interrupted checkpoint
    /// (still shown paused, resumable by an explicit tap) but does not retry itself.
    private func finishCatalogAttempt(_ state: CatalogScanState) {
        catalogState = state
        pendingResume = nil
        finishCheckpointRun(kind: .catalog)
        syncBackgroundTask()
    }

    func cancelCatalogBuild() {
        // An explicit cancel abandons this build's own resumable state: its file goes, and
        // a paused catalog surface returns to "not started". Scoped to `.catalog` (M13) —
        // a concurrently paused analysis or sharpness checkpoint is not this build's to
        // abandon; each pass owns its own channel.
        discardInterruptedCheckpoint(kinds: [.catalog])
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration += 1
        if catalogState.isRunning {
            catalogState = .cancelled
        }
        syncBackgroundTask()
    }

    private func isCurrentCatalog(_ generation: Int) -> Bool {
        catalogGeneration == generation
    }

    // MARK: - Analysis coordination (M10)

    /// Starts the queued pass, if any, now that the pipeline is free. Called only from
    /// terminal transitions — completion, failure, or cancel of a heavy pass (the `didSet`
    /// observers on `analysisState` / `blurAnalysisState`), or a deletion leaving
    /// `.deleting` — never while a pause still owns the pipeline: a paused run resumes
    /// itself and keeps the queue waiting.
    private func drivePendingAnalysis() {
        guard let request = pendingAnalysisRequest else { return }
        // A paused pass still owns the slot (it will resume itself); handing the pipeline
        // over now would run two passes the moment the app returns to the foreground.
        if case .paused = analysisState { return }
        if case .paused = blurAnalysisState { return }
        guard !analysisState.isRunning, !blurAnalysisState.isRunning else { return }
        // A deletion in flight keeps the queue; the flip out of `.deleting` drives again
        // (see `deletionState`'s observer).
        guard !deletionState.isDeleting else { return }
        pendingAnalysisRequest = nil
        switch request {
        case .similarity: startSimilarityAnalysis()
        case .blur: startBlurAnalysis()
        }
    }

    /// Removes the queued request without touching the running pass. Idempotent.
    func cancelPendingAnalysis() {
        pendingAnalysisRequest = nil
    }

    /// Explicit cancel-and-switch: the running pass is cancelled through its normal
    /// generation-guarded path and the queued pass starts immediately, without waiting for
    /// any other transition. The queue slot is claimed first so the cancel's own terminal
    /// flip cannot also drive it (exactly-once).
    func startPendingAnalysisNow() {
        guard let request = pendingAnalysisRequest else { return }
        pendingAnalysisRequest = nil
        switch request {
        case .similarity:
            cancelBlurAnalysis()
            startSimilarityAnalysis()
        case .blur:
            cancelSimilarityAnalysis()
            startBlurAnalysis()
        }
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
    ///
    /// This is the **standalone, single-pass** entry point (retry, resume, and the legacy
    /// queue): it keeps its serialized admission so an explicit one-pass request never races
    /// the other. The unified Image Cleanup session — what every Analyze button calls — is
    /// `startImageAnalysis`, which shares one enumeration across both pipelines.
    ///
    /// `resuming` carries an interrupted run's checkpoint: its evidence seeds the cheap
    /// pass (already-hashed and already-keyed assets cost no request) and its progress
    /// display survives the interruption. Enumeration (Stage A) still restarts — catalog
    /// offsets cannot be reconstructed without persisting the whole catalog, which
    /// checkpoints deliberately never do.
    func startSimilarityAnalysis(resuming checkpoint: ScanCheckpoint? = nil) {
        guard !analysisState.isRunning else { return }
        // Serialized admission for the standalone entry point (M10): one explicit one-pass
        // request queues — visibly, never a silent drop — and starts when the running pass
        // releases the pipeline. The unified session bypasses this by owning the catalog.
        if blurAnalysisState.isRunning {
            pendingAnalysisRequest = .similarity
            return
        }
        // Never rebuild datasets underneath an in-flight Photos mutation.
        guard !deletionState.isDeleting else { return }
        // The request is admitted past the coordination guards; any queue entry is spent.
        pendingAnalysisRequest = nil
        guard photoPermissionState.isUsable else {
            analysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }
        prepareSimilarityRun()
        let generation = analysisGeneration
        // Claim this pass's checkpoint channel: a resumed run adopts the carried payload, a
        // fresh run discards whatever interrupted state existed for this kind (design: an
        // explicit new run supersedes resumable work).
        let runSequence = beginCheckpointRun(kind: .similarity, carrying: checkpoint)
        let engine = Self.makeSimilarityEngine(
            thumbnailLoader: thumbnailLoader,
            accumulator: checkpointChannels.accumulator(for: .similarity),
            runSequence: runSequence,
            budget: analysisConcurrencyBudget
        )
        analysisTask = Task { [weak self] in
            guard let self else { return }
            guard let catalog = await self.enumerateSharedCatalog(generation: generation, unified: false) else {
                return
            }
            await self.runSimilarityStageB(
                catalog: catalog,
                generation: generation,
                checkpoint: checkpoint,
                engine: engine
            )
        }
        syncBackgroundTask()
    }

    /// The single user-facing Analyze action (M13): one shared catalog enumeration, then the
    /// similarity and sharpness pipelines launched **concurrently** over the same snapshot.
    ///
    /// This is what every Analyze button calls. With both pipelines idle it starts the
    /// unified session; with exactly one still running (the other failed or was cancelled
    /// mid-session) it starts only the idle one through its own entry point, which queues it
    /// behind the running pipeline rather than dropping the tap — a retry of one pipeline
    /// never restarts or cancels work that is still in flight. Repeated taps are idempotent
    /// for the active session (while both run, the request is already satisfied).
    ///
    /// Neither pipeline waits for the other to finish: similarity may reach `.completed` and
    /// become reviewable while the sharpness pass is still running, and completion, failure,
    /// or cancellation of one never touches the other. They coordinate only through the
    /// shared `AnalysisConcurrencyBudget` so their combined worker width never exceeds one
    /// pass's alone.
    ///
    /// One `PHAsset.fetchAssets` enumeration feeds both pipelines. It lives in `catalogTask`
    /// — not either pipeline's task — so an explicit cancel of one pipeline's *work* leaves
    /// the shared read standing for the other: cancelling similarity mid-enumeration still
    /// lets the sharpness pass get its catalog, and vice versa. The read is only abandoned
    /// when the whole session is (pause, deletion, a superseding session), because then both
    /// pipelines are interrupted together. Both checkpoint channels are claimed at setup so
    /// an interruption during the shared read resumes both from their own files; the
    /// sharpness pass's own evidence is only seeded once its pass actually begins.
    ///
    /// `resuming` seeds each pipeline from its own interrupted checkpoint without starting a
    /// pass that was not interrupted.
    func startImageAnalysis(
        resuming similarityCheckpoint: ScanCheckpoint? = nil,
        blurCheckpoint: ScanCheckpoint? = nil
    ) {
        // Idempotent for the active session: while both pipelines run, this tap's intent is
        // already being served — starting over would discard in-flight work.
        guard !(analysisState.isRunning && blurAnalysisState.isRunning) else { return }
        // Never rebuild datasets underneath an in-flight Photos mutation.
        guard !deletionState.isDeleting else { return }
        // The unified session owns admission; a queued single-pass request is spent here and
        // may be re-set by the single-pipeline fallback below.
        pendingAnalysisRequest = nil
        guard photoPermissionState.isUsable else {
            if !analysisState.isRunning { analysisState = .failed(.underlying("Photos access is required to read your library.")) }
            if !blurAnalysisState.isRunning { blurAnalysisState = .failed(.underlying("Photos access is required to read your library.")) }
            return
        }

        // Exactly one pipeline still running: start only the idle one. Its own entry point
        // queues it behind the running pipeline (M10) instead of racing it, so a retry of
        // one screen never disturbs the pass that is still doing work.
        if analysisState.isRunning {
            startBlurAnalysis(resuming: blurCheckpoint)
            return
        }
        if blurAnalysisState.isRunning {
            startSimilarityAnalysis(resuming: similarityCheckpoint)
            return
        }

        // Both idle: the unified session — one shared enumeration, two concurrent pipelines.
        prepareSimilarityRun()
        prepareBlurRun()
        let similarityGeneration = analysisGeneration
        let blurGeneration = blurAnalysisGeneration

        // Both channels are claimed at setup (M13): an interruption during the shared read
        // produces a resumable file for each pipeline, and a pass that never got to start
        // resumes as a fresh pass with no evidence (its seed refuses an empty calibration).
        let similaritySequence = beginCheckpointRun(kind: .similarity, carrying: similarityCheckpoint)
        let blurSequence = beginCheckpointRun(kind: .blur, carrying: blurCheckpoint)
        let engine = Self.makeSimilarityEngine(
            thumbnailLoader: thumbnailLoader,
            accumulator: checkpointChannels.accumulator(for: .similarity),
            runSequence: similaritySequence,
            budget: analysisConcurrencyBudget
        )

        // The shared enumeration runs in `catalogTask` — deliberately not either pipeline's
        // task — so cancelling similarity leaves the read standing for blur, and vice versa.
        // Both pipelines launch over its result, each still guarded by its own generation.
        sharedEnumerationInFlight = true
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sharedEnumerationInFlight = false }
            guard let catalog = await self.enumerateSharedCatalog(generation: self.catalogGeneration, unified: true) else {
                return
            }
            // Catalog stands: launch whatever is still running, concurrently. Either
            // pipeline may have been cancelled during the shared read — that cancel was
            // about *its* work, so only that pipeline is skipped; the other proceeds.
            if self.blurAnalysisState.isRunning {
                self.blurAnalysisTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runBlurPass(
                        catalog: catalog,
                        generation: blurGeneration,
                        checkpoint: blurCheckpoint,
                        runSequence: blurSequence
                    )
                }
            } else {
                // Blur was cancelled or paused during the shared read: release the channel
                // its setup claimed so a later run finds it free.
                self.finishCheckpointRun(kind: .blur)
            }
            if self.analysisState.isRunning {
                self.analysisTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runSimilarityStageB(
                        catalog: catalog,
                        generation: similarityGeneration,
                        checkpoint: similarityCheckpoint,
                        engine: engine
                    )
                }
            }
        }
        syncBackgroundTask()
    }

    /// Common setup for a similarity run: supersedes any prepared plan, claims a fresh
    /// generation and selection, resets the progress display, and moves `analysisState`
    /// to `.running(.preparing)`. Leaves `catalogTask` cancelled so this run owns the
    /// single library enumeration.
    private func prepareSimilarityRun() {
        // Video-size measurement is deliberately untouched here: it is I/O-bound over
        // its own bounded batches and coexists with a pass (the dataset a pass walks
        // does not change), so starting an analysis no longer starves it — the failure
        // mode where chained passes left the Video Cleanup screen forever unmeasured.
        // A fresh analysis supersedes any prepared plan.
        planBuildGeneration += 1
        applyDeletion(.noSelection)
        // A fresh run enumerates the *current* catalog, so any removals recorded against a
        // previous, superseded run are not this run's to reconcile (M13).
        deletionsDuringRunningPasses = []

        analysisTask?.cancel()
        analysisGeneration += 1
        selection = PhotoSelectionModel()

        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration += 1
        if catalogState.isRunning {
            catalogState = .cancelled
        }

        lastAppliedProgressAt = 0
        lastAppliedStage = nil
        lastAppliedCatalogProgressAt = 0
        lastAppliedCatalogTotal = -1
        scanETAEstimator.reset()
        // Committed before the reader exists: reader creation runs inside the task on the
        // cooperative pool (see `startCatalogBuild`), so a failure surfaces through the
        // task's PhotoLibraryReadError catch rather than synchronously here.
        analysisState = .running(
            PhotoAnalysisProgress(stage: .preparing, completedUnits: 0, totalUnits: 0)
        )
    }

    /// Common setup for a sharpness run: supersedes any prepared plan, claims a fresh
    /// generation and an empty selection, and moves `blurAnalysisState` to `.running`. The
    /// state flip happens here (at admission) so the Potentially Blurry screen shows the
    /// session immediately; its first real counts arrive when the pass begins.
    private func prepareBlurRun() {
        planBuildGeneration += 1
        applyDeletion(.noSelection)
        // A fresh pass measures the *current* catalog, so any removals recorded against a
        // previous, superseded run are not this pass's to reconcile (M13).
        deletionsDuringRunningPasses = []
        blurAnalysisGeneration += 1
        blurSelection = PhotoSelectionModel()
        blurAnalysisState = .running(BlurAnalysisProgress(completedUnits: 0, totalUnits: 0))
    }

    /// Stage A: enumerates the permitted photo catalog exactly once for this run, reporting
    /// progress through `analysisState`'s `preparing` stage and the similarity checkpoint.
    /// Stores the result in `catalogState` when it completes. Returns the catalog, or `nil`
    /// when the read was superseded, cancelled, or failed (the failure is surfaced through
    /// the similarity pipeline, and in a unified session through the sharpness pipeline too
    /// — a shared read that fails leaves neither pipeline a catalog to stand on).
    ///
    /// `generation` is the survival key: a standalone run guards on the similarity
    /// generation (cancelling the run aborts its own read), a unified session guards on the
    /// catalog generation (cancelling one pipeline's *work* does not abort the shared read
    /// the other still needs — see `startImageAnalysis`). Progress is only written while the
    /// similarity surface still wants it, so a cancelled pipeline never receives a late tick.
    private func enumerateSharedCatalog(generation: Int, unified: Bool) async -> CatalogScanResult? {
        let factory = makePhotoLibrary
        let builder = PhotoCatalogBuilder()
        var built: CatalogScanResult?
        do {
            // The reader is created off the main actor — a `PHAsset.fetchAssets` round trip
            // over the whole library costs no main-thread time either way.
            let reading = try await Task.detached(priority: .userInitiated) {
                try factory()
            }.value
            for try await event in builder.makeScanStream(reading: reading) {
                guard unified ? isCurrentCatalog(generation) : isCurrentAnalysis(generation) else { return nil }
                switch event {
                case .progress(let progress):
                    // Coalesced under the catalog policy (see `shouldApplyCatalogProgress`):
                    // the enumeration phase no longer writes observed storage once per event,
                    // which for a 40k library is thousands of unneeded writes.
                    // Only while the similarity surface still wants it: a pipeline cancelled
                    // during a unified shared read stops receiving ticks — the read itself
                    // survives for the other pipeline.
                    guard analysisState.isRunning,
                          shouldApplyCatalogProgress(
                            totalCount: progress.totalCount,
                            isComplete: progress.isComplete
                          )
                    else { break }
                    analysisState = .running(PhotoAnalysisProgress(
                        stage: .preparing,
                        completedUnits: progress.enumeratedCount,
                        totalUnits: progress.totalCount
                    ))
                    // Stage A of an analysis *is* a catalog build — feed the estimator the
                    // same standalone build does, or the dashboard's countdown sat
                    // un-updated for the whole enumeration phase.
                    scanETAEstimator.record(
                        stage: "catalog",
                        completed: progress.enumeratedCount,
                        total: progress.totalCount,
                        at: ScanETAEstimator.monotonicNow()
                    )
                    // Tagged `.similarity`: this run owns that channel, and its stage A is
                    // the stage a resume would restore.
                    checkpointChannels.accumulator(for: .similarity).setProgress(
                        kind: .similarity,
                        stage: PhotoAnalysisStage.preparing.rawValue,
                        completed: progress.enumeratedCount,
                        total: progress.totalCount
                    )
                case .completed(let result):
                    built = result
                    noteCatalogCompleted(result)
                }
            }
        } catch is CancellationError {
            finishSharedEnumerationFailure(.cancelled, unified: unified)
            return nil
        } catch let failure as CatalogScanFailure {
            finishSharedEnumerationFailure(
                failure == .cancelled ? .cancelled : .failed(.underlying(failure.userMessage)),
                unified: unified
            )
            return nil
        } catch let failure as PhotoLibraryReadError {
            finishSharedEnumerationFailure(.failed(Self.analysisFailure(for: failure)), unified: unified)
            return nil
        } catch {
            finishSharedEnumerationFailure(
                .failed(.underlying("Photos access is required to read your library.")),
                unified: unified
            )
            return nil
        }

        // The stream can finish without `.completed` when it was cancelled mid-read.
        guard let built else {
            finishSharedEnumerationFailure(.cancelled, unified: unified)
            return nil
        }
        guard unified ? isCurrentCatalog(generation) : isCurrentAnalysis(generation) else { return nil }
        return built
    }

    /// Surfaces a shared enumeration that ended without a catalog. In a unified session the
    /// sharpness pass depended on the same read, so it is failed/cancelled alongside the
    /// similarity pipeline — never left "running" with no catalog to stand on. In a
    /// standalone run only the similarity pipeline is touched.
    private func finishSharedEnumerationFailure(_ state: PhotoAnalysisState, unified: Bool) {
        finishAnalysis(analysisGeneration, as: state)
        guard unified, blurAnalysisState.isRunning else { return }
        switch state {
        case .cancelled:
            finishBlurAnalysis(blurAnalysisGeneration, as: .cancelled)
        case .failed(let failure):
            finishBlurAnalysis(
                blurAnalysisGeneration,
                as: .failed(.underlying(Self.blurFailureMessage(for: failure)))
            )
        default:
            break
        }
    }

    /// The sharpness pass's user-facing message for a similarity failure. The shared read
    /// failed, so both surfaces show an honest, independent explanation.
    private static func blurFailureMessage(for failure: PhotoAnalysisFailure) -> String {
        switch failure {
        case .cancelled:
            return "Sharpness analysis could not finish. Please try again."
        case .underlying(let detail):
            return detail
        }
    }

    /// A catalog's records indexed by asset ID — the lookup `removingAssets(_:catalogRecords:)`
    /// uses to re-score a group whose recommended KEEP was deleted.
    private static func recordsByID(_ catalog: CatalogScanResult) -> [String: PhotoAssetRecord] {
        Dictionary(
            catalog.records.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Drops the shared deletion-reconciliation set once no pipeline is running (M13). At
    /// that point every result that could have been affected has already been reconciled,
    /// and a later run must never inherit a stale set.
    private func clearDeletionReconciliationIfIdle() {
        guard !analysisState.isRunning, !blurAnalysisState.isRunning else { return }
        deletionsDuringRunningPasses = []
    }

    /// Stage B (similarity): runs the engine over a catalog the caller has already built and
    /// stands in `catalogState`. Reports through `analysisState`, releases the similarity
    /// checkpoint on success, and persists the completed result. The caller owns admission
    /// and must already have set `.running` and claimed the checkpoint run.
    private func runSimilarityStageB(
        catalog: CatalogScanResult,
        generation: Int,
        checkpoint: ScanCheckpoint?,
        engine: PhotoSimilarityEngine
    ) async {
        // Seeded with whatever the interrupted run already earned (entries whose asset still
        // exists with the exact recorded modification date; deleted or changed assets
        // recompute).
        var sawCompletion = false
        let seed = Self.fingerprintSeed(from: checkpoint, records: catalog.records)
        do {
            for try await event in engine.makeAnalysisStream(
                records: catalog.records,
                seed: seed
            ) {
                guard isCurrentAnalysis(generation) else { return }
                switch event {
                case .progress(let progress):
                    applyAnalysisProgress(progress)
                case .completed(let result):
                    sawCompletion = true
                    // The channel is released *before* the terminal state write: the flip
                    // may hand a queued single-pass request its slot (M10), which must find
                    // the checkpoint free.
                    finishCheckpointRun(kind: .similarity)
                    // Reconcile confirmed removals that landed while this pass ran (M13):
                    // the pass sampled the pre-mutation catalog, so its result may still
                    // describe assets that no longer exist. Only the removed IDs leave —
                    // the work for every surviving asset stands, so a deletion never
                    // forces a full re-run.
                    let reconciled = result.removingAssets(
                        deletionsDuringRunningPasses,
                        catalogRecords: Self.recordsByID(catalog)
                    )
                    selection = PhotoSelectionModel(result: reconciled)
                    analysisState = .completed(reconciled)
                    clearDeletionReconciliationIfIdle()
                    let completedAt = await persistCompletedScan(reconciled)
                    await writeWidgetSummaryAfterScanCompleted(at: completedAt)
                }
            }
            if !sawCompletion {
                finishAnalysis(generation, as: .cancelled)
            }
        } catch is CancellationError {
            finishAnalysis(generation, as: .cancelled)
        } catch let failure as PhotoAnalysisFailure {
            finishAnalysis(
                generation,
                as: failure == .cancelled ? .cancelled : .failed(failure)
            )
        } catch {
            // PhotoKit/underlying error descriptions never reach the user verbatim.
            finishAnalysis(
                generation,
                as: .failed(.underlying("Similarity analysis could not finish. Please try again."))
            )
        }
    }

    /// Builds the similarity engine with its checkpoint sink bound to the given run sequence
    /// and its worker width bound to the shared cross-pipeline budget (M13).
    private static func makeSimilarityEngine(
        thumbnailLoader: any PhotoThumbnailLoading,
        accumulator: ScanCheckpointAccumulator,
        runSequence: Int,
        budget: AnalysisConcurrencyBudget
    ) -> PhotoSimilarityEngine {
        var configuration = PhotoAnalysisConfiguration()
        // A policy source, not a tuning value: the engine reads the live active-pass count
        // at every width decision, so both pipelines halve their width while concurrent and
        // each keeps the full width when it is the only heavy pass running.
        configuration.concurrentPasses = { budget.activePassCount }
        let checkpointSink: (@Sendable (CheckpointEvidence) -> Void)? = { evidence in
            accumulator.record(evidence, runSequence: runSequence)
        }
        #if DEBUG
        // M4B validation hook: `NETTO_SCAN_METRICS=1` injects the signpost observer and the
        // metrics recorder so an end-to-end run can be measured from `log stream`. Production
        // never sets the variable; without it the engine is exactly as before (no telemetry).
        if ProcessInfo.processInfo.environment["NETTO_SCAN_METRICS"] == "1" {
            return PhotoSimilarityEngine(
                configuration: configuration,
                // The shared loader (and its shared asset-reference cache): the
                // perceptual/verification/sharpness passes reuse resolved references
                // instead of re-fetching them per stage.
                thumbnailLoader: thumbnailLoader,
                stageObserver: SignpostStageObserver(),
                metrics: AnalysisMetrics(),
                checkpointSink: checkpointSink
            )
        }
        return PhotoSimilarityEngine(
            configuration: configuration,
            thumbnailLoader: thumbnailLoader,
            checkpointSink: checkpointSink
        )
        #else
        return PhotoSimilarityEngine(
            configuration: configuration,
            thumbnailLoader: thumbnailLoader,
            checkpointSink: checkpointSink
        )
        #endif
    }

    /// Cancels the in-flight run. The generation bump makes any late write from the old run a
    /// no-op, so the state can never flip back after this returns.
    func cancelSimilarityAnalysis() {
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        // The checkpoint is abandoned before the state flip: cancelling a running pass is
        // a terminal transition, and the flip may drive a queued pass (M10) that claims
        // its slot. Scoped to this kind (M13): a concurrently running sharpness pass keeps
        // its own channel, its own file, and its own progress.
        discardInterruptedCheckpoint(kinds: [.similarity])
        if analysisState.isRunning {
            analysisState = .cancelled
        }
        syncBackgroundTask()
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
        // Same cadence as the state write: the checkpoint's saved stage never runs ahead of
        // or behind what the UI was told, and a pause saves exactly the progress on screen.
        checkpointChannels.accumulator(for: .similarity).setProgress(
            kind: .similarity,
            stage: progress.stage.rawValue,
            completed: progress.completedUnits,
            total: progress.totalUnits
        )
        // Sampled at the same coalesced cadence the state is written, with monotonic time —
        // the estimator's own minimum sample interval smooths it further.
        scanETAEstimator.record(
            stage: progress.stage.rawValue,
            completed: progress.completedUnits,
            total: progress.totalUnits,
            at: ScanETAEstimator.monotonicNow()
        )
    }

    /// Catalog progress coalescing, shared by a standalone build and Stage A of an analysis:
    /// apply when the denominator changed (…of a *different* total — the value readers key
    /// off), when the count is terminal (a run's last tick must not be swallowed), or when
    /// `progressCoalesceInterval` has passed. Every other event is dropped — its counters
    /// are not lost: the next applied event carries the newest ones, and completion is its
    /// own unconditional event. The producer is untouched; this only bounds the main-actor
    /// write rate, never raises it, and never delays cancellation, completion, or failure.
    /// Callers record into the ETA estimator only when this returns `true`, so the
    /// estimator's samples match what the UI actually saw.
    private func shouldApplyCatalogProgress(totalCount: Int, isComplete: Bool) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if lastAppliedCatalogTotal != totalCount || isComplete {
            lastAppliedCatalogTotal = totalCount
            lastAppliedCatalogProgressAt = now
            return true
        }
        guard now - lastAppliedCatalogProgressAt >= progressCoalesceInterval else { return false }
        lastAppliedCatalogProgressAt = now
        return true
    }

    /// The active scan's current-stage estimate. Computed on read from the rolling estimator
    /// — the view formats it; no arithmetic and no additional state writes live in SwiftUI.
    func scanETA() -> ScanETA {
        scanETAEstimator.estimate()
    }

    private func finishAnalysis(_ generation: Int, as state: PhotoAnalysisState) {
        guard isCurrentAnalysis(generation) else { return }
        // Release the checkpoint slot before the terminal write (M10 — same order as the
        // sharpness pass): the flip may drive a queued pass that claims the slot. A
        // paused run never reaches here (pausing bumped the generation, so this write
        // would be staled anyway).
        if case .cancelled = state {
            finishCheckpointRun(kind: .similarity)
        } else if case .failed = state {
            finishCheckpointRun(kind: .similarity)
        }
        analysisState = state
        syncBackgroundTask()
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
    /// seam every other pass uses and never touches the photo library. Starting it also
    /// invalidates any prepared deletion review — plans are bound to the dataset they were
    /// built from — and resets the blur selection, so a fresh run always opens with
    /// nothing marked.
    ///
    /// This is the **standalone, single-pass** entry point (retry, resume, and the legacy
    /// queue): it keeps its serialized admission so an explicit one-pass request never races
    /// the other, and it requires the catalog to already stand. The unified Image Cleanup
    /// session — what every Analyze button calls — is `startImageAnalysis`, which builds the
    /// catalog once and launches this pass concurrently with similarity.
    ///
    /// `resuming` carries an interrupted pass's checkpoint: already-classified assets are
    /// tallied without a request (only under the exact thresholds they were classified
    /// with — a calibration change re-measures everything) and the saved progress display
    /// continues.
    func startBlurAnalysis(resuming checkpoint: ScanCheckpoint? = nil) {
        guard !blurAnalysisState.isRunning else { return }
        // Serialized admission for the standalone entry point (M10): the request queues —
        // visible, never a silent drop — and starts when the running pass releases the
        // pipeline. The unified session bypasses this by owning the shared catalog.
        if analysisState.isRunning {
            pendingAnalysisRequest = .blur
            return
        }
        // Never rebuild datasets underneath an in-flight Photos mutation.
        guard !deletionState.isDeleting else { return }
        // The request is admitted past the coordination guards; any queue entry is spent.
        pendingAnalysisRequest = nil
        guard photoPermissionState.isUsable else {
            blurAnalysisState = .failed(.underlying("Photos access is required to read your library."))
            return
        }
        guard case .completed(let catalog) = catalogState else {
            blurAnalysisState = .failed(.underlying("Your library scan has not finished. Build your catalog, then try again."))
            return
        }
        prepareBlurRun()
        let generation = blurAnalysisGeneration
        // Claim this pass's channel (adopting the carried payload on resume; discarding
        // superseded interrupted state of this kind on a fresh start).
        let runSequence = beginCheckpointRun(kind: .blur, carrying: checkpoint)
        blurAnalysisTask = Task { [weak self] in
            guard let self else { return }
            await self.runBlurPass(
                catalog: catalog,
                generation: generation,
                checkpoint: checkpoint,
                runSequence: runSequence
            )
        }
        syncBackgroundTask()
    }

    /// The sharpness pass over a catalog the caller has already built and stands in
    /// `catalogState`. Reports through `blurAnalysisState`, releases the blur checkpoint on
    /// success, and synchronizes the blur dataset so candidates become markable. Admission,
    /// the `.running` state, and the claimed checkpoint run are the caller's — this is the
    /// body both the standalone entry point and the unified session share.
    private func runBlurPass(
        catalog: CatalogScanResult,
        generation: Int,
        checkpoint: ScanCheckpoint?,
        runSequence: Int
    ) async {
        let engine = Self.makeBlurEngine(
            thumbnailLoader: thumbnailLoader,
            accumulator: checkpointChannels.accumulator(for: .blur),
            runSequence: runSequence,
            clock: blurAnalysisClock,
            budget: analysisConcurrencyBudget
        )
        let records = catalog.records
        // Verdicts the interrupted run already earned, reconciled against the fresh catalog
        // (deleted or re-exported assets re-measure) — nil when the calibration differs,
        // which the engine also refuses, so a mismatch is always a full pass. Built off the
        // main actor: the seed walks every catalog record and saved verdict, work that used
        // to stall the tap-to-start path on a large library before the first thumbnail was
        // ever requested.
        let seedCheckpoint = checkpoint
        let seedRecords = records
        let seedThresholds = engine.configuration.thresholds
        let seed = await Task.detached(priority: .userInitiated) {
            Self.blurSeed(
                from: seedCheckpoint,
                records: seedRecords,
                thresholds: seedThresholds
            )
        }.value

        var sawCompletion = false
        do {
            for try await event in engine.makeAnalysisStream(
                records: records,
                seed: seed
            ) {
                guard isCurrentBlurAnalysis(generation) else { return }
                switch event {
                case .progress(let progress):
                    blurAnalysisState = .running(progress)
                    // Single-stage pass: counts only, tagged `.blur` so a chained catalog
                    // rebuild can never rewrite this run's saved progress.
                    checkpointChannels.accumulator(for: .blur).setProgress(
                        kind: .blur,
                        stage: "",
                        completed: progress.completedUnits,
                        total: progress.totalUnits
                    )
                case .completed(let result):
                    sawCompletion = true
                    // The channel is released *before* the terminal state write: the flip
                    // may hand a queued single-pass request its slot (M10), which must find
                    // the checkpoint free.
                    finishCheckpointRun(kind: .blur)
                    // Reconcile confirmed removals that landed while this pass ran (M13):
                    // the pass sampled the pre-mutation catalog, so its result may still
                    // describe assets that no longer exist. Only the removed IDs leave —
                    // the work for every surviving asset stands.
                    let reconciled = result.removingAssets(deletionsDuringRunningPasses)
                    blurAnalysisState = .completed(reconciled)
                    clearDeletionReconciliationIfIdle()
                    // Admission only: candidates become markable, nothing is marked.
                    synchronizeBlurDataset()
                }
            }
            if !sawCompletion {
                finishBlurAnalysis(generation, as: .cancelled)
            }
        } catch is CancellationError {
            finishBlurAnalysis(generation, as: .cancelled)
        } catch let failure as BlurAnalysisFailure {
            finishBlurAnalysis(
                generation,
                as: failure == .cancelled ? .cancelled : .failed(failure)
            )
        } catch {
            // PhotoKit/underlying error descriptions never reach the user verbatim.
            finishBlurAnalysis(
                generation,
                as: .failed(.underlying("Sharpness analysis could not finish. Please try again."))
            )
        }
    }

    /// Builds the sharpness engine with its checkpoint sink bound to the given run sequence
    /// and its worker width bound to the shared cross-pipeline budget (M13), stamping the
    /// calibration the verdicts will be classified under into the accumulator first (so an
    /// interruption persists it alongside the evidence).
    private static func makeBlurEngine(
        thumbnailLoader: any PhotoThumbnailLoading,
        accumulator: ScanCheckpointAccumulator,
        runSequence: Int,
        clock: @escaping @Sendable () -> Date,
        budget: AnalysisConcurrencyBudget
    ) -> BlurAnalysisEngine {
        var configuration = BlurAnalysisConfiguration()
        // A policy source, not a tuning value: read live at every width decision so both
        // pipelines halve their width while concurrent (see `makeSimilarityEngine`).
        configuration.concurrentPasses = { budget.activePassCount }
        accumulator.noteBlurThresholds(configuration.thresholds)
        let checkpointSink: (@Sendable (CheckpointEvidence) -> Void)? = { evidence in
            accumulator.record(evidence, runSequence: runSequence)
        }
        #if DEBUG
        // Same validation hook as the similarity pass: `NETTO_SCAN_METRICS=1` injects the
        // blur metrics recorder so an end-to-end run prints one `blur-summary` line at the
        // end (see `BlurAnalysisMetrics`). Without it the engine is exactly as before.
        if ProcessInfo.processInfo.environment["NETTO_SCAN_METRICS"] == "1" {
            return BlurAnalysisEngine(
                configuration: configuration,
                thumbnailLoader: thumbnailLoader,
                metrics: BlurAnalysisMetrics(),
                now: clock,
                checkpointSink: checkpointSink
            )
        }
        return BlurAnalysisEngine(
            configuration: configuration,
            thumbnailLoader: thumbnailLoader,
            now: clock,
            checkpointSink: checkpointSink
        )
        #else
        return BlurAnalysisEngine(
            configuration: configuration,
            thumbnailLoader: thumbnailLoader,
            now: clock,
            checkpointSink: checkpointSink
        )
        #endif
    }

    /// Cancels the in-flight sharpness pass. The generation bump makes any late write
    /// from the old run a no-op, so the state can never flip back after this returns.
    func cancelBlurAnalysis() {
        blurAnalysisGeneration += 1
        blurAnalysisTask?.cancel()
        blurAnalysisTask = nil
        // The checkpoint is abandoned before the state flip: cancelling a running pass is
        // a terminal transition, and the flip may drive a queued pass (M10) that claims
        // its slot. Scoped to this kind (M13): a concurrently running similarity pass keeps
        // its own channel, its own file, and its own progress.
        discardInterruptedCheckpoint(kinds: [.blur])
        if blurAnalysisState.isRunning {
            blurAnalysisState = .cancelled
        }
        syncBackgroundTask()
    }

    private func isCurrentBlurAnalysis(_ generation: Int) -> Bool {
        blurAnalysisGeneration == generation
    }

    private func finishBlurAnalysis(_ generation: Int, as state: BlurAnalysisState) {
        guard isCurrentBlurAnalysis(generation) else { return }
        // Release the checkpoint slot before the terminal write: flipping the state may
        // drive a queued pass into `beginCheckpointRun` (M10), which must find the slot
        // free. A paused pass never reaches here (its generation was bumped at pause, so
        // this write would be staled anyway).
        if case .cancelled = state {
            finishCheckpointRun(kind: .blur)
        } else if case .failed = state {
            finishCheckpointRun(kind: .blur)
        }
        blurAnalysisState = state
        syncBackgroundTask()
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
        case .notStarted, .running, .paused, .cancelled, .failed:
            // Paused has no result yet either — the pass saved its progress, not a
            // dataset, and resume (or an explicit cancel) reconciles again afterwards.
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
        case .running, .paused:
            // A rebuild is in flight — or was interrupted with no completed catalog to
            // read from; reconcile again when it completes, resumes, or is cancelled.
            catalogImageIDs = []
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
        case .similarPhotos, .swipeReview:
            // Swipe Review writes its marks into this same selection and never needs the
            // similarity result to open or run — its deck *is* the scanned catalog — so a
            // library that has not been analysed must not dead-end its "Review Cleanup".
            // Fall back to the empty result exactly as the catalog-only sources do: the
            // plan is record-driven (validation, sizes, confirmation are unchanged), and
            // a later analysis rebuilds the selection and stales any plan built without it.
            // The swipe-cleanup source additionally scopes the plan to the checked subset
            // of that selection (`selectionIDs(for:)`), but plan *building* is identical.
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
    /// immediately stale. Only plans built from a source that reads this selection are
    /// affected: `.similarPhotos` reads all of it, and `.swipeReview` reads its checked
    /// subset of it, so either kind of plan must stale when the marks move underneath.
    func mutateSelection(_ mutation: (inout PhotoSelectionModel) -> Void) {
        let before = selection.selectedIDs
        mutation(&selection)
        guard planSource == .similarPhotos || planSource == .swipeReview else { return }
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
            await preserveResultsAfterDeletion(removing: plannedIDs.subtracting(success.remainingIDs))
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
    ///
    /// M13: a pipeline still *running* is never cancelled here. Its work for every asset
    /// that survived the mutation is valid, so the confirmed removals are recorded and
    /// reconciled out of its result the moment it lands (`deletionsDuringRunningPasses`)
    /// — a deletion never throws away a concurrent pass's progress or forces a re-run.
    private func preserveResultsAfterDeletion(removing deletedAssetIDs: Set<String>) async {
        planBuildGeneration += 1
        // Deletion invalidation: nothing derived from a removed asset may outlive it —
        // neither the resolved asset references (a stale `PHAsset` handle) nor cached
        // renditions at any size. LRU eviction is the memory bound; this is the
        // correctness hook (only reached for confirmed successes).
        if !deletedAssetIDs.isEmpty {
            PhotoAssetReferenceCache.shared.invalidate(assetIDs: deletedAssetIDs)
            await thumbnails.remove(assetIDs: deletedAssetIDs)
        }
        // `planSource` is deliberately left at the source that produced this deletion:
        // overwriting it here made a foreign outcome (screenshots/videos/blur) look like a
        // similar-photos result on the next review appearance, so that screen showed the
        // wrong deletion's summary instead of preparing its own plan.
        cancelVideoSizeResolution()
        videoSizeResolution = .idle

        // A pipeline still running sampled the pre-mutation catalog, but its work for every
        // asset that *survived* is valid (M13). Cancelling it would throw that away and
        // force a full re-run; instead the confirmed removals are recorded and reconciled
        // out of the result the moment it lands (see `reconcileDeletionDuringRun`). The
        // pass keeps its generation — a late write from it is still *its* write, now
        // reconciled, never a write from a superseded run.
        let similarityWasRunning = analysisState.isRunning
        let blurWasRunning = blurAnalysisState.isRunning
        if !deletedAssetIDs.isEmpty, similarityWasRunning || blurWasRunning {
            deletionsDuringRunningPasses.formUnion(deletedAssetIDs)
        }
        // Only a *standalone* catalog read is abandoned: it would complete with pre-mutation
        // records and could overwrite the pruned catalog. A pipeline's own pass is never
        // cancelled here (see above), and a unified session's shared enumeration cannot be
        // in flight — a deletion plan requires the completed catalog it would be building.
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
            await persistUpdatedScanResult(updated)
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
    private func persistUpdatedScanResult(_ result: PhotoAnalysisResult) async {
        if let existing = scanSnapshotStore.loadLatest() {
            let snapshot = ScanSnapshot(
                schemaVersion: ScanSnapshot.currentSchemaVersion,
                scanID: existing.scanID,
                completedAt: existing.completedAt,
                result: result
            )
            let store = scanSnapshotStore
            await Task.detached(priority: .utility) {
                try? store.save(snapshot)
            }.value
            lastScanCompletedAt = existing.completedAt
        } else {
            await persistCompletedScan(result)
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
        if standalone {
            // The catalog's own run is finished — release its checkpoint slot before any
            // chained resume claims the file (kind-aware: an analysis Stage A completion
            // passes `standalone: false` and never touches the `.similarity` file).
            finishCheckpointRun(kind: .catalog)
        }
        synchronizeScreenshotDataset()
        synchronizeVideoDataset()
        synchronizeBlurDataset()
        if standalone {
            // Lift the chained resume out *before* invalidation: the invalidation below
            // discards interrupted state (its own view of `pendingResume` must not race
            // this dispatch), then the resumed pass claims a fresh slot for the same
            // payload.
            let pending = pendingResume
            pendingResume = nil
            invalidateAnalysisAfterRebuild()
            if let pending {
                dispatchInterruptedResume(pending)
            }
        }
    }

    /// A standalone rebuild supersedes every fact derived from the previous catalog: groups,
    /// the photo selection, the sharpness results, and any prepared plan were all computed
    /// over data that no longer exists. The photo flows have no per-dataset signature check
    /// (screenshots and videos reconcile themselves above), so the invalidation is explicit
    /// here. Cannot run during an analysis, a sharpness pass (a standalone build is refused
    /// while either is running) or a deletion (same).
    ///
    /// The interrupted-run checkpoint is discarded with them — evidence gathered against the
    /// superseded catalog is stale by definition. A chained resume is an exception: the
    /// caller lifted its checkpoint out before calling, so it survives below and is
    /// re-claimed afterwards.
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
        discardInterruptedCheckpoint()
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
        case .running, .paused:
            // A rebuild is in flight (or was interrupted); reconcile again when it
            // completes, resumes, or is cancelled — never against partial enumeration.
            break
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
            let signature = videoDatasetSignature
            if !videoSizeResolution.isCurrent(for: signature) {
                // Bytes measured against another dataset are dropped, never mixed in.
                cancelVideoSizeResolution()
                videoSizeResolution = .idle
            }
        case .notStarted, .cancelled, .failed:
            videoSelection.reset()
            cancelVideoSizeResolution()
            videoSizeResolution = .idle
        case .running, .paused:
            // A rebuild is in flight (or was interrupted): nothing to reconcile against
            // until it completes, resumes, or is cancelled.
            break
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
        // Checked ∩ live selection: a check that no longer maps to a mark (the photo was
        // unmarked elsewhere or pruned) is not a deletion candidate, and a mark the user
        // just unchecked is not either. Read identically at build and at execution, so any
        // change on either side stales or refuses the plan.
        case .swipeReview: return swipeCleanupCheckedIDs.intersection(selection.selectedIDs)
        }
    }

    /// Dataset fingerprint a plan of `source` must match at execution time; `""` when there is
    /// no dataset (never matches a real plan's stamp, so such a plan is stale).
    private func currentDatasetSignature(for source: DeletionSelectionSource) -> String {
        switch source {
        case .similarPhotos, .swipeReview:
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
        case .similarPhotos, .swipeReview: return DeletionPlanner.analysisSignature(for: analysis)
        case .screenshots: return ScreenshotDataset.signature(in: catalog)
        case .videos: return VideoDataset.signature(in: catalog)
        case .blurReview:
            guard let blur else { return "" }
            return BlurDataset.signature(in: blur)
        }
    }

    // MARK: - Video size resolution (measure once, largest-first honestly)

    /// Ensures the video dataset is measured — the Video Cleanup screen's entry point.
    /// Starts from `.idle`, and **continues** a settled measurement (keeping every size it
    /// already measured and re-checking only the unknowns), so opening the screen never
    /// re-measures what it already knows. An in-flight run and a fully measured dataset
    /// are left exactly as they are: revisiting costs no provider calls at all.
    func startVideoSizeResolution() {
        guard !videoSizeResolution.isMeasuring else { return }
        resumeVideoSizeMeasurement()
    }

    /// The user-initiated Rescan (mirrors the Contacts screen's Rescan): discards the
    /// measured sizes and their persisted checkpoint and measures the dataset fresh. This
    /// is the only path that throws measured data away — ordinary entry reuses it.
    func rescanVideoSizes() {
        videoSizeGeneration += 1
        videoSizeTask?.cancel()
        videoSizeTask = nil
        videoSizeResolution = .idle
        clearVideoCheckpointIfOwned()
        resumeVideoSizeMeasurement()
    }

    /// Measures the videos whose sizes are still unknown (all of them when idle), in bounded
    /// sequential batches. Read-only: it never touches the selection or a prepared plan — plan
    /// sizes are resolved separately for the reviewed subset at prepare time. Safe to call
    /// repeatedly: while a run is in flight nothing restarts, and a fully measured dataset
    /// settles again without calling the provider.
    ///
    /// Coexists with analysis passes: sizing is I/O-bound over its own bounded batches, so it
    /// is *not* deferred while a pass runs — deferring it was the failure that left the Video
    /// Cleanup screen unmeasured forever under chained passes (every pass start also used to
    /// cancel it, and only a visible screen's observer restarted it).
    func resumeVideoSizeMeasurement() {
        guard !videoSizeResolution.isMeasuring else { return }
        guard photoPermissionState.isUsable else { return }
        guard case .completed(let catalog) = catalogState else { return }

        let videos = VideoDataset.records(in: catalog)
        guard !videos.isEmpty else {
            videoSizeResolution = .idle
            return
        }

        let signature = videoDatasetSignature
        let total = videos.count
        // A settled run that already attempted the whole dataset is authoritative: a
        // revisit does nothing at all — it keeps every measured size and never re-pokes
        // the videos that could not be measured. (A partial run continues below.)
        if videoSizeResolution.isCurrent(for: signature),
           let existing = videoSizeResolution.measurement,
           existing.total == total,
           existing.resolvedCount >= existing.total {
            return
        }
        var measuredBytes: [String: Int64]
        var unavailableIDs: Set<String> = []
        if videoSizeResolution.isCurrent(for: signature) {
            measuredBytes = videoSizeResolution.bytes // resume: keep what this dataset already measured
            // …and keep its known failures: a video that could not be measured stays
            // marked unavailable until a later attempt measures it (the fingerprint
            // match guarantees these ids still belong to this dataset).
            unavailableIDs = videoSizeResolution.measurement?.unavailableIDs ?? []
        } else {
            measuredBytes = [:] // another dataset's bytes are never mixed into this one
        }
        // Sizes an interrupted run already measured, validated against this catalog: only
        // an asset that still exists with the exact recorded modification date
        // contributes; deleted or re-exported videos are measured again.
        if let checkpoint = resumableCheckpoints[.videoSizes],
           !checkpoint.videoSizes.isEmpty {
            var index: [String: PhotoAssetRecord] = [:]
            index.reserveCapacity(videos.count)
            for record in videos {
                index[record.localIdentifier] = record
            }
            for entry in checkpoint.videoSizes {
                guard measuredBytes[entry.assetID] == nil,
                      let record = index[entry.assetID],
                      record.modificationDate == entry.modified
                else { continue }
                measuredBytes[entry.assetID] = entry.bytes
            }
        }
        // Newest-first: the Photos daemon classifies videos at a hard ~125/second ceiling
        // (measured on an iPhone 17 Pro — independent of probe width or connection count),
        // and locally stored videos are the newest ones on an Optimize-Storage library.
        // Walking newest-first therefore surfaces the sized, sorted local results within
        // seconds while the older cloud-only tail resolves in the background — every video
        // is still probed; nothing is skipped or guessed.
        let targets = videos
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .lazy
            .map(\.localIdentifier)
            .filter { measuredBytes[$0] == nil }

        guard !targets.isEmpty else {
            videoSizeResolution = .settled(
                VideoSizeResolution.Measurement(
                    datasetSignature: signature,
                    bytes: measuredBytes,
                    total: total
                )
            )
            // Fully measured: persist the sizes as kept scan data (not clear them), so a
            // relaunch and every later visit reuse them instead of re-measuring. Only the
            // user's Rescan discards them.
            writeVideoSizeCheckpoint()
            syncBackgroundTask()
            return
        }

        videoSizeGeneration += 1
        let generation = videoSizeGeneration
        videoSizeTask?.cancel()
        videoSizeResolution = .measuring(
            VideoSizeResolution.Measurement(
                datasetSignature: signature,
                bytes: measuredBytes,
                total: total,
                unavailableIDs: unavailableIDs
            )
        )

        let provider = sizeProvider
        videoSizeTask = Task { [weak self] in
            guard let self else { return }
            let batchSize = VideoSizeResolution.measurementBatchSize
            var pending = Array(targets)
            var knownUnavailable = unavailableIDs
            var lastPublish = ContinuousClock.now
            while !pending.isEmpty {
                let batch = Array(pending.prefix(batchSize))
                pending.removeFirst(batch.count)
                // Outcomes, not bare sizes: a batch the provider could not measure
                // (iCloud-only, unreadable) still resolves every identifier — the
                // on-screen progress advances through failures instead of sitting at
                // "0 of N" while real work is happening.
                let outcomes = await provider.outcomes(for: batch)
                // Each batch re-checks the generation, so a cancelled run's remaining batches
                // are discarding no-ops — they can never overwrite newer state.
                guard self.videoSizeGeneration == generation else { return }
                for identifier in batch {
                    switch outcomes[identifier] {
                    case .measured(let size):
                        measuredBytes[identifier] = size
                        knownUnavailable.remove(identifier)
                    case .unavailable, nil:
                        // Never counted as measured, never zero — recorded as an
                        // attempted-and-failed id the UI may call "unavailable".
                        knownUnavailable.insert(identifier)
                    }
                }
                // Coalesced publishes: a cloud-only library resolves batches in
                // milliseconds, and one observed-state write per batch would storm the
                // main actor. At most ~4 updates per second; the settled state below
                // always publishes, so the final frame is never dropped.
                if ContinuousClock.now - lastPublish >= .milliseconds(250) {
                    lastPublish = ContinuousClock.now
                    self.videoSizeResolution = .measuring(
                        VideoSizeResolution.Measurement(
                            datasetSignature: signature,
                            bytes: measuredBytes,
                            total: total,
                            unavailableIDs: knownUnavailable
                        )
                    )
                }
            }
            guard self.videoSizeGeneration == generation else { return }
            self.videoSizeResolution = .settled(
                VideoSizeResolution.Measurement(
                    datasetSignature: signature,
                    bytes: measuredBytes,
                    total: total,
                    unavailableIDs: knownUnavailable
                )
            )
            self.videoSizeTask = nil
            // Fully measured: keep what this run measured as the persisted scan data the
            // next session reuses — the checkpoint is no longer just interrupted-run
            // evidence, it is the kept result. Only Rescan clears it.
            self.writeVideoSizeCheckpoint()
            self.syncBackgroundTask()
        }
        syncBackgroundTask()
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

    // MARK: - Interrupted runs: checkpoints, pause, resume (Phase C)

    /// Claims this kind's checkpoint channel for a run and returns the sequence its sink
    /// must present. `carrying` resumes an interrupted run's payload; `nil` starts empty —
    /// and first discards that kind's interrupted state, because an explicit new run
    /// supersedes resumable work (the Resume button is what continues it, never a fresh tap).
    @discardableResult
    private func beginCheckpointRun(
        kind: ScanCheckpoint.Kind,
        carrying checkpoint: ScanCheckpoint?
    ) -> Int {
        if checkpoint == nil {
            discardInterruptedCheckpoint(kinds: [kind])
        }
        let sequence = nextRunSequence
        nextRunSequence += 1
        checkpointChannels.accumulator(for: kind)
            .begin(kind: kind, runSequence: sequence, carrying: checkpoint)
        // The accumulator owns the payload from here (video checkpoints are the exception:
        // they never begin a run and keep their `resumableCheckpoints` entry as their seed).
        resumableCheckpoints[kind] = nil
        return sequence
    }

    /// Abandons interrupted work for the given kinds: files gone, no straggler can
    /// resurrect them, and every affected paused surface returns to "not started". Used by
    /// explicit cancels, fresh runs, and supersession — never by completion (which is
    /// kind-aware, via `finishCheckpointRun`). Defaults to every kind: "abandon everything".
    private func discardInterruptedCheckpoint(kinds: [ScanCheckpoint.Kind] = ScanCheckpoint.Kind.allCases) {
        for kind in kinds {
            let accumulator = checkpointChannels.accumulator(for: kind)
            accumulator.endRun()
            // Blocks every write at or below the last known run, so a late flush from the
            // discarded run can never bring the file back.
            checkpointChannels.writer(for: kind).clear(through: nextRunSequence - 1)
            resumableCheckpoints[kind] = nil
        }
        pendingResume = nil
        lastVideoCheckpointSequence = nil
        if kinds.contains(.similarity), case .paused = analysisState { analysisState = .notStarted }
        if kinds.contains(.catalog), case .paused = catalogState { catalogState = .notStarted }
        if kinds.contains(.blur), case .paused = blurAnalysisState { blurAnalysisState = .notStarted }
    }

    /// Completion (or non-pause cancellation) release for the pass that owns its channel
    /// right now. A no-op when that channel belongs to nobody — that file is not this run's
    /// to clear, and blocking through a foreign sequence would freeze its owner out.
    private func finishCheckpointRun(kind: ScanCheckpoint.Kind) {
        let accumulator = checkpointChannels.accumulator(for: kind)
        guard accumulator.activeKind == kind else { return }
        let sequence = accumulator.currentRunSequence
        accumulator.endRun()
        checkpointChannels.writer(for: kind).clear(owning: kind, through: sequence)
    }

    /// Releases the video-size checkpoint once its dataset is fully measured. Only the video
    /// file is ever removed (its own channel), and only writes at or below its own sequence
    /// are blocked — every other kind's file lives in its own channel and is untouched.
    private func clearVideoCheckpointIfOwned() {
        guard let checkpoint = resumableCheckpoints[.videoSizes] else { return }
        let sequence = lastVideoCheckpointSequence ?? checkpoint.runSequence
        lastVideoCheckpointSequence = nil
        resumableCheckpoints[.videoSizes] = nil
        checkpointChannels.writer(for: .videoSizes).clear(owning: .videoSizes, through: sequence)
    }

    /// Persists an in-flight video measurement as resumable state — only while a
    /// measurement is running and only with bytes this catalog actually measured. One
    /// synchronous bounded write at the pause transition: determinism matters more than a
    /// few milliseconds there, and this is never a per-asset or per-batch write.
    private func writeVideoSizeCheckpoint() {
        let measurement: VideoSizeResolution.Measurement
        switch videoSizeResolution {
        case .measuring(let running), .settled(let running):
            measurement = running
        case .idle:
            return
        }
        guard case .completed(let catalog) = catalogState else { return }
        let videos = VideoDataset.records(in: catalog)
        guard !videos.isEmpty, !measurement.bytes.isEmpty else { return }
        var index: [String: PhotoAssetRecord] = [:]
        index.reserveCapacity(videos.count)
        for record in videos {
            if index[record.localIdentifier] == nil {
                index[record.localIdentifier] = record
            }
        }
        let entries = measurement.bytes.compactMap { assetID, bytes -> VideoSizeEntry? in
            guard let record = index[assetID] else { return nil }
            return VideoSizeEntry(assetID: assetID, modified: record.modificationDate, bytes: bytes)
        }
        guard !entries.isEmpty else { return }
        let sequence = nextRunSequence
        nextRunSequence += 1
        let checkpoint = ScanCheckpoint(
            runSequence: sequence,
            kind: .videoSizes,
            startedAt: Date(),
            updatedAt: Date(),
            stage: "",
            completedUnits: entries.count,
            totalUnits: measurement.total,
            videoSizes: entries.sorted { $0.assetID < $1.assetID }
        )
        lastVideoCheckpointSequence = sequence
        resumableCheckpoints[.videoSizes] = checkpoint
        checkpointChannels.writer(for: .videoSizes).write(checkpoint)
    }

    /// Freezes every in-flight pass at an interruption (background expiration), in the one
    /// order that keeps state and file consistent: stop each running pass and tag its
    /// progress, write the accumulated checkpoint while it is still the newest state, then
    /// let a running video measurement claim the slot (which it cannot do while a paused
    /// heavy pass's file exists). Fully synchronous — this is the last deterministic moment.
    private func pauseAllActiveWork() {
        var interruptedWork = false
        var interruptedKinds: [ScanCheckpoint.Kind] = []
        if case .running(let progress) = analysisState {
            interruptedWork = true
            interruptedKinds.append(.similarity)
            analysisGeneration += 1
            analysisTask?.cancel()
            analysisTask = nil
            // The progress on screen is the progress saved — no rounding to a stale tick.
            analysisState = .paused(progress)
            checkpointChannels.accumulator(for: .similarity).setProgress(
                kind: .similarity,
                stage: progress.stage.rawValue,
                completed: progress.completedUnits,
                total: progress.totalUnits
            )
        }
        // A unified session's shared read is in flight when its `catalogTask` is running but
        // `catalogState` never went `.running` (the read reports through similarity's
        // `preparing` stage). Interruption abandons the shared read itself — both pipelines
        // are paused above and below, and resume restarts the read for both.
        if sharedEnumerationInFlight {
            interruptedWork = true
            if !interruptedKinds.contains(.catalog) { interruptedKinds.append(.catalog) }
            catalogGeneration += 1
            catalogTask?.cancel()
            catalogTask = nil
            sharedEnumerationInFlight = false
        }
        if case .running(let progress) = catalogState {
            interruptedWork = true
            if !interruptedKinds.contains(.catalog) { interruptedKinds.append(.catalog) }
            catalogGeneration += 1
            catalogTask?.cancel()
            catalogTask = nil
            catalogState = .paused(progress)
            checkpointChannels.accumulator(for: .catalog).setProgress(
                kind: .catalog,
                stage: "catalog",
                completed: progress.enumeratedCount,
                total: progress.totalCount
            )
        }
        if case .running(let progress) = blurAnalysisState {
            interruptedWork = true
            interruptedKinds.append(.blur)
            blurAnalysisGeneration += 1
            blurAnalysisTask?.cancel()
            blurAnalysisTask = nil
            blurAnalysisState = .paused(progress)
            checkpointChannels.accumulator(for: .blur).setProgress(
                kind: .blur,
                stage: "",
                completed: progress.completedUnits,
                total: progress.totalUnits
            )
        }
        // After this loop each interrupted pass's own file is exactly what resume will start
        // from — every kind owns its channel, so concurrent passes never clobber one another.
        for kind in interruptedKinds {
            let accumulator = checkpointChannels.accumulator(for: kind)
            accumulator.flushNowSync()
            if let paused = accumulator.snapshot() {
                resumableCheckpoints[kind] = paused
            }
            accumulator.endRun()
        }
        if case .measuring = videoSizeResolution {
            interruptedWork = true
            // Checkpoint first (still `.measuring`, so its bytes are complete), then stop:
            // at most one batch of sizes is lost if the process dies here.
            writeVideoSizeCheckpoint()
            cancelVideoSizeResolution()
        }
        // Estimator anchors from the live run would render as a live countdown against a
        // paused card — reset so resume re-anchors from actual resumed samples.
        scanETAEstimator.reset()
        // Only an interruption *this session* auto-resumes on foreground. A checkpoint
        // restored at launch keeps waiting for an explicit tap.
        if interruptedWork {
            pausedThisSession = true
        }
        syncBackgroundTask()
    }

    /// Insurance-flushes every channel that has an active run (one bounded write per active
    /// pass, never per asset, never on the main actor during a run). Video sizes persist
    /// through their own transition, not here.
    private func flushActiveCheckpoints() {
        for kind in ScanCheckpoint.Kind.allCases {
            let accumulator = checkpointChannels.accumulator(for: kind)
            if accumulator.isActive {
                accumulator.flushNowSync()
            }
        }
    }

    /// Whether anything is still computing. The background task is held only for this —
    /// never as a promise of unlimited time, and never while foregrounded.
    private var hasActiveWork: Bool {
        analysisState.isRunning
            || catalogState.isRunning
            || blurAnalysisState.isRunning
            || videoSizeResolution.isMeasuring
    }

    /// Keeps the OS background task aligned with reality: held only while backgrounded
    /// with work in flight, released the moment either ends (completion, cancel, pause,
    /// foreground). Expiration pauses the runs instead of racing the remaining time.
    private func syncBackgroundTask() {
        if lifecyclePhase == .background && hasActiveWork {
            guard !backgroundTasks.isHolding else { return }
            backgroundTasks.begin { [weak self] in
                guard let self else { return }
                self.handleBackgroundExpiration()
            }
        } else if backgroundTasks.isHolding {
            backgroundTasks.end()
        }
    }

    /// Scene-phase entry point. `.active` re-reconciles permissions and storage, releases
    /// any background task, and auto-resumes what *this session* interrupted. `.inactive`
    /// only flushes — the app may come straight back, and iOS allows a moment of work.
    /// `.background` arms the interruption machinery. Nothing here assumes `background`
    /// means imminent death, or that a background task buys uninterrupted execution.
    func handleLifecycle(_ phase: AppLifecyclePhase) {
        lifecyclePhase = phase
        switch phase {
        case .active:
            // Returning from Settings (or the app being foregrounded) is the only moment a
            // permission granted elsewhere becomes visible here — without this, both
            // permission screens read the boot-time status forever.
            refreshPermissions()
            Task { await refreshStorage() }
            syncBackgroundTask()
            if pausedThisSession {
                resumeInterruptedWork()
            }
        case .inactive:
            flushActiveCheckpoints()
        case .background:
            enterBackground()
        }
    }

    /// The app left the foreground: insurance-flush whatever the batchers have not written
    /// yet (one bounded write per active pass, not per asset), then hold a background task
    /// only if there is work to protect. Video measurement keeps running under the task's
    /// budget.
    private func enterBackground() {
        flushActiveCheckpoints()
        syncBackgroundTask()
    }

    /// The system is about to reclaim the background task. Pause synchronously — this is
    /// the last deterministic moment — then let `syncBackgroundTask` release it.
    private func handleBackgroundExpiration() {
        pauseAllActiveWork()
        syncBackgroundTask()
    }

    /// Resumes the interrupted run, if the library still allows it. Safe to call
    /// repeatedly: no-ops while work is running, during deletion, without Photos access,
    /// or with nothing to resume.
    ///
    /// M13: a unified session checkpoints both passes at once, so a resume that finds both
    /// a similarity and a sharpness checkpoint restarts **both** from their own files — one
    /// shared enumeration, two independent pipelines. A resume that finds only one resumes
    /// just that pass (a sharpness-only checkpoint is the honest state after the similarity
    /// pass completed and its file was released).
    func resumeInterruptedWork() {
        guard !analysisState.isRunning,
              !catalogState.isRunning,
              !blurAnalysisState.isRunning
        else { return }
        guard !deletionState.isDeleting else { return }
        guard photoPermissionState.isUsable else { return }
        pausedThisSession = false
        let similarityCheckpoint = resumableCheckpoints[.similarity]
        let blurCheckpoint = resumableCheckpoints[.blur]
        if let similarityCheckpoint, let blurCheckpoint {
            // Both passes of one unified session were interrupted together: resume them
            // together, each seeded from its own evidence.
            startImageAnalysis(resuming: similarityCheckpoint, blurCheckpoint: blurCheckpoint)
            return
        }
        if let similarityCheckpoint {
            dispatchInterruptedResume(similarityCheckpoint)
            return
        }
        if let blurCheckpoint {
            dispatchInterruptedResume(blurCheckpoint)
            return
        }
        if let catalogCheckpoint = resumableCheckpoints[.catalog] {
            dispatchInterruptedResume(catalogCheckpoint)
            return
        }
        if let videoCheckpoint = resumableCheckpoints[.videoSizes] {
            dispatchInterruptedResume(videoCheckpoint)
        }
    }

    /// Routes a single checkpoint to the pass that owns it — chaining a catalog rebuild
    /// first when the seed needs fresh records to reconcile against (blur and video sizes
    /// both do; similarity rebuilds its own catalog as Stage A regardless). The chained
    /// rebuild owns no checkpoint of its own: it must not begin one, and must not discard
    /// the one it is rebuilding for (`startCatalogBuild` keys that off `pendingResume`).
    private func dispatchInterruptedResume(_ checkpoint: ScanCheckpoint) {
        switch checkpoint.kind {
        case .similarity:
            startSimilarityAnalysis(resuming: checkpoint)
        case .catalog:
            startCatalogBuild(resuming: checkpoint)
        case .blur:
            if case .completed = catalogState {
                startBlurAnalysis(resuming: checkpoint)
            } else {
                pendingResume = checkpoint
                startCatalogBuild()
            }
        case .videoSizes:
            if case .completed = catalogState {
                resumableCheckpoints[.videoSizes] = checkpoint
                resumeVideoSizeMeasurement()
            } else {
                pendingResume = checkpoint
                startCatalogBuild()
            }
        }
    }

    /// Evidence from an interrupted similarity run that survives reconciliation against the
    /// fresh catalog: an entry is trusted only when the asset still exists with the exact
    /// modification date it was recorded under. Deleted or changed assets are recomputed,
    /// and anything the checkpoint never saw is simply new work — an asset that was merely
    /// unavailable during the interrupted run gets its one bounded retry here (a later
    /// resume retries it again; nothing is ever marked analyzed without evidence).
    private static func fingerprintSeed(
        from checkpoint: ScanCheckpoint?,
        records: [PhotoAssetRecord]
    ) -> FingerprintSeed {
        guard let checkpoint, checkpoint.kind == .similarity else { return .empty }
        var index: [String: PhotoAssetRecord] = [:]
        index.reserveCapacity(records.count)
        for record in records {
            if index[record.localIdentifier] == nil {
                index[record.localIdentifier] = record
            }
        }
        var seed = FingerprintSeed()
        for entry in checkpoint.perceptualHashes {
            guard let record = index[entry.assetID],
                  record.modificationDate == entry.modified
            else { continue }
            seed.perceptualHashes[entry.assetID] = PerceptualHash(bits: entry.bits)
        }
        for entry in checkpoint.byteKeys {
            guard let record = index[entry.assetID],
                  record.modificationDate == entry.modified
            else { continue }
            seed.byteKeys[entry.assetID] = ContentByteKey(
                imageBytes: entry.imageBytes,
                videoBytes: entry.videoBytes
            )
        }
        return seed
    }

    /// Verdicts from an interrupted sharpness pass that survive reconciliation: the asset
    /// must still exist with the recorded modification date, and the calibration must be
    /// the one this run will classify with — otherwise the seed is refused outright (the
    /// engine refuses it too; both checks exist so no path can mix calibrations). A
    /// candidate without its score cannot explain itself in review, so it re-measures.
    /// `nonisolated` so the walk over every catalog record and saved verdict runs off the
    /// main actor (see `startBlurAnalysis`).
    nonisolated private static func blurSeed(
        from checkpoint: ScanCheckpoint?,
        records: [PhotoAssetRecord],
        thresholds: BlurThresholds
    ) -> BlurAnalysisSeed? {
        guard let checkpoint, checkpoint.kind == .blur else { return nil }
        guard checkpoint.blurThresholds == thresholds else { return nil }
        var index: [String: PhotoAssetRecord] = [:]
        index.reserveCapacity(records.count)
        for record in records {
            if index[record.localIdentifier] == nil {
                index[record.localIdentifier] = record
            }
        }
        var seed = BlurAnalysisSeed(thresholds: thresholds)
        for entry in checkpoint.blurVerdicts {
            guard let record = index[entry.assetID],
                  record.modificationDate == entry.modified
            else { continue }
            if entry.verdict.isCandidate, entry.laplacianVariance == nil { continue }
            seed.verdicts[entry.assetID] = BlurSeedVerdict(
                verdict: entry.verdict,
                laplacianVariance: entry.laplacianVariance
            )
        }
        return seed
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
        // the startup condition every existing dashboard UI test was written against. The
        // interrupted-run checkpoint goes with it: a leaked paused card would break the same
        // tests on their second launch.
        if arguments.contains("-resetScanSnapshot") {
            FileScanSnapshotStore().clear()
            FileScanCheckpointStore().clear()
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
            // The environment owns lifecycle policy: permission reconciliation on return,
            // checkpoint flushes on inactive, interruption handling on background, and
            // same-session resume when active again (see `handleLifecycle`).
            env.handleLifecycle(AppLifecyclePhase(scenePhase: newPhase))
        }
    }
}

extension AppLifecyclePhase {
    init(scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            // A future phase behaves like the most conservative one we know: stop assuming
            // foreground, flush, and treat it as background for task purposes.
            self = .background
        }
    }
}
