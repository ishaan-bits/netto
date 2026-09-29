import Combine
import SwiftUI

/// Which selection produced a deletion plan. Both sources share the one plan → confirmation →
/// mutation → verification pipeline — the source only decides which selection model a plan is
/// built from and which dataset fingerprint it is validated against.
enum DeletionSelectionSource: Sendable, Equatable {
    case similarPhotos
    case screenshots
}

@MainActor
final class AppEnvironment: ObservableObject {
    let storageProvider: any StorageProviding
    let photoPermission: any PhotoLibraryPermissionServicing
    let contactsPermission: any ContactsPermissionServicing
    /// Review thumbnails: bounded, coalesced, pixel-capped (never full-resolution pixels).
    let thumbnails: ThumbnailStore
    /// Real byte measurement for the reviewed selection (bounded, never during enumeration).
    let sizeProvider: any AssetSizeProviding
    /// The deletion boundary — the only path from this app to Photos mutation.
    let deletionService: any PhotoDeleting

    @Published var flowState: AppFlowState = .launching
    @Published var prompt: PermissionPrompt = .none
    @Published var photoPermissionState: PermissionState = .notDetermined
    @Published var contactsPermissionState: PermissionState = .notDetermined
    @Published var storageSnapshot: StorageSnapshot?
    @Published var catalogState: CatalogScanState = .notStarted
    @Published var analysisState: PhotoAnalysisState = .notStarted
    @Published var selection = PhotoSelectionModel()
    /// Screenshots marked for cleanup — a filter over the catalog, not a second enumeration.
    @Published var screenshotSelection = ScreenshotSelectionModel()
    /// The deletion state machine (§16). Every change goes through `applyDeletion`.
    @Published var deletionState: DeletionState = .noSelection

    private let makePhotoLibrary: @Sendable () throws -> any PhotoLibraryReading
    /// Identity of this app session; plans from another session can never execute.
    private let deletionSessionToken: String
    private var catalogTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// Bumped on every start and cancel. An in-flight run compares it before each state write,
    /// so a cancelled run can never overwrite a newer one's state.
    private var analysisGeneration = 0
    /// Bumped on every plan build; a superseded build discards its result instead of writing it.
    private var planBuildGeneration = 0
    /// Which source the current/last plan was built from; confirmation validates against it.
    private var planSource: DeletionSelectionSource = .similarPhotos

    init(
        storageProvider: any StorageProviding = SystemStorageProvider(),
        photoPermission: any PhotoLibraryPermissionServicing = PhotoLibraryPermissionService(),
        contactsPermission: any ContactsPermissionServicing = ContactsPermissionService(),
        makePhotoLibrary: @escaping @Sendable () throws -> any PhotoLibraryReading = {
            try SystemPhotoLibrary()
        },
        thumbnailLoader: any PhotoThumbnailLoading = PhotoKitThumbnailLoader(),
        sizeProvider: any AssetSizeProviding = PhotoKitAssetSizeProvider(),
        deletionService: any PhotoDeleting = PhotoDeletionService(),
        sessionToken: String = UUID().uuidString
    ) {
        self.storageProvider = storageProvider
        self.photoPermission = photoPermission
        self.contactsPermission = contactsPermission
        self.makePhotoLibrary = makePhotoLibrary
        self.thumbnails = ThumbnailStore(loader: thumbnailLoader)
        self.sizeProvider = sizeProvider
        self.deletionService = deletionService
        self.deletionSessionToken = sessionToken
    }

    func bootstrap() async {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
        storageSnapshot = await storageProvider.deviceStorage()
        flowState = .dashboard
    }

    func refreshStorage() async {
        storageSnapshot = await storageProvider.deviceStorage()
    }

    func refreshPermissions() {
        photoPermissionState = photoPermission.currentStatus()
        contactsPermissionState = contactsPermission.currentStatus()
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
    }

    /// Builds the metadata catalog. Enumeration runs on a detached producer task; this loop only
    /// consumes ordered events, so the main actor stays responsive while the library is read.
    func startCatalogBuild() {
        catalogTask?.cancel()

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
        catalogState = .running(.indeterminate)

        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in builder.makeScanStream(reading: reading) {
                    switch event {
                    case .progress(let progress):
                        if self.catalogState.isRunning {
                            self.catalogState = .running(progress)
                        }
                    case .completed(let result):
                        self.noteCatalogCompleted(result)
                    }
                }
            } catch is CancellationError {
                self.catalogState = .cancelled
            } catch let failure as CatalogScanFailure {
                self.catalogState = failure == .cancelled ? .cancelled : .failed(failure)
            } catch {
                self.catalogState = .failed(.underlying("Photos access is required to read your library."))
            }
        }
    }

    func cancelCatalogBuild() {
        catalogTask?.cancel()
        catalogTask = nil
        if catalogState.isRunning {
            catalogState = .cancelled
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
    func startSimilarityAnalysis() {
        guard !analysisState.isRunning else { return }
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

        analysisState = .running(
            PhotoAnalysisProgress(stage: .preparing, completedUnits: 0, totalUnits: 0)
        )

        let builder = PhotoCatalogBuilder()
        let engine = PhotoSimilarityEngine()

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
                        self.analysisState = .running(progress)
                    case .completed(let result):
                        sawCompletion = true
                        self.selection = PhotoSelectionModel(result: result)
                        self.analysisState = .completed(result)
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
                self.finishAnalysis(
                    generation,
                    as: .failed(.underlying(String(describing: error)))
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

    // MARK: - Deletion (plan → confirmation → mutation → verification)

    /// Builds an immutable deletion plan from `source`'s current selection.
    ///
    /// Never runs while a build, a confirmed deletion, or a result is on screen; requires a
    /// completed catalog — plus a completed analysis for the similar-photos source (screenshots
    /// are a subtype filter recorded during enumeration, so they never wait on analysis);
    /// resolves real sizes through `sizeProvider` (never during enumeration); then validates
    /// the fresh plan against the *current* context before presenting it for review.
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
        case .screenshots:
            analysisResult = .empty
        case .similarPhotos:
            guard case .completed(let completed) = analysisState else {
                applyDeletion(.failed("Similarity analysis has not finished. Run analysis, then review again."))
                return
            }
            analysisResult = completed
        }

        // The fingerprint is derived from the inputs captured *now*; the self-check below
        // compares it against the context as it is *then*, so a dataset change during size
        // resolution lands the plan in `.planStale`, never in `.readyForReview`.
        let datasetSignature = Self.datasetSignature(
            for: source,
            catalog: catalogResult,
            analysis: analysisResult
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
    func reviewDidAppear(from source: DeletionSelectionSource) {
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
        mutation(&selection)
        guard planSource == .similarPhotos else { return }
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

    /// Leaves a terminal result state (also used to leave `.planStale`).
    func dismissDeletionResult() {
        applyDeletion(.noSelection)
    }

    private func handleDeletionOutcome(_ outcome: DeletionOutcome) async {
        switch outcome {
        case .succeeded(let success):
            if success.isFullyRemoved {
                applyDeletion(.succeeded(success))
            } else {
                applyDeletion(.needsReview(success))
            }
            // Photos changed: drop every dataset-derived fact so nothing stale is shown again.
            resetLibraryStateAfterDeletion()
            await refreshStorage()

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

        case .verificationFailed(let message), .revalidationFailed(let message):
            applyDeletion(.failed(message))

        case .cancelled:
            if case .deleting(let plan) = deletionState {
                applyDeletion(.readyForReview(plan))
            } else {
                assertionFailure("cancelled outcome outside .deleting")
            }
        }
    }

    /// Selection is reset, in-flight analysis invalidated, and both datasets marked for a fresh
    /// read — the library changed, so nothing read before the deletion may be reused.
    private func resetLibraryStateAfterDeletion() {
        planBuildGeneration += 1
        selection = PhotoSelectionModel()
        screenshotSelection.reset()
        planSource = .similarPhotos
        analysisGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        analysisState = .notStarted
        catalogState = .notStarted
    }

    private func isCurrentPlanBuild(_ generation: Int) -> Bool {
        planBuildGeneration == generation
    }

    // MARK: - Dataset synchronization (screenshot subset of the catalog)

    /// Stores a completed catalog and reconciles the screenshot selection against it, so a
    /// rebuilt dataset can never leave the selection pointing at vanished assets.
    private func noteCatalogCompleted(_ result: CatalogScanResult) {
        catalogState = .completed(result)
        synchronizeScreenshotDataset()
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

    /// The identifiers `source`'s selection is drawn from right now.
    private func selectionIDs(for source: DeletionSelectionSource) -> Set<String> {
        switch source {
        case .similarPhotos: return selection.selectedIDs
        case .screenshots: return screenshotSelection.selectedIDs
        }
    }

    /// Dataset fingerprint a plan of `source` must match at execution time; `""` when there is
    /// no dataset (never matches a real plan's stamp, so such a plan is stale).
    private func currentDatasetSignature(for source: DeletionSelectionSource) -> String {
        switch source {
        case .similarPhotos:
            guard case .completed(let result) = analysisState else { return "" }
            return DeletionPlanner.analysisSignature(for: result)
        case .screenshots:
            guard case .completed(let result) = catalogState else { return "" }
            return ScreenshotDataset.signature(in: result)
        }
    }

    /// The fingerprint stamped at build time, derived from the inputs captured with the plan.
    private static func datasetSignature(
        for source: DeletionSelectionSource,
        catalog: CatalogScanResult,
        analysis: PhotoAnalysisResult
    ) -> String {
        switch source {
        case .similarPhotos: return DeletionPlanner.analysisSignature(for: analysis)
        case .screenshots: return ScreenshotDataset.signature(in: catalog)
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
    static func live() -> AppEnvironment {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fixtureLibrary") {
            return AppEnvironment(
                makePhotoLibrary: { FixturePhotoLibrary() },
                thumbnailLoader: PreviewData.ThumbnailLoader(),
                sizeProvider: FixtureSizeProvider()
            )
        }
        #endif
        return AppEnvironment()
    }
}

struct RootView: View {
    @StateObject private var env = AppEnvironment.live()

    var body: some View {
        Group {
            switch env.flowState {
            case .launching:
                ProgressView("Starting Netto…")
            case .dashboard, .scanning, .resultsAvailable, .review,
                 .deleting, .deletionCompleted, .deletionFailed:
                DashboardView()
                    .environmentObject(env)
            }
        }
        .task {
            await env.bootstrap()
        }
    }
}
